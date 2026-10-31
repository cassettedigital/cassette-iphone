//
//  HomeManager.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 29.12.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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

import AmperfyKit
import CoreData
import UIKit

// MARK: - HomeItem

/// cassette: diffable identity is **section-scoped** — the owning `HomeSection`
/// is folded into Hashable/Equatable, so the diffable identifier is effectively
/// `"\(section):\(stableID)"`. This lets the same underlying album/artist appear
/// in Recent AND its typed shelf as two distinct items, with no diffable
/// "identifiers already exist" collision and no expensive cross-section move.
/// With this, no shelf needs to subtract any other shelf — the old cross-shelf
/// dedup is fully retired (overlap is allowed everywhere). `stableID` stays the
/// per-container key (`album-<id>` etc.) used for intra-shelf dedup and CarPlay.
struct HomeItem: Hashable, @unchecked Sendable {
  let section: HomeSection
  let stableID: String
  var playableContainable: PlayableContainable
  /// One Home: a made-for-you style playlist drawn among a row's records (the reaching row's
  /// Nostalgia mix), by its id; `playableContainable` is then its first record, for its art.
  var mixID: String? = nil

  static func == (lhs: HomeItem, rhs: HomeItem) -> Bool {
    lhs.section == rhs.section && lhs.stableID == rhs.stableID
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(section)
    hasher.combine(stableID)
  }
}

// MARK: - ShelfScore

/// cassette Home Shelves v1 foundation. Read-time play signals aggregated for
/// a container (album or artist) from a bounded sample of its songs. The
/// per-song `playCount` / `lastTimePlayed` are maintained on the play path;
/// album/artist counts are not, so we derive them here with no new writes.
///
/// Structured for reuse by the v2 themed rows: "all-time favorites" is
/// `playCount`, "recent favorites" / "this time last year" layer a windowed
/// `ScrobbleEntryMO` query on top of the same shape.
struct ShelfScore {
  var lastPlayed: Date? // max song.lastTimePlayed → recency
  var playCount: Int // sum song.playCount → affinity
  var newestAdded: Date? // max song.addedDate → recency-of-addition (backfill)
}

// MARK: - HomeManager

/// cassette Patch 042: drives the four-shelf Cassette home IA
/// (Recent / Playlists / Albums / Artists). The Recent shelf merges
/// recently-played albums, playlists, and artists (folding in newest
/// albums when the library has no play history yet) sorted by
/// interaction date desc; the lower three shelves filter out anything
/// already surfaced in Recent so the user never sees the same item
/// twice on Home.
@MainActor
class HomeManager: NSObject {
  /// The phone's Home, so Library's Playlists can list the same made-for-you playlists Home
  /// shows (set by HomeVC; nil until Home has loaded).
  static weak var live: HomeManager?

  // Remote-sync batch size (newest / recent album sync). Distinct from the
  // on-screen shelf sizing below.
  public static let sectionMaxItemCount = 20

  // cassette Home Shelves v1. Two distinct ideas: a *target* fill (the
  // minimum so a shelf is never sparse) and a *cap* (the max shown in the
  // carousel; the remainder routes to "See all"). `songSampleLimit` bounds
  // every song fetch so read-time aggregation never scans the whole library;
  // `libraryBackfillLimit` bounds the stable at-large fallback.
  private static let shelfTargetCount = 10
  private static let shelfCarouselCap = 12
  private static let songSampleLimit = 100
  private static let libraryBackfillLimit = 60

  /// The rows Home draws, in order: the cloud's (One Home), else the stand-in's.
  public private(set) var orderedVisibleSections: [HomeSection]
  /// The phone's own rows, drawn only while no cloud Home is held (Edit Home changes these).
  public var standInSections: [HomeSection] = HomeSection.defaultValue {
    didSet { if !cloudHome.isDrawn { orderedVisibleSections = standInSections } }
  }
  public var data: [HomeSection: [HomeItem]] = [:]
  public var applySnapshotCB: VoidFunctionCallback?

  /// One Home: the cloud's rows found on this phone, shared with CarPlay.
  let cloudHome: CloudHome
  /// The cloud's name for each row it sent (shout and answer), drawn as is; empty while the
  /// stand-in draws.
  private(set) var cloudHeadings: [HomeSection: (shout: String, answer: String)] = [:]
  /// The reaching row's shelf on this phone, while the cloud's Home draws.
  private(set) var reachShelf: CloudHome.Shelf?
  /// How many of today's shelves All shelves holds; 0 hides its link.
  private(set) var allShelvesCount = 0
  /// Resume: the song to start the record at when the player is not already in it (the
  /// newest play of it, on any device).
  private(set) var resumeStartSong: Song?
  /// Set while a recompute runs, so the CloudHome change it causes does not ask for another.
  private var isRecomputing = false

  private let account: Account
  private let storage: PersistentStorage
  private let getMeta: (_ accountInfo: AccountInfo) -> MetaManager
  private let eventLogger: EventLogger
  private let player: PlayerFacade
  /// cassette (Forgotten Albums): when true, this instance builds the iOS-only
  /// "From Your Collection" anti-recency shelf (`.forgottenAlbums`). CarPlay
  /// leaves it false (its section list doesn't include it).
  private let buildsForgottenShelf: Bool

  // cassette (Forgotten Albums) tuning knobs.
  private static let forgottenCandidateFetchLimit = 150
  private static let forgottenTurnoverDays = 7
  private static let forgottenColdSeconds: TimeInterval = 60 * 24 * 60 * 60 // 60 days
  private static let forgottenRekindleMinPlays: Int = 5

  var isOfflineMode: Bool {
    storage.settings.user.isOfflineMode
  }

  // cassette Home Shelves v1: rank albums & artists from maintained *song*
  // play data (the per-song playCount / lastTimePlayed are bumped on the play
  // path; album/artist counts and the server-assigned recentIndex/newestIndex
  // are not). We sample three bounded song fetches and aggregate per container
  // at read time — the proven Artists-shelf pattern, now applied to albums too.
  private var recentSongsFetch: SongsFetchedResultsController? // lastPlayedDate desc → recency
  private var topSongsFetch: SongsFetchedResultsController? // playCount desc → affinity
  private var newestSongsFetch: SongsFetchedResultsController? // addedDate desc → newest-added
  private var playlistsLastPlayedFetch: PlaylistFetchedResultsController?

  // Stable library-at-large backfill (alphabetical; no dependency on the
  // server-assigned indices) so a shelf never renders below target when the
  // items exist.
  private var albumsAllFetch: AlbumFetchedResultsController?
  private var artistsAllFetch: ArtistFetchedResultsController?
  // cassette (Forgotten Albums): owned-album candidate pool (the on-device
  // ownership predicate auto-applies), newest-sorted so the older end
  // approximates "added long ago".
  private var forgottenAlbumsFetch: AlbumFetchedResultsController?

  // Transient per-recompute scoring, rebuilt at the top of
  // `recomputeAllShelves` and consumed by the shelf builders in that pass.
  private var albumScores: [String: (container: Album, score: ShelfScore)] = [:]
  private var artistScores: [String: (container: Artist, score: ShelfScore)] = [:]
  private var rankedAlbumIDs: [String] = []
  // cassette (BUG-036): `rankedArtistIDs` (song-derived artist ranking) retired —
  // the Artists shelf now ranks by the real artist-play signal in
  // `updateRecentArtists()`, so album plays no longer surface artists.

  // Part 2a: coalesce the FRC-change burst (~30 callbacks in 0.1s as Core Data
  // settles after a play / sync) and player transitions into a single debounced
  // recompute, so one snapshot is applied instead of a storm. The initial
  // build in `createFetchController` runs immediately for first paint.
  private var pendingRecompute: DispatchWorkItem?
  private static let recomputeDebounce: TimeInterval = 0.12
  // cassette (CarPlay off-window crash): when this HomeManager's host view is not
  // on screen — the phone Home while CarPlay drives playback — defer recomputes
  // instead of rebuilding and applying an animated snapshot to an off-window
  // collection view (the production SIGTRAP cluster). The phone HomeVC sets this;
  // CarPlay's own HomeManager leaves it nil so its templates keep updating live. A
  // deferred recompute is flushed once by the host on next appearance
  // (`recomputeIfDeferred()`).
  public var isHostVisible: (() -> Bool)?
  private var needsRecomputeWhileHidden = false
  // cassette (CarPlay off-window crash): coalesce the per-builder snapshot
  // callbacks fired within one `recomputeAllShelves` into a SINGLE apply, so a
  // rebuild is one diff/animation instead of 4-6 overlapping animated applies.
  private var isBatchingSnapshot = false

  /// phone-taste: the Lately tile's mix, built once and kept, so the tile's picture always
  /// shows records the tap will play.
  struct LatelyMix {
    /// The songs a tap plays, in order (on this phone, matching lately).
    let songs: [AbstractPlayable]
    /// Up to four of the mix's albums for the tile's picture, in mix order, those with a
    /// cover on disk first.
    let leadAlbums: [Album]
    /// Changes whenever `songs` or `leadAlbums` change, and only then, so Home redraws the
    /// Mood row only when there is something new to draw.
    let generation: Int
  }

  /// The current Lately mix, or nil when there is no lately profile (no mood tags or no
  /// recent listening). It is drawn again only when what it is drawn from changes (a new
  /// day, new mood tags, a new lately profile from the cloud, or more tagged music on the
  /// phone), never on a play, a pause or a cache expiry, and the draw is seeded by the day,
  /// so a relaunch draws the same mix (BUG-494). Songs that leave the phone drop out of it
  /// on the next recompute.
  private(set) var latelyMix: LatelyMix?
  /// What `latelyMix` was drawn from (see `LatelyMixKey`).
  private var latelyMixKey: LatelyMixKey?
  private var latelyMixGeneration = 0
  /// Set when `LatelyLibrary` posts `.cassetteMoodIndexReady`: the cached mood index was
  /// just rebuilt, so a nil index on the next recompute really means "nothing tagged here".
  private var moodIndexJustLanded = false

  /// The inputs a Lately mix is drawn from. Deliberately not the local lately profile
  /// (it shifts on every play) and not the time: those would reshuffle the tile under the
  /// person's finger.
  private struct LatelyMixKey: Equatable {
    /// The day it is drawn for: the mix is the same all day and new the next.
    let day: Date
    let tagCount: Int
    let sharedProfile: ListeningShelves.TagVector
    /// Tagged songs on the phone.
    let candidateCount: Int
    /// Whether the songs carry sound (BUG-498): the index can land after the profile does.
    let hasSound: Bool

    /// Whether a mix drawn from `self` should be drawn again for `new`: a new day, new tags,
    /// a new cloud profile, more tagged music on the phone, or sound arriving. Fewer songs
    /// does not reshuffle; the songs that left just drop out of the mix.
    func isOutdated(by new: LatelyMixKey) -> Bool {
      day != new.day || tagCount != new.tagCount || sharedProfile != new.sharedProfile
        || new.candidateCount > candidateCount || hasSound != new.hasSound
    }
  }

  /// The Lately mix's leading moods ("Wistful · Contemplative") for its page, kept with it.
  private var latelyDescription: String?

  /// phone-taste (founder, 2026-10-21): a playlist Home makes for you. Lately is one; the
  /// rest (this part of the day, Been a While and the mood mixes) are ListeningShelves'
  /// made-for-you mixes, drawn on the phone from songs on the phone.
  struct MadeForYouMix {
    enum Kind: Equatable {
      case lately
      case daypart
      case beenAWhile
      case mood(key: String, hexColor: String)
      /// One Home: Nostalgia's mix of songs from its span of years, by the shelf's id.
      case years(id: String)
    }

    let kind: Kind
    let title: String
    /// The answer line on the mix's page ("Wistful · Contemplative"), or nil.
    let subtitle: String?
    /// The songs a tap plays, in order.
    let songs: [AbstractPlayable]
    /// Up to four of the mix's albums for its picture, those with a cover on disk first.
    let leadAlbums: [Album]
    /// A mood mix's cover version (`ListeningShelves.moodCoverVariants`): the day's turn, or
    /// for Get Pumped the one its songs call for. Set when the mixes are built; nil for the
    /// other playlists.
    var coverVariant: String? = nil

    var id: String {
      switch kind {
      case .lately: return "lately"
      case .daypart: return "daypart"
      case .beenAWhile: return "been-a-while"
      case let .mood(key, _): return "mood:\(key)"
      case let .years(id): return id
      }
    }
  }

  /// Every made-for-you playlist in row order: Lately first, then the rest.
  var madeForYouMixes: [MadeForYouMix] {
    var all = [MadeForYouMix]()
    if let latelyMix, !latelyMix.songs.isEmpty {
      all.append(MadeForYouMix(
        kind: .lately,
        title: "Lately",
        subtitle: latelyDescription,
        songs: latelyMix.songs,
        leadAlbums: latelyMix.leadAlbums
      ))
    }
    return all + otherMixes
  }

  /// Moves whenever any made-for-you playlist's songs or pictures change, and only then,
  /// so Home redraws that row only when there is something new to draw.
  var madeForYouSignature: [Int] {
    [latelyMix?.generation ?? -1, otherMixesGeneration]
  }

  /// The made-for-you playlists after Lately.
  private(set) var otherMixes: [MadeForYouMix] = []
  private var otherMixesGeneration = 0
  /// What `otherMixes` were drawn from; they are drawn again only when this changes.
  private var otherMixesKey: OtherMixesKey?

  private struct OtherMixesKey: Equatable {
    /// The day they were seeded for (each is the same all day, new the next).
    let day: Date
    let weekend: Bool
    let daypart: ListeningShelves.Daypart
    let tagCount: Int
    let candidateCount: Int
    /// Whether the songs carry sound: the day it first arrives redraws them once.
    let hasSound: Bool
    /// The time-of-day mix leaves out Lately's songs, so a new Lately redraws it.
    let latelySongIDs: [String]
  }

  /// More Like Lately's ranking and what it was ranked from (see updateLatelyShelves).
  private var moreLikeCache: (key: LatelyMixKey, at: Date, ids: [String])?
  private static let moreLikeLifetime: TimeInterval = 5 * 60

  /// phone-taste: the Resume card's second line, for the record now on the card.
  struct ResumeLine {
    /// `stableID(for:)` of the record it belongs to.
    let stableID: String
    let text: String?
  }

  /// Built once per recompute (not per apply), so redrawing the card is free.
  private(set) var resumeLine: ResumeLine?

  init(
    account: Account,
    storage: PersistentStorage,
    getMeta: @escaping (_ accountInfo: AccountInfo) -> MetaManager,
    eventLogger: EventLogger,
    player: PlayerFacade,
    buildsForgottenShelf: Bool = false
  ) {
    self.account = account
    self.storage = storage
    self.getMeta = getMeta
    self.eventLogger = eventLogger
    self.player = player
    self.buildsForgottenShelf = buildsForgottenShelf
    self.cloudHome = CloudHome.shared(account: account, storage: storage, player: player)
    // cassette Patch 042: four-shelf IA is fixed. Legacy
    // `accountSettings.homeSections` is left on disk untouched so a
    // future rollback or re-introduction of editable shelves can
    // still decode it, but it no longer influences what renders.
    // One Home: the cloud's order replaces this as soon as an answer is held.
    self.orderedVisibleSections = HomeSection.defaultValue
    super.init()
    // One Home: the cloud's rows changed (a new answer, music came or went, a play started).
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleCloudHomeChanged),
      name: CloudHome.didChange,
      object: nil
    )
    // Recompute Recent whenever playback transitions so the first
    // card reflects the live queue (or vanishes when the user stops
    // and the recency list still wants the next item).
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePlayerChanged),
      name: .playerPlay,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePlayerChanged),
      name: .playerPause,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePlayerChanged),
      name: .playerStop,
      object: nil
    )
    // phone-taste: the mood index Home reads through `LatelyLibrary.moodIndexIfReady` is
    // built off the main thread; rebuild the rows once it lands.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMoodIndexReady),
      name: .cassetteMoodIndexReady,
      object: nil
    )
    // cassette 2026-10-21: a station saved or unsaved (here, on the dial, or on the web)
    // moves to the front of the Radio row.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRadioSavedChanged),
      name: RadioSaved.didChange,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    // pendingRecompute uses [weak self], so a stale fire after dealloc no-ops;
    // no explicit cancel needed (and deinit is nonisolated, can't touch it).
  }

  func createFetchController() {
    playlistsLastPlayedFetch = PlaylistFetchedResultsController(
      coreDataCompanion: storage.main, account: account,
      sortType: .lastPlayed,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.songSampleLimit
    )
    playlistsLastPlayedFetch?.delegate = self
    playlistsLastPlayedFetch?.search(
      searchText: "",
      playlistSearchCategory: isOfflineMode ? .cached : .all
    )

    // Bounded song samples — recency, affinity, newest-added. Aggregated per
    // album/artist in memory (see scoreContainers); no writes on the play
    // path. Reuses SongsFetchedResultsController so we inherit the per-account
    // / exclude-server-deleted predicates and `keepAllResultsUpdated = false`.
    recentSongsFetch = makeSongSample(sortType: .lastPlayedDate)
    topSongsFetch = makeSongSample(sortType: .playCount)
    newestSongsFetch = makeSongSample(sortType: .addedDate)

    // Stable at-large backfill (alphabetical) so shelves fill to target on a
    // tiny library without leaning on the unset server indices.
    albumsAllFetch = AlbumFetchedResultsController(
      coreDataCompanion: storage.main, account: account,
      sortType: .name,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.libraryBackfillLimit
    )
    albumsAllFetch?.delegate = self
    albumsAllFetch?.search(searchText: "", onlyCached: isOfflineMode, displayFilter: .all)

    artistsAllFetch = ArtistFetchedResultsController(
      coreDataCompanion: storage.main, account: account,
      sortType: .name,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.libraryBackfillLimit
    )
    artistsAllFetch?.delegate = self
    artistsAllFetch?.search(searchText: "", onlyCached: isOfflineMode, displayFilter: .all)

    // cassette (Forgotten Albums): iOS-only owned-album candidate FRC. In
    // on-device-only mode the AlbumFetchedResultsController's ownership predicate
    // already constrains this to owned albums.
    if buildsForgottenShelf {
      forgottenAlbumsFetch = AlbumFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        sortType: .newest,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.forgottenCandidateFetchLimit
      )
      forgottenAlbumsFetch?.delegate = self
      forgottenAlbumsFetch?.search(searchText: "", onlyCached: isOfflineMode, displayFilter: .all)
    }

    recomputeAllShelves()
  }

  private func makeSongSample(sortType: SongElementSortType) -> SongsFetchedResultsController {
    let frc = SongsFetchedResultsController(
      coreDataCompanion: storage.main,
      account: account,
      sortType: sortType,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.songSampleLimit
    )
    frc.delegate = self
    frc.search(searchText: "", onlyCachedSongs: isOfflineMode, displayFilter: .all)
    return frc
  }

  func updateFromRemote() {
    guard storage.settings.user.isOnlineMode else {
      print("Cassette recency: updateFromRemote SKIPPED — app is in offline mode")
      return
    }
    // cassette 2026-10-21: the saved stations from the cloud (a change reorders the Radio row).
    Task { @MainActor in await RadioSaved.shared.refresh() }
    // One Home: the cloud's Home, when the one held is half an hour old (or none is).
    Task { @MainActor in await HomeStore.shared.refreshIfDue() }
    Task { @MainActor in
      do {
        try await AutoDownloadLibrarySyncer(
          storage: self.storage,
          account: self.account,
          librarySyncer: self.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.getMeta(self.account.info)
            .playableDownloadManager
        )
        .syncNewestLibraryElements(offset: 0, count: Self.sectionMaxItemCount)
      } catch {
        // cassette Patch 040: Home tab background sync — silenced.
        self.eventLogger.report(
          topic: "Recently Added Sync",
          error: error,
          isBackground: true
        )
      }
    }
    Task { @MainActor in
      do {
        try await self.getMeta(self.account.info).librarySyncer
          .syncRecentAlbums(
            offset: 0,
            count: Self.sectionMaxItemCount
          )
      } catch {
        self.eventLogger.report(
          topic: "Recent Sync",
          error: error,
          isBackground: true
        )
      }
    }
    Task { @MainActor in
      do {
        try await self.getMeta(self.account.info).librarySyncer
          .syncDownPlaylistsWithoutSongs()
      } catch {
        self.eventLogger.report(
          topic: "Playlists Sync",
          error: error,
          isBackground: true
        )
      }
    }
    // cassette: fold plays made on the user's OTHER devices (e.g. their
    // computer) into local recency, so the Home "Recent" shelf reflects
    // cross-device listening. Advance-only; read-only against the network.
    Task { @MainActor in
      let changed = await CloudPlayReconciler.reconcile(
        storage: self.storage,
        account: self.account
      )
      if changed { self.scheduleRecompute() }
    }
  }

  // MARK: - Shelf builders

  /// cassette Patch 042: stable composite key per container so
  /// diffable snapshots animate predictably and so cross-shelf
  /// dedupe is a single `Set<String>` membership check. Falls back
  /// to `ObjectIdentifier` for any container type we haven't
  /// special-cased; never needs to fire today since every Home cell
  /// is a recognized library entity.
  static func stableID(for container: PlayableContainable) -> String {
    if let album = container as? Album { return "album-\(album.id)" }
    if let playlist = container as? Playlist { return "playlist-\(playlist.id)" }
    if let artist = container as? Artist { return "artist-\(artist.id)" }
    if let podcast = container as? Podcast { return "podcast-\(podcast.id)" }
    if let episode = container as? PodcastEpisode { return "podcastEpisode-\(episode.id)" }
    if let radio = container as? Radio { return "radio-\(radio.id)" }
    if let genre = container as? Genre { return "genre-\(genre.id)" }
    return "obj-\(ObjectIdentifier(container as AnyObject).hashValue)"
  }

  /// Debounced entry point (Part 2a): coalesce a burst of FRC-change / player-
  /// transition callbacks into one recompute after the burst settles, so a play
  /// action or library sync applies a single snapshot instead of ~30.
  private func scheduleRecompute() {
    if let isHostVisible, !isHostVisible() {
      // Host (phone Home) is off-window — e.g. CarPlay is driving playback. Rebuilding
      // and applying an animated snapshot to an off-window collection view is the
      // production crash; defer and let the host flush one recompute on reappearance.
      needsRecomputeWhileHidden = true
      return
    }
    pendingRecompute?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.recomputeAllShelves() }
    pendingRecompute = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.recomputeDebounce, execute: work)
  }

  /// Rebuild the rows soon, e.g. after the mood tags change: the same debounced recompute
  /// a library change triggers, deferred while Home is off screen.
  func refreshListeningShelves() {
    scheduleRecompute()
  }

  /// Drop LatelyLibrary's cached mood index (new tags, or music came or went). The next
  /// recompute starts a rebuild off the main thread and keeps the current More Like and
  /// Lately rows, minus anything no longer on the phone, until it lands.
  func invalidateMoodIndex() {
    LatelyLibrary.invalidate()
    moodIndexJustLanded = false
  }

  /// Flushed by the host (phone Home) when it becomes visible again: runs one
  /// coalesced recompute if any were deferred while the host was off-window.
  public func recomputeIfDeferred() {
    guard needsRecomputeWhileHidden else { return }
    needsRecomputeWhileHidden = false
    scheduleRecompute()
  }

  /// Fire the host's snapshot callback, unless we're mid-rebuild — during a
  /// `recomputeAllShelves` the per-builder calls are suppressed and collapse into
  /// the single apply that recompute fires when the whole rebuild finishes.
  private func notifySnapshot() {
    guard !isBatchingSnapshot else { return }
    applySnapshotCB?()
  }

  /// Rebuild the song-derived scores once, then every shelf. Order is Recent →
  /// Resume → Playlists → Albums → Artists. Then the softer rows give way to the
  /// rows above them (`cascadeSofterRows`).
  private func recomputeAllShelves() {
    // Suppress the per-builder snapshot callbacks and fire exactly one apply for
    // the whole rebuild (via defer, so it still fires if a builder bails early).
    isBatchingSnapshot = true
    isRecomputing = true
    defer {
      isBatchingSnapshot = false
      isRecomputing = false
      applySnapshotCB?()
    }
    // One Home (founder, 2026-10-28): the cloud's rows, in its order and under its names,
    // whenever an answer is held and the phone holds some of it. Everything below is the
    // phone's own Home, which only stands in until then.
    cloudHome.refresh()
    if applyCloudHome() { return }
    orderedVisibleSections = standInSections
    cloudHeadings = [:]
    reachShelf = nil
    allShelvesCount = 0
    resumeStartSong = nil
    let songs = sampledSongs()
    albumScores = scoreContainers(from: songs) { $0.album }
    artistScores = scoreContainers(from: songs) { $0.artist }
    rankedAlbumIDs = rankedContainerIDs(albumScores)

    updateRecent()
    updateListeningShelves()
    updatePlaylists()
    updateAlbums()
    updateRadios()
    // cassette: the Albums + Artists shelves now run the SHARED home-shelf engine
    // (the same algorithm as web + Android, kept in sync by the conformance
    // fixtures). Built ONCE from Core Data here, AFTER Recent so its items can be
    // excluded. The old updateRecentArtists / updateForgottenAlbums are retired in
    // favour of the engine (their forgotten/deep-dive logic is what the engine was
    // ported from; the engine additionally gives Artists the added/cold/affinity
    // blend iOS lacked).
    let shelfInput = buildShelfInput()
    updateArtistsViaEngine(shelfInput)
    // cassette (Forgotten Albums): iOS-only anti-recency shelf, now engine-backed.
    if buildsForgottenShelf {
      updateAlbumsViaEngine(shelfInput)
    }
    cascadeSofterRows()
    // cassette 2026-10-20: More Like Lately takes the Albums row's place when it has
    // something; Albums stays as the fallback until mood tags arrive.
    if !(data[.moreLikeLately] ?? []).isEmpty {
      data[.forgottenAlbums] = []
    }
  }

  /// The rows that suggest rather than report: they give way to the rows above them.
  private static let softerRows: Set<HomeSection> = [
    .aroundNow, .fromYourMixes, .moreLikeLately, .forgottenAlbums,
  ]

  /// Home's rows in cascading priority (founder, 2026-10-21: "everything else is a softer
  /// recommendation and should emphasize variety over accuracy"). Resume and On Repeat
  /// report what you play and stay exact. The softer rows (this time of day, From Your
  /// Mixes, More Like, Albums) leave out any record, and any artist, already shown in a row
  /// above them, and show one record per artist, so scrolling down keeps turning up
  /// something new.
  /// Runs once at the end of a recompute, over the rows in the order Home shows them; the
  /// softer rows arrive uncapped so what they give way to is backfilled from further down.
  private func cascadeSofterRows() {
    var shownAlbums = Set<String>()
    var shownArtists = Set<String>()
    for section in orderedVisibleSections {
      var items = data[section] ?? []
      if Self.softerRows.contains(section) {
        var rowArtists = Set<String>()
        items = items.filter { item in
          guard let album = item.playableContainable as? Album else { return true }
          let artist = Self.artistKey(of: album)
          return !shownAlbums.contains(album.id) && !shownArtists.contains(artist)
            && rowArtists.insert(artist).inserted
        }
        items = Array(items.prefix(Self.shelfCarouselCap))
        data[section] = items
      }
      for item in items {
        guard let album = item.playableContainable as? Album else { continue }
        shownAlbums.insert(album.id)
        shownArtists.insert(Self.artistKey(of: album))
      }
    }
  }

  /// An album's artist as the cascade compares them: the normalised name, else the id.
  private static func artistKey(of album: Album) -> String {
    let key = ListeningShelves.normalizedArtistName(album.artist?.name ?? "")
    return key.isEmpty ? album.id : key
  }

  // MARK: - One Home (the cloud's rows)

  /// Lays out the cloud's Home (CloudHome): its rows in its order and under its names, each
  /// with what the phone holds of it; a row the phone can't fill is left out. The cloud has
  /// already kept each record to one row, so nothing here trims one row against another.
  /// Returns false when there is nothing of it to draw: the phone's own rows stand in.
  private func applyCloudHome() -> Bool {
    guard cloudHome.isDrawn else { return false }
    let isOnPhone = makeOnPhoneCheck()
    var sections = [HomeSection]()
    var headings = [HomeSection: (shout: String, answer: String)]()
    data = [:]
    reachShelf = nil
    allShelvesCount = 0
    resumeLine = nil
    resumeStartSong = nil
    var mixes = [MadeForYouMix]()
    for row in cloudHome.drawnRows where !sections.contains(row.section) {
      sections.append(row.section)
      headings[row.section] = (row.shout, row.answer)
      switch row.section {
      case .moodDoors:
        mixes = row.mixes
      case .reach:
        guard let shelf = row.shelf else { continue }
        reachShelf = shelf
        data[.reach] = Self.reachItems(shelf)
      case .allShelves:
        allShelvesCount = row.shelfCount
      default:
        data[row.section] = row.items.map {
          HomeItem(section: row.section, stableID: Self.stableID(for: $0), playableContainable: $0)
        }
      }
      if row.section == .resume, let container = row.items.first {
        resumeStartSong = row.song
        resumeLine = ResumeLine(
          stableID: Self.stableID(for: container),
          text: cloudResumeLine(for: container, song: row.song, isOnPhone: isOnPhone)
        )
      }
    }
    preferPlayerForResume(sections: &sections, isOnPhone: isOnPhone)
    applyCloudMixes(mixes)
    orderedVisibleSections = sections
    cloudHeadings = headings
    return true
  }

  /// The player wins (I-S10): Resume never names one record while the mini player holds
  /// another. Songs from a record on this phone: that record is the card, swapped in place. A
  /// station leaves the card on the last record, the way back to it: taking the card away
  /// slid every shelf up the moment a station started (the founder, 2026-10-31).
  private func preferPlayerForResume(sections: inout [HomeSection], isOnPhone: OnPhoneCheck) {
    guard let playing = player.currentlyPlaying, !playing.isRadio else { return }
    // The card's record, playlist or artist already holds the song on now: nothing to change.
    guard let song = playing.asSong, let live = song.album, isOnPhone(live),
          let shown = data[.resume]?.first,
          !Self.song(song, belongsTo: shown.playableContainable)
    else { return }
    data[.resume] = [HomeItem(section: .resume, stableID: Self.stableID(for: live), playableContainable: live)]
    resumeStartSong = nil
    resumeLine = ResumeLine(
      stableID: Self.stableID(for: live),
      text: cloudResumeLine(for: live, song: nil, isOnPhone: isOnPhone)
    )
  }

  /// The made-for-you row's playlists from the cloud's Home (Lately first), kept as Home's
  /// Lately mix and other mixes, which the row, the playlist pages and the car read.
  private func applyCloudMixes(_ mixes: [MadeForYouMix]) {
    mixesFromCloud = true
    // the stand-in lays its own set out afresh if it ever draws again
    appliedFeedSignature = nil
    latelyMixKey = nil
    otherMixesKey = nil
    let lately = mixes.first { $0.kind == .lately }
    latelyDescription = lately?.subtitle
    if let lately {
      publishLatelyMix(lately.songs)
    } else if latelyMix != nil {
      latelyMix = nil
      latelyMixGeneration += 1
    }
    setOtherMixes(mixes.filter { $0.kind != .lately })
  }

  /// The reaching row's tiles: Deep dive's one record (its big card), else Nostalgia's mix
  /// first and the shelf's records after it.
  private static func reachItems(_ shelf: CloudHome.Shelf) -> [HomeItem] {
    if shelf.isDeepDive {
      return shelf.albums.prefix(1).map {
        HomeItem(section: .reach, stableID: stableID(for: $0), playableContainable: $0)
      }
    }
    var items = [HomeItem]()
    if let mix = shelf.mix, let art = mix.leadAlbums.first ?? shelf.albums.first {
      items.append(HomeItem(section: .reach, stableID: "mix-\(mix.id)", playableContainable: art, mixID: mix.id))
    }
    items += shelf.albums.prefix(shelfCarouselCap).map {
      HomeItem(section: .reach, stableID: stableID(for: $0), playableContainable: $0)
    }
    return items
  }

  /// The reaching row's Nostalgia mix, by its id.
  func reachMix(id: String) -> MadeForYouMix? {
    reachShelf?.mix.flatMap { $0.id == id ? $0 : nil }
  }

  /// Resume's second line: the song playing now when it belongs to the card's record, else
  /// the song the cloud says was played last, else the record's latest played song here.
  private func cloudResumeLine(
    for container: PlayableContainable,
    song: Song?,
    isOnPhone: OnPhoneCheck
  )
    -> String? {
    if let playing = player.currentMusicItem?.asSong, Self.song(playing, belongsTo: container) {
      return playing.title
    }
    if let song { return song.title }
    return latestPlayableSongTitle(in: container, isOnPhone: isOnPhone) ?? container.subtitle
  }

  // MARK: - Play scoring (Home Shelves v1 foundation)

  /// Deduplicated union of the bounded song samples (recency + most-played +
  /// newest-added). Each song is wrapped once so affinity sums aren't inflated
  /// by a song appearing in more than one sample.
  private func sampledSongs() -> [Song] {
    var seen = Set<NSManagedObjectID>()
    var songs: [Song] = []
    for fetch in [recentSongsFetch, topSongsFetch, newestSongsFetch] {
      for mo in (fetch?.fetchedObjects as? [SongMO]) ?? [] where seen.insert(mo.objectID).inserted {
        songs.append(Song(managedObject: mo))
      }
    }
    return songs
  }

  /// Fold a song sample into per-container scores keyed by stable id. `key`
  /// extracts the album/artist for a song, or nil to skip it.
  private func scoreContainers<C: PlayableContainable>(
    from songs: [Song],
    key: (Song) -> C?
  )
    -> [String: (container: C, score: ShelfScore)] {
    var out: [String: (container: C, score: ShelfScore)] = [:]
    for song in songs {
      guard let container = key(song) else { continue }
      let id = Self.stableID(for: container)
      var entry = out[id] ??
        (container: container, score: ShelfScore(lastPlayed: nil, playCount: 0, newestAdded: nil))
      if let lastPlayed = song.lastTimePlayed,
         entry.score.lastPlayed == nil || lastPlayed > entry.score.lastPlayed! {
        entry.score.lastPlayed = lastPlayed
      }
      entry.score.playCount += song.playCount
      if let added = song.addedDate,
         entry.score.newestAdded == nil || added > entry.score.newestAdded! {
        entry.score.newestAdded = added
      }
      out[id] = entry
    }
    return out
  }

  /// Rank container ids: played first (most-recent play, then affinity), then
  /// unplayed by recency-of-addition, then a stable id tiebreak so the order
  /// doesn't reshuffle across Home reloads.
  private func rankedContainerIDs<C>(
    _ scored: [String: (container: C, score: ShelfScore)]
  )
    -> [String] {
    scored.keys.sorted { lhs, rhs in
      guard let a = scored[lhs]?.score, let b = scored[rhs]?.score else { return lhs < rhs }
      let aPlayed = a.lastPlayed != nil, bPlayed = b.lastPlayed != nil
      if aPlayed != bPlayed { return aPlayed }
      if aPlayed, let la = a.lastPlayed, let lb = b.lastPlayed, la != lb { return la > lb }
      if a.playCount != b.playCount { return a.playCount > b.playCount }
      let na = a.newestAdded ?? .distantPast, nb = b.newestAdded ?? .distantPast
      if na != nb { return na > nb }
      return lhs < rhs
    }
  }

  /// Heterogeneous merge: recently-played albums + playlists +
  /// recently-played-artists (deduped from the song fetch). Folds
  /// in newest albums when nothing has been played yet so a brand-
  /// new library still shows fresh content. Prepends the live
  /// queue's source album.
  func updateRecent() {
    var entries: [(date: Date, container: PlayableContainable, id: String)] = []

    // cassette Home Shelves v1 — album vs. artist recency are DELIBERATELY
    // asymmetric here; do not "unify" them:
    //  • Albums use song-derived recency (scored.score.lastPlayed). Load-bearing:
    //    an album can reach Recent via a non-containable play context (queue,
    //    mix) where Album.playedViaContext() never fires, so the song rollup is
    //    the only path that surfaces it. (BUG-037: album.lastTimePlayed IS
    //    written on PlayContext(containable: album) — just not on those
    //    queue/mix paths — hence the rollup.)
    //  • Artists use the container signal (scored.container.lastTimePlayed,
    //    written by Artist.playedViaContext()). An artist only reaches a queue by
    //    being CHOSEN as an artist, which always writes that signal — so the song
    //    rollup would re-surface an artist whenever an album of theirs played
    //    ("Bleachers doubling", BUG-038). Ranking by the container signal means an
    //    album play no longer promotes the artist into Recent. Same read-side fix
    //    as BUG-036 on the Artists shelf (updateRecentArtists), second builder.
    for (id, scored) in albumScores {
      if let date = scored.score.lastPlayed {
        entries.append((date, scored.container, id))
      }
    }
    for (id, scored) in artistScores {
      if let date = scored.container.lastTimePlayed {
        entries.append((date, scored.container, id))
      }
    }
    if let playlistMOs = playlistsLastPlayedFetch?.fetchedObjects as? [PlaylistMO] {
      for mo in playlistMOs.prefix(Self.shelfCarouselCap) {
        let playlist = Playlist(library: storage.main.library, managedObject: mo)
        if let date = playlist.lastTimePlayed {
          entries.append((date, playlist, Self.stableID(for: playlist)))
        }
      }
    }

    entries.sort { $0.date > $1.date }

    var merged: [PlayableContainable] = []
    var seenIDs = Set<String>()
    for entry in entries {
      if seenIDs.insert(entry.id).inserted {
        merged.append(entry.container)
      }
    }

    // First-run fallback: nothing played yet → fold in newest content (the
    // song-derived ranking already leads with newest-added albums, then the
    // stable at-large list) so a freshly synced library isn't empty.
    if merged.isEmpty {
      for id in rankedAlbumIDs {
        guard let album = albumScores[id]?.container, seenIDs.insert(id).inserted else { continue }
        merged.append(album)
        if merged.count >= Self.shelfCarouselCap { break }
      }
      if merged.count < Self.shelfTargetCount,
         let albumMOs = albumsAllFetch?.fetchedObjects as? [AlbumMO] {
        for mo in albumMOs {
          let album = Album(managedObject: mo)
          let id = Self.stableID(for: album)
          guard seenIDs.insert(id).inserted else { continue }
          merged.append(album)
          if merged.count >= Self.shelfTargetCount { break }
        }
      }
    }

    // Prepend live queue's source album if present and not already
    // in the top slot. Drop any later occurrence so the live album
    // only appears once.
    var hasLiveAlbum = false
    if let song = player.currentlyPlaying?.asSong, let liveAlbum = song.album {
      hasLiveAlbum = true
      let liveID = Self.stableID(for: liveAlbum)
      let isAlreadyTop = merged.first.map { Self.stableID(for: $0) == liveID } ?? false
      if !isAlreadyTop {
        merged.removeAll { Self.stableID(for: $0) == liveID }
        merged.insert(liveAlbum, at: 0)
      }
    }

    // cassette redesign (Surface 4): the head of the merged recency list
    // becomes the Resume card (live queue first, otherwise the most
    // recently played container) and drops out of the Recent shelf. On a
    // fresh library with no play history (first-run fallback only) there
    // is nothing to resume, so the card hides.
    //
    // cassette (BUG-436): a phone shows only what is on it. Play history is the
    // same everywhere (it lives in the account), but an album, artist or playlist
    // with nothing on this phone has no music and no art here, so it drops out of
    // Resume and Recent alike. That includes the album of a queued song that is not
    // on the phone. Server Mode keeps everything.
    let hasPlayHistory = hasLiveAlbum || !entries.isEmpty
    let isOnPhone = makeOnPhoneCheck()
    merged.removeAll { !isOnPhone($0) }
    if hasPlayHistory, !merged.isEmpty {
      let resumeIndex = 0
      let resumeContainer = merged[resumeIndex]
      // Section-scoped HomeItem identity already makes Resume vs a shelf a
      // distinct item, so a container moving between them is a delete+insert
      // that re-runs the cell provider — the Patch-104 "resume:" stableID
      // prefix is no longer needed.
      data[.resume] = [HomeItem(
        section: .resume,
        stableID: Self.stableID(for: resumeContainer),
        playableContainable: resumeContainer
      )]
      resumeLine = ResumeLine(
        stableID: Self.stableID(for: resumeContainer),
        text: resumeLineText(for: resumeContainer, isOnPhone: isOnPhone)
      )
      merged.remove(at: resumeIndex)
    } else {
      data[.resume] = []
      resumeLine = nil
    }

    data[.recent] = merged.prefix(Self.shelfCarouselCap).map {
      HomeItem(section: .recent, stableID: Self.stableID(for: $0), playableContainable: $0)
    }
    notifySnapshot()
  }

  // MARK: - Resume line

  /// The Resume card's second line answers "where was I" with a song: the song playing
  /// now when it belongs to the card's record; else the record's most recently played
  /// song that the card's play disc can actually play (on this phone, or cached while
  /// offline in Server Mode; plays from other devices count, via CloudPlayReconciler);
  /// else the record's own subtitle. Two bounded fetches, never a walk of the record.
  private func resumeLineText(
    for container: PlayableContainable,
    isOnPhone: OnPhoneCheck
  )
    -> String? {
    if let song = player.currentMusicItem?.asSong, Self.song(song, belongsTo: container) {
      return song.title
    }
    return latestPlayableSongTitle(in: container, isOnPhone: isOnPhone) ?? container.subtitle
  }

  /// Whether `song` belongs to `container`: the same album, a song by the artist (its own
  /// artist or its album's), or a song in the playlist. A playlist is asked with a count
  /// fetch, not by walking its items.
  static func song(_ song: Song, belongsTo container: PlayableContainable) -> Bool {
    if let album = container as? Album {
      return !album.id.isEmpty && song.album?.id == album.id
    }
    if let artist = container as? Artist {
      guard !artist.id.isEmpty else { return false }
      return song.artist?.id == artist.id || song.album?.artist?.id == artist.id
    }
    if let playlist = container as? Playlist {
      guard let context = playlist.managedObject.managedObjectContext else { return false }
      let request: NSFetchRequest<PlaylistItemMO> = PlaylistItemMO.fetchRequest()
      request.predicate = NSPredicate(
        format: "playlist == %@ AND playable == %@",
        playlist.managedObject,
        song.managedObject
      )
      request.fetchLimit = 1
      return ((try? context.count(for: request)) ?? 0) > 0
    }
    return false
  }

  /// How many of the record's most recently played songs to look through for one the
  /// disc can play. Enough for an album; for a big artist or playlist whose recent plays
  /// are all elsewhere, the line falls back to the record's subtitle.
  private static let resumeLineCandidateLimit = 25

  /// The title of the record's most recently played song among those the play disc plays
  /// (`OneTapPlay.playables`: an album's or an artist's own songs, a playlist's songs),
  /// keeping only songs on the phone (or cached while offline in Server Mode).
  private func latestPlayableSongTitle(
    in container: PlayableContainable,
    isOnPhone: OnPhoneCheck
  )
    -> String? {
    let scope: NSPredicate
    if let album = container as? Album {
      scope = NSPredicate(format: "album == %@", album.managedObject)
    } else if let artist = container as? Artist {
      scope = NSPredicate(format: "artist == %@", artist.managedObject)
    } else if let playlist = container as? Playlist {
      scope = NSPredicate(format: "ANY playlistItems.playlist == %@", playlist.managedObject)
    } else {
      return nil
    }
    var predicates = [scope, NSPredicate(format: "lastPlayedDate != nil")]
    if isOnPhone.owned == nil, isOfflineMode {
      predicates.append(NSPredicate(format: "relFilePath != nil"))
    }
    let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    request.sortDescriptors = [NSSortDescriptor(key: "lastPlayedDate", ascending: false)]
    request.fetchLimit = Self.resumeLineCandidateLimit
    let candidates = (try? storage.main.context.fetch(request)) ?? []
    for songMO in candidates {
      let song = Song(managedObject: songMO)
      if isOnPhone.contains(song) { return song.title }
    }
    return nil
  }

  /// cassette (BUG-436): whether a Home item has anything on this phone. Albums and
  /// artists by their owned-id sets, playlists by holding at least one song that is
  /// here (a partly synced playlist stays, and lists only its songs on the phone).
  /// The id sets are resolved once per call, not per item. Always true in Server Mode.
  private func makeOnPhoneCheck() -> OnPhoneCheck {
    Self.makeOnPhoneCheck(storage: storage)
  }

  /// The same, for CloudHome.
  static func makeOnPhoneCheck(storage: PersistentStorage) -> OnPhoneCheck {
    guard CassetteLibraryFilterProvider.shared.isOnDeviceOnly else {
      return OnPhoneCheck(owned: nil)
    }
    let ownership = DeviceOwnershipManager(context: storage.main.context)
    return OnPhoneCheck(owned: (
      albumIds: ownership.fetchOwnedAlbumIds(),
      artistIds: ownership.fetchOwnedArtistIds(),
      trackIds: ownership.fetchAllSubsonicTrackIds()
    ))
  }

  /// The owned-id sets for one pass, callable on a Home item (`isOnPhone(album)`) and on a
  /// song. `owned` nil is Server Mode, where everything counts.
  struct OnPhoneCheck {
    let owned: (albumIds: Set<String>, artistIds: Set<String>, trackIds: Set<String>)?

    func callAsFunction(_ container: PlayableContainable) -> Bool {
      guard let owned else { return true }
      if let album = container as? Album { return owned.albumIds.contains(album.id) }
      if let artist = container as? Artist { return owned.artistIds.contains(artist.id) }
      if let playlist = container as? Playlist {
        return playlist.managedObject.items.contains { owned.trackIds.contains($0.playable.id) }
      }
      return true
    }

    /// A song is on the phone when its id is in the ownership set; anything that is not a
    /// song passes.
    func contains(_ playable: AbstractPlayable) -> Bool {
      guard let owned, let song = playable.asSong else { return true }
      return owned.trackIds.contains(song.id)
    }
  }

  /// cassette 2026-10-20: On Repeat and Around This Time, ranked from the phone's own
  /// play log (one timestamped entry per completed play) by ListeningShelves. Only albums
  /// on this phone; overlap with Recent is allowed. A row with too little history to say
  /// anything stays empty, and an empty row is hidden.
  func updateListeningShelves() {
    let now = Date()
    let since = now.addingTimeInterval(-Double(ListeningShelves.lookbackDays) * 86400)
    let entries = storage.main.library.getScrobbleEntries(
      for: account,
      since: since,
      fetchLimit: Self.listeningPlayFetchLimit
    )
    // The same newest-first fetch also feeds the lately pass: its last 30 days are what
    // LatelyLibrary's own 30-day fetch would return.
    let latelySince = now.addingTimeInterval(-Double(Self.latelyWindowDays) * 86400)
    let mixSince = now.addingTimeInterval(-Double(Self.mixRecentlyPlayedDays) * 86400)
    var albumsByID = [String: Album]()
    var plays = [ListeningPlay]()
    var lately = LatelyPlays()
    // Every play in the lookback, for the made-for-you mixes (the time-of-day one reads two
    // months of habit).
    var songPlays = [(date: Date, songID: String)]()
    for entry in entries {
      guard let date = entry.date, let song = entry.playable?.asSong else { continue }
      songPlays.append((date, song.id))
      let album = song.album
      let albumID = album?.id ?? ""
      if date >= latelySince {
        lately.songPlays.append((date, song.id))
        if !albumID.isEmpty { lately.albums.insert(albumID) }
        if date >= mixSince { lately.songsJustPlayed.insert(song.id) }
      }
      guard let album, !albumID.isEmpty else { continue }
      albumsByID[albumID] = album
      plays.append(ListeningPlay(date: date, albumID: albumID))
    }
    let isOnPhone = makeOnPhoneCheck()
    func items(_ ids: [String], _ section: HomeSection, capped: Bool = true) -> [HomeItem] {
      ids.compactMap { albumsByID[$0] }
        .filter { isOnPhone($0) }
        .prefix(capped ? Self.shelfCarouselCap : Int.max)
        .map { HomeItem(section: section, stableID: Self.stableID(for: $0), playableContainable: $0) }
    }
    data[.onRepeat] = items(ListeningShelves.onRepeat(plays, now: now), .onRepeat)
    data[.fromYourMixes] = items(Self.heardInPassing(entries, now: now), .fromYourMixes, capped: false)
    // Uncapped: cascadeSofterRows trims it against On Repeat, then caps it.
    data[.aroundNow] = items(ListeningShelves.aroundNow(plays, now: now), .aroundNow, capped: false)
    // The made-for-you playlists come from the cloud (MadeForYouStore), the same set every
    // device plays; the phone's own recipe only stands in when it holds none for this moment.
    let fromCloud = applyMadeForYouFeed(now: now, isOnPhone: isOnPhone)
    updateLatelyShelves(lately, now: now, isOnPhone: isOnPhone)
    if !fromCloud {
      updateMadeForYouMixes(songPlays: songPlays, lately: lately, now: now, isOnPhone: isOnPhone)
    }
  }

  /// From Your Mixes: records you heard one or two songs of in the last two weeks, most
  /// recently heard first. Nearly all of them come from the made-for-you playlists, which
  /// play single songs across many records; this is the nudge to go deeper on one. (Recent
  /// used to show these as if they were records you had been playing.) Uncapped:
  /// cascadeSofterRows trims it against the rows above, then caps it.
  private static func heardInPassing(_ entries: [ScrobbleEntry], now: Date) -> [String] {
    let since = now.addingTimeInterval(-Double(heardInPassingDays) * 86400)
    var songsByAlbum = [String: Set<String>]()
    var lastHeard = [String: Date]()
    for entry in entries {
      guard let date = entry.date, date >= since, date <= now, let song = entry.playable?.asSong,
            let albumID = song.album?.id, !albumID.isEmpty
      else { continue }
      songsByAlbum[albumID, default: []].insert(song.id)
      lastHeard[albumID] = max(lastHeard[albumID] ?? .distantPast, date)
    }
    return songsByAlbum
      .filter { $0.value.count <= heardInPassingMaxSongs }
      .keys
      .sorted { lastHeard[$0]! != lastHeard[$1]! ? lastHeard[$0]! > lastHeard[$1]! : $0 < $1 }
  }

  private static let heardInPassingDays = 14
  private static let heardInPassingMaxSongs = 2

  /// The last 30 days of plays as the lately pass needs them.
  private struct LatelyPlays {
    var songPlays = [(date: Date, songID: String)]()
    /// Albums with a play in the window (kept out of More Like Lately).
    var albums = Set<String>()
    /// Songs played in the last three days (kept out of the mix).
    var songsJustPlayed = Set<String>()
  }

  /// More Like Lately and the Lately mix, from the cached mood tags (LibraryMoods) and the
  /// phone's mood index. The index is read through `LatelyLibrary.moodIndexIfReady`, which
  /// never builds it on the main thread: on a miss it builds in the background and posts
  /// `.cassetteMoodIndexReady` (see `handleMoodIndexReady`), and Home keeps what it showed,
  /// minus anything that has left the phone, until then. Never `LatelyLibrary.snapshot`:
  /// on a cache miss that builds the index right here, on the main thread.
  private func updateLatelyShelves(_ lately: LatelyPlays, now: Date, isOnPhone: OnPhoneCheck) {
    let tags = LibraryMoods.shared.byLocalID
    let justLanded = moodIndexJustLanded
    moodIndexJustLanded = false
    guard let index = LatelyLibrary.moodIndexIfReady(storage: storage, account: account, now: now)
    else {
      if tags.isEmpty || justLanded {
        // No tags yet, or nothing tagged is on this phone: no More Like and no mix.
        moreLikeCache = nil
        data[.moreLikeLately] = []
        setLatelyMix(nil, key: nil)
      } else {
        // The index is still building (first open, or music came or went).
        data[.moreLikeLately] = (data[.moreLikeLately] ?? [])
          .filter { isOnPhone($0.playableContainable) }
        keepLatelyMix(isOnPhone: isOnPhone)
      }
      return
    }

    let sharedProfile = LibraryMoods.shared.sharedProfile
    let key = LatelyMixKey(
      day: Calendar.current.startOfDay(for: now),
      tagCount: tags.count,
      sharedProfile: sharedProfile,
      candidateCount: index.songCandidates.count,
      hasSound: index.hasSound
    )
    // The cloud's lately profile (every device's plays) when the phone has it, else one
    // built from this phone's own plays, as LatelyLibrary.snapshot builds it. Built only
    // when something below needs it.
    var builtProfile: ListeningShelves.TagVector?
    func profile() -> ListeningShelves.TagVector {
      if let builtProfile { return builtProfile }
      var result = sharedProfile
      if result.isEmpty {
        var tagsBySongID = [String: ListeningShelves.TagVector](
          minimumCapacity: index.songCandidates.count
        )
        for candidate in index.songCandidates {
          tagsBySongID[candidate.songID] = candidate.tags
        }
        result = ListeningShelves.latelyProfile(
          plays: lately.songPlays,
          tagsForSong: { tagsBySongID[$0] },
          now: now
        )
      }
      builtProfile = result
      return result
    }

    // More Like keeps its ranking for a few minutes, as the lately snapshot did, so a play
    // or a pause does not reshuffle the row.
    let moreLikeIDs: [String]
    if let cached = moreLikeCache, cached.key == key,
       now.timeIntervalSince(cached.at) < Self.moreLikeLifetime {
      moreLikeIDs = cached.ids
    } else {
      guard !profile().isEmpty else {
        // Nothing recent to build a profile from.
        moreLikeCache = nil
        data[.moreLikeLately] = []
        setLatelyMix(nil, key: nil)
        return
      }
      moreLikeIDs = ListeningShelves.moreLikeLately(
        index.albumCandidates,
        profile: profile(),
        playedRecently: lately.albums
      )
      moreLikeCache = (key, now, moreLikeIDs)
    }
    // Uncapped: cascadeSofterRows trims it against the rows above, then caps it.
    data[.moreLikeLately] = moreLikeIDs
      .compactMap { index.albumsByID[$0] }
      .filter { isOnPhone($0) }
      .map { album in
        HomeItem(
          section: .moreLikeLately,
          stableID: Self.stableID(for: album),
          playableContainable: album
        )
      }

    // The cloud's Lately when it is held (applyMadeForYouFeed); the rest is the stand-in.
    guard !mixesFromCloud else { return }
    // The mix is drawn again only when what it is drawn from changed (see LatelyMixKey);
    // otherwise it stays, minus songs that have left the phone.
    if latelyMix != nil, let drawnFrom = latelyMixKey, !drawnFrom.isOutdated(by: key) {
      latelyMixKey = key
      keepLatelyMix(isOnPhone: isOnPhone)
      return
    }
    guard !profile().isEmpty else {
      setLatelyMix(nil, key: nil)
      return
    }
    var rng = ListeningShelves.DailyGenerator(day: now, key: "lately")
    let ids = ListeningShelves.latelyMix(
      index.songCandidates,
      profile: profile(),
      playedRecently: lately.songsJustPlayed,
      count: Self.latelyMixLength,
      using: &rng
    )
    // No artist back within four songs where the mix allows it (founder, 2026-08-20).
    let spaced = ListeningShelves.spacedByArtist(ids) { id in
      Self.artistKey(of: index.songsByID[id])
    }
    let songs: [AbstractPlayable] = spaced
      .compactMap { index.songsByID[$0] }
      .filter { isOnPhone.contains($0) }
    let described = ListeningShelves.describe(profile())
    latelyDescription = described.isEmpty ? nil : described
    setLatelyMix(songs, key: key)
  }

  /// Replace the Lately mix (`songs` nil: no mix) and remember what it was drawn from.
  private func setLatelyMix(_ songs: [AbstractPlayable]?, key: LatelyMixKey?) {
    guard !mixesFromCloud else { return }
    latelyMixKey = key
    guard let songs else {
      latelyMix = nil
      return
    }
    publishLatelyMix(songs)
  }

  /// Keep the current mix, dropping songs that are no longer on the phone.
  private func keepLatelyMix(isOnPhone: OnPhoneCheck) {
    guard !mixesFromCloud, let current = latelyMix, isOnPhone.owned != nil else { return }
    let kept = current.songs.filter { isOnPhone.contains($0) }
    guard kept.count != current.songs.count else { return }
    publishLatelyMix(kept)
  }

  /// Store `songs` as the mix with its lead albums. The generation moves only when the
  /// songs or the lead albums actually differ from what is there. A song whose row is gone
  /// (deleted, or no longer in a context) is dropped first: the Lately tile on the phone and
  /// in the car must never hand the player a dead object.
  private func publishLatelyMix(_ candidates: [AbstractPlayable]) {
    let songs = candidates.filter {
      !$0.playableManagedObject.isDeleted && $0.playableManagedObject.managedObjectContext != nil
    }
    let lead = leadAlbums(for: songs)
    if let current = latelyMix,
       current.songs.map(\.id) == songs.map(\.id),
       current.leadAlbums.map(\.id) == lead.map(\.id) {
      return
    }
    latelyMixGeneration += 1
    latelyMix = LatelyMix(songs: songs, leadAlbums: lead, generation: latelyMixGeneration)
  }

  /// ListeningShelves' lately window and the mix's "played just now" window. They are
  /// internal to AmperfyKit, so Home mirrors them; keep the two in step.
  private static let latelyWindowDays = 30
  private static let mixRecentlyPlayedDays = 3

  private static let latelyMixLength = 40
  private static let latelyLeadAlbumCount = 4

  /// The first four distinct albums of the mix, in mix order, preferring those whose cover
  /// is on disk, then filling with any.
  private func leadAlbums(for songs: [AbstractPlayable]) -> [Album] {
    Self.leadAlbums(for: songs, storage: storage, account: account)
  }

  /// The same, for CloudHome.
  static func leadAlbums(
    for songs: [AbstractPlayable],
    storage: PersistentStorage,
    account: Account
  )
    -> [Album] {
    let setting = storage.settings.accounts.getSetting(account.info).read.artworkDisplayPreference
    var seen = Set<String>()
    var distinct = [Album]()
    for song in songs {
      guard let album = song.asSong?.album, !album.id.isEmpty, seen.insert(album.id).inserted
      else { continue }
      distinct.append(album)
    }
    let withCover = distinct.filter { album in
      guard let path = album.imagePath(setting: setting) else { return false }
      return FileManager.default.fileExists(atPath: path)
    }
    var lead = Array(withCover.prefix(Self.latelyLeadAlbumCount))
    var leadIDs = Set(lead.map(\.id))
    for album in distinct where lead.count < Self.latelyLeadAlbumCount {
      if leadIDs.insert(album.id).inserted { lead.append(album) }
    }
    return lead
  }

  /// Two months of plays is about a thousand entries for a heavy listener; the cap only
  /// bounds the fetch on a recompute.
  private static let listeningPlayFetchLimit = 5000

  // MARK: - Made for you (founder, 2026-10-21)

  /// Whether Lately and the other made-for-you playlists are the cloud's (MadeForYouStore).
  private var mixesFromCloud = false
  /// What the cloud's set was last laid out from: its day, part of the day, revision and
  /// the songs on the phone. The same again keeps the playlists as they are.
  private var appliedFeedSignature: String?

  /// Lays out the cloud's made-for-you playlists for this moment (Lately first, then the
  /// rest in its order) from the songs on the phone, and asks for a fresher set when one is
  /// due. A playlist under 15 songs on the phone is left out (Lately shows with any).
  /// Returns false when no set for this moment is held: the phone's own recipe stands in.
  private func applyMadeForYouFeed(now: Date, isOnPhone: OnPhoneCheck) -> Bool {
    let store = MadeForYouStore.shared
    Task { await store.refreshIfDue(now: now) }
    guard let feed = store.feed(for: now) else {
      if mixesFromCloud {
        mixesFromCloud = false
        appliedFeedSignature = nil
        latelyMixKey = nil
        otherMixesKey = nil
      }
      return false
    }
    let signature = "\(feed.day)|\(feed.slot)|\(store.revision)|\(isOnPhone.owned?.trackIds.count ?? -1)"
    if mixesFromCloud, signature == appliedFeedSignature { return true }
    mixesFromCloud = true
    appliedFeedSignature = signature

    let songIDByLocalID = songIDsByLocalID()
    let wanted = Set(feed.mixes.flatMap { $0.songs.compactMap { songIDByLocalID[$0] } })
    let songsByID = storage.main.library.getSongsByID(for: account, ids: wanted)
    var latelySongs: [AbstractPlayable] = []
    var latelySubtitle: String?
    var others = [MadeForYouMix]()
    for mix in feed.mixes {
      let songs: [AbstractPlayable] = mix.songs
        .compactMap { songIDByLocalID[$0].flatMap { songsByID[$0] } }
        .filter {
          isOnPhone.contains($0) && !$0.playableManagedObject.isDeleted
            && $0.playableManagedObject.managedObjectContext != nil
        }
      let kind: MadeForYouMix.Kind
      switch mix.kind {
      case "lately":
        latelySongs = songs
        latelySubtitle = mix.subtitle
        continue
      case "daypart": kind = .daypart
      case "been-a-while": kind = .beenAWhile
      case "mood": kind = .mood(key: String(mix.id.dropFirst("mood:".count)), hexColor: mix.color ?? "#6B5A44")
      default: continue
      }
      guard songs.count >= ListeningShelves.madeMixMinSongs else { continue }
      others.append(MadeForYouMix(
        kind: kind,
        title: mix.title,
        subtitle: mix.subtitle,
        songs: songs,
        leadAlbums: leadAlbums(for: songs),
        coverVariant: mix.cover?.variant
      ))
    }
    latelyDescription = latelySubtitle
    if latelySongs.isEmpty {
      if latelyMix != nil {
        latelyMix = nil
        latelyMixGeneration += 1
      }
    } else {
      publishLatelyMix(latelySongs)
    }
    setOtherMixes(others)
    return true
  }

  /// The playlists made for you after Lately: this part of the day, Been a While, then the
  /// mood mixes in the order this part of the day suits them. Each is seeded by the day, so
  /// it is the same all day and new the next. They are drawn in row order and a song goes
  /// to the first playlist that takes it, never to two (BUG-497). They are drawn again only
  /// when the day, the part of the day, the tags, the tagged music on the phone or Lately's
  /// songs change;
  /// otherwise they stay, minus songs that have left the phone. The mood index is read
  /// through `moodIndexIfReady`, never built here on the main thread.
  private func updateMadeForYouMixes(
    songPlays: [(date: Date, songID: String)],
    lately: LatelyPlays,
    now: Date,
    isOnPhone: OnPhoneCheck
  ) {
    let tags = LibraryMoods.shared.byLocalID
    guard let index = LatelyLibrary.moodIndexIfReady(storage: storage, account: account, now: now)
    else {
      if tags.isEmpty {
        otherMixesKey = nil
        setOtherMixes([])
      } else {
        keepOtherMixes(isOnPhone: isOnPhone)
      }
      return
    }
    let calendar = Calendar.current
    let daypart = ListeningShelves.daypart(of: now, calendar: calendar)
    let key = OtherMixesKey(
      day: calendar.startOfDay(for: now),
      weekend: calendar.isDateInWeekend(now),
      daypart: daypart,
      tagCount: tags.count,
      candidateCount: index.songCandidates.count,
      hasSound: index.hasSound,
      latelySongIDs: latelyMix?.songs.map(\.id) ?? []
    )
    guard key != otherMixesKey else {
      keepOtherMixes(isOnPhone: isOnPhone)
      return
    }
    otherMixesKey = key

    var mixSongs = [ListeningShelves.MixSong]()
    mixSongs.reserveCapacity(index.songCandidates.count)
    for candidate in index.songCandidates {
      guard let song = index.songsByID[candidate.songID] else { continue }
      let album = song.album
      let year = album?.year ?? 0
      let genre = (song.genre?.name ?? album?.genre?.name)?.lowercased() ?? ""
      mixSongs.append(ListeningShelves.MixSong(
        songID: candidate.songID,
        albumID: candidate.albumID,
        artistKey: Self.artistKey(of: song),
        genre: genre.isEmpty ? nil : genre,
        year: year > 0 ? year : song.year,
        tags: candidate.tags
      ))
    }
    var mixes = [MadeForYouMix]()
    let slotKey = "\(key.weekend ? "weekend" : "weekday")-\(daypart)"

    // Songs already in a playlist to the left: one song, one playlist (BUG-497).
    var taken = Set(key.latelySongIDs)

    // This part of the day.
    var daypartRNG = ListeningShelves.DailyGenerator(day: now, key: "daypart|\(slotKey)", calendar: calendar)
    let daypartIDs = ListeningShelves.daypartMix(
      plays: songPlays,
      songs: mixSongs,
      excluding: taken,
      playedRecently: lately.songsJustPlayed,
      now: now,
      calendar: calendar,
      using: &daypartRNG
    )
    if let mix = makeMix(
      .daypart,
      title: ListeningShelves.aroundNowTitle(now: now, calendar: calendar),
      ids: daypartIDs,
      songsByID: index.songsByID,
      isOnPhone: isOnPhone
    ) {
      mixes.append(mix)
      taken.formUnion(mix.songs.map(\.id))
    }

    // Been a While: favourites on the phone, untagged ones too, never an interlude (BUG-496).
    let cutoff = now.addingTimeInterval(-45 * 86400)
    let former = storage.main.library.getFormerFavoriteSongs(
      for: account,
      lastPlayedBefore: cutoff,
      minPlayCount: 4,
      fetchLimit: 400
    ).filter { isOnPhone.contains($0) && !ListeningShelves.isInterlude(title: $0.title, duration: $0.duration) }
    var formerByID = [String: Song]()
    for song in former { formerByID[song.id] = song }
    var whileRNG = ListeningShelves.DailyGenerator(day: now, key: "been-a-while", calendar: calendar)
    let whileIDs = ListeningShelves.beenAWhile(
      former.map {
        ListeningShelves.PlayedSong(
          songID: $0.id,
          albumID: $0.album?.id ?? $0.id,
          artistKey: Self.artistKey(of: $0),
          playCount: $0.playCount,
          lastPlayed: $0.lastTimePlayed
        )
      },
      excluding: taken,
      now: now,
      using: &whileRNG
    )
    if let mix = makeMix(.beenAWhile, title: "Been a While", ids: whileIDs, songsByID: formerByID, isOnPhone: isOnPhone) {
      mixes.append(mix)
      taken.formUnion(mix.songs.map(\.id))
    }

    // The mood mixes, the ones this part of the day suits first. Each song may only join the
    // one it fits best (its home), so the six stay apart whatever the time of day.
    let favored = Set(lately.songPlays.map(\.songID))
    let homes = ListeningShelves.moodHomes(mixSongs)
    let mixSongByID = Dictionary(mixSongs.map { ($0.songID, $0) }, uniquingKeysWith: { first, _ in first })
    for moodKey in ListeningShelves.moodMixOrder(for: daypart) {
      guard let mood = ListeningShelves.moodMixes.first(where: { $0.key == moodKey }) else { continue }
      var moodRNG = ListeningShelves.DailyGenerator(day: now, key: "mood|\(mood.key)", calendar: calendar)
      let ids = ListeningShelves.moodMix(
        mood,
        songs: mixSongs.filter { homes[$0.songID] == mood.key },
        favored: favored,
        excluding: taken,
        using: &moodRNG
      )
      if var mix = makeMix(
        .mood(key: mood.key, hexColor: mood.hexColor),
        title: mood.title,
        ids: ids,
        songsByID: index.songsByID,
        isOnPhone: isOnPhone
      ) {
        // Its cover: the day's turn, except Get Pumped's (by how heavy its songs are).
        mix.coverVariant = mood.key == "get-pumped"
          ? ListeningShelves.getPumpedCoverVariant(mix.songs.compactMap { mixSongByID[$0.id] })
          : ListeningShelves.dailyCoverVariant(key: mood.key, on: now)
        mixes.append(mix)
        taken.formUnion(mix.songs.map(\.id))
      }
    }
    setOtherMixes(mixes)
  }

  /// A made-for-you playlist from song ids, keeping only songs on the phone (and live rows);
  /// nil when too few are left.
  private func makeMix(
    _ kind: MadeForYouMix.Kind,
    title: String,
    subtitle: String? = nil,
    ids: [String],
    songsByID: [String: Song],
    isOnPhone: OnPhoneCheck
  )
    -> MadeForYouMix? {
    let songs: [AbstractPlayable] = ids.compactMap { songsByID[$0] }.filter {
      isOnPhone.contains($0) && !$0.playableManagedObject.isDeleted
        && $0.playableManagedObject.managedObjectContext != nil
    }
    guard songs.count >= ListeningShelves.madeMixMinSongs else { return nil }
    return MadeForYouMix(
      kind: kind,
      title: title,
      subtitle: subtitle,
      songs: songs,
      leadAlbums: leadAlbums(for: songs)
    )
  }

  /// cassette_local_id -> the song on this phone, newest download first when an id repeats.
  /// The cloud's playlists name songs by cassette_local_id.
  private func songIDsByLocalID() -> [String: String] {
    Self.songIDsByLocalID(storage: storage)
  }

  /// The same, for CloudHome.
  static func songIDsByLocalID(storage: PersistentStorage) -> [String: String] {
    var songIDByLocalID = [String: String]()
    for row in (try? DeviceOwnershipManager(context: storage.main.context).fetchAll()) ?? [] {
      let localID: String? = row.cassetteLocalId
      guard let localID, let songID = row.subsonicTrackId, songIDByLocalID[localID] == nil else { continue }
      songIDByLocalID[localID] = songID
    }
    return songIDByLocalID
  }

  /// Store the made-for-you playlists after Lately; the generation moves only when one
  /// actually differs from what is there.
  private func setOtherMixes(_ mixes: [MadeForYouMix]) {
    func signature(_ list: [MadeForYouMix]) -> [String] {
      list.map { mix in
        ([mix.id, mix.title, mix.coverVariant ?? ""] + mix.songs.map(\.id)
          + mix.leadAlbums.map(\.id)).joined(separator: ",")
      }
    }
    defer { fetchMoodCovers() }
    guard signature(mixes) != signature(otherMixes) else { return }
    otherMixes = mixes
    otherMixesGeneration += 1
  }

  /// Fetches the mood mixes' drawn covers this process has not got yet (`MixCoverCache`
  /// skips what is on disk and backs off after a failure), so Home, the mix pages and
  /// CarPlay have them even if Home was never on screen. Each one that lands redraws the
  /// host once: CarPlay swaps it in; Home's tiles fade it in themselves.
  private func fetchMoodCovers() {
    let addresses = otherMixes.compactMap { MixCoverCache.address(for: $0) }
    MixCoverCache.prefetch(addresses) { [weak self] in
      self?.notifySnapshot()
    }
  }

  /// Keep the made-for-you playlists, dropping songs that are no longer on the phone (a
  /// playlist left with too few songs goes).
  private func keepOtherMixes(isOnPhone: OnPhoneCheck) {
    guard isOnPhone.owned != nil, !otherMixes.isEmpty else { return }
    let kept: [MadeForYouMix] = otherMixes.compactMap { mix in
      let songs = mix.songs.filter {
        isOnPhone.contains($0) && !$0.playableManagedObject.isDeleted
          && $0.playableManagedObject.managedObjectContext != nil
      }
      guard songs.count >= ListeningShelves.madeMixMinSongs else { return nil }
      guard songs.count != mix.songs.count else { return mix }
      // The cover stays as it was drawn: a song leaving the phone never swaps it mid-day.
      return MadeForYouMix(
        kind: mix.kind,
        title: mix.title,
        subtitle: mix.subtitle,
        songs: songs,
        leadAlbums: leadAlbums(for: songs),
        coverVariant: mix.coverVariant
      )
    }
    setOtherMixes(kept)
  }

  /// The artist a mix spaces and caps by: the album artist, else the song's, normalised.
  private static func artistKey(of song: Song?) -> String {
    guard let song else { return "" }
    let name = song.album?.artist?.name ?? song.artist?.name ?? ""
    let key = ListeningShelves.normalizedArtistName(name)
    return key.isEmpty ? song.id : key
  }

  /// Recently-played playlists. Overlap with Recent is allowed (section-scoped
  /// identity), so no cross-shelf subtraction.
  func updatePlaylists() {
    guard let playlistMOs = playlistsLastPlayedFetch?.fetchedObjects as? [PlaylistMO] else {
      data[.yourPlaylists] = []
      notifySnapshot()
      return
    }
    // cassette: dedup by stableID like every other shelf builder (updateRecent's
    // seenIDs, filledShelf's seen, blendForgotten). Two PlaylistMOs sharing a
    // playlist id — a row materialized twice, or a degenerate/empty id on a
    // local playlist — otherwise map to two identical HomeItems in one section,
    // a duplicate diffable identifier that hard-crashes applySnapshot (SIGTRAP).
    var seenPlaylistIDs = Set<String>()
    let isOnPhone = makeOnPhoneCheck()
    data[.yourPlaylists] = playlistMOs
      .compactMap { Playlist(library: storage.main.library, managedObject: $0) }
      .filter { isOnPhone($0) && seenPlaylistIDs.insert(Self.stableID(for: $0)).inserted }
      .prefix(Self.shelfCarouselCap)
      .map { HomeItem(
        section: .yourPlaylists,
        stableID: Self.stableID(for: $0),
        playableContainable: $0
      ) }
    notifySnapshot()
  }

  /// Albums ranked from maintained song play data: played first (recency then
  /// affinity), then newest-added, then a stable at-large backfill — filled to
  /// target so the shelf is never sparse, capped for the carousel. No reliance
  /// on the unset server indices; overlap with Recent is allowed.
  func updateAlbums() {
    data[.recentlyAdded] = filledShelf(
      section: .recentlyAdded,
      rankedIDs: rankedAlbumIDs,
      containerForID: { albumScores[$0]?.container },
      atLargeMOs: albumsAllFetch?.fetchedObjects as? [AlbumMO],
      wrap: { Album(managedObject: $0) }
    )
    notifySnapshot()
  }

  /// cassette (BUG-036): rank by the REAL artist-play signal, not song-rollup.
  /// `Artist.playedViaContext()` (AbstractLibraryEntity) writes `lastTimePlayed`
  /// on every `PlayContext(containable: artist)`, so an artist that was actually
  /// played leads — whereas playing an *album* stamps the album's `lastTimePlayed`,
  /// not the artist's, so it no longer surfaces the artist here (the old
  /// song-rollup couldn't tell the two apart). Candidates still come from
  /// `artistScores` (a played artist's songs are in the recent sample, so it is
  /// present); we just rank by `container.lastTimePlayed`. Backfill (fill-to-N) is
  /// unchanged so the shelf never renders empty — an artist that only appears via
  /// alphabetical backfill is there by library membership, not "surfaced" by a play.
  // cassette 2026-10-13: the Radio shelf. The stations on the dial (the whole registry since
  // 2026-10-29, RadioDial), the saved ones
  // first (2026-10-21), the rest ranked by what this person tunes to (play count + recency on the station itself),
  // then by how well a station's genres match the genres they OWN, then live
  // stations for breadth, capped per network. No network, no model; the
  // registry rides inside the app (RadiosVC.swift). Batched like the rest.
  func updateRadios() {
    let radios = RadioDial.radios(for: account, storage: storage)
    guard !radios.isEmpty else {
      data[.radios] = []
      return
    }
    var genreWeight: [String: Int] = [:]
    for album in storage.main.library.getAlbums(for: account) {
      guard let name = album.genre?.name, !name.isEmpty else { continue }
      genreWeight[RadioShelf.normalize(name), default: 0] += 1
    }
    // cassette 2026-10-20: and the genres of what was played in the last 30 days, recent
    // plays weighted up (ten-day half-life), from the phone's own play log.
    let now = Date()
    var recentGenres: [String: Double] = [:]
    let since = now.addingTimeInterval(-30 * 86400)
    for entry in storage.main.library.getScrobbleEntries(for: account, since: since, fetchLimit: 5000) {
      guard let date = entry.date, let song = entry.playable?.asSong,
            let name = song.genre?.name ?? song.album?.genre?.name, !name.isEmpty else { continue }
      let weight = pow(0.5, max(0, now.timeIntervalSince(date)) / 86400 / 10)
      recentGenres[RadioShelf.normalize(name), default: 0] += weight
    }
    let ranked = RadioShelf.rank(
      radios: radios,
      libraryGenres: genreWeight,
      recentGenres: recentGenres,
      savedSlugs: RadioSaved.shared.slugs,
      now: now
    )
    data[.radios] = ranked.prefix(Self.shelfCarouselCap).map {
      HomeItem(section: .radios, stableID: "radio:\($0.id)", playableContainable: $0)
    }
  }

  func updateRecentArtists() {
    let rankedByArtistPlay = artistScores
      .filter { $0.value.container.lastTimePlayed != nil }
      .sorted {
        ($0.value.container.lastTimePlayed ?? .distantPast) >
          ($1.value.container.lastTimePlayed ?? .distantPast)
      }
      .map { $0.key }
    data[.recentlyPlayedArtists] = filledShelf(
      section: .recentlyPlayedArtists,
      rankedIDs: rankedByArtistPlay,
      containerForID: { artistScores[$0]?.container },
      atLargeMOs: artistsAllFetch?.fetchedObjects as? [ArtistMO],
      wrap: { Artist(managedObject: $0) }
    )
    notifySnapshot()
  }

  // MARK: - Engine-backed shelves (shared home-shelf algorithm)

  /// cassette: the Albums + Artists shelves run the SHARED home-shelf engine
  /// (`AmperfyKit/HomeShelfEngine`) — the same algorithm the web and Android run,
  /// kept genuinely in sync by the golden conformance fixtures. `HomeManager`'s job
  /// is only the adapter: turn Core Data into the engine's `ShelfInput`, call the
  /// engine, and map its ordered keys back to `HomeItem`s. Recent stays iOS's own
  /// `updateRecent` (its Resume split + live-queue prepend are iOS-specific).
  private struct EngineShelfData {
    let input: ShelfInput
    let albumsByKey: [String: Album]
    let artistsByKey: [String: Artist]
  }

  /// Adapt Core Data → `ShelfInput` (+ key→container maps to render the result).
  /// Candidate pools reuse the existing fetches (forgotten-album + all-artist)
  /// unioned with the played containers from the song sample, then each candidate's
  /// tracks are rolled up into the engine's per-container signals. Keys are the same
  /// stableIDs the rest of Home uses, so exclusion and mapping line up. On the phone
  /// (a deliberate subset of the full library) this per-candidate roll-up is bounded.
  private func buildShelfInput() -> EngineShelfData {
    func ms(_ d: Date?) -> Int64? { d.map { Int64($0.timeIntervalSince1970 * 1000) } }

    // Albums: forgotten-candidate fetch ∪ played albums from the sample.
    var albumsByKey: [String: Album] = [:]
    for mo in (forgottenAlbumsFetch?.fetchedObjects as? [AlbumMO]) ?? [] {
      let album = Album(managedObject: mo)
      albumsByKey[Self.stableID(for: album)] = album
    }
    for (_, scored) in albumScores {
      albumsByKey[Self.stableID(for: scored.container)] = scored.container
    }
    var shelfAlbums: [ShelfAlbum] = []
    for (key, album) in albumsByKey {
      let tracks = album.playables
      var played = 0, total = 0
      var last: Date?, added: Date?
      for track in tracks {
        if track.playCount > 0 { played += 1 }
        total += track.playCount
        if let lp = track.lastTimePlayed, last == nil || lp > last! { last = lp }
        if let ad = (track as? Song)?.addedDate, added == nil || ad < added! { added = ad }
      }
      shelfAlbums.append(ShelfAlbum(
        key: key, title: album.name, artist: album.artist?.name ?? "",
        genre: album.genre?.name, trackCount: tracks.count,
        playedTrackCount: played, totalPlays: total,
        lastPlayedAt: ms(last), addedAt: ms(added)
      ))
    }

    // Artists: all-artist fetch ∪ played artists from the sample.
    var artistsByKey: [String: Artist] = [:]
    for mo in (artistsAllFetch?.fetchedObjects as? [ArtistMO]) ?? [] {
      let artist = Artist(managedObject: mo)
      artistsByKey[Self.stableID(for: artist)] = artist
    }
    for (_, scored) in artistScores {
      artistsByKey[Self.stableID(for: scored.container)] = scored.container
    }
    var shelfArtists: [ShelfArtist] = []
    for (key, artist) in artistsByKey {
      let songs = artist.songs
      var total = 0
      var last: Date?, added: Date?
      for song in songs {
        total += song.playCount
        if let lp = song.lastTimePlayed, last == nil || lp > last! { last = lp }
        if let ad = (song as? Song)?.addedDate, added == nil || ad < added! { added = ad }
      }
      shelfArtists.append(ShelfArtist(
        key: key, name: artist.name, genre: artist.genre?.name,
        trackCount: songs.count, albumCount: artist.albums.count,
        totalPlays: total, lastPlayedAt: ms(last), addedAt: ms(added)
      ))
    }

    let input = ShelfInput(
      albums: shelfAlbums, artists: shelfArtists, playlists: [],
      recentArtistKeys: nil,
      now: Int64(Date().timeIntervalSince1970 * 1000),
      seed: "cassette-home"
    )
    return EngineShelfData(input: input, albumsByKey: albumsByKey, artistsByKey: artistsByKey)
  }

  /// Keys already surfaced in Resume, excluded from the engine shelves so nothing shows
  /// twice (matches the web engine's cross-shelf exclusion). Recent is no longer on Home
  /// (2026-10-21), so its items no longer hold anything back; the softer rows give way to
  /// the rows above them in `cascadeSofterRows`.
  private func recentExclusions() -> Set<String> {
    var out = Set<String>()
    for section in [HomeSection.resume] {
      for item in data[section] ?? [] { out.insert(item.stableID) }
    }
    return out
  }

  private func updateAlbumsViaEngine(_ shelf: EngineShelfData) {
    let picks = buildAlbums(
      shelf.input.albums, HOME_SHELF_CONFIG, shelf.input.now, shelf.input.seed, recentExclusions()
    )
    data[.forgottenAlbums] = picks.compactMap { shelf.albumsByKey[$0.key] }.map {
      HomeItem(section: .forgottenAlbums, stableID: Self.stableID(for: $0), playableContainable: $0)
    }
    notifySnapshot()
  }

  private func updateArtistsViaEngine(_ shelf: EngineShelfData) {
    let picks = buildArtists(shelf.input, HOME_SHELF_CONFIG, recentExclusions())
    data[.recentlyPlayedArtists] = picks.compactMap { shelf.artistsByKey[$0.key] }.map {
      HomeItem(
        section: .recentlyPlayedArtists,
        stableID: Self.stableID(for: $0),
        playableContainable: $0
      )
    }
    notifySnapshot()
  }

  /// cassette (Forgotten Albums): the anti-recency shelf — owned albums the user
  /// has drifted from or never explored. iOS-only (`buildsForgottenShelf`). Draws
  /// from three pools, forgotten-purchase-weighted (the deep pool at launch):
  ///  • forgotten purchase — owned & never played, from the older (added-long-ago) end
  ///  • deep cut — 1-2 tracks ever played, the rest at zero ("kept for one song")
  ///  • rekindle — real lifetime plays, gone cold
  /// Turnover-aware: albums surfaced on a recent PRIOR day are held back so the set
  /// changes day to day (HomeVC stamps `lastSurfacedOnHomeDate` when the shelf shows).
  /// Song iteration for deep-cut/rekindle is confined to the *touched* subset, so a
  /// fresh install (only forgotten-purchase populated) does no per-song work.
  func updateForgottenAlbums() {
    guard let albumMOs = forgottenAlbumsFetch?.fetchedObjects as? [AlbumMO] else {
      data[.forgottenAlbums] = []
      notifySnapshot()
      return
    }
    // FRC is newest-first; the OLDER end approximates "added long ago".
    let owned = albumMOs.map { Album(managedObject: $0) }

    // Never repeat what Resume already shows on the same screen.
    var excludedIDs = Set<String>()
    for section in [HomeSection.resume] {
      for item in data[section] ?? [] { excludedIDs.insert(item.stableID) }
    }

    // Turnover cooldown: hold back albums surfaced on a recent *prior* day, so
    // today's set stays stable while yesterday's rotates out.
    let cal = Calendar.current
    let startOfToday = cal.startOfDay(for: Date())
    let cooldownStart = cal.date(
      byAdding: .day,
      value: -Self.forgottenTurnoverDays,
      to: startOfToday
    ) ?? startOfToday
    func isEligible(_ album: Album) -> Bool {
      if excludedIDs.contains(Self.stableID(for: album)) { return false }
      if let d = album.lastSurfacedOnHomeDate, d >= cooldownStart, d < startOfToday {
        return false
      }
      return true
    }

    // Pool 1 — forgotten purchase: owned & never played, oldest-added first.
    let forgottenPurchase = owned.reversed().filter {
      $0.lastTimePlayed == nil && $0.playCount == 0 && isEligible($0)
    }

    // Pools 2 & 3 — over the TOUCHED subset only (bounded song iteration).
    let coldCutoff = Date().addingTimeInterval(-Self.forgottenColdSeconds)
    var deepCut: [Album] = []
    var rekindle: [(album: Album, plays: Int)] = []
    for album in owned
      where (album.lastTimePlayed != nil || album.playCount > 0) && isEligible(album) {
      let tracks = album.playables
      let playedTracks = tracks.reduce(0) { $0 + ($1.playCount > 0 ? 1 : 0) }
      if tracks.count >= 3, (1 ... 2).contains(playedTracks) {
        deepCut.append(album)
      }
      let playSum = tracks.reduce(0) { $0 + $1.playCount }
      let isCold = album.lastTimePlayed.map { $0 < coldCutoff } ?? true
      if playSum >= Self.forgottenRekindleMinPlays, isCold {
        rekindle.append((album, playSum))
      }
    }
    let rekindleRanked = rekindle.sorted { $0.plays > $1.plays }.map(\.album)

    var blended = blendForgotten(
      forgottenPurchase: Array(forgottenPurchase),
      deepCut: deepCut,
      rekindle: rekindleRanked
    )
    // Fill-to-target: the three forgotten pools are legitimately sparse on a
    // library with little play history (a fresh install populates only the
    // forgotten-purchase pool), and this shelf — unlike the album/artist shelves'
    // `filledShelf` — had NO backfill, so the "Albums" row collapsed to a couple
    // of items. Top up from the owned albums at-large (oldest-added first, matching
    // the "added long ago" lean), skipping Resume/Recent and dupes, so the shelf
    // always reads as a full row.
    if blended.count < Self.shelfTargetCount {
      var included = Set(blended.map { Self.stableID(for: $0) })
      for album in owned.reversed() where blended.count < Self.shelfTargetCount {
        let id = Self.stableID(for: album)
        if included.contains(id) || excludedIDs.contains(id) { continue }
        included.insert(id)
        blended.append(album)
      }
    }
    data[.forgottenAlbums] = blended.prefix(Self.shelfCarouselCap).map {
      HomeItem(
        section: .forgottenAlbums,
        stableID: Self.stableID(for: $0),
        playableContainable: $0
      )
    }
    notifySnapshot()
  }

  /// Forgotten-weighted interleave: ~3 forgotten-purchase to 1 secondary (deep-cut
  /// / rekindle, alternating), deduped within the shelf, capped at the carousel max.
  private func blendForgotten(
    forgottenPurchase: [Album],
    deepCut: [Album],
    rekindle: [Album]
  )
    -> [Album] {
    var out: [Album] = []
    var seen = Set<String>()
    func push(_ album: Album) {
      let id = Self.stableID(for: album)
      guard !seen.contains(id) else { return }
      seen.insert(id)
      out.append(album)
    }
    var fi = 0, di = 0, ri = 0
    var preferDeep = true
    while out.count < Self.shelfCarouselCap {
      let before = out.count
      var f = 0
      while f < 3, fi < forgottenPurchase.count, out.count < Self.shelfCarouselCap {
        push(forgottenPurchase[fi]); fi += 1; f += 1
      }
      if out.count < Self.shelfCarouselCap {
        if preferDeep, di < deepCut.count {
          push(deepCut[di]); di += 1
        } else if ri < rekindle.count {
          push(rekindle[ri]); ri += 1
        } else if di < deepCut.count {
          push(deepCut[di]); di += 1
        }
        preferDeep.toggle()
      }
      if out.count == before { break } // all pools exhausted
    }
    return out
  }

  /// Shared fill-to-N builder for the album & artist shelves: the song-derived
  /// ranking (played → newest-added) first, then the stable at-large fetch
  /// until the target is reached, deduped *within* the shelf and capped at the
  /// carousel max. No cross-shelf subtraction — section-scoped identity lets an
  /// item also live in Recent, so the old two-pass "minus Recent then add it
  /// back" dance is gone.
  private func filledShelf<C: PlayableContainable, MO: NSManagedObject>(
    section: HomeSection,
    rankedIDs: [String],
    containerForID: (String) -> C?,
    atLargeMOs: [MO]?,
    wrap: (MO) -> C
  )
    -> [HomeItem] {
    var ordered: [PlayableContainable] = []
    var seen = Set<String>()

    for id in rankedIDs {
      guard let container = containerForID(id), seen.insert(id).inserted else { continue }
      ordered.append(container)
      if ordered.count >= Self.shelfCarouselCap { break }
    }

    if ordered.count < Self.shelfTargetCount, let atLargeMOs {
      for mo in atLargeMOs {
        let container = wrap(mo)
        guard seen.insert(Self.stableID(for: container)).inserted else { continue }
        ordered.append(container)
        if ordered.count >= Self.shelfTargetCount { break }
      }
    }

    return ordered.prefix(Self.shelfCarouselCap).map {
      HomeItem(section: section, stableID: Self.stableID(for: $0), playableContainable: $0)
    }
  }

  // MARK: - Player observer

  @objc
  private func handlePlayerChanged() {
    // A play/pause/stop can move the live album to the top of Recent / Resume.
    // This is a real play event (HomeManager does not observe per-tick elapsed
    // time, and popup-open posts none of these), but the matching countPlayed
    // write also fires an FRC-change burst — so coalesce both into one
    // debounced recompute rather than recomputing per notification.
    Task { @MainActor in
      self.scheduleRecompute()
    }
  }

  /// The mood index finished building off the main thread (posted on the main actor).
  /// Recompute so More Like and the Lately mix read it; deferred while Home is off screen.
  @objc
  private func handleMoodIndexReady() {
    moodIndexJustLanded = true
    scheduleRecompute()
  }

  @objc
  private func handleRadioSavedChanged() {
    scheduleRecompute()
  }

  /// The cloud's rows changed outside a recompute (a new answer, music came or went).
  @objc
  private func handleCloudHomeChanged() {
    guard !isRecomputing else { return }
    scheduleRecompute()
  }
}

extension HomeManager: @preconcurrency NSFetchedResultsControllerDelegate {
  func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
    // fetch controllers are created on Main thread -> Runtime Error if this function call is not on Main thread
    MainActor.assumeIsolated {
      // Any of our FRCs changing means the play-data / library moved; coalesce
      // the burst (~30 callbacks in 0.1s as Core Data settles) into a single
      // debounced recompute.
      if controller == recentSongsFetch?.fetchResultsController
        || controller == topSongsFetch?.fetchResultsController
        || controller == newestSongsFetch?.fetchResultsController
        || controller == playlistsLastPlayedFetch?.fetchResultsController
        || controller == albumsAllFetch?.fetchResultsController
        || controller == artistsAllFetch?.fetchResultsController
        || controller == forgottenAlbumsFetch?.fetchResultsController {
        scheduleRecompute()
      }
    }
  }
}
