//
//  SongsVC.swift
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

class SongsVC: SingleFetchedResultsTableViewController<SongMO> {
  override var sceneTitle: String? {
    switch displayFilter {
    case .all, .newest, .recent: "Songs"
    // cassette Patch 044: rename to match the virtual-playlist
    // entry in PlaylistsVC. The displayFilter / sort / sync paths
    // stay intact — only the user-facing label changes.
    case .favorites: "Liked Songs"
    }
  }

  private var fetchedResultsController: SongsFetchedResultsController!
  private var detailHeaderView: LibraryElementDetailTableHeaderView?
  private var optionsButton: UIBarButtonItem!
  public var displayFilter: DisplayCategoryFilter = .all
  private var sortType: SongElementSortType = .name
  private var filterTitle = "Songs"
  // cassette Layer 3 Phase 3.2: owned track ids for Server Mode row dimming.
  // Only populated in Server Mode (in on-device-only mode the list is already
  // filtered to owned tracks, so the distinction is unnecessary).
  private var cassetteOwnedTrackIds: Set<String> = []

  private static var maxPlayContextCount = 40

  init(account: Account) {
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    #if !targetEnvironment(macCatalyst)
      refreshControl = UIRefreshControl()
    #endif

    appDelegate.userStatistics.visited(.songs)

    optionsButton = UIBarButtonItem.createOptionsBarButton()

    refreshCassetteOwnedTrackIdsIfServerMode()
    applyFilter()
    // cassette Polish 2 (B1): per-category search removed; use the global
    // Search tab. (B2): no Play/Shuffle listing header either. `detailHeaderView`
    // stays nil and all `detailHeaderView?.` calls are no-ops.
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.backgroundColor = .backgroundColor

    #if !targetEnvironment(macCatalyst)
      refreshControl?.addTarget(
        self,
        action: #selector(Self.handleRefresh),
        for: UIControl.Event.valueChanged
      )
    #endif

    containableAtIndexPathCallback = { indexPath in
      self.fetchedResultsController.getWrappedEntity(at: indexPath)
    }
    playContextAtIndexPathCallback = convertIndexPathToPlayContext
    swipeCallback = { indexPath, completionHandler in
      let song = self.fetchedResultsController.getWrappedEntity(at: indexPath)
      let playContext = self.convertIndexPathToPlayContext(songIndexPath: indexPath)
      completionHandler(SwipeActionContext(containable: song, playContext: playContext))
    }
    resultUpdateHandler?.changesDidEnd = {
      self.updateContentUnavailable()
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
    refreshCassetteOwnedTrackIdsIfServerMode()
    change(sortType: sortType)
    updateContentUnavailable()
  }

  private func refreshCassetteOwnedTrackIdsIfServerMode() {
    guard CassetteLibraryFilterProvider.shared.currentFilter == .everything else {
      cassetteOwnedTrackIds = []
      return
    }
    cassetteOwnedTrackIds = DeviceOwnershipManager(
      context: appDelegate.storage.main.context
    ).fetchAllSubsonicTrackIds()
  }

  func updateContentUnavailable() {
    let isEmpty = fetchedResultsController.fetchedObjects?.count ?? 0 == 0
    applyEmptyState(emptyContentState, isEmpty: isEmpty)
    detailHeaderView?.isHidden = isEmpty
  }

  lazy var emptyContentState = ListEmptyState(
    empty: .cassetteEmpty(
      image: .musicalNotes,
      title: "No songs yet",
      body: nil
    ),
    followsOnDeviceFilter: true
  )

  // cassette Layer 3 Phase 3.2: on-device-only empty states. Steer the user to
  // sending music from cassette.digital or enabling Server Mode.
  // cassette (BUG-419): copy and type come from the shared factory
  // (UtilitiesExtensions). There is no Server Mode toggle on the phone.
  func applyFilter() {
    switch displayFilter {
    case .all:
      filterTitle = "Songs"
      isIndexTitelsHidden = false
      change(sortType: appDelegate.storage.settings.user.songsSortSetting)
    case .newest, .recent:
      break
    case .favorites:
      // cassette Patch 044: matches `sceneTitle` for the favorites
      // filter; surfaces in the nav-bar large title, the search
      // placeholder, the play-context name, and the download menu.
      filterTitle = "Liked Songs"
      isIndexTitelsHidden = false
      if account.apiType.asServerApiType != .ampache {
        change(sortType: appDelegate.storage.settings.user.favoriteSongSortSetting)
      } else {
        change(sortType: appDelegate.storage.settings.user.songsSortSetting)
      }
    }
    setNavBarTitle(title: filterTitle)
  }

  func change(sortType: SongElementSortType) {
    self.sortType = sortType
    singleFetchedResultsController?.clearResults()
    tableView.reloadData()
    fetchedResultsController = SongsFetchedResultsController(
      coreDataCompanion: appDelegate.storage.main, account: account,
      sortType: sortType,
      isGroupedInAlphabeticSections: sortType.hasSectionTitles
    )
    fetchedResultsController.fetchResultsController.sectionIndexType = sortType.asSectionIndexType
    singleFetchedResultsController = fetchedResultsController

    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    switch sortType {
    case .rating:
      tableView.sectionHeaderHeight = CommonScreenOperations.tableSectionHeightLarge
      tableView.estimatedSectionHeaderHeight = CommonScreenOperations.tableSectionHeightLarge
    default:
      tableView.sectionHeaderHeight = 0.0
      tableView.estimatedSectionHeaderHeight = 0.0
    }

    tableView.reloadData()
    updateRightBarButtonItems()
    detailHeaderView?.refresh()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    updateRightBarButtonItems()
    updateFromRemote()
    detailHeaderView?.refresh()
  }

  func updateRightBarButtonItems() {
    var actions = [UIMenu]()
    actions.append(createSortButtonMenu())
    if appDelegate.storage.settings.user.isOnlineMode {
      actions.append(createActionButtonMenu())
    }
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu(children: actions)
    setRightBarButtonItems([optionsButton])
  }

  func updateFromRemote() {
    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    switch displayFilter {
    case .all:
      break
    case .newest, .recent:
      break
    case .favorites:
      Task { @MainActor in
        do {
          try await self.appDelegate.getMeta(self.account.info).librarySyncer
            .syncFavoriteLibraryElements()
        } catch {
          // cassette Patch 040: tab-appear background sync.
          self.appDelegate.eventLogger.report(
            topic: "Favorite Songs Sync",
            error: error,
            isBackground: true
          )
        }
        self.detailHeaderView?.refresh()
        self.updateSearchResults(for: self.searchController)
      }
    }
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
    let song = fetchedResultsController.getWrappedEntity(at: indexPath)
    // cassette Layer 3 Phase 3.2: in Server Mode the list shows the full catalog;
    // dim the tracks that aren't on this phone so ownership stays legible. In
    // on-device-only mode every listed song is owned, so no flag is passed.
    let isServerMode = CassetteLibraryFilterProvider.shared.currentFilter == .everything
    cell.display(
      playable: song,
      playContextCb: convertCellViewToPlayContext,
      rootView: self,
      cassetteIsOwned: isServerMode ? cassetteOwnedTrackIds.contains(song.id) : nil
    )
    return cell
  }

  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    switch sortType {
    case .name:
      return 0.0
    case .rating:
      return CommonScreenOperations.tableSectionHeightLarge
    case .addedDate:
      return 0.0
    case .duration:
      return 0.0
    case .starredDate:
      return 0.0
    case .lastPlayedDate:
      // cassette Patch 038: this sort case only feeds the Home
      // Artists shelf today and isn't surfaced in SongsVC; if it
      // ever is, no section headers are wanted (pure recency list).
      return 0.0
    case .playCount:
      // cassette Home Shelves v1: affinity sort feeds the Home album/artist
      // shelves only, not surfaced in SongsVC — no section headers.
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    switch sortType {
    case .name:
      return super.tableView(tableView, titleForHeaderInSection: section)
    case .rating:
      if let sectionNameInitial = super.tableView(tableView, titleForHeaderInSection: section),
         sectionNameInitial != SectionIndexType.noRatingIndexSymbol {
        return "\(sectionNameInitial) Star\(sectionNameInitial != "1" ? "s" : "")"
      } else {
        return "Not rated"
      }
    case .addedDate:
      return nil
    case .duration:
      return nil
    case .starredDate:
      return nil
    case .lastPlayedDate:
      return nil
    case .playCount:
      return nil
    }
  }

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext {
    let song = fetchedResultsController.getWrappedEntity(at: songIndexPath)

    guard let allFetchedObjects = fetchedResultsController.fetchedObjects,
          let arrayIndex = allFetchedObjects.firstIndex(of: song.managedObject)
    else { return PlayContext(containable: song) }

    var contextPlayables = [AbstractPlayable]()
    let endIndex = min(arrayIndex + Self.maxPlayContextCount - 1, allFetchedObjects.count - 1)
    for i in arrayIndex ... endIndex {
      contextPlayables.append(Song(managedObject: allFetchedObjects[i]))
    }
    return PlayContext(name: filterTitle, playables: contextPlayables)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell) else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: indexPath)
  }

  override func updateSearchResults(for searchController: UISearchController) {
    guard let searchText = searchController.searchBar.text else { return }
    if !searchText.isEmpty, searchController.searchBar.selectedScopeButtonIndex == 0 {
      // Cassette fork — Layer 3 Phase 3.2 (library filtering). The remote
      // Subsonic search only makes sense in Server Mode; in on-device-only mode
      // we search the (already ownership-filtered) local FRC alone. Kept as a
      // separate statement from the FRC search so a future tri-state mode is a
      // clean add.
      if CassetteLibraryFilterProvider.shared.currentFilter == .everything {
        Task { @MainActor in do {
          try await self.appDelegate.getMeta(self.account.info).librarySyncer
            .searchSongs(searchText: searchText)
        } catch {
          self.appDelegate.eventLogger.report(topic: "Songs Search", error: error)
        }}
      }
      fetchedResultsController.search(
        searchText: searchText,
        onlyCachedSongs: false,
        displayFilter: displayFilter
      )
    } else if searchController.searchBar.selectedScopeButtonIndex == 1 {
      fetchedResultsController.search(
        searchText: searchText,
        onlyCachedSongs: true,
        displayFilter: displayFilter
      )
    } else if displayFilter != .all {
      fetchedResultsController.search(
        searchText: searchText,
        onlyCachedSongs: searchController.searchBar.selectedScopeButtonIndex == 1,
        displayFilter: displayFilter
      )
    } else {
      fetchedResultsController.showAllResults()
    }
    tableView.reloadData()
    detailHeaderView?.refresh()
    updateContentUnavailable()
  }

  private func saveSortPreference(preference: SongElementSortType) {
    if account.apiType.asServerApiType != .ampache, displayFilter == .favorites {
      appDelegate.storage.settings.user.favoriteSongSortSetting = preference
    } else {
      appDelegate.storage.settings.user.songsSortSetting = preference
    }
  }

  private func handleHeaderPlay() -> PlayContext {
    guard let displayedSongsMO = fetchedResultsController.fetchedObjects else { return PlayContext(
      name: filterTitle,
      playables: []
    ) }
    if displayedSongsMO.count > appDelegate.player.maxSongsToAddOnce {
      let songsToPlay = displayedSongsMO.prefix(appDelegate.player.maxSongsToAddOnce)
        .compactMap { Song(managedObject: $0) }
      return PlayContext(name: filterTitle, playables: songsToPlay)
    } else {
      let songsToPlay = displayedSongsMO.compactMap { Song(managedObject: $0) }
      return PlayContext(name: filterTitle, playables: songsToPlay)
    }
  }

  private func handleHeaderShuffle() -> PlayContext {
    guard let displayedSongsMO = fetchedResultsController.fetchedObjects else { return PlayContext(
      name: filterTitle,
      playables: []
    ) }
    if displayedSongsMO.count > appDelegate.player.maxSongsToAddOnce {
      let songsToPlay = displayedSongsMO[randomPick: appDelegate.player.maxSongsToAddOnce]
        .compactMap { Song(managedObject: $0) }
      return PlayContext(name: filterTitle, playables: songsToPlay)
    } else {
      let songsToPlay = displayedSongsMO.compactMap { Song(managedObject: $0) }
      return PlayContext(name: filterTitle, playables: songsToPlay)
    }
  }

  private func createSortButtonMenu() -> UIMenu {
    let sortByName = UIAction(
      title: "Name",
      image: sortType == .name ? .check : nil,
      handler: { _ in
        self.change(sortType: .name)
        self.saveSortPreference(preference: .name)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByRating = UIAction(
      title: "Rating",
      image: sortType == .rating ? .check : nil,
      handler: { _ in
        self.change(sortType: .rating)
        self.saveSortPreference(preference: .rating)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByDuration = UIAction(
      title: "Duration",
      image: sortType == .duration ? .check : nil,
      handler: { _ in
        self.change(sortType: .duration)
        self.saveSortPreference(preference: .duration)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByStarredDate = UIAction(
      title: "Starred date",
      image: sortType == .starredDate ? .check : nil,
      handler: { _ in
        self.change(sortType: .starredDate)
        self.saveSortPreference(preference: .starredDate)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByAddedDate = UIAction(
      title: "Date Added",
      image: sortType == .addedDate ? .check : nil,
      handler: { _ in
        self.change(sortType: .addedDate)
        self.saveSortPreference(preference: .addedDate)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    if displayFilter == .favorites, account.apiType.asServerApiType != .ampache {
      return UIMenu(
        title: "Sort",
        image: .sort,
        options: [],
        children: [sortByName, sortByRating, sortByDuration, sortByStarredDate, sortByAddedDate]
      )
    } else if account.apiType.asServerApiType != .ampache {
      return UIMenu(
        title: "Sort",
        image: .sort,
        options: [],
        children: [sortByName, sortByRating, sortByDuration, sortByAddedDate]
      )
    } else {
      return UIMenu(
        title: "Sort",
        image: .sort,
        options: [],
        children: [sortByName, sortByRating, sortByDuration]
      )
    }
  }

  private func createActionButtonMenu() -> UIMenu {
    let action = UIAction(
      title: "Download \(filterTitle)",
      image: UIImage.startDownload,
      handler: { _ in
        var songs = [Song]()
        switch self.displayFilter {
        case .all:
          songs = self.appDelegate.storage.main.library.getSongs(for: self.account)
        case .newest, .recent:
          break
        case .favorites:
          songs = self.appDelegate.storage.main.library
            .getFavoriteSongs(for: self.account)
        }
        if songs.count > AppDelegate.maxPlayablesDownloadsToAddAtOnceWithoutWarning {
          let alert = UIAlertController(
            title: "Many Songs",
            message: "Are you sure to add \(songs.count) songs from \"\(self.filterTitle)\" to download queue?",
            preferredStyle: .alert
          )
          alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            self.appDelegate.getMeta(self.account.info).playableDownloadManager
              .download(objects: songs)
          }))
          alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
          self.present(alert, animated: true, completion: nil)
        } else {
          self.appDelegate.getMeta(self.account.info).playableDownloadManager
            .download(objects: songs)
        }
      }
    )
    return UIMenu(options: [.displayInline], children: [action])
  }

  @objc
  func handleRefresh(refreshControl: UIRefreshControl) {
    guard appDelegate.storage.settings.user.isOnlineMode else {
      self.refreshControl?.endRefreshing()
      return
    }
    Task { @MainActor in
      do {
        try await AutoDownloadLibrarySyncer(
          storage: self.appDelegate.storage,
          account: self.account,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
        .syncNewestLibraryElements()
      } catch {
        self.appDelegate.eventLogger.report(
          topic: "Songs Newest Elements Sync",
          error: error,
          isBackground: true
        )
      }
      detailHeaderView?.refresh()
      self.refreshControl?.endRefreshing()
    }
  }
}
