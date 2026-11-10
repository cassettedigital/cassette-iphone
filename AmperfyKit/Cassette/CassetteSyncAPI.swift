//
//  CassetteSyncAPI.swift
//  AmperfyKit
//
//  Cassette fork — Layer 3 Phase 3.1 (Transfer Mechanism).
//
//  Thin client for cassette.digital's /api/sync/* endpoints, authenticated
//  with the bearer token persisted at login (Settings.cassetteBearerToken).
//  Used by IntentExecutor (polling / state transitions) and
//  CassetteTransferSession (inventory reporting).
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

import CryptoKit
import Foundation
import os.log
import Security
import UIKit

// MARK: - CassetteSyncError

public enum CassetteSyncError: Error {
  case notAuthenticated
  case unsupportedBackend
  case badURL
  case http(Int)
  case invalidResponse
}

extension Notification.Name {
  /// Posted when a sync request gets a 401 — the bearer token was revoked
  /// (e.g. the device was removed from the account on the dashboard) or
  /// expired. The app shows a one-per-launch "reconnect?" alert that runs
  /// the re-link flow instead of silently dying.
  public static let cassetteTokenRejected = Notification.Name("CassetteTokenRejected")

  /// Posted (main thread) when `CassetteSyncStatus.isActive` flips — a library
  /// sync wave started or finished. The Home screen swaps its "Syncing your
  /// library" banner in over the Resume card while it is true.
  public static let cassetteSyncActiveChanged = Notification.Name("CassetteSyncActiveChanged")

  /// Posted (main thread) when a fresh /api/sync/account pull changes the account
  /// avatar (the chosen preset/emoji or the photo URL) — set on another device.
  /// The nav-bar account chip re-renders in place, so a change made on desktop
  /// shows up here without a relaunch or a navigation.
  public static let cassetteAccountAvatarChanged = Notification.Name("CassetteAccountAvatarChanged")

  /// Posted (main thread) when a fresh GET /api/player/devices/mac lands: the hub's
  /// heartbeat, its totals and its newest albums. The Mac's state word reads the heartbeat,
  /// so anything showing it re-reads on this as well as on `.cassetteSyncActiveChanged`.
  public static let cassetteMacSummaryChanged = Notification.Name("CassetteMacSummaryChanged")
}

// MARK: - CassetteSyncStatus

/// cassette: the one place the app asks "is music arriving from the hub, and can the
/// phone reach it?"
///
/// A wave = the phone still has albums to pull from the hub (the person's Cassette Player).
/// The intent executor is the authority: at the end of each pass it reports how many album
/// adds are still outstanding and whether the hub answered. This deliberately does NOT
/// track the 30s poll itself, which would blink the status on every quiet check.
///
/// Library data only. Playlists, likes and listens sync through the cloud and never wait
/// on the hub, so nothing here speaks for them.
@MainActor
public enum CassetteSyncStatus {
  /// Whether downloads are in flight (the Home status line shows while true).
  public private(set) static var isActive = false
  /// Album adds still outstanding after the last pass.
  public private(set) static var pendingAlbums = 0
  /// The size of the current wave: the most albums outstanding since it began. Resets when
  /// nothing is outstanding, so "3 of 12" counts this wave, not history.
  public private(set) static var waveTotal = 0
  /// False when the last pass had albums to pull and the hub did not answer.
  public private(set) static var isHubReachable = true
  /// True when the last download asked for had no room on this phone past its reserve (BUG-883).
  public private(set) static var isPhoneFull = false

  /// Set by the download queue each time it asks for a song; posts only on a change.
  nonisolated public static func setPhoneFull(_ full: Bool) {
    Task { @MainActor in
      guard full != isPhoneFull else { return }
      isPhoneFull = full
      NotificationCenter.default.post(name: .cassetteSyncActiveChanged, object: nil)
    }
  }

  /// Called at the end of each intent pass with whether real sync work remains.
  /// Posts `.cassetteSyncActiveChanged` only on a real transition, so observers
  /// don't churn on every poll.
  public static func setActive(_ active: Bool) {
    update(active: active, pendingAlbums: pendingAlbums, hubReachable: isHubReachable)
  }

  /// The full end-of-pass report. `hubReachable` is nil when the pass did not need the hub
  /// (nothing to pull), which leaves the last known answer standing until it matters.
  public static func update(active: Bool, pendingAlbums: Int, hubReachable: Bool?) {
    let newTotal = pendingAlbums == 0 ? 0 : max(waveTotal, pendingAlbums)
    let newReachable = pendingAlbums == 0 ? true : (hubReachable ?? isHubReachable)
    guard active != isActive || pendingAlbums != Self.pendingAlbums || newTotal != waveTotal
      || newReachable != isHubReachable else { return }
    isActive = active
    Self.pendingAlbums = pendingAlbums
    waveTotal = newTotal
    isHubReachable = newReachable
    NotificationCenter.default.post(name: .cassetteSyncActiveChanged, object: nil)
  }

  /// The one quiet line Home shows, or nil when there is nothing to say (the normal case).
  /// - Arriving: "Syncing 3 of 12 albums from Michael's MacBook Pro"
  /// - Hub out of reach with albums waiting: "Can't reach Michael's MacBook Pro · new music
  ///   arrives when it's back"
  /// - No room for the albums waiting: "This phone is full · new music waits until there's room"
  public static func statusLine(hubName: String?) -> String? {
    let inSentence = fallbackHubName.prefix(1).lowercased() + fallbackHubName.dropFirst()
    let hub = hubName ?? inSentence
    if pendingAlbums > 0, isPhoneFull {
      return "This phone is full · new music waits until there's room"
    }
    if pendingAlbums > 0, !isHubReachable {
      return "Can't reach \(hub) · new music arrives when it's back"
    }
    guard isActive || pendingAlbums > 0 else { return nil }
    if waveTotal > 1 {
      let done = max(0, min(waveTotal, waveTotal - pendingAlbums + 1))
      return "Syncing \(done) of \(waveTotal) albums from \(hub)"
    }
    return "Syncing from \(hub)"
  }

  // MARK: The Mac in one word (phone-taste)

  /// The Mac's state, in the one word the Settings head, the avatar menu and the Mac page
  /// all show.
  public enum MacState: Sendable, Equatable {
    case inSync
    case syncing
    case outOfReach
    case notPaired
    /// No heartbeat in hand that speaks for now (none fetched yet, or too old): no word is
    /// shown until the cloud answers. Never read as "in sync".
    case unknown

    public var word: String {
      switch self {
      case .inSync: return "in sync"
      case .syncing: return "syncing"
      case .outOfReach: return "out of reach"
      // The Home card's words ("Your computer / Not set up"): "paired" named a step a
      // newcomer never sees.
      case .notPaired: return "not set up"
      case .unknown: return ""
      }
    }

    /// The word to show, or nil when there is nothing true to say yet.
    public var answer: String? {
      self == .unknown ? nil : word
    }
  }

  /// The hub heartbeats every few minutes while it runs; older than this, it is out of reach.
  public static let heartbeatWindow: TimeInterval = 15 * 60
  /// How long a fetched "it was already out of reach" answer stands without a newer fetch.
  private static let heartbeatTrust: TimeInterval = 30 * 60

  /// The Mac's state, checked in order: not paired; the phone cannot sync at all (no token
  /// or no network); albums waiting and the hub did not answer; albums arriving; then the
  /// hub's own heartbeat (GET /api/player/devices/mac, cached, see `heartbeatState`).
  /// `canSync` is "a bearer token is present and the network is up".
  public static func macState(isPaired: Bool, canSync: Bool, now: Date = Date()) -> MacState {
    guard isPaired else { return .notPaired }
    guard canSync else { return .outOfReach }
    if pendingAlbums > 0, !isHubReachable { return .outOfReach }
    if isActive || pendingAlbums > 0 { return .syncing }
    return heartbeatState(now: now)
  }

  /// What the cached heartbeat proves about now:
  /// - in sync: the hub was seen within the last 15 minutes;
  /// - out of reach: when the cloud was last asked (under 30 minutes ago), the hub had
  ///   already been silent for 15 minutes or more, or no hub was registered;
  /// - unknown otherwise: nothing fetched, a payload that does not decode, or a heartbeat
  ///   that was fresh when fetched but is too old now to speak for the present.
  static func heartbeatState(now: Date) -> MacState {
    guard let fetchedAt = CassetteSyncAPI.cachedMacSummaryFetchedAt,
          let summary = CassetteSyncAPI.cachedMacSummary
    else { return .unknown }
    let isRecentFetch = now.timeIntervalSince(fetchedAt) < heartbeatTrust
    guard let seen = summary.mac?.lastSeenDate else {
      return isRecentFetch ? .outOfReach : .unknown
    }
    if now.timeIntervalSince(seen) < heartbeatWindow { return .inSync }
    if isRecentFetch, fetchedAt.timeIntervalSince(seen) >= heartbeatWindow { return .outOfReach }
    return .unknown
  }

  /// The avatar menu's line under the person's name: "Michaels MacBook Pro · in sync",
  /// just the Mac's name until its state is known, or "Computer not set up" (the Home card's
  /// words, short enough for one line under the name).
  public static func menuLine(hubName: String?, state: MacState) -> String {
    if state == .notPaired { return "Computer not set up" }
    let hub = hubName ?? fallbackHubName
    guard let answer = state.answer else { return hub }
    return "\(hub) · \(answer)"
  }

  /// The hub's name when there is none to show (a bare-IP pairing the cloud has not named
  /// yet). The one fallback Home's line ("your computer" mid-sentence), the avatar menu,
  /// Settings and the computer's page all use. Never "Mac" as the general word (I-W1): the
  /// phone can be paired to any computer.
  public static let fallbackHubName = "Your computer"

  /// The hub's name for display: from the paired LAN address, else from the hostname the
  /// hub last reported to the cloud (a bare IP in the address carries no name). Every
  /// surface that names the hub reads this one, so Home and the avatar menu agree.
  public static func displayHubName(serverUrl: String?) -> String? {
    hubName(serverUrl: pairedServerUrl(serverUrl))
      ?? hubName(host: CassetteSyncAPI.cachedMacSummary?.mac?.lanHostname)
  }

  /// The address a phone is signed in to while its account has no computer yet (BUG-876,
  /// BUG-899). Anyone with a Cassette account gets in and lands on Home's "Not set up" card;
  /// the name is reserved and never resolves, so any reach for a computer fails at once. When
  /// the account's computer signs in, the phone swaps in that computer's login on its own
  /// (`AppDelegate.connectComputerIfReady`).
  public nonisolated static let noComputerHost = "no-computer.invalid"

  /// Whether this sign-in is the stand-in for an account with no computer yet.
  public nonisolated static func isNoComputer(serverUrl: String?) -> Bool {
    guard let serverUrl, let host = URL(string: serverUrl)?.host else { return false }
    return host == noComputerHost
  }

  /// The signed-in computer's address: nil when signed out or when the account has no
  /// computer yet. Every "is there a computer" question reads this, never the raw address.
  public nonisolated static func pairedServerUrl(_ serverUrl: String?) -> String? {
    isNoComputer(serverUrl: serverUrl) ? nil : serverUrl
  }

  /// Whether the hub's name reads as a laptop ("MacBook", "laptop", "notebook").
  public static func isLaptop(hubName: String?) -> Bool {
    guard let hubName else { return false }
    let lower = hubName.lowercased()
    return ["macbook", "laptop", "notebook"].contains { lower.contains($0) }
  }

  private static var macRefreshTask: Task<CassetteMacSummary?, Never>?
  private static var lastMacAttemptAt: Date?

  /// The Mac summary, refreshed from the cloud when the cached copy is older than `maxAge`.
  /// One request at a time, and (unless `force`, after Resync Library) at most one attempt a
  /// minute, so the avatar menu, Settings and the Mac page share it. Only something a person
  /// opened calls this, never the sync poll: a heavy server read must not run unattended.
  /// Never throws: on a failure the cached copy (or nil) comes back. Posts
  /// `.cassetteMacSummaryChanged` when a fresh copy lands.
  @discardableResult
  public static func refreshMacSummary(
    maxAge: TimeInterval,
    force: Bool = false
  ) async
    -> CassetteMacSummary? {
    if let fetchedAt = CassetteSyncAPI.cachedMacSummaryFetchedAt,
       Date().timeIntervalSince(fetchedAt) < maxAge {
      return CassetteSyncAPI.cachedMacSummary
    }
    let cached = CassetteSyncAPI.cachedMacSummary
    if let macRefreshTask { return await macRefreshTask.value ?? cached }
    guard CassetteSyncAPI.bearerToken != nil else { return cached }
    if !force, let lastMacAttemptAt, Date().timeIntervalSince(lastMacAttemptAt) < 60 {
      return cached
    }
    lastMacAttemptAt = Date()
    let task = Task<CassetteMacSummary?, Never> {
      try? await CassetteSyncAPI.shared.getMacSummary()
    }
    macRefreshTask = task
    let fresh = await task.value
    macRefreshTask = nil
    guard let fresh else { return cached }
    NotificationCenter.default.post(name: .cassetteMacSummaryChanged, object: nil)
    return fresh
  }

  /// A human name for the paired hub from its LAN address (`http://<host>:<port>`): a
  /// Bonjour host like "Michaels-MacBook-Pro.local" reads "Michaels MacBook Pro"; a bare IP
  /// carries no name and returns nil.
  public static func hubName(serverUrl: String?) -> String? {
    guard let serverUrl, let host = URL(string: serverUrl)?.host else { return nil }
    return hubName(host: host)
  }

  /// `hubName(serverUrl:)` for a bare hostname ("Michaels-MacBook-Pro.local").
  public static func hubName(host: String?) -> String? {
    guard let host, !host.isEmpty else { return nil }
    let isIPv4 = host.split(separator: ".").count == 4
      && host.allSatisfy { $0.isNumber || $0 == "." }
    if isIPv4 || host.contains(":") { return nil }
    var name = host
    if name.lowercased().hasSuffix(".local") { name = String(name.dropLast(".local".count)) }
    name = name.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
  }
}

// MARK: - CassetteSyncIntent

public struct CassetteSyncIntent: Sendable, Decodable {
  public let id: String
  public let scope: String
  public let targetId: String
  public let state: String
  public let intentKind: String
  /// Which device this intent is for. The server stamps every intent with a
  /// device (explicit or resolved-primary); nil only on legacy rows from the
  /// single-device era.
  public let targetDeviceId: String?

  enum CodingKeys: String, CodingKey {
    case id
    case scope
    case targetId = "target_id"
    case state
    case intentKind = "intent_kind"
    case targetDeviceId = "target_device_id"
  }
}

// MARK: - CassetteSyncTrack

public struct CassetteSyncTrack: Sendable, Decodable {
  public let subsonicTrackId: String
  public let cassetteLocalId: String
  public let mbid: String?
  public let title: String?
  public let duration: Int?
  public let fileExtension: String

  enum CodingKeys: String, CodingKey {
    case subsonicTrackId = "subsonic_track_id"
    case cassetteLocalId = "cassette_local_id"
    case mbid
    case title
    case duration
    case fileExtension = "file_extension"
  }
}

// MARK: - CassetteSyncAlbumCover

/// Album-level cover bundled into the tracks response so the phone can
/// materialize the album art locally — no display-time getCoverArt fetch.
/// `url` is the full original (faithful: full image, square, no crop);
/// `thumbUrl` is an edge-resized grid size. Null when the album has no
/// resolved catalog cover (the phone then falls back to its lazy fetch).
public struct CassetteSyncAlbumCover: Sendable, Decodable {
  public let url: String
  public let thumbUrl: String?

  enum CodingKeys: String, CodingKey {
    case url
    case thumbUrl = "thumb_url"
  }
}

// MARK: - CassetteSyncArtist

/// The album artist's catalog image, bundled into the tracks response so the
/// phone materializes the artist's artwork locally too (matching the web).
/// `imageUrl` is the full original; `thumbUrl` is edge-resized. Null when the
/// artist has no catalog image.
public struct CassetteSyncArtist: Sendable, Decodable {
  public let imageUrl: String
  public let thumbUrl: String?

  enum CodingKeys: String, CodingKey {
    case imageUrl = "image_url"
    case thumbUrl = "thumb_url"
  }
}

// MARK: - CassetteIntentTracksResponse

/// The `/intents/:id/tracks` envelope: the resolvable track list plus the
/// album's bundled cover + artist image (Fast Album Art).
public struct CassetteIntentTracksResponse: Sendable, Decodable {
  public let tracks: [CassetteSyncTrack]
  public let cover: CassetteSyncAlbumCover?
  public let artist: CassetteSyncArtist?
}

// MARK: - CassetteImageRef

/// A picture on the image ladder (docs/reference/CASSETTE_IMAGES.md; `ImageRefJson` in
/// @discovery/cassette-contract). `src` carries `{rung}`, replaced with one of the kit's rungs
/// (120, 240, 480, 800, 1200); `w` and `h` are the natural size when the cloud knows it. Always
/// sent beside the old url fields, which keep their exact values.
public struct CassetteImageRef: Sendable, Decodable, Equatable {
  public let src: String
  public let w: Int?
  public let h: Int?
  public let kind: String?

  /// The address of `rung`, or nil when `src` is not a ladder template.
  public func url(rung: Int) -> String? {
    guard src.contains("{rung}") else { return nil }
    return src.replacingOccurrences(of: "{rung}", with: String(rung))
  }
}

// MARK: - CassetteDeviceArtworkAlbum

/// One owned album in the artwork backfill manifest: the album artist's
/// catalog image and the album's catalog cover, keyed by (artistName,
/// albumName) so the phone can match it to a local album. All four image
/// fields are nullable — only an already-stored catalog image is returned.
///
/// `contentVersion` is a short, deterministic hash of the four artwork URLs:
/// same URLs ⇒ same version, any change ⇒ a new version. The phone records the
/// last-applied version per album and refreshes the artwork on-device when it
/// changes (content reconciliation increment 2) — not just when it's missing.
public struct CassetteDeviceArtworkAlbum: Sendable, Decodable {
  public let artistName: String
  public let albumName: String
  public let artistImageUrl: String?
  public let artistThumbUrl: String?
  /// The artist photo on the image ladder. The phone keeps its top rung and falls back to
  /// `artistImageUrl` when that fails; `artistImageUrl` stays the photo's identity (it is what
  /// `contentVersion` hashes). Optional so an older server response still decodes.
  public let artistImage: CassetteImageRef?
  public let coverUrl: String?
  public let coverThumbUrl: String?
  /// True when cover_url is the user's OWN chosen cover (an override), not our
  /// catalog. The phone adopts the cover onto the local library only when this is
  /// true. Optional so an older server response (without the field) still decodes.
  public let coverIsOverride: Bool?
  /// Fingerprint of the LAN folder cover's bytes on the paired Mac. Non-nil ONLY
  /// when the album has no user pick — the server nulls it whenever coverIsOverride
  /// is true — so acting on it can never take a pick back. Optional so a response
  /// from an older server still decodes.
  public let localCoverVersion: String?
  public let contentVersion: String

  enum CodingKeys: String, CodingKey {
    case artistName = "artist_name"
    case albumName = "album_name"
    case artistImageUrl = "artist_image_url"
    case artistThumbUrl = "artist_thumb_url"
    case artistImage = "artist_image"
    case coverUrl = "cover_url"
    case coverThumbUrl = "cover_thumb_url"
    case coverIsOverride = "cover_is_override"
    case localCoverVersion = "local_cover_version"
    case contentVersion = "content_version"
  }
}

// MARK: - CassetteDeviceArtworkResponse

/// The `/devices/:device_id/artwork` envelope: the artwork backfill manifest
/// for every album the device owns (read-only — heals already-synced albums).
public struct CassetteDeviceArtworkResponse: Sendable, Decodable {
  public let albums: [CassetteDeviceArtworkAlbum]
}

// MARK: - CassetteTrackFreshnessEntry

/// One owned track in the content-freshness sweep manifest: the audio
/// sibling of CassetteDeviceArtworkAlbum. Keyed by cassetteLocalId (the
/// same identity DeviceOwnershipMO stores), with subsonicTrackId carried
/// too since some lookups key on it instead.
///
/// `audioVersion` is a content fingerprint of the track's own file on the
/// paired Mac. nil means UNKNOWN (the hub hasn't successfully hashed this
/// file yet) — never treat nil as "changed". A device that has never
/// recorded a fingerprint for this track ADOPTS whatever value arrives
/// here on first sight rather than re-fetching (the file it already has
/// IS current; there's nothing to correct). Only a stored, non-nil value
/// that differs from this one means the bytes actually changed — e.g. a
/// re-rip that fixed an audio-quality issue without changing the title or
/// duration, which cassetteLocalId can't see by design.
public struct CassetteTrackFreshnessEntry: Sendable, Decodable {
  public let cassetteLocalId: String
  public let subsonicTrackId: String
  public let audioVersion: String?
  /// When the song's file came into being on the computer: a re-rip makes a new file, a tag
  /// write keeps the date. nil until the computer reports it (BUG-897).
  public let fileCreatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case cassetteLocalId = "cassette_local_id"
    case subsonicTrackId = "subsonic_track_id"
    case audioVersion = "audio_version"
    case fileCreatedAt = "file_created_at"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.cassetteLocalId = try c.decode(String.self, forKey: .cassetteLocalId)
    self.subsonicTrackId = try c.decode(String.self, forKey: .subsonicTrackId)
    self.audioVersion = try c.decodeIfPresent(String.self, forKey: .audioVersion)
    self.fileCreatedAt = CassetteISODate.parse(try c.decodeIfPresent(String.self, forKey: .fileCreatedAt))
  }
}

// MARK: - CassetteTrackFreshnessResponse

/// The `/devices/:device_id/track-freshness` envelope: the content-freshness
/// sweep manifest for every track the device owns.
public struct CassetteTrackFreshnessResponse: Sendable, Decodable {
  public let tracks: [CassetteTrackFreshnessEntry]
}

// MARK: - CassetteDeviceGroupingItem

/// One owned track's catalog-blind album grouping, returned additively on the
/// `/api/sync/device-inventory` response. `groupKey` is the web's
/// buildAlbumGroupKey for the track's album bucket — the device keys its AlbumMO
/// by it so its albums match the web. `displayAlbum`/`displayArtist` are the
/// web's canonical card labels; `albumArtRef` is the catalog cover URL (or nil →
/// fall back to the local cover proxy keyed by subsonicTrackId).
public struct CassetteDeviceGroupingItem: Sendable, Decodable {
  public let cassetteLocalId: String?
  public let subsonicTrackId: String
  public let groupKey: String
  public let displayAlbum: String
  public let displayArtist: String
  /// The artist's NORMALIZED cloud identity key (the web's artist_group_key —
  /// `inherited-artist:<name>` / `catalog-artist:<id>`). The device keys its
  /// ArtistMO by it so an artist's IDENTITY matches the web while its NAME stays
  /// the library-stylized display. Optional so an older cloud response (before the
  /// field) still decodes → the regroup falls back to today's synthetic id.
  public let artistGroupKey: String?
  public let albumArtRef: String?
  /// The track's own title + duration (additive). Present once the cloud deploy
  /// includes them; lets the device materialize a SongMO for an owned track it
  /// never library-synced (AlbumRegrouper), so "owned" always equals "visible".
  /// Optional so an older cloud response still decodes.
  public let trackTitle: String?
  public let duration: Int?
  /// The track's 1-based position on its disc, so a materialized SongMO sorts in
  /// album order. Optional/nullable (only ripped-and-linked tracks carry it).
  public let discTrackIndex: Int?
  /// Album release year from the cloud (override ?? catalog), same source as
  /// the web rail. Optional so older deploys still decode; nil means leave the
  /// local Subsonic year alone.
  public let year: Int?

  enum CodingKeys: String, CodingKey {
    case cassetteLocalId = "cassette_local_id"
    case subsonicTrackId = "subsonic_track_id"
    case groupKey = "group_key"
    case displayAlbum = "display_album"
    case displayArtist = "display_artist"
    case artistGroupKey = "artist_group_key"
    case albumArtRef = "album_art_ref"
    case trackTitle = "track_title"
    case duration
    case discTrackIndex = "disc_track_index"
    case year
  }
}

// MARK: - CassetteDeviceInventoryResponse

/// The `/api/sync/device-inventory` response envelope. Both fields are optional
/// on the wire (older deploys omit them) so this decodes cleanly to an empty
/// grouping rather than throwing.
public struct CassetteDeviceInventoryResponse: Sendable, Decodable {
  public let grouping: [CassetteDeviceGroupingItem]
  public let groupingModelVersion: Int

  enum CodingKeys: String, CodingKey {
    case grouping
    case groupingModelVersion = "grouping_model_version"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.grouping = try c
      .decodeIfPresent([CassetteDeviceGroupingItem].self, forKey: .grouping) ?? []
    self.groupingModelVersion = try c.decodeIfPresent(Int.self, forKey: .groupingModelVersion) ?? 0
  }
}

// MARK: - CassetteAccount

/// The authenticated caller's OWN account identity from `/api/sync/account`.
/// `name` is the (nullable) Cassette display name; `email` is the account
/// email the user signs in with. The account menu prefers `name`, falls back
/// to `email`, so the status row shows the user's ACCOUNT — not the paired
/// Player's LAN hostname.
// MARK: - CassetteBetaAccess

/// Cassette Mixtape beta: the account's self-serve beta opt-in (users.is_beta_tester),
/// mirrored from GET /api/sync/account. Read-only on the phone; the web account page
/// owns the toggle. Every Mixtape entry point (the Home Mood shelf, "Start Mixtape")
/// checks this before rendering, because the Mixtape API answers 404 for an account
/// that is not in the beta, and a visible button that can only fail is worse than none.
public enum CassetteBetaAccess {
  public static let defaultsKey = "cassette.isBetaTester"
  public static let changedNotification = Notification.Name("CassetteBetaAccessChanged")
  public static var isBetaTester: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

public struct CassetteAccount: Sendable, Decodable {
  public let email: String
  public let name: String?
  /// Profile photo URL when set; null falls back to avatarPreset. Optional
  /// decode so older deploys keep the silhouette glyph.
  public let image: String?
  /// Default disc when image is null: silhouette | initials | color id.
  /// Optional decode → "silhouette" (the existing person glyph).
  public let avatarPreset: String
  /// Cassette §C: account-sourced Server Mode (browse/stream filter). Optional
  /// decode so a server that doesn't yet emit the field — or an older deploy —
  /// decodes cleanly as `false` (on-device-only) instead of failing.
  public let serverMode: Bool
  /// The paired Cassette Player's sidecar HTTP port (default 5173), distinct from
  /// the Navidrome LAN port (loginCredentials.serverUrl). Still decoded and kept, but
  /// the phone no longer builds any address from it: the hub's own server listens on
  /// the computer only, and the rescan ask goes through the hub's Wi-Fi gateway
  /// instead (`convergeOnPlayer`, BUG-078). Optional decode: null when no player is
  /// paired or an older sidecar/deploy doesn't emit it.
  public let sidecarPort: Int?

  /// Cassette Phase 2b: account-sourced download quality tier ("lossless" |
  /// "high" | "efficient") the phone applies to the music it downloads. Optional
  /// decode → "high" for older deploys that don't emit it.
  public let downloadQuality: String

  /// Cassette Diagnostics: account-level consent that gates AUTO diagnostic
  /// reports (crash / hang / unhandled_error). Rides the same cross-device rail
  /// as themeId/iconId — the web/dashboard owns it, the phone mirrors it. OPT-OUT:
  /// optional decode → true for older deploys / anonymous, so uploads stay
  /// always-on out of the box. Manual `user_feedback` is unaffected by this.
  public let diagnosticsConsent: Bool

  /// Cassette Mixtape beta: the self-serve beta opt-in (users.is_beta_tester). Optional
  /// decode -> false for older deploys, so a server that does not emit it hides Mixtape.
  public let isBetaTester: Bool

  /// The key of the computer's own certificate, for the encrypted link to it (CassetteHubTrust,
  /// BUG-879). nil while the cloud has none for it (a computer app from before).
  public let lanTlsPin: String?

  enum CodingKeys: String, CodingKey {
    case email, name, image, avatarPreset, serverMode, sidecarPort, downloadQuality,
         diagnosticsConsent, isBetaTester, lanTlsPin
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.email = try c.decode(String.self, forKey: .email)
    self.name = try c.decodeIfPresent(String.self, forKey: .name)
    self.image = try c.decodeIfPresent(String.self, forKey: .image)
    self.avatarPreset = try c.decodeIfPresent(String.self, forKey: .avatarPreset) ?? "silhouette"
    self.serverMode = try c.decodeIfPresent(Bool.self, forKey: .serverMode) ?? false
    self.sidecarPort = try c.decodeIfPresent(Int.self, forKey: .sidecarPort)
    self.downloadQuality = try c.decodeIfPresent(String.self, forKey: .downloadQuality) ?? "high"
    self.diagnosticsConsent = try c
      .decodeIfPresent(Bool.self, forKey: .diagnosticsConsent) ?? true
    self.isBetaTester = try c.decodeIfPresent(Bool.self, forKey: .isBetaTester) ?? false
    self.lanTlsPin = try c.decodeIfPresent(String.self, forKey: .lanTlsPin)
  }
}

// MARK: - Device pages (phone-taste)

/// Reads the ISO-8601 strings the web sends for dates ("2026-10-21T03:12:44.123Z"), with or
/// without fractional seconds. A formatter per call: a handful of dates per page open.
enum CassetteISODate {
  static func parse(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
  }
}

/// GET /api/player/devices/mac: the paired hub's heartbeat and last full sync, its library
/// totals, and its newest albums. `mac` is nil when no hub is registered.
public struct CassetteMacSummary: Sendable, Decodable {
  public struct Mac: Sendable, Decodable {
    public let lastSeenAt: String?
    public let lanHostname: String?
    public let lastSyncAt: String?

    public var lastSeenDate: Date? { CassetteISODate.parse(lastSeenAt) }
    public var lastSyncDate: Date? { CassetteISODate.parse(lastSyncAt) }
  }

  /// One of the hub's newest albums. `groupKey` is the web's key, never a phone album id;
  /// `localCoverTrackId` (a hub track id, which the phone stores as the song id) is the
  /// exact bridge to a local album.
  public struct RecentItem: Sendable, Decodable, Identifiable {
    public var id: String { groupKey }
    public let groupKey: String
    public let albumName: String
    public let artistName: String
    public let coverRawUrl: String?
    public let coverOverrideUrl: String?
    public let localCoverTrackId: String?
    /// "#RRGGBB" from the catalog, when the album is matched.
    public let dominantColor: String?
  }

  public let mac: Mac?
  public let tracks: Int
  public let albums: Int
  public let recentItems: [RecentItem]

  enum CodingKeys: String, CodingKey {
    case mac, tracks, albums, recentItems
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.mac = try c.decodeIfPresent(Mac.self, forKey: .mac)
    self.tracks = try c.decodeIfPresent(Int.self, forKey: .tracks) ?? 0
    self.albums = try c.decodeIfPresent(Int.self, forKey: .albums) ?? 0
    self.recentItems = try c.decodeIfPresent([RecentItem].self, forKey: .recentItems) ?? []
  }
}

/// GET /api/player/devices/{this phone}: only what the This Phone page uses. The payload
/// carries much more (the whole library card set); the rest is left undecoded.
public struct CassetteDeviceSummary: Sendable, Decodable {
  /// An album removed from this phone and kept off it until it is put back.
  public struct KeptOffAlbum: Sendable, Decodable, Identifiable {
    public var id: String { groupKey }
    public let groupKey: String
    public let albumName: String
    public let artistName: String
    public let coverArtSmallUrl: String?
    public let coverArtUrl: String?
    public let coverOverrideUrl: String?
    public let localCoverTrackId: String?
    /// The exclusion marks to clear (DELETE /api/sync/marks/exclude) to put it back.
    public let excludeTargetIds: [String]
  }

  /// "everything" or "selective" (account-wide, users.sync_scope).
  public let scope: String
  /// "lossless" | "high" | "efficient".
  public let downloadQualityTier: String?
  public let keptOffAlbums: [KeptOffAlbum]
  /// How many of the Mac's albums the cloud counts on this phone (at least one song here,
  /// not kept off), grouped as the Mac summary's `albums` total is. nil when not sent.
  public let onPhoneAlbumCount: Int?

  enum CodingKeys: String, CodingKey {
    case scope, downloadQualityTier, keptOffAlbums, onPhoneAlbums
  }

  /// One element of an array that is only counted.
  private struct Skipped: Decodable {
    init(from decoder: Decoder) throws {}
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "everything"
    self.downloadQualityTier = try c.decodeIfPresent(String.self, forKey: .downloadQualityTier)
    self.keptOffAlbums = try c.decodeIfPresent([KeptOffAlbum].self, forKey: .keptOffAlbums) ?? []
    self.onPhoneAlbumCount = try c.decodeIfPresent([Skipped].self, forKey: .onPhoneAlbums)?.count
  }
}

/// The cloud's keep playing answer (POST /api/sync/keep-playing; the contract is the web's
/// lib/keep-playing/contract.ts): records that sound like the one that ended or the same
/// artist's, each as its songs in the library; or songs; or nothing ("none"); with the words
/// under THEN.
public struct KeepPlayingAnswer: Decodable, Sendable {
  public struct Record: Decodable, Sendable {
    public let songs: [String]
  }

  /// The words under THEN, as every surface shows them (version 2).
  public struct Heading: Decodable, Sendable {
    public let shout: String
    public let answer: String
  }

  public let kind: String
  public let answer: String?
  public let heading: Heading?
  public let records: [Record]?
  public let songs: [String]?
}

// MARK: - DeviceIdentityCache

/// The phone's id and label, kept for any thread. A real id is kept the first time it is read
/// and never replaced; the stand-in "unknown-device" (the system withholds the id before the
/// first unlock after a restart) is handed out but never kept, so one early call cannot pin the
/// phone to it. The label is kept the same way, and refreshed when the app starts.
final class DeviceIdentityCache: @unchecked Sendable {
  static let unknownId = "unknown-device"
  static let unknownLabel = "iPhone"

  private let lock = NSLock()
  private var id: String?
  private var label: String?

  /// What the main thread just read. A missing or empty id changes nothing.
  func keep(id newId: String?, label newLabel: String?) {
    lock.lock()
    defer { lock.unlock() }
    if id == nil, let newId, !newId.isEmpty { id = newId }
    if let newLabel, !newLabel.isEmpty { label = newLabel }
  }

  func deviceId(reading read: () -> String?) -> String {
    if let kept = kept({ $0.id }) { return kept }
    guard let value = read(), !value.isEmpty else { return Self.unknownId }
    keep(id: value, label: nil)
    return kept { $0.id } ?? value
  }

  func deviceLabel(reading read: () -> String?) -> String {
    if let kept = kept({ $0.label }) { return kept }
    guard let value = read(), !value.isEmpty else { return Self.unknownLabel }
    keep(id: nil, label: value)
    return value
  }

  private func kept(_ pick: (DeviceIdentityCache) -> String?) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return pick(self)
  }
}

// MARK: - DeviceReadBox

/// The answer of a main-thread read handed back to the thread that asked.
private final class DeviceReadBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: (id: String?, label: String)?

  func set(_ value: (id: String?, label: String)) {
    lock.lock()
    stored = value
    lock.unlock()
  }

  var value: (id: String?, label: String)? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

// MARK: - CassetteSyncAPI

public final class CassetteSyncAPI: @unchecked Sendable {
  public static let shared = CassetteSyncAPI()

  private static let apiBase = "https://cassette.digital"
  /// The www host, for a POST whose body must arrive: the bare domain 307s to www, and a redirect
  /// can lose the body on the way (HTTPDiagnosticUploader.swift posts here for the same reason).
  private static let wwwBase = "https://www.cassette.digital"
  private let log = OSLog(subsystem: "Amperfy", category: "CassetteSyncAPI")

  // Ephemeral session with the auth-preserving delegate so the bearer
  // header survives any Vercel redirect (URLSession.shared drops it).
  private lazy var session: URLSession = .init(
    configuration: .ephemeral,
    delegate: CassetteAuthPreservingDelegate(),
    delegateQueue: nil
  )

  public init() {}

  // MARK: Token

  /// The bearer token persisted at login, from the Keychain (SecureSettingsStore,
  /// BUG-878), which is safe to call off the main actor.
  public static var bearerToken: String? {
    SecureSettingsStore
      .string(forKey: PersistentStorage.UserDefaultsKey.CassetteBearerToken.rawValue)
  }

  // MARK: Account identity (account-menu status line)

  /// The caller's Cassette ACCOUNT identity, cached from `/api/sync/account`.
  /// Persisted to UserDefaults (raw keys, mirroring `lastSyncAt`) so the
  /// account menu reads it synchronously, off the main actor, surviving
  /// relaunch and offline opens. `nil` until the first successful fetch.
  nonisolated private static let accountNameKey = "cassette.accountName"
  nonisolated private static let accountEmailKey = "cassette.accountEmail"
  nonisolated private static let accountImageKey = "cassette.accountImage"
  nonisolated private static let accountAvatarPresetKey = "cassette.accountAvatarPreset"
  nonisolated private static let sidecarPortKey = "cassette.sidecarPort"
  /// Cassette Phase 2b: last-known account-sourced download quality tier, read by
  /// the download URL builder so it honors the web-set quality synchronously.
  nonisolated static let downloadQualityKey = "cassette.downloadQuality"

  /// The paired Player's sidecar HTTP port, cached from `/api/sync/account`.
  /// `nil`/0 when unknown (no player paired, or a sidecar/deploy that predates
  /// the field). Nothing builds an address from it any more: that port answers
  /// on the computer only (BUG-078, see `convergeOnPlayer`).
  public static var sidecarPort: Int? {
    let value = UserDefaults.standard.integer(forKey: sidecarPortKey)
    return value > 0 ? value : nil
  }

  public static var accountName: String? {
    let value = UserDefaults.standard.string(forKey: accountNameKey)
    return (value?.isEmpty == false) ? value : nil
  }

  public static var accountEmail: String? {
    let value = UserDefaults.standard.string(forKey: accountEmailKey)
    return (value?.isEmpty == false) ? value : nil
  }

  /// Profile photo URL from `/api/sync/account`, cached for the nav chip.
  public static var accountImage: String? {
    let value = UserDefaults.standard.string(forKey: accountImageKey)
    return (value?.isEmpty == false) ? value : nil
  }

  /// Default disc id when there is no photo (`silhouette` when unset).
  public static var accountAvatarPreset: String {
    UserDefaults.standard.string(forKey: accountAvatarPresetKey) ?? "silhouette"
  }

  /// The account's download quality tier ("lossless" | "high" | "efficient"), the value the
  /// download URL builder follows; nil until the first account fetch.
  public static var downloadQualityTier: String? {
    let value = UserDefaults.standard.string(forKey: downloadQualityKey)
    return (value?.isEmpty == false) ? value : nil
  }

  // MARK: Mac summary cache (phone-taste)

  nonisolated private static let macSummaryKey = "cassette.macSummary"
  nonisolated private static let macSummaryFetchedAtKey = "cassette.macSummaryFetchedAt"

  /// The last Mac summary the cloud returned (raw JSON in UserDefaults), so the Mac page and
  /// the state word have something the moment they open. nil before the first fetch.
  public static var cachedMacSummary: CassetteMacSummary? {
    guard let data = UserDefaults.standard.data(forKey: macSummaryKey) else { return nil }
    return try? JSONDecoder().decode(CassetteMacSummary.self, from: data)
  }

  /// When `cachedMacSummary` was fetched.
  public static var cachedMacSummaryFetchedAt: Date? {
    let t = UserDefaults.standard.double(forKey: macSummaryFetchedAtKey)
    return t > 0 ? Date(timeIntervalSince1970: t) : nil
  }

  /// Ends this phone's sign-in on the cloud as well (BUG-878), so a copy of it (a backup, a sold
  /// phone) stops working. Best effort: a phone offline at sign-out still forgets it locally, and
  /// the cloud lets an unused sign-in lapse after 90 days.
  nonisolated public static func revokeSignIn(_ token: String) async {
    guard let url = URL(string: "\(wwwBase)/api/player/sign-out") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let session = URLSession(configuration: .ephemeral)
    _ = try? await session.data(for: request)
    session.finishTasksAndInvalidate()
  }

  /// Signing out signs out of Cassette (BUG-619): the phone forgets the sign-in and everything it kept for
  /// the person, so the next sign-in, theirs or someone else's, starts clean. The device's own state stays:
  /// its install id and diagnostics choice, the cover fixes it has made, the public station list, and the
  /// music, which the sign-out question decides on its own.
  nonisolated public static func forgetAccount() {
    let defaults = UserDefaults.standard
    SecureSettingsStore.setString(nil, forKey: PersistentStorage.UserDefaultsKey.CassetteBearerToken.rawValue)
    CassetteHubTrust.forget()
    let keys = [
      accountNameKey, accountEmailKey, accountImageKey, accountAvatarPresetKey,
      sidecarPortKey, macSummaryKey, macSummaryFetchedAtKey, downloadQualityKey,
      CassetteLibraryFilterProvider.serverModeDefaultsKey,
      "cassette.isBetaTester", "cassette.lastSyncAt", "cassette.cloudPlaylistPlayedPending",
      "cassette.libraryMoods.lastFetchAt", "cassette.libraryMoods.format", "cassette.libraryMoods.formatTriedAt",
      "cassette.radio.saved.v1",
    ]
    for key in keys { defaults.removeObject(forKey: key) }
    // each playlist's cloud ids, cover and description
    let perPlaylist = ["cassette.cloudPlaylistItemIds.", "cassette.cloudPlaylistDescription.", "cassette.cloudPlaylistCoverUrl.", "cassette.playlistCoverMaterializedUrl."]
    for key in defaults.dictionaryRepresentation().keys where perPlaylist.contains(where: { key.hasPrefix($0) }) {
      defaults.removeObject(forKey: key)
    }
    // the kept Home and the made-for-you and listening files drawn from the person's library
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    for folder in ["CassetteHome", "CassetteMoods"] {
      try? FileManager.default.removeItem(at: base.appendingPathComponent(folder))
    }
  }

  /// Store the fetched account so the menu can render it without a network
  /// round-trip. A `nil`/empty name clears the stored name (so a later
  /// name removal upstream doesn't leave a stale label).
  nonisolated static func persistAccount(_ account: CassetteAccount) {
    // a computer that made a new key, or got its first, is picked up here (BUG-879)
    CassetteHubTrust.recordPin(account.lanTlsPin)
    let defaults = UserDefaults.standard
    // Snapshot the avatar-affecting fields BEFORE we overwrite them, so a change
    // pulled from another device can repaint the account chip in place.
    let previousAvatarPreset = defaults.string(forKey: accountAvatarPresetKey)
    let previousImage = defaults.string(forKey: accountImageKey)
    defaults.set(account.email, forKey: accountEmailKey)
    if let name = account.name, !name.isEmpty {
      defaults.set(name, forKey: accountNameKey)
    } else {
      defaults.removeObject(forKey: accountNameKey)
    }
    if let image = account.image, !image.isEmpty {
      defaults.set(image, forKey: accountImageKey)
    } else {
      defaults.removeObject(forKey: accountImageKey)
    }
    defaults.set(account.avatarPreset, forKey: accountAvatarPresetKey)

    // Avatar changed on another device → repaint the account chip in place (the
    // preset/emoji or the photo URL moved). Same "detect change, post, refresh
    // without a relaunch" pattern Server Mode uses below.
    let newImage = (account.image?.isEmpty == false) ? account.image : nil
    if previousAvatarPreset != account.avatarPreset || previousImage != newImage {
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .cassetteAccountAvatarChanged, object: nil)
      }
    }

    // Persist the paired Player's sidecar port so the pull-to-refresh path can
    // reach the sidecar synchronously, off the main actor. 0 clears it (no
    // player / older sidecar) so a stale port can't linger after unpair.
    defaults.set(account.sidecarPort ?? 0, forKey: sidecarPortKey)

    // Cassette §C: persist the account-sourced Server Mode so the library filter
    // reads it synchronously (immediately on launch/offline). The server value
    // is authoritative — no phone-side toggle, no local override. If it changed
    // since the last fetch, post filterChangedNotification so library views
    // re-filter without a relaunch.
    let serverModeKey = CassetteLibraryFilterProvider.serverModeDefaultsKey
    let previousServerMode = defaults.bool(forKey: serverModeKey)
    defaults.set(account.serverMode, forKey: serverModeKey)
    if previousServerMode != account.serverMode {
      DispatchQueue.main.async {
        NotificationCenter.default.post(
          name: CassetteLibraryFilterProvider.filterChangedNotification,
          object: nil
        )
      }
    }

    // Cassette Mixtape beta (BUG-348): mirror the account's self-serve beta opt-in
    // so the Mood shelf and "Start Mixtape" render only for opted-in accounts.
    // Web-authoritative (the account page toggle); the phone never writes it. Post
    // on change so Home re-applies without a relaunch, as Server Mode does above.
    let betaKey = CassetteBetaAccess.defaultsKey
    let previousBeta = defaults.bool(forKey: betaKey)
    defaults.set(account.isBetaTester, forKey: betaKey)
    if previousBeta != account.isBetaTester {
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: CassetteBetaAccess.changedNotification, object: nil)
      }
    }

    // Cassette Phase 2b: persist the account-sourced download quality so the
    // download URL builder honors it synchronously (web-authoritative — the
    // Devices page owns this; the phone reads it here).
    defaults.set(account.downloadQuality, forKey: downloadQualityKey)

    // Cassette Diagnostics: mirror the account-level diagnostics consent onto the
    // device (same cross-device rail as theme/icon). This gates AUTO reports only;
    // the effective gate is (local toggle AND this synced consent). Manual
    // user_feedback is never gated. Web/dashboard is authoritative.
    DiagnosticsConfig.syncedConsent = account.diagnosticsConsent
  }

  // MARK: Device identity

  /// What the sync layer knows of this phone, kept once read (BUG-459). UIDevice answers on the
  /// main thread only and these are read from every thread, so the answer is read on the main
  /// thread and kept, never fetched per call off it.
  nonisolated private static let identity = DeviceIdentityCache()

  /// Read this phone's id and label on the main thread and keep them. Called at launch, so a
  /// call from a background thread finds them kept instead of reaching for UIDevice.
  @MainActor
  public static func primeDeviceIdentity() {
    let device = UIDevice.current
    identity.keep(id: device.identifierForVendor?.uuidString, label: device.name)
  }

  /// Stable per-vendor device id — the key the whole sync layer (inventory,
  /// intents, and now the user_devices registry) uses for this phone. Once a real
  /// id has been read it never changes for the life of the app. Before the first
  /// unlock after a restart the system can still withhold it: that call answers
  /// "unknown-device", exactly as before, and the answer is NOT kept, so the real
  /// id is used from the first call after the system hands it over.
  public static var deviceId: String {
    identity.deviceId { readDeviceOnMainThread()?.id }
  }

  /// Human label ("Michael's iPhone").
  public static var deviceLabel: String {
    identity.deviceLabel { readDeviceOnMainThread()?.label }
  }

  /// The id and name straight from UIDevice, read on the main thread (a hop of at most two
  /// seconds when asked from another, so a main thread that is itself waiting on this one can
  /// never freeze the app). Nil when the hop timed out.
  nonisolated static func readDeviceOnMainThread() -> (id: String?, label: String)? {
    @Sendable
    func read() -> (id: String?, label: String) {
      MainActor.assumeIsolated {
        let device = UIDevice.current
        return (device.identifierForVendor?.uuidString, device.name)
      }
    }
    if Thread.isMainThread { return read() }
    let box = DeviceReadBox()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
      box.set(read())
      done.signal()
    }
    guard done.wait(timeout: .now() + 2) == .success else { return nil }
    return box.value
  }

  /// HTTP header values must be ASCII; device names often aren't (curly
  /// apostrophes). Header carries the lossy form, registerDevice's JSON body
  /// carries the exact one.
  private static var deviceLabelHeaderValue: String {
    let ascii = deviceLabel.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 }
    let cleaned = String(String.UnicodeScalarView(ascii))
    return cleaned.isEmpty ? "iPhone" : cleaned
  }

  // MARK: Endpoints

  /// Register (upsert) this device in the cassette.digital first-class
  /// device registry (user_devices). Called at pairing and once per launch;
  /// the registry row is what makes the phone visible on the dashboard,
  /// independent of any downloads. Idempotent — safe to call repeatedly.
  public func registerDevice() async throws {
    // iOS 26 SDK: UIDevice.current is MainActor-isolated, so reading
    // `model` from this nonisolated context now requires an await.
    // Compile fix only — no behavior change to the spine.
    let body: [String: Any] = await [
      "device_id": Self.deviceId,
      "device_label": Self.deviceLabel,
      "platform": "ios",
      "model": UIDevice.current.model,
      "app_version": Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
    ]
    _ = try await send(method: "POST", path: "/api/sync/devices", json: body)
    print("Cassette sync: device registered (\(Self.deviceId))")
  }

  /// Non-terminal intents THIS device should act on: brand-new (`pending`),
  /// resuming after a crash (`syncing`), and parked-on-unreachable
  /// (`waiting`). executeIntent is idempotent, so re-seeing `syncing` is safe.
  ///
  /// Device filter: the intents list is account-wide, so it includes intents
  /// targeted at the user's OTHER devices (the Android phone). Acting on
  /// those would download their albums here and race their state machine —
  /// only own-device intents pass. nil targets are legacy single-device rows;
  /// the iPhone (the original device) keeps honoring them.
  public func getActionableIntents() async throws -> [CassetteSyncIntent] {
    struct Envelope: Decodable { let intents: [CassetteSyncIntent] }
    // Only this device's open requests, not the account's whole history on every check (BUG-886). The filter
    // below stays, so an older website answering with the full list still works.
    let myDeviceId = Self.deviceId
    let device = myDeviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? myDeviceId
    let data = try await get(path: "/api/sync/intents?open=1&for_device=\(device)")
    let all = try JSONDecoder().decode(Envelope.self, from: data).intents
    let actionable: Set<String> = ["pending", "syncing", "waiting"]
    return all.filter {
      actionable.contains($0.state) &&
        ($0.targetDeviceId == nil || $0.targetDeviceId == myDeviceId)
    }
  }

  public func getIntentTracks(intentId: String) async throws -> CassetteIntentTracksResponse {
    let data = try await get(path: "/api/sync/intents/\(intentId)/tracks")
    return try JSONDecoder().decode(CassetteIntentTracksResponse.self, from: data)
  }

  /// The authenticated caller's OWN account identity (name + email), resolved
  /// server-side from the bearer token. Read-only and self-scoped. The result
  /// is persisted to UserDefaults (`Self.persistAccount`) so the account menu
  /// can render it synchronously, surviving relaunch and offline opens.
  @discardableResult
  public func getAccount() async throws -> CassetteAccount {
    let data = try await get(path: "/api/sync/account")
    let account = try JSONDecoder().decode(CassetteAccount.self, from: data)
    Self.persistAccount(account)
    return account
  }

  /// Cassette Phase 2c: push the phone-chosen download quality UP to the account
  /// (the hub), so the web reflects it and the next `/api/sync/account` fetch
  /// won't clobber the local choice. Also updates the local UserDefaults key the
  /// download URL builder reads, so the change applies immediately. Fire-and-
  /// forget from the Playback picker.
  public func setDownloadQuality(_ tier: String) async throws {
    UserDefaults.standard.set(tier, forKey: Self.downloadQualityKey)
    _ = try await send(
      method: "PATCH",
      path: "/api/account/download-quality",
      json: ["download_quality_tier": tier]
    )
  }

  /// Cassette Diagnostics: push the phone's diagnostics opt-out UP to the account
  /// (the hub), so the choice rides the same cross-device rail as theme/icon and
  /// the next `/api/sync/account` fetch reflects it instead of clobbering it. Also
  /// updates the local synced-consent mirror so the gate applies immediately.
  /// Signed-in only: with no bearer token the client is anonymous (always-on), so
  /// there's nothing to sync and the device-local toggle governs alone.
  /// Fire-and-forget from the Diagnostics toggle.
  public func setDiagnosticsConsent(_ enabled: Bool) async throws {
    guard Self.bearerToken != nil else { return }
    DiagnosticsConfig.syncedConsent = enabled
    _ = try await send(
      method: "PATCH",
      path: "/api/account/diagnostics",
      json: ["diagnostics_consent": enabled]
    )
  }

  /// Read-only artwork backfill manifest for a device's owned albums — the
  /// album artist's catalog image + the album's catalog cover, per owned
  /// album. Used to heal already-synced libraries without a remove/re-add.
  public func getDeviceArtwork(deviceId: String) async throws
    -> CassetteDeviceArtworkResponse {
    let encoded = deviceId.addingPercentEncoding(
      withAllowedCharacters: .urlPathAllowed
    ) ?? deviceId
    let data = try await get(path: "/api/sync/devices/\(encoded)/artwork")
    return try JSONDecoder().decode(CassetteDeviceArtworkResponse.self, from: data)
  }

  /// Read-only content-freshness sweep manifest for a device's owned tracks —
  /// the audio sibling of getDeviceArtwork. Used to notice a re-rip that
  /// changed a track's bytes without changing its identity (title/duration),
  /// which is otherwise invisible to every other sync signal.
  public func getTrackFreshness(deviceId: String) async throws
    -> CassetteTrackFreshnessResponse {
    let encoded = deviceId.addingPercentEncoding(
      withAllowedCharacters: .urlPathAllowed
    ) ?? deviceId
    let data = try await get(path: "/api/sync/devices/\(encoded)/track-freshness")
    return try JSONDecoder().decode(CassetteTrackFreshnessResponse.self, from: data)
  }

  public func updateIntent(
    id: String,
    state: String,
    error: String? = nil
  ) async throws {
    var body: [String: Any] = ["state": state]
    if let error { body["error_message"] = error }
    _ = try await send(method: "PUT", path: "/api/sync/intents/\(id)", json: body)
  }

  /// A genre for each album in this library, by the album's group key, the id this phone files
  /// it under (GET /api/sync/album-genres): the person's own genre, else the catalog's from our
  /// own tagging. Albums with neither are absent.
  public func getAlbumGenres() async throws -> [(groupKey: String, genre: String)] {
    let data = try await get(path: "/api/sync/album-genres")
    return try JSONDecoder().decode(AlbumGenresResponse.self, from: data).albums.map { ($0.groupKey, $0.genre) }
  }

  /// The mood, energy and valence tags of the songs in this library, keyed by
  /// cassette_local_id (GET /api/sync/library-moods). Untagged songs are absent.
  public func getLibraryMoods() async throws -> [String: LibraryMoodTags] {
    let data = try await get(path: "/api/sync/library-moods")
    let response = try JSONDecoder().decode(LibraryMoodsResponse.self, from: data)
    var byLocalID = [String: LibraryMoodTags]()
    for track in response.tracks {
      byLocalID[track.cassetteLocalId] = LibraryMoodTags(
        moods: track.moods,
        energy: track.energy,
        valence: track.valence,
        subgenres: track.subgenres,
        scenarios: track.scenarios
      )
    }
    return byLocalID
  }

  /// This part of the day's made-for-you playlists, made in the cloud for every device
  /// (GET /api/sync/made-for-you): `timeZone` is the listener's, whose day and hour pick them.
  public func getMadeForYou(timeZone: String) async throws -> MadeForYouFeed {
    let tz = timeZone.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "UTC"
    let data = try await get(path: "/api/sync/made-for-you?tz=\(tz)")
    return try JSONDecoder().decode(MadeForYouFeed.self, from: data)
  }

  /// What plays when the queue runs out (POST /api/sync/keep-playing, the made-for-you recipe
  /// seeded from the queue): `seed` is what just played, oldest first, `exclude` the whole queue,
  /// both as cassette_local_ids. Posted to www so the body survives the bare domain's redirect.
  public func postKeepPlaying(
    kind: String,
    started: [String],
    seed: [String],
    exclude: [String],
    timeZone: String
  ) async throws -> KeepPlayingAnswer {
    let body = try JSONSerialization.data(withJSONObject: [
      "kind": kind,
      "started": started,
      "seed": seed,
      "exclude": exclude,
      "tz": timeZone,
    ])
    let data = try await send(method: "POST", path: "/api/sync/keep-playing", body: body, base: Self.wwwBase)
    return try JSONDecoder().decode(KeepPlayingAnswer.self, from: data)
  }

  /// Home, made once in the cloud for every device (GET /api/sync/home, One Home): every row
  /// in order with its name and what is in it, and every reaching shelf made today. `timeZone`
  /// is the listener's: their hour picks the part of the day, their day (turning at 4 am) the
  /// day's playlists and shelves.
  public func getHome(timeZone: String) async throws -> HomeAnswer {
    let tz = timeZone.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "UTC"
    let data = try await get(path: "/api/sync/home?tz=\(tz)")
    return try JSONDecoder().decode(HomeAnswer.self, from: data)
  }

  /// The shared "lately" profile from every device's plays (GET /api/sync/taste-lately),
  /// keyed by the same tokens ListeningShelves uses (`mood:<m>`, `energy:<e>`, ...), with
  /// the plays' sound (`sound:<subgenre>`, sent apart as `sound`) added in.
  public func getLatelyProfile() async throws -> [String: Double] {
    struct Response: Decodable {
      let profile: [String: Double]
      let sound: [String: Double]?
    }
    let data = try await get(path: "/api/sync/taste-lately")
    let response = try JSONDecoder().decode(Response.self, from: data)
    var profile = response.profile
    for (key, weight) in response.sound ?? [:] where key.hasPrefix("sound:") {
      profile[key] = weight
    }
    return profile
  }

  /// Keep the albums holding these songs off this phone (the phone just removed them).
  /// The server resolves the albums from the hub's library index and stops sending
  /// them here until they are sent back from the device page in Cassette Player.
  public func keepOffThisPhone(cassetteLocalIds: [String]) async throws {
    guard !cassetteLocalIds.isEmpty else { return }
    _ = try await send(
      method: "POST",
      path: "/api/sync/marks/exclude",
      json: ["device_id": Self.deviceId, "cassette_local_ids": cassetteLocalIds]
    )
  }

  // MARK: Device pages (phone-taste)

  /// The paired hub, as the web's Mac page reads it: heartbeat, last full sync, totals and
  /// newest albums. The payload is cached (see `cachedMacSummary`). A heavy server read
  /// (it builds the library card set), so it runs only when a person opens something that
  /// shows it (`CassetteSyncStatus.refreshMacSummary`), never from the sync poll.
  public func getMacSummary() async throws -> CassetteMacSummary {
    let data = try await get(path: "/api/player/devices/mac", timeout: 45)
    let summary = try JSONDecoder().decode(CassetteMacSummary.self, from: data)
    let defaults = UserDefaults.standard
    defaults.set(data, forKey: Self.macSummaryKey)
    defaults.set(Date().timeIntervalSince1970, forKey: Self.macSummaryFetchedAtKey)
    return summary
  }

  /// This phone, as the web's device page reads it: the sync scope, the download quality
  /// and the albums kept off it. nil when the cloud does not know this phone yet (404).
  /// Never cached: Put back acts on these ids, so they must be fresh.
  public func getThisDeviceSummary() async throws -> CassetteDeviceSummary? {
    var unreserved = CharacterSet.alphanumerics
    unreserved.insert(charactersIn: "-._~")
    let encoded = Self.deviceId
      .addingPercentEncoding(withAllowedCharacters: unreserved) ?? Self.deviceId
    do {
      let data = try await get(path: "/api/player/devices/\(encoded)", timeout: 45)
      return try JSONDecoder().decode(CassetteDeviceSummary.self, from: data)
    } catch CassetteSyncError.http(404) {
      return nil
    }
  }

  /// Put albums back on this phone: clear their exclusion marks. The next inventory report
  /// lets the cloud queue them again.
  public func putBack(targetIds: [String]) async throws {
    guard !targetIds.isEmpty else { return }
    _ = try await send(
      method: "DELETE",
      path: "/api/sync/marks/exclude",
      json: ["device_id": Self.deviceId, "target_ids": targetIds]
    )
  }

  /// Differential device-inventory report. `added` entries are upserted,
  /// `removed` localIds are deleted, for this device.
  public func reportDeviceInventory(
    deviceId: String,
    deviceLabel: String?,
    added: [(cassetteLocalId: String, mbid: String?, downloadedAt: Date)],
    removed: [String]
  ) async throws {
    var body: [String: Any] = ["device_id": deviceId]
    if let deviceLabel { body["device_label"] = deviceLabel }

    let iso = ISO8601DateFormatter()
    if !added.isEmpty {
      body["added"] = added.map { entry -> [String: Any] in
        var row: [String: Any] = [
          "cassette_local_id": entry.cassetteLocalId,
          "downloaded_at": iso.string(from: entry.downloadedAt),
        ]
        row["mbid"] = entry.mbid as Any? ?? NSNull()
        return row
      }
    }
    if !removed.isEmpty {
      body["removed"] = removed.map { ["cassette_local_id": $0] }
    }
    if added.isEmpty, removed.isEmpty { return }
    _ = try await send(method: "POST", path: "/api/sync/device-inventory", json: body)
  }

  /// Full-state device-inventory report — the device's COMPLETE owned-set as a
  /// true snapshot (not a delta). The server replaces every row for this device
  /// with `items` and stamps `inventory_as_of`, the freshness signal the
  /// reconciler gates removes on. Unlike the differential report, an empty
  /// device is meaningful here (`items: []` == "I hold nothing"), so this never
  /// early-returns on an empty list.
  /// Returns the server's decoded device-inventory response — carrying the
  /// additive per-track album grouping (Phase 1) the regroup applies — or nil if
  /// the body can't be decoded (older deploy). `@discardableResult` so callers
  /// that only care about the side effect (the report itself) are unchanged.
  @discardableResult
  public func reportFullInventory(
    deviceId: String,
    deviceLabel: String?,
    items: [(cassetteLocalId: String, mbid: String?, downloadedAt: Date)]
  ) async throws
    -> CassetteDeviceInventoryResponse? {
    var body: [String: Any] = ["device_id": deviceId, "full_state": true]
    if let deviceLabel { body["device_label"] = deviceLabel }

    let iso = ISO8601DateFormatter()
    body["items"] = items.map { entry -> [String: Any] in
      var row: [String: Any] = [
        "cassette_local_id": entry.cassetteLocalId,
        "downloaded_at": iso.string(from: entry.downloadedAt),
      ]
      row["mbid"] = entry.mbid as Any? ?? NSNull()
      return row
    }
    let data = try await send(method: "POST", path: "/api/sync/device-inventory", json: body)
    do {
      return try JSONDecoder().decode(CassetteDeviceInventoryResponse.self, from: data)
    } catch {
      // Silent nil used to hide decode failures (e.g. a single bad grouping
      // row), which meant regroup never ran and album years stayed empty.
      print(
        "Cassette sync: device-inventory response decode failed - \(error.localizedDescription)"
      )
      return nil
    }
  }

  // MARK: Play spine (cross-surface listening history)

  /// Batch-report completed plays to the cloud play spine (`/api/sync/plays`).
  /// Append-only + no server-side dedup, so the caller must only send plays it
  /// hasn't sent before (the ScrobbleSyncer stamps `cloudSyncedAt` on success).
  /// Identity is `cassetteLocalId`, computed on-device via `CassetteLocalID` so
  /// it keys on the same id as the web-computed library index. `mbid`,
  /// `durationPlayedSeconds` and `completionRatio` are optional. Send ≤ 500 per
  /// call (the endpoint's cap).
  public func recordPlays(
    _ plays: [(
      cassetteLocalId: String,
      mbid: String?,
      playedAt: Date,
      durationPlayedSeconds: Int?,
      completionRatio: Double?
    )]
  ) async throws {
    guard !plays.isEmpty else { return }
    let iso = ISO8601DateFormatter()
    let rows: [[String: Any]] = plays.map { play -> [String: Any] in
      var row: [String: Any] = [
        "cassette_local_id": play.cassetteLocalId,
        "played_at": iso.string(from: play.playedAt),
        "source_device": "ios",
      ]
      row["mbid"] = play.mbid as Any? ?? NSNull()
      row["duration_played_seconds"] = play.durationPlayedSeconds as Any? ?? NSNull()
      row["completion_ratio"] = play.completionRatio as Any? ?? NSNull()
      return row
    }
    _ = try await send(method: "POST", path: "/api/sync/plays", json: ["plays": rows])
  }

  // MARK: Cloud playlists (user_playlists)

  /// GET /api/sync/playlists — account playlists. Pass `includeItems: true` for
  /// full membership (used to materialise local PlaylistMO rows).
  public func listPlaylists(includeItems: Bool = false, since: Date? = nil) async throws
    -> [CassetteCloudPlaylist] {
    var query: [String] = []
    if includeItems { query.append("include=items") }
    if let since {
      let iso = ISO8601DateFormatter().string(from: since)
      let encoded = iso.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? iso
      query.append("since=\(encoded)")
    }
    let path = query.isEmpty
      ? "/api/sync/playlists"
      : "/api/sync/playlists?\(query.joined(separator: "&"))"
    let data = try await get(path: path)
    return try JSONDecoder().decode(ListPlaylistsResponse.self, from: data).playlists
  }

  public func getPlaylist(id: String) async throws -> CassetteCloudPlaylist {
    let data = try await get(path: "/api/sync/playlists/\(id)")
    return try JSONDecoder().decode(PlaylistEnvelope.self, from: data).playlist
  }

  /// POST /api/sync/playlists/{id}/played: this playlist started playing (One Home: your
  /// playlists sort by the one last played on any device). `playedAt` is when it started; the
  /// cloud only ever moves the date forward.
  public func playlistPlayed(id: String, playedAt: Date) async throws {
    let at = ISO8601DateFormatter().string(from: playedAt)
    _ = try await send(method: "POST", path: "/api/sync/playlists/\(id)/played", json: ["played_at": at])
  }

  public func createPlaylist(
    id: String,
    name: String,
    description: String? = nil
  ) async throws
    -> CassetteCloudPlaylist {
    var body: [String: Any] = ["id": id, "name": name]
    if let description { body["description"] = description }
    let data = try await send(method: "POST", path: "/api/sync/playlists", json: body)
    return try JSONDecoder().decode(PlaylistEnvelope.self, from: data).playlist
  }

  public func updatePlaylist(
    id: String,
    name: String? = nil,
    description: String? = nil
  ) async throws
    -> CassetteCloudPlaylist {
    var body: [String: Any] = [:]
    if let name { body["name"] = name }
    if let description { body["description"] = description }
    let data = try await send(method: "PUT", path: "/api/sync/playlists/\(id)", json: body)
    return try JSONDecoder().decode(PlaylistEnvelope.self, from: data).playlist
  }

  public func deletePlaylist(id: String) async throws {
    _ = try await send(method: "DELETE", path: "/api/sync/playlists/\(id)", json: [:])
  }

  public func applyPlaylistOps(
    playlistId: String,
    ops: [CassettePlaylistOp]
  ) async throws
    -> CassetteCloudPlaylist {
    let bodyData = try JSONEncoder().encode(CassettePlaylistOpsBody(ops: ops))
    let data = try await send(
      method: "POST",
      path: "/api/sync/playlists/\(playlistId)/ops",
      body: bodyData
    )
    return try JSONDecoder().decode(PlaylistOpsEnvelope.self, from: data).playlist
  }

  // MARK: Cloud favorites / Saved

  public func listFavorites(since: Date? = nil) async throws -> [CassetteCloudFavorite] {
    var path = "/api/sync/favorites"
    if let since {
      let iso = ISO8601DateFormatter().string(from: since)
      let encoded = iso.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? iso
      path += "?since=\(encoded)"
    }
    let data = try await get(path: path)
    return try JSONDecoder().decode(ListFavoritesResponse.self, from: data).favorites
  }

  public func upsertFavorite(
    cassetteLocalId: String,
    mbid: String?,
    trackTitle: String?,
    artistName: String?,
    albumName: String?
  ) async throws {
    var body: [String: Any] = [
      "cassette_local_id": cassetteLocalId,
      "event_at": ISO8601DateFormatter().string(from: Date()),
      "source_device": "ios",
    ]
    body["mbid"] = mbid as Any? ?? NSNull()
    if let trackTitle { body["track_title"] = trackTitle }
    if let artistName { body["artist_name"] = artistName }
    if let albumName { body["album_name"] = albumName }
    _ = try await send(method: "POST", path: "/api/sync/favorites", json: body)
  }

  public func removeFavorite(cassetteLocalId: String) async throws {
    // DELETE with JSON body — URLSession needs httpBody on a custom request.
    guard let token = Self.bearerToken else { throw CassetteSyncError.notAuthenticated }
    guard let url = URL(string: Self.apiBase + "/api/sync/favorites") else {
      throw CassetteSyncError.badURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.timeoutInterval = 20
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyDeviceHeaders(&request)
    let body: [String: Any] = [
      "cassette_local_id": cassetteLocalId,
      "event_at": ISO8601DateFormatter().string(from: Date()),
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    _ = try await perform(request)
  }

  // MARK: Saved radio stations

  /// cassette 2026-10-21: the account's saved stations (radio registry slugs), latest save
  /// first: the same list the web's /radio shows under "Your stations". nil when the
  /// server did not say the list is the account's (a deploy of the route from before the
  /// phone read it, which answers every bearer with an empty list); the caller then keeps
  /// its own copy rather than wiping it.
  public func getSavedRadioStations() async throws -> [String]? {
    struct Response: Decodable {
      let saved: [String]
      let signedIn: Bool?
    }
    let data = try await get(path: "/api/radio/saved")
    let response = try JSONDecoder().decode(Response.self, from: data)
    return response.signedIn == true ? response.saved : nil
  }

  /// cassette 2026-10-21: which of a catalog record's songs this account owns, as the hub's
  /// own song ids (the ids this phone's library uses), from the site's album source
  /// (GET /api/album/<slug>/tracks, signed in). Empty when they own none of it.
  public func getOwnedSongIds(albumSlug: String) async throws -> [String] {
    struct Response: Decodable {
      struct Track: Decodable { let subsonicTrackId: String? }
      let tracks: [Track]
    }
    let slug = albumSlug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? albumSlug
    let data = try await get(path: "/api/album/\(slug)/tracks", timeout: 4)
    return try JSONDecoder().decode(Response.self, from: data).tracks.compactMap(\.subsonicTrackId)
  }

  /// Save or unsave a station through the web's own follow edge (POST / DELETE
  /// /api/follows, type `radio_station`), so a save on the phone is the web's save.
  public func setRadioStationSaved(slug: String, saved: Bool) async throws {
    _ = try await send(
      method: saved ? "POST" : "DELETE",
      path: "/api/follows",
      json: ["type": "radio_station", "id": slug, "source": "ios"]
    )
  }

  /// GET /api/sync/plays?since=<iso> — cloud play history, newest first, plays
  /// strictly newer than `since` (server default page size when `since == nil`).
  /// Strictly READ-ONLY. Used by `CloudPlayReconciler` to fold in plays made on
  /// the user's OTHER devices (e.g. their computer) so recency is synchronized
  /// cross-device.
  public func fetchPlays(
    since: Date?,
    excludeSource: String? = nil
  ) async throws
    -> [CassetteCloudPlay] {
    var query: [String] = []
    if let since {
      // Match `recordPlays`' formatter (second precision); the server parses
      // either. `get(path:)` does no percent-encoding, so encode here.
      let iso = ISO8601DateFormatter()
      let sinceStr = iso.string(from: since)
      let encoded = sinceStr
        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sinceStr
      query.append("since=\(encoded)")
    }
    // Drop our OWN device's plays server-side so the newest-N page is spent on
    // cross-device history, not our own listening (which is already local recency).
    if let excludeSource {
      query.append("exclude_source=\(excludeSource)")
    }
    let path = query.isEmpty ? "/api/sync/plays" : "/api/sync/plays?\(query.joined(separator: "&"))"
    let data = try await get(path: path)
    return try JSONDecoder().decode(PlaysResponse.self, from: data).plays
  }

  private struct PlaysResponse: Decodable {
    let plays: [CassetteCloudPlay]
  }

  /// One ranked song from `POST /api/sync/popular-rank`.
  public struct PopularRankItem: Decodable, Sendable {
    public let cassetteLocalId: String
    public let title: String
    public let playCount: Int

    private enum CodingKeys: String, CodingKey {
      case cassetteLocalId = "cassette_local_id"
      case title
      case playCount = "play_count"
    }
  }

  private struct PopularRankResponse: Decodable {
    let items: [PopularRankItem]
  }

  /// POST /api/sync/popular-rank — cloud play-count ranking for an artist's
  /// owned songs (same order as the web/desktop artist rail). Caller sends
  /// cassette_local_id + title; server returns play_count ↓, title A→Z,
  /// capped at 20. Offline callers should fall back to a local tally with
  /// the same comparator.
  public func rankPopular(
    items: [(cassetteLocalId: String, title: String)]
  ) async throws
    -> [PopularRankItem] {
    guard !items.isEmpty else { return [] }
    let rows: [[String: Any]] = items.map { item in
      [
        "cassette_local_id": item.cassetteLocalId,
        "title": item.title,
      ]
    }
    let data = try await send(
      method: "POST",
      path: "/api/sync/popular-rank",
      json: ["items": rows]
    )
    return try JSONDecoder().decode(PopularRankResponse.self, from: data).items
  }

  // MARK: On-demand convergence (B2 pull-to-refresh)

  public enum ConvergeResult: Sendable, Equatable {
    case converged // the computer finished reading its music folder again
    case timeout // the computer is still reading past its window: proceed lazily
    case unavailable // no encrypted address or sign-in yet, or the computer can't take the ask
    case unreachable // network error reaching the computer
  }

  /// Ask the paired computer to read its music folder again and tell the cloud, then return
  /// so the caller can re-report inventory and reconcile (Settings > Resync Library and
  /// Home's pull-to-refresh).
  ///
  /// The hub's own server listens on the computer only, so until BUG-078 this ask (made to
  /// the hub's own port) was refused every time. It now goes where the phone already plays
  /// music from: the hub's Wi-Fi gateway at the address in use (`activeBackendServerUrl`,
  /// its host and port kept), through `CassetteHubTrust.session` so the computer's key pin
  /// applies, with the same Subsonic sign-in the phone sends to `/rest`. The gateway takes it
  /// only encrypted, as a POST, with a sign-in its music server accepts. While the address
  /// in use is still plain http (the cloud has no key for this computer yet) the phone
  /// doesn't ask at all. A hub from before the door answers 404.
  ///
  /// Blocks up to ~95s (just past the hub's 90s wait). Best-effort: every failure returns a
  /// non-fatal result, so the refresh still does the phone's half and the computer's own
  /// folder watch catches up, never an error wall.
  public func convergeOnPlayer(credentials: LoginCredentials?) async -> ConvergeResult {
    guard let credentials,
          let url = Self.convergeURL(
            activeServerUrl: credentials.activeBackendServerUrl,
            username: credentials.username,
            password: credentials.password
          )
    else { return .unavailable }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 95
    do {
      let (data, response) = try await CassetteHubTrust.session.data(for: request)
      guard let http = response as? HTTPURLResponse else { return .unreachable }
      return Self.convergeResult(status: http.statusCode, body: data)
    } catch {
      return .unreachable
    }
  }

  static let convergePath = "/api/library/converge"

  /// The address that asks the computer to read its folder again: the address in use with
  /// its host and port, the converge path, and the Subsonic sign-in (`u`, `t` = md5 of the
  /// password and salt, `s`, `v`, `c`), the way `SubsonicServerApi` signs every `/rest`
  /// call. nil when the address isn't https (no key pin yet, so the gateway would refuse
  /// it) or there's no sign-in to send.
  static func convergeURL(
    activeServerUrl: String,
    username: String,
    password: String,
    salt: String = String.generateRandomString(ofLength: 16)
  )
    -> URL? {
    guard !username.isEmpty, !password.isEmpty, !salt.isEmpty,
          var parts = URLComponents(string: activeServerUrl),
          parts.scheme?.lowercased() == "https",
          let host = parts.host, !host.isEmpty
    else { return nil }
    parts.path = convergePath
    parts.fragment = nil
    parts.queryItems = [
      URLQueryItem(name: "u", value: username),
      URLQueryItem(name: "t", value: StringHasher.md5Hex(dataString: password + salt)),
      URLQueryItem(name: "s", value: salt),
      URLQueryItem(name: "v", value: "1.16.1"),
      URLQueryItem(name: "c", value: "Amperfy"),
    ]
    return parts.url
  }

  /// What the gateway's answer means. 200 with `"converged":true` is a finished rescan, any
  /// other 200 is the hub's 90s timeout. 401 (sign-in refused), 403 (not encrypted) and 404
  /// (a hub from before the door) mean the computer can't take this ask, so the refresh falls
  /// back to the phone's half as before. Anything else is treated as not reaching it.
  static func convergeResult(status: Int, body: Data) -> ConvergeResult {
    switch status {
    case 200:
      if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
         (json["converged"] as? Bool) == true {
        return .converged
      }
      return .timeout
    case 401, 403, 404:
      return .unavailable
    default:
      return .unreachable
    }
  }

  // MARK: HTTP plumbing

  private func get(path: String, timeout: TimeInterval = 20, base: String = CassetteSyncAPI.apiBase) async throws -> Data {
    guard let token = Self.bearerToken else { throw CassetteSyncError.notAuthenticated }
    guard let url = URL(string: base + path) else { throw CassetteSyncError.badURL }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = timeout
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    applyDeviceHeaders(&request)
    return try await perform(request)
  }

  private func send(method: String, path: String, json: [String: Any]) async throws -> Data {
    try await send(
      method: method,
      path: path,
      body: try JSONSerialization.data(withJSONObject: json)
    )
  }

  private func send(method: String, path: String, body: Data, base: String = CassetteSyncAPI.apiBase) async throws -> Data {
    guard let token = Self.bearerToken else { throw CassetteSyncError.notAuthenticated }
    guard let url = URL(string: base + path) else { throw CassetteSyncError.badURL }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyDeviceHeaders(&request)
    request.httpBody = body
    return try await perform(request)
  }

  /// Device identity rides every sync request. Server-side, a bearer-authed
  /// request carrying X-Cassette-Device-Id bumps user_devices.last_seen_at
  /// (the keep-alive that keeps the dashboard's device view honest) and
  /// stamps the token <-> device link used by unpair.
  private func applyDeviceHeaders(_ request: inout URLRequest) {
    request.setValue(Self.deviceId, forHTTPHeaderField: "X-Cassette-Device-Id")
    request.setValue(Self.deviceLabelHeaderValue, forHTTPHeaderField: "X-Cassette-Device-Label")
  }

  private func perform(_ request: URLRequest) async throws -> Data {
    // Verbose-but-temporary logging (Phase 3.1) — `print` is visible in the
    // Xcode console regardless of os_log level filtering.
    let label = "\(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
    print("Cassette sync: -> \(label)")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      print("Cassette sync: <- \(label) invalid (non-HTTP) response")
      throw CassetteSyncError.invalidResponse
    }
    print("Cassette sync: <- \(label) \(http.statusCode)")
    guard (200 ..< 300).contains(http.statusCode) else {
      os_log(
        "sync request %{public}@ failed: %d",
        log: self.log,
        type: .error,
        request.url?.path ?? "?",
        http.statusCode
      )
      if http.statusCode == 401 {
        // Token revoked (device unpaired on the dashboard) or expired.
        // Let the app surface a reconnect prompt instead of dying silently.
        NotificationCenter.default.post(name: .cassetteTokenRejected, object: nil)
      }
      throw CassetteSyncError.http(http.statusCode)
    }
    return data
  }

  // MARK: - Song shares

  /// GET /api/share/song: can this song be sent right now (CASSETTE_SHARING.md)? Asked before Share is
  /// offered, so a song with no video that plays is greyed out instead of failing after a note is
  /// written. Pass every identity on hand; the server finds the catalog song through this person's own
  /// copy first. Saves nothing.
  public func checkSongShare(
    cassetteLocalId: String?,
    mbid: String?,
    subsonicTrackId: String?
  ) async throws
    -> Bool {
    struct Answer: Decodable { let shareable: Bool }
    var query = URLComponents()
    query.queryItems = [
      ("subsonic_track_id", subsonicTrackId),
      ("cassette_local_id", cassetteLocalId),
      ("mbid", mbid),
    ].compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
    let data = try await get(
      path: "/api/share/song?" + (query.percentEncodedQuery ?? ""),
      timeout: 8,
      base: Self.wwwBase
    )
    return try JSONDecoder().decode(Answer.self, from: data).shareable
  }

  /// POST /api/share/song: save a song share (CASSETTE_SHARING.md). `id` is the 8-character code this
  /// phone already put in the link it handed Apple's share sheet; saving the same code again for the
  /// same song updates its note and start (Add a Note, or a retry). The server checks the song's video
  /// again first, so a link never goes out to nothing.
  public func createSongShare(
    id: String,
    cassetteLocalId: String?,
    mbid: String?,
    subsonicTrackId: String?,
    note: String?,
    startSeconds: Int?
  ) async throws
    -> CassetteSongShareResult {
    let body: [String: Any] = [
      "id": id,
      "cassette_local_id": cassetteLocalId as Any? ?? NSNull(),
      "mbid": mbid as Any? ?? NSNull(),
      "subsonic_track_id": subsonicTrackId as Any? ?? NSNull(),
      "note": note as Any? ?? NSNull(),
      "start_seconds": startSeconds as Any? ?? NSNull(),
    ]
    let data = try await send(
      method: "POST",
      path: "/api/share/song",
      body: try JSONSerialization.data(withJSONObject: body),
      base: Self.wwwBase
    )
    return try JSONDecoder().decode(CassetteSongShareResult.self, from: data)
  }

  // MARK: - Mixtape

  /// POST /api/mixtape/generate — whole-library "Smart Mixtape", no seed, no
  /// body. Ephemeral: the server never saves anything until `saveMixtape` is
  /// called explicitly.
  public func generateMixtape() async throws -> CassetteMixtapeResponse {
    let data = try await send(method: "POST", path: "/api/mixtape/generate", json: [:])
    return try JSONDecoder().decode(CassetteMixtapeResponse.self, from: data)
  }

  /// POST /api/mixtape/radio — seeded from one track. Pass whatever identity
  /// is on hand; the server matches on cassette_local_id, mbid, or
  /// subsonic_track_id, in that priority order.
  public func startMixtapeRadio(
    cassetteLocalId: String?,
    mbid: String?,
    subsonicTrackId: String?
  ) async throws
    -> CassetteMixtapeResponse {
    let body: [String: Any] = [
      "cassette_local_id": cassetteLocalId as Any? ?? NSNull(),
      "mbid": mbid as Any? ?? NSNull(),
      "subsonic_track_id": subsonicTrackId as Any? ?? NSNull(),
    ]
    let data = try await send(method: "POST", path: "/api/mixtape/radio", json: body)
    return try JSONDecoder().decode(CassetteMixtapeResponse.self, from: data)
  }

  /// POST /api/mixtape/door — one of the six mood presets. Cached server-side
  /// once per (account, door) per day; `rebuild: true` forces a fresh take
  /// and replaces that day's cached build.
  public func generateDoorMixtape(
    doorKey: String,
    rebuild: Bool = false
  ) async throws
    -> CassetteMixtapeResponse {
    let body: [String: Any] = ["door_key": doorKey, "rebuild": rebuild]
    let data = try await send(method: "POST", path: "/api/mixtape/door", json: body)
    return try JSONDecoder().decode(CassetteMixtapeResponse.self, from: data)
  }

  /// POST /api/mixtape/save — the only mixtape endpoint that writes anything.
  /// Post back exactly the name/description/tracks a generate/radio/door call
  /// returned; the server persists it as a real playlist and returns its id.
  public func saveMixtape(
    name: String,
    description: String,
    tracks: [CassetteMixtapeTrack]
  ) async throws
    -> String {
    let bodyData = try JSONEncoder().encode(CassetteSaveMixtapeBody(
      name: name,
      description: description,
      tracks: tracks
    ))
    let data = try await send(method: "POST", path: "/api/mixtape/save", body: bodyData)
    return try JSONDecoder().decode(CassetteSaveMixtapeResponse.self, from: data).playlistId
  }
}

// MARK: - CassetteAuthPreservingDelegate

/// Re-applies the Authorization header across redirects. Vercel may issue a
/// redirect before the route handler runs, and URLSession strips Authorization
/// on cross-request redirects by default.
final class CassetteAuthPreservingDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> ()
  ) {
    var newRequest = request
    // Only onto Cassette's own hosts over https: a redirect anywhere else, or to plain http,
    // goes on without the sign-in (BUG-878).
    if let auth = task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
       Self.keepsSignIn(request.url) {
      newRequest.setValue(auth, forHTTPHeaderField: "Authorization")
    }
    completionHandler(newRequest)
  }

  static func keepsSignIn(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
    return host == "cassette.digital" || host == "www.cassette.digital"
  }
}

// MARK: - CassettePlaylistOp

/// Wire-shaped playlist mutation op for POST /api/sync/playlists/:id/ops.
/// Sendable so MainActor callers can hand it to this nonisolated client.
public enum CassettePlaylistOp: Encodable, Sendable {
  case add(
    itemId: String,
    cassetteLocalId: String,
    mbid: String?,
    position: Double,
    addedAt: String,
    addedByDevice: String
  )
  case remove(itemId: String)
  case reorder(itemId: String, position: Double)

  private enum CodingKeys: String, CodingKey {
    case op
    case itemId = "item_id"
    case cassetteLocalId = "cassette_local_id"
    case mbid
    case position
    case addedAt = "added_at"
    case addedByDevice = "added_by_device"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .add(itemId, cassetteLocalId, mbid, position, addedAt, addedByDevice):
      try container.encode("add", forKey: .op)
      try container.encode(itemId, forKey: .itemId)
      try container.encode(cassetteLocalId, forKey: .cassetteLocalId)
      try container.encode(mbid, forKey: .mbid)
      try container.encode(position, forKey: .position)
      try container.encode(addedAt, forKey: .addedAt)
      try container.encode(addedByDevice, forKey: .addedByDevice)
    case let .remove(itemId):
      try container.encode("remove", forKey: .op)
      try container.encode(itemId, forKey: .itemId)
    case let .reorder(itemId, position):
      try container.encode("reorder", forKey: .op)
      try container.encode(itemId, forKey: .itemId)
      try container.encode(position, forKey: .position)
    }
  }
}

// MARK: - CassettePlaylistOpsBody

private struct CassettePlaylistOpsBody: Encodable {
  let ops: [CassettePlaylistOp]
}

// MARK: - CassetteCloudPlaylistItem

public struct CassetteCloudPlaylistItem: Sendable, Decodable {
  public let id: String
  public let cassetteLocalId: String
  public let mbid: String?
  public let position: Double
  public let addedAt: String?
  public let removedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case cassetteLocalId = "cassette_local_id"
    case mbid
    case position
    case addedAt = "added_at"
    case removedAt = "removed_at"
  }

  /// The cloud's order for a playlist's songs: by place, then when added, then by id (the
  /// readers' tie-break, BUG-587), so songs saved at the same place keep one order.
  public static func inPlaylistOrder(_ items: [CassetteCloudPlaylistItem]) -> [CassetteCloudPlaylistItem] {
    items.filter { $0.removedAt == nil }.sorted { a, b in
      if a.position != b.position { return a.position < b.position }
      let addedA = a.addedAt ?? "", addedB = b.addedAt ?? ""
      if addedA != addedB { return addedA < addedB }
      return a.id < b.id
    }
  }
}

// MARK: - CassetteCloudPlaylist

public struct CassetteCloudPlaylist: Sendable, Decodable {
  public let id: String
  public let name: String
  public let description: String?
  public let coverImageUrl: String?
  // cassette (cover unification): server-picked preset for a playlist with no
  // user cover. Optional (absent on older servers → nil). Rendered from the phone's
  // BUNDLED preset asset, so it's local + offline; the user's own pick still wins.
  public let derivedCoverUrl: String?
  public let updatedAt: String?
  /// When it last started playing on any device (One Home), or nil.
  public let lastPlayedAt: String?
  public let deletedAt: String?
  public let items: [CassetteCloudPlaylistItem]?

  enum CodingKeys: String, CodingKey {
    case id, name, description, items
    case coverImageUrl = "cover_image_url"
    case derivedCoverUrl = "derived_cover_url"
    case updatedAt = "updated_at"
    case lastPlayedAt = "last_played_at"
    case deletedAt = "deleted_at"
  }
}

// MARK: - ListPlaylistsResponse

private struct ListPlaylistsResponse: Decodable {
  let playlists: [CassetteCloudPlaylist]
}

// MARK: - PlaylistEnvelope

private struct PlaylistEnvelope: Decodable {
  let playlist: CassetteCloudPlaylist
}

// MARK: - PlaylistOpsEnvelope

private struct PlaylistOpsEnvelope: Decodable {
  let playlist: CassetteCloudPlaylist
}

// MARK: - CassetteCloudFavorite

public struct CassetteCloudFavorite: Sendable, Decodable {
  public let cassetteLocalId: String
  public let mbid: String?
  public let trackTitle: String?
  public let artistName: String?
  public let albumName: String?
  public let eventAt: String?

  enum CodingKeys: String, CodingKey {
    case cassetteLocalId = "cassette_local_id"
    case mbid
    case trackTitle = "track_title"
    case artistName = "artist_name"
    case albumName = "album_name"
    case eventAt = "event_at"
  }
}

// MARK: - ListFavoritesResponse

private struct ListFavoritesResponse: Decodable {
  let favorites: [CassetteCloudFavorite]
}

// MARK: - CassetteMixtapeTrack

/// One track as returned by generate/radio/door and posted back to save —
/// same shape both directions, matching the web app's SavedMixtapeTrack.
public struct CassetteMixtapeTrack: Sendable, Codable {
  public let title: String
  public let artist: String
  public let album: String?
  public let durationSeconds: Int?
  public let cassetteLocalId: String
  public let mbid: String?
  public let subsonicTrackId: String?
}

// MARK: - CassetteMixtapeArt

/// Procedural art motif for a mood-door mixtape (shape + hex color) — nil for
/// the whole-library/radio generators, which render a plain gradient instead.
public struct CassetteMixtapeArt: Sendable, Codable {
  public let shape: String
  public let color: String
}

// MARK: - CassetteMixtapeResponse

/// The answer to createSongShare: saved, or why not.
public struct CassetteSongShareResult: Sendable, Decodable {
  public let ok: Bool
  /// "not_in_catalog", "no_video", "not_visible", "not_found" or "taken" when ok is false.
  public let reason: String?
  public let url: String?
  /// "Listen to <song> by <artist> on Cassette".
  public let title: String?
  public let text: String?
}

/// The response shape ALL THREE generators (generate/radio/door) return.
/// Ephemeral — nothing is saved server-side until `saveMixtape` posts this
/// exact shape back to /api/mixtape/save.
public struct CassetteMixtapeResponse: Sendable, Decodable {
  public let name: String
  public let description: String?
  public let art: CassetteMixtapeArt?
  public let tracks: [CassetteMixtapeTrack]
  /// Present only for a door-seeded mixtape — which mood preset generated it,
  /// needed to wire up the Rebuild action. nil for generate/radio.
  public let doorKey: String?
}

// MARK: - CassetteSaveMixtapeBody

private struct CassetteSaveMixtapeBody: Encodable {
  let name: String
  let description: String
  let tracks: [CassetteMixtapeTrack]
}

// MARK: - CassetteSaveMixtapeResponse

private struct CassetteSaveMixtapeResponse: Decodable {
  let playlistId: String
}

// MARK: - CassetteCloudPlay

/// One play returned by `GET /api/sync/plays` — the subset the Home recency
/// reconciler needs. Mirrors the server `PlayJson` wire shape.
public struct CassetteCloudPlay: Decodable {
  public let cassetteLocalId: String
  public let mbid: String?
  public let playedAt: Date
  public let sourceDevice: String?

  private enum CodingKeys: String, CodingKey {
    case cassetteLocalId = "cassette_local_id"
    case mbid
    case playedAt = "played_at"
    case sourceDevice = "source_device"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.cassetteLocalId = try c.decode(String.self, forKey: .cassetteLocalId)
    self.mbid = try c.decodeIfPresent(String.self, forKey: .mbid)
    self.sourceDevice = try c.decodeIfPresent(String.self, forKey: .sourceDevice)
    let raw = try c.decode(String.self, forKey: .playedAt)
    guard let date = CassetteCloudPlay.parseISO(raw) else {
      throw DecodingError.dataCorruptedError(
        forKey: .playedAt,
        in: c,
        debugDescription: "played_at is not an ISO-8601 timestamp: \(raw)"
      )
    }
    self.playedAt = date
  }

  /// The server emits JS `toISOString()` (fractional seconds + `Z`); tolerate a
  /// plain second-precision stamp too.
  private static func parseISO(_ s: String) -> Date? {
    let withFrac = ISO8601DateFormatter()
    withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFrac.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
  }
}

// MARK: - CloudPlayReconciler

/// Folds cloud play history made on the user's OTHER devices (e.g. their
/// computer) into this device's local recency, so the Home "Recent" shelf
/// reflects cross-device listening. It only ever ADVANCES a `Song`'s
/// `lastTimePlayed` (never decrements, never touches `playCount`), and is
/// read-only against the network (`GET /api/sync/plays`).
///
/// Identity chain: a cloud play's `cassette_local_id` → the indexed
/// `DeviceOwnershipMO` (owned/downloaded tracks) → its `subsonicTrackId` → the
/// local `Song`. Cloud plays for tracks not on this device have no local Song
/// and are skipped — they couldn't appear in a local shelf anyway.
public enum CloudPlayReconciler {
  /// How far back to re-scan cloud plays on every run. A forward-only "newest
  /// playedAt" watermark stranded cross-device history: the phone's OWN plays are
  /// always the newest, so the watermark raced to "now" and every play from
  /// another device — always at an earlier timestamp — fell permanently behind it
  /// and was never fetched again. Instead we re-scan this bounded recent window
  /// every run and lean on advance-only idempotency (re-applying a play already
  /// folded in is a no-op), so cross-device plays are always caught and the pass
  /// self-heals. The server caps the page at its own limit, newest-first, which is
  /// plenty for a "Recent" shelf.
  nonisolated private static let recencyWindow: TimeInterval = 60 * 60 * 24 * 90 // 90 days

  /// Fetch recent cloud plays and advance the matching local Songs'
  /// `lastTimePlayed` so the Home "Recent" shelf reflects listening on the user's
  /// OTHER devices (e.g. their computer). Returns `true` if any Song changed, so
  /// the caller can refresh recency-driven UI. Advance-only (never decrements,
  /// never bumps `playCount`) and read-only against the network — safe to re-run.
  @MainActor
  public static func reconcile(storage: PersistentStorage, account: Account) async -> Bool {
    guard CassetteSyncAPI.bearerToken != nil else { return false }

    let since = Date().addingTimeInterval(-recencyWindow)
    let plays: [CassetteCloudPlay]
    do {
      // exclude our own "ios" plays — we only need OTHER devices' listening, and
      // dropping ours keeps the newest-N page spent on cross-device history.
      plays = try await CassetteSyncAPI.shared.fetchPlays(since: since, excludeSource: "ios")
    } catch {
      print("Cassette recency: fetchPlays FAILED: \(error)")
      return false
    }
    // cassette recency diagnostics — temporary. Founder pastes the Xcode console;
    // this maps the funnel from cloud plays → local recency advances so we can see
    // exactly where cross-device recency is (or isn't) landing. Remove once green.
    print("Cassette recency: fetched \(plays.count) cloud plays since \(since)")
    guard !plays.isEmpty else { return false }

    let ownership = DeviceOwnershipManager(context: storage.main.context)
    var changed = false
    // Funnel counters: how many plays survive each resolution step.
    var fromOtherDevice = 0, ownedMatch = 0, hadSubsonicId = 0, songResolved = 0, advanced = 0

    for play in plays {
      if play.sourceDevice != "ios" { fromOtherDevice += 1 }
      // Resolve by the stable mbid first (survives the fingerprint drift between
      // this phone and the hub), then the cassette_local_id fingerprint.
      let ownedOpt = (play.mbid.flatMap { try? ownership.fetchOne(mbid: $0) })
        ?? (try? ownership.fetchOne(cassetteLocalId: play.cassetteLocalId))
      guard let owned = ownedOpt else { continue }
      ownedMatch += 1
      guard let subsonicId = owned.subsonicTrackId else { continue }
      hadSubsonicId += 1
      guard let song = storage.main.library.getSong(for: account, id: subsonicId)
      else { continue }
      songResolved += 1
      // Advance-only: never move a Song's recency backwards, never bump count.
      if let current = song.lastTimePlayed, current >= play.playedAt { continue }
      song.lastTimePlayed = play.playedAt
      advanced += 1
      changed = true
    }
    print(
      "Cassette recency: \(plays.count) plays (\(fromOtherDevice) off-device) → "
        +
        "\(ownedMatch) owned / \(hadSubsonicId) with subsonicId / \(songResolved) song resolved / "
        + "\(advanced) recency advanced"
    )

    if changed { storage.main.saveContext() }
    return changed
  }
}

// MARK: - CassetteHubTrust

/// The encrypted link to the person's computer (BUG-879). Each computer makes its own
/// certificate, with no name in it and nobody vouching for it, so the system's usual checks
/// would refuse it. The phone instead compares the certificate's key with the one the cloud
/// handed over for that computer (`lanTlsPin`: the SHA-256 of the key's SubjectPublicKeyInfo,
/// base64) and trusts nothing else at that address. While the cloud has no key for the
/// computer (a computer app from before), the phone stays on plain http.
///
/// The login's own address (`serverUrl`) never changes, because the phone's library is filed
/// under it (Account.createInfo). Only the address in use (`activeBackendServerUrl`) moves
/// between https and http.
public enum CassetteHubTrust {
  private static let pinKey = "cassette.lanTlsPin"
  private static let hostKey = "cassette.lanTlsHost"

  /// The computer's key as the cloud last reported it, or nil.
  public static var pin: String? {
    UserDefaults.standard.string(forKey: pinKey).flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Remembers the key the cloud reports (at sign-in, and on every account fetch, so a new
  /// key reaches the phone), and the computer's name when known. nil forgets the key.
  public static func recordPin(_ pin: String?, host: String? = nil) {
    if let pin, !pin.isEmpty {
      UserDefaults.standard.set(pin, forKey: pinKey)
    } else {
      UserDefaults.standard.removeObject(forKey: pinKey)
    }
    if let host, !host.isEmpty { UserDefaults.standard.set(host.lowercased(), forKey: hostKey) }
  }

  public static func forget() {
    UserDefaults.standard.removeObject(forKey: pinKey)
    UserDefaults.standard.removeObject(forKey: hostKey)
  }

  /// The address to use for the computer: https while the cloud has its key, http otherwise.
  public static func activeAddress(for serverUrl: String) -> String {
    guard var parts = URLComponents(string: serverUrl), ["http", "https"].contains(parts.scheme ?? "")
    else { return serverUrl }
    parts.scheme = pin == nil ? "http" : "https"
    return parts.string ?? serverUrl
  }

  /// Moves the active login between https and http to match the key on record. Only for the
  /// computer Cassette paired, never a server someone set up by hand; a no-op when it matches.
  @MainActor
  public static func applyToActiveAccount() {
    let accounts = AmperKit.shared.storage.settings.accounts
    guard let info = accounts.active,
          let credentials = accounts.getSetting(info).read.loginCredentials,
          let host = URLComponents(string: credentials.serverUrl)?.host?.lowercased()
    else { return }
    let stored = UserDefaults.standard.string(forKey: hostKey)
    guard stored == nil || stored == host else { return }
    if stored == nil { UserDefaults.standard.set(host, forKey: hostKey) }
    let current = credentials.activeBackendServerUrl
    guard current == credentials.serverUrl || current == activeAddress(for: credentials.serverUrl)
      || current.replacingOccurrences(of: "https://", with: "http://") == credentials.serverUrl
    else { return } // the person picked another address in Settings
    let wanted = activeAddress(for: credentials.serverUrl)
    guard wanted != current else { return }
    AmperKit.shared.storage.settings.accounts.updateSetting(info) { setting in
      setting.loginCredentials?.activeBackendServerUrl = wanted
    }
    var updated = credentials
    updated.activeBackendServerUrl = wanted
    AmperKit.shared.getMeta(info).backendApi.provideCredentials(credentials: updated)
  }

  /// Whether a host is the computer's, whose certificate only its key answers for.
  public static func isComputer(host: String) -> Bool {
    guard pin != nil, let stored = UserDefaults.standard.string(forKey: hostKey) else { return false }
    return host.lowercased() == stored
  }

  /// The answer to a server-trust challenge: the computer's key matches, or the connection is
  /// refused. Every other host gets the system's usual handling.
  public static func answer(_ challenge: URLAuthenticationChallenge)
    -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    let space = challenge.protectionSpace
    guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          isComputer(host: space.host)
    else { return (.performDefaultHandling, nil) }
    guard let trust = space.serverTrust, let pin, keyPin(of: trust) == pin else {
      return (.cancelAuthenticationChallenge, nil)
    }
    return (.useCredential, URLCredential(trust: trust))
  }

  /// The key's SHA-256 over its SubjectPublicKeyInfo, base64, as the computer reports it
  /// (sha256 of the leaf's RawSubjectPublicKeyInfo). The computer's keys are P-256, whose
  /// SubjectPublicKeyInfo is a fixed header and the 65-byte point.
  public static func keyPin(of trust: SecTrust) -> String? {
    guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
          let key = SecCertificateCopyKey(leaf),
          let attributes = SecKeyCopyAttributes(key) as? [String: Any],
          "\(attributes[kSecAttrKeyType as String] ?? "")" == (kSecAttrKeyTypeECSECPrimeRandom as String),
          "\(attributes[kSecAttrKeySizeInBits as String] ?? "")" == "256",
          let point = SecKeyCopyExternalRepresentation(key, nil) as Data?, point.count == 65
    else { return nil }
    var info = Data(p256Header)
    info.append(point)
    return Data(SHA256.hash(data: info)).base64EncodedString()
  }

  private static let p256Header: [UInt8] = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
  ]

  /// For a session that reaches the computer.
  public final class Delegate: NSObject, URLSessionDelegate, Sendable {
    public func urlSession(
      _ session: URLSession,
      didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
      CassetteHubTrust.answer(challenge)
    }
  }

  /// One shared session for single requests to the computer (covers, the reachability check).
  public static let session = URLSession(configuration: .default, delegate: Delegate(), delegateQueue: nil)
}
