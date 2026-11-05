//
//  LibraryEntityImage.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 10.06.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import CoreData
import ImageIO
import UIKit

extension LibraryEntityImage {
  // Cache should not be used between different instances -> iOS and Carplay
  static public func getImageToDisplayImmediately(
    libraryEntity: AbstractLibraryEntity,
    themePreference: ThemePreference,
    artworkDisplayPreference: ArtworkDisplayPreference,
    useCache: Bool
  )
    -> UIImage {
    if let img = coverImage(
      libraryEntity: libraryEntity,
      artworkDisplayPreference: artworkDisplayPreference,
      useCache: useCache
    ) {
      return img
    }
    return UIImage.getGeneratedArtwork(
      theme: themePreference,
      artworkType: libraryEntity.getDefaultArtworkType(),
      name: (libraryEntity as? PlayableContainable)?.name
    )
  }

  /// The entity's real cover, or nil when it has none on disk. Callers that draw their own
  /// placeholder (CarPlay, which needs a legible one at the car's scale) use this instead of
  /// `getImageToDisplayImmediately`, which falls back to the phone's quiet ghost tile.
  static public func coverImage(
    libraryEntity: AbstractLibraryEntity,
    artworkDisplayPreference: ArtworkDisplayPreference,
    useCache: Bool
  )
    -> UIImage? {
    // cassette §art-collapse: resolve the album-level cover (the `setting` is
    // inert), prefer the small thumb tier, and decode it DOWNSAMPLED via ImageIO
    // — never the synchronous full-resolution decode this used to do on the main
    // thread (it fires on every track change via NowPlayingInfoCenterHandler).
    // Cache-first, so repeat calls are free.
    guard let fullPath = libraryEntity.imagePath(setting: artworkDisplayPreference) else {
      return nil
    }
    // The 480 rung, from the thumb: what callers that need a picture at once (the lock screen,
    // notifications, CarPlay) have always been given.
    let key = CoverImageStore.decodeKey(forFullPath: fullPath, rung: CoverImageStore.thumbMaxPixel)
    if useCache, let cachedImg = CoverBitmapCache.shared.image(for: key) {
      return cachedImg
    }
    guard let img = CoverImageStore.downsampledImage(atPath: key.path, maxPixel: key.maxPixel)
    else { return nil }
    CoverBitmapCache.shared.set(img, for: key)
    return img
  }
}

// MARK: - CoverDecodeKey

/// One decoded size of one cover file: the cache key and the unit a decode is shared on.
public struct CoverDecodeKey: Hashable, Sendable {
  public let path: String
  public let maxPixel: Int
}

// MARK: - CoverBitmapCache

/// cassette (BUG-816): the decoded covers, by file and size. Bounded by bytes (a 1200 hero is
/// about 6 MB, a 240 row about 0.2 MB) and emptied on a memory warning; it had no limit at all, so
/// scrolling a big library grew it until iOS stepped in.
@MainActor
public final class CoverBitmapCache {
  public static let shared = CoverBitmapCache()

  /// Holds a full screen of hero covers or a few screens of tiles and rows.
  static let byteLimit = 64 * 1024 * 1024

  private let cache = NSCache<NSString, UIImage>()
  /// The cached sizes of each file, so a re-downloaded cover drops all of them.
  private var keysByPath = [String: Set<CoverDecodeKey>]()
  private var memoryWarning: NSObjectProtocol?

  private init() {
    cache.totalCostLimit = Self.byteLimit
    memoryWarning = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated { CoverBitmapCache.shared.removeAll() }
    }
  }

  private static func name(_ key: CoverDecodeKey) -> NSString {
    "\(key.path)|\(key.maxPixel)" as NSString
  }

  func image(for key: CoverDecodeKey) -> UIImage? {
    cache.object(forKey: Self.name(key))
  }

  func set(_ image: UIImage, for key: CoverDecodeKey) {
    let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    cache.setObject(image, forKey: Self.name(key), cost: cost)
    keysByPath[key.path, default: []].insert(key)
  }

  /// Drop every size of the file at `path` (its bytes changed at the same path).
  func evict(path: String) {
    for key in keysByPath.removeValue(forKey: path) ?? [] {
      cache.removeObject(forKey: Self.name(key))
    }
    CoverDecoder.forget(path: path)
  }

  func removeAll() {
    cache.removeAllObjects()
    keysByPath.removeAll()
  }
}

// MARK: - CoverDecoder

/// cassette (BUG-816): one off-main decode per cover and size, shared by every view that asks
/// for it while it runs. A view that scrolls away leaves its decode; one nobody is waiting for
/// is cancelled before it starts, so a fast scroll no longer decodes every cover it passes.
@MainActor
enum CoverDecoder {
  @MainActor
  private final class Job {
    let task: Task<UIImage?, Never>
    var waiters = 0
    init(task: Task<UIImage?, Never>) { self.task = task }
  }

  private static var jobs = [CoverDecodeKey: Job]()

  /// Join the decode for `key`, starting it if nothing is running. Pair with `leave`.
  static func enter(_ key: CoverDecodeKey) {
    if let job = jobs[key], !job.task.isCancelled {
      job.waiters += 1
      return
    }
    let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
      guard !Task.isCancelled else { return nil }
      return CoverImageStore.downsampledImage(atPath: key.path, maxPixel: key.maxPixel)
    }
    let job = Job(task: task)
    job.waiters = 1
    jobs[key] = job
    // A decode that had already started when its last view left still lands in the cache, so
    // scrolling back shows it at once; one cancelled before it started returns nil and is dropped.
    Task { @MainActor in
      finish(job, key: key, image: await task.value)
    }
  }

  static func leave(_ key: CoverDecodeKey) {
    guard let job = jobs[key] else { return }
    job.waiters -= 1
    if job.waiters <= 0 { job.task.cancel() }
  }

  /// The decoded cover for `key`: the cache, else the running decode's result.
  static func image(for key: CoverDecodeKey) async -> UIImage? {
    if let hit = CoverBitmapCache.shared.image(for: key) { return hit }
    guard let job = jobs[key] else { return nil }
    let image = await job.task.value
    finish(job, key: key, image: image)
    return image
  }

  /// A file's bytes changed: a decode already reading the old ones must not cache them.
  static func forget(path: String) {
    for key in jobs.keys where key.path == path {
      jobs[key] = nil
    }
  }

  private static func finish(_ job: Job, key: CoverDecodeKey, image: UIImage?) {
    guard jobs[key] === job else { return }
    jobs[key] = nil
    if let image { CoverBitmapCache.shared.set(image, for: key) }
  }
}

// MARK: - LibraryEntityImage

@MainActor
public class LibraryEntityImage: RoundedImage {
  /// Drop the cached bitmap(s) for a cover whose bytes changed on disk (every size of
  /// both the full and thumb tiers). The cache is keyed by tier source PATH, and a
  /// re-download overwrites at the SAME path — so without this the stale image survives
  /// until the app restarts. Also called directly by the Cassette folder-cover refresh,
  /// where every other invalidation hook keys on path or entity identity and so sees
  /// nothing change.
  static func evictCache(forFullPath fullPath: String) {
    CoverBitmapCache.shared.evict(path: fullPath)
    CoverBitmapCache.shared.evict(path: CoverImageStore.thumbPath(forFullPath: fullPath))
  }

  private let appDelegate: AmperKit

  private var entity: AbstractLibraryEntity?
  private var backupArtworkType: ArtworkType?
  private var accountNotificationHandler: AccountNotificationHandler?
  // The decode (file and size) currently in `image`, so a layout pass that doesn't
  // change the size doesn't trigger a redundant decode.
  private var shownKey: CoverDecodeKey?
  // The decode this view is waiting for, its request and the task awaiting it.
  private var pendingKey: CoverDecodeKey?
  private var pendingToken: UUID?
  private var loadTask: Task<(), Never>?
  // A decode that found nothing (a missing or broken file), not retried on every layout pass.
  private var failedKey: CoverDecodeKey?
  // cassette (BUG-816): set by display(entity:) until the next layout pass. Until then
  // the bounds are the nib's design size (291pt in EntityImageView.xib) or zero, both of
  // which read as a hero, so a fresh cell decoded the full cover before its real size
  // was known and then the thumb again. The cache can still answer before layout.
  private var awaitingLayout = false

  required public init?(coder: NSCoder) {
    self.appDelegate = AmperKit.shared
    super.init(coder: coder)
    // cassette §art-collapse: one contentMode for every cover. With square
    // sources aspectFill never crops; this fixes the mini-player stretch
    // (UIImageView's scaleToFill default) and fills the now-playing hero, in one
    // place instead of the old per-surface aspectFill/aspectFit/scaleToFill mix.
    contentMode = .scaleAspectFill
    self.accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).artworkDownloadManager
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).playableDownloadManager
      )
    }
  }

  override public init(frame: CGRect) {
    self.appDelegate = AmperKit.shared
    super.init(frame: .zero)
    contentMode = .scaleAspectFill
    self.accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).artworkDownloadManager
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).playableDownloadManager
      )
    }
  }

  public func display(entity: AbstractLibraryEntity) {
    // A reused cell stops waiting for the cover it showed last.
    cancelLoad()
    self.entity = entity
    backupArtworkType = entity.getDefaultArtworkType()
    shownKey = nil
    failedKey = nil
    awaitingLayout = true
    setNeedsLayout()
    refresh()
  }

  public func displayAndUpdate(entity: AbstractLibraryEntity) {
    guard self.entity != entity else { return }

    display(entity: entity)
    if let artwork = entity.artwork, let accountInfo = entity.account?.info {
      appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: artwork)
    }
  }

  public func display(image: UIImage) {
    cancelLoad()
    self.image = image
    entity = nil
    shownKey = nil
    awaitingLayout = false
  }

  public func display(artworkType: ArtworkType) {
    cancelLoad()
    backupArtworkType = artworkType
    entity = nil
    shownKey = nil
    awaitingLayout = false
    refresh()
  }

  private var placeholderImage: UIImage {
    var theme = appDelegate.storage.settings.accounts.activeSetting.read.themePreference
    if let accountInfo = entity?.account?.info {
      theme = appDelegate.storage.settings.accounts.getSetting(accountInfo).read.themePreference
    }
    // cassette (BUG-817): drawn at the size it shows, not 300pt (900px, about 3.2 MB) in
    // every row. Before layout the size is unknown, so the smallest stands in.
    let points = awaitingLayout ? 0 : max(bounds.width, bounds.height)
    let side = CoverImageStore.placeholderSide(forPoints: points)
    return UIImage.getGeneratedArtwork(
      theme: theme,
      artworkType: backupArtworkType ?? .song,
      name: (entity as? PlayableContainable)?.name,
      size: CGSize(width: side, height: side)
    )
  }

  /// The album-level cover path for the current entity (the `setting` is inert
  /// after the art-collapse — every playable resolves to its album cover).
  private var entityImagePathToDisplay: String? {
    let setting = appDelegate.storage.settings.accounts.activeSetting.read.artworkDisplayPreference
    return entity?.imagePath(setting: setting)
  }

  /// `keepCurrentImageWhileLoading` suppresses the placeholder swap while we
  /// re-decode NEW bytes for the SAME entity that already has a valid image on
  /// screen — a cover re-check or pick overwrite. Without it every cover the sync
  /// pass re-checks briefly flashes the gray placeholder before the (usually
  /// identical) new bytes land, which is the "covers flash while it checks them"
  /// blink. A fresh entity or a reused cell still shows the placeholder, because
  /// there `shownKey` is nil AND this stays false (see the call sites).
  private func refresh(keepCurrentImageWhileLoading: Bool = false) {
    guard let fullPath = entityImagePathToDisplay else {
      cancelLoad()
      image = placeholderImage
      shownKey = nil
      return
    }
    // The decode this view's size calls for: its ladder rung at the screen's scale, from the
    // thumb up to 480, the full cover above. Driven by the bounds, so it settles after layout.
    let points = max(bounds.width, bounds.height)
    let key = CoverImageStore.decodeKey(
      forFullPath: fullPath,
      size: bounds.size,
      scale: traitCollection.displayScale,
      aspect: entity is Artist
        ? CassetteKitTokens.Images.assumedPhotoAspect
        : CassetteKitTokens.Images.assumedCoverAspect
    )

    // Already showing that size — nothing to do (avoids redundant decodes on every
    // layout pass).
    if key == shownKey, image != nil {
      return
    }

    if let cachedImg = CoverBitmapCache.shared.image(for: key) {
      cancelLoad()
      image = cachedImg
      shownKey = key
      return
    }

    if shownKey == nil, !keepCurrentImageWhileLoading {
      image = placeholderImage
    }
    // No decode until the real size is known (layoutSubviews clears this), and none twice.
    guard !awaitingLayout, points > 1, key != pendingKey, key != failedKey else { return }
    load(key)
  }

  /// Off-main, size-bounded ImageIO decode, shared with any other view showing the same
  /// cover at the same size — a 48pt row never holds a 480px bitmap, and there is no
  /// synchronous main-thread decode.
  private func load(_ key: CoverDecodeKey) {
    cancelLoad()
    let token = UUID()
    pendingKey = key
    pendingToken = token
    CoverDecoder.enter(key)
    loadTask = Task { [weak self] in
      let decoded = await CoverDecoder.image(for: key)
      guard let self, pendingToken == token else { return }
      CoverDecoder.leave(key)
      pendingKey = nil
      pendingToken = nil
      loadTask = nil
      // Re-evaluate against the current size (bounds may have changed) and show.
      if decoded != nil { refresh() } else { failedKey = key }
    }
  }

  /// Leave the decode this view was waiting for (a reused cell, a new entity).
  private func cancelLoad() {
    if let pendingKey { CoverDecoder.leave(pendingKey) }
    pendingKey = nil
    pendingToken = nil
    loadTask?.cancel()
    loadTask = nil
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    // Bounds are valid here — pick the size (e.g. a hero upgrading from a cached
    // thumb to the full cover). refresh() no-ops when the size is stable.
    if entity != nil {
      awaitingLayout = false
      refresh()
    }
  }

  @objc
  private func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification), let entity
    else { return }
    let matchesPlayable = (entity as? AbstractPlayable)?.uniqueID == downloadNotification.id
    let matchesArtwork = entity.artwork?.uniqueID == downloadNotification.id
    // cassette: a song shows its ALBUM's cover (AbstractPlayable.imagePath is
    // album-first), and the album artwork is a DISTINCT Core Data row from the
    // song's own — so an owned-album cover backfill completing carries the album
    // artwork id, which the two ids above both miss, and the now-playing hero /
    // any song cell stays on the gray placeholder until the next track change or a
    // layout pass. Match the album artwork id too. Mirrors the C09 patch already in
    // NowPlayingInfoCenterHandler (lock screen); this is the same fix for the in-app view.
    let matchesAlbumArtwork =
      (entity as? AbstractPlayable)?.asSong?.album?.artwork?.uniqueID == downloadNotification.id
    guard matchesPlayable || matchesArtwork || matchesAlbumArtwork else { return }
    Task { @MainActor in
      // The cover (and its thumb) now exist — or its bytes CHANGED (a pick
      // re-download overwrites at the same path). Drop the stale cache first so
      // refresh() re-decodes the new file instead of serving the old bitmap, then
      // re-resolve the tier and load it. Keep whatever is already on screen up
      // until the new bytes are decoded (keepCurrentImageWhileLoading) — a re-check
      // that lands the same or a better cover must never blink through the gray
      // placeholder first.
      if let fullPath = self.entityImagePathToDisplay {
        Self.evictCache(forFullPath: fullPath)
      }
      self.cancelLoad()
      self.shownKey = nil
      self.failedKey = nil
      self.refresh(keepCurrentImageWhileLoading: true)
    }
  }
}

// MARK: - CoverImageStore

/// cassette §art-collapse: the two-tier, square, off-main cover machinery shared
/// by ingestion (the native getCoverArt path via SubsonicArtworkDownloadDelegate)
/// and display (LibraryEntityImage). One album-level cover per album, stored as
/// a capped full file plus a ~480px square thumb beside it (`<id>_thumb.<ext>`),
/// decoded at the size the view actually needs.
public enum CoverImageStore {
  /// The image ladder's top rung, 1200 (docs/reference/CASSETTE_IMAGES.md; the rungs come from
  /// packages/cassette-kit tokens.json through CassetteKitTokens). The size every cover is asked
  /// from the hub at and the largest any surface decodes. Covers pulled before 2026-11-04 were
  /// asked at 1000 and stay as they are.
  public static let topRung = CassetteKitTokens.Images
    .rungs[CassetteKitTokens.Images.rungs.count - 1]
  /// Thumb tier longest side, the 480 rung: written beside each full cover, and read for every
  /// surface whose rung is 480 or smaller (rows and small tiles), so they never open the full file.
  public static let thumbMaxPixel = 480
  /// Placeholder sizes only (placeholderSide); covers are sized by the ladder.
  public static let smallSurfaceMaxPt: CGFloat = 200
  public static let rowSurfaceMaxPt: CGFloat = 80

  /// What a surface of `size` points at `scale` decodes: its ladder rung (decodePixels), read
  /// from the thumb (when one exists) for rungs it holds, else from the full cover.
  public static func decodeKey(
    forFullPath full: String,
    size: CGSize,
    scale: CGFloat,
    aspect: Double = CassetteKitTokens.Images.assumedCoverAspect
  )
    -> CoverDecodeKey {
    decodeKey(forFullPath: full, rung: decodePixels(for: size, scale: scale, aspect: aspect))
  }

  /// The decode for a rung already chosen: the thumb serves 480 and below.
  public static func decodeKey(forFullPath full: String, rung: Int) -> CoverDecodeKey {
    CoverDecodeKey(
      path: preferredSourcePath(forFullPath: full, smallSurface: rung <= thumbMaxPixel),
      maxPixel: rung
    )
  }

  /// The ladder rung for a surface of `size` points at `scale`, showing a picture of `aspect`
  /// cropped to fill: the kit's one pick rule, so a 48pt row at 3x reads 240 and a 360pt hero
  /// 1200, and the same row on a 2x screen 120. An unknown size (not laid out) is the top rung,
  /// so callers wait for layout rather than decode it; an unknown scale counts as 3x.
  public static func decodePixels(
    for size: CGSize,
    scale: CGFloat,
    aspect: Double = CassetteKitTokens.Images.assumedCoverAspect
  )
    -> Int {
    guard size.width > 1, size.height > 1 else { return topRung }
    return CassetteKitTokens.Images.pickRung(
      w: Double(size.width),
      h: Double(size.height),
      scale: Double(scale > 0 ? scale : 3),
      aspect: aspect
    )
  }

  /// cassette (BUG-817): the side, in points, to draw a "no cover" placeholder for a surface
  /// whose longest side is `points` (0 when not laid out yet): row, tile or hero.
  public static func placeholderSide(forPoints points: CGFloat) -> CGFloat {
    if points <= rowSurfaceMaxPt { return rowSurfaceMaxPt }
    if points <= smallSurfaceMaxPt { return 160 }
    return 300
  }

  /// Thumb path for a full cover path: `…/al-x.png` → `…/al-x_thumb.png`.
  public static func thumbPath(forFullPath full: String) -> String {
    let ns = full as NSString
    let ext = ns.pathExtension
    let base = ns.deletingPathExtension
    return ext.isEmpty ? base + "_thumb" : base + "_thumb." + ext
  }

  /// Whether `path` already names a thumb file.
  public static func isThumbPath(_ path: String) -> Bool {
    ((path as NSString).deletingPathExtension as NSString).lastPathComponent.hasSuffix("_thumb")
  }

  /// The path to decode for a surface: the thumb (when small and present), else
  /// the full cover.
  public static func preferredSourcePath(forFullPath full: String, smallSurface: Bool) -> String {
    guard smallSurface else { return full }
    let tp = thumbPath(forFullPath: full)
    return FileManager.default.fileExists(atPath: tp) ? tp : full
  }

  /// Off-disk ImageIO decode, downsampled so the longest side ≈ maxPixel.
  /// Bounded cost regardless of the source's real dimensions; safe to call off
  /// the main thread.
  public static func downsampledImage(atPath path: String, maxPixel: Int) -> UIImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
    else { return nil }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    else { return nil }
    // cassette §art-collapse: normalize to sRGB. ImageIO returns the source's
    // own colour space, so a CMYK or exotic-profile JPEG (common in commercial
    // CD cover art) comes back non-RGB and renders as a solid BLACK square once
    // wrapped in a UIImage and drawn through an opaque context. Redrawing into an
    // sRGB bitmap forces the conversion, so every cover decodes to true colour on
    // every surface. (UIImage(contentsOfFile:) used to hide this; the tiered
    // ImageIO path does not.) An 8-bit RGB decode, nearly every cover, draws right as
    // it is, so it skips the second bitmap and the redraw (BUG-816).
    if isPlainRGB(cg) { return UIImage(cgImage: cg) }
    return normalizedSRGBImage(cg) ?? UIImage(cgImage: cg)
  }

  /// 8 bits per channel, 32 bits per pixel, in an RGB colour space: what UIKit draws as is.
  private static func isPlainRGB(_ cg: CGImage) -> Bool {
    cg.colorSpace?.model == .rgb && cg.bitsPerComponent == 8 && cg.bitsPerPixel == 32
  }

  /// Redraw a CGImage into an 8-bit sRGB bitmap so non-RGB sources (CMYK,
  /// grayscale, wide-gamut, odd ICC profiles) become standard sRGB. Returns nil
  /// only when the context can't be created (the caller then falls back to the
  /// raw image rather than showing nothing).
  private static func normalizedSRGBImage(_ cg: CGImage) -> UIImage? {
    let width = cg.width
    let height = cg.height
    guard width > 0, height > 0 else { return nil }
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue
    guard let ctx = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: space,
      bitmapInfo: bitmapInfo
    ) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let normalized = ctx.makeImage() else { return nil }
    return UIImage(cgImage: normalized)
  }

  /// Longest-side cap for the decodability probe below. An unbounded full decode
  /// (`CGImageSourceCreateImageAtIndex(src, 0, nil)`) allocates the source's
  /// entire bitmap — a 6000² cover ≈ 144MB RGBA — which can be jettisoned under
  /// memory pressure and is exactly what dropped oversized covers on the phone.
  /// Probing with a bounded thumbnail proves the bytes decode at a fraction of
  /// the cost, so an oversized/hostile cover can never take the accept path down
  /// regardless of what the server sends.
  public static let decodeProbeMaxPixel = 2048

  /// Whether `src` decodes to a real image WITHOUT ever allocating the full-
  /// resolution bitmap. `kCGImageSourceCreateThumbnailFromImageAlways` forces a
  /// genuine decode (so truncated/corrupt data is still rejected), bounded to
  /// `decodeProbeMaxPixel`.
  private static func sourceDecodes(_ src: CGImageSource) -> Bool {
    guard CGImageSourceGetCount(src) > 0 else { return false }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: decodeProbeMaxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) != nil
  }

  /// Whether raw bytes decode to an image. Forces an actual (bounded) decode, not
  /// just a header read, so truncated/corrupt data is rejected. Used to gate
  /// every cover write — a download that doesn't decode must never overwrite a
  /// good cover (Rule 1) and falls to the placeholder, never a broken file (§5).
  public static func isDecodable(_ data: Data) -> Bool {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    return sourceDecodes(src)
  }

  /// Whether the file at `url` decodes to an image (forces a bounded real decode).
  public static func isDecodable(fileURL url: URL) -> Bool {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    return sourceDecodes(src)
  }

  /// Pixel dimensions of an image file via ImageIO (header only — no decode).
  public static func pixelSize(atPath path: String) -> (width: Int, height: Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (w, h)
  }

  /// Ingest a freshly-stored full cover: write the ~480px thumb beside it, at the
  /// source's NATIVE aspect. Best-effort — failures leave the full cover usable on
  /// its own. Safe to call off the main thread.
  ///
  /// Nothing is padded to a square. We never bake bars into a stored image: album
  /// covers are square already, and an artist photo is a portrait/landscape press
  /// shot that would bar-out if squared. Every frame crops to fill (`.scaleAspectFill`
  /// / the web's `object-fit: cover`), so native aspect is exactly what fills, and a
  /// bar the crop can't remove is never created. The sidecar makes the same choice
  /// (normalizeCover, native ratio) for the files it materializes.
  public static func processStoredCover(fullFileURL: URL) {
    let fullPath = fullFileURL.path
    // Thumb tier — native aspect, capped. No square-pad, ever.
    if let thumbSrc = downsampledImage(atPath: fullPath, maxPixel: thumbMaxPixel) {
      if let data = thumbSrc.jpegData(compressionQuality: 0.85) {
        try? data.write(to: URL(fileURLWithPath: thumbPath(forFullPath: fullPath)))
      }
    }
  }

  /// Generate the thumb tier for an existing full cover only when it's missing.
  /// Cheap + idempotent (a single fileExists check when the thumb is present),
  /// so the re-tier backfill is safe to run on every sync. Safe off-main.
  public static func ensureThumb(forFullPath fullPath: String) {
    if FileManager.default.fileExists(atPath: thumbPath(forFullPath: fullPath)) { return }
    processStoredCover(fullFileURL: URL(fileURLWithPath: fullPath))
  }
}
