//
//  CassetteCloudPlaylistBridge.swift
//  AmperfyKit
//
//  Cassette fork — cloud playlist cutover.
//
//  Replaces Subsonic getPlaylists / createPlaylist / updatePlaylist for the
//  Cassette UX. Materialises user_playlists into local PlaylistMO rows (id =
//  cloud UUID) so PlaylistsVC / PlaylistDetailVC / PlaylistSelectorVC keep
//  working, and writes every mutation back through /api/sync/playlists.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

import CoreData
import Foundation
import os.log
import UIKit

// MARK: - CassetteCloudPlaylistBridge

@MainActor
public enum CassetteCloudPlaylistBridge {
  private static let log = OSLog(subsystem: "digital.cassette", category: "cloud-playlists")
  private static let hubImportDoneKey = "cassette.hubPlaylistImportDone"

  public static var isCloudAvailable: Bool {
    CassetteSyncAPI.bearerToken != nil
  }

  // MARK: - Item-id / cover URL side maps (cloud fields ↔ local playlist id)

  nonisolated private static func itemIdsKey(_ playlistId: String) -> String {
    "cassette.cloudPlaylistItemIds." + playlistId
  }

  nonisolated private static func pendingMovesKey(_ playlistId: String) -> String {
    "cassette.cloudPlaylistPendingMoves." + playlistId
  }

  nonisolated private static func coverUrlKey(_ playlistId: String) -> String {
    "cassette.cloudPlaylistCoverUrl." + playlistId
  }

  nonisolated private static func descriptionKey(_ playlistId: String) -> String {
    "cassette.cloudPlaylistDescription." + playlistId
  }

  /// The playlist's own description from the last cloud sync, shown verbatim under its
  /// name (phone-taste). nil when it has none, or when it is a generated mixtape's
  /// instruction line (see `personDescription`).
  nonisolated public static func storedDescription(for playlistId: String) -> String? {
    guard !playlistId.isEmpty,
          let text = UserDefaults.standard.string(forKey: descriptionKey(playlistId)),
          !text.isEmpty
    else { return nil }
    return text
  }

  /// UserDefaults only, safe inside a background Core Data perform. nil removes it.
  nonisolated private static func storeDescription(_ description: String?, for playlistId: String) {
    guard !playlistId.isEmpty else { return }
    if let text = personDescription(description) {
      UserDefaults.standard.set(text, forKey: descriptionKey(playlistId))
    } else {
      UserDefaults.standard.removeObject(forKey: descriptionKey(playlistId))
    }
  }

  /// The description a person wrote, trimmed; nil when empty. The web's mixtape
  /// generators save an instruction line as the description ("... hit Rebuild for a
  /// different take.", "... tap Smart Mixtape again for a new take."), which is not the
  /// person's words and points at buttons the phone does not have, so it counts as none.
  nonisolated static func personDescription(_ description: String?) -> String? {
    guard let text = description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else { return nil }
    let lowered = text.lowercased()
    if lowered.hasSuffix("for a different take.") || lowered.hasSuffix("for a new take.") {
      return nil
    }
    return text
  }

  /// The derived preset as the cover URL the web would send (`derived_cover_url`), for a
  /// playlist whose sync response left it out.
  nonisolated static func derivedPresetCoverUrl(forPlaylistId playlistId: String) -> String? {
    guard let name = derivedPresetAssetName(forPlaylistId: playlistId) else { return nil }
    // "playlist-cover-preset-07" -> ".../playlist-covers/preset-07.png"
    let slug = name.replacingOccurrences(of: "playlist-cover-", with: "")
    return "https://cassette.digital/playlist-covers/\(slug).png"
  }

  public static func storedItemIds(for playlistId: String) -> [String] {
    UserDefaults.standard.stringArray(forKey: itemIdsKey(playlistId)) ?? []
  }

  /// A song was moved within a playlist on this phone (PlaylistDetailVC): move its cloud item id the same
  /// way, and note that it moved. The stored ids run beside the playlist's songs one for one (BUG-616: the
  /// page, which reloads from the cloud whenever it appears, put a moved song back), and `updateOrder` then
  /// sends a new place for the moved song alone (BUG-887).
  public static func moveStoredItem(playlistId: String, from: Int, to: Int) {
    var ids = storedItemIds(for: playlistId)
    guard from >= 0, from < ids.count, to >= 0, to < ids.count, from != to else { return }
    let moved = ids.remove(at: from)
    ids.insert(moved, at: to)
    storeItemIds(ids, for: playlistId)
    var pending = UserDefaults.standard.stringArray(forKey: pendingMovesKey(playlistId)) ?? []
    pending.removeAll { $0 == moved }
    pending.append(moved)
    UserDefaults.standard.set(pending, forKey: pendingMovesKey(playlistId))
  }

  /// The cloud spaces a playlist's places this far apart after every change (POSITION_STEP in
  /// apps/cassette/src/lib/playlist-order.ts).
  nonisolated static let cloudPositionStep: Double = 1024

  /// The new place for a song moved on this phone, in the playlist's whole order, which also holds the
  /// songs this phone doesn't have (BUG-887). `phoneOrder` is this phone's item ids after the move; `full`
  /// is every item in the cloud, in playlist order. The song goes right after the phone song now above it
  /// (or, moved to the top, right before the one below it), between that song and its neighbour in the
  /// whole list, so every other song keeps its place on every device. nil when neither neighbour is in the
  /// cloud's list, or there is no room between them.
  nonisolated static func placeMoved(
    _ moved: String,
    phoneOrder: [String],
    full: [(id: String, position: Double)]
  )
    -> Double? {
    guard let i = phoneOrder.firstIndex(of: moved),
          full.contains(where: { $0.id == moved }) else { return nil }
    let rest = full.filter { $0.id != moved }
    let at: Int
    if i > 0, let above = rest.firstIndex(where: { $0.id == phoneOrder[i - 1] }) {
      at = above + 1
    } else if i + 1 < phoneOrder.count,
              let below = rest.firstIndex(where: { $0.id == phoneOrder[i + 1] }) {
      at = below
    } else {
      return nil
    }
    let lo = at > 0 ? rest[at - 1].position : nil
    let hi = at < rest.count ? rest[at].position : nil
    switch (lo, hi) {
    case let (lo?, hi?):
      let mid = (lo + hi) / 2
      return mid > lo && mid < hi ? mid : nil
    case let (lo?, nil): return lo + cloudPositionStep
    case let (nil, hi?): return hi - cloudPositionStep
    case (nil, nil): return nil
    }
  }

  /// Absolute cover URL from the last cloud sync, if any.
  nonisolated public static func storedCoverUrl(for playlistId: String) -> String? {
    guard !playlistId.isEmpty,
          let url = UserDefaults.standard.string(forKey: coverUrlKey(playlistId)),
          !url.isEmpty
    else { return nil }
    return url
  }

  /// Bundled PNG for curated web presets (SVG on site; phones can't paint SVG).
  nonisolated public static func bundledPresetCoverImage(forCoverUrl urlString: String)
    -> UIImage? {
    guard let name = bundledPresetAssetName(forCoverUrl: urlString) else { return nil }
    return UIImage(named: name, in: Bundle(for: EntityImageView.self), compatibleWith: nil)
  }

  nonisolated public static func bundledPresetAssetName(forCoverUrl urlString: String) -> String? {
    guard let regex = try? NSRegularExpression(
      pattern: #"playlist-covers/(preset-\d+)\.(?:svg|png)"#,
      options: .caseInsensitive
    ),
      let match = regex.firstMatch(
        in: urlString,
        range: NSRange(urlString.startIndex..., in: urlString)
      ),
      match.numberOfRanges >= 2,
      let slugRange = Range(match.range(at: 1), in: urlString)
    else { return nil }
    // Asset catalog: playlist-cover-preset-07
    return "playlist-cover-\(urlString[slugRange].lowercased())"
  }

  /// The deterministic preset for a playlist with no cover of its own: the same pick the
  /// web makes (`stableIndex` in apps/cassette/src/lib/covers/playlist.ts, FNV-1a over the
  /// id's UTF-16 units with a wrapping 32-bit multiply, i.e. charCodeAt + Math.imul), so
  /// the phone shows the cover the web shows before the server's derived_cover_url arrives.
  /// The id is NOT lowercased: the web hashes it as stored. nil for an empty id (the
  /// player queue's playlist).
  ///
  /// Fixtures (the web's own function, run in node on 2026-10-21):
  ///   "00000000-0000-0000-0000-000000000000" -> playlist-cover-preset-02
  ///   "3f2b9c1e-8a4d-4e2f-9b7a-1c2d3e4f5a6b" -> playlist-cover-preset-08
  nonisolated public static func derivedPresetAssetName(forPlaylistId playlistId: String) -> String? {
    guard !playlistId.isEmpty else { return nil }
    var h: UInt32 = 2_166_136_261
    for unit in playlistId.utf16 {
      h ^= UInt32(unit)
      h = h &* 16_777_619
    }
    return String(format: "playlist-cover-preset-%02d", Int(h % 16) + 1)
  }

  /// The bundled image for `derivedPresetAssetName(forPlaylistId:)`.
  nonisolated public static func derivedPresetCoverImage(forPlaylistId playlistId: String) -> UIImage? {
    guard let name = derivedPresetAssetName(forPlaylistId: playlistId) else { return nil }
    return UIImage(named: name, in: Bundle(for: EntityImageView.self), compatibleWith: nil)
  }

  // MARK: - Local-first materialized pick covers (offline / cold launch)

  // A playlist's own cover comes from three places: a bundled abstract preset
  // (already local), or a user PICK — a remote uploaded image. The pick used to be
  // re-fetched over the network on every render and never persisted, so it blanked
  // on a cold/offline launch (the one image type that wasn't local-first). We now
  // cache the picked bytes on disk keyed by playlist id; the source url carries
  // ?v=updated_at, so a changed pick misses the cache and re-materializes, and a
  // stale file is overwritten. Presets never come here — they render from the bundle.

  nonisolated private static func coverCacheDir() -> URL? {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    let dir = caches.appendingPathComponent("cassette-playlist-covers", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  nonisolated private static func coverFileURL(_ playlistId: String) -> URL? {
    guard !playlistId.isEmpty, let dir = coverCacheDir() else { return nil }
    return dir.appendingPathComponent(playlistId + ".img")
  }

  nonisolated private static func materializedUrlKey(_ playlistId: String) -> String {
    "cassette.playlistCoverMaterializedUrl." + playlistId
  }

  /// Decoded picks by playlist, url and size. A row used to read the file and decode the whole
  /// picture (up to 1400px) on every configure (BUG-819). NSCache is thread-safe.
  nonisolated(unsafe) private static let decodedCovers: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.totalCostLimit = 24 * 1024 * 1024
    return cache
  }()

  /// The playlist's picked cover already on disk, IF it was materialized for this
  /// exact url — so a cold/offline launch renders it with no network. Decoded no larger
  /// than `maxPixel` (the surface's rung, the ladder's top rung by default) and kept in memory.
  nonisolated public static func materializedCoverImage(
    for playlistId: String,
    url: String,
    maxPixel: Int = CoverImageStore.topRung
  )
    -> UIImage? {
    guard UserDefaults.standard.string(forKey: materializedUrlKey(playlistId)) == url,
          let file = coverFileURL(playlistId)
    else { return nil }
    let key = "\(playlistId)|\(url)|\(maxPixel)" as NSString
    if let hit = decodedCovers.object(forKey: key) { return hit }
    guard let image = CoverImageStore.downsampledImage(atPath: file.path, maxPixel: maxPixel)
    else { return nil }
    let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    decodedCovers.setObject(image, forKey: key, cost: cost)
    return image
  }

  /// Posted on the main thread when a playlist's picked cover lands on the phone; the
  /// notification's object is the playlist id. A surface lit from the preset while the pick
  /// was downloading lights again from the pick (the playlist page, the Resume card; BUG-461).
  nonisolated public static let coverDidLand = Notification.Name("CassettePlaylistCoverDidLand")

  /// Persist freshly-downloaded pick bytes so the next cold/offline launch reads local.
  nonisolated public static func storeMaterializedCover(
    _ data: Data,
    for playlistId: String,
    url: String
  ) {
    guard let file = coverFileURL(playlistId) else { return }
    do {
      try data.write(to: file, options: .atomic)
      UserDefaults.standard.set(url, forKey: materializedUrlKey(playlistId))
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: coverDidLand, object: playlistId)
      }
    } catch {
      // Best-effort cache — a failed write just means the next launch re-fetches.
    }
  }

  /// Drop a playlist's materialized cover (on delete / cover cleared).
  nonisolated private static func removeMaterializedCover(_ playlistId: String) {
    if let file = coverFileURL(playlistId) { try? FileManager.default.removeItem(at: file) }
    UserDefaults.standard.removeObject(forKey: materializedUrlKey(playlistId))
  }

  /// The playlist's cover as a LOCAL image — a bundled preset, or a materialized
  /// pick — or nil if a pick hasn't been materialized yet. Fully synchronous, for
  /// surfaces (CarPlay rows) that need an image up front rather than an async fetch.
  /// phone-taste: a playlist with no stored cover gets its derived preset (the person's
  /// pick, else the preset; never album art).
  nonisolated public static func localCoverImage(for playlistId: String) -> UIImage? {
    guard let urlString = storedCoverUrl(for: playlistId) else {
      return derivedPresetCoverImage(forPlaylistId: playlistId)
    }
    if let bundled = bundledPresetCoverImage(forCoverUrl: urlString) { return bundled }
    return materializedCoverImage(for: playlistId, url: urlString)
  }

  /// phone-taste: the playlist's cover to draw right now from what is on the phone: its own
  /// (`localCoverImage`), else, while a pick has not downloaded yet, its derived preset.
  /// Never album art. The one fallback every surface uses (CarPlay rows and Home tiles, Siri,
  /// the Resume card, the playlist page's light), matching the phone tile, which shows the
  /// preset when a pick cannot load.
  nonisolated public static func displayCoverImage(for playlistId: String) -> UIImage? {
    localCoverImage(for: playlistId) ?? derivedPresetCoverImage(forPlaylistId: playlistId)
  }

  /// Whether `localCoverImage(for:)` has the playlist's own cover now: no pick (its preset),
  /// a bundled preset, or a pick materialized for its current url. No decode, so a surface
  /// can key its light on it and light again once a pending pick lands.
  nonisolated public static func hasLocalCover(for playlistId: String) -> Bool {
    guard let urlString = storedCoverUrl(for: playlistId) else { return true }
    if bundledPresetAssetName(forCoverUrl: urlString) != nil { return true }
    guard UserDefaults.standard.string(forKey: materializedUrlKey(playlistId)) == urlString,
          let file = coverFileURL(playlistId)
    else { return false }
    return FileManager.default.fileExists(atPath: file.path)
  }

  /// UserDefaults only — safe to call from a background Core Data perform.
  nonisolated private static func storeItemIds(_ ids: [String], for playlistId: String) {
    UserDefaults.standard.set(ids, forKey: itemIdsKey(playlistId))
  }

  nonisolated private static func storeCoverUrl(_ url: String?, for playlistId: String) {
    guard !playlistId.isEmpty else { return }
    if let normalized = Self.normalizeCoverUrl(url) {
      UserDefaults.standard.set(normalized, forKey: coverUrlKey(playlistId))
    } else {
      UserDefaults.standard.removeObject(forKey: coverUrlKey(playlistId))
      // Cover cleared / playlist gone — drop the on-disk pick too. A CHANGED pick
      // reuses the same per-playlist file (overwritten on re-materialize), so only
      // removal needs cleanup; no orphans accumulate.
      removeMaterializedCover(playlistId)
    }
  }

  /// Absolute http(s) URL phones can load. Relative site paths and preset
  /// SVGs are normalized the same way the sync API does (defense in depth).
  nonisolated private static func normalizeCoverUrl(_ url: String?) -> String? {
    guard var out = url?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty
    else { return nil }
    if out.hasPrefix("/") {
      out = "https://cassette.digital" + out
    }
    if out.contains("/playlist-covers/preset-"), out.hasSuffix(".svg") {
      out = String(out.dropLast(4)) + ".png"
    }
    return out
  }

  private static func newUUID() -> String {
    UUID().uuidString.lowercased()
  }

  // MARK: - Resolve cassette_local_id → Song

  public static func resolveSong(
    cassetteLocalId: String,
    mbid: String?,
    storage: PersistentStorage,
    account: Account
  )
    -> Song? {
    let ownership = DeviceOwnershipManager(context: storage.main.context)
    let owned =
      (mbid.flatMap { try? ownership.fetchOne(mbid: $0) })
        ?? (try? ownership.fetchOne(cassetteLocalId: cassetteLocalId))
    guard let owned, let subsonicId = owned.subsonicTrackId else { return nil }
    return storage.main.library.getSong(for: account, id: subsonicId)
  }

  public static func cassetteLocalId(for song: Song) -> String {
    let ownership = DeviceOwnershipManager(context: song.managedObject.managedObjectContext!)
    if let owned = try? ownership.fetchOne(subsonicTrackId: song.id) {
      let lid = owned.cassetteLocalId
      if !lid.isEmpty { return lid }
    }
    return CassetteLocalID.compute(
      artist: song.artist?.name ?? song.album?.artist?.name ?? "",
      title: song.title,
      durationSeconds: song.duration
    )
  }

  // MARK: - Sync down (cloud → Core Data)

  public static func syncDownPlaylists(
    storage: PersistentStorage,
    accountObjectId: NSManagedObjectID
  ) async throws {
    guard isCloudAvailable else { return }

    let cloud = try await CassetteSyncAPI.shared.listPlaylists(includeItems: true)
    let cloudIds = Set(cloud.map(\.id))

    try await storage.async.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
      let existing = asyncCompanion.library.getPlaylists(for: account)

      // Drop local playlists that are no longer in the cloud. Skip empty-id
      // rows (Amperfy player queues) and anything still linked as a player
      // context/queue playlist.
      for pl in existing where !pl.id.isEmpty && !cloudIds.contains(pl.id) {
        let mo = pl.managedObject
        if mo.playersContextPlaylist != nil
          || mo.playersPodcastPlaylist != nil
          || mo.playersShuffledContextPlaylist != nil
          || mo.playersUserQueuePlaylist != nil {
          continue
        }
        asyncCompanion.library.deletePlaylist(pl)
        storeCoverUrl(nil, for: pl.id)
        storeDescription(nil, for: pl.id)
        UserDefaults.standard.removeObject(forKey: itemIdsKey(pl.id))
      }

      for remote in cloud {
        var playlist = existing.first(where: { $0.id == remote.id })
        if playlist == nil {
          let created = asyncCompanion.library.createPlaylist(account: account)
          created.id = remote.id
          playlist = created
        }
        guard let playlist else { continue }
        playlist.name = remote.name
        // cassette (cover unification): the user's own pick wins; else the server's
        // deterministic preset (rendered from the bundled asset — local + offline);
        // else the same preset derived here, so a response without it never clears it.
        storeCoverUrl(
          remote.coverImageUrl ?? remote.derivedCoverUrl
            ?? derivedPresetCoverUrl(forPlaylistId: remote.id),
          for: remote.id
        )
        storeDescription(remote.description, for: remote.id)

        // Rebuild items from resolved songs.
        playlist.removeAllItems()
        var itemIds: [String] = []
        let items = CassetteCloudPlaylistItem.inPlaylistOrder(remote.items ?? [])
        for item in items {
          let ownership = DeviceOwnershipManager(context: asyncCompanion.context)
          let owned =
            (item.mbid.flatMap { try? ownership.fetchOne(mbid: $0) })
              ?? (try? ownership.fetchOne(cassetteLocalId: item.cassetteLocalId))
          guard let owned, let sid = owned.subsonicTrackId,
                let song = asyncCompanion.library.getSong(for: account, id: sid)
          else { continue }
          playlist.append(playable: song)
          itemIds.append(item.id)
        }
        playlist.remoteSongCount = items.count
        storeItemIds(itemIds, for: remote.id)
        foldCloudDates(remote, into: playlist)
      }
    }
    await sendPendingPlays()
    os_log(
      "Cloud playlists: synced %d playlists",
      log: log,
      type: .info,
      cloud.count
    )
  }

  public static func syncDownPlaylistDetail(
    playlist: Playlist,
    storage: PersistentStorage,
    accountObjectId: NSManagedObjectID
  ) async throws {
    guard isCloudAvailable, !playlist.id.isEmpty else { return }
    let remote = try await CassetteSyncAPI.shared.getPlaylist(id: playlist.id)
    let playlistObjectId = playlist.managedObject.objectID
    try await storage.async.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
      let playlistAsync = Playlist(
        library: asyncCompanion.library,
        managedObject: asyncCompanion.context.object(with: playlistObjectId) as! PlaylistMO
      )
      playlistAsync.name = remote.name
      // cassette (cover unification): user pick wins; else the server preset (bundled).
      // phone-taste: the detail response omits derived_cover_url (the web's [id] route
      // passes no derived cover), so the preset is derived here rather than cleared; a
      // deleted playlist is still cleared by the list sync.
      storeCoverUrl(
        remote.coverImageUrl ?? remote.derivedCoverUrl
          ?? derivedPresetCoverUrl(forPlaylistId: remote.id),
        for: remote.id
      )
      storeDescription(remote.description, for: remote.id)
      playlistAsync.removeAllItems()
      var itemIds: [String] = []
      let items = CassetteCloudPlaylistItem.inPlaylistOrder(remote.items ?? [])
      for item in items {
        let ownership = DeviceOwnershipManager(context: asyncCompanion.context)
        let owned =
          (item.mbid.flatMap { try? ownership.fetchOne(mbid: $0) })
            ?? (try? ownership.fetchOne(cassetteLocalId: item.cassetteLocalId))
        guard let owned, let sid = owned.subsonicTrackId,
              let song = asyncCompanion.library.getSong(for: account, id: sid)
        else { continue }
        playlistAsync.append(playable: song)
        itemIds.append(item.id)
      }
      playlistAsync.remoteSongCount = items.count
      storeItemIds(itemIds, for: remote.id)
      foldCloudDates(remote, into: playlistAsync)
    }
  }

  /// The cloud's dates, written last (setting a name or the songs stamps the change date
  /// with now). The change date is the cloud's last edit (BUG-588: a sync used to stamp
  /// every playlist with the sync's time, so "Last changed" sorted by name). The last-played
  /// date is the later of this phone's and the cloud's (One Home: played on any device), so
  /// it never moves backwards.
  nonisolated private static func foldCloudDates(_ remote: CassetteCloudPlaylist, into playlist: Playlist) {
    if let edited = CassetteISODate.parse(remote.updatedAt) {
      playlist.changeDate = edited
    }
    if let played = CassetteISODate.parse(remote.lastPlayedAt),
       played > (playlist.lastTimePlayed ?? .distantPast) {
      playlist.lastTimePlayed = played
    }
  }

  // MARK: - Played (One Home)

  nonisolated private static let pendingPlaysKey = "cassette.cloudPlaylistPlayedPending"

  /// A playlist started playing on this phone: tell the cloud, so every device lists the
  /// playlist last played first (POST /api/sync/playlists/{id}/played). Offline, the start is
  /// kept and sent with the next one or the next playlist sync, carrying when it happened.
  public static func reportPlayed(playlistId: String, at: Date) {
    guard UUID(uuidString: playlistId) != nil else { return }
    var pending = UserDefaults.standard.dictionary(forKey: pendingPlaysKey) as? [String: Double] ?? [:]
    pending[playlistId.lowercased()] = max(pending[playlistId.lowercased()] ?? 0, at.timeIntervalSince1970)
    UserDefaults.standard.set(pending, forKey: pendingPlaysKey)
    Task { await sendPendingPlays() }
  }

  private static var isSendingPlays = false

  private static func sendPendingPlays() async {
    guard isCloudAvailable, !isSendingPlays else { return }
    isSendingPlays = true
    defer { isSendingPlays = false }
    let pending = UserDefaults.standard.dictionary(forKey: pendingPlaysKey) as? [String: Double] ?? [:]
    for (id, at) in pending {
      do {
        try await CassetteSyncAPI.shared.playlistPlayed(id: id, playedAt: Date(timeIntervalSince1970: at))
      } catch CassetteSyncError.http(404) {
        // the playlist is gone from the cloud: nothing to keep
      } catch {
        continue
      }
      var left = UserDefaults.standard.dictionary(forKey: pendingPlaysKey) as? [String: Double] ?? [:]
      // a later start of the same playlist while this one was in flight stays to be sent
      if left[id] == at { left[id] = nil }
      UserDefaults.standard.set(left, forKey: pendingPlaysKey)
    }
  }

  // MARK: - Uploads (local → cloud)

  public static func createPlaylistRemote(playlist: Playlist) async throws {
    guard isCloudAvailable else { return }
    let id = playlist.id.isEmpty ? newUUID() : playlist.id
    if playlist.id.isEmpty { playlist.id = id }
    _ = try await CassetteSyncAPI.shared.createPlaylist(id: id, name: playlist.name)
    storeItemIds([], for: id)
    os_log("Cloud playlists: created %{public}@", log: log, type: .info, id)
  }

  public static func updateName(playlist: Playlist) async throws {
    guard isCloudAvailable else { return }
    if playlist.id.isEmpty {
      try await createPlaylistRemote(playlist: playlist)
      return
    }
    _ = try await CassetteSyncAPI.shared.updatePlaylist(id: playlist.id, name: playlist.name)
  }

  public static func addSongs(playlist: Playlist, songs: [Song]) async throws {
    guard isCloudAvailable, !songs.isEmpty else { return }
    if playlist.id.isEmpty {
      try await createPlaylistRemote(playlist: playlist)
    }
    var ids = storedItemIds(for: playlist.id)
    var ops: [CassettePlaylistOp] = []
    let base = Double(Date().timeIntervalSince1970 * 1000)
    let addedAt = ISO8601DateFormatter().string(from: Date())
    for (i, song) in songs.enumerated() {
      let itemId = newUUID()
      let localId = cassetteLocalId(for: song)
      ops.append(
        .add(
          itemId: itemId,
          cassetteLocalId: localId,
          mbid: song.musicBrainzId,
          position: base + Double(i),
          addedAt: addedAt,
          addedByDevice: "ios"
        )
      )
      ids.append(itemId)
    }
    _ = try await CassetteSyncAPI.shared.applyPlaylistOps(
      playlistId: playlist.id,
      ops: ops
    )
    // Beside this phone's songs one for one, the new ones last as the phone appends them: never the
    // cloud's whole list, which also holds songs this phone doesn't have, so a later removal by index
    // would take the wrong song (BUG-887).
    storeItemIds(ids, for: playlist.id)
  }

  public static func deleteSong(playlist: Playlist, index: Int) async throws {
    guard isCloudAvailable, !playlist.id.isEmpty else { return }
    var ids = storedItemIds(for: playlist.id)
    // The stored ids run beside this phone's songs one for one. Past their end they no longer line up,
    // and the cloud's whole list (songs this phone doesn't have too) can't say which song this was: it
    // used to be read by the phone's index and removed the wrong one (BUG-887). Nothing is removed; the
    // next sync puts the cloud's list back on the phone.
    guard index >= 0, index < ids.count else {
      os_log(
        "Cloud playlists: removal at %d with %d stored ids, not sent",
        log: log,
        type: .error,
        index,
        ids.count
      )
      return
    }
    let itemId = ids[index]
    _ = try await CassetteSyncAPI.shared.applyPlaylistOps(
      playlistId: playlist.id,
      ops: [.remove(itemId: itemId)]
    )
    ids.remove(at: index)
    storeItemIds(ids, for: playlist.id)
  }

  /// Sends the songs moved on this phone since the last send, each alone to its new place in the
  /// playlist's whole order (placeMoved). It used to re-place every song this phone has at the end, so on
  /// every device the songs it doesn't have jumped to the top (BUG-887).
  public static func updateOrder(playlist: Playlist) async throws {
    guard isCloudAvailable, !playlist.id.isEmpty else { return }
    let moved = UserDefaults.standard.stringArray(forKey: pendingMovesKey(playlist.id)) ?? []
    UserDefaults.standard.removeObject(forKey: pendingMovesKey(playlist.id))
    guard !moved.isEmpty else { return }
    let ids = storedItemIds(for: playlist.id)
    let remote = try await CassetteSyncAPI.shared.getPlaylist(id: playlist.id)
    var full = CassetteCloudPlaylistItem.inPlaylistOrder(remote.items ?? []).map { (
      id: $0.id,
      position: $0.position
    ) }
    var ops: [CassettePlaylistOp] = []
    for itemId in moved {
      guard let position = placeMoved(itemId, phoneOrder: ids, full: full) else { continue }
      full.removeAll { $0.id == itemId }
      full.insert(
        (id: itemId, position: position),
        at: full.firstIndex { $0.position > position } ?? full.count
      )
      ops.append(.reorder(itemId: itemId, position: position))
    }
    guard !ops.isEmpty else { return }
    _ = try await CassetteSyncAPI.shared.applyPlaylistOps(playlistId: playlist.id, ops: ops)
  }

  public static func deletePlaylist(id: String) async throws {
    guard isCloudAvailable, !id.isEmpty else { return }
    try await CassetteSyncAPI.shared.deletePlaylist(id: id)
    UserDefaults.standard.removeObject(forKey: itemIdsKey(id))
    storeCoverUrl(nil, for: id)
    storeDescription(nil, for: id)
  }

  // MARK: - One-shot hub Subsonic → cloud import

  /// Pull any leftover Subsonic playlists into user_playlists once, then never
  /// again. Best-effort: empty/unreachable hub is fine. Does not mutate Core
  /// Data — reads Subsonic XML and writes straight to the cloud.
  /// Internal (not public): `SubsonicServerApi` is an internal type.
  static func importHubPlaylistsIfNeeded(
    subsonicApi: SubsonicServerApi,
    storage: PersistentStorage,
    accountObjectId: NSManagedObjectID
  ) async {
    guard isCloudAvailable else { return }
    guard !UserDefaults.standard.bool(forKey: hubImportDoneKey) else { return }
    defer { UserDefaults.standard.set(true, forKey: hubImportDoneKey) }

    do {
      let response = try await subsonicApi.requestPlaylists()
      let hubPlaylists = parseHubPlaylistSummaries(from: response.data)
      guard !hubPlaylists.isEmpty else {
        os_log("Cloud playlists: hub import — no Subsonic playlists", log: log, type: .info)
        return
      }

      let existing = (try? await CassetteSyncAPI.shared.listPlaylists()) ?? []
      let existingNames = Set(existing.map(\.name))

      for hub in hubPlaylists {
        if existingNames.contains(hub.name) { continue }
        let cloudId = newUUID()
        _ = try await CassetteSyncAPI.shared.createPlaylist(id: cloudId, name: hub.name)

        let songsResponse = try await subsonicApi.requestPlaylistSongs(id: hub.id)
        let songIds = parseHubSongIds(from: songsResponse.data)
        let base = Double(Date().timeIntervalSince1970 * 1000)

        // Resolve songs on the Core Data queue, then build ops on the main actor
        // (avoids mutating a captured [[String: Any]] inside a @Sendable closure).
        let resolved: [HubImportSong] = try await storage.async.performAndGet {
          asyncCompanion in
          let account = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
          var out: [HubImportSong] = []
          for (i, sid) in songIds.enumerated() {
            guard let song = asyncCompanion.library.getSong(for: account, id: sid) else {
              continue
            }
            let localId = CassetteLocalID.compute(
              artist: song.artist?.name ?? song.album?.artist?.name ?? "",
              title: song.title,
              durationSeconds: song.duration
            )
            out.append(HubImportSong(localId: localId, index: i))
          }
          return out
        }

        if !resolved.isEmpty {
          let addedAt = ISO8601DateFormatter().string(from: Date())
          let ops: [CassettePlaylistOp] = resolved.map { song in
            .add(
              itemId: UUID().uuidString.lowercased(),
              cassetteLocalId: song.localId,
              mbid: nil,
              position: base + Double(song.index),
              addedAt: addedAt,
              addedByDevice: "ios-hub-import"
            )
          }
          _ = try await CassetteSyncAPI.shared.applyPlaylistOps(
            playlistId: cloudId,
            ops: ops
          )
        }
      }
      os_log(
        "Cloud playlists: hub import done (%d)",
        log: log,
        type: .info,
        hubPlaylists.count
      )
    } catch {
      os_log(
        "Cloud playlists: hub import skipped/failed: %{public}@",
        log: log,
        type: .info,
        String(describing: error)
      )
    }
  }

  /// Extract `(id, name)` pairs from a Subsonic `getPlaylists` XML body.
  private static func parseHubPlaylistSummaries(from data: Data) -> [(id: String, name: String)] {
    guard let xml = String(data: data, encoding: .utf8) else { return [] }
    var out: [(id: String, name: String)] = []
    let pattern = #"<playlist\b[^>]*>"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = xml as NSString
    for match in regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
      let tag = ns.substring(with: match.range)
      guard let id = attr(tag, "id"), let name = attr(tag, "name"), !id.isEmpty else {
        continue
      }
      out.append((id: id, name: name.htmlUnescaped))
    }
    return out
  }

  private static func parseHubSongIds(from data: Data) -> [String] {
    guard let xml = String(data: data, encoding: .utf8) else { return [] }
    var out: [String] = []
    let pattern = #"<entry\b[^>]*\bid="([^"]+)"[^>]*>"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = xml as NSString
    for match in regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
      if match.numberOfRanges >= 2 {
        out.append(ns.substring(with: match.range(at: 1)))
      }
    }
    if out.isEmpty {
      let entryPattern = #"<entry\b[^>]*>"#
      if let entryRegex = try? NSRegularExpression(pattern: entryPattern) {
        for match in entryRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
          let tag = ns.substring(with: match.range)
          if let id = attr(tag, "id") { out.append(id) }
        }
      }
    }
    return out
  }

  private static func attr(_ tag: String, _ name: String) -> String? {
    let pattern = #"\#(name)="([^"]*)""#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(
            in: tag,
            range: NSRange(location: 0, length: (tag as NSString).length)
          ),
          match.numberOfRanges >= 2
    else { return nil }
    return (tag as NSString).substring(with: match.range(at: 1))
  }
}

// MARK: - HubImportSong

/// Sendable song identity collected inside a Core Data perform for hub import.
private struct HubImportSong: Sendable {
  let localId: String
  let index: Int
}

extension String {
  fileprivate var htmlUnescaped: String {
    replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
  }
}
