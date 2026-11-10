//
//  IntentExecutor.swift
//  AmperfyKit
//
//  Cassette fork — Layer 3 Phase 3.1 (Transfer Mechanism).
//
//  Polls cassette.digital for actionable sync intents and drives them to
//  completion: marks syncing, checks the Cassette Player is reachable on the
//  LAN, resolves the album's track list server-side, and enqueues background
//  downloads (or removals). State transitions are reported back so the admin
//  test tool can observe progress.
//
//  Idempotent by design: re-running an intent skips already-owned tracks and
//  already-in-flight downloads, then completes once everything is present.
//  This makes crash/relaunch recovery and the 30s foreground poll safe.
//
//  Phase 3.1 handles `scope == "album"` only. Other scopes fail with
//  `unsupported_scope_in_phase_31`.
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
import CryptoKit
import Foundation
import os.log
import UIKit

@MainActor
public final class IntentExecutor {
  public static let shared = IntentExecutor()

  private let log = OSLog(subsystem: "Amperfy", category: "IntentExecutor")
  private let api = CassetteSyncAPI.shared
  private let transferSession = CassetteTransferSession.shared

  private var isRunning = false
  /// Set by executeRemoval when a remove intent deleted owned tracks; drives the
  /// single guaranteed library repaint at the end of a poll cycle.
  private var didRemoveThisCycle = false
  /// Set by executeIntent when it leaves an intent `syncing` (owned tracks still
  /// downloading). Read at the end of a pass to drive CassetteSyncStatus — the
  /// "Syncing your library" banner — so the banner reflects a real download wave,
  /// not the 30s poll itself.
  private var downloadsInFlightThisPass = false
  /// Per pass, for the Home status line: album adds outstanding when the pass began, and
  /// whether the hub answered or failed to answer an add that needed it.
  private var pendingAlbumAddsThisPass = 0
  private var hubReachedThisPass = false
  private var hubUnreachableThisPass = false
  /// Whether the computer answered this pass, once asked (nil until an add needs it): one try a pass (BUG-886).
  private var hubAnswerThisPass: Bool?
  // Once-per-launch device registration (user_devices upsert). The header
  // keep-alive rides every request; this full registration also refreshes
  // platform/model/app_version.
  private var hasRegisteredDevice = false
  // Throttled account refresh (name/email + avatar + appearance skin/icon +
  // server mode + download quality — the whole /api/sync/account blob, ~300
  // bytes). Re-fetched on a short interval instead of once per launch, so a
  // change made on another device (e.g. a new profile emoji) shows up here
  // promptly. `nil` until the first fetch.
  private var lastAccountRefreshAt: Date?
  /// Album keys the cloud reports as carrying a USER PICK (cover_is_override), learned
  /// from the artwork manifest. The folder-cover backfill consults this before touching
  /// any album: artwork IDENTITY cannot identify a pick (picks are materialized onto the
  /// album's existing song-keyed cover-art id), so the manifest flag is the only
  /// trustworthy signal — and getting this wrong overwrites a cover the user chose.
  /// Whether the LAST completed poll actually did something (executed an intent,
  /// refreshed artwork, or removed tracks). Drives the poll cadence: polling every
  /// 30s forever is a battery cost paid for nothing once a library has settled.
  public private(set) var lastPollDidWork = false
  /// Set by the artwork pass when it actually refreshed something this poll.
  private var artworkDidWorkThisPass = false
  /// True once a manifest pass has completed this launch. The folder-cover pass must
  /// not run before it: without the pick set it cannot tell a user's cover from a
  /// folder cover, and an ownership break is worse than a delayed refresh.
  private var hasReadManifestThisLaunch = false

  /// Throttle for the artwork manifest fetch (GET /devices/:id/artwork). It
  /// re-evaluates every owned album, but artwork changes rarely, so pulling it on
  /// every 30s poll is wasted chatter. We refetch on the first pass, when the owned
  /// set changes, or after this interval — see backfillOwnedArtistImages.
  private var lastArtworkManifestAt: Date?
  private var lastManifestOwnedCount = -1
  private static let artworkManifestMinInterval: TimeInterval = 300 // 5 min

  /// Throttle for the track-freshness manifest fetch (GET
  /// /devices/:id/track-freshness) — the audio sibling of the artwork
  /// manifest throttle above. A re-rip that changes a track's bytes without
  /// changing its title/duration is rare enough that checking every 30s poll
  /// would be wasted chatter; this runs on the same cadence as the artwork
  /// pass for the same reason.
  private var lastTrackFreshnessSweepAt: Date?
  private static let trackFreshnessMinInterval: TimeInterval = 300 // 5 min

  /// Once per launch: drop leftover artwork downloads for unfetchable artist ids.
  private var didSweepStaleArtistDownloadsThisLaunch = false

  // Sync Reconciliation (Phase 1): throttle for the periodic full-state
  // inventory report — the device's complete owned-set, posted on poll so the
  // server's "actual" self-heals. The per-transfer differential report keeps
  // things live during active sync; this corrects drift (missed reports,
  // out-of-band deletions). nil until the first report this launch.
  private var lastFullInventoryReportAt: Date?
  private let fullInventoryReportMinInterval: TimeInterval = 120

  // Per-artwork retry back-off. The cover + artist-image backfills re-evaluate the
  // whole owned set every poll; without this they re-fetch a cover/photo the source
  // CANNOT provide — a synthetic artist with no real image, an album whose cover.jpg
  // is off-LAN or genuinely absent — on EVERY 30s poll, forever (the "Artwork not
  // found" / "OVERWRITING cached cover" churn). We stamp each attempt and skip a
  // re-attempt inside the cooldown. First attempts and genuine content changes bypass
  // it, so healthy art still heals on the very next poll (a ripped CD's cover appears
  // right away) — only the doomed retries are throttled. In-memory on purpose: a
  // relaunch clears it and gives everything one fresh attempt.
  private var artworkRetryAt: [String: Date] = [:]
  private let artworkRetryCooldown: TimeInterval = 600 // 10 min

  /// Returns true (and stamps `key`) when it has NOT been attempted within the
  /// cooldown, false to skip this poll. A caller acting on a real content change
  /// should NOT consult this — it should fetch straight away.
  private func mayRetryArtwork(_ key: String) -> Bool {
    let now = Date()
    if let last = artworkRetryAt[key], now.timeIntervalSince(last) < artworkRetryCooldown {
      return false
    }
    artworkRetryAt[key] = now
    return true
  }

  public init() {}

  /// Entry point for polling (foreground + 30s timer). No-op if no account or
  /// no bearer token yet, or if a run is already in progress.
  public func handlePendingIntents() async {
    // Verbose-but-temporary logging (Phase 3.1) — `print` is guaranteed
    // visible in the Xcode console, unlike os_log .info which is filtered.
    print("Cassette poll: handlePendingIntents() entered")
    guard !isRunning else {
      print("Cassette poll: skip - a run is already in progress")
      return
    }
    guard CassetteSyncAPI.bearerToken != nil else {
      print("Cassette poll: skip - NO BEARER TOKEN (re-link in Settings > Developer)")
      return
    }
    guard AmperKit.shared.storage.settings.accounts.active != nil else {
      print("Cassette poll: skip - no active account")
      return
    }

    isRunning = true
    defer { isRunning = false }
    // https to the computer once the cloud has its key, http until then (BUG-879)
    CassetteHubTrust.applyToActiveAccount()
    didRemoveThisCycle = false
    downloadsInFlightThisPass = false
    pendingAlbumAddsThisPass = 0
    hubReachedThisPass = false
    hubUnreachableThisPass = false
    hubAnswerThisPass = nil
    // Reset per-poll; set below by anything that constitutes real work.
    var pollDidWork = false
    artworkDidWorkThisPass = false
    defer { lastPollDidWork = pollDidWork || artworkDidWorkThisPass }
    // Albums removed on this phone: tell the cloud to keep them off it before this
    // pass reports inventory, or the reconcile that report triggers re-adds them.
    await PhoneRemoval.sendPending()
    // Mood tags for More Like Lately and the Lately mix; refreshes at most twice a day.
    await LibraryMoods.shared.refreshIfDue()
    // Genres for albums whose files have none (Library > Genres); at most twice a day.
    await LibraryGenres.shared.applyIfDue()
    // Home, made in the cloud (One Home), which carries the made-for-you playlists. Their own
    // set is only asked for while no Home has ever arrived (the stand-in Home reads it).
    await HomeStore.shared.refreshIfDue()
    if HomeStore.shared.answer == nil {
      await MadeForYouStore.shared.refreshIfDue()
    }

    // One-time: clear artwork state poisoned by the retired synthetic paths, so the
    // backfills below can actually heal those albums instead of skipping them as
    // "unchanged" forever. No-op after the first run. See the helper for why.
    healLegacyArtworkPoisonIfNeeded()
    // One-time per launch: drop any leftover artwork download for an artist getCoverArt
    // can never resolve, so a synthetic-artist request from an older build stops
    // oscillating failed → reset → retry in the queue.
    await sweepStaleUnfetchableArtistDownloadsIfNeeded()

    if !hasRegisteredDevice {
      do {
        try await api.registerDevice()
        hasRegisteredDevice = true
      } catch {
        // Non-fatal: the X-Cassette-Device-Id header on the poll below still
        // upserts the registry row. Retry the full registration next poll.
        print("Cassette poll: device registration failed - \(error.localizedDescription)")
      }
    }

    let intents: [CassetteSyncIntent]
    do {
      print("Cassette poll: fetching pending intents from cassette.digital")
      intents = try await api.getActionableIntents()
    } catch {
      print("Cassette poll: failed to fetch intents - \(error.localizedDescription)")
      os_log(
        "failed to fetch intents: %{public}@",
        log: self.log,
        type: .error,
        error.localizedDescription
      )
      return
    }

    print("Cassette poll: received \(intents.count) actionable intent(s)")
    pendingAlbumAddsThisPass = intents.filter { $0.scope == "album" && $0.intentKind != "remove" }.count
    // The fetch above round-tripped to cassette.digital with a valid bearer
    // token, so the device is paired and reachable: stamp the freshness signal
    // the account menu reads ("Synced 5m ago"). Persisted (not just the
    // in-memory lastFullInventoryReportAt) so it survives relaunch.
    Self.recordSuccessfulSync()

    // Refresh the caller's ACCOUNT (name/email, avatar, appearance, server mode,
    // download quality) so anything changed on another device shows up here. On a
    // short throttle (not once-per-launch): the payload is tiny and these are
    // things a person expects to sync promptly. Best-effort, off the critical path.
    await refreshAccountIfDue()
    for intent in intents {
      await executeIntent(intent)
    }
    // Work is progress: the computer answered, a download is moving, or something came off. Albums only waiting
    // for a computer that's out of reach are not work, so a phone away from home settles to the idle pace
    // instead of checking every 30 seconds (BUG-886); opening the app still checks at once.
    if hubReachedThisPass || downloadsInFlightThisPass || intents.contains(where: { $0.intentKind == "remove" }) {
      pollDidWork = true
    }

    // Removals just deleted owned tracks: repaint the on-device-only library ONCE,
    // immediately, now that the whole burst has settled and the main thread is free.
    // A removed album's tracks are no longer owned, so the rebuilt FRC drops it in
    // place — no relaunch. Fired here (right after the loop) rather than per-removal
    // so the burst can't cancel it and it can't race the regroup below.
    if didRemoveThisCycle {
      pollDidWork = true
      await MainActor.run { CassetteOwnershipNotifier.shared.ownershipDidChangeNow() }
    }

    // Fast Album Art: fill covers for albums already on the device — not just
    // fresh transfers. Off-main, throttled, idempotent; reconciles every sync
    // so existing albums get and keep their art.
    if let accountInfo = AmperKit.shared.storage.settings.accounts.active {
      // Collision heal BEFORE the manifest pass: it clears the cached path of any
      // album still sharing a file with its song, which is exactly the signal the
      // Run after it instead and a picked album would sit path-less for a whole poll.
      await healAlbumArtworkPathCollisionIfNeeded()
      // Must run BEFORE the manifest pass below, which is what reads these stamps.
      // DIAGNOSTIC: `.updateOncePerSession` makes the artwork queue re-download EVERY
      // rendered artwork once per launch regardless of it already being cached, which
      // would overwrite picks on every cold start; `.onlyOnce` leaves cached rows
      // alone. Which one is active decides whether the overwrite needs preventing at
      // the queue or only repairing after the fact, so print it rather than assume.
      print(
        "Cassette poll: artworkDownloadSetting = "
          +
          "\(AmperKit.shared.storage.settings.accounts.getSetting(accountInfo).read.artworkDownloadSetting)"
      )
      // Manifest pass FIRST: it learns which albums carry a user PICK, and the
      // folder-cover backfill below must know that before it touches anything —
      // otherwise it re-points a picked album and overwrites the user's choice.
      await backfillOwnedArtistImages(accountInfo: accountInfo)
      await backfillOwnedAlbumCovers(accountInfo: accountInfo)
      // cassette §art-collapse: re-tier existing local covers (generate the
      // ~480px thumb) for any that predate tiering. Idempotent + off-main.
      await backfillCoverThumbnails(accountInfo: accountInfo)
      // Content-freshness sweep: notice a re-rip that changed an owned track's
      // bytes without changing its title/duration (invisible to every other
      // sync signal). Throttled the same as the artwork manifest above.
      await sweepTrackFreshnessIfDue()
    }

    // Sync Reconciliation (Phase 1): report the device's COMPLETE owned-set so
    // the server's "actual" inventory self-heals from any missed differential
    // report or out-of-band deletion. Throttled — see fullInventoryReportMinInterval.
    // The response carries the catalog-blind album grouping (Phase 1, Gap 1) —
    // apply it so the device's albums match the web.
    let inventoryResponse = await reportFullInventoryIfDue()
    if let inventoryResponse {
      await applyAlbumGrouping(inventoryResponse)
    }

    // Publish the sync-active state for the Home banner: true while a real
    // download wave is moving (an intent left `syncing`), false once every
    // actionable intent's tracks are on disk. Only flips on a real change.
    // with how many albums are still outstanding and whether the hub answered (nil when
    // no add needed it this pass).
    let hubReachable: Bool? = hubReachedThisPass ? true : (hubUnreachableThisPass ? false : nil)
    await CassetteSyncStatus.update(
      active: downloadsInFlightThisPass,
      pendingAlbums: pendingAlbumAddsThisPass,
      hubReachable: hubReachable
    )
  }

  /// Pull-to-refresh entry point (B2). Drives the full on-demand convergence
  /// chain so the user's gesture reflects the Mac's CURRENT disk: (1) ask the
  /// paired Player's sidecar to re-read the disk and push the refreshed index to
  /// the cloud (scan-first convergence over the LAN), then (2) re-report this
  /// device's full inventory (foreground throttle bypassed) and apply the intents
  /// the cloud reconcile produces. Best-effort throughout — if the sidecar is
  /// unreachable or its port is unknown, convergeOnPlayer returns a non-fatal
  /// result and we still fall through to the normal poll, so the refresh degrades
  /// to lazy convergence (watcher + heartbeat) rather than failing.
  ///
  /// Wire the library view's pull-to-refresh (UIRefreshControl / .refreshable)
  /// to `await …intentExecutor.convergeAndRefresh()`.
  public func convergeAndRefresh() async {
    let serverUrl = AmperKit.shared.storage.settings.accounts.activeSetting.read
      .loginCredentials?.serverUrl
    _ = await CassetteSyncAPI.shared.convergeOnPlayer(serverUrl: serverUrl)
    // Force a fresh full-inventory report (bypass the throttle) so the cloud
    // reconcile runs against current truth, then apply what it queued.
    lastFullInventoryReportAt = nil
    await handlePendingIntents()
  }

  /// Report this phone's full inventory now (throttle bypassed) and run a pass, without
  /// asking the Mac to rescan. After Put back, so the cloud queues the album again.
  public func reportInventoryNow() async {
    lastFullInventoryReportAt = nil
    await handlePendingIntents()
  }

  /// Post the device's complete owned-set (full-state inventory) to the server,
  /// throttled so the 30s foreground timer doesn't spam it — a background poll
  /// always exceeds the interval. The server replaces this device's rows with
  /// the snapshot and stamps `inventory_as_of` (the reconciler's freshness
  /// signal). Best-effort: a failure just retries on the next poll, and the
  /// per-transfer differential report keeps the server live in the meantime.
  private func reportFullInventoryIfDue() async -> CassetteDeviceInventoryResponse? {
    if let last = lastFullInventoryReportAt,
       Date().timeIntervalSince(last) < fullInventoryReportMinInterval {
      return nil
    }

    let manager = DeviceOwnershipManager(context: AmperKit.shared.storage.main.context)
    let items: [(cassetteLocalId: String, mbid: String?, downloadedAt: Date)]
    do {
      items = try manager.fetchAllInventory()
    } catch {
      print("Cassette poll: full-inventory snapshot failed - \(error.localizedDescription)")
      return nil
    }

    // A full-state report is a complete snapshot; the server replaces the
    // device's rows with exactly what we send. The inventory endpoint caps a
    // request at 5000 items, so for a larger library we must NOT send a
    // truncated list — that would read as a smaller "actual" and (once removes
    // go live) orphan the rest. Skip instead; the differential report keeps the
    // server live, and the freshness gate treats a missing snapshot as stale.
    if items.count > 5000 {
      print(
        "Cassette poll: skipping full-state inventory — \(items.count) items exceeds the 5000 server cap"
      )
      return nil
    }

    let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    let deviceLabel = UIDevice.current.name
    do {
      let response = try await api.reportFullInventory(
        deviceId: deviceId,
        deviceLabel: deviceLabel,
        items: items
      )
      lastFullInventoryReportAt = Date()
      print("Cassette poll: reported full-state inventory (\(items.count) item(s))")
      return response
    } catch {
      print("Cassette poll: full-state inventory report failed - \(error.localizedDescription)")
      return nil
    }
  }

  /// Content-freshness sweep: for every owned track, compare the hub's current
  /// content fingerprint (from GET /devices/:id/track-freshness) against what
  /// this device last applied.
  ///
  /// cassetteLocalId is deliberately content-blind (artist+title+duration), so
  /// a re-rip that fixes an audio-quality issue without changing the title or
  /// duration is invisible to every other signal — the device already has
  /// "that identity" and never looks again. This is the periodic check-in that
  /// closes the gap, the audio sibling of the artwork manifest's
  /// local_cover_version handling.
  ///
  /// The phone is a satellite of the computer: "if the hub updates a file, every satellite
  /// follows" (the founder, BUG-897). Each copy carries the hub version it was made from
  /// (`contentFingerprint`), set only when that is known, never from a value merely heard:
  ///
  /// - A copy with a made-from version: no version from the hub, nothing to do; a version of
  ///   another kind (the part before a colon; old ones have none) is the computer measuring
  ///   differently, adopted silently unless the hub's file is newer than the copy; the same
  ///   kind with another value is a changed song, fetched again.
  /// - A copy without one (every copy from before this, and every new add until vouched for):
  ///   with no file date from the hub yet, nothing, and no version is adopted for it; a hub
  ///   file newer than the copy means a re-rip the phone never got, fetched again; otherwise
  ///   the copy came from that very file and takes its version.
  ///
  /// A song fetched again keeps the old copy playing until the new one lands (BUG-882), only
  /// when the computer answers, at most `trackRefreshesPerSweep` a pass; it is stamped with the
  /// version it was fetched for as it lands. A failed download leaves the old song and the
  /// next sweep tries again.
  private func sweepTrackFreshnessIfDue() async {
    if let last = lastTrackFreshnessSweepAt,
       Date().timeIntervalSince(last) < Self.trackFreshnessMinInterval {
      return
    }
    guard let deviceId = UIDevice.current.identifierForVendor?.uuidString else { return }

    let manifest: CassetteTrackFreshnessResponse
    do {
      manifest = try await api.getTrackFreshness(deviceId: deviceId)
    } catch {
      print("Cassette poll: track-freshness manifest fetch failed - \(error.localizedDescription)")
      return
    }
    lastTrackFreshnessSweepAt = Date()

    let manager = DeviceOwnershipManager(context: AmperKit.shared.storage.main.context)
    // Once: the values the phone held were the first ones it heard, not what its copies were
    // made from, so every copy starts out unvouched for (BUG-897).
    if !UserDefaults.standard.bool(forKey: Self.madeFromResetKey) {
      do {
        let cleared = try manager.clearContentFingerprints()
        UserDefaults.standard.set(true, forKey: Self.madeFromResetKey)
        print("Cassette poll: track-freshness - \(cleared) copies to vouch for again")
      } catch {
        return
      }
    }

    var stamps: [(cassetteLocalId: String, fingerprint: String)] = []
    var changed: [(entry: CassetteTrackFreshnessEntry, version: String?, mbid: String?, ext: String)] = []
    for entry in manifest.tracks {
      guard let owned = try? manager.fetchOne(cassetteLocalId: entry.cassetteLocalId)
      else { continue } // not actually on this device, or the fetch failed — nothing to check
      let version = entry.audioVersion
      switch CassetteFreshness.decide(
        madeFrom: owned.contentFingerprint,
        version: version,
        fileCreatedAt: entry.fileCreatedAt,
        downloadedAt: owned.downloadedAt
      ) {
      case .wait:
        continue
      case let .vouch(made):
        stamps.append((entry.cassetteLocalId, made))
        continue
      case .fetchAgain:
        break
      }
      let ext = (owned.filePath as NSString).pathExtension
      guard !ext.isEmpty else { continue }
      changed.append((entry, version, owned.mbid, ext))
    }
    try? manager.stampContentFingerprints(stamps)

    // Away from home, or with the computer asleep, nothing changes: the songs stay as they are.
    var refreshing = 0
    if !changed.isEmpty, await isCassettePlayerReachable(),
       let accountInfo = AmperKit.shared.storage.settings.accounts.active {
      let backendApi = AmperKit.shared.getMeta(accountInfo).backendApi
      for change in changed.prefix(Self.trackRefreshesPerSweep) {
        guard let url = try? await backendApi
          .cassetteDownloadUrl(forSubsonicTrackId: change.entry.subsonicTrackId)
        else { continue }
        await transferSession.enqueueDownload(
          url: url,
          cassetteLocalId: change.entry.cassetteLocalId,
          mbid: change.mbid,
          subsonicTrackId: change.entry.subsonicTrackId,
          fileExtension: change.ext,
          intentId: "freshness-refresh",
          contentFingerprint: change.version
        )
        refreshing += 1
      }
    }
    if !stamps.isEmpty || !changed.isEmpty {
      print(
        "Cassette poll: track-freshness sweep — \(stamps.count) vouched for, \(changed.count) to fetch again, " +
          "\(refreshing) fetching (old copies kept until the new ones land)"
      )
    }
  }

  /// Set once the one-time forgetting of heard-but-unproven versions has run (BUG-897).
  private static let madeFromResetKey = "cassette.madeFrom.reset.v1"

  /// How many changed songs one sweep sends for again (sweeps run at most every
  /// five minutes), so a retag of a whole library comes across over a few hours
  /// instead of all at once.
  private static let trackRefreshesPerSweep = 50


  /// Apply the catalog-blind album grouping (Phase 1, Gap 1) the cloud returned
  /// on the inventory report: collapse owned songs onto their group-key albums so
  /// the device's albums match the web. Idempotent; runs on every sync that
  /// returns grouping. Records the applied model version for diagnostics.
  private func applyAlbumGrouping(_ response: CassetteDeviceInventoryResponse) async {
    guard !response.grouping.isEmpty else { return }
    guard let accountInfo = AmperKit.shared.storage.settings.accounts.active else { return }

    let context = AmperKit.shared.storage.main.context
    let summary = AlbumRegrouper(context: context).regroup(
      items: response.grouping,
      accountInfo: accountInfo
    )

    if AmperKit.shared.storage.settings.app.appliedGroupingModelVersion
      != response.groupingModelVersion {
      AmperKit.shared.storage.settings.app.appliedGroupingModelVersion =
        response.groupingModelVersion
    }

    // Covers are served by the native getCoverArt byte path (Navidrome → the
    // local-drive folder cover.jpg over the LAN): the regroup provisions each
    // album's Artwork with its native cover id (AlbumRegrouper), and the owned-
    // album backfill below enqueues the fetch. There is no catalog/R2 cover path.
    let ctx: [String: String] = [
      "version": String(response.groupingModelVersion),
      "groups": String(summary.groups),
      "moved": String(summary.movedSongs),
      "created": String(summary.createdAlbums),
      "createdSongs": String(summary.createdSongs),
      "purged": String(summary.purgedAlbums),
      "byLocalId": String(summary.matchedByLocalId),
      "skipped": String(summary.skipped),
      "provisioned": String(summary.coversProvisioned),
    ]
    DiagnosticLog.shared.log(.lifecycle, "album regroup", context: ctx)
    print("Cassette regroup: v\(response.groupingModelVersion) \(ctx)")
    os_log(
      "regroup v%d groups=%d moved=%d created=%d purged=%d byLocalId=%d skipped=%d provisioned=%d",
      log: self.log,
      type: .info,
      response.groupingModelVersion,
      summary.groups,
      summary.movedSongs,
      summary.createdAlbums,
      summary.purgedAlbums,
      summary.matchedByLocalId,
      summary.skipped,
      summary.coversProvisioned
    )

    // The regroup may have created new group-key albums (and SongMOs for owned
    // tracks that had no catalog record). Two follow-ups so they show up right,
    // in-place, without an app relaunch:
    //  1. Those albums are NOT in the library FRC's owned-album-id predicate (a
    //     snapshot from FRC setup), so they stay hidden until it's rebuilt — the
    //     "invisible until relaunch" symptom. The ownership notifier's observers
    //     rebuild the FRC with a fresh owned-album set.
    //  2. The cover backfill (backfillOwnedAlbumCovers) ran BEFORE the regroup
    //     this poll, so the just-created albums missed it and render coverless.
    //     Re-run it now (idempotent — skips albums that already have a local
    //     cover) so their covers fetch on this same sync.
    if summary.createdSongs > 0 || summary.createdAlbums > 0 {
      await MainActor.run { CassetteOwnershipNotifier.shared.ownershipDidChange() }
    }
    // Re-run the cover backfill (which ran BEFORE the regroup this poll) whenever
    // the regroup provisioned an album cover id — for newly-created albums OR
    // already-owned albums an earlier build left coverless — so their covers fetch
    // on this same sync. Idempotent: skips albums that already have a local cover,
    // and self-terminates once coversProvisioned falls to 0.
    if summary.coversProvisioned > 0 || summary.createdSongs > 0 {
      await backfillOwnedAlbumCovers(accountInfo: accountInfo)
    }
  }

  /// Fast Album Art backfill AND the per-poll cover-convergence heal.
  ///
  /// Albums already on the device whose cover was never fetched (transferred before
  /// cover-bundling, or never viewed) get filled here — and so do albums whose cover
  /// is BROKEN: a retired synthetic shell, or a `.CustomImage` row whose file is gone.
  /// Those used to be healable only by AlbumRegrouper.provisionNativeCover, which runs
  /// solely inside the inventory report — throttled, and skipped outright above 5000
  /// items — so on a normal 30s poll nothing converged and a black-band cover could
  /// persist indefinitely. This runs EVERY poll with no throttle and no cap, so it is
  /// the dependable path; the regroup is now belt-and-suspenders.
  ///
  /// For each owned album lacking a valid on-disk cover it PRESERVES the album's
  /// existing cover-art identity (an album legitimately carries al-<album>_<hex> while
  /// its songs carry al-<album>_0 — treating that difference as "needs re-pointing"
  /// re-pointed every album and caused a library-wide cover flash), replacing it only
  /// when it is empty or the retired type. It then clears any dead relFilePath, re-arms
  /// the status, and hands it to the artwork download manager: an actor-based,
  /// 2-wide-throttled, off-main queue that pulls the folder cover.jpg from the LAN
  /// Player's getCoverArt and lands the same `.CustomImage` end-state as a transfer
  /// (honoring artworkDownloadSetting and de-duping in-flight).
  ///
  /// Ownership: a user's PICKED cover (an override, keyed on the album's own id) is
  /// never re-pointed here — only ever re-materialized from their own override URL by
  /// backfillOwnedArtistImages. We fill what's missing; we never replace their choice.
  /// Idempotent: an album with a valid cover on disk is skipped and never written.
  private func backfillOwnedAlbumCovers(accountInfo: AccountInfo) async {
    // Never run before a manifest pass has succeeded this launch: without the pick set
    // this pass cannot distinguish a user's chosen cover from a folder cover, and it
    // would re-point and overwrite the pick. A delayed refresh is the cheaper failure.
    guard hasReadManifestThisLaunch else { return }
    // Snapshot the picked-album keys as an immutable value the @Sendable background
    // closure can capture. Empty on the very first poll of a launch (the manifest has
    // not been read yet), which is why handlePendingIntents runs the manifest pass
    // BEFORE this one.
    // Enumerate + gate OFF the main thread, on a background context.
    let artworkIDs: [NSManagedObjectID]
    do {
      artworkIDs = try await AmperKit.shared.storage.async.performAndGet { asyncCompanion in
        let context = asyncCompanion.context
        let albumIds = DeviceOwnershipManager(context: context).fetchOwnedAlbumIds()
        guard !albumIds.isEmpty else { return [NSManagedObjectID]() }

        let request: NSFetchRequest<AlbumMO> = AlbumMO.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", Array(albumIds))
        request.returnsObjectsAsFaults = false
        let albumMOs = (try? context.fetch(request)) ?? []

        let library = LibraryStorage(context: context)
        let account = library.getAccount(info: accountInfo)

        var ids = [NSManagedObjectID]()
        for albumMO in albumMOs {
          let album = Album(managedObject: albumMO)
          let existing = album.artwork

          // A RETIRED cover identity (the legacy "cassette-album" type) can NEVER be
          // refreshed: prepareDownload refuses it outright, so whatever bytes it last
          // cached are frozen forever — even though its file is PRESENT on disk at
          // artworks/cassette-album/<id>.png. Presence is not health.
          let isRetiredIdentity = existing?.remoteInfo.type == "cassette-album"

          // 1. Skip only an album that has a valid cover on disk AND an identity that
          //    can still be refreshed. Asking merely "is there a cover FILE?" is what
          //    froze these albums: a retired shell answers yes and is skipped forever,
          //    so it keeps serving a stale cover no matter how often the source changes.
          if !isRetiredIdentity, let aw = existing, aw.status == .CustomImage,
             let path = aw.imagePath,
             FileManager.default.fileExists(atPath: path) {
            continue
          }

          // 2. Narrow backstop only. An artwork keyed on the album's OWN id can be a
          //    pick materialized before this album had any cover-art id. It is NOT a
          //    reliable pick test — picks are normally written onto the album's
          //    existing song-keyed id, which is why guard 2b below (the manifest's
          //    cover_is_override) is the authoritative one.
          // Either type counts: rows materialized before the album path space existed
          // carry an empty type, ones minted since carry cassetteAlbumArtworkType.
          // Matching only the empty type here would stop recognizing NEW picks and
          // re-point them onto the folder cover — the very bug this guard prevents.
          if let aw = existing, !album.id.isEmpty,
             aw.remoteInfo.id == album.id,
             aw.remoteInfo.type.isEmpty || aw.remoteInfo.type == cassetteAlbumArtworkType {
            continue
          }

          // NOTE: picked albums are deliberately NOT skipped any more. This used to
          // exclude them so the folder cover could not replace a pick — correct while
          // a pick existed only in the cloud. The hub now writes the pick INTO
          // cover.jpg, so the folder cover IS the pick, and skipping these albums
          // would exclude them from the only path that can deliver it.

          // 3. The native folder-cover key: an owned song's Subsonic id with an EMPTY
          //    type — exactly what the regroup provisions and what getCoverArt serves
          //    the LAN folder cover.jpg on. Type is forced empty so a synthetic-typed
          //    song artwork can never re-poison the album into a prepareDownload refusal.
          // KEEP a usable existing identity. An album legitimately carries its OWN
          // cover-art id (al-<album>_<hex>) while its songs carry al-<album>_0 — both
          // resolve to the same folder cover, so treating "different from the song's"
          // as "needs re-pointing" re-pointed EVERY album, cleared its path, and forced
          // a full re-download: the cover-flash-on-every-update. Only replace an
          // identity that genuinely cannot be fetched (empty, or the retired type).
          let existingInfo = existing?.remoteInfo
          let identityUnusable = (existingInfo?.id.isEmpty ?? true) || isRetiredIdentity
          let native: ArtworkRemoteInfo
          if identityUnusable {
            // Only now do we need a song: minting an identity is the ONLY use for it,
            // and requiring one up front skipped albums whose identity was perfectly
            // usable and merely needed re-enqueueing.
            guard let song = album.songs.first(where: { !$0.id.isEmpty }) else { continue }
            let songArtworkId = song.artwork?.remoteInfo.id ?? ""
            // Song's cover-art ID (fetches the folder cover), album's own path
            // space — see cassetteAlbumArtworkType. Must match AlbumRegrouper.
            native = ArtworkRemoteInfo(
              id: songArtworkId.isEmpty ? song.id : songArtworkId,
              type: cassetteAlbumArtworkType
            )
          } else {
            native = existingInfo!
          }

          let artwork = existing ?? library.createArtwork(account: account)
          // 4. Re-point + re-arm ONLY when something actually changes, so an album whose
          //    cover genuinely can't be fetched (Mac off-LAN, no folder cover.jpg) does
          //    not flip status and re-save on every 30s poll forever. A row already on
          //    the native id whose last fetch failed keeps .FetchError — the download
          //    manager retries those — we simply re-enqueue it below.
          let needsRepoint = artwork.remoteInfo != native
          let hasDeadPath = artwork.relFilePath != nil && artwork.imagePath == nil
          if needsRepoint || hasDeadPath {
            if needsRepoint { artwork.remoteInfo = native }
            if artwork.status != .FetchError { artwork.status = .NotChecked }
            if artwork.relFilePath != nil { artwork.relFilePath = nil }
            album.artwork = artwork
            // A freshly created artwork still carries a TEMPORARY objectID here, which
            // the main-context re-wrap below could not resolve — the download would be
            // silently dropped. performAndGet saves after this body, so force it now.
            try? context.obtainPermanentIDs(for: [artwork.managedObject])
          }
          ids.append(artwork.managedObject.objectID)
        }
        return ids
      }
    } catch {
      return
    }
    guard !artworkIDs.isEmpty else { return }

    // Re-wrap on the main context (cheap object-id lookups) and enqueue. The
    // download manager itself runs the fetches off-main, throttled, idempotent.
    let mainContext = AmperKit.shared.storage.main.context
    let artworks = artworkIDs.compactMap { id -> Artwork? in
      guard let mo = try? mainContext.existingObject(with: id) as? ArtworkMO else { return nil }
      return Artwork(managedObject: mo)
    }
    // Back off covers just attempted. An album whose cover the hub can't serve (off-LAN,
    // or none exists) is re-collected here on every poll; without this gate it re-downloads
    // every 30s forever. Keyed by the artwork's stable objectID. A newly-missing cover is
    // absent from the map, so it still fetches on the next poll.
    let eligible = artworks.filter {
      mayRetryArtwork("albumcover:" + $0.managedObject.objectID.uriRepresentation().absoluteString)
    }
    guard !eligible.isEmpty else { return }
    print("Cassette poll: backfilling covers for \(eligible.count) owned album(s)")
    AmperKit.shared.getMeta(accountInfo).artworkDownloadManager.download(objects: eligible)
  }

  /// cassette §art-collapse: one-time re-tier heal. Walks the account's artworks
  /// directory and generates the ~480px thumb for any full cover that predates
  /// tiering. Idempotent (CoverImageStore.ensureThumb skips covers that already
  /// have a thumb) and entirely off-main, so it's safe to reconcile every sync.
  private func backfillCoverThumbnails(accountInfo: AccountInfo) async {
    guard let artworksDir = CacheFileManager.shared
      .getOrCreateAbsoluteArtworksDirectory(for: accountInfo)
    else { return }
    await Task.detached(priority: .utility) {
      guard let entries = try? FileManager.default.contentsOfDirectory(
        at: artworksDir,
        includingPropertiesForKeys: nil
      ) else { return }
      var healed = 0
      for url in entries {
        // SKIP DIRECTORIES. Typed artwork nests under artworks/<type>/<id>.png, so this
        // listing also returns the "cassette-album" and "artist" SUBDIRECTORIES. Feeding
        // a directory to the thumbnailer can never produce a thumb, so it was retried on
        // every single poll forever — the endless "re-tiered 2 existing cover(s)" plus
        // the "can't open ... (fileExists == false)" spam, which looked like broken
        // covers but was entirely self-inflicted noise from this loop.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { continue }
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        if stem.hasSuffix("_thumb") { continue } // skip thumbs themselves
        if FileManager.default
          .fileExists(atPath: CoverImageStore.thumbPath(forFullPath: url.path)) {
          continue
        }
        CoverImageStore.ensureThumb(forFullPath: url.path)
        healed += 1
      }
      if healed > 0 {
        print("Cassette: re-tiered \(healed) existing cover(s)")
      }
    }.value
  }

  /// Fast Album Art backfill + refresh-on-change (content reconciliation
  /// increment 2): the album-cover backfill's sibling for both the album
  /// ARTIST image and the album COVER. Albums already on the device — synced
  /// before artist-image bundling, or whose artwork was never materialized, or
  /// whose catalog artwork has since CHANGED — get the album artist's catalog
  /// photo and the album cover here, with no remove/re-add. Strictly READ-ONLY:
  /// it reads only the already-stored manifest the server returns for the
  /// device's owned albums and never triggers an upstream enrichment.
  ///
  /// Change detection is driven by the manifest's `content_version` (a hash of
  /// the artwork URLs), compared against a small per-album applied-version store
  /// in UserDefaults (see `appliedArtworkVersion`). For each manifest album we
  /// compute its albumKey and read the stored version:
  ///   - stored == nil (first run): materialize once, record the version.
  ///   - stored != manifest.contentVersion (changed): force-materialize the
  ///     artist image (bypassing the on-disk idempotent gate so the changed bytes
  ///     overwrite the old file), then record the version.
  ///   - stored == manifest.contentVersion (unchanged): skip entirely — cheap.
  ///
  /// Off the main actor for the enumeration/matching, throttled the same way
  /// (once per poll, after the cover backfill). Skips cleanly with no bearer
  /// token / account.
  private func backfillOwnedArtistImages(accountInfo: AccountInfo) async {
    guard CassetteSyncAPI.bearerToken != nil else { return }

    // Throttle the manifest fetch: refetch on the FIRST pass this launch, when the
    // owned set CHANGES (a transfer/removal → new art to resolve), or after the
    // interval (to catch a cloud-side enrichment or a new pick). Otherwise skip — the
    // per-transfer Fast Album Art already arms a brand-new album's art, and
    // backfillOwnedAlbumCovers heals missing covers from disk regardless. This turns
    // the every-30s manifest GET into roughly one per 5 min at rest while still
    // converging instantly on a real library change. `hasReadManifestThisLaunch`
    // stays sticky once set, so the folder-cover pass below is never starved.
    let ownedCount = DeviceOwnershipManager(context: AmperKit.shared.storage.main.context)
      .fetchAllSubsonicTrackIds().count
    let manifestDue = !hasReadManifestThisLaunch
      || ownedCount != lastManifestOwnedCount
      || (lastArtworkManifestAt.map {
        Date().timeIntervalSince($0) >= Self.artworkManifestMinInterval
      } ?? true)
    guard manifestDue else { return }

    // Sendable value types so the @Sendable background closure captures only
    // immutable, concurrency-safe state. A candidate carries the manifest's
    // artwork URLs (either may be nil) + the album's content version.
    struct ManifestCandidate: Sendable {
      let artist: String
      let albumKey: String
      let artistImageUrl: String?
      /// The same photo's top ladder rung, tried first (artistImageUrl stays its identity).
      let artistImageLadderUrl: String?
      let coverUrl: String?
      let coverIsOverride: Bool
      /// Folder-cover byte fingerprint from the Mac; nil when the album has a user pick.
      let localCoverVersion: String?
      let contentVersion: String
    }

    // 1. Server manifest: the album artist's catalog image + the album cover,
    //    per owned album. Keyed by normalized album name → [candidate] so a
    //    device album resolves even when its local artist string differs from
    //    the catalog one we keyed the image on. We keep EVERY album (even one
    //    with no image URLs) so a cover-only change still refreshes and the
    //    version is recorded.
    let manifest: CassetteDeviceArtworkResponse
    do {
      manifest = try await api.getDeviceArtwork(deviceId: CassetteSyncAPI.deviceId)
    } catch {
      print("Cassette poll: artwork manifest fetch failed - \(error.localizedDescription)")
      return
    }
    // Stamp only on success, so a failed fetch retries next poll rather than idling
    // out the interval.
    lastArtworkManifestAt = Date()
    lastManifestOwnedCount = ownedCount
    var manifestByAlbum = [String: [ManifestCandidate]]()
    for album in manifest.albums {
      let albumNorm = Self.normalizeForVersionKey(album.albumName)
      let artistNorm = Self.normalizeForVersionKey(album.artistName)
      let imageUrl = (album.artistImageUrl?.isEmpty == false) ? album.artistImageUrl : nil
      let ladderUrl = imageUrl == nil ? nil : album.artistImage?.url(rung: CoverImageStore.topRung)
      let coverUrl = (album.coverUrl?.isEmpty == false) ? album.coverUrl : nil
      manifestByAlbum[albumNorm, default: []].append(ManifestCandidate(
        artist: artistNorm,
        albumKey: Self.albumVersionKey(artist: album.artistName, album: album.albumName),
        artistImageUrl: imageUrl,
        artistImageLadderUrl: ladderUrl,
        coverUrl: coverUrl,
        coverIsOverride: album.coverIsOverride ?? false,
        localCoverVersion: (album.localCoverVersion?.isEmpty == false)
          ? album.localCoverVersion : nil,
        contentVersion: album.contentVersion
      ))
    }
    guard !manifestByAlbum.isEmpty else { return }
    // Bind to a `let` so the @Sendable background closure captures an immutable
    // (and Sendable) value rather than a captured `var`.
    let byAlbum = manifestByAlbum

    // 2. Off-main: group owned songs by album, match each device album to its
    //    manifest candidate (same album-name lookup + artist disambiguation as
    //    before), and collect a worklist carrying the manifest's artwork URLs,
    //    version, and albumKey alongside the resolved subsonicIds. No on-disk
    //    gate here — change detection is the version compare on the main actor.
    struct ArtworkJob: Sendable {
      let albumKey: String
      let contentVersion: String
      let artistImageUrl: String?
      let artistImageLadderUrl: String?
      let coverUrl: String?
      let coverIsOverride: Bool
      let localCoverVersion: String?
      let subsonicIds: [String]
    }
    let jobs: [ArtworkJob]
    do {
      jobs = try await AmperKit.shared.storage.async.performAndGet { asyncCompanion in
        let context = asyncCompanion.context
        let trackIds = DeviceOwnershipManager(context: context).fetchAllSubsonicTrackIds()
        guard !trackIds.isEmpty else { return [ArtworkJob]() }

        let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", Array(trackIds))
        request.returnsObjectsAsFaults = false
        let songMOs = (try? context.fetch(request)) ?? []

        // Group the owned tracks by their album's identity.
        var subsonicIdsByAlbum = [String: [String]]()
        var albumNameByKey = [String: String]()
        var artistNamesByKey = [String: Set<String>]()
        for songMO in songMOs {
          let song = Song(managedObject: songMO)
          let songId = songMO.id
          guard !songId.isEmpty,
                let albumName = songMO.album?.name, !albumName.isEmpty else { continue }
          let artistName = songMO.artist?.name ?? ""
          // Album bucket key: album name + the album's own artist if linked,
          // else the track artist — enough to keep distinct albums apart while
          // matching the manifest's album-name lookup.
          let albumArtist = song.album?.artist?.name ?? artistName
          let key = "\(albumName.lowercased())\u{0}\(albumArtist.lowercased())"
          subsonicIdsByAlbum[key, default: []].append(songId)
          albumNameByKey[key] = albumName
          artistNamesByKey[key, default: []].insert(artistName.lowercased())
          artistNamesByKey[key]?.insert(albumArtist.lowercased())
        }

        var result = [ArtworkJob]()
        for (key, subsonicIds) in subsonicIdsByAlbum {
          guard let albumName = albumNameByKey[key] else { continue }
          let lookupKey = Self.normalizeForVersionKey(albumName)
          guard let candidates = byAlbum[lookupKey], !candidates.isEmpty else { continue }

          // Prefer a candidate whose artist matches one of this album's artist
          // strings; otherwise, if there's exactly one candidate for the album
          // name, use it (unambiguous).
          let artists = artistNamesByKey[key] ?? []
          let chosen = candidates.first(where: { artists.contains($0.artist) })
            ?? (candidates.count == 1 ? candidates.first : nil)
          guard let chosen else { continue }
          result.append(ArtworkJob(
            albumKey: chosen.albumKey,
            contentVersion: chosen.contentVersion,
            artistImageUrl: chosen.artistImageUrl,
            artistImageLadderUrl: chosen.artistImageLadderUrl,
            coverUrl: chosen.coverUrl,
            coverIsOverride: chosen.coverIsOverride,
            localCoverVersion: chosen.localCoverVersion,
            subsonicIds: subsonicIds
          ))
        }
        return result
      }
    } catch {
      return
    }
    // Exact pick set: the SUBSONIC TRACK IDS of albums the cloud says carry a user
    // pick. Deliberately not a name key — the album-name match here is deliberately
    // tolerant of catalog-vs-local drift ("Abbey Road" vs "Abbey Road (Remastered)"),
    // and re-deriving a stricter key downstream would silently stop protecting picks.
    hasReadManifestThisLaunch = true
    guard !jobs.isEmpty else { return }

    // 3. Main actor: version-gate each job. Unchanged → skip (cheap). Changed
    //    or first-run → force-materialize both artworks, then record the
    //    version so the next poll no-ops. De-dupe by albumKey in case two
    //    device buckets resolved to the same manifest album.
    var appliedThisPass = Set<String>()
    var refreshed = 0
    var forcedCoverPulls = 0
    var adoptedWithoutPull = 0
    // Pick adoption is network work too — bound it like the folder pulls, so a
    // library full of picks cannot fire dozens of serial downloads on one launch.
    // Evaluated ONCE: the loop below writes both maps this decision reads.
    let freshInstall = isFreshCoverInstall
    // Artist-photo source depends on mode, fixed for the pass so read once: an
    // on-device library anchors artists to a cloud identity and takes their face from
    // the catalog (R2) via job.artistImageUrl; Server Mode uses the real Navidrome
    // artist + getCoverArt.
    let onDeviceOnly = CassetteLibraryFilterProvider.shared.isOnDeviceOnly
    // Forced folder-cover pulls go over the LAN to the paired Mac. Off-LAN, each one
    // is a serial awaited request that converges nothing and holds the poll's
    // single-flight lock, blocking the next poll's intents and removals. Probe ONCE
    // and skip those pulls for this pass. Cloud-hosted work (artist images, picks)
    // still runs — only the LAN-dependent step is gated.
    var canReachPlayer: Bool?
    for job in jobs {
      if appliedThisPass.contains(job.albumKey) { continue }
      let stored = appliedArtworkVersion(forAlbumKey: job.albumKey)

      // The album's FOLDER cover bytes changed on the Mac. This is THE signal for the
      // art changing — a swapped cover.jpg moves no cloud URL, so content_version
      // structurally cannot see it and the phone would keep its first-fetched art
      // forever.
      //
      // No longer gated on !coverIsOverride. That gate existed because a pick lived
      // only in the cloud, so letting the folder win would have taken the user's
      // cover back. A pick is now WRITTEN INTO the folder, so the folder IS the pick
      // and this is the path by which a pick reaches the phone at all. Keeping the
      // gate would have permanently excluded picked albums from the only mechanism
      // that can update them.
      let localCover: String? = job.localCoverVersion
      let storedCoverFp = appliedCoverFingerprint(forAlbumKey: job.albumKey)
      let coverBytesChanged = localCover != nil && localCover != storedCoverFp

      // FRESH INSTALL: nothing on this device can be stale, because the ordinary
      // backfill has just fetched every cover from the same source the fingerprint
      // describes. Adopt the fingerprint silently instead of re-downloading the
      // whole library byte-for-byte. An UPGRADING device keeps the re-pull, because
      // there its covers genuinely predate the signal and may be stale.
      if coverBytesChanged, storedCoverFp == nil, freshInstall, let localCover {
        setAppliedCoverFingerprint(localCover, forAlbumKey: job.albumKey)
        adoptedWithoutPull += 1
        continue
      }

      // Bounded per pass: re-pulling a whole library serially on the main actor
      // would stall the app. A cap converges over a few polls instead, and the
      // compare is idempotent so the remainder simply rolls to the next one.
      var mayPullCover = coverBytesChanged && forcedCoverPulls < Self.maxForcedCoverPullsPerPass
      if mayPullCover {
        if canReachPlayer == nil { canReachPlayer = await isCassettePlayerReachable() }
        if canReachPlayer != true { mayPullCover = false }
      }

      // A LOCALLY broken artist image — a shared row, the wrong identity, or missing
      // bytes — must be repairable without the catalog having changed. What "broken"
      // means depends on the mode:
      //  • on-device: the anchored artist's face comes from the catalog (R2), so it's
      //    broken when a catalog URL exists yet its bytes aren't on disk yet. An
      //    artist we hold NO catalog image for is not broken — it just has no face
      //    (the hub-folder photo over the LAN is Phase 3), so it never re-fires.
      //  • Server Mode: the getCoverArt/folder photo — the existing health check.
      // The one-time square-heal forces a re-pull of every artist photo (both
      // modes) so images stored padded-to-square before the aspect-aware fix are
      // replaced at natural aspect and finally fill the circle.
      let squareHealPending = artistImageSquareHealPending
      let artistImageBroken = onDeviceOnly
        ? (
          job.artistImageUrl != nil
            && (squareHealPending || onDeviceArtistPhotoMissing(subsonicIds: job.subsonicIds))
        )
        : (
          artistImageSourceMigrationPending
            || squareHealPending
            || !hasHealthyArtistImage(subsonicIds: job.subsonicIds)
        )

      let versionChanged = stored != job.contentVersion
      guard versionChanged || mayPullCover || artistImageBroken else { continue }
      let force = stored != nil // first-run materializes once (no force needed)

      // Route the artist photo by mode. On-device: the anchored identity's face is the
      // catalog primary (job.artistImageUrl), downloaded straight from R2 onto the
      // identity artist — never getCoverArt, which can only 404 for a cloud id. Server
      // Mode: the real Navidrome artist via getCoverArt, exactly as before.
      if onDeviceOnly {
        if let imageUrl = job.artistImageUrl, versionChanged || artistImageBroken {
          // A version change always re-pulls; a missing photo with no version change is
          // throttled so an artist mid-fetch isn't hammered. Idempotent inside.
          let mayRepair = versionChanged || mayRetryArtwork("artistimg:" + job.albumKey)
          if mayRepair {
            await materializeArtistImageFromUrl(
              subsonicIds: job.subsonicIds,
              imageUrl: imageUrl,
              ladderUrl: job.artistImageLadderUrl,
              accountInfo: accountInfo,
              // The heal must overwrite the existing padded-square file, so it
              // forces past materialize's idempotent "already on disk" gate.
              force: versionChanged || squareHealPending
            )
          }
        }
        // No catalog face for an on-device identity artist → no getCoverArt fallback
        // (it can only 404 here); leave the placeholder until the LAN folder photo
        // path lands (Phase 3, BUG-078).
      } else if versionChanged || artistImageBroken {
        // A version change always re-fetches. A "broken" image with no version change
        // reads as broken every poll and would re-fetch forever — so throttle that path.
        let mayRepair = versionChanged || mayRetryArtwork("artistimg:" + job.albumKey)
        if mayRepair {
          if artistImageBroken, !versionChanged {
            print("Cassette poll: repairing artist image - '\(job.albumKey)'")
          }
          await materializeArtistImage(
            subsonicIds: job.subsonicIds,
            accountInfo: accountInfo,
            // A broken row must be replaced even though the catalog is unchanged;
            // the idempotent gate inside would otherwise keep the poisoned file.
            force: force || artistImageBroken
          )
        }
      }
      // NOTE: there is deliberately NO cloud pick-adoption here any more. A cover the
      // user picks is written into their folder cover.jpg by the hub, so it reaches
      // this device through the folder-cover path below like any other change. The
      // phone downloading picks straight from the cloud made it a SECOND writer to
      // the same cache file, fighting the folder cover on every launch, and left the
      // art depending on a live fetch to the archive that intermittently fails.
      // Folder cover changed on the Mac → re-pull it over the LAN and swap it in.
      // Stamped ONLY on confirmed success: if the Mac is unreachable we must leave
      // the fingerprint unstamped so the next poll retries, rather than recording a
      // refresh that never happened and pinning the album to stale art.
      if mayPullCover, let localCover {
        forcedCoverPulls += 1
        let ok = await forceRefreshNativeCover(
          subsonicIds: job.subsonicIds,
          accountInfo: accountInfo,
          cacheBust: localCover
        )
        if ok {
          setAppliedCoverFingerprint(localCover, forAlbumKey: job.albumKey)
          print("Cassette poll: folder cover refreshed - '\(job.albumKey)'")
        }
      }
      // Record the applied version after the best-effort refreshes above.
      if versionChanged {
        setAppliedArtworkVersion(job.contentVersion, forAlbumKey: job.albumKey)
      }
      appliedThisPass.insert(job.albumKey)
      refreshed += 1
    }
    pruneAppliedMaps(keeping: Set(jobs.map { $0.albumKey }))
    markCoverSignalSeen()
    if adoptedWithoutPull > 0 {
      print(
        "Cassette poll: adopted \(adoptedWithoutPull) cover fingerprint(s) without re-pulling (fresh install)"
      )
    }
    if refreshed > 0 { artworkDidWorkThisPass = true }
    if refreshed > 0 {
      print("Cassette poll: refreshed artwork for \(refreshed) owned album(s)")
    }
    // The whole manifest was walked, so every artist image has now been re-pointed
    // at the hub (or found to have nothing there). Stamped only HERE — stamping it
    // earlier, or on a pass that bailed out, would leave devices half-migrated with
    // no way to notice.
    if artistImageSourceMigrationPending { markArtistImageSourceMigrated() }
    if artistImageSquareHealPending { markArtistImageSquareHealed() }
  }

  // MARK: - Sync freshness (account-menu status line)

  /// Wall-clock time of the last successful poll round-trip to cassette.digital,
  /// persisted in UserDefaults so it survives relaunch (unlike the per-launch
  /// in-memory `lastFullInventoryReportAt`). The account menu renders this as a
  /// relative "Synced 5m ago" line. `nonisolated`/`static` so a UI surface can
  /// read it cheaply and synchronously off the main actor without touching the
  /// executor's actor-isolated state.
  nonisolated private static let lastSyncAtKey = "cassette.lastSyncAt"

  nonisolated public static var lastSyncAt: Date? {
    let t = UserDefaults.standard.double(forKey: lastSyncAtKey)
    return t > 0 ? Date(timeIntervalSince1970: t) : nil
  }

  nonisolated static func recordSuccessfulSync() {
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSyncAtKey)
  }

  /// Fetch + persist the caller's account identity (name/email) once per
  /// launch, so the account menu leads with the user's Cassette account name
  /// (or email) instead of the paired Player's hostname. Best-effort: a
  /// failure just leaves the last-persisted value (or "Connected" before any
  /// fetch) and retries next launch. `getAccount()` persists internally.
  private func refreshAccountIfDue() async {
    // Throttle to once per 30s (the poll cadence): re-fetches on foreground and
    // roughly every poll, so an avatar / skin / server-mode change on another
    // device lands within ~30s here, while a hot loop can't hammer the endpoint.
    if let last = lastAccountRefreshAt, Date().timeIntervalSince(last) < 30 { return }
    do {
      // persistAccount (inside getAccount) applies every field and posts
      // cassetteAccountAvatarChanged if the avatar moved, so the chip repaints.
      let account = try await api.getAccount()
      lastAccountRefreshAt = Date()
      print("Cassette poll: account refreshed (\(account.name ?? account.email))")
    } catch {
      // Leave lastAccountRefreshAt unchanged so the next poll retries.
      print("Cassette poll: account fetch failed - \(error.localizedDescription)")
    }
  }

  // MARK: - Applied-artwork-version store (refresh-on-change)

  /// Per-album last-applied `content_version`, persisted in UserDefaults as a
  /// `[albumKey: version]` map. Lets the backfill detect when an album's
  /// catalog artwork has CHANGED (version differs) versus is merely absent, so
  /// a changed cover/artist photo refreshes on-device without a remove/re-add.
  private static let appliedArtworkVersionsKey = "cassette.appliedArtworkVersions"

  /// The version-store key for a manifest album. Reuses the same per-field
  /// normalization the manifest↔device matching uses (lowercased + whitespace-
  /// trimmed), joined with a NUL so "<artist><NUL><album>" can't collide with a
  /// differently-split pair. Same (artist, album) ⇒ same key on every poll.
  /// `nonisolated` so the off-main enumeration closure can call it.
  nonisolated private static func albumVersionKey(artist: String, album: String) -> String {
    "\(normalizeForVersionKey(artist))\u{0}\(normalizeForVersionKey(album))"
  }

  /// Lowercase + whitespace-trim — the exact normalization the manifest lookup
  /// already applies to album/artist names. `nonisolated` so the off-main
  /// enumeration closure can call it.
  nonisolated private static func normalizeForVersionKey(_ value: String) -> String {
    value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func appliedArtworkVersion(forAlbumKey albumKey: String) -> String? {
    let map = UserDefaults.standard
      .dictionary(forKey: Self.appliedArtworkVersionsKey) as? [String: String]
    return map?[albumKey]
  }

  private func setAppliedArtworkVersion(_ version: String, forAlbumKey albumKey: String) {
    var map = (
      UserDefaults.standard
        .dictionary(forKey: Self.appliedArtworkVersionsKey) as? [String: String]
    ) ?? [:]
    map[albumKey] = version
    UserDefaults.standard.set(map, forKey: Self.appliedArtworkVersionsKey)
  }

  /// Per-album last-applied FOLDER-COVER fingerprint (`local_cover_version`), kept in
  /// UserDefaults as an [albumKey: fingerprint] map.
  ///
  /// Deliberately DISJOINT from the content_version store: a cloud catalog/pick change
  /// and a Mac folder-cover swap are different events with different sources of truth,
  /// and letting either overwrite the other's stamp would make one of them undetectable.
  /// Written ONLY after a confirmed successful re-pull.
  private static let appliedCoverFingerprintsKey = "cassette.appliedCoverFingerprints"

  /// Per-album last-applied USER PICK url (the manifest's cover_url, already
  /// cache-busted with the pick's updatedAt, so it changes whenever the pick changes).
  /// Gates pick adoption on the PICK itself rather than on content_version: an album
  /// whose content_version was stamped long ago would otherwise never adopt a newer
  /// pick, and could sit forever showing the folder cover instead of the user's choice.
  /// Whether every ALBUM ARTIST behind these tracks has a usable image of its OWN.
  ///
  /// "Usable" means an artwork row this artist does not SHARE. A shared row is how a
  /// featured artist ends up wearing the album artist's face (Laufey rendering Bon
  /// Iver): one Artwork object attached to two artists, so whichever the surface
  /// reads renders the same picture. That is a local identity fault — wrong no matter
  /// where the bytes came from — and `materializeArtistImage` already knows how to
  /// repair it by minting the artist its own row.
  ///
  /// The repair just could never RUN: it sat behind `versionChanged`, and an artist
  /// whose catalog entry has not moved in months never trips that, so a device
  /// carrying a shared row kept the wrong face indefinitely. A heal gated on "did the
  /// SOURCE change?" cannot fix state that is broken LOCALLY.
  ///
  /// Deliberately checks only ALBUM artists (the entity the cloud keys the image on
  /// and the one materializeArtistImage targets). Flagging a song-only featured
  /// artist would request a repair that never comes and re-trigger every poll.
  private func hasHealthyArtistImage(subsonicIds: [String]) -> Bool {
    guard !subsonicIds.isEmpty else { return true }
    let context = AmperKit.shared.storage.main.context
    var healthy = true
    context.performAndWait {
      let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      request.predicate = NSPredicate(format: "id IN %@", subsonicIds)
      request.returnsObjectsAsFaults = false
      let songMOs = (try? context.fetch(request)) ?? []

      var seenArtists = Set<NSManagedObjectID>()
      for songMO in songMOs {
        guard let artist = Song(managedObject: songMO).album?.artist else { continue }
        guard seenArtists.insert(artist.managedObject.objectID).inserted else { continue }
        // An artist keyed on an id the hub can't resolve — an on-device synthetic id
        // or a cloud identity key — can only 404 on getCoverArt. There is no hub photo
        // to fetch that way (the sidecar proxy handles it), and flagging it would ask
        // for the same failure every poll.
        if Self.isUnfetchableArtistId(artist.id) { continue }

        guard let artwork = artist.artwork else { healthy = false; return }
        // Shared with another owner → poisoned, whoever it currently renders as.
        if (artwork.managedObject.owners?.count ?? 0) > 1 { healthy = false; return }
        // A fetch that ALREADY FAILED is settled, not broken — the hub simply has no
        // photo for this artist. The download manager retries on its own schedule;
        // re-flagging here just re-requests a known 404 forever, which is exactly the
        // "repair that never comes" loop this check was written to avoid.
        if artwork.status == .FetchError { continue }
        // RIGHT IDENTITY, not merely a usable one. An artwork still keyed on the old
        // cloud-image identity is perfectly "healthy" — own row, .CustomImage, file
        // present — while holding a photo of somebody else entirely, which is exactly
        // how Laufey kept Bon Iver's face through several fixes. Only (artist id,
        // "artist") resolves to the artist folder's own artist.* on the hub, so
        // anything else is stale by definition and must be re-pointed.
        if !artist.id.isEmpty,
           artwork.remoteInfo != ArtworkRemoteInfo(id: artist.id, type: "artist") {
          healthy = false
          return
        }
        guard artwork.status == .CustomImage,
              let path = artwork.imagePath,
              FileManager.default.fileExists(atPath: path)
        else { healthy = false; return }
      }
    }
    return healthy
  }

  /// Prefix of an artist id minted ON DEVICE (see AlbumRegrouper). Navidrome has
  /// never seen these, so they can never resolve to a hub photo.
  nonisolated private static let syntheticArtistIDPrefix = "cassette-synth-artist:"

  /// True for any artist id the hub's getCoverArt can NEVER resolve — an on-device
  /// synthetic id OR a cloud identity key (`inherited-artist:` / `catalog-artist:`,
  /// the artist_group_key the regroup now anchors to). getCoverArt can only 404 for
  /// these, so the getCoverArt repair path (materializeArtistImage / hasHealthyArtistImage)
  /// must skip them or it re-requests a guaranteed 404 forever (the "repair that never
  /// comes" loop). Their real photo is now sourced (Phase 2) from the catalog primary
  /// (R2) that the artwork manifest delivers as `artist_image_url`, downloaded straight
  /// onto the identity artist by `materializeArtistImageFromUrl` in on-device mode —
  /// never through getCoverArt. An artist with no catalog face still shows a placeholder
  /// until the LAN hub-folder photo path lands (Phase 3, BUG-078).
  // nonisolated: a pure prefix check over immutable constants, so the artwork
  // download delegate can call it from its background Core Data closure (the
  // CarPlay-replug getCoverArt guard) without hopping to the main actor.
  nonisolated static func isUnfetchableArtistId(_ id: String) -> Bool {
    id.hasPrefix(syntheticArtistIDPrefix)
      || id.hasPrefix("inherited-artist:")
      || id.hasPrefix("catalog-artist:")
  }

  /// One-time re-fetch of every artist image after the SOURCE changed from the cloud
  /// to the hub's artist folder.
  ///
  /// The identity check alone cannot catch these: the previous code already used
  /// (artist id, "artist") as the identity, and merely filled it with bytes
  /// downloaded from R2. So a device holds a row that is correctly identified,
  /// correctly unshared, present on disk — and showing the wrong person. Nothing
  /// about its shape reveals that, which is why Laufey survived every earlier fix.
  /// Changing where bytes come from means the bytes themselves must be re-pulled once.
  private var artistImageSourceMigrationPending: Bool {
    !UserDefaults.standard.bool(forKey: "cassette.artistImageSourceMigrationV1")
  }

  private func markArtistImageSourceMigrated() {
    UserDefaults.standard.set(true, forKey: "cassette.artistImageSourceMigrationV1")
    print("Cassette: artist images re-sourced from the hub")
  }

  /// One-time re-fetch of every artist image after the art-collapse squaring was
  /// made aspect-aware. Existing artist photos were stored padded to square (the
  /// full file overwritten, the thumb squared), which no display contentMode can
  /// crop — the brand-black bars showed inside the circle. Re-tiering alone can't
  /// heal them (the padded full is all that's left on disk), so the bytes must be
  /// re-pulled once at natural aspect. Mirrors artistImageSourceMigrationV1.
  private var artistImageSquareHealPending: Bool {
    !UserDefaults.standard.bool(forKey: "cassette.artistImageSquareHealV2")
  }

  private func markArtistImageSquareHealed() {
    UserDefaults.standard.set(true, forKey: "cassette.artistImageSquareHealV2")
    print("Cassette: artist images re-fetched at natural aspect")
  }

  /// One-time-per-launch sweep of stale artwork downloads whose target artist id
  /// getCoverArt can NEVER resolve (inherited-artist:/catalog-artist:/cassette-synth-
  /// artist:). Such a request left in the queue by an older build oscillates
  /// failed → reset → retry forever (getAndResetFailedDownloads re-arms any errored
  /// download), so prepareDownload's guard keeps firing a guaranteed 404 every cycle.
  /// These artists take their photo from the catalog (R2) via
  /// materializeArtistImageFromUrl, never getCoverArt, so the queued request is pure
  /// residue — delete it via the same background-context path the download queue's own
  /// clearFinishedDownloads uses. Idempotent; once cleared, none remain.
  private func sweepStaleUnfetchableArtistDownloadsIfNeeded() async {
    guard !didSweepStaleArtistDownloadsThisLaunch else { return }
    didSweepStaleArtistDownloadsThisLaunch = true
    let removed = (
      try? await AmperKit.shared.storage.async
        .performAndGet { asyncCompanion -> Int in
          let request: NSFetchRequest<DownloadMO> = DownloadMO.fetchRequest()
          request.predicate = NSPredicate(
            format: "artwork != nil AND artwork.type == %@ AND "
              +
              "(artwork.id BEGINSWITH %@ OR artwork.id BEGINSWITH %@ OR artwork.id BEGINSWITH %@)",
            "artist", "cassette-synth-artist:", "inherited-artist:", "catalog-artist:"
          )
          let stale = (try? asyncCompanion.context.fetch(request)) ?? []
          for downloadMO in stale {
            asyncCompanion.library.deleteDownload(Download(managedObject: downloadMO))
          }
          if !stale.isEmpty { asyncCompanion.saveContext() }
          return stale.count
        }
    ) ?? 0
    if removed > 0 {
      print("Cassette poll: cleared \(removed) stale unfetchable-artist download request(s)")
    }
  }

  private static let appliedOverrideCoversKey = "cassette.appliedOverrideCovers"

  /// Set once this install has completed a full artwork-manifest pass.
  private static let coverSignalSeenKey = "cassette.coverSignalSeen"

  /// Whether this album currently has a decodable cover file on disk. Used to notice
  /// that a user's PICK has gone missing (cache purge, or a folder cover that replaced
  /// it) so it can be re-materialized from their own URL rather than left as a
  /// placeholder — or silently taken over by the folder cover.

  private func appliedOverrideCover(forAlbumKey albumKey: String) -> String? {
    stringMap(Self.appliedOverrideCoversKey)[albumKey]
  }

  private func setAppliedOverrideCover(_ url: String, forAlbumKey albumKey: String) {
    setStringMapValue(url, key: albumKey, in: Self.appliedOverrideCoversKey)
  }

  private func clearAppliedOverrideCover(forAlbumKey albumKey: String) {
    setStringMapValue(nil, key: albumKey, in: Self.appliedOverrideCoversKey)
  }

  /// Ceiling on forced folder-cover re-pulls per poll. The version loop is serial and
  /// on the main actor, so an unbounded first pass over a large library would stall
  /// the app; the fingerprint compare is idempotent, so anything skipped simply rolls
  /// to the next poll and the library converges over a few of them.
  private static let maxForcedCoverPullsPerPass = 12

  /// Namespaced per ACCOUNT. The album key is only artist|album, so two accounts on
  /// one device sharing an album would otherwise share a stamp — account B would read
  /// account A's pick as already applied and silently show the wrong user's cover.
  private func scopedKey(_ base: String) -> String {
    guard let ident = AmperKit.shared.storage.settings.accounts.active?.ident,
          !ident.isEmpty else { return base }
    return "\(base).\(ident)"
  }

  /// One-time carry-over of the pre-namespacing maps. These keys used to be global;
  /// scoping them per account orphaned every existing stamp, so a device concluded
  /// nothing had ever been applied and re-pulled its whole library. Migrating costs
  /// one dictionary copy and saves every upgrading device that same wasted traffic.
  private func migrateUnscopedMapIfNeeded(_ base: String) {
    let scoped = scopedKey(base)
    guard scoped != base else { return } // no active account yet — nothing to scope to
    let defaults = UserDefaults.standard
    guard defaults.dictionary(forKey: scoped) == nil,
          let legacy = defaults.dictionary(forKey: base) as? [String: String],
          !legacy.isEmpty
    else { return }
    defaults.set(legacy, forKey: scoped)
    print(
      "Cassette: carried \(legacy.count) applied-artwork stamp(s) into the account-scoped store"
    )
  }

  private func stringMap(_ base: String) -> [String: String] {
    migrateUnscopedMapIfNeeded(base)
    return (UserDefaults.standard.dictionary(forKey: scopedKey(base)) as? [String: String]) ?? [:]
  }

  private func setStringMapValue(_ value: String?, key: String, in base: String) {
    var map = stringMap(base)
    if let value { map[key] = value } else { map.removeValue(forKey: key) }
    UserDefaults.standard.set(map, forKey: scopedKey(base))
  }

  /// Drop stamps for albums the manifest no longer lists, so the maps do not grow for
  /// the life of the install as albums are removed or retagged.
  private func pruneAppliedMaps(keeping liveKeys: Set<String>) {
    guard !liveKeys.isEmpty else { return }
    for base in [
      Self.appliedCoverFingerprintsKey,
      Self.appliedOverrideCoversKey,
    ] {
      let map = stringMap(base)
      let pruned = map.filter { liveKeys.contains($0.key) }
      if pruned.count != map.count {
        UserDefaults.standard.set(pruned, forKey: scopedKey(base))
      }
    }
  }

  private func appliedCoverFingerprint(forAlbumKey albumKey: String) -> String? {
    stringMap(Self.appliedCoverFingerprintsKey)[albumKey]
  }

  private func setAppliedCoverFingerprint(_ fingerprint: String, forAlbumKey albumKey: String) {
    setStringMapValue(fingerprint, key: albumKey, in: Self.appliedCoverFingerprintsKey)
  }

  private func clearAppliedCoverFingerprint(forAlbumKey albumKey: String) {
    setStringMapValue(nil, key: albumKey, in: Self.appliedCoverFingerprintsKey)
  }

  /// Whether this install has never known the pre-signal world.
  ///
  /// A genuinely NEW install cannot hold a stale cover: the ordinary backfill just
  /// fetched every cover from the same source the fingerprint describes, so adopting
  /// the fingerprint silently saves re-downloading the whole library byte-for-byte.
  /// An UPGRADING install must still re-pull — its covers predate the signal and may
  /// be exactly the stale art this feature exists to fix.
  ///
  /// The tell is the PRE-EXISTING artwork-version map: it is written by the older
  /// artwork pass, so a device carrying entries has been running before the cover
  /// signal existed. Must be evaluated ONCE, before this pass stamps anything.
  private var isFreshCoverInstall: Bool {
    guard !UserDefaults.standard.bool(forKey: scopedKey(Self.coverSignalSeenKey)) else {
      return false
    }
    let priorVersions = UserDefaults.standard
      .dictionary(forKey: Self.appliedArtworkVersionsKey) as? [String: String]
    return (priorVersions?.isEmpty ?? true)
  }

  private func markCoverSignalSeen() {
    UserDefaults.standard.set(true, forKey: scopedKey(Self.coverSignalSeenKey))
  }

  /// One-time heal for installs poisoned by the retired synthetic-artwork paths.
  ///
  /// Two pieces of state outlive a code fix and must be cleared once on-device:
  ///  1. The applied-artwork-version map. It was stamped even when a materialize was
  ///     SKIPPED or FAILED, so those albums compare "unchanged" forever against a
  ///     catalog hash that never changes and are never retried — this is what froze
  ///     the artist images on the dead `artworks/artist` path. Clearing it re-arms the
  ///     gate exactly once; the on-disk idempotent gates keep the re-run cheap (only
  ///     genuinely missing images re-download) and healthy albums just re-stamp.
  ///  2. The extension-less legacy FILES literally named "cassette-album" / "artist"
  ///     at the top of the artworks dir. Every real cover carries an extension
  ///     (createRelPath always appends one), so these are pure artifacts — and while
  ///     they exist the cache disk-scan can re-adopt them as .CustomImage rows with a
  ///     bare relFilePath, re-minting the exact dead paths we just healed.
  ///
  /// Flag-guarded so it runs exactly once per install and is a no-op on every launch
  /// after that (no repeated full re-materialize pass).
  private func healLegacyArtworkPoisonIfNeeded() {
    let healKey = "cassette.legacyArtworkHealV1"
    guard !UserDefaults.standard.bool(forKey: healKey) else { return }

    UserDefaults.standard.removeObject(forKey: Self.appliedArtworkVersionsKey)

    if let accountInfo = AmperKit.shared.storage.settings.accounts.active,
       let artworksDir = CacheFileManager.shared
       .getOrCreateAbsoluteArtworksDirectory(for: accountInfo) {
      for legacyName in ["cassette-album", "artist"] {
        let legacy = artworksDir.appendingPathComponent(legacyName)
        var isDir: ObjCBool = false
        // ONLY remove a plain file. "artist" is ALSO the legitimate subdirectory that
        // holds nested artist artwork (artworks/artist/<id>.png) — deleting that would
        // wipe every real artist image. Never touch a directory here.
        guard FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDir),
              !isDir.boolValue else { continue }
        try? FileManager.default.removeItem(at: legacy)
        print("Cassette: removed legacy artwork artifact '\(legacyName)'")
      }
    }

    UserDefaults.standard.set(true, forKey: healKey)
    print("Cassette: legacy artwork heal applied - artwork version map re-armed")
  }

  /// One-time heal for album artwork that shares a CACHE FILE with one of its own
  /// songs. Re-typing the mint sites (see `cassetteAlbumArtworkType`) only fixes
  /// rows minted from here on; rows already on disk still carry an empty type and
  /// still resolve to the same `artworks/<id>.png` as the song, so a picked cover
  /// keeps getting overwritten the moment the song is rendered.
  ///
  /// Re-points the ALBUM row into its own path space and drops its cached path so
  /// the very next pass re-fetches to the new, unshared location:
  ///   • a picked album — `hasValidCoverOnDisk` now reads false, so the manifest
  ///     pass re-adopts the user's pick from the cloud (which is the authority on
  ///     picks). This is why the heal must run BEFORE that pass.
  ///   • any other album — the folder-cover backfill re-enqueues it for getCoverArt.
  /// The id never changes, so what gets fetched is identical; only where it lands.
  ///
  /// The shared FILE is deliberately left alone: it is the song's own cover and
  /// remains correct for the song's row.
  private func healAlbumArtworkPathCollisionIfNeeded() async {
    let healKey = "cassette.albumArtworkPathCollisionHealV1"
    guard !UserDefaults.standard.bool(forKey: healKey) else { return }

    let healed = try? await AmperKit.shared.storage.async.performAndGet { asyncCompanion -> Int in
      let context = asyncCompanion.context
      let albumIds = DeviceOwnershipManager(context: context).fetchOwnedAlbumIds()
      guard !albumIds.isEmpty else { return 0 }

      let request: NSFetchRequest<AlbumMO> = AlbumMO.fetchRequest()
      request.predicate = NSPredicate(format: "id IN %@", Array(albumIds))
      request.returnsObjectsAsFaults = false
      let albumMOs = (try? context.fetch(request)) ?? []

      var count = 0
      for albumMO in albumMOs {
        let album = Album(managedObject: albumMO)
        guard let artwork = album.artwork else { continue }
        let info = artwork.remoteInfo
        // Only an empty type collides; anything already nested has its own space.
        guard !info.id.isEmpty, info.type.isEmpty else { continue }

        // The collision is a DISTINCT row carrying the same (id, empty type) — two
        // rows, one file. A song that shares the very same row is one entity with
        // one file and is consistent by construction, so it is left alone.
        let collides = album.songs.contains { song in
          guard let songArtwork = song.artwork else { return false }
          return songArtwork.remoteInfo.id == info.id
            && songArtwork.remoteInfo.type.isEmpty
            && songArtwork.managedObject != artwork.managedObject
        }
        guard collides else { continue }

        artwork.remoteInfo = ArtworkRemoteInfo(id: info.id, type: cassetteAlbumArtworkType)
        // .FetchError is left as-is; the download manager already retries those.
        if artwork.status != .FetchError { artwork.status = .NotChecked }
        artwork.relFilePath = nil
        count += 1
      }
      if count > 0 { asyncCompanion.saveContext() }
      return count
    }

    // Only stamp on a pass that actually completed, so a failed heal retries next
    // poll rather than marking the library healed when nothing was inspected.
    guard let healed else { return }
    UserDefaults.standard.set(true, forKey: healKey)
    print("Cassette: album artwork path-collision heal applied - \(healed) album(s) re-pointed")
  }

  /// The cassette_local_id if `targetId` is an id-keyed remove target
  /// (`localid@<clid>`), else nil. Mirrors the cloud's LOCAL_ID_REMOVE_PREFIX +
  /// decodeLocalIdRemoveTargetId (sync-intents.ts).
  private static let localIdRemovePrefix = "localid@"
  static func decodeLocalIdRemoveTarget(_ targetId: String) -> String? {
    guard targetId.hasPrefix(localIdRemovePrefix) else { return nil }
    let clid = targetId.dropFirst(localIdRemovePrefix.count)
      .trimmingCharacters(in: .whitespaces)
    return clid.isEmpty ? nil : clid
  }

  private func executeIntent(_ intent: CassetteSyncIntent) async {
    print(
      "Cassette poll: executing intent \(intent.id) " +
        "scope=\(intent.scope) kind=\(intent.intentKind) target=\(intent.targetId)"
    )
    // Phase 3.1: album scope only.
    guard intent.scope == "album" else {
      print("Cassette poll: intent \(intent.id) - unsupported scope '\(intent.scope)', failing")
      try? await api.updateIntent(
        id: intent.id,
        state: "failed",
        error: "unsupported_scope_in_phase_31"
      )
      return
    }

    let isRemove = intent.intentKind == "remove"

    // Reachability: only an ADD needs the LAN Player (to pull files). A REMOVE
    // deletes local files + ownership rows, so it must run even with the Mac
    // off-LAN — gating removes on reachability used to strand them in "waiting".
    // Asked once a pass, not once an album (BUG-886: each one cost a 5-second try).
    if !isRemove {
      let reachable: Bool
      if let known = hubAnswerThisPass {
        reachable = known
      } else {
        reachable = await isCassettePlayerReachable()
        hubAnswerThisPass = reachable
      }
      print("Cassette poll: intent \(intent.id) - Cassette Player reachable=\(reachable)")
      if reachable { hubReachedThisPass = true } else { hubUnreachableThisPass = true }
      guard reachable else {
        // already waiting: nothing to tell the cloud again on every pass
        if intent.state != "waiting" {
          try? await api.updateIntent(
            id: intent.id,
            state: "waiting",
            error: "cassette_player_unreachable"
          )
        }
        return
      }
    }

    // Marked syncing only once it can go ahead, so an album out of reach goes pending -> waiting in one write.
    if intent.state == "pending" {
      try? await api.updateIntent(id: intent.id, state: "syncing")
    }

    // Tracks: an id-keyed remove (`localid@<clid>`) carries its target in the
    // intent id, so skip the network resolve entirely — a local delete needs only
    // the cassette_local_id. This is the fast path for the reconciler's per-track
    // removes. Everything else (adds, legacy album-keyed removes) resolves via the
    // tracks endpoint.
    let tracks: [CassetteSyncTrack]
    let albumArtist: CassetteSyncArtist?
    if isRemove, let clid = Self.decodeLocalIdRemoveTarget(intent.targetId) {
      tracks = [CassetteSyncTrack(
        subsonicTrackId: "",
        cassetteLocalId: clid,
        mbid: nil,
        title: nil,
        duration: nil,
        fileExtension: ""
      )]
      albumArtist = nil
    } else {
      do {
        let response = try await api.getIntentTracks(intentId: intent.id)
        tracks = response.tracks
        albumArtist = response.artist
      } catch {
        print(
          "Cassette poll: intent \(intent.id) - track resolve failed: \(error.localizedDescription)"
        )
        try? await api.updateIntent(
          id: intent.id,
          state: "failed",
          error: "track_resolve_failed"
        )
        return
      }
    }
    print("Cassette poll: intent \(intent.id) - resolved \(tracks.count) track(s)")

    let manager = DeviceOwnershipManager(context: AmperKit.shared.storage.main.context)

    if intent.intentKind == "remove" {
      await executeRemoval(intent: intent, tracks: tracks, manager: manager)
      return
    }

    // Add: enqueue downloads for any track not already owned.
    guard let accountInfo = AmperKit.shared.storage.settings.accounts.active else { return }
    let backendApi = AmperKit.shared.getMeta(accountInfo).backendApi

    var enqueued = 0
    for track in tracks {
      if manager.exists(cassetteLocalId: track.cassetteLocalId) { continue }
      do {
        let url = try await backendApi
          .cassetteDownloadUrl(forSubsonicTrackId: track.subsonicTrackId)
        // No room past the reserve (BUG-883): the album waits as it is, and Home says the phone is full.
        guard await transferSession.enqueueDownload(
          url: url,
          cassetteLocalId: track.cassetteLocalId,
          mbid: track.mbid,
          subsonicTrackId: track.subsonicTrackId,
          fileExtension: track.fileExtension,
          intentId: intent.id,
          durationSeconds: track.duration
        ) else { break }
        enqueued += 1
        print("Cassette poll: intent \(intent.id) - enqueued download for \(track.cassetteLocalId)")
      } catch {
        print(
          "Cassette poll: intent \(intent.id) - failed to build download URL " +
            "for \(track.subsonicTrackId): \(error.localizedDescription)"
        )
        os_log(
          "failed to build download URL for %{public}@: %{public}@",
          log: self.log,
          type: .error,
          track.subsonicTrackId,
          error.localizedDescription
        )
      }
    }
    print("Cassette poll: intent \(intent.id) - enqueued \(enqueued) new download(s)")

    // Fast Album Art (artist photo): bundle the album artist's image so it's
    // on-device with the album. Covers come from native getCoverArt (the local-
    // drive cover.jpg over the LAN), not a bundled URL. Best-effort; idempotent.
    await materializeArtistImage(
      subsonicIds: tracks.map(\.subsonicTrackId),
      accountInfo: accountInfo
    )

    // Complete the intent once everything it covers is on disk. Otherwise
    // leave it `syncing`; a later poll (or the next foreground) finalizes it
    // as background downloads land.
    let allOwned = tracks.allSatisfy { manager.exists(cassetteLocalId: $0.cassetteLocalId) }
    if allOwned {
      print("Cassette poll: intent \(intent.id) - all tracks owned, marking complete")
      try? await api.updateIntent(id: intent.id, state: "complete")
    } else {
      print("Cassette poll: intent \(intent.id) - downloads in flight, leaving syncing")
      downloadsInFlightThisPass = true
    }
  }

  /// Download the album artist's bundled image and wire it into the artist's
  /// `Artwork` — a local `.CustomImage` for the album artist, the same disk
  /// end-state a successful getCoverArt would land. Best-effort and idempotent:
  /// honors the artwork-download preference, skips when a local artist image
  /// already exists, and no-ops on any failure.
  ///
  /// Artist photos have no local-drive equivalent the way album covers do (no
  /// folder cover.jpg over getCoverArt), so they keep this catalog-sourced
  /// materialize path — unlike album covers, which are now native getCoverArt only.
  ///
  /// Unlike covers (one hop: `song.album?.artwork`), the artist image must NOT
  /// depend on the inherited `album → artist → artwork` graph. Cassette
  /// downloads build no Core Data graph and `SsSongParserDelegate` never links
  /// `album → artist`, so `song.album?.artist` is almost always nil — the old
  /// implementation dead-ended at its nil guard even though the server sent a
  /// URL. We instead resolve the artist the on-device library UI actually
  /// renders: the Artists list / Artist detail are keyed on the song→artist
  /// relationship (`DeviceOwnershipManager.fetchOwnedArtistIds` collects
  /// `song.artist?.id`; the FRC predicate is `id IN <thatSet>`), i.e.
  /// `song.artist`, which `SsSongParserDelegate` DOES populate. We:
  ///   1. resolve the target `Artist` robustly (`song.album?.artist`, else
  ///      `song.artist`, else create/link one by the song's artist name),
  ///   2. ensure it has an `Artwork` (create + attach one when nil), and
  ///   3. write the bytes + flip it to `.CustomImage`, exactly as the cover path.
  /// We attach to `song.artist` (the proven UI source) and, when present and
  /// distinct, also to `song.album?.artist` so either display path renders.
  ///
  /// Takes the raw `imageUrl` + the owned tracks' `subsonicIds` so both the
  /// transfer path (a fresh intent) and the backfill path (already-synced
  /// albums) drive the identical end-state.
  ///
  /// Pass `force: true` to BYPASS the "already .CustomImage on disk" gate so a
  /// CHANGED artist image overwrites the old file (content reconciliation
  /// increment 2). The artist/artwork resolution + provisioning still runs; only
  /// the on-disk skip is suppressed. The default preserves the absence-only
  /// behavior of every existing caller.
  /// Give an artist the image the HUB holds — the same way an album gets its cover.
  ///
  /// remoteInfo becomes (artist's Subsonic id, type "artist"), so the un-gated
  /// getCoverArt path serves the artist folder's `artist.*` file straight off the
  /// user's own disk. The phone no longer downloads artist photos from the cloud:
  /// that was the last cloud→phone media path, and it is exactly why a wrong face
  /// could persist on the device no matter what the library actually held.
  ///
  /// Two local faults are repaired here, because neither is visible upstream:
  ///  • a SHARED artwork row (one Artwork attached to two artists) — how a featured
  ///    artist ends up wearing the album artist's face. Confidently wrong art is
  ///    worse than none, so a shared row is treated as poisoned and this artist is
  ///    given its own.
  ///  • an artwork still on an OLDER identity (a synthetic id, or bytes pulled from
  ///    the cloud) — re-pointed so it re-fetches from the hub. This is what migrates
  ///    a device that already cached the wrong photo.
  private func materializeArtistImage(
    subsonicIds: [String],
    accountInfo: AccountInfo,
    force: Bool = false
  ) async {
    guard AmperKit.shared.storage.settings.accounts
      .getSetting(accountInfo).read.artworkDownloadSetting != .never else { return }
    guard !subsonicIds.isEmpty else { return }

    let context = AmperKit.shared.storage.main.context
    var artworkObjectID: NSManagedObjectID?
    var repointedName: String?
    context.performAndWait {
      let library = LibraryStorage(context: context)
      let account = library.getAccount(info: accountInfo)

      let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      request.predicate = NSPredicate(format: "id IN %@", subsonicIds)
      request.fetchLimit = 1
      guard let songMO = try? context.fetch(request).first else { return }
      let song = Song(managedObject: songMO)

      // Target the ALBUM artist — the entity the hub keys the folder photo on —
      // falling back to the song's own artist, then to one resolved by name.
      let artist: Artist
      if let albumArtist = song.album?.artist {
        artist = albumArtist
      } else if let songArtist = song.artist {
        artist = songArtist
      } else {
        guard let artistName = songMO.artist?.name, !artistName.isEmpty else { return }
        let resolved = library.getArtistByExactName(for: account, name: artistName)
          ?? {
            let created = library.createArtist(account: account)
            created.name = artistName
            return created
          }()
        song.artist = resolved
        artist = resolved
      }

      // Without a Subsonic id there is nothing for getCoverArt to resolve.
      guard !artist.id.isEmpty else { return }

      // An artist minted ON DEVICE carries a synthetic id the hub has never seen, so
      // getCoverArt can only 404 for it. Re-arming one destroys a working photo and
      // replaces it with a guaranteed failure — which is exactly what the source
      // migration did to every such artist (Adrianne Lenker, Green Day, Radiohead…).
      // Leave them completely alone, and re-adopt the file if it is still on disk:
      // clearing relFilePath does not delete the bytes, so the picture is usually
      // recoverable without any fetch at all.
      //
      // The hub DOES hold a correct photo for these artists under its own artist id;
      // reaching it needs that id resolved, which is a separate piece of work.
      if Self.isUnfetchableArtistId(artist.id) {
        if let aw = artist.artwork, aw.relFilePath == nil,
           let rel = CacheFileManager.shared.createRelPath(
             for: aw.remoteInfo, account: accountInfo
           ),
           let abs = CacheFileManager.shared.getAbsoluteAmperfyPath(relFilePath: rel),
           FileManager.default.fileExists(atPath: abs.path) {
          aw.relFilePath = rel
          aw.status = .CustomImage
          try? context.save()
          print("Cassette poll: recovered on-disk artist image - '\(artist.name)'")
        }
        return
      }

      let want = ArtworkRemoteInfo(id: artist.id, type: "artist")

      let isSharedRow = (artist.artwork?.managedObject.owners?.count ?? 0) > 1
      let artwork: Artwork
      if let existing = artist.artwork, !isSharedRow {
        artwork = existing
      } else {
        let created = library.createArtwork(account: account)
        created.remoteInfo = want
        created.status = .NotChecked
        artist.artwork = created
        artwork = created
        if isSharedRow {
          print("Cassette poll: un-sharing artist image - '\(artist.name)'")
        }
      }

      let needsRepoint = artwork.remoteInfo != want
      if needsRepoint {
        artwork.remoteInfo = want
        repointedName = artist.name
      }

      // Already correct and on disk → nothing to do.
      if !force, !needsRepoint, artwork.status == .CustomImage,
         let path = artwork.imagePath, FileManager.default.fileExists(atPath: path) {
        return
      }
      // Re-arm so the download manager will actually fetch it. .FetchError is left
      // alone — that queue already retries those.
      if artwork.status != .FetchError { artwork.status = .NotChecked }
      if artwork.relFilePath != nil { artwork.relFilePath = nil }
      // A freshly created row still carries a TEMPORARY objectID, which the
      // main-context re-wrap below could not resolve — the download would be dropped.
      try? context.obtainPermanentIDs(for: [artwork.managedObject])
      try? context.save()
      artworkObjectID = artwork.managedObject.objectID
    }

    guard let artworkObjectID else { return }
    let mainContext = AmperKit.shared.storage.main.context
    guard let mo = try? mainContext.existingObject(with: artworkObjectID) as? ArtworkMO
    else { return }
    if let repointedName {
      print("Cassette poll: artist image re-pointed at the hub - '\(repointedName)'")
    }
    await MainActor.run {
      AmperKit.shared.getMeta(accountInfo).artworkDownloadManager
        .download(object: Artwork(managedObject: mo))
    }
  }

  /// The decodable bytes at `url`, or nil (an error status, an empty or undecodable body, a
  /// network failure).
  nonisolated private static func fetchArtistPhoto(_ url: URL) async -> Data? {
    var urlRequest = URLRequest(url: url)
    // Well under URLSession's 60s default: these run serially inside the poll.
    urlRequest.timeoutInterval = 15
    do {
      let (downloaded, response) = try await URLSession.shared.data(for: urlRequest)
      guard let http = response as? HTTPURLResponse,
            (200 ..< 300).contains(http.statusCode), !downloaded.isEmpty,
            CoverImageStore.isDecodable(downloaded)
      else { return nil }
      return downloaded
    } catch {
      print("Cassette poll: artist photo fetch failed - \(error.localizedDescription)")
      return nil
    }
  }

  /// True when this album's ANCHORED artist still lacks its catalog face on disk —
  /// the signal to pull `job.artistImageUrl` from R2. Unlike `hasHealthyArtistImage`
  /// this does NOT skip cloud-identity ids (`inherited-artist:`/`catalog-artist:`):
  /// those are exactly the artists whose photo now comes from the catalog (Phase 2),
  /// not getCoverArt. A shared, wrongly-identified, or fileless row all read missing.
  private func onDeviceArtistPhotoMissing(subsonicIds: [String]) -> Bool {
    guard !subsonicIds.isEmpty else { return false }
    let context = AmperKit.shared.storage.main.context
    var missing = false
    context.performAndWait {
      let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      request.predicate = NSPredicate(format: "id IN %@", subsonicIds)
      request.returnsObjectsAsFaults = false
      let songMOs = (try? context.fetch(request)) ?? []
      var seen = Set<NSManagedObjectID>()
      for songMO in songMOs {
        let song = Song(managedObject: songMO)
        guard let artist = song.album?.artist ?? song.artist else { continue }
        guard seen.insert(artist.managedObject.objectID).inserted else { continue }
        guard !artist.id.isEmpty,
              let artwork = artist.artwork,
              (artwork.managedObject.owners?.count ?? 0) <= 1,
              artwork.remoteInfo == ArtworkRemoteInfo(id: artist.id, type: "artist"),
              artwork.status == .CustomImage,
              let path = artwork.imagePath,
              FileManager.default.fileExists(atPath: path)
        else { missing = true; return }
      }
    }
    return missing
  }

  /// Give an on-device ARTIST IDENTITY its face from the catalog (Phase 2).
  ///
  /// The identity anchor (AlbumRegrouper) keys every on-device artist on a cloud
  /// identity that getCoverArt can only 404 for, so `materializeArtistImage` leaves
  /// them a placeholder. Their real photo is the SAME catalog primary the web Artists
  /// wall shows; the artwork manifest already delivers its R2 URL per owned album
  /// (`job.artistImageUrl`). This downloads that plain URL directly and stores it onto
  /// the identity artist's own `(id,"artist")` Artwork — bypassing Navidrome's
  /// stale/wrong image cache (BUG-082) entirely, so the phone's faces match the web.
  ///
  /// Stores STRAIGHT to `.CustomImage` (never `.NotChecked`) so the getCoverArt
  /// download delegate never re-fetches over the catalog bytes. Idempotent: unless
  /// `force`, an artist already carrying its photo on disk is left untouched (no
  /// network). Un-shares a poisoned shared row first so the photo can't leak onto a
  /// featured artist. Models `forceRefreshNativeCover` (the album-cover twin).
  ///
  /// `ladderUrl` is the same photo at the image ladder's top rung (1200), tried first so the
  /// phone keeps a 1200 copy rather than the full original; `imageUrl` is the fallback when
  /// the ladder is unreachable or refuses it. Photos already on the phone stay as they are.
  @discardableResult
  private func materializeArtistImageFromUrl(
    subsonicIds: [String],
    imageUrl: String,
    ladderUrl: String? = nil,
    accountInfo: AccountInfo,
    force: Bool
  ) async
    -> Bool {
    guard AmperKit.shared.storage.settings.accounts
      .getSetting(accountInfo).read.artworkDownloadSetting != .never else { return false }
    guard !subsonicIds.isEmpty, let url = URL(string: imageUrl) else { return false }

    let context = AmperKit.shared.storage.main.context
    var artworkObjectID: NSManagedObjectID?
    var remoteInfo: ArtworkRemoteInfo?
    var artworkUniqueID: String?
    var artistName: String?
    context.performAndWait {
      let library = LibraryStorage(context: context)
      let account = library.getAccount(info: accountInfo)
      let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      request.predicate = NSPredicate(format: "id IN %@", subsonicIds)
      request.fetchLimit = 1
      guard let songMO = try? context.fetch(request).first else { return }
      let song = Song(managedObject: songMO)

      // Target the ALBUM artist — the identity the anchor keyed and the Artists list
      // renders — falling back to the song's own artist.
      guard let artist = song.album?.artist ?? song.artist, !artist.id.isEmpty else { return }

      // Store under (id,"artist"): the display reads it exactly like a getCoverArt
      // photo, and onDeviceArtistPhotoMissing recognizes it as the artist's own row.
      let want = ArtworkRemoteInfo(id: artist.id, type: "artist")

      // Un-share a poisoned shared row (owners > 1) so this photo can't render on a
      // featured artist that happens to share the Artwork.
      let isSharedRow = (artist.artwork?.managedObject.owners?.count ?? 0) > 1
      let artwork: Artwork
      if let existing = artist.artwork, !isSharedRow {
        artwork = existing
      } else {
        let created = library.createArtwork(account: account)
        created.remoteInfo = want
        created.status = .NotChecked
        artist.artwork = created
        artwork = created
        if isSharedRow { print("Cassette poll: un-sharing artist image - '\(artist.name)'") }
      }
      if artwork.remoteInfo != want { artwork.remoteInfo = want }

      // Idempotent: already carrying its photo on disk → nothing to fetch.
      if !force, artwork.status == .CustomImage,
         let path = artwork.imagePath, FileManager.default.fileExists(atPath: path) {
        return
      }
      // A freshly created row still carries a TEMPORARY objectID; make it permanent so
      // the re-wrap after the download can resolve it.
      try? context.obtainPermanentIDs(for: [artwork.managedObject])
      try? context.save()
      artworkObjectID = artwork.managedObject.objectID
      remoteInfo = want
      artworkUniqueID = artwork.uniqueID
      artistName = artist.name
    }
    guard let artworkObjectID, let remoteInfo else { return false }

    var data: Data?
    if let ladderUrl, let ladder = URL(string: ladderUrl) {
      data = await Self.fetchArtistPhoto(ladder)
    }
    if data == nil {
      data = await Self.fetchArtistPhoto(url)
    }
    guard let data else { return false }

    let fileManager = CacheFileManager.shared
    guard let relFilePath = fileManager.createRelPath(for: remoteInfo, account: accountInfo),
          let absFilePath = fileManager.getAbsoluteAmperfyPath(relFilePath: relFilePath)
    else { return false }
    do {
      try fileManager.writeDataExcludedFromBackup(
        data: data, to: absFilePath, accountInfo: accountInfo
      )
    } catch {
      print("Cassette poll: artist photo write failed - \(error.localizedDescription)")
      return false
    }

    context.performAndWait {
      guard let artworkMO = try? context.existingObject(with: artworkObjectID) as? ArtworkMO
      else { return }
      let artwork = Artwork(managedObject: artworkMO)
      artwork.status = .CustomImage
      artwork.relFilePath = relFilePath
      try? context.save()
    }

    // Invalidate every layer keyed by this (unchanged) path so the new face paints.
    // The thumb is regenerated at native aspect (nothing squares now); aspectFill
    // crops it to fill the circle, matching the web wall.
    let thumbPath = CoverImageStore.thumbPath(forFullPath: absFilePath.path)
    try? FileManager.default.removeItem(atPath: thumbPath)
    CoverImageStore.ensureThumb(forFullPath: absFilePath.path)
    LibraryEntityImage.evictCache(forFullPath: absFilePath.path)
    if let artworkUniqueID {
      AmperKit.shared.notificationHandler.post(
        name: .downloadFinishedSuccess,
        object: AmperKit.shared.getMeta(accountInfo).artworkDownloadManager,
        userInfo: DownloadNotification(id: artworkUniqueID).asNotificationUserInfo
      )
    }
    if let artistName { print("Cassette poll: artist photo set from catalog - '\(artistName)'") }
    return true
  }

  private func forceRefreshNativeCover(
    subsonicIds: [String],
    accountInfo: AccountInfo,
    cacheBust: String
  ) async
    -> Bool {
    guard AmperKit.shared.storage.settings.accounts
      .getSetting(accountInfo).read.artworkDownloadSetting != .never else { return false }
    guard !subsonicIds.isEmpty else { return false }

    let context = AmperKit.shared.storage.main.context
    var artworkObjectID: NSManagedObjectID?
    var remoteInfo: ArtworkRemoteInfo?
    var artworkUniqueID: String?
    context.performAndWait {
      let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      request.predicate = NSPredicate(format: "id IN %@", subsonicIds)
      request.fetchLimit = 1
      guard let songMO = try? context.fetch(request).first,
            let album = Song(managedObject: songMO).album,
            let artwork = album.artwork,
            !artwork.remoteInfo.id.isEmpty
      else { return }
      // No identity minting and no status change here: this artwork already resolves,
      // and touching status would make imagePath return nil — flashing a placeholder
      // over a cover that is still perfectly good until the new bytes land.
      artworkObjectID = artwork.managedObject.objectID
      remoteInfo = artwork.remoteInfo
      artworkUniqueID = artwork.uniqueID
    }
    // Only Sendable value types crossed that boundary — no managed object escapes.
    guard let artworkObjectID, let remoteInfo else { return false }

    // Reuse the artwork download delegate's own URL construction (auth + the bounded
    // size= parameter) instead of rebuilding it: this is exactly the URL the download
    // manager would fetch, and it takes only a Sendable objectID.
    let delegate = AmperKit.shared.getMeta(accountInfo).backendApi
      .getActiveArtworkDownloadDelegate()
    guard let baseUrl = try? await delegate.prepareDownload(
      downloadInfo: DownloadElementInfo(objectId: artworkObjectID, type: .artwork),
      storage: AmperKit.shared.storage.async
    ) else { return false }

    // Cache-bust twice over. Navidrome serves cover art with a ~10-year max-age and
    // the shared URLCache would gladly hand back the OLD bytes for this byte-identical
    // URL, which would silently defeat the entire feature.
    var comps = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)
    // Build the list in a local first: reading comps?.queryItems while assigning to
    // it in one statement is an overlapping access under Swift's exclusivity rules.
    var queryItems = comps?.queryItems ?? []
    queryItems.append(URLQueryItem(name: "_cv", value: cacheBust))
    comps?.queryItems = queryItems
    guard let url = comps?.url else { return false }
    var urlRequest = URLRequest(url: url)
    urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    // Well under URLSession's 60s default: these run serially inside the poll, so a
    // slow or half-open LAN would otherwise stall the whole sync loop.
    urlRequest.timeoutInterval = 12

    let data: Data
    do {
      // from the computer, so through its key check (BUG-879)
      let (downloaded, response) = try await CassetteHubTrust.session.data(for: urlRequest)
      guard let http = response as? HTTPURLResponse,
            (200 ..< 300).contains(http.statusCode), !downloaded.isEmpty
      else { return false }
      // Subsonic reports errors as a 200 with an XML/JSON body — refuse to write that
      // over a perfectly good cover.
      guard CoverImageStore.isDecodable(downloaded) else { return false }
      data = downloaded
    } catch {
      print("Cassette poll: folder cover re-pull failed - \(error.localizedDescription)")
      return false
    }

    let fileManager = CacheFileManager.shared
    guard let relFilePath = fileManager.createRelPath(for: remoteInfo, account: accountInfo),
          let absFilePath = fileManager.getAbsoluteAmperfyPath(relFilePath: relFilePath)
    else { return false }
    do {
      try fileManager.writeDataExcludedFromBackup(
        data: data,
        to: absFilePath,
        accountInfo: accountInfo
      )
    } catch {
      print("Cassette poll: folder cover write failed - \(error.localizedDescription)")
      return false
    }

    context.performAndWait {
      guard let artworkMO = try? context.existingObject(with: artworkObjectID) as? ArtworkMO
      else { return }
      let artwork = Artwork(managedObject: artworkMO)
      artwork.status = .CustomImage
      artwork.relFilePath = relFilePath
      try? context.save()
    }

    // Invalidate every layer that would otherwise keep showing the OLD pixels. The
    // file PATH is unchanged (same artwork identity, new bytes), so nothing here
    // self-invalidates the way a new path would:
    //   1. the tiered thumb — ensureThumb SKIPS when a thumb already exists,
    //   2. the decoded-bitmap NSCache, which is keyed by that unchanged path,
    //   3. mounted cells, via the download-finished notification they already observe.
    let thumbPath = CoverImageStore.thumbPath(forFullPath: absFilePath.path)
    try? FileManager.default.removeItem(atPath: thumbPath)
    CoverImageStore.ensureThumb(forFullPath: absFilePath.path)
    LibraryEntityImage.evictCache(forFullPath: absFilePath.path)
    if let artworkUniqueID {
      AmperKit.shared.notificationHandler.post(
        name: .downloadFinishedSuccess,
        object: AmperKit.shared.getMeta(accountInfo).artworkDownloadManager,
        userInfo: DownloadNotification(id: artworkUniqueID).asNotificationUserInfo
      )
    }
    return true
  }

  private func executeRemoval(
    intent: CassetteSyncIntent,
    tracks: [CassetteSyncTrack],
    manager: DeviceOwnershipManager
  ) async {
    var removed: [String] = []
    for track in tracks {
      guard manager.exists(cassetteLocalId: track.cassetteLocalId) else { continue }
      do {
        try manager.remove(cassetteLocalId: track.cassetteLocalId)
        removed.append(track.cassetteLocalId)
      } catch {
        os_log(
          "failed to remove %{public}@: %{public}@",
          log: self.log,
          type: .error,
          track.cassetteLocalId,
          error.localizedDescription
        )
      }
    }

    print("Cassette poll: intent \(intent.id) - removed \(removed.count) owned track(s)")
    if !removed.isEmpty {
      // Mark the cycle dirty; handlePendingIntents fires ONE immediate library
      // refresh after the whole burst settles. (The old per-removal debounced
      // ownershipDidChange got repeatedly cancelled during a fast multi-track
      // burst and the last one raced the main-thread-blocking regroup, so the
      // removed album could linger on screen until an app relaunch.)
      didRemoveThisCycle = true
      let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
      try? await api.reportDeviceInventory(
        deviceId: deviceId,
        deviceLabel: UIDevice.current.name,
        added: [],
        removed: removed
      )
    }
    try? await api.updateIntent(id: intent.id, state: "complete")
  }

  // MARK: - Reachability

  /// A quick GET to the active account's LAN server with a 5s timeout. Any
  /// HTTP response means reachable; only network errors / timeouts mean not.
  private func isCassettePlayerReachable() async -> Bool {
    // the address in use (https once the computer's key is known), not the login's own
    guard let serverUrl = AmperKit.shared.storage.settings.accounts.activeSetting.read
      .loginCredentials?.activeBackendServerUrl,
      let url = URL(string: serverUrl)
    else { return false }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 5

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    config.waitsForConnectivity = false
    let session = URLSession(configuration: config, delegate: CassetteHubTrust.Delegate(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    do {
      let (_, response) = try await session.data(for: request)
      return response is HTTPURLResponse
    } catch {
      return false
    }
  }
}

// MARK: - CassetteFreshness

/// What the sweep does with one copy on this phone, from the hub version it was made from (nil
/// when the phone can't vouch for it), the hub's version now, when the hub's file came into
/// being, and when the copy was downloaded (the satellite rule, BUG-897).
public enum CassetteFreshness {
  public enum Decision: Equatable {
    /// nothing to do yet
    case wait
    /// the copy is made from this version; record it
    case vouch(String)
    /// a changed song or a re-rip the copy never got: fetch it again, keeping the old one until then
    case fetchAgain
  }

  /// How far a hub file's date may sit after a copy's download and still be the file it came from.
  public static let clockSlack: TimeInterval = 60

  public static func decide(
    madeFrom: String?,
    version: String?,
    fileCreatedAt: Date?,
    downloadedAt: Date
  ) -> Decision {
    let sourceIsNewer = fileCreatedAt.map { $0 > downloadedAt.addingTimeInterval(clockSlack) } ?? false
    if let madeFrom {
      guard let version, version != madeFrom else { return .wait }
      // the computer measuring differently is not a change, unless its file is newer than the copy
      if kind(madeFrom) != kind(version), !sourceIsNewer { return .vouch(version) }
      return .fetchAgain
    }
    // a copy nobody can vouch for: only the hub's file date decides, and a version is never
    // adopted for it without one
    guard fileCreatedAt != nil else { return .wait }
    if sourceIsNewer { return .fetchAgain }
    return version.map { .vouch($0) } ?? .wait
  }

  /// The kind of a fingerprint: the part before a colon ("" for the first ones), so the computer
  /// can change how it measures without every phone taking it as every song changed.
  public static func kind(_ fingerprint: String) -> String {
    guard let colon = fingerprint.firstIndex(of: ":") else { return "" }
    return String(fingerprint[..<colon])
  }
}
