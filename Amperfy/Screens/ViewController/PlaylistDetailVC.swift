//
//  PlaylistDetailVC.swift
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

// MARK: - PlaylistDetailDiffableDataSource

class PlaylistDetailDiffableDataSource: BasicUITableViewDiffableDataSource {
  var playlist: Playlist!
  var isMoveAllowed = false
  var isEditAllowed = true

  /// The playlist position of a row. On the phone the list hides songs that are not on
  /// it, so a row number is not a position in the playlist (UX review 2026-10-20).
  private func playlistIndex(for indexPath: IndexPath) -> Int {
    guard let objectID = itemIdentifier(for: indexPath),
          let index = playlist.managedObject.items.firstIndex(where: { $0.objectID == objectID })
    else { return indexPath.row }
    return index
  }

  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    // Return false if you do not want the item to be re-orderable.
    isMoveAllowed
  }

  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    // Return true to be enable swipe
    isEditAllowed
  }

  override func tableView(
    _ tableView: UITableView,
    moveRowAt sourceIndexPath: IndexPath,
    to destinationIndexPath: IndexPath
  ) {
    let fromIndex = playlistIndex(for: sourceIndexPath)
    let toIndex = playlistIndex(for: destinationIndexPath)
    exectueAfterAnimation {
      self.playlist?.movePlaylistItem(fromIndex: fromIndex, to: toIndex)
      if let id = self.playlist?.id {
        CassetteCloudPlaylistBridge.moveStoredItem(playlistId: id, from: fromIndex, to: toIndex)
      }

      guard self.appDelegate.storage.settings.user.isOnlineMode,
            let account = self.playlist.account else { return }
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(account.info).librarySyncer
          .syncUpload(playlistToUpdateOrder: self.playlist)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Upload Order Update", error: error)
      }}
    }
    super.tableView(tableView, moveRowAt: sourceIndexPath, to: destinationIndexPath)
  }

  override func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    guard editingStyle == .delete else { return }
    let index = playlistIndex(for: indexPath)
    exectueAfterAnimation {
      self.playlist?.remove(at: index)
      guard self.appDelegate.storage.settings.user.isOnlineMode,
            let account = self.playlist.account else { return }
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(account.info).librarySyncer.syncUpload(
          playlistToDeleteSong: self.playlist,
          index: index
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Upload Entry Remove", error: error)
      }}
    }
    super.tableView(tableView, commit: editingStyle, forRowAt: indexPath)
  }
}

// MARK: - PlaylistDetailVC

class PlaylistDetailVC: SingleSnapshotFetchedResultsTableViewController<PlaylistItemMO> {
  override var sceneTitle: String? { playlist.name }

  private var fetchedResultsController: PlaylistItemsFetchedResultsController!
  let playlist: Playlist
  // Cassette fork — Layer 3 Phase 3.2 (library filtering). Owned track ids used
  // to dim non-owned rows in Server Mode. On the phone the list shows only songs
  // that are on it; the playlist itself keeps every item (UX review 2026-10-20).
  private var cassetteOwnedTrackIds: Set<String> = []

  var detailOperationsView: GenericDetailTableHeader?
  /// The shared detail-page frame (Wave 3). phone-taste: the cover sits up top between the
  /// back and more buttons, as on the album page. There is no pull-to-refresh: the page
  /// re-syncs on every appear. Edit lives in the more menu.
  private lazy var chrome = DetailScreenChrome(
    host: self,
    placement: .underBar,
    menu: { [weak self] in
      guard let self else { return [] }
      var actions = EntityPreviewActionBuilder(container: playlist, on: self).createMenuActions()
      if appDelegate.storage.settings.user.isOnlineMode, !playlist.isSmartPlaylist {
        actions.append(UIAction(title: "Edit") { [weak self] _ in
          self?.openEditView()
        })
      }
      return actions
    },
    playContext: { [weak self] in self?.playlistPlayContext() }
  )
  /// phone-taste: the footer under the songs (the on-phone line, then MORE LIKE).
  private var recordFooter: DetailRecordFooter?
  /// What the footer was last built from (see rebuildFooter).
  private var recordFooterSignature: String?
  /// MORE LIKE <playlist>: albums on the phone, not in the playlist, whose moods match it.
  private var moreLikeAlbums: [Album] = []
  /// Looks for a picked cover the hero is still downloading (bounded).
  private var coverRetryCount = 0

  init(account: Account, playlist: Playlist) {
    self.playlist = playlist
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func createDiffableDataSource() -> BasicUITableViewDiffableDataSource {
    let source =
      PlaylistDetailDiffableDataSource(tableView: tableView) { [
        weak self
      ] tableView, indexPath, objectID -> UITableViewCell? in
        guard let self else { return UITableViewCell() }
        guard let object = try? appDelegate.storage.main.context
          .existingObject(with: objectID),
          let playlistItemMO = object as? PlaylistItemMO
        else {
          return UITableViewCell()
        }
        let playlistItem = PlaylistItem(
          library: appDelegate.storage.main.library,
          managedObject: playlistItemMO
        )
        return createCell(tableView, forRowAt: indexPath, playlistItem: playlistItem)
      }
    source.playlist = playlist
    return source
  }

  override func viewDidLoad() {
    // cassette Patch 037: see ArtistDetailVC for context — pin
    // inline title before super so the parent's large title
    // doesn't flash through the push transition.
    chrome.prepareBeforeLoad()
    super.viewDidLoad()

    appDelegate.userStatistics.visited(.playlistDetail)
    cassetteOwnedTrackIds = DeviceOwnershipManager(
      context: appDelegate.storage.main.context
    ).fetchAllSubsonicTrackIds()
    fetchedResultsController = PlaylistItemsFetchedResultsController(
      forPlaylist: playlist,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    singleFetchedResultsController = fetchedResultsController
    singleFetchedResultsController?.delegate = self
    singleFetchedResultsController?.fetch()

    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.backgroundColor = .backgroundColor
    // No row separators (the album page's clean block).
    tableView.separatorStyle = .none

    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: {
        DetailScreenChrome.songCountText(
          onPhone: self.fetchedResultsController.fetchResultsController.fetchedObjects?.count ?? 0,
          total: max(self.playlist.songCount, self.fetchedResultsController.totalItemCount)
        )
      },
      playContextCb: { () in self.playlistPlayContext() },
      player: appDelegate.player,
      isInfoAlwaysHidden: true,
      usesProminentPlayButton: true
    )
    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: playlist,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: playShuffleInfoConfig,
      extendsUnderNavigationBar: chrome.extendsUnderNavigationBar,
      heroStyle: .room
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)
    refreshDescriptionLine()
    refreshPlaylistMetadataLine()
    chrome.install(header: detailOperationsView, title: playlist.name)
    // phone-taste: lit by the playlist's own cover (the person's pick, else its preset;
    // never album art). The MORE LIKE answer follows the cover's colour when it lands. The
    // artwork downloader never fetches a pick, so the page does not listen to it; a pick
    // still arriving is looked for again from lightUpFromCover.
    chrome.onTintChanged = { [weak self] tint in
      self?.recordFooter?.setAnswerColor(tint.text)
    }

    snapshotDidChange = { [weak self] in
      self?.refreshPlaylistMetadataLine()
      self?.detailOperationsView?.refresh()
    }

    containableAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      return fetchedResultsController.getWrappedEntity(at: indexPath).playable
    }
    playContextAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      return convertIndexPathToPlayContext(songIndexPath: indexPath)
    }
    swipeCallback = { [weak self] indexPath, completionHandler in
      guard let self else { return }
      let playlistItem = fetchedResultsController.getWrappedEntity(at: indexPath)
      let playContext = convertIndexPathToPlayContext(songIndexPath: indexPath)
      completionHandler(SwipeActionContext(
        containable: playlistItem.playable,
        playContext: playContext
      ))
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
    refreshEmptyState()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // Playlist never re-measured its hero on layout, so a rotation or iPad resize that kept
    // the size class left it at the old width (DET-4).
    chrome.viewDidLayoutSubviews()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    chrome.viewWillDisappear(isMovingFromParent: isMovingFromParent)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    chrome.viewDidDisappear()
    // A page nobody can see has no shelf to update; it recomputes on its next appearance.
    NotificationCenter.default.removeObserver(self, name: .cassetteMoodIndexReady, object: nil)
    NotificationCenter.default.removeObserver(self, name: .cassetteLibraryMoodsChanged, object: nil)
    NotificationCenter.default.removeObserver(
      self,
      name: CassetteCloudPlaylistBridge.coverDidLand,
      object: nil
    )
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
  private func playlistPlayContext() -> PlayContext {
    PlayContext(
      containable: playlist,
      playables: fetchedResultsController
        .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode) ?? []
    )
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    chrome.viewIsAppearing()
    observeMoodsWhileVisible()
    coverRetryCount = 0
    lightUpFromCover()
    // cassette (UX review 2026-10-20): "8 of 12 songs on this phone" under the list, then
    // MORE LIKE (phone-taste).
    recomputeMoreLike()
    rebuildFooter()
    if appDelegate.storage.settings.user.isOfflineMode {
      tableView.isEditing = false
    }
    Task { @MainActor in
      do {
        try await playlist.fetch(
          storage: self.appDelegate.storage,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Sync", error: error)
      }
      self.refreshDescriptionLine()
      self.refreshPlaylistMetadataLine()
      self.detailOperationsView?.refresh()
      self.refreshEmptyState()
      self.lightUpFromCover()
      self.recomputeMoreLike()
      self.rebuildFooter()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // Patch 026: playlist metadata line. Year doesn't apply for playlists,
  // so we surface scope. phone-taste: "12 songs · 74 min" (the header sets it in tracked
  // capitals; minutes stay minutes past an hour). On the phone it counts the songs on the
  // phone, which is what the list shows; Server Mode keeps the playlist's own totals.
  // Parts are skipped when missing.
  private func refreshPlaylistMetadataLine() {
    let count: Int
    let seconds: Int
    if CassetteLibraryFilterProvider.shared.isOnDeviceOnly {
      let playables = (fetchedResultsController?.fetchResultsController.fetchedObjects ?? [])
        .compactMap { ($0 as? PlaylistItemMO).map { AbstractPlayable(managedObject: $0.playable) } }
      count = playables.count
      seconds = playables.reduce(0) { $0 + $1.duration }
    } else {
      count = playlist.songCount
      seconds = playlist.duration
    }
    var parts: [String] = []
    if count > 0 {
      parts.append("\(count) song\(count == 1 ? "" : "s")")
    }
    let minutes = Int((Double(seconds) / 60).rounded())
    if minutes > 0 {
      parts.append("\(minutes) min")
    }
    detailOperationsView?.metadataOverride = parts.joined(separator: " \(CommonString.oneMiddleDot) ")
    chrome.setTitle(playlist.name)
  }

  /// The playlist's own description under its name, verbatim, in the answer voice. None
  /// (or a generated mixtape's instruction line) shows no line.
  private func refreshDescriptionLine() {
    detailOperationsView?.answerLine = CassetteCloudPlaylistBridge.storedDescription(for: playlist.id)
  }

  /// Light the page from the playlist's own cover: the person's pick, else its preset.
  /// Never the playlist's imagePath or an album mosaic. A pick the hero is still
  /// downloading lights from the preset meanwhile (the shared fallback,
  /// `displayCoverImage`) and is looked for again a few times.
  private func lightUpFromCover() {
    let id = playlist.id
    let url = CassetteCloudPlaylistBridge.storedCoverUrl(for: id)
    let isOwn = CassetteCloudPlaylistBridge.hasLocalCover(for: id)
    let image = CassetteCloudPlaylistBridge.displayCoverImage(for: id)
    chrome.lightUp(
      image: image,
      key: "playlist:\(id)|\(url ?? "preset")|\(isOwn ? "ready" : "pending")"
    )
    if !isOwn, url != nil, coverRetryCount < 3 {
      coverRetryCount += 1
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
        self?.lightUpFromCover()
      }
    }
  }

  // MARK: - MORE LIKE (phone-taste)

  /// Listen for the mood index while the page is on screen (removed in viewDidDisappear;
  /// removed first here so a cancelled swipe-back, which appears again without having
  /// disappeared, never registers twice).
  private func observeMoodsWhileVisible() {
    let center = NotificationCenter.default
    for name in [Notification.Name.cassetteMoodIndexReady, .cassetteLibraryMoodsChanged] {
      center.removeObserver(self, name: name, object: nil)
      center.addObserver(self, selector: #selector(moodIndexChanged), name: name, object: nil)
    }
    // A pick slower than lightUpFromCover's few retries lights the page when it lands
    // (BUG-461). Removed with the mood observers in viewDidDisappear.
    let coverLanded = CassetteCloudPlaylistBridge.coverDidLand
    center.removeObserver(self, name: coverLanded, object: nil)
    center.addObserver(
      self,
      selector: #selector(playlistCoverLanded(_:)),
      name: coverLanded,
      object: nil
    )
  }

  @objc
  private func playlistCoverLanded(_ notification: Notification) {
    guard notification.object as? String == playlist.id else { return }
    coverRetryCount = 0
    lightUpFromCover()
  }

  @objc
  private func moodIndexChanged() {
    let before = moreLikeAlbums.map(\.id)
    recomputeMoreLike()
    guard moreLikeAlbums.map(\.id) != before else { return }
    rebuildFooter()
  }

  /// Albums on the phone whose songs' moods match this playlist's songs on the phone, none
  /// with a song in the playlist, one per artist, at most eight. Empty (the shelf hides)
  /// until the mood index is ready; it never builds on the main thread here.
  private func recomputeMoreLike() {
    guard let index = LatelyLibrary.moodIndexIfReady(storage: appDelegate.storage, account: account)
    else {
      moreLikeAlbums = []
      return
    }
    let onPhoneSongIDs = Set(
      (fetchedResultsController?.fetchResultsController.fetchedObjects ?? [])
        .compactMap { ($0 as? PlaylistItemMO)?.playable.id }
    )
    var profile = ListeningShelves.TagVector()
    for candidate in index.songCandidates where onPhoneSongIDs.contains(candidate.songID) {
      ListeningShelves.add(candidate.tags, into: &profile)
    }
    let excluding = Set(playlist.playables.compactMap { $0.asSong?.album?.id })
    let ids = ListeningShelves.moreLike(
      profile: profile,
      albums: index.albumCandidates,
      excluding: excluding,
      minMatch: 0.7,
      perArtist: 1,
      limit: 8
    )
    moreLikeAlbums = ids.compactMap { index.albumsByID[$0] }
  }

  /// The footer: the on-phone line, then MORE LIKE <playlist>. Rebuilt only when what it
  /// shows changed, so the shelf keeps its scroll position on the way back from a tile.
  private func rebuildFooter() {
    let shelf = DetailShelfBlock(
      shout: "More like",
      answer: playlist.name,
      albums: moreLikeAlbums,
      onSelect: { [weak self] album in
        guard let self else { return }
        navigationController?.pushViewController(
          AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
          animated: true
        )
      },
      onPlay: { album in OneTapPlay.play(album) }
    )
    let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
    let onPhone = fetchedResultsController.fetchResultsController.fetchedObjects?.count ?? 0
    let total = max(playlist.songCount, fetchedResultsController.totalItemCount)
    let signature = [
      "\(width)", "\(onPhone)", "\(total)", playlist.name,
      moreLikeAlbums.map(\.id).joined(separator: ","),
    ].joined(separator: "|")
    guard signature != recordFooterSignature else { return }
    recordFooterSignature = signature
    let footer = DetailScreenChrome.makeRecordFooter(
      width: width,
      onPhone: onPhone,
      total: total,
      shelves: [shelf],
      answerColor: chrome.tint.text
    )
    recordFooter = footer
    tableView.tableFooterView = footer
  }

  /// cassette Patch 020: Cassette-flavored "Empty playlist" state.
  /// Refreshed on appear and after the playlist sync completes.
  private func refreshEmptyState() {
    contentUnavailableConfiguration = playlist.songCount == 0
      ? Self.emptyPlaylistConfig
      : nil
  }

  /// phone-taste: no explainer line, just the title.
  private static let emptyPlaylistConfig: UIContentUnavailableConfiguration = .cassetteEmpty(
    image: CassetteIcon.playlist.uiImage,
    title: "Empty playlist",
    body: nil
  )

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext? {
    guard let songs = fetchedResultsController
      .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode)
    else { return nil }
    return PlayContext(containable: playlist, index: songIndexPath.row, playables: songs)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell)
    else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: IndexPath(row: indexPath.row, section: 0))
  }

  /// The playlist editor, from the more menu's Edit.
  private func openEditView() {
    let playlistDetailVC = AppStoryboard.Main.segueToPlaylistEdit(
      account: account,
      playlist: playlist
    )
    let playlistDetailNav = UINavigationController(rootViewController: playlistDetailVC)
    playlistDetailVC.onDoneCB = {
      self.detailOperationsView?.refresh()
      self.tableView.reloadData()
      self.refreshEmptyState()
    }
    present(playlistDetailNav, animated: true, completion: nil)
  }

  func createCell(
    _ tableView: UITableView,
    forRowAt indexPath: IndexPath,
    playlistItem: PlaylistItem
  )
    -> UITableViewCell {
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
    if let song = playlistItem.playable.asSong {
      // phone-taste: the page's 20pt gutter, the one the MORE LIKE shelf, the album page and
      // Search's song rows share. The row height stays (the 52pt rows are the album page's
      // alone).
      cell.display(
        playable: song,
        playContextCb: convertCellViewToPlayContext,
        rootView: self,
        cassetteIsOwned: cassetteOwnedTrackIds.contains(song.id),
        options: PlayableCellOptions(horizontalMargin: CassetteHeading.sideInset)
      )
    }
    return cell
  }

  // cassette Patch 045: vestigial `updateSearchResults` override
  // removed. PlaylistDetailVC never installed a search controller,
  // so this override only ran when ancestral lifecycle hooks
  // (e.g. BasicTableViewController.viewIsAppearing) called through.
  // The base no-op covers that path.
}
