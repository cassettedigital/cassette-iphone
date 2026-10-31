//
//  MoodDoorRow.swift
//  Amperfy
//
//  Cassette: the Home "PLAYLISTS made for you" row (was the "Mood" shelf).
//
//  cassette 2026-10-20: the first tile is "Lately", a mix of songs on this phone that
//  match the mood of what the person has been playing (ListeningShelves).
//
//  phone-taste (approved phone mock, 2026-10-20): the row reads like every other Home row
//  (the shout, the shelf's 20pt gutter and 12pt gap, 150pt square tiles).
//
//  Founder, 2026-10-21: the row says what it is (PLAYLISTS *made for you*), and each tile
//  gets the album treatment: the picture, the one-tap play disc, and the name and song count
//  under it rather than on it. A tap on the picture opens the playlist's page (what's
//  inside); the disc plays it. Beside Lately sit the other made-for-you playlists (this
//  part of the day, Been a While, the mood mixes), all drawn on the phone by HomeManager.
//  The server's mood doors no longer show here: the mood mixes replace them on the phone.
//  The row never builds a mix itself; it draws and plays the ones HomeManager keeps,
//  re-checked against the phone at the tap.
//

import AmperfyKit
import CryptoKit
import SwiftUI
import UIKit

// MARK: - MoodDoorRow

struct MoodDoorRow: View {
  /// HomeManager's made-for-you playlists, in row order. Empty: the row is not shown.
  let mixes: [HomeManager.MadeForYouMix]
  /// The row's name in two voices (One Home: the cloud's, "PLAYLISTS made for you").
  var shout = "PLAYLISTS"
  var answer: String? = "made for you"
  /// Opens a playlist's page.
  let onOpen: (HomeManager.MadeForYouMix) -> ()

  /// The mock's `.shelf` gap.
  private static let tileSpacing: CGFloat = 12

  var body: some View {
    VStack(alignment: .leading, spacing: CassetteHeading.bottomSpacing) {
      // The same two-voice heading, gutter and air as the UIKit rows around it.
      CassetteHeadingText(shout: shout, answer: answer)
        .padding(.horizontal, CassetteHeading.sideInset)
        .padding(.top, CassetteHeading.topSpacing)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: Self.tileSpacing) {
          ForEach(mixes, id: \.id) { mix in
            MadeForYouTile(
              mix: mix,
              coverPaths: Self.coverPaths(of: mix),
              open: { onOpen(mix) },
              play: { Self.play(mix) }
            )
          }
        }
        .padding(.horizontal, AlbumCarousel.mockGutter)
      }
    }
    // The cover shelves' bottom inset (the next row's heading brings its own 28pt).
    .padding(.bottom, 2)
  }

  /// The app delegate, for these static helpers (`appDelegate` is an instance property).
  private static var app: AppDelegate {
    UIApplication.shared.delegate as! AppDelegate
  }

  /// The playlist's lead albums' covers that are on disk, in mix order.
  static func coverPaths(of mix: HomeManager.MadeForYouMix) -> [String] {
    let settings = app.storage.settings.accounts
    var seen = Set<String>()
    return mix.leadAlbums.compactMap { album -> String? in
      let preference = settings.getSetting(album.account?.info).read.artworkDisplayPreference
      guard let path = album.imagePath(setting: preference),
            FileManager.default.fileExists(atPath: path),
            seen.insert(path).inserted
      else { return nil }
      return path
    }
  }

  /// Plays the playlist the tile shows, checked against the phone at the tap (HomeManager
  /// keeps it between recomputes, and music can leave the phone in between), by
  /// OneTapPlay's rule.
  static func play(_ mix: HomeManager.MadeForYouMix) {
    let songs = OneTapPlay.playables(mix.songs)
    guard !songs.isEmpty else { return }
    app.player.play(context: PlayContext(name: mix.title, playables: songs))
    Haptics.light.vibrate(isHapticsEnabled: app.storage.settings.user.isHapticsEnabled)
  }
}

// MARK: - MadeForYouTile

/// One made-for-you playlist, as an album tile: a 150pt square picture with the one-tap
/// play disc at its bottom-right, then the name and the song count. The picture is four of
/// its records (Lately, the time of day, Been a While) or the mood's own art (a mood mix).
/// A tap on the picture opens the playlist; the disc plays it. The disc is a sibling of the
/// picture's button, never inside it (in SwiftUI the outer button's tap would win).
struct MadeForYouTile: View {
  static let side: CGFloat = MoodDoorTile.side

  let mix: HomeManager.MadeForYouMix
  let coverPaths: [String]
  let open: () -> ()
  let play: () -> ()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .bottomTrailing) {
        Button(action: open) {
          MadeForYouArt(mix: mix, coverPaths: coverPaths, side: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: CassetteRadius.artworkTile))
            .contentShape(RoundedRectangle(cornerRadius: CassetteRadius.artworkTile))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mix.title)
        .accessibilityHint("Opens the playlist")

        CassettePlayDisc(action: play)
          .padding(8)
      }
      .frame(width: Self.side, height: Self.side)

      Button(action: open) {
        VStack(alignment: .leading, spacing: 2) {
          Text(mix.title)
            .font(Font.cassette(.rowTitle))
            .foregroundStyle(Color.cassette(.textPrimary))
            .lineLimit(1)
          Text(mix.songs.count == 1 ? "1 song" : "\(mix.songs.count) songs")
            .font(Font.cassette(.cardSubtitle))
            .foregroundStyle(Color.cassette(.textSecondary))
            .lineLimit(1)
        }
        .padding(.top, 6)
        .frame(width: Self.side, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHidden(true)
    }
    .frame(width: Self.side, alignment: .leading)
  }
}

// MARK: - MadeForYouArt

/// A made-for-you playlist's picture at `side`: a 2x2 of covers from it (repeated when it
/// has fewer than four, the ring art when none is on disk yet), or, for a mood mix, its drawn
/// cover (`MixCoverArt`, the mood's colour and shape until it lands). No words added on it:
/// the name sits underneath (a drawn cover carries its own title).
struct MadeForYouArt: View {
  let mix: HomeManager.MadeForYouMix
  let coverPaths: [String]
  let side: CGFloat

  var body: some View {
    Group {
      if case let .mood(key, hexColor) = mix.kind {
        MixCoverArt(address: MixCoverCache.address(for: mix), key: key, hexColor: hexColor)
      } else if coverPaths.isEmpty {
        MoodMixArt(key: "lately", hexColor: "#B07AA1")
      } else {
        mosaic
      }
    }
    .frame(width: side, height: side)
  }

  /// Four slots, filled in mix order and repeated to make four.
  private var mosaic: some View {
    let slots = (0 ..< 4).map { coverPaths[$0 % coverPaths.count] }
    let half = side / 2
    return VStack(spacing: 0) {
      HStack(spacing: 0) {
        LatelyCover(path: slots[0], side: half)
        LatelyCover(path: slots[1], side: half)
      }
      HStack(spacing: 0) {
        LatelyCover(path: slots[2], side: half)
        LatelyCover(path: slots[3], side: half)
      }
    }
  }
}

// MARK: - MoodMixArt

/// A mood mix's picture: the door's colour washing in from the top-left and its shape
/// (MoodDoors.swift), with no label. Fills its frame.
struct MoodMixArt: View {
  let key: String
  let hexColor: String

  var body: some View {
    let color = Color(hexString: hexColor) ?? Color.cassette(.textSecondary)
    let shape = MoodDoors.all.first(where: { $0.key == key })?.shape ?? .concentricRings
    return ZStack {
      Color.cassette(.surfaceElevated)
      LinearGradient(
        stops: [
          .init(color: color.opacity(0.45), location: 0),
          .init(color: .clear, location: 0.75),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      MoodDoorArt(shape: shape, color: color)
    }
  }
}

// MARK: - MixCoverArt

/// A mood mix's drawn cover (`MixCoverCache`), fading in over the mood's own art
/// (`MoodMixArt`), which shows while it loads, offline, or if it never comes. Fills its frame.
struct MixCoverArt: View {
  let address: URL?
  let key: String
  let hexColor: String

  @State
  private var image: UIImage?

  init(address: URL?, key: String, hexColor: String) {
    self.address = address
    self.key = key
    self.hexColor = hexColor
    _image = State(initialValue: address.flatMap { MixCoverCache.cached($0) })
  }

  var body: some View {
    ZStack {
      MoodMixArt(key: key, hexColor: hexColor)
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .transition(.opacity)
      }
    }
    .clipped()
    .accessibilityHidden(true)
    .task(id: address) {
      guard image == nil, let address else { return }
      if let loaded = await MixCoverCache.load(address) {
        withAnimation(.easeIn(duration: 0.3)) { image = loaded }
      }
    }
  }
}

// MARK: - MixCoverCache

/// The mood mixes' drawn covers, which cassette.digital draws (/api/covers/mix/{key}): one
/// 900px JPEG per address, saved under Caches so CarPlay and an offline launch read it from
/// disk, decoded once into memory. An address is fetched once per process; a failure backs
/// off (a minute, doubling to an hour) rather than retrying; a copy older than a week is
/// shown while a fresh one is fetched behind it. Five covers a day at most.
@MainActor
enum MixCoverCache {
  /// One size serves the Home tile, the mix page (240pt at 3x) and CarPlay.
  static let pixelSize = 900
  private static let freshFor: TimeInterval = 7 * 86400

  private static var base: String {
    #if DEBUG
      // A debug build can read a local web server before the route ships:
      // SIMCTL_CHILD_CASSETTE_COVER_BASE=http://localhost:3300 xcrun simctl launch …
      if let base = ProcessInfo.processInfo.environment["CASSETTE_COVER_BASE"], !base.isEmpty {
        return base
      }
    #endif
    return "https://cassette.digital"
  }

  private static let memory = NSCache<NSString, UIImage>()
  private static var inFlight = [String: Task<UIImage?, Never>]()
  private static var failures = [String: (count: Int, at: Date)]()

  /// A mood mix's cover address, or nil for the other playlists (or a mix built before it
  /// had a cover version).
  static func address(for mix: HomeManager.MadeForYouMix) -> URL? {
    guard case let .mood(key, _) = mix.kind, let variant = mix.coverVariant else { return nil }
    return address(key: key, variant: variant)
  }

  /// A mood mix's cover address by its key and the day's variant (Put something on's Focus
  /// and Wind down tiles are those mixes).
  static func address(key: String, variant: String) -> URL? {
    URL(string: "\(base)/api/covers/mix/\(key)?variant=\(variant)&s=\(pixelSize)")
  }

  /// The cover already decoded in memory.
  static func cached(_ address: URL) -> UIImage? {
    memory.object(forKey: address.absoluteString as NSString)
  }

  /// Whether the cover is on disk (CarPlay draws only what is).
  static func isOnDisk(_ address: URL) -> Bool {
    guard let file = fileURL(for: address) else { return false }
    return FileManager.default.fileExists(atPath: file.path)
  }

  /// The cover from disk, decoded now at `maxPixelSize`, for a surface that needs a picture
  /// up front (CarPlay). Never touches the network.
  static func diskImage(_ address: URL, maxPixelSize: Int) -> UIImage? {
    guard let file = fileURL(for: address), FileManager.default.fileExists(atPath: file.path) else {
      return nil
    }
    return AmbientSourceDecoder.thumbnail(contentsOfFile: file.path, maxPixelSize: maxPixelSize)
  }

  /// The cover: from memory, else from disk (a stale copy also fetches a fresh one behind
  /// it), else fetched. Nil while offline or after a failure.
  static func load(_ address: URL) async -> UIImage? {
    if let hit = cached(address) { return hit }
    if let file = fileURL(for: address), FileManager.default.fileExists(atPath: file.path) {
      let path = file.path
      let size = pixelSize
      let image = await Task.detached(priority: .utility) {
        AmbientSourceDecoder.thumbnail(contentsOfFile: path, maxPixelSize: size)
      }.value
      if let image {
        memory.setObject(image, forKey: address.absoluteString as NSString)
        if isStale(file) { Task { _ = await fetch(address) } }
        return image
      }
    }
    return await fetch(address)
  }

  /// Fetches every cover in `addresses` not on disk yet (or gone stale), and calls `landed`
  /// once for each that arrives.
  static func prefetch(_ addresses: [URL], landed: @escaping @MainActor () -> ()) {
    for address in addresses {
      if let file = fileURL(for: address), FileManager.default.fileExists(atPath: file.path),
         !isStale(file) {
        continue
      }
      guard inFlight[address.absoluteString] == nil, !isBackingOff(address) else { continue }
      Task {
        if await fetch(address) != nil { landed() }
      }
    }
  }

  /// One download per address at a time, saved to disk and decoded.
  private static func fetch(_ address: URL) async -> UIImage? {
    let key = address.absoluteString
    if let running = inFlight[key] { return await running.value }
    guard !isBackingOff(address), let file = fileURL(for: address) else { return nil }
    let task = Task<UIImage?, Never> {
      do {
        let (data, response) = try await URLSession.shared.data(from: address)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let path = file.path
        let size = pixelSize
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
          do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
          } catch {
            return nil
          }
          return AmbientSourceDecoder.thumbnail(contentsOfFile: path, maxPixelSize: size)
        }.value
        return image
      } catch {
        return nil
      }
    }
    inFlight[key] = task
    let image = await task.value
    inFlight[key] = nil
    if let image {
      failures[key] = nil
      memory.setObject(image, forKey: key as NSString)
    } else {
      failures[key] = ((failures[key]?.count ?? 0) + 1, Date())
    }
    return image
  }

  private static func isBackingOff(_ address: URL) -> Bool {
    guard let failure = failures[address.absoluteString] else { return false }
    let wait = min(3600, 60 * pow(2, Double(failure.count - 1)))
    return Date().timeIntervalSince(failure.at) < wait
  }

  private static func isStale(_ file: URL) -> Bool {
    guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate]
      as? Date
    else { return false }
    return Date().timeIntervalSince(modified) > freshFor
  }

  private static func fileURL(for address: URL) -> URL? {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return nil
    }
    let dir = caches.appendingPathComponent("cassette-mix-covers", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let digest = SHA256.hash(data: Data(address.absoluteString.utf8))
    let name = digest.map { String(format: "%02x", $0) }.joined()
    return dir.appendingPathComponent(name + ".jpg")
  }
}

// MARK: - LatelyCover

/// One square of a mosaic: the cover decoded small off the main thread, from the cache
/// when it has been decoded before. bg3 until it lands.
struct LatelyCover: View {
  let path: String
  let side: CGFloat

  @State
  private var image: UIImage?

  init(path: String, side: CGFloat) {
    self.path = path
    self.side = side
    _image = State(initialValue: LatelyCoverCache.cached(path))
  }

  var body: some View {
    ZStack {
      Color.cassette(.surfaceElevated)
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      }
    }
    .frame(width: side, height: side)
    .clipped()
    .accessibilityHidden(true)
    .task(id: path) {
      guard image == nil else { return }
      image = await LatelyCoverCache.load(path)
    }
  }
}

// MARK: - LatelyCoverCache

/// Mosaic covers, decoded once at 360px off the main thread and kept by path. Static,
/// because Home re-hosts this row on every configure, which resets any @State.
@MainActor
enum LatelyCoverCache {
  private static let cache = NSCache<NSString, UIImage>()

  static func cached(_ path: String) -> UIImage? {
    cache.object(forKey: path as NSString)
  }

  static func load(_ path: String) async -> UIImage? {
    if let hit = cached(path) { return hit }
    let image = await Task.detached(priority: .utility) {
      AmbientSourceDecoder.thumbnail(contentsOfFile: path, maxPixelSize: 360)
    }.value
    if let image {
      cache.setObject(image, forKey: path as NSString)
    }
    return image
  }
}

// MARK: - MadeForYouList

/// cassette 2026-10-31 (the founder: "They're playlists, they're just generated rather than
/// curated"): the made-for-you playlists under the person's own in Library > Playlists, one row
/// each in the playlist rows' shape (picture, name, songs and length), a tap opening the page
/// Home's tile opens.
struct MadeForYouList: View {
  let mixes: [HomeManager.MadeForYouMix]
  let onOpen: (HomeManager.MadeForYouMix) -> ()

  /// The playlist rows' picture and row (PlaylistTableCell: 70pt and its margins).
  static let artSide: CGFloat = 70
  static let rowHeight: CGFloat = 86

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      CassetteHeadingText(shout: "MADE FOR YOU", answer: nil)
        .padding(.horizontal, CassetteHeading.sideInset)
        .padding(.top, CassetteHeading.topSpacing)
        .padding(.bottom, CassetteHeading.bottomSpacing)
      ForEach(mixes, id: \.id) { mix in
        Button { onOpen(mix) } label: { row(mix) }
          .buttonStyle(.plain)
          .accessibilityLabel("\(mix.title), \(Self.info(mix))")
      }
    }
    .padding(.bottom, CassetteTheme.Spacing.lg)
  }

  private func row(_ mix: HomeManager.MadeForYouMix) -> some View {
    HStack(spacing: CassetteTheme.Spacing.md) {
      MadeForYouArt(mix: mix, coverPaths: MoodDoorRow.coverPaths(of: mix), side: Self.artSide)
        .clipShape(RoundedRectangle(cornerRadius: CassetteRadius.small))
      VStack(alignment: .leading, spacing: 4) {
        Text(mix.title)
          .font(.cassette(.rowTitle))
          .foregroundStyle(Color.cassette(.textPrimary))
          .lineLimit(1)
        Text(Self.info(mix))
          .font(.cassette(.metadata))
          .foregroundStyle(Color.cassette(.textSecondary))
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.system(size: CassetteIconSize.row.rawValue, weight: .semibold))
        .foregroundStyle(Color.cassette(.textTertiary))
    }
    .padding(.horizontal, CassetteHeading.sideInset)
    .frame(height: Self.rowHeight)
    .contentShape(Rectangle())
  }

  /// "25 Songs · 1h 32m", as the playlist rows above say it.
  static func info(_ mix: HomeManager.MadeForYouMix) -> String {
    let songs = OneTapPlay.playables(mix.songs)
    let seconds = songs.reduce(0) { $0 + $1.duration }
    let count = "\(songs.count) \(songs.count == 1 ? "Song" : "Songs")"
    return seconds > 0 ? "\(count) · \(seconds.asDurationShortString)" : count
  }
}
