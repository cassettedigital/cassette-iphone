//
//  AlbumRegrouper.swift
//  AmperfyKit
//
//  Cassette fork — Phase 1 (Gap 1): device album grouping.
//
//  Collapses the device's OWNED songs onto the catalog-blind album group keys
//  the cloud computes (buildAlbumGroupKey), so the phone's albums match the web
//  character-for-character. The regroup is the per-sync authority for album
//  identity: it find-or-creates an AlbumMO whose id == group_key, re-points each
//  owned Song onto it, folds the emptied legacy albums' annotations + art, and
//  deletes the emptied legacy albums.
//
//  Idempotent — safe to run on every sync; once every owned song already points
//  at its group-key album it makes no changes. It is catalog-blind — two disk
//  albums that resolve to one catalog album (e.g. a box set) keep their distinct
//  group keys and stay separate.
//
//  It also MATERIALIZES a missing catalog record: the transfer path records a
//  DeviceOwnership row + the file but never builds the SongMO the library renders
//  from (those otherwise come only from a separate, online-gated library sync). So
//  an owned track can sit on disk yet render nowhere. The pre-pass below creates a
//  SongMO (id == the owned Subsonic id, title + duration from the grouping entry)
//  for any owned track that lacks one, so "owned" always equals "visible". It
//  never touches a file or a DeviceOwnership row — the OWNED-track count stays
//  invariant; only the SongMO count grows to match it.
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
import Foundation
import os.log

/// Artwork `type` for a Cassette-provisioned ALBUM cover.
///
/// An owned album's artwork deliberately carries its owned SONG's Subsonic
/// cover-art id, because that is what makes the un-gated getCoverArt byte path
/// serve the folder cover.* from the LAN Player. But `CacheFileManager
/// .createRelPath(for:account:)` derives the cache path from that id, so with an
/// empty type the album and the song resolve to the SAME file —
/// `artworks/<id>.png` — and two rows write over one file: rendering the song
/// re-fetched the folder cover straight over a cover the user had PICKED (art
/// went back to the old one "only temporarily" after every pick).
///
/// A non-empty type nests the album under its own path space —
/// `artworks/album/<id>.png` — while leaving the id (and therefore the fetch)
/// untouched. Mirrors the "artist" type already used for artist images.
/// SubsonicArtworkDownloadDelegate.prepareDownload only rejects the retired
/// "cassette-album" type, so this fetches normally.
///
/// Every site that mints an album artwork identity MUST use this, or the two
/// sites disagree and the collision comes back for whichever albums the other
/// one touched.
let cassetteAlbumArtworkType = "album"

// MARK: - AlbumRegrouper

public final class AlbumRegrouper {
  public struct Summary: Sendable {
    public var movedSongs = 0
    public var purgedAlbums = 0
    /// Emptied on-device synthetic artist rows (cassette-synth-artist:*) purged this
    /// pass — the identity anchor re-keyed their songs+albums onto the cloud artist
    /// identity, leaving the old synthetic row ownerless. Steady-state 0 once folded.
    public var purgedArtists = 0
    public var groups = 0
    public var createdAlbums = 0
    /// SongMOs materialized this pass for OWNED tracks that had a grouping entry
    /// but no catalog record yet (the transfer path records ownership + file but
    /// never builds a SongMO). This is what makes "owned" == "visible".
    public var createdSongs = 0
    public var matchedByLocalId = 0
    public var skipped = 0
    /// Albums (re)pointed at their native cover id this pass — i.e. still awaiting
    /// the getCoverArt fetch. Reads high on the first post-switch pass (migration),
    /// then falls to 0 as covers land `.CustomImage`. A non-zero steady-state value
    /// means provisioning runs but the LAN fetch isn't settling the cover.
    public var coversProvisioned = 0
  }

  private let log = OSLog(subsystem: "Amperfy", category: "AlbumRegrouper")
  private let context: NSManagedObjectContext

  public init(context: NSManagedObjectContext) {
    self.context = context
  }

  /// Apply the cloud grouping to this device's owned songs. `items` is the
  /// per-track grouping from the device-inventory response, keyed by Subsonic
  /// track id (which equals SongMO.id on this device).
  @discardableResult
  public func regroup(
    items: [CassetteDeviceGroupingItem],
    accountInfo: AccountInfo
  )
    -> Summary {
    var summary = Summary()
    guard !items.isEmpty else { return summary }

    // Match a device song to a payload entry by EITHER key: the Subsonic id is
    // the fast path, but a re-sync can reassign Subsonic ids out from under us, so
    // the cassette_local_id (stable, content-derived) is the fallback that keeps a
    // drifted song from being stranded on its old album. These are `let` so they
    // stay Sendable when captured inside context.performAndWait's closure.
    let byTrackId: [String: CassetteDeviceGroupingItem] = {
      var d = [String: CassetteDeviceGroupingItem]()
      for item in items { d[item.subsonicTrackId] = item }
      return d
    }()
    let byLocalId: [String: CassetteDeviceGroupingItem] = {
      var d = [String: CassetteDeviceGroupingItem]()
      for item in items {
        if let lid = item.cassetteLocalId, !lid.isEmpty { d[lid] = item }
      }
      return d
    }()

    let manager = DeviceOwnershipManager(context: context)
    let ownedIds = manager.fetchAllSubsonicTrackIds()
    guard !ownedIds.isEmpty else { return summary }
    // SongMO.id (Subsonic) -> cassette_local_id, for the fallback match above.
    let localIdBySubsonic: [String: String] = {
      var d = [String: String]()
      if let rows = try? manager.fetchAll() {
        for r in rows where r.subsonicTrackId != nil { d[r.subsonicTrackId!] = r.cassetteLocalId }
      }
      return d
    }()

    context.performAndWait {
      let library = LibraryStorage(context: context)
      let account = library.getAccount(info: accountInfo)

      // Cassette artist-identity anchor. Resolve the ONE Artist whose IDENTITY is the
      // cloud's normalized artist key (item.artistGroupKey — inherited-artist:<x> /
      // catalog-artist:<id>) while its NAME stays the library-stylized display, so an
      // artist matches the web while "fun." still shows over the catalog "Fun".
      // Find-or-create by that id; an existing row is RE-KEYED onto it, folding
      // "Fun"/"fun." toward one identity (same-id duplicates then merge). Falls back
      // to today's synthetic id when the cloud payload predates artist_group_key, so
      // nothing regresses pre-deploy.
      func artistIdentity(for item: CassetteDeviceGroupingItem, songArtist: Artist?) -> Artist {
        // Anchor to the cloud identity ONLY in on-device-only mode. In Server Mode the
        // artists are REAL Navidrome rows — SHARED across the artist's whole catalog —
        // that getCoverArt resolves; re-keying one would fork it into a duplicate on the
        // next getArtists sync and drag its non-owned albums along. A nil key (cloud
        // predates the field) is likewise never allowed to re-key. Both fall to today's
        // behavior: reuse an existing artist by display name, else the song's own, else
        // mint a synthetic — NEVER re-key an existing row.
        guard CassetteLibraryFilterProvider.shared.isOnDeviceOnly,
              let artistId = item.artistGroupKey
        else {
          if let named = library.getArtistByExactName(for: account, name: item.displayArtist) {
            return named
          }
          if let songArtist { return songArtist }
          let created = library.createArtist(account: account)
          created.id = "cassette-synth-artist:\(item.displayArtist)"
          created.name = item.displayArtist
          return created
        }
        // Cloud identity present → find-or-create by the key, re-keying an existing row
        // onto it so "Fun"/"fun." fold to one identity while its NAME is untouched.
        if let existing = library.getArtist(for: account, id: artistId) { return existing }
        if let songArtist {
          if songArtist.id != artistId { songArtist.id = artistId }
          return songArtist
        }
        if let named = library.getArtistByExactName(for: account, name: item.displayArtist) {
          if named.id != artistId { named.id = artistId }
          return named
        }
        let created = library.createArtist(account: account)
        created.id = artistId
        created.name = item.displayArtist
        return created
      }

      // PRE-PASS (cassette owned==visible heal): materialize a SongMO for any
      // OWNED track that has a grouping entry but no catalog record yet. Runs
      // before the fetch below so the newly-created songs are picked up and
      // grouped in the same pass (a pending insert matches an IN-predicate fetch).
      // Requires the grouping entry to carry a title (older cloud deploys omit it
      // → nothing is created, the heal simply waits for the deploy).
      do {
        let existingReq: NSFetchRequest<SongMO> = SongMO.fetchRequest()
        existingReq.predicate = NSPredicate(format: "id IN %@", ownedIds)
        let existingIds = Set(((try? context.fetch(existingReq)) ?? []).map(\.id))
        for sid in ownedIds where !existingIds.contains(sid) {
          guard let item = byTrackId[sid] ?? localIdBySubsonic[sid].flatMap({ byLocalId[$0] }),
                let title = item.trackTitle, !title.isEmpty else { continue }
          let song = library.createSong(account: account)
          song.id = sid
          song.title = title
          if let dur = item.duration, dur > 0 { song.remoteDuration = dur }
          // Rip track position → album-detail sort order (disk → track → title).
          // Only set on THIS created song; real-synced songs already carry .track.
          // Null (non-ripped) leaves track = 0 → sorts by title, no worse than before.
          if let idx = item.discTrackIndex, idx > 0 { song.track = idx }
          // Native cover id is provisioned in the main loop below (for ANY owned
          // song lacking artwork), so a heal also fixes songs an earlier build
          // created coverless — not only the ones created this pass.
          // Anchor the freshly-materialized song to the ONE cloud-keyed artist
          // identity (name = the cloud display). Its album link converges on the SAME
          // identity in the main loop's adoptArtistIdentity below.
          song.artist = artistIdentity(for: item, songArtist: nil)
          summary.createdSongs += 1
        }
      }

      // One fetch of every owned Song, with its album prefetched.
      let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      request.predicate = NSPredicate(format: "id IN %@", ownedIds)
      request.relationshipKeyPathsForPrefetching = [#keyPath(SongMO.album)]
      request.returnsObjectsAsFaults = false
      let songMOs = (try? context.fetch(request)) ?? []

      var targetByKey = [String: Album]()
      var mergedLegacyIds = Set<String>() // legacy album ids already folded in
      var coverProvisioned = Set<String>() // album ids whose cover we've settled this pass
      var artistAdopted = Set<String>() // album ids whose display artist we've settled this pass
      // BUG-98: an artist row a song or album left this pass -> the identity it went to, so
      // the purge below can carry the emptied row's rating, plays and star onto it first.
      var artistFoldedInto = [ObjectIdentifier: Artist]()
      var createdCount = 0 // local — nested target() can't mutate the outer summary
      var provisionedCount = 0 // local — albums (re)pointed at a native cover id this pass

      func validLocalCover(_ aw: Artwork?) -> Bool {
        guard let aw, aw.status == .CustomImage, let p = aw.imagePath else { return false }
        return FileManager.default.fileExists(atPath: p)
      }

      // Give an owned album an Artwork keyed on the owned song's NATIVE Subsonic
      // cover id, so the (un-gated) getCoverArt byte path pulls the local-drive
      // cover.jpg from the LAN Player (Navidrome serves the folder cover.* ahead of
      // embedded art). One path for matched and unmatched albums alike — there is
      // no catalog/R2 cover path anymore.
      //
      // Runs for EVERY owned album every regroup, not only when a song moves: an
      // already-grouped device (steady-state moved=0) reaches ONLY the no-move
      // branch, and must still provision + migrate its covers. Deduped per album
      // id; an album with no native id from this song is left for a later song.
      //
      // Migration: an existing device may still hold a synthetic "cassette-album"
      // Artwork from the retired R2 path — a stale .NotChecked/.FetchError shell OR
      // a materialized .CustomImage carrying the WRONG catalog cover (the "green vs
      // gold" case). Re-point either to the native id and reset .NotChecked so
      // getCoverArt re-fetches the correct disk cover.
      func provisionNativeCover(on album: Album, nativeCover: ArtworkRemoteInfo?) {
        guard !coverProvisioned.contains(album.id) else { return }
        let isSyntheticShell = album.artwork?.remoteInfo.type == "cassette-album"
        if !isSyntheticShell, validLocalCover(album.artwork) {
          coverProvisioned.insert(album.id) // already has a good local cover
          return
        }
        // Picked albums are NOT skipped. The hub writes a pick into the album's
        // cover.jpg, so provisioning the native cover id is how that pick reaches
        // this device — the folder cover and the pick are the same bytes now.
        guard let nativeCover, !nativeCover.id.isEmpty else { return } // try a later song
        let aw = album.artwork ?? library.createArtwork(account: account)
        // PRESERVE a usable identity. An album legitimately carries its own
        // al-<album>_<hex> while its songs carry al-<album>_0; replacing one with the
        // other re-points every album and forces a full re-download (the library-wide
        // cover flash). Only mint a new identity when the current one cannot be
        // fetched at all — empty, or the retired "cassette-album" type.
        let identityUnusable = aw.remoteInfo.id.isEmpty || isSyntheticShell
        if identityUnusable {
          // Keep the song's cover-art ID (that is what fetches the folder cover)
          // but give the album its OWN path space — see cassetteAlbumArtworkType.
          let native = ArtworkRemoteInfo(id: nativeCover.id, type: cassetteAlbumArtworkType)
          if aw.remoteInfo != native { aw.remoteInfo = native }
        }
        // Reaching here means the album has NO valid on-disk cover (a good one already
        // early-returned above), so re-arm it for re-fetch and NULL any stale path.
        // The old `if aw.status != .CustomImage` was a no-op on exactly the
        // materialized-wrong .CustomImage shell this function exists to reset, and it
        // never cleared relFilePath — so such a shell served a dead/wrong file forever,
        // contradicting this function's own contract. .FetchError is left as-is (the
        // download manager already retries those) to avoid pointless status churn.
        if aw.status != .FetchError { aw.status = .NotChecked }
        if aw.relFilePath != nil { aw.relFilePath = nil }
        album.artwork = aw
        coverProvisioned.insert(album.id)
        provisionedCount += 1
      }

      // Anchor the album's artist to the ONE cloud-keyed identity every pass — the
      // move-gate twin of the cover heal. A settled device (moved=0) reaches ONLY the
      // no-move branch, so this must run there too. Points BOTH the song and the album
      // at one artist row (id == the cloud key, name == the library-stylized display),
      // so the Artists list, the album's artist line, and the song row all resolve to
      // one identity. Deduped per album id; idempotent — re-pointing when already
      // correct writes nothing. (The old blanket "album.artist != nil → skip" is gone:
      // an album stuck on a stale synthetic id must re-point to the cloud key, which
      // the .id guards below make a no-op once correct.)
      func adoptArtistIdentity(on album: Album, for item: CassetteDeviceGroupingItem, song: Song) {
        guard !artistAdopted.contains(album.id) else { return }
        let artist = artistIdentity(for: item, songArtist: song.artist)
        for left in [song.artist, album.artist].compactMap({ $0 })
          where left.id != artist.id && left.managedObject !== artist.managedObject {
          artistFoldedInto[ObjectIdentifier(left.managedObject)] = artist
        }
        if song.artist?.id != artist.id { song.artist = artist }
        if album.artist?.id != artist.id { album.artist = artist }
        artistAdopted.insert(album.id)
      }

      // Cloud year (catalog / display override), same number the web rail shows.
      // Subsonic tags are often empty for rips; don't invent from track years.
      // Must run on the no-move branch too: a settled library (moved=0) never
      // calls target(), so year would stay 0 forever if it only lived there.
      func applyCloudYear(on album: Album, from item: CassetteDeviceGroupingItem) {
        if let year = item.year, year > 0, album.year != year {
          album.year = year
        }
      }

      func target(for item: CassetteDeviceGroupingItem, nativeCover: ArtworkRemoteInfo?) -> Album {
        let album: Album
        if let cached = targetByKey[item.groupKey] {
          album = cached
        } else {
          album = library.getAlbum(
            for: account,
            id: item.groupKey,
            isDetailFaultResolution: false
          ) ?? {
            let created = library.createAlbum(account: account)
            created.id = item.groupKey
            createdCount += 1
            return created
          }()
          if album.name != item.displayAlbum { album.name = item.displayAlbum }
          targetByKey[item.groupKey] = album
        }
        applyCloudYear(on: album, from: item)
        provisionNativeCover(on: album, nativeCover: nativeCover)
        return album
      }

      for songMO in songMOs {
        let item = byTrackId[songMO.id] ?? localIdBySubsonic[songMO.id].flatMap { byLocalId[$0] }
        guard let item else { summary.skipped += 1; continue }
        if byTrackId[songMO.id] == nil { summary.matchedByLocalId += 1 }
        let song = Song(managedObject: songMO)
        // Owned==visible + ordering heal for EVERY matched owned song (freshly
        // materialized AND pre-existing / re-parented-from-an-old-rip), idempotent:
        //  • track — authoritative disc position from the cloud grouping. A song
        //    re-parented from an earlier partial rip otherwise keeps track 0 and
        //    sorts BEFORE track 1 (the CarPlay out-of-order symptom); the pre-pass
        //    only set track on songs it created, never on re-parented ones.
        //  • size — a materialized (or older coverless-build) SongMO has size 0 and
        //    no local file, so AlbumSongsFetchedResultsController's
        //    excludeServerDeleteUncachedSongsFetchPredicate — (size > 0 AND album
        //    available) OR relFilePath != nil — hides it: the album detail shows a
        //    song COUNT header but an EMPTY track list (the Box Car Racer symptom).
        //    These tracks are owned and streamable over the LAN by their Subsonic
        //    id, so give them a plausible positive size (estimated from duration).
        //    size is the server byte size, NOT a cached flag — playback still
        //    streams; this only clears the "server-deleted uncached ghost" filter.
        if let idx = item.discTrackIndex, idx > 0, song.track != idx { song.track = idx }
        if song.size <= 0 {
          let estimatedBytes = (item.duration ?? 0) * 32_000 // ~256 kbps
          song.size = estimatedBytes > 0 ? estimatedBytes : 1
        }
        // Ensure the song carries a native cover id — its own Subsonic id, the LAN
        // cover proxy key — so its album can get a cover. Songs created by the
        // owned==visible heal (or synced before artwork bundling) may lack one;
        // provisioning here (idempotent — only when absent) heals already-coverless
        // albums too, not just ones created this pass. Mirrors SsXmlParser
        // .parseArtwork (id, empty type, NotChecked); the album inherits it via
        // provisionNativeCover and backfillOwnedAlbumCovers fetches the cover.jpg.
        if song.artwork == nil {
          let aw = library.createArtwork(account: account)
          aw.remoteInfo = ArtworkRemoteInfo(id: songMO.id, type: "")
          aw.status = .NotChecked
          song.artwork = aw
        }
        let current = song.album
        let nativeCover = song.artwork?.remoteInfo
        if current?.id == item.groupKey {
          // Already grouped → no move, but STILL provision the cover, adopt the
          // display artist, and stamp cloud year. A steady-state device
          // (moved=0) reaches ONLY this branch, so without this its covers
          // never paint, its artist line stays blank, and year stays 0.
          if let current {
            provisionNativeCover(on: current, nativeCover: nativeCover)
            adoptArtistIdentity(on: current, for: item, song: song)
            applyCloudYear(on: current, from: item)
          }
          continue
        }

        // Pass the owned song's native Subsonic cover id so getCoverArt can load
        // the album's local-drive cover.jpg over the LAN.
        let targetAlbum = target(for: item, nativeCover: nativeCover)
        adoptArtistIdentity(on: targetAlbum, for: item, song: song)

        if let legacy = current, legacy.id != item.groupKey {
          if !mergedLegacyIds.contains(legacy.id) {
            mergeAnnotations(from: legacy, into: targetAlbum)
            // Preserve a working LOCAL cover from a legacy album (the original
            // downloaded art) when the group album doesn't already have one. If
            // target() provisioned a placeholder shell (a non-.CustomImage native
            // or synthetic Artwork with no file on disk), the real legacy cover
            // supersedes it — delete the orphaned shell so the regroup never leaks
            // a dangling Artwork row (no-orphans invariant).
            if !validLocalCover(targetAlbum.artwork), validLocalCover(legacy.artwork) {
              let superseded = targetAlbum.artwork
              targetAlbum.artwork = legacy.artwork
              if let superseded, superseded.managedObject !== legacy.artwork?.managedObject {
                library.deleteArtwork(artwork: superseded)
              }
            }
            mergedLegacyIds.insert(legacy.id)
          }
        }

        song.album = targetAlbum
        summary.movedSongs += 1
      }

      // Refresh each group album's DENORMALIZED song count (Album.songCount reads
      // the cached managedObject.songCount, not the live relationship, so the
      // "N Songs" header would otherwise read 0 after a re-point).
      for (_, targetAlbum) in targetByKey {
        let count = Int16(clamping: targetAlbum.songs.count)
        if targetAlbum.managedObject.songCount != count {
          targetAlbum.managedObject.songCount = count
        }
      }

      summary.groups = targetByKey.count
      summary.createdAlbums = createdCount
      summary.coversProvisioned = provisionedCount

      // SAVE #1 — re-points + new group-key albums + refreshed counts. This is
      // the user-visible change: the grid settles onto the correct albums in one
      // atomic FRC update. Every owned song already points at its group-key album
      // (the loop above), so no song is album-less across this save; the emptied
      // legacy albums simply hold zero songs until the purge save below.
      do {
        try context.save()
      } catch {
        os_log(
          "regroup save #1 (re-points) failed: %{public}@",
          log: self.log,
          type: .error,
          error.localizedDescription
        )
      }

      // PURGE every empty album — not only the ones we re-pointed off this run.
      // This sweeps the NUL-era + Subsonic duplicate leftovers the old
      // (re-pointed-only) deletion missed: once the consolidation above moves a
      // duplicate's last owned song away, the duplicate is empty and meaningless
      // in this download-only model, so it goes. An album still holding songs
      // (owned or not) is untouched. Done as a SECOND save so the moves above are
      // durably persisted before any delete (a crash between can't strand a song)
      // and the grid sees the moves before the removals — never an insert+delete
      // churn in one batch. No empty AlbumMO survives the operation.
      let albumReq: NSFetchRequest<AlbumMO> = AlbumMO.fetchRequest()
      let allAlbums = (try? context.fetch(albumReq)) ?? []
      for albumMO in allAlbums where (albumMO.songs?.count ?? 0) == 0 {
        context.delete(albumMO)
        summary.purgedAlbums += 1
      }

      // PURGE emptied on-device synthetic artist rows. The identity anchor re-keys an
      // existing artist onto the cloud key (item.artistGroupKey); when two spellings
      // ("Fun"/"fun.") fold onto one identity, the loser keeps its old
      // cassette-synth-artist:* id but its songs + albums were re-pointed to the winner
      // above — so it is now ownerless and meaningless. Scoped to the synthetic prefix
      // (never a real or cloud-keyed artist) + zero owners, mirroring the album purge.
      // Idempotent: once folded, none remain (steady-state purgedArtists == 0).
      let artistReq: NSFetchRequest<ArtistMO> = ArtistMO.fetchRequest()
      artistReq.predicate = NSPredicate(
        format: "%K BEGINSWITH %@", #keyPath(ArtistMO.id), "cassette-synth-artist:"
      )
      let synthArtists = (try? context.fetch(artistReq)) ?? []
      for artistMO in synthArtists
        where (artistMO.songs?.count ?? 0) == 0 && (artistMO.albums?.count ?? 0) == 0 {
        // The artist twin of the album fold (BUG-98): what the person gave the loser
        // survives on the identity it folded into. Once per loser: it is deleted next.
        if let winner = artistFoldedInto[ObjectIdentifier(artistMO)],
           winner.managedObject !== artistMO, !winner.managedObject.isDeleted {
          mergeAnnotations(from: Artist(managedObject: artistMO), into: winner)
        }
        context.delete(artistMO)
        summary.purgedArtists += 1
      }

      // SAVE #2 — the purges (emptied legacy albums + folded synthetic artists).
      do {
        try context.save()
      } catch {
        os_log(
          "regroup save #2 (purge) failed: %{public}@",
          log: self.log,
          type: .error,
          error.localizedDescription
        )
      }
    }
    return summary
  }

  /// Fold an emptied legacy album's (or folded artist's) user annotations into the row that
  /// replaces it. Policy: OR isFavorite, max rating, sum playCount, earliest starredDate,
  /// latest lastTimePlayed. Run once per legacy row (the legacy is deleted after), so
  /// playCount never double-counts across syncs.
  private func mergeAnnotations(
    from legacy: AbstractLibraryEntity,
    into target: AbstractLibraryEntity
  ) {
    if legacy.isFavorite { target.isFavorite = true }
    if legacy.rating > target.rating { target.rating = legacy.rating }
    if legacy.playCount > 0 { target.playCount = target.playCount + legacy.playCount }
    if let ls = legacy.starredDate {
      target.starredDate = min(target.starredDate ?? ls, ls)
    }
    if let ll = legacy.lastTimePlayed {
      target.lastTimePlayed = max(target.lastTimePlayed ?? ll, ll)
    }
  }
}
