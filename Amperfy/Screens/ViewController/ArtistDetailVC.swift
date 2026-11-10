//
//  ArtistDetailVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

class ArtistDetailVC: MultiSourceTableViewController {
  override var sceneTitle: String? { artist.name }

  /// phone-taste: the approved mock puts what you play first. MOST PLAYED leads, then the
  /// artist's ALBUMS, then MORE LIKE them from your own shelf. (From Patch 110 until the
  /// mock, Albums led and "Popular" followed; the founder-approved mock overturns that.)
  /// Section 0 stays the empty spacer the legacy layout needs (see numberOfSections). A
  /// single ArtistDetailVC serves both the owned-library and (in Server Mode) the
  /// broader-catalog artist context; there is no separate discovery screen.
  private enum BodySection: Int, CaseIterable {
    case spacer = 0
    case mostPlayed = 1
    case albums = 2
    case moreLike = 3
  }

  private var artist: Artist
  var albumToScrollTo: Album?
  private var albumsFetchedResultsController: ArtistAlbumsItemsFetchedResultsController!
  private var songsFetchedResultsController: ArtistSongsItemsFetchedResultsController!
  private var optionsButton: UIBarButtonItem!
  private var collapsedPlayButton: UIBarButtonItem!
  private var detailOperationsView: GenericDetailTableHeader?
  private let stickyHeader = DetailStickyHeaderView()

  /// phone-taste: MOST PLAYED lists only songs that have actually been played, at most
  /// five, with no "Show more". When this phone has played at least three of the artist's
  /// songs twice in the last 60 days, it shows those, most played lately first, headed
  /// MOST PLAYED *lately* (ListeningShelves.mostPlayedLately). Otherwise it shows all-time
  /// counts: the cloud's via `POST /api/sync/popular-rank`, or this phone's own when
  /// unpaired or offline. The two counts stay separate, never blended (founder, 2026-10-21).
  private static let mostPlayedLimit = 5
  /// Songs played lately needed before MOST PLAYED switches to the lately order.
  private static let mostPlayedLatelyMinSongs = 3
  /// How many play-log entries the lately order reads (the same bound Home uses).
  private static let mostPlayedLatelyFetchLimit = 5000
  /// Whether MOST PLAYED is showing the lately order (its heading says so).
  private var mostPlayedIsLately = false
  /// A MOST PLAYED row: the 44pt cover plus 8pt above and below.
  private static let mostPlayedRowHeight: CGFloat = 60
  private static let mostPlayedVerticalMargin: CGFloat = 8
  /// The page gutter the rows share with the shelves.
  private static let gutter: CGFloat = 20
  /// The shelves' tiles (150pt, clear over the lit page).
  private static let shelfStyle = AlbumShelfStyle.mockLit
  /// Bumps when a new rank request starts so a late response can't paint stale.
  private var mostPlayedRankGeneration = 0

  /// cassette: the MOST PLAYED order is SNAPSHOTTED for the presentation so a live
  /// play-count bump never reorders rows under the user. Re-ranks on each appearance only.
  ///
  /// phone-taste: MOST PLAYED now leads the page, so it never sits empty while the cloud
  /// rank is in flight (ALBUMS and MORE LIKE would paint first and then be pushed down by
  /// up to six rows when it landed). The first paint is this session's last cloud order
  /// for the artist, else this phone's own played songs; a re-rank keeps the rows on
  /// screen and swaps them only when the ranked set differs.
  private var frozenMostPlayedSongs: [Song] = []
  private var hasSeededMostPlayed = false
  /// The last cloud MOST PLAYED order per artist id (song ids) this session, so an artist
  /// opened again paints its ranked rows at once.
  @MainActor
  private static var rememberedMostPlayed: [String: [String]] = [:]

  // MARK: phone-taste state

  /// Reads the lead record's colour and glow. The artist page has no DetailScreenChrome,
  /// so it owns its lighter and lights its own header.
  private let lighter = DetailCoverLighter()
  /// Every album the albums list holds, newest first (year 0 last, then by name): the
  /// artist's own records and the ones they only appear on.
  private var artistAlbums: [Album] = []
  /// The artist's own records (credited to them), newest first.
  private var creditedAlbums: [Album] = []
  /// What the ALBUMS shelf, the meta count, the fan and the lead record describe: the
  /// artist's own records, or what they appear on when nothing on the phone is theirs.
  private var shelfAlbums: [Album] = []
  /// The record that lights the page: the artist's own newest album with a cover file.
  private var leadAlbum: Album?
  /// The artist's own newest records for the hero fan.
  private var fanAlbums: [Album] = []
  /// MORE LIKE: other artists on the phone whose moods match, one album each.
  private var moreLikeAlbums: [Album] = []
  /// The MORE LIKE heading's label, recoloured in place when the tint lands.
  private weak var moreLikeHeadingLabel: UILabel?
  /// The MOST PLAYED heading's label, recoloured in place when the tint lands ("lately").
  private weak var mostPlayedHeadingLabel: UILabel?

  private func frozenMostPlayedSong(at row: Int) -> Song? {
    guard row >= 0, row < frozenMostPlayedSongs.count else { return nil }
    return frozenMostPlayedSongs[row]
  }

  /// Every song the songs list holds, most played first.
  private func listedSongs() -> [Song] {
    let count = songsFetchedResultsController?.sections?.first?.numberOfObjects ?? 0
    return (0 ..< count).compactMap {
      songsFetchedResultsController?.getWrappedEntity(at: IndexPath(row: $0, section: 0))
    }
  }

  /// The first paint of MOST PLAYED, set in viewDidLoad before the table first loads, so
  /// the page opens with its rows in place.
  private func seedMostPlayedIfNeeded(_ local: [Song]) {
    guard !hasSeededMostPlayed else { return }
    hasSeededMostPlayed = true
    if let lately = latelyPlayedSongs(local) {
      mostPlayedIsLately = true
      frozenMostPlayedSongs = lately
    } else {
      frozenMostPlayedSongs = rememberedMostPlayedSongs(in: local) ?? localPlayedSongs(local)
    }
    if isViewLoaded, tableView.window != nil {
      tableView.reloadData()
    }
  }

  /// Re-rank MOST PLAYED from the cloud (or local fallback) and swap the rows only if the
  /// ranked set differs. The rows already shown stay while it is in flight.
  private func freezeMostPlayedOrder() {
    let local = listedSongs()
    seedMostPlayedIfNeeded(local)
    guard !local.isEmpty else {
      applyMostPlayed([], lately: false)
      return
    }
    // Recently popular for you, from this phone's own play log, when there is enough of it.
    if let lately = latelyPlayedSongs(local) {
      mostPlayedRankGeneration &+= 1
      applyMostPlayed(lately, lately: true)
      return
    }
    mostPlayedRankGeneration &+= 1
    let generation = mostPlayedRankGeneration
    let artistID = artist.id
    Task { @MainActor [weak self] in
      guard let self else { return }
      let ranked = await self.rankMostPlayedCloudOrLocal(local)
      guard generation == self.mostPlayedRankGeneration else { return }
      Self.rememberedMostPlayed[artistID] = ranked.map(\.id)
      self.applyMostPlayed(ranked, lately: false)
    }
  }

  /// The artist's songs this phone has played lately, most played first, or nil when fewer
  /// than `mostPlayedLatelyMinSongs` qualify. Reads the play log (one entry per completed
  /// play) for the lookback window, as Home's On Repeat does.
  private func latelyPlayedSongs(_ songs: [Song]) -> [Song]? {
    guard !songs.isEmpty else { return nil }
    let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let now = Date()
    let since = now.addingTimeInterval(-Double(ListeningShelves.lookbackDays) * 86400)
    let entries = appDelegate.storage.main.library.getScrobbleEntries(
      for: account,
      since: since,
      fetchLimit: Self.mostPlayedLatelyFetchLimit
    )
    var plays = [(date: Date, songID: String)]()
    for entry in entries {
      guard let date = entry.date, let song = entry.playable?.asSong, byID[song.id] != nil
      else { continue }
      plays.append((date, song.id))
    }
    let ranked = ListeningShelves.mostPlayedLately(plays, now: now)
      .compactMap { byID[$0] }
      .prefix(Self.mostPlayedLimit)
    return ranked.count >= Self.mostPlayedLatelyMinSongs ? Array(ranked) : nil
  }

  /// This phone's own played songs, most played first (the songs list sorts by play count).
  private func localPlayedSongs(_ songs: [Song]) -> [Song] {
    Array(songs.filter { $0.playCount > 0 }.prefix(Self.mostPlayedLimit))
  }

  /// This session's last ranked order for the artist, kept to the songs still listed.
  private func rememberedMostPlayedSongs(in songs: [Song]) -> [Song]? {
    guard let ids = Self.rememberedMostPlayed[artist.id] else { return nil }
    let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let remembered = ids.compactMap { byID[$0] }
    return remembered.isEmpty ? nil : remembered
  }

  /// Swap MOST PLAYED to `songs` when they differ from what is shown. MOST PLAYED sits
  /// above the shelves, so when it changes height while the reader is below it, the
  /// scroll position moves with it and what they are looking at stays put.
  private func applyMostPlayed(_ songs: [Song], lately: Bool) {
    guard songs != frozenMostPlayedSongs || lately != mostPlayedIsLately else { return }
    let section = BodySection.mostPlayed.rawValue
    guard isViewLoaded, tableView.numberOfSections > section else {
      // Not loaded yet: the first load reads it.
      frozenMostPlayedSongs = songs
      mostPlayedIsLately = lately
      return
    }
    let before = tableView.rect(forSection: section)
    frozenMostPlayedSongs = songs
    mostPlayedIsLately = lately
    UIView.performWithoutAnimation {
      tableView.reloadSections(IndexSet(integer: section), with: .none)
    }
    guard tableView.window != nil else { return }
    let readerTop = tableView.contentOffset.y + view.safeAreaInsets.top
    guard readerTop >= before.maxY else { return }
    tableView.layoutIfNeeded()
    let delta = tableView.rect(forSection: section).height - before.height
    guard delta != 0 else { return }
    tableView.contentOffset.y += delta
  }

  /// Cloud union counts via popular-rank, played songs only; if none of the cloud's have a
  /// play (or the phone is unpaired / offline), this phone's own plays. Song.playCount
  /// counts every time a song is put into the player, skips included.
  private func rankMostPlayedCloudOrLocal(_ songs: [Song]) async -> [Song] {
    let localPlayed = localPlayedSongs(songs)
    guard CassetteSyncAPI.bearerToken != nil else { return localPlayed }
    var byLocalId: [String: Song] = [:]
    var inputs: [(cassetteLocalId: String, title: String)] = []
    inputs.reserveCapacity(songs.count)
    for song in songs {
      let localId = CassetteCloudPlaylistBridge.cassetteLocalId(for: song)
      byLocalId[localId] = song
      inputs.append((localId, song.title))
    }
    do {
      let ranked = try await CassetteSyncAPI.shared.rankPopular(items: inputs)
      let played = ranked.filter { $0.playCount > 0 }.compactMap { byLocalId[$0.cassetteLocalId] }
      if !played.isEmpty {
        return Array(played.prefix(Self.mostPlayedLimit))
      }
    } catch {
      // Offline or network: fall through to local play counts.
    }
    return localPlayed
  }

  init(account: Account, artist: Artist) {
    self.artist = artist
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func viewDidLoad() {
    // cassette Patch 037: pin inline title for this VC before super
    // runs so the nav bar collapses the parent's large title in the
    // first frame of the push transition — otherwise "Artists"
    // briefly renders behind the detail title.
    navigationItem.largeTitleDisplayMode = .never
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.artistDetail)

    // cassette Patch 103 (Phase 3.3): re-resolve to the relationship-rich same-id
    // artist before building the FRCs. Prevents the empty-detail bug when this VC
    // is entered with a metadata-only stub (album link, search, Home shelf) whose
    // identity-bound FRCs (song.artist == self) would otherwise return nothing.
    artist = appDelegate.storage.main.library.richestSameIdArtist(for: artist, account: account)

    // cassette redesign (Surface 1): overflow returns to the navigation bar
    // (native glass circle on iOS 26); a play bar-button joins it when the
    // hero collapses under the bar.
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu.lazyMenu { [weak self] in
      guard let self else { return [] }
      return EntityPreviewActionBuilder(container: artist, on: self).createMenuActions()
    }
    collapsedPlayButton = UIBarButtonItem(
      image: UIImage(systemName: "play.fill"),
      primaryAction: UIAction { [weak self] _ in
        guard let self else { return }
        let songs = songsFetchedResultsController
          .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode) ?? []
        appDelegate.player.play(context: PlayContext(
          containable: artist,
          playables: songs.filterSongs().sortByAlbum()
        ))
      }
    )
    collapsedPlayButton.accessibilityLabel = "Play"

    albumsFetchedResultsController = ArtistAlbumsItemsFetchedResultsController(
      for: artist,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    albumsFetchedResultsController.delegate = self
    songsFetchedResultsController = ArtistSongsItemsFetchedResultsController(
      for: artist,
      displayFilter: appDelegate.storage.settings.user.artistsFilterSetting,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false,
      sortByPlayCount: true
    )
    songsFetchedResultsController.delegate = self
    // cassette Patch 104: the named bug behind the empty artist body — the
    // FRCs were created but never fetched. Patch 045 removed the in-view
    // search path whose showAllResults() used to do the fetching, so the
    // body rendered zero rows even though the data was there. Fetch both
    // explicitly.
    albumsFetchedResultsController.fetch()
    songsFetchedResultsController.fetch()
    recomputeAlbumState()
    seedMostPlayedIfNeeded(listedSongs())
    tableView.register(nibName: GenericTableCell.typeName)
    tableView.register(nibName: PlayableTableCell.typeName)
    // Patch 110 (3b): the artist's albums render as a horizontal carousel
    // (one row hosting AlbumCarouselTableCell) instead of vertical list rows.
    tableView.register(
      AlbumCarouselTableCell.self,
      forCellReuseIdentifier: AlbumCarouselTableCell.reuseIdentifier
    )
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    // The two-voice headings carry their own 28pt of air.
    tableView.sectionHeaderTopPadding = 0
    tableView.backgroundColor = .backgroundColor
    // Patch 111 (1): no row separators and no dividers between the sections.
    tableView.separatorStyle = .none

    // cassette Patch 104 (Root 2): artwork is the first content of the
    // scroll. The table extends under the navigation bar (insets mirrored
    // manually in viewDidLayoutSubviews) and the bar is transparent at the
    // scroll edge so back/overflow float over the artwork; the system
    // restores the standard bar surface once content scrolls under it.
    tableView.contentInsetAdjustmentBehavior = .never
    // Patch 109: every appearance slot starts transparent so the bar never
    // snaps to the opaque global standardAppearance the instant the user
    // scrolls. DetailStickyHeaderSupport.updateAlpha then fades the bar
    // background in lockstep with the title as the hero collapses.
    let transparentBar = UINavigationBarAppearance()
    transparentBar.configureWithTransparentBackground()
    navigationItem.standardAppearance = transparentBar
    navigationItem.compactAppearance = transparentBar
    navigationItem.scrollEdgeAppearance = transparentBar
    navigationItem.compactScrollEdgeAppearance = transparentBar
    // cassette Patch 108: iOS 26 adds an always-on soft top scroll-edge effect
    // (a dark gradient/scrim) over content that extends under the bar, which
    // darkens the top of the artwork at rest. Hide it so the artwork is clean
    // at rest; the opaque standardAppearance still supplies the solid bar
    // surface once content scrolls under it.
    if #available(iOS 26.0, *) {
      tableView.topEdgeEffect.isHidden = true
    }

    // cassette Patch 045: in-view search removed from artist detail.
    // Library category lists keep their search controllers; the
    // detail view shows the artist's full top-songs + albums set.
    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: {
        "\(self.artist.albumCount) Album\(self.artist.albumCount == 1 ? "" : "s") \(CommonString.oneMiddleDot) \(self.artist.songCount) Song\(self.artist.songCount == 1 ? "" : "s")"
      },
      playContextCb: { () in
        let songs = self.songsFetchedResultsController
          .getContextSongs(onlyCachedSongs: self.appDelegate.storage.settings.user.isOfflineMode) ??
          []
        let sortedSongs = songs.filterSongs().sortByAlbum()
        return PlayContext(containable: self.artist, playables: sortedSongs)
      },
      player: appDelegate.player,
      isInfoAlwaysHidden: true,
      usesProminentPlayButton: true
    )
    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: artist,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: playShuffleInfoConfig,
      extendsUnderNavigationBar: true,
      heroStyle: .artistHero
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)
    detailOperationsView?.setArtistFan(albums: fanAlbums)
    refreshArtistMetadataLine()
    DetailStickyHeaderSupport.install(
      stickyHeader: stickyHeader,
      in: self,
      overflowItem: optionsButton,
      collapsedPlayItem: collapsedPlayButton
    )
    refreshStickyHeaderText()
    tableView.layoutIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.stickyHeader.alpha = 0
    }

    // phone-taste: the page is lit by the artist's own newest record. Rank numbers and the
    // MORE LIKE answer follow its colour; a cover or a photo that downloads later relights.
    lighter.apply = { [weak self] tint, glow, key in
      self?.landLight(tint: tint, glow: glow, key: key)
    }
    // Only a download in lighter.watchedArtworkIDs (their records' covers, their photo)
    // calls this, and only while the page is on screen (viewIsAppearing to
    // viewDidDisappear).
    lighter.relight = { [weak self] in
      guard let self else { return }
      recomputeLeadAlbum()
      lightUpFromLeadAlbum()
      detailOperationsView?.refreshArtistPhoto()
    }

    containableAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      switch BodySection(rawValue: indexPath.section) {
      case .mostPlayed:
        return frozenMostPlayedSong(at: indexPath.row)
      default:
        // The shelves are single carousel rows: no per-album swipe or menu.
        return nil
      }
    }
    playContextAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      switch BodySection(rawValue: indexPath.section) {
      case .mostPlayed:
        let songIndexPath = IndexPath(row: indexPath.row, section: 0)
        return convertIndexPathToPlayContext(songIndexPath: songIndexPath)
      default:
        // Shelf taps navigate (onSelect) or play (the tile's disc), not a play context.
        return nil
      }
    }
    swipeCallback = { [weak self] indexPath, completionHandler in
      guard let self else { return }
      switch BodySection(rawValue: indexPath.section) {
      case .mostPlayed:
        guard let song = frozenMostPlayedSong(at: indexPath.row) else {
          completionHandler(nil)
          return
        }
        let songIndexPath = IndexPath(row: indexPath.row, section: 0)
        let playContext = convertIndexPathToPlayContext(songIndexPath: songIndexPath)
        completionHandler(SwipeActionContext(containable: song, playContext: playContext))
      default:
        // No swipe actions on the carousel rows.
        completionHandler(nil)
      }
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
    // Re-rank MOST PLAYED from the cloud play store. The rows already shown stay until
    // the rank lands, and change only if it differs.
    freezeMostPlayedOrder()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // cassette (header-pop fix, round 3): while popping, skip ALL of the
    // inset-driven re-layout — see AlbumDetailVC for the full rationale (the
    // safe-area-derived insets shift as the bar animates and re-expand the hero).
    guard !isHeaderTransitionFrozen else { return }
    // Patch 104 (Root 2): with contentInsetAdjustmentBehavior == .never the
    // safe areas are mirrored manually (bottom = tab bar + mini player).
    tableView.contentInset.bottom = view.safeAreaInsets.bottom
    tableView.verticalScrollIndicatorInsets.top = view.safeAreaInsets.top
    tableView.verticalScrollIndicatorInsets.bottom = view.safeAreaInsets.bottom
    detailOperationsView?.resizeToFit()
  }

  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateStickyHeaderAlpha()
    (tabBarController as? TabBarVC)?.cassetteUpdateMinimizeForScroll(scrollView)
  }

  // resizeToFit defers any header re-measure that arrives mid-scroll (it would
  // flash the collapsed title — see GenericDetailTableHeader.resizeToFit). Land
  // the deferred size once the scroll settles.
  // NOTE: no super call here — ArtistDetailVC's super chain goes through
  // MultiSourceTableViewController → BasicTableViewController →
  // KeyCommandTableViewController → UITableViewController, none of which
  // implement scrollViewDidEnd*. The chain for AlbumDetailVC is different
  // (it goes through BasicFetchedResultsTableViewController which does).
  // Calling super from here would crash with "unrecognized selector".
  override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    detailOperationsView?.resizeToFit()
  }

  override func scrollViewDidEndDragging(
    _ scrollView: UIScrollView,
    willDecelerate decelerate: Bool
  ) {
    if !decelerate {
      detailOperationsView?.resizeToFit()
    }
  }

  private func updateStickyHeaderAlpha() {
    DetailStickyHeaderSupport.updateAlpha(
      stickyHeader: stickyHeader,
      scrollView: tableView,
      tableHeaderView: tableView.tableHeaderView,
      in: self,
      collapsedPlayItem: collapsedPlayButton
    )
  }

  private func refreshStickyHeaderText() {
    let counts = ownCounts()
    var parts = ["Artist"]
    if counts.albums > 0 {
      parts.append("\(counts.albums) album\(counts.albums == 1 ? "" : "s")")
    }
    if counts.songs > 0 {
      parts.append("\(counts.songs) song\(counts.songs == 1 ? "" : "s")")
    }
    let subtitle = parts.count > 1 ? parts.joined(separator: " · ") : nil
    stickyHeader.configure(title: artist.name, subtitle: subtitle)
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    // Restore the correct alpha when popping back to a scrolled screen —
    // viewWillDisappear resets alpha to 0 for the push transition.
    updateStickyHeaderAlpha()
    albumsFetchedResultsController?.delegate = self
    songsFetchedResultsController?.delegate = self
    observeWhileVisible()
    // A cover or a photo may have landed while the page was hidden.
    recomputeLeadAlbum()
    lightUpFromLeadAlbum()
    detailOperationsView?.refreshArtistPhoto()
    refreshMoreLike()
    Task { @MainActor in
      do {
        try await artist.fetch(
          storage: self.appDelegate.storage,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
      } catch {
        // cassette Patch 040: detail-appear background sync.
        self.appDelegate.eventLogger.report(
          topic: "Artist Sync",
          error: error,
          isBackground: true
        )
      }
      self.refreshArtistMetadataLine()
      self.detailOperationsView?.refresh()
    }
  }

  // Patch 026: artist metadata line. Year doesn't apply, so we surface
  // scope instead. phone-taste: "12 albums · 187 songs" counted from the artist's own
  // records in the list, which on the phone is what is on the phone (the header sets it
  // in tracked capitals). Counts are suppressed when missing rather than rendered as
  // zeros.
  //
  // cassette: the leading type noun is gone across every detail page. It
  // only ever told you which page you were already looking at.
  private func refreshArtistMetadataLine() {
    let counts = ownCounts()
    var parts: [String] = []
    if counts.albums > 0 {
      parts.append("\(counts.albums) album\(counts.albums == 1 ? "" : "s")")
    }
    if counts.songs > 0 {
      parts.append("\(counts.songs) song\(counts.songs == 1 ? "" : "s")")
    }
    detailOperationsView?.metadataOverride = parts.joined(separator: " \(CommonString.oneMiddleDot) ")
    refreshStickyHeaderText()
  }

  /// The artist's own records the list holds: albums credited to them (not records they
  /// only appear on), and the songs FRC's count (on the phone, the songs on the phone).
  /// Artist.albumCount / songCount count every hub record, on the phone or not.
  private func ownCounts() -> (albums: Int, songs: Int) {
    let albums = creditedAlbums.count
    let songs = songsFetchedResultsController?.sections?.first?.numberOfObjects ?? 0
    return (albums, songs)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // Reset the collapsed title only when PUSHING a child (this VC stays in the
    // stack, so the child's bar starts clean). On a POP — including the
    // interactive edge-swipe — `isMovingFromParent` is true; zeroing alpha here
    // would snap the bar title off mid-swipe ("header re-expands"). Leave it so
    // the title slides away continuously with the content. A cancelled swipe
    // self-heals: viewIsAppearing recomputes alpha from the scroll offset.
    if !isMovingFromParent {
      stickyHeader.alpha = 0
    } else {
      // cassette (header-pop fix, round 3): freeze the collapsing header for the
      // whole pop so it rides off-screen instead of re-expanding.
      freezeCollapsingHeaderForPopTransition { [weak self] in
        guard let self else { return }
        // On a cancelled swipe, resume normal scroll-driven layout/alpha.
        detailOperationsView?.resizeToFit()
        updateStickyHeaderAlpha()
      }
    }
    albumsFetchedResultsController?.delegate = nil
    songsFetchedResultsController?.delegate = nil
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // A page nobody can see has no light or shelf to update; it catches up on its next
    // appearance. (Record pages stay alive in the stack, and past a pop.)
    lighter.stopObservingArtworkDownloads()
    NotificationCenter.default.removeObserver(self, name: .cassetteMoodIndexReady, object: nil)
    NotificationCenter.default.removeObserver(self, name: .cassetteLibraryMoodsChanged, object: nil)
  }

  /// Listen for artwork downloads and the mood index while the page is on screen. Removed
  /// first, so a cancelled swipe-back (which appears again without having disappeared)
  /// never registers twice.
  private func observeWhileVisible() {
    lighter.startObservingArtworkDownloads(account: account)
    let center = NotificationCenter.default
    for name in [Notification.Name.cassetteMoodIndexReady, .cassetteLibraryMoodsChanged] {
      center.removeObserver(self, name: name, object: nil)
      center.addObserver(self, selector: #selector(moodIndexChanged), name: name, object: nil)
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    defer { albumToScrollTo = nil }
    // Patch 110 (3b): albums live in one carousel row — scroll that row into
    // view (the per-album scroll target no longer maps to a table row).
    guard albumToScrollTo != nil,
          tableView.numberOfSections > BodySection.albums.rawValue,
          tableView.numberOfRows(inSection: BodySection.albums.rawValue) > 0
    else { return }
    tableView.scrollToRow(
      at: IndexPath(row: 0, section: BodySection.albums.rawValue),
      at: .top,
      animated: true
    )
  }

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext? {
    // Play from the frozen MOST PLAYED order so the queue matches what's on screen.
    guard let selectedSong = frozenMostPlayedSong(at: songIndexPath.row) else { return nil }
    let contextSongs = appDelegate.storage.settings.user.isOfflineMode
      ? frozenMostPlayedSongs.filter { $0.isCached }
      : frozenMostPlayedSongs
    guard let playContextIndex = contextSongs.firstIndex(of: selectedSong) else { return nil }
    return PlayContext(containable: artist, index: playContextIndex, playables: contextSongs)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell),
          BodySection(rawValue: indexPath.section) == .mostPlayed
    else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: IndexPath(row: indexPath.row, section: 0))
  }

  // MARK: - Records (phone-taste)

  /// The album cover file on disk, if there is one.
  private func coverPath(of album: Album) -> String? {
    let setting = appDelegate.storage.settings.accounts.getSetting(account.info).read
    return album.imagePath(setting: setting.artworkDisplayPreference)
  }

  /// Every album the FRC holds, newest first, year 0 last, then by name (`Artist.newestFirst`,
  /// the order Search and CarPlay use too). The shared fetch request (oldest first) is left
  /// as it is.
  private func allArtistAlbums() -> [Album] {
    let count = albumsFetchedResultsController.sections?[0].numberOfObjects ?? 0
    let albums = (0 ..< count).compactMap { albumsFetchedResultsController.getWrappedEntity(at: $0) }
    return Artist.newestFirst(albums)
  }

  /// Rebuilds the albums, the shelf, the lead record and the fan from the FRC.
  private func recomputeAlbumState() {
    artistAlbums = allArtistAlbums()
    // Credited: the artist's own records (`Artist.isCredited`, shared with Search and CarPlay).
    creditedAlbums = artistAlbums.filter { artist.isCredited($0) }
    // The mock's ALBUMS is the artist's own records; with none on the phone, what they
    // appear on (the same rule as the fan and the lead record).
    shelfAlbums = creditedAlbums.isEmpty ? artistAlbums : creditedAlbums
    recomputeLeadAlbum()
    fanAlbums = Array(shelfAlbums.prefix(3))
    // The downloads that can change the light: a cover for one of these records (a newer
    // one landing becomes the lead) or the artist's own photo.
    lighter.watchedArtworkIDs = Set(
      (creditedAlbums.isEmpty ? Array(artistAlbums.prefix(1)) : creditedAlbums)
        .compactMap { $0.artwork?.uniqueID } + [artist.artwork?.uniqueID].compactMap { $0 }
    )
  }

  /// The record that lights the page: the newest album credited to this artist that has a
  /// cover file, else the newest credited album (no glow, neutral colour), else the newest
  /// album they appear on. A compilation they are on never lights their page while a
  /// record of their own is here. The same rule (`Artist.leadAlbum`) lights Search's card
  /// for this artist and draws their CarPlay header.
  private func recomputeLeadAlbum() {
    leadAlbum = artist.leadAlbum(among: artistAlbums) { coverPath(of: $0) != nil }
  }

  private func lightUpFromLeadAlbum() {
    let path = leadAlbum.flatMap { coverPath(of: $0) }
    lighter.lightUp(coverPath: path, key: path ?? "artist-no-cover:\(artist.id)")
  }

  /// The tint landed: light the header, and recolour the ranks and the MORE LIKE answer in
  /// place (a reload would restart the playing row's waveform).
  private func landLight(tint: CoverTint, glow: UIImage?, key: String) {
    detailOperationsView?.applyCoverLight(tint: tint, glowImage: glow, glowKey: key)
    for cell in tableView.visibleCells {
      guard let cell = cell as? PlayableTableCell,
            let indexPath = tableView.indexPath(for: cell),
            BodySection(rawValue: indexPath.section) == .mostPlayed
      else { continue }
      cell.setTrackNumberColor(tint.text)
    }
    moreLikeHeadingLabel?.attributedText = CassetteHeading.attributed(
      shout: "More like",
      answer: artist.name,
      answerColor: tint.text
    )
    if mostPlayedIsLately {
      mostPlayedHeadingLabel?.attributedText = CassetteHeading.attributed(
        shout: "Most played",
        answer: "lately",
        answerColor: tint.text
      )
    }
  }

  @objc
  private func moodIndexChanged() {
    refreshMoreLike()
  }

  /// MORE LIKE: other artists on the phone whose music carries the same moods, one album
  /// each, best match first. Hidden until the mood index is ready (it never builds on the
  /// main thread here); reloads its section only when the set changed.
  private func refreshMoreLike() {
    var albums: [Album] = []
    if let index = LatelyLibrary.moodIndexIfReady(storage: appDelegate.storage, account: account) {
      let ids = ListeningShelves.moreLikeArtist(
        pageArtistName: artist.name,
        albums: index.albumCandidates,
        artistNameByAlbum: index.artistNameByAlbumID
      )
      albums = ids.compactMap { index.albumsByID[$0] }
    }
    guard albums.map(\.id) != moreLikeAlbums.map(\.id) else { return }
    moreLikeAlbums = albums
    guard isViewLoaded, tableView.numberOfSections > BodySection.moreLike.rawValue else { return }
    tableView.reloadSections(IndexSet(integer: BodySection.moreLike.rawValue), with: .none)
  }

  private func pushAlbum(_ album: Album) {
    navigationController?.pushViewController(
      AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
      animated: true
    )
  }

  // MARK: - Table view data source

  override func numberOfSections(in tableView: UITableView) -> Int {
    // 3 sections + 1 top section. The top section is needed due to display bugs
    BodySection.allCases.count
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    switch BodySection(rawValue: section) {
    case .mostPlayed:
      return "Most Played"
    case .albums:
      return "Albums"
    case .moreLike:
      return "More Like"
    default:
      return ""
    }
  }

  /// phone-taste: two-voice headings (Barlow capitals, then the answer in the New York
  /// italic), at the 20pt gutter with 28pt of air above. No dividers between sections.
  override func tableView(
    _ tableView: UITableView,
    viewForHeaderInSection section: Int
  )
    -> UIView? {
    switch BodySection(rawValue: section) {
    case .mostPlayed:
      guard !frozenMostPlayedSongs.isEmpty else { return nil }
      let view = CassetteHeading.makeTableHeaderView(
        shout: "Most played",
        answer: mostPlayedIsLately ? "lately" : nil,
        answerColor: lighter.tint.text
      )
      mostPlayedHeadingLabel = view.subviews.compactMap { $0 as? UILabel }.first
      return view
    case .albums:
      guard !shelfAlbums.isEmpty else { return nil }
      return CassetteHeading.makeTableHeaderView(
        shout: "Albums",
        answer: nil,
        answerColor: lighter.tint.text
      )
    case .moreLike:
      guard !moreLikeAlbums.isEmpty else { return nil }
      let view = CassetteHeading.makeTableHeaderView(
        shout: "More like",
        answer: artist.name,
        answerColor: lighter.tint.text
      )
      moreLikeHeadingLabel = view.subviews.compactMap { $0 as? UILabel }.first
      return view
    default:
      return nil
    }
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch BodySection(rawValue: section) {
    case .mostPlayed:
      return frozenMostPlayedSongs.count
    case .albums:
      // Patch 110 (3b): a single row hosting the horizontal album carousel.
      return shelfAlbums.isEmpty ? 0 : 1
    case .moreLike:
      return moreLikeAlbums.isEmpty ? 0 : 1
    default:
      return 0
    }
  }

  private var albumsReloadScheduled = false
  /// Coalesce FRC album changes into a single reload of the carousel row, and rebuild what
  /// depends on the albums: the lead record, the fan, the meta line and the light.
  private func scheduleAlbumsReload() {
    guard !albumsReloadScheduled else { return }
    albumsReloadScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      albumsReloadScheduled = false
      recomputeAlbumState()
      detailOperationsView?.setArtistFan(albums: fanAlbums)
      refreshArtistMetadataLine()
      lightUpFromLeadAlbum()
      guard tableView.numberOfSections > BodySection.albums.rawValue else { return }
      tableView.reloadSections(IndexSet(integer: BodySection.albums.rawValue), with: .none)
    }
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    switch BodySection(rawValue: indexPath.section) {
    case .mostPlayed:
      let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
      guard let song = frozenMostPlayedSong(at: indexPath.row) else { return UITableViewCell() }
      // A ranked row: the number in the record's colour, a 44pt cover, the album under the
      // title, no length, clear over the lit page.
      cell.display(
        playable: song,
        playContextCb: convertCellViewToPlayContext,
        rootView: self,
        contextArtistName: artist.name,
        options: PlayableCellOptions(
          horizontalMargin: Self.gutter,
          verticalMargin: Self.mostPlayedVerticalMargin,
          subtitleOverride: song.album?.name,
          hidesDuration: true,
          clearsBackground: true,
          rank: indexPath.row + 1,
          rankColor: lighter.tint.text
        )
      )
      return cell
    case .albums:
      let cell = tableView.dequeueReusableCell(
        withIdentifier: AlbumCarouselTableCell.reuseIdentifier,
        for: indexPath
      ) as! AlbumCarouselTableCell
      cell.configure(
        albums: shelfAlbums,
        onSelect: { [weak self] album in self?.pushAlbum(album) },
        onPlay: { album in OneTapPlay.play(album) },
        style: Self.shelfStyle,
        subtitle: { album in album.year > 0 ? "\(album.year)" : "" }
      )
      return cell
    case .moreLike:
      let cell = tableView.dequeueReusableCell(
        withIdentifier: AlbumCarouselTableCell.reuseIdentifier,
        for: indexPath
      ) as! AlbumCarouselTableCell
      cell.configure(
        albums: moreLikeAlbums,
        onSelect: { [weak self] album in self?.pushAlbum(album) },
        onPlay: { album in OneTapPlay.play(album) },
        style: Self.shelfStyle
      )
      return cell
    default:
      return UITableViewCell()
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    switch BodySection(rawValue: section) {
    case .mostPlayed:
      return frozenMostPlayedSongs.isEmpty ? 0 : CassetteHeading.tableHeaderHeight
    case .albums:
      return shelfAlbums.isEmpty ? 0 : CassetteHeading.tableHeaderHeight
    case .moreLike:
      return moreLikeAlbums.isEmpty ? 0 : CassetteHeading.tableHeaderHeight
    default:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch BodySection(rawValue: indexPath.section) {
    case .mostPlayed:
      return Self.mostPlayedRowHeight
    case .albums, .moreLike:
      return AlbumShelfView.preferredHeight(for: Self.shelfStyle)
    default:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    estimatedHeightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch BodySection(rawValue: indexPath.section) {
    case .mostPlayed:
      return Self.mostPlayedRowHeight
    case .albums, .moreLike:
      return AlbumShelfView.preferredHeight(for: Self.shelfStyle)
    default:
      return 0.0
    }
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    // MOST PLAYED rows play through their own tap; the shelves handle their tiles. Nothing
    // else on the page is selectable.
  }

  // cassette Patch 045: `updateSearchResults` override removed
  // alongside the search controller; the base no-op runs in its
  // place when a parent view fires `updateSearchResults(for:)`.

  override func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>,
    didChange anObject: Any,
    at indexPath: IndexPath?,
    for type: NSFetchedResultsChangeType,
    newIndexPath: IndexPath?
  ) {
    let section = 0
    switch controller {
    case albumsFetchedResultsController.fetchResultsController:
      // Patch 110 (3b): albums are one carousel row; the FRC's per-album
      // indices no longer map to table rows. Coalesce to a section reload so
      // the carousel rebuilds from the fresh album set.
      scheduleAlbumsReload()
      return
    case songsFetchedResultsController.fetchResultsController:
      // cassette: the MOST PLAYED order is frozen for the presentation (see
      // frozenMostPlayedSongs), so ignore live FRC reorders / play-count re-sorts
      // here: applying them would shuffle the list under the user. The order
      // re-ranks on the next appearance via freezeMostPlayedOrder(); the
      // now-playing indicator stays live through the cell's own player observer.
      return
    default:
      return
    }

    resultUpdateHandler?.applyChangesOfMultiRowType(
      controller,
      didChange: anObject,
      determinedSection: section,
      at: indexPath,
      for: type,
      newIndexPath: newIndexPath
    )
  }

  override func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>,
    didChange sectionInfo: NSFetchedResultsSectionInfo,
    atSectionIndex sectionIndex: Int,
    for type: NSFetchedResultsChangeType
  ) {}
}
