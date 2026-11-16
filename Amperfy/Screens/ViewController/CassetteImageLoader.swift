//
//  CassetteImageLoader.swift
//  Amperfy
//
//  cassette 2026-11-16 (image ladder Phase 4, BUG-827): the one loader for every picture the
//  phone shows from the cloud: station marks, show pictures, song and record covers on the
//  radio, Search's catalog rows, the account photo, the cover of an album no longer on the phone.
//  It began as RadioArtLoader (BUG-818) and keeps its shape.
//
//  The rules (docs/reference/CASSETTE_IMAGES.md, packages/cassette-kit/IMAGES.md):
//  - A picture is asked at the ladder rung its frame needs (CassetteKitTokens.Images.pickRung),
//    from the reference the cloud sent beside its plain address. The phone never builds a ladder
//    address itself: a picture with no reference is loaded from its plain address, as before,
//    and decoded no larger than the same rung.
//  - A ladder size that fails falls back to the plain address once.
//  - One decode per picture and rung, off the main thread, in a byte-capped memory cache.
//  - `keep` pictures (the person's own: their account photo, the albums on their devices) are
//    also written to Application Support, so they show the same offline as online.
//  The person's own covers from their computer are not here: LibraryEntityImage draws those.
//  Mix covers are drawn by the site (MixCoverCache) and asked at a rung there.
//

import AmperfyKit
import CryptoKit
import ImageIO
import UIKit

/// The old name, still used by work in progress elsewhere (PutSomethingOnRow). Same loader.
typealias RadioArtLoader = CassetteImageLoader

// MARK: - CassetteImageLoader

@MainActor
final class CassetteImageLoader {
  static let shared = CassetteImageLoader()

  private let cache = NSCache<NSString, UIImage>()
  private var inFlight = [String: Task<UIImage?, Never>]()
  /// The ladder reference the cloud sent beside each plain address, by that address.
  private var refs = [String: CassetteImageRef]()
  /// The rungs of each picture now in memory, so a frame can show a size it already has.
  private var rungsInMemory = [String: Set<Int>]()

  private init() {
    cache.countLimit = 200
    // BUG-818: by bytes too. Three searches of full-size covers once added about 90 MB.
    cache.totalCostLimit = 24 * 1024 * 1024
  }

  // MARK: Sizes

  nonisolated private static var rungs: [Int] { CassetteKitTokens.Images.rungs }

  /// The station page's 240pt picture at 3x (720 pixels), as a rung: Home's 150pt tiles and
  /// CarPlay draw the same bitmap smaller.
  static let maxPixel = rung(forPixels: 720)
  /// Search's 48pt rows at 3x.
  static let rowPixel = rung(forPixels: 144)

  /// The smallest rung holding `pixels`, else the top one.
  nonisolated static func rung(forPixels pixels: Int) -> Int {
    rungs.first { $0 >= pixels } ?? rungs[rungs.count - 1]
  }

  /// The rung for a square frame of `side` points on this screen (the kit's one pick rule).
  static func rung(side: CGFloat, scale: CGFloat = 0) -> Int {
    let screen = scale > 0 ? scale : UITraitCollection.current.displayScale
    return CassetteKitTokens.Images.pickRung(
      w: Double(side), h: Double(side), scale: Double(screen > 0 ? screen : 3),
      aspect: CassetteKitTokens.Images.assumedCoverAspect
    )
  }

  /// A station mark's rung for a frame of `side` points, never below 240: `isSharp` asks whether
  /// the station's own art is good enough, and a smaller rung would fail it for the rung's sake.
  static func markPixel(side: CGFloat) -> Int {
    max(rung(side: side), 240)
  }

  /// Big enough to stand for a station on a Home tile (150pt): at least 150 pixels on its short
  /// side. A smaller logo stretched up is a blur, so the station keeps its word art (I-V13).
  static func isSharp(_ image: UIImage) -> Bool {
    min(image.size.width, image.size.height) * image.scale >= 150
  }

  // MARK: References

  /// Remembers `ref` as the ladder copy of the picture at `address`.
  func register(_ address: String?, _ ref: CassetteImageRef?) {
    guard let address, !address.isEmpty, let ref, ref.url(rung: Self.rungs[0]) != nil else { return }
    refs[address] = ref
  }

  /// The plain-address field and the reference field the cloud sends beside it
  /// (apps/cassette/src/lib/radio/picture-refs.ts and the account route).
  private static let refFields = ["image": "imageRef", "coverUrl": "coverRef", "coverFullUrl": "coverFullRef"]

  /// Remembers every reference in a cloud answer, at any depth. Radio answers carry their
  /// pictures in many places; reading them here keeps every screen that shows one on the
  /// ladder without each one decoding the reference itself.
  func registerRefs(inJSON data: Data) {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { return }
    var pending: [Any] = [root]
    while let node = pending.popLast() {
      if let list = node as? [Any] {
        pending.append(contentsOf: list)
      } else if let object = node as? [String: Any] {
        for (field, refField) in Self.refFields {
          guard let address = object[field] as? String,
                let raw = object[refField] as? [String: Any],
                let src = raw["src"] as? String
          else { continue }
          register(address, CassetteImageRef(
            src: src, w: raw["w"] as? Int, h: raw["h"] as? Int, kind: raw["kind"] as? String
          ))
        }
        pending.append(contentsOf: object.values)
      }
    }
  }

  /// Where the picture is fetched from at `rung`: the ladder when the cloud sent a reference
  /// (never above the picture's own size), else its plain address.
  private func sources(for address: String, rung: Int) -> [URL] {
    var urls = [URL]()
    if let ref = refs[address] {
      let natural = [ref.w, ref.h].compactMap { $0 }.max()
      let capped = natural.map { min(rung, Self.rung(forPixels: $0)) } ?? rung
      if let ladder = ref.url(rung: capped).flatMap(URL.init(string:)) { urls.append(ladder) }
    }
    if let plain = URL(string: address), !urls.contains(plain) { urls.append(plain) }
    return urls
  }

  // MARK: Memory

  private static func key(_ address: String, _ rung: Int) -> NSString {
    "\(rung)|\(address)" as NSString
  }

  /// The picture when it is already in memory at `maxPixel`'s rung or larger, with no fetch: a
  /// rebuilt CarPlay row shows it at once instead of flashing the word picture first.
  func cachedImage(for address: String, maxPixel: Int = CassetteImageLoader.maxPixel) -> UIImage? {
    let rung = Self.rung(forPixels: maxPixel)
    for held in (rungsInMemory[address] ?? []).sorted() where held >= rung {
      if let hit = cache.object(forKey: Self.key(address, held)) { return hit }
    }
    return nil
  }

  /// Any size of the picture in memory, the largest first: what a bigger frame shows while its
  /// own size arrives, rather than an empty square.
  func anyCachedImage(for address: String) -> UIImage? {
    for held in (rungsInMemory[address] ?? []).sorted(by: >) {
      if let hit = cache.object(forKey: Self.key(address, held)) { return hit }
    }
    return nil
  }

  private func remember(_ image: UIImage, _ address: String, _ rung: Int) {
    let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    cache.setObject(image, forKey: Self.key(address, rung), cost: cost)
    rungsInMemory[address, default: []].insert(rung)
  }

  // MARK: Loading

  /// The picture at `address` for a frame needing `maxPixel` pixels, at that rung; one fetch
  /// per picture and rung at a time. `keep` writes it to disk and reads it from there first.
  func image(
    for address: String,
    maxPixel: Int = CassetteImageLoader.maxPixel,
    keep: Bool = false
  ) async -> UIImage? {
    let rung = Self.rung(forPixels: maxPixel)
    if let hit = cachedImage(for: address, maxPixel: rung) { return hit }
    let key = Self.key(address, rung) as String
    if let running = inFlight[key] { return await running.value }
    let urls = sources(for: address, rung: rung)
    guard !urls.isEmpty else { return nil }
    let file = keep ? Self.keptFile(address, rung) : nil
    let task = Task<UIImage?, Never> {
      if let file, let kept = await Self.decode(file: file, rung: rung) { return kept }
      for url in urls {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
          guard let image = Self.downsampled(data, maxPixel: rung) else { return nil }
          if let file { try? data.write(to: file, options: .atomic) }
          return image
        }.value
        if let image { return image }
      }
      // Offline with no copy of this size: any size kept earlier is better than nothing.
      if keep, let other = Self.anyKeptFile(address) { return await Self.decode(file: other, rung: rung) }
      return nil
    }
    inFlight[key] = task
    let image = await task.value
    inFlight[key] = nil
    if let image { remember(image, address, rung) }
    return image
  }

  /// The picture for a square frame of `side` points.
  func image(for address: String, side: CGFloat, keep: Bool = false) async -> UIImage? {
    await image(for: address, maxPixel: Self.rung(side: side), keep: keep)
  }

  /// Decoded now, not on the main thread at first draw, and never larger than it shows.
  nonisolated private static func downsampled(_ data: Data, maxPixel: Int) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return thumbnail(source, maxPixel: maxPixel)
  }

  nonisolated private static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> UIImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    return UIImage(cgImage: cgImage)
  }

  // MARK: Kept on disk

  /// Application Support, not Caches: the system clears Caches when space runs low, and these
  /// are the pictures a person expects to see offline.
  /// Signing out removes the folder (CassetteSyncAPI.forgetAccount), so it is made again here.
  nonisolated private static var keptFolder: URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    var dir = base.appendingPathComponent("cassette-pictures", isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? dir.setResourceValues(values)
    }
    return dir
  }

  nonisolated private static func keptName(_ address: String) -> String {
    SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated private static func keptFile(_ address: String, _ rung: Int) -> URL? {
    keptFolder?.appendingPathComponent("\(keptName(address))-\(rung)")
  }

  /// Any size of the picture kept on disk, the largest first.
  nonisolated private static func anyKeptFile(_ address: String) -> URL? {
    rungs.reversed().lazy.compactMap { keptFile(address, $0) }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  nonisolated private static func decode(file: URL, rung: Int) async -> UIImage? {
    await Task.detached(priority: .userInitiated) { () -> UIImage? in
      guard FileManager.default.fileExists(atPath: file.path),
            let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
      return thumbnail(source, maxPixel: rung)
    }.value
  }
}

// MARK: - The account photo

extension CassetteImageLoader {
  /// The account's photo for a frame of `side` points, from the ladder when the cloud sent its
  /// reference, kept on the phone so the avatar looks the same offline. Nil when there is none.
  func accountPhoto(side: CGFloat) async -> UIImage? {
    guard let address = CassetteSyncAPI.accountImage else { return nil }
    register(address, CassetteSyncAPI.accountImageRef)
    return await image(for: address, side: side, keep: true)
  }
}
