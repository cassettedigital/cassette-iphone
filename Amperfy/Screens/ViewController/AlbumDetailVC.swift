//
//  AlbumDetailVC.swift
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

// MARK: - AlbumDetailDiffableDataSource

class AlbumDetailDiffableDataSource: BasicUITableViewDiffableDataSource {
  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    false
  }

  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    // Return true to be enable swipe
    true
  }
}

// MARK: - AlbumDetailVC

class AlbumDetailVC: SingleSnapshotFetchedResultsTableViewController<SongMO> {
  override var sceneTitle: String? { album.name }

  var songToScrollTo: Song?
  private var fetchedResultsController: AlbumSongsFetchedResultsController!
  private var detailOperationsView: GenericDetailTableHeader?
  /// The shared detail-page frame: bar, collapsing title, overflow and bar play (Wave 3).
  private lazy var chrome = DetailScreenChrome(
    host: self,
    placement: .underBar,
    menu: { [weak self] in
      guard let self else { return [] }
      return EntityPreviewActionBuilder(container: album, on: self).createMenuActions()
    },
    playContext: { [weak self] in self?.albumPlayContext() }
  )
  private var hideUniformArtistSubtitle = false
  /// phone-taste: the footer under the songs (the on-phone line, then MORE BY, then MORE
  /// LIKE).
  private var recordFooter: DetailRecordFooter?
  /// What the footer was last built from, so an appearance that changes nothing keeps it
  /// (and the MORE BY shelf keeps its scroll position on the way back from a tile).
  private var recordFooterSignature: String?
  /// MORE BY: the artist's own other records on the phone. Worked out once when the page
  /// loads and again after the album syncs, never on every appearance.
  private var moreByAlbumsCache: [Album] = []
  /// MORE LIKE <album>: other artists' records on the phone whose songs carry the same
  /// moods (founder, 2026-10-21: "why not show Albums like Father of the Bride?"). Empty
  /// until the mood index is ready; it never builds on the main thread here.
  private var moreLikeAlbumsCache: [Album] = []
  /// The album rows' height: one 48pt line plus 2pt top and bottom (was 76).
  private static let rowHeight: CGFloat = 52
  private static let rowVerticalMargin: CGFloat = (rowHeight - 48) / 2
  /// The page gutter the rows, disc labels and shelf share.
  private static let gutter: CGFloat = 20
  // Cassette fork — Layer 3 Phase 3.2 (library filtering). Owned track ids used
  // to dim non-owned rows in Server Mode. On the phone the list itself holds only
  // songs that are on it (AlbumSongsFetchedResultsController, UX review 2026-10-20).
  private var cassetteOwnedTrackIds: Set<String> = []
  // Cassette: re-resolve the album by id so a background regroup that re-keys or
  // purges the underlying AlbumMO can't strand this view on a deleted-object
  // fault. A re-key changes the id (no same-id successor to follow), so the
  // deletion path is to POP — see the deleted-object observer registered in
  // viewDidLoad and the viewWillAppear re-resolve below.
  var album: Album
  private let albumId: String

  init(account: Account, album: Album) {
    self.album = album
    self.albumId = album.id
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(
      self,
      name: .NSManagedObjectContextObjectsDidChange,
      object: nil
    )
  }

  // Cassette: a background regroup re-points owned songs onto group-key albums
  // and purges the emptied legacy AlbumMOs. If the AlbumMO this view is showing
  // is one of those deletions, the view is dead — the song list empties and any
  // album.* access faults. Pop unconditionally on the main thread before any
  // such access; a deleted AlbumMO is a dead view, regardless of whether a
  // regroup is "in progress".
  @objc
  private func cassetteAlbumMODeleted(_ notification: Notification) {
    let deleted = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject>
    let mo = album.managedObject
    guard mo.isDeleted || (deleted?.contains(mo) ?? false) else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, let nav = navigationController else { return }
      if nav.topViewController === self {
        nav.popViewController(animated: true)
      } else {
        nav.viewControllers.removeAll { $0 === self }
      }
    }
  }

  override func createDiffableDataSource() -> BasicUITableViewDiffableDataSource {
    let source =
      AlbumDetailDiffableDataSource(tableView: tableView) { [
        weak self
      ] tableView, indexPath, objectID -> UITableViewCell? in
        guard let self else { return UITableViewCell() }
        guard let object = try? appDelegate.storage.main.context
          .existingObject(with: objectID),
          let songMO = object as? SongMO
        else {
          fatalError("Managed object should be available")
        }
        let song = Song(managedObject: songMO)
        return createCell(tableView, forRowAt: indexPath, song: song)
      }
    return source
  }

  override func viewDidLoad() {
    // cassette Patch 037: see ArtistDetailVC for context — pin
    // inline title before super so the parent's large title
    // doesn't flash through the push transition.
    chrome.prepareBeforeLoad()
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.albumDetail)

    cassetteOwnedTrackIds = DeviceOwnershipManager(
      context: appDelegate.storage.main.context
    ).fetchAllSubsonicTrackIds()

    // Patch 110 (1): section the track list by disc. The track FRC sorts by
    // `disk` first, so grouping turns each distinct disc value into its own
    // section (the flag's keypath is sortDescriptors[0] == disk). Single-disc
    // albums produce one section and render flat exactly as before; multi-disc
    // albums get "Disc N" headers (see viewForHeaderInSection). Playback is
    // unaffected: getContextSongs still returns one continuous queue ordered
    // disc 1 → disc 2, so grouping is display-only.
    fetchedResultsController = AlbumSongsFetchedResultsController(
      forAlbum: album,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: true
    )
    singleFetchedResultsController = fetchedResultsController
    singleFetchedResultsController?.delegate = self
    singleFetchedResultsController?.fetch()
    recomputeMoreBy()
    recomputeMoreLike()

    // Cassette: pop this view if a background regroup deletes the AlbumMO it is
    // showing (re-key or purge). Registered once per instance; removed in deinit.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(cassetteAlbumMODeleted(_:)),
      name: .NSManagedObjectContextObjectsDidChange,
      object: appDelegate.storage.main.context
    )

    // cassette Patch 045: in-view search removed from album detail.
    // Library / Songs / Playlists category lists keep search; the
    // detail view presents a fixed track list instead.
    tableView.register(nibName: PlayableTableCell.typeName)
    // phone-taste: tighter one-line rows (the mock's density).
    tableView.rowHeight = Self.rowHeight
    // Catalyst also need an estimate to calculate the correct height before scrolling
    tableView.estimatedRowHeight = Self.rowHeight
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.backgroundColor = .backgroundColor
    // Patch 111 (1): no row separators — the track list reads as a clean block.
    // Disc grouping is shown by the "Disc N" labels alone (no dividers).
    tableView.separatorStyle = .none

    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: {
        DetailScreenChrome.songCountText(
          onPhone: self.fetchedResultsController.fetchResultsController.fetchedObjects?.count ?? 0,
          total: max(self.album.songCount, self.fetchedResultsController.totalSongCount)
        )
      },
      playContextCb: { () in self.albumPlayContext() },
      player: appDelegate.player,
      isInfoAlwaysHidden: true,
      usesProminentPlayButton: true
    )
    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: album,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: playShuffleInfoConfig,
      extendsUnderNavigationBar: chrome.extendsUnderNavigationBar,
      heroStyle: .room
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)
    refreshAlbumMetadataLine()
    chrome.install(header: detailOperationsView, title: album.name)
    // phone-taste: the page is lit by its own cover. Track numbers and the MORE BY answer
    // follow the cover's colour when it lands; a cover that downloads later relights.
    chrome.tintsTrackNumbers = true
    chrome.relight = { [weak self] in self?.lightUpFromCover() }
    chrome.observeArtworkDownloads(account: account)
    chrome.onTintChanged = { [weak self] tint in
      self?.recordFooter?.setAnswerColor(tint.text)
    }
    updateHideUniformArtistSubtitle()
    snapshotDidChange = { [weak self] in
      self?.updateHideUniformArtistSubtitle()
      // Song years may arrive after the first header paint — re-resolve year.
      self?.refreshAlbumMetadataLine()
    }

    containableAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      return fetchedResultsController.getWrappedEntity(at: indexPath)
    }
    playContextAtIndexPathCallback = { [weak self] indexPath in
      self?.convertIndexPathToPlayContext(songIndexPath: indexPath)
    }
    swipeCallback = { [weak self] indexPath, completionHandler in
      guard let self else { return }
      let song = fetchedResultsController.getWrappedEntity(at: indexPath)
      let playContext = convertIndexPathToPlayContext(songIndexPath: indexPath)
      completionHandler(SwipeActionContext(containable: song, playContext: playContext))
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Cassette: re-resolve the album by id in case a background regroup replaced
    // the underlying AlbumMO since the last appearance (no-op in steady state; a
    // re-keyed/purged album returns nil here and the deleted-object observer pops).
    if let fresh = appDelegate.storage.main.library.getAlbum(
      for: account, id: albumId, isDetailFaultResolution: false
    ) {
      album = fresh
    }
    // Regroup may have stamped year while we were away — refresh the header line
    // from the (possibly new) album wrapper, and the collapsed title (DET-7).
    refreshAlbumMetadataLine()
    chrome.setTitle(album.name)
    navigationController?.navigationBar.prefersLargeTitles = false
    observeMoodsWhileVisible()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    chrome.viewDidLayoutSubviews()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    chrome.viewWillDisappear(isMovingFromParent: isMovingFromParent)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    chrome.viewDidDisappear()
    let center = NotificationCenter.default
    center.removeObserver(self, name: .cassetteMoodIndexReady, object: nil)
    center.removeObserver(self, name: .cassetteLibraryMoodsChanged, object: nil)
  }

  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    chrome.scrollViewDidScroll()
  }

  override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    super.scrollViewDidEndDecelerating(scrollView)
    chrome.scrollDidSettle()
  }

  override func scrollViewDidEndDragging(
    _ scrollView: UIScrollView,
    willDecelerate decelerate: Bool
  ) {
    super.scrollViewDidEndDragging(scrollView, willDecelerate: decelerate)
    if !decelerate {
      chrome.scrollDidSettle()
    }
  }

  /// What Play plays, for the hero button and the collapsed bar button alike.
  private func albumPlayContext() -> PlayContext {
    PlayContext(
      containable: album,
      playables: fetchedResultsController
        .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode) ?? []
    )
  }

  private func updateHideUniformArtistSubtitle() {
    let songs = fetchedResultsController?
      .getContextSongs(onlyCachedSongs: false) ?? []
    let names = Set(songs.compactMap(\.creatorName))
    hideUniformArtistSubtitle = names.count == 1
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    chrome.viewIsAppearing()
    lightUpFromCover()
    // cassette (UX review 2026-10-20): "8 of 12 songs on this phone" under the list, then
    // MORE BY (phone-taste).
    rebuildFooter()

    Task { @MainActor in
      do {
        try await album.fetch(
          storage: self.appDelegate.storage,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
      } catch {
        // cassette Patch 040: detail-appear background sync.
        self.appDelegate.eventLogger.report(
          topic: "Album Sync",
          error: error,
          isBackground: true
        )
      }
      self.refreshAlbumMetadataLine()
      self.detailOperationsView?.refresh()
      self.lightUpFromCover()
      self.recomputeMoreBy()
      self.recomputeMoreLike()
      self.rebuildFooter()
    }
  }

  /// phone-taste: "1997 · 12 songs · 53 min" (the header sets it in tracked capitals). The
  /// year is album.year, which the cloud regroup fills from the same catalog/override path
  /// as the web rail (not track-tag averages). The songs and minutes count what is listed,
  /// which on the phone is what is on the phone; the footer says what is not.
  private func refreshAlbumMetadataLine() {
    var parts: [String] = []
    if album.year > 0 {
      parts.append("\(album.year)")
    }
    let songs = (fetchedResultsController?.fetchResultsController.fetchedObjects ?? [])
      .compactMap { ($0 as? SongMO).map(Song.init(managedObject:)) }
    if !songs.isEmpty {
      parts.append("\(songs.count) song\(songs.count == 1 ? "" : "s")")
    }
    let seconds = songs.reduce(0) { $0 + $1.duration }
    let minutes = Int((Double(seconds) / 60).rounded())
    if minutes > 0 {
      parts.append("\(minutes) min")
    }
    detailOperationsView?.metadataOverride = parts.joined(separator: " \(CommonString.oneMiddleDot) ")
  }

  /// Light the page from the album's cover file. With no file there is no glow (never the
  /// generated placeholder) and the colour stays neutral.
  private func lightUpFromCover() {
    // A regroup can purge this album while a sync is in flight; the deletion observer pops
    // the page, and nothing reads the dead object meanwhile.
    guard !album.managedObject.isDeleted else { return }
    let setting = appDelegate.storage.settings.accounts.getSetting(account.info).read
    let path = album.imagePath(setting: setting.artworkDisplayPreference)
    // Only this album's own cover landing can change the light.
    chrome.watchedArtworkIDs = Set([album.artwork?.uniqueID].compactMap { $0 })
    chrome.lightUp(coverPath: path, key: path ?? "album-no-cover:\(album.id)")
  }

  // MARK: - MORE BY (phone-taste)

  /// The footer: the on-phone line, then MORE BY and the artist's other records. Rebuilt
  /// only when what it shows changed.
  private func rebuildFooter() {
    let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
    let onPhone = fetchedResultsController.fetchResultsController.fetchedObjects?.count ?? 0
    let total = max(album.songCount, fetchedResultsController.totalSongCount)
    let shelf = moreByShelf()
    let likeShelf = moreLikeShelf()
    let signature = [
      "\(width)", "\(onPhone)", "\(total)", shelf?.answer ?? "",
      (shelf?.albums ?? []).map(\.id).joined(separator: ","),
      likeShelf?.answer ?? "",
      (likeShelf?.albums ?? []).map(\.id).joined(separator: ","),
    ].joined(separator: "|")
    guard signature != recordFooterSignature else { return }
    recordFooterSignature = signature
    let footer = DetailScreenChrome.makeRecordFooter(
      width: width,
      onPhone: onPhone,
      total: total,
      shelves: [shelf, likeShelf].compactMap { $0 },
      answerColor: chrome.tint.text
    )
    recordFooter = footer
    tableView.tableFooterView = footer
  }

  private func recomputeMoreBy() {
    guard !album.managedObject.isDeleted, let artist = album.artist else {
      moreByAlbumsCache = []
      return
    }
    moreByAlbumsCache = moreByAlbums(artist: artist)
  }

  // MARK: - MORE LIKE (founder, 2026-10-21)

  /// Listen for the mood index while the page is on screen (removed in viewDidDisappear;
  /// removed first here so a cancelled swipe-back, which appears again without having
  /// disappeared, never registers twice).
  private func observeMoodsWhileVisible() {
    let center = NotificationCenter.default
    for name in [Notification.Name.cassetteMoodIndexReady, .cassetteLibraryMoodsChanged] {
      center.removeObserver(self, name: name, object: nil)
      center.addObserver(self, selector: #selector(moodIndexChanged), name: name, object: nil)
    }
  }

  @objc
  private func moodIndexChanged() {
    let before = moreLikeAlbumsCache.map(\.id)
    recomputeMoreLike()
    guard moreLikeAlbumsCache.map(\.id) != before else { return }
    rebuildFooter()
  }

  /// Records on the phone whose songs' moods match this album's, best first: one per
  /// artist, never this album's artist (MORE BY covers them) nor Various Artists, at most
  /// eight. The same scoring the playlist page's MORE LIKE uses, matched a little tighter
  /// because one record's moods are narrower than a playlist's.
  private func recomputeMoreLike() {
    guard !album.managedObject.isDeleted,
          let index = LatelyLibrary.moodIndexIfReady(storage: appDelegate.storage, account: account),
          let own = index.albumCandidates.first(where: { $0.albumID == album.id })
    else {
      moreLikeAlbumsCache = []
      return
    }
    var profile = ListeningShelves.TagVector()
    for tags in own.songTags { ListeningShelves.add(tags, into: &profile) }
    let nameOf: (String) -> String = { id in
      ListeningShelves.normalizedArtistName(index.artistNameByAlbumID[id] ?? "")
    }
    let pageArtist = ListeningShelves.normalizedArtistName(album.artist?.name ?? nameOf(album.id))
    var excluding: Set<String> = [album.id]
    for candidate in index.albumCandidates {
      let name = nameOf(candidate.albumID)
      if name.isEmpty || name == pageArtist || name == "various artists" {
        excluding.insert(candidate.albumID)
      }
    }
    let ids = ListeningShelves.moreLike(
      profile: profile,
      albums: index.albumCandidates,
      excluding: excluding,
      minMatch: 0.75,
      perArtist: 1,
      limit: 8,
      artistKey: { nameOf($0.albumID) }
    )
    moreLikeAlbumsCache = ids.compactMap { index.albumsByID[$0] }
  }

  private func moreLikeShelf() -> DetailShelfBlock? {
    let albums = moreLikeAlbumsCache
    guard !albums.isEmpty else { return nil }
    return DetailShelfBlock(
      shout: "More like",
      answer: album.name,
      albums: albums,
      onSelect: { [weak self] album in
        guard let self else { return }
        navigationController?.pushViewController(
          AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
          animated: true
        )
      },
      onPlay: { album in OneTapPlay.play(album) }
    )
  }

  private func moreByShelf() -> DetailShelfBlock? {
    guard let artist = album.artist else { return nil }
    let albums = moreByAlbumsCache
    guard !albums.isEmpty else { return nil }
    return DetailShelfBlock(
      shout: "More by",
      answer: artist.name,
      albums: albums,
      onSelect: { [weak self] album in
        guard let self else { return }
        navigationController?.pushViewController(
          AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
          animated: true
        )
      },
      onPlay: { album in OneTapPlay.play(album) }
    )
  }

  /// The artist's own other records on the phone, newest first (year 0 last): albums
  /// credited to them, so features and compilations stay out, and never this one. Empty
  /// for Various Artists.
  ///
  /// One fetch scoped to this artist (the same set the artist page's album list holds).
  /// "On the phone" is checked against the owned track ids this page already loaded, not
  /// the album-list ownership predicate, which walks every owned song on the main thread.
  private func moreByAlbums(artist: Artist) -> [Album] {
    let pageName = ListeningShelves.normalizedArtistName(artist.name)
    guard !pageName.isEmpty, pageName != "various artists" else { return [] }
    let library = appDelegate.storage.main.library
    let artistID = library.richestSameIdArtist(for: artist, account: account).managedObject.objectID
    var predicates = [
      NSPredicate(
        format: "remoteStatus == %i OR SUBQUERY(songs, $song, $song.relFilePath != nil).@count > 0",
        RemoteStatus.available.rawValue
      ),
      NSPredicate(
        format: "artist == %@ OR SUBQUERY(songs, $song, $song.artist == %@).@count > 0",
        artistID,
        artistID
      ),
    ]
    if CassetteLibraryFilterProvider.shared.isOnDeviceOnly {
      predicates.append(NSPredicate(
        format: "SUBQUERY(songs, $song, $song.id IN %@).@count > 0",
        cassetteOwnedTrackIds
      ))
    }
    let request: NSFetchRequest<AlbumMO> = AlbumMO.fetchRequest()
    request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    request.relationshipKeyPathsForPrefetching = ["artwork", "artist"]
    let candidates = ((try? appDelegate.storage.main.context.fetch(request)) ?? [])
      .map(Album.init(managedObject:))
    return candidates
      .filter { candidate in
        guard candidate.id != album.id, let credited = candidate.artist else { return false }
        return credited.id == artist.id
          || ListeningShelves.normalizedArtistName(credited.name) == pageName
      }
      .sorted { lhs, rhs in
        let ly = lhs.year > 0 ? lhs.year : Int.min
        let ry = rhs.year > 0 ? rhs.year : Int.min
        if ly != ry { return ly > ry }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    defer { songToScrollTo = nil }
    guard let songToScrollTo = songToScrollTo,
          let indexPath = fetchedResultsController.fetchResultsController
          .indexPath(forObject: songToScrollTo.managedObject)
    else { return }
    tableView.scrollToRow(at: indexPath, at: .top, animated: true)
  }

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext? {
    guard let songs = fetchedResultsController
      .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode)
    else { return nil }
    let selectedSong = fetchedResultsController.getWrappedEntity(at: songIndexPath)
    guard let playContextIndex = songs.firstIndex(of: selectedSong) else { return nil }
    return PlayContext(containable: album, index: playContextIndex, playables: songs)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell) else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: indexPath)
  }

  func createCell(
    _ tableView: UITableView,
    forRowAt indexPath: IndexPath,
    song: Song
  )
    -> UITableViewCell {
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
    cell.display(
      playable: song,
      playContextCb: convertCellViewToPlayContext,
      rootView: self,
      isDislayAlbumTrackNumberStyle: true,
      contextArtistName: album.artist?.name,
      cassetteIsOwned: cassetteOwnedTrackIds.contains(song.id),
      // phone-taste: track numbers in the cover's colour, 52pt rows at a 20pt inset.
      options: PlayableCellOptions(
        trackNumberColor: chrome.tint.text,
        horizontalMargin: Self.gutter,
        verticalMargin: Self.rowVerticalMargin
      )
    )
    return cell
  }

  // cassette Patch 045: `updateSearchResults` override removed
  // alongside the search controller. The base no-op
  // `BasicTableViewController.updateSearchResults` runs harmlessly
  // when scrolled-into-view callbacks fire.

  // MARK: - Disc section headers (Patch 110, item 1)

  /// True only when the album genuinely spans more than one disc. Single-disc
  /// albums keep one section and render flat with no header.
  private var isMultiDisc: Bool {
    (fetchedResultsController?.numberOfSections ?? 0) > 1
  }

  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    isMultiDisc ? 35.0 : 0.0
  }

  override func tableView(
    _ tableView: UITableView,
    viewForHeaderInSection section: Int
  )
    -> UIView? {
    guard isMultiDisc else { return nil }
    // The FRC sections by `disk`, so the section name is the raw disc value
    // (e.g. "1", "2") — display it as-is under a "Disc" label.
    let discValue = fetchedResultsController?.sections?.element(at: section)?
      .name ?? "\(section + 1)"
    return makeDiscHeaderView(disc: discValue)
  }

  /// Patch 111 (1/2): a quiet disc label only, no hairline or divider. phone-taste: "DISC N"
  /// in the tracked mono kicker (13pt, the mono floor), at the rows' 20pt gutter, 2pt off
  /// the bottom of a 35pt header (the mock's 18 above).
  private func makeDiscHeaderView(disc: String) -> UIView {
    let container = UIView()
    container.backgroundColor = .clear
    let label = UILabel()
    label.attributedText = NSAttributedString.cassette(
      "Disc \(disc)",
      .kicker,
      color: .cassette(.textSecondary)
    )
    label.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.gutter),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
    ])
    return container
  }
}
