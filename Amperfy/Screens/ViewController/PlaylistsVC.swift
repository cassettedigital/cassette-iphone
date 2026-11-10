//
//  PlaylistsVC.swift
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
import SwiftUI
import UIKit

// MARK: - PlaylistsDiffableDataSource

class PlaylistsDiffableDataSource: BasicUITableViewDiffableDataSource {
  /// Shows the delete confirmation.
  weak var presenter: UIViewController?

  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    // Return false if you do not want the item to be re-orderable.
    false
  }

  func playlistAt(indexPath: IndexPath) -> Playlist? {
    let objectID = itemIdentifier(for: indexPath)
    guard let objectID,
          let object = try? appDelegate.storage.main.context
          .existingObject(with: objectID),
          let playlistMO = object as? PlaylistMO
    else {
      return nil
    }

    let playlist = Playlist(
      library: appDelegate.storage.main.library,
      managedObject: playlistMO
    )
    return playlist
  }

  // Override to support editing the table view.
  override func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    guard editingStyle == .delete else { return }

    guard let playlist = playlistAt(indexPath: indexPath)
    else {
      return
    }

    // A playlist is deleted on every device and can't be brought back, so the swipe asks
    // first (BUG-891). Cancel leaves the row as it was.
    let confirm = UIAlertController(
      title: "Delete \u{201C}\(playlist.name)\u{201D}?",
      message: "It goes from all your devices.",
      preferredStyle: .alert
    )
    confirm.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
      self?.delete(playlist)
    })
    confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
      tableView.setEditing(false, animated: true)
    })
    // Nothing to ask from, nothing deleted.
    presenter?.present(confirm, animated: true)
  }

  private func delete(_ playlist: Playlist) {
    let playlistId = playlist.id
    appDelegate.storage.main.library.deletePlaylist(playlist)
    appDelegate.storage.main.saveContext()

    guard let account = playlist.account else { return }
    Task { @MainActor in do {
      try await self.appDelegate.getMeta(account.info).librarySyncer
        .syncUpload(playlistIdToDelete: playlistId)
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlist Upload Deletion", error: error)
    }}
  }
}

// MARK: - PlaylistsVC

class PlaylistsVC: SingleSnapshotFetchedResultsTableViewController<PlaylistMO> {
  override var sceneTitle: String? { "Playlists" }

  private var fetchedResultsController: PlaylistFetchedResultsController!
  private var optionsButton: UIBarButtonItem!
  private var sortType: PlaylistSortType = .name

  init(account: Account) {
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  override func createDiffableDataSource() -> BasicUITableViewDiffableDataSource {
    let source =
      PlaylistsDiffableDataSource(tableView: tableView) { [
        weak self
      ] tableView, indexPath, objectID -> UITableViewCell? in
        guard let self else { return UITableViewCell() }
        guard let object = try? appDelegate.storage.main.context
          .existingObject(with: objectID),
          let playlistMO = object as? PlaylistMO
        else {
          return UITableViewCell()
        }
        let playlist = Playlist(
          library: appDelegate.storage.main.library,
          managedObject: playlistMO
        )
        return createCell(tableView, forRowAt: indexPath, playlist: playlist)
      }
    source.presenter = self
    return source
  }

  func playlistAt(indexPath: IndexPath) -> Playlist? {
    (diffableDataSource as? PlaylistsDiffableDataSource)?.playlistAt(indexPath: indexPath)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.playlists)

    optionsButton = UIBarButtonItem.createSortBarButton()

    change(sortType: appDelegate.storage.settings.user.playlistsSortSetting)

    // cassette Polish 2 (B1): per-category search removed; use the global Search tab.
    setNavBarTitle(title: "Playlists")
    tableView.register(nibName: PlaylistTableCell.typeName)
    tableView.rowHeight = PlaylistTableCell.rowHeight
    tableView.estimatedRowHeight = PlaylistTableCell.rowHeight
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    #if !targetEnvironment(macCatalyst)
      refreshControl = UIRefreshControl()
    #endif
    refreshControl?.addTarget(
      self,
      action: #selector(Self.handleRefresh),
      for: UIControl.Event.valueChanged
    )

    containableAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      return playlistAt(indexPath: indexPath)
    }
    playContextAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      guard let entity = playlistAt(indexPath: indexPath) else { return nil }
      // phone-taste: only the playlist's songs on this phone (OneTapPlay).
      return PlayContext(containable: entity, index: 0, playables: OneTapPlay.playables(of: entity))
    }
    swipeCallback = { [weak self] indexPath, completionHandler in
      guard let self else { return }
      guard let playlist = playlistAt(indexPath: indexPath) else { return }
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
        // phone-taste: the swipe queues and plays only what is on this phone.
        completionHandler(SwipeActionContext(containable: OnPhoneContainable(playlist)))
      }
    }
    snapshotDidChange = { [weak self] in
      guard let self else { return }
      updateContentUnavailable()
    }
  }

  func updateContentUnavailable() {
    // Made-for-you playlists under an empty list of their own still make a page.
    applyEmptyState(
      emptyContentState,
      isEmpty: fetchedResultsController.fetchedObjects?.count ?? 0 == 0 && madeForYouHost == nil
    )
  }

  lazy var emptyContentState = ListEmptyState(empty: .cassetteEmpty(
    image: .playlist,
    title: "No playlists yet",
    body: nil
  ))

  func change(sortType: PlaylistSortType) {
    self.sortType = sortType
    appDelegate.storage.settings.user.playlistsSortSetting = sortType
    singleFetchedResultsController?.clearResults()
    fetchedResultsController = PlaylistFetchedResultsController(
      coreDataCompanion: appDelegate.storage.main, account: account,
      sortType: sortType,
      isGroupedInAlphabeticSections: sortType.asSectionIndexType != .none
    )
    fetchedResultsController.fetchResultsController.sectionIndexType = sortType.asSectionIndexType
    singleFetchedResultsController = fetchedResultsController
    singleFetchedResultsController?.delegate = self
    singleFetchedResultsController?.fetch()
    tableView.reloadData()
    updateRightBarButtonItems()
    updateContentUnavailable()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    showMadeForYou()
    if appDelegate.storage.settings.user.isOfflineMode {
      isEditing = false
    }
    updateRightBarButtonItems()
    updateContentUnavailable()
    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    Task { @MainActor in do {
      try await self.appDelegate.getMeta(self.account.info).librarySyncer
        .syncDownPlaylistsWithoutSongs()
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlists Sync", error: error)
    }}
  }

  // MARK: Made for you

  private var madeForYouHost: UIHostingController<MadeForYouList>?

  /// The made-for-you playlists Home shows, under the person's own (I-M8). Built each time
  /// the list appears, from Home's current set; nothing when Home has none.
  private func showMadeForYou() {
    madeForYouHost?.willMove(toParent: nil)
    madeForYouHost?.view.removeFromSuperview()
    madeForYouHost?.removeFromParent()
    madeForYouHost = nil
    let mixes = HomeManager.live?.madeForYouMixes.filter { !OneTapPlay.playables($0.songs).isEmpty } ?? []
    guard !mixes.isEmpty else {
      tableView.tableFooterView = nil
      return
    }
    let host = UIHostingController(rootView: MadeForYouList(mixes: mixes) { [weak self] mix in
      guard let self else { return }
      navigationController?.pushViewController(MixDetailVC(account: account, mix: mix), animated: true)
      navigationController?.navigationBar.prefersLargeTitles = false
    })
    host.view.backgroundColor = .clear
    let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
    let height = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
    addChild(host)
    tableView.tableFooterView = host.view
    host.didMove(toParent: self)
    madeForYouHost = host
  }

  func updateRightBarButtonItems() {
    var actions = [UIMenu]()
    actions.append(createSortButtonMenu())
    actions.append(createOptionsButtonMenu())
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu(children: actions)
    var barButtons = [UIBarButtonItem]()
    barButtons.append(optionsButton)
    if appDelegate.storage.settings.user.isOnlineMode {
      barButtons.append(editButtonItem)
    }
    setRightBarButtonItems(barButtons)
  }

  func createCell(
    _ tableView: UITableView,
    forRowAt indexPath: IndexPath,
    playlist: Playlist
  )
    -> UITableViewCell {
    let cell: PlaylistTableCell = dequeueCell(for: tableView, at: indexPath)
    cell.display(playlist: playlist, rootView: self)
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard let playlist = playlistAt(indexPath: indexPath) else { return }
    navigationController?.pushViewController(
      AppStoryboard.Main.segueToPlaylistDetail(account: account, playlist: playlist),
      animated: true
    )
  }

  private func createSortButtonMenu() -> UIMenu {
    let sortByName = UIAction(
      title: "Name",
      image: sortType == .name ? .check : nil,
      handler: { [weak self] _ in
        guard let self else { return }
        change(sortType: .name)
        updateSearchResults(for: searchController)
        appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByLastTimePlayed = UIAction(
      title: "Last time played",
      image: sortType == .lastPlayed ? .check : nil,
      handler: { [weak self] _ in
        guard let self else { return }
        change(sortType: .lastPlayed)
        updateSearchResults(for: searchController)
        appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByChangeDate = UIAction(
      title: "Change date",
      image: sortType == .lastChanged ? .check : nil,
      handler: { [weak self] _ in
        guard let self else { return }
        change(sortType: .lastChanged)
        updateSearchResults(for: searchController)
        appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByDuration = UIAction(
      title: "Duration",
      image: sortType == .duration ? .check : nil,
      handler: { [weak self] _ in
        guard let self else { return }
        change(sortType: .duration)
        updateSearchResults(for: searchController)
        appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    return UIMenu(
      title: "Sort",
      image: .sort,
      options: [.displayInline],
      children: [sortByName, sortByLastTimePlayed, sortByChangeDate, sortByDuration]
    )
  }

  private func createOptionsButtonMenu() -> UIMenu {
    let fetchAllPlaylists = UIAction(
      title: "Sync All Playlists",
      image: .refresh,
      handler: { [weak self] _ in
        guard let self else { return }
        Task { @MainActor in do {
          let accountObjectId = self.account.managedObject.objectID
          let playlistsIds = try await self.appDelegate.storage.async
            .performAndGet { asyncCompanion in
              let accoundAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
              let playlists = asyncCompanion.library.getPlaylists(for: accoundAsync)
              return playlists.compactMap { $0.managedObject.objectID }
            }
          for moId in playlistsIds {
            let playlistMainMO = self.appDelegate.storage.main.context
              .object(with: moId) as! PlaylistMO
            let playlistMain = Playlist(
              library: self.appDelegate.storage.main.library,
              managedObject: playlistMainMO
            )
            try await playlistMain.fetch(
              storage: self.appDelegate.storage,
              librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
              playableDownloadManager: self.appDelegate.getMeta(self.account.info)
                .playableDownloadManager
            )
          }
          self.appDelegate.eventLogger.info(
            topic: "Sync All Playlists",
            message: "All playlists have been synced."
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Sync All Playlists", error: error)
        }}
      }
    )
    return UIMenu(
      title: "Options",
      image: .sort,
      options: [.displayInline],
      children: [fetchAllPlaylists]
    )
  }

  @objc
  func handleRefresh(refreshControl: UIRefreshControl) {
    Task { @MainActor in
      do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .syncDownPlaylistsWithoutSongs()
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlists Sync", error: error)
      }
      self.refreshControl?.endRefreshing()
    }
  }

  override func updateSearchResults(for searchController: UISearchController) {
    let searchText = searchController.searchBar.text ?? ""
    let playlistSearchCategory = PlaylistSearchCategory(
      rawValue: searchController.searchBar
        .selectedScopeButtonIndex
    ) ?? PlaylistSearchCategory.defaultValue
    fetchedResultsController.search(
      searchText: searchText,
      playlistSearchCategory: playlistSearchCategory
    )
    tableView.reloadData()
    updateContentUnavailable()
  }

  // cassette: the pinned "Liked Songs" header (Patch 044) was removed with the
  // favorites feature. Its setup/refresh/relayout methods, the
  // viewDidLayoutSubviews override that repositioned it, and the
  // LikedSongsHeaderRowView class were all deleted.
}
