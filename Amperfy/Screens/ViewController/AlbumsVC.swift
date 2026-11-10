//
//  AlbumsVC.swift
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

// MARK: - AlbumsDiffableDataSource

class AlbumsDiffableDataSource: BasicUITableViewDiffableDataSource {
  var sortType: AlbumElementSortType = .name
  /// cassette: mirrors AlbumsCommonVCInteractions.isGroupedInAlphabeticSections
  /// (synced alongside sortType) so the table suppresses section headers when a
  /// small collection is flattened by the adaptive-grouping decision.
  var isGroupedInAlphabeticSections = false

  func getAlbum(at indexPath: IndexPath) -> Album? {
    guard let objectID = itemIdentifier(for: indexPath) else { return nil }
    guard let object = try? appDelegate.storage.main.context.existingObject(with: objectID),
          let albumMO = object as? AlbumMO
    else {
      return nil
    }
    return Album(managedObject: albumMO)
  }

  func getFirstAlbum(in section: Int) -> Album? {
    getAlbum(at: IndexPath(row: 0, section: section))
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    // cassette: adaptive grouping — when flattened, suppress section titles so
    // a small collection shows no lone letter header (mirrors the grid style).
    guard isGroupedInAlphabeticSections else { return nil }
    switch sortType {
    case .name:
      guard let album = getFirstAlbum(in: section) else { return nil }
      return album.name
    case .rating:
      guard let album = getFirstAlbum(in: section) else { return nil }
      if album.rating > 0 {
        return "\(album.rating) Star\(album.rating != 1 ? "s" : "")"
      } else {
        return "Not rated"
      }
    case .newest, .recent:
      return nil
    case .artist:
      guard let album = getFirstAlbum(in: section) else { return nil }
      return album.subtitle
    case .duration:
      guard let album = getFirstAlbum(in: section) else { return nil }
      return album.duration.description
    case .year:
      let year = getFirstAlbum(in: section)?.year.description
      guard let year = year else { return nil }
      return IndexHeaderNameGenerator.sortByYear(forSectionName: year)
    }
  }

  override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
    let sectionCount = numberOfSections(in: tableView)
    var indexTitles = [String]()
    for i in 0 ..< sectionCount {
      if let sectionName = self.tableView(tableView, titleForHeaderInSection: i) {
        var indexTitle = ""
        switch sortType {
        case .name:
          indexTitle = sectionName.prefix(1).uppercased()
          if let _ = Int(indexTitle) {
            indexTitle = "#"
          }
        case .artist:
          indexTitle = sectionName.prefix(1).uppercased()
          if let _ = Int(indexTitle) {
            indexTitle = "#"
          }
        case .rating:
          indexTitle = IndexHeaderNameGenerator.sortByRating(forSectionName: sectionName)
        case .duration:
          indexTitle = IndexHeaderNameGenerator.sortByDurationAlbum(forSectionName: sectionName)
        case .year:
          indexTitle = IndexHeaderNameGenerator.sortByYear(forSectionName: sectionName)
        default:
          break
        }
        indexTitles.append(indexTitle)
      }
    }
    return indexTitles
  }

  override func tableView(
    _ tableView: UITableView,
    sectionForSectionIndexTitle title: String,
    at index: Int
  )
    -> Int {
    index
  }
}

// MARK: - AlbumsVC

class AlbumsVC: SingleSnapshotFetchedResultsTableViewController<AlbumMO> {
  override var sceneTitle: String? {
    common.sceneTitle
  }

  private let common: AlbumsCommonVCInteractions
  private var detailHeader: LibraryElementDetailTableHeaderView?
  // cassette Layer 3 Phase 3.2: owned album ids for Server Mode row dimming.
  private var cassetteOwnedAlbumIds: Set<String> = []

  public var displayFilter: DisplayCategoryFilter {
    set { common.displayFilter = newValue }
    get { common.displayFilter }
  }

  private var albumsDataSource: AlbumsDiffableDataSource? {
    diffableDataSource as? AlbumsDiffableDataSource
  }

  init(account: Account) {
    self.common = AlbumsCommonVCInteractions(account: account)
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func createDiffableDataSource() -> BasicUITableViewDiffableDataSource {
    let source =
      AlbumsDiffableDataSource(tableView: tableView) { [
        weak self
      ] tableView, indexPath, objectID -> UITableViewCell? in
        guard let self else { return UITableViewCell() }
        guard let object = try? appDelegate.storage.main.context
          .existingObject(with: objectID),
          let albumMO = object as? AlbumMO
        else {
          fatalError("Managed object should be available")
        }
        let album = Album(managedObject: albumMO)
        return createCell(tableView, forRowAt: indexPath, album: album)
      }
    return source
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    suppressDuplicateLibraryEntityIds = true
    usesFadingSectionIndex = true

    #if !targetEnvironment(macCatalyst)
      refreshControl = UIRefreshControl()
    #endif

    appDelegate.userStatistics.visited(.albums)

    common.rootVC = self
    common.isIndexTitelsHiddenCB = { [weak self] in
      guard let self else { return }
      isIndexTitelsHidden = common.isIndexTitelsHidden
    }
    common.reloadListViewCB = { [weak self] in
      guard let self else { return }
      tableView.reloadData()
    }
    common.updateSearchResultsCB = { [weak self] in
      guard let self else { return }
      updateSearchResults(for: searchController)
    }
    common.endRefreshCB = { [weak self] in
      guard let self else { return }
      refreshControl?.endRefreshing()
    }
    common.updateFetchDataSourceCB = { [weak self] in
      guard let self else { return }
      let albumsSource = diffableDataSource as? AlbumsDiffableDataSource
      albumsSource?.sortType = common.sortType
      albumsSource?.isGroupedInAlphabeticSections = common.isGroupedInAlphabeticSections
      singleFetchedResultsController = common.fetchedResultsController
      singleFetchedResultsController?.delegate = self
    }

    refreshCassetteOwnedAlbumIdsIfServerMode()
    common.applyFilter()
    // cassette Polish 2 (B1): per-category search removed; the global Search
    // tab covers this. No `navigationItem.searchController` is installed.
    tableView.register(nibName: GenericTableCell.typeName)
    tableView.rowHeight = GenericTableCell.rowHeight
    tableView.estimatedRowHeight = GenericTableCell.rowHeight
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    // cassette Polish 2 (B2): no Play/Shuffle header on the Albums listing
    // page ("play all my albums" is not a useful action). The detail-page
    // header (Album/Artist/Playlist) keeps its Play/Shuffle. `detailHeader`
    // stays nil; all `detailHeader?.` calls become no-ops.
    refreshControl?.addTarget(
      common,
      action: #selector(AlbumsCommonVCInteractions.handleRefresh),
      for: UIControl.Event.valueChanged
    )

    containableAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      return albumsDataSource?.getAlbum(at: indexPath)
    }
    playContextAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      guard let album = albumsDataSource?.getAlbum(at: indexPath) else { return nil }
      // phone-taste: only the album's songs on this phone (OneTapPlay).
      return PlayContext(containable: album, index: 0, playables: OneTapPlay.playables(of: album))
    }
    swipeCallback = { [weak self] indexPath, completionHandler in
      guard let self else { return }
      guard let album = albumsDataSource?.getAlbum(at: indexPath) else {
        completionHandler(nil)
        return
      }
      Task { @MainActor in
        do {
          try await album.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          // cassette Patch 040: swipe-prefetch background sync.
          self.appDelegate.eventLogger.report(
            topic: "Album Sync",
            error: error,
            isBackground: true
          )
        }
        // phone-taste: the swipe queues and plays only what is on this phone.
        completionHandler(SwipeActionContext(containable: OnPhoneContainable(album)))
      }
    }
    snapshotDidChange = { [weak self] in
      guard let self else { return }
      common.updateContentUnavailable()
      updateHeaderViewVisibility()
    }

    // cassette Layer 3 Phase 3.2: rebuild the FRC when Server Mode toggles so
    // the ownership predicate changes between on-device-only and full catalog.
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(cassetteLibraryFilterChanged),
      name: CassetteLibraryFilterProvider.filterChangedNotification,
      object: nil
    )
  }

  @objc
  private func cassetteLibraryFilterChanged() {
    refreshCassetteOwnedAlbumIdsIfServerMode()
    // Music arriving or leaving: go straight from the old albums to the new ones and keep the
    // place, as the grid does, instead of emptying the list and landing back at the top (BUG-448).
    if common.refreshOwnedScope() {
      tableView.reloadData()
    }
  }

  private func refreshCassetteOwnedAlbumIdsIfServerMode() {
    guard CassetteLibraryFilterProvider.shared.currentFilter == .everything else {
      cassetteOwnedAlbumIds = []
      return
    }
    cassetteOwnedAlbumIds = DeviceOwnershipManager(
      context: appDelegate.storage.main.context
    ).fetchOwnedAlbumIds()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    detailHeader?.refresh()
    common.updateRightBarButtonItems()
    common.updateFromRemote()
    common.updateContentUnavailable()
    updateHeaderViewVisibility()
  }

  func updateHeaderViewVisibility() {
    detailHeader?.isHidden = common.isContentUnavailable
  }

  override func tableView(
    _ tableView: UITableView,
    willDisplay cell: UITableViewCell,
    forRowAt indexPath: IndexPath
  ) {
    common.listViewWillDisplayCell(at: indexPath, searchBarText: searchController.searchBar.text)
  }

  func createCell(
    _ tableView: UITableView,
    forRowAt indexPath: IndexPath,
    album: Album
  )
    -> UITableViewCell {
    let cell: GenericTableCell = dequeueCell(for: tableView, at: indexPath)
    if let album = (diffableDataSource as? AlbumsDiffableDataSource)?.getAlbum(at: indexPath) {
      // cassette Layer 3 Phase 3.2: dim non-owned albums in Server Mode.
      let isServerMode = CassetteLibraryFilterProvider.shared.currentFilter == .everything
      cell.display(
        container: album,
        rootView: self,
        cassetteIsOwned: isServerMode ? cassetteOwnedAlbumIds.contains(album.id) : nil
      )
    }
    return cell
  }

  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    switch common.sortType {
    case .artist, .duration, .name, .newest, .recent:
      return 0.0
    case .rating, .year:
      return CommonScreenOperations.tableSectionHeightLarge
    }
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard let album = (diffableDataSource as? AlbumsDiffableDataSource)?.getAlbum(at: indexPath)
    else { return }
    navigationController?.pushViewController(
      AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
      animated: true
    )
  }

  override func updateSearchResults(for searchController: UISearchController) {
    common.updateSearchResults(for: self.searchController)
    tableView.reloadData()
    detailHeader?.refresh()
    updateHeaderViewVisibility()
  }
}
