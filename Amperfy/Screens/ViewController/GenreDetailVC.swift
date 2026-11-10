//
//  GenreDetailVC.swift
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

class GenreDetailVC: MultiSourceTableViewController {
  override var sceneTitle: String? { genre.name }

  private let genre: Genre

  private var artistsFetchedResultsController: GenreArtistsFetchedResultsController!
  private var albumsFetchedResultsController: GenreAlbumsFetchedResultsController!
  private var songsFetchedResultsController: GenreSongsFetchedResultsController!
  private var optionsButton: UIBarButtonItem!
  private var detailOperationsView: GenericDetailTableHeader?
  /// What the page lists (phone-taste): on the phone, the artists, albums and songs on it;
  /// in Server Mode, the hub's counts. Read in `refreshGenreMetadataLine`.
  private var listedCounts = (artists: 0, albums: 0, songs: 0)

  init(account: Account, genre: Genre) {
    self.genre = genre
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    // cassette Patch 037: see ArtistDetailVC for context — pin
    // inline title before super so the parent's large title
    // doesn't flash through the push transition.
    navigationItem.largeTitleDisplayMode = .never
    super.viewDidLoad()

    appDelegate.userStatistics.visited(.genreDetail)

    optionsButton = UIBarButtonItem.createOptionsBarButton()

    makeFetchedResultsControllers()
    setFetchedResultsDelegates(self)
    // phone-taste: the three lists bake what is on the phone into their queries, so they
    // are rebuilt when that changes (an album arrives or is removed from this phone) or
    // Server Mode flips, as the library lists are.
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(libraryFilterChanged),
      name: CassetteLibraryFilterProvider.filterChangedNotification,
      object: nil
    )
    tableView.register(nibName: GenericTableCell.typeName)
    tableView.register(nibName: GenericTableCell.typeName)
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    // phone-taste: on the phone everything listed is already here, so the All/Cached
    // scope is a no-op and is hidden (as on Search). Server Mode keeps it.
    configureSearchController(
      placeholder: "Artists, Albums and Songs",
      scopeButtonTitles: CassetteLibraryFilterProvider.shared.isOnDeviceOnly ? nil : ["All", "Cached"]
    )
    setNavBarTitle(title: genre.name)
    refreshListedCounts()

    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: {
        let counts = self.listedCounts
        return "\(counts.artists) Artist\(counts.artists == 1 ? "" : "s") \(CommonString.oneMiddleDot) \(counts.albums) Album\(counts.albums == 1 ? "" : "s") \(CommonString.oneMiddleDot) \(counts.songs) Song\(counts.songs == 1 ? "" : "s")"
      },
      playContextCb: { () in PlayContext(containable: self.genre, playables: self.listedSongs()) },
      player: appDelegate.player,
      isInfoAlwaysHidden: true
    )
    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: genre,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: playShuffleInfoConfig
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)
    refreshGenreMetadataLine()

    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu.lazyMenu {
      // phone-taste: the shared builder plays and queues `genre.playables`, every song the
      // hub has in the genre. On the phone the menu reads the page's own list instead.
      if CassetteLibraryFilterProvider.shared.isOnDeviceOnly {
        return self.onPhoneOptionsMenuActions()
      }
      return EntityPreviewActionBuilder(container: self.genre, on: self).createMenuActions()
    }
    navigationItem.rightBarButtonItem = optionsButton

    containableAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      switch indexPath.section + 0 {
      case LibraryElement.Artist.rawValue:
        return artistsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
      case LibraryElement.Album.rawValue:
        return albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
      case LibraryElement.Song.rawValue:
        return songsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
      default:
        return nil
      }
    }
    playContextAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      switch indexPath.section + 0 {
      case LibraryElement.Artist.rawValue:
        let entity = artistsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
        return Self.onPhonePlayContext(entity)
      case LibraryElement.Album.rawValue:
        let entity = albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
        return Self.onPhonePlayContext(entity)
      case LibraryElement.Song.rawValue:
        let entity = songsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
        return PlayContext(containable: entity)
      default:
        return nil
      }
    }
    swipeCallback = { [weak self] indexPath, completionHandler in
      guard let self else { return }
      switch indexPath.section + 0 {
      case LibraryElement.Artist.rawValue:
        let artist = artistsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
        Task { @MainActor in
          do {
            try await artist.fetch(
              storage: self.appDelegate.storage,
              librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
              playableDownloadManager: self.appDelegate.getMeta(self.account.info)
                .playableDownloadManager
            )
          } catch {
            // cassette Patch 040: swipe-prefetch background sync.
            self.appDelegate.eventLogger.report(
              topic: "Artist Sync",
              error: error,
              isBackground: true
            )
          }
          // The queue swipes read the context's container, so it is the artist as
          // seen through the phone.
          completionHandler(SwipeActionContext(
            containable: OnPhoneContainable(artist),
            playContext: Self.onPhonePlayContext(artist)
          ))
        }
      case LibraryElement.Album.rawValue:
        let album = albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
        Task { @MainActor in
          do {
            try await album.fetch(
              storage: self.appDelegate.storage,
              librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
              playableDownloadManager: self.appDelegate.getMeta(self.account.info)
                .playableDownloadManager
            )
          } catch {
            self.appDelegate.eventLogger.report(
              topic: "Album Sync",
              error: error,
              isBackground: true
            )
          }
          // The queue swipes read the context's container, so it is the album as
          // seen through the phone.
          completionHandler(SwipeActionContext(
            containable: OnPhoneContainable(album),
            playContext: Self.onPhonePlayContext(album)
          ))
        }
      case LibraryElement.Song.rawValue:
        let songIndexPath = IndexPath(row: indexPath.row, section: 0)
        let song = songsFetchedResultsController.getWrappedEntity(at: songIndexPath)
        let playContext = convertIndexPathToPlayContext(songIndexPath: songIndexPath)
        completionHandler(SwipeActionContext(containable: song, playContext: playContext))
      default:
        completionHandler(nil)
      }
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    setFetchedResultsDelegates(self)

    Task { @MainActor in
      do {
        try await genre.fetch(
          storage: self.appDelegate.storage,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
      } catch {
        // cassette Patch 040: detail-appear background sync.
        self.appDelegate.eventLogger.report(
          topic: "Genre Sync",
          error: error,
          isBackground: true
        )
      }
      self.refreshListedCounts()
      self.refreshGenreMetadataLine()
      self.detailOperationsView?.refresh()
    }
  }

  /// The three lists, built over one read of what is on the phone (nil in Server Mode)
  /// instead of each list reading every owned song on its own.
  private func makeFetchedResultsControllers() {
    let main = appDelegate.storage.main
    let onPhone = CassetteOnPhoneSource.shared(CassetteOnPhoneIds.read(coreDataCompanion: main))
    artistsFetchedResultsController = GenreArtistsFetchedResultsController(
      for: genre,
      coreDataCompanion: main,
      isGroupedInAlphabeticSections: false,
      onPhone: onPhone
    )
    albumsFetchedResultsController = GenreAlbumsFetchedResultsController(
      for: genre,
      coreDataCompanion: main,
      isGroupedInAlphabeticSections: false,
      onPhone: onPhone
    )
    songsFetchedResultsController = GenreSongsFetchedResultsController(
      for: genre,
      coreDataCompanion: main,
      isGroupedInAlphabeticSections: false,
      onPhone: onPhone
    )
  }

  /// The lists follow changes while the page is on screen (self) and stop when it leaves
  /// (nil).
  private func setFetchedResultsDelegates(_ delegate: NSFetchedResultsControllerDelegate?) {
    artistsFetchedResultsController?.delegate = delegate
    albumsFetchedResultsController?.delegate = delegate
    songsFetchedResultsController?.delegate = delegate
  }

  /// What is on the phone changed (an album arrived, or was removed from this phone) or
  /// Server Mode flipped. The lists baked the old set into their queries, so they are
  /// rebuilt and re-run, and the counts and Play follow them.
  @objc
  private func libraryFilterChanged() {
    guard isViewLoaded else { return }
    setFetchedResultsDelegates(nil)
    makeFetchedResultsControllers()
    if viewIfLoaded?.window != nil {
      setFetchedResultsDelegates(self)
    }
    updateSearchResults(for: searchController)
    detailOperationsView?.refresh()
  }

  /// phone-taste: count what the page lists. On the phone the three lists hold only what
  /// is on it, so the counts are their sizes, taken while no search narrows them (a search
  /// inside the page keeps the counts of the whole page); Server Mode keeps the hub's
  /// counts.
  private func refreshListedCounts() {
    guard CassetteLibraryFilterProvider.shared.isOnDeviceOnly,
          let artistsFetchedResultsController,
          let albumsFetchedResultsController,
          let songsFetchedResultsController
    else {
      listedCounts = (genre.artistCount, genre.albumCount, genre.songCount)
      return
    }
    guard !artistsFetchedResultsController.isSearchActive,
          !albumsFetchedResultsController.isSearchActive,
          !songsFetchedResultsController.isSearchActive,
          let artists = artistsFetchedResultsController.fetchedObjects,
          let albums = albumsFetchedResultsController.fetchedObjects,
          let songs = songsFetchedResultsController.fetchedObjects
    else { return }
    listedCounts = (artists.count, albums.count, songs.count)
  }

  /// The page's songs as the header's Play takes them: on the phone, only the songs on
  /// it (the song list's own query).
  private func listedSongs() -> [AbstractPlayable] {
    songsFetchedResultsController
      .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode) ?? []
  }

  /// phone-taste: the options menu on the phone. Every action takes the page's own list of
  /// songs on the phone (`listedSongs`), never `genre.playables`, which is every song the
  /// hub has in the genre. Same actions and wording as the shared menu for a genre.
  private func onPhoneOptionsMenuActions() -> [UIMenuElement] {
    let settings = appDelegate.storage.settings.user
    var playActions: [UIMenuElement] = [
      UIAction(title: "Play", image: .play) { [weak self] _ in
        guard let self else { return }
        withListedSongs { songs in
          self.appDelegate.player.play(context: PlayContext(
            containable: self.genre,
            playables: songs
          ))
        }
      },
    ]
    if settings.isPlayerShuffleButtonEnabled {
      playActions.append(UIAction(title: "Shuffle", image: .shuffle) { [weak self] _ in
        guard let self else { return }
        withListedSongs { songs in
          self.appDelegate.player
            .playShuffled(context: PlayContext(containable: self.genre, playables: songs))
        }
      })
    }
    var actions: [UIMenuElement] = [
      UIMenu(options: .displayInline, children: playActions),
      // the two queue verbs, as in every other menu (EntityPreviewVC.createMusicQueueAction)
      UIMenu(options: .displayInline, children: [
        UIAction(title: "Play Next", image: .userQueueInsert) { [weak self] _ in
          guard let self else { return }
          withListedSongs { self.appDelegate.player.insertUserQueue(playables: $0) }
        },
        UIAction(title: "Add to Queue", image: .userQueueAppend) { [weak self] _ in
          guard let self else { return }
          withListedSongs { self.appDelegate.player.appendUserQueue(playables: $0) }
        },
      ]),
    ]
    if settings.isOnlineMode {
      actions.append(UIMenu(options: .displayInline, children: [
        UIAction(title: "Add to Playlist", image: .playlistPlus) { [weak self] _ in
          guard let self else { return }
          withListedSongs { songs in
            let selectPlaylistVC = AppStoryboard.Main
              .segueToPlaylistSelector(account: self.account, itemsToAdd: songs.filterSongs())
            self.present(UINavigationController(rootViewController: selectPlaylistVC), animated: true)
          }
        },
      ]))
    }
    return actions
  }

  /// Runs `action` with the page's songs on the phone, read when the action is chosen;
  /// nothing happens when there are none.
  private func withListedSongs(_ action: ([AbstractPlayable]) -> ()) {
    let songs = listedSongs()
    guard !songs.isEmpty else { return }
    action(songs)
  }

  /// A row's play context with only the songs this phone can play (OneTapPlay's rule), so
  /// a long-press or swipe Play never starts music that is not here. The swipe queue
  /// actions get the same through OnPhoneContainable; the long-press menu's queue and Add to
  /// Playlist actions apply the same rule themselves (EntityPreviewActionBuilder).
  private static func onPhonePlayContext(_ containable: PlayableContainable) -> PlayContext {
    PlayContext(containable: containable, index: 0, playables: OneTapPlay.playables(of: containable))
  }

  // Patch 026: genre metadata line, "23 artists · 412 songs". cassette:
  // leading type noun dropped, matching the other detail pages. phone-taste: counted from
  // what the page lists (see refreshListedCounts).
  private func refreshGenreMetadataLine() {
    let counts = listedCounts
    var parts: [String] = []
    if counts.artists > 0 {
      parts.append("\(counts.artists) artist\(counts.artists == 1 ? "" : "s")")
    }
    if counts.songs > 0 {
      parts.append("\(counts.songs) song\(counts.songs == 1 ? "" : "s")")
    }
    detailOperationsView?.metadataOverride = parts.joined(separator: " · ")
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    setFetchedResultsDelegates(nil)
  }

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext? {
    guard let songs = songsFetchedResultsController
      .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode)
    else { return nil }
    let selectedSong = songsFetchedResultsController.getWrappedEntity(at: songIndexPath)
    guard let playContextIndex = songs.firstIndex(of: selectedSong) else { return nil }
    return PlayContext(containable: genre, index: playContextIndex, playables: songs)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell),
          indexPath.section + 0 == LibraryElement.Song.rawValue
    else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: IndexPath(row: indexPath.row, section: 0))
  }

  // MARK: - Table view data source

  override func numberOfSections(in tableView: UITableView) -> Int {
    // 3 section + 1 top section. The top section is needed due to display bugs
    4
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    switch section + 0 {
    case LibraryElement.Artist.rawValue:
      return "Artists"
    case LibraryElement.Album.rawValue:
      return "Albums"
    case LibraryElement.Song.rawValue:
      return "Songs"
    default:
      return ""
    }
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch section + 0 {
    case LibraryElement.Artist.rawValue:
      return artistsFetchedResultsController.sections?[0].numberOfObjects ?? 0
    case LibraryElement.Album.rawValue:
      return albumsFetchedResultsController.sections?[0].numberOfObjects ?? 0
    case LibraryElement.Song.rawValue:
      return songsFetchedResultsController.sections?[0].numberOfObjects ?? 0
    default:
      return 0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    switch indexPath.section + 0 {
    case LibraryElement.Artist.rawValue:
      let cell: GenericTableCell = dequeueCell(for: tableView, at: indexPath)
      let artist = artistsFetchedResultsController.getWrappedEntity(at: IndexPath(
        row: indexPath.row,
        section: 0
      ))
      cell.display(container: artist, rootView: self)
      return cell
    case LibraryElement.Album.rawValue:
      let cell: GenericTableCell = dequeueCell(for: tableView, at: indexPath)
      let album = albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
        row: indexPath.row,
        section: 0
      ))
      cell.display(container: album, rootView: self)
      return cell
    case LibraryElement.Song.rawValue:
      let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
      let song = songsFetchedResultsController.getWrappedEntity(at: IndexPath(
        row: indexPath.row,
        section: 0
      ))
      cell.display(playable: song, playContextCb: convertCellViewToPlayContext, rootView: self)
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
    switch section + 0 {
    case LibraryElement.Artist.rawValue:
      return artistsFetchedResultsController.sections?[0]
        .numberOfObjects ?? 0 > 0 ? CommonScreenOperations.tableSectionHeightLarge : 0
    case LibraryElement.Album.rawValue:
      return albumsFetchedResultsController.sections?[0]
        .numberOfObjects ?? 0 > 0 ? CommonScreenOperations.tableSectionHeightLarge : 0
    case LibraryElement.Song.rawValue:
      return songsFetchedResultsController.sections?[0]
        .numberOfObjects ?? 0 > 0 ? CommonScreenOperations.tableSectionHeightLarge : 0
    default:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch indexPath.section + 0 {
    case LibraryElement.Artist.rawValue:
      return GenericTableCell.rowHeight
    case LibraryElement.Album.rawValue:
      return GenericTableCell.rowHeight
    case LibraryElement.Song.rawValue:
      return PlayableTableCell.rowHeight
    default:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    estimatedHeightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch indexPath.section + 0 {
    case LibraryElement.Artist.rawValue:
      return GenericTableCell.rowHeight
    case LibraryElement.Album.rawValue:
      return GenericTableCell.rowHeight
    case LibraryElement.Song.rawValue:
      return PlayableTableCell.rowHeight
    default:
      return 0.0
    }
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    switch indexPath.section + 0 {
    case LibraryElement.Artist.rawValue:
      let artist = artistsFetchedResultsController.getWrappedEntity(at: IndexPath(
        row: indexPath.row,
        section: 0
      ))
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist),
        animated: true
      )
    case LibraryElement.Album.rawValue:
      let album = albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
        row: indexPath.row,
        section: 0
      ))
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
        animated: true
      )
    case LibraryElement.Song.rawValue: break
    default: break
    }
  }

  override func updateSearchResults(for searchController: UISearchController) {
    guard let searchText = searchController.searchBar.text else { return }
    // With the scope bar hidden (on the phone) the selected index is -1, not 0, so the
    // default search is anything but the Cached scope (index 1), as on Search.
    if !searchText.isEmpty, searchController.searchBar.selectedScopeButtonIndex != 1 {
      artistsFetchedResultsController.search(searchText: searchText, onlyCached: false)
      albumsFetchedResultsController.search(searchText: searchText, onlyCached: false)
      songsFetchedResultsController.search(searchText: searchText, onlyCachedSongs: false)
    } else if searchController.searchBar.selectedScopeButtonIndex == 1 {
      artistsFetchedResultsController.search(searchText: searchText, onlyCached: true)
      albumsFetchedResultsController.search(searchText: searchText, onlyCached: true)
      songsFetchedResultsController.search(searchText: searchText, onlyCachedSongs: true)
    } else {
      artistsFetchedResultsController.showAllResults()
      albumsFetchedResultsController.showAllResults()
      songsFetchedResultsController.showAllResults()
    }
    refreshListedCounts()
    refreshGenreMetadataLine()
    tableView.reloadData()
  }

  override func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>,
    didChange anObject: Any,
    at indexPath: IndexPath?,
    for type: NSFetchedResultsChangeType,
    newIndexPath: IndexPath?
  ) {
    var section = 0
    switch controller {
    case artistsFetchedResultsController.fetchResultsController:
      section = LibraryElement.Artist.rawValue - 0
    case albumsFetchedResultsController.fetchResultsController:
      section = LibraryElement.Album.rawValue - 0
    case songsFetchedResultsController.fetchResultsController:
      section = LibraryElement.Song.rawValue - 0
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
