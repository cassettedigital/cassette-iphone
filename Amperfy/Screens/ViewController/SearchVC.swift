//
//  SearchVC.swift
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

// MARK: - SearchSection

/// The Search table's sections, top to bottom. phone-taste (approved mock, Screens.tsx
/// SearchResultsScreen): one top result to play at once, then SONGS, ALBUMS, ARTISTS and
/// PLAYLISTS. Recently Searched shows only before anyone types. STATIONS (2026-10-29, Q17 in
/// docs/CASSETTE_APP_AUDIT.md): the radio dial's stations, as the Mac's search finds them.
public enum SearchSection: Int, CaseIterable {
  case History
  case Top
  case Song
  case Album
  case Artist
  case Playlist
  case Station
  /// Cassette's catalog: what isn't on this phone (the founder, 2026-10-31, Q17).
  case Catalog

  /// The section's shout heading (none for the top card).
  var shout: String {
    switch self {
    case .History: return "RECENT"
    case .Top: return ""
    case .Song: return "SONGS"
    case .Album: return "ALBUMS"
    case .Artist: return "ARTISTS"
    case .Playlist: return "PLAYLISTS"
    case .Station: return "STATIONS"
    case .Catalog: return "ON CASSETTE"
    }
  }

  /// The heading's italic answer, where it has one.
  var answer: String? {
    self == .Catalog ? "not in your library" : nil
  }
}

// MARK: - SearchRow

/// One row of the Search table. Song, playlist and history rows are entity rows; the top
/// card and the two shelves are rows of their own, so a swipe or a long-press is routed by
/// what the row is and never lands on an album or an artist by position.
enum SearchRow: Hashable, Sendable {
  case top(NSManagedObjectID)
  case entity(NSManagedObjectID)
  case albumShelf
  case artistShelf
  /// A station on the radio dial, by its record's id (RadioDial).
  case station(String)
  /// An artist, album or song from Cassette's catalog, by `CatalogHit.id`.
  case catalog(String)
}

// MARK: - SearchDiffableDataSource

final class SearchDiffableDataSource: UITableViewDiffableDataSource<Int, SearchRow> {
  weak var searchVC: SearchVC?

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    searchVC?.headerShout(for: section)
  }

  /// Only entity rows swipe: song, playlist and history rows keep their actions; the top
  /// card and the shelves have none.
  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    if case .entity = itemIdentifier(for: indexPath) { return true }
    return false
  }
}

// MARK: - SearchTopPick

/// The top result as found in the background context: an artist whose name starts with
/// the query, else the first album. Sendable, resolved on the main context.
struct SearchTopPick: Sendable {
  let isArtist: Bool
  let objectID: NSManagedObjectID
  /// Albums whose cover can light the card, best first (for an album, the album itself).
  let coverAlbumIDs: [NSManagedObjectID]
}

// MARK: - SearchOwnedIDs

/// The ids of what is on this phone (DeviceOwnership), for filtering search history.
struct SearchOwnedIDs: Sendable {
  let songs: Set<String>
  let albums: Set<String>
  let artists: Set<String>
}

// MARK: - SearchTopResult

/// The top result on the main context.
struct SearchTopResult {
  enum Kind {
    case artist(Artist)
    case album(Album)
  }

  let kind: Kind
  /// The album whose cover lights the card, and stands in for a missing artist photo.
  let coverAlbum: Album?
  /// An artist with their own photo on disk shows it in a circle.
  let showsPhoto: Bool

  var container: PlayableContainable {
    switch kind {
    case let .artist(artist): return artist
    case let .album(album): return album
    }
  }

  var objectID: NSManagedObjectID {
    switch kind {
    case let .artist(artist): return artist.managedObject.objectID
    case let .album(album): return album.managedObject.objectID
    }
  }
}

// MARK: - SearchArtistTile

/// One circle on the ARTISTS shelf, on the main context.
struct SearchArtistTile {
  let artist: Artist
  /// The artist's own photo is on disk (`hasOwnPhotoOnDisk`), so the circle shows it.
  let showsPhoto: Bool
  /// Otherwise one of their records on the phone stands in, as the mock draws; with none,
  /// the generated artist placeholder (never the artist's shared artwork, which can be
  /// someone else's face).
  let coverAlbum: Album?
}

// MARK: - SearchVC

class SearchVC: BasicTableViewController {
  override var sceneTitle: String { "Search" }

  private var diffableDataSource: SearchDiffableDataSource?
  fileprivate var searchHistory: [SearchHistoryItem] = []
  fileprivate var artists: [SearchArtistTile] = []
  fileprivate var albums: [Album] = []
  fileprivate var playlists: [Playlist] = []
  fileprivate var songs: [Song] = []
  /// The dial's stations that match, the best few (the radio's own search goes through all of them).
  fileprivate var stations: [RadioRow] = []
  /// Cassette's catalog matches that aren't on this phone, read from the site after the
  /// phone's own pass (I-M9).
  fileprivate var catalog: [CatalogHit] = []
  private var catalogTask: Task<(), Never>?
  private var topResult: SearchTopResult?
  /// The query the shown results were found for (the top card lights its letters).
  private var currentQuery = ""
  /// What is on this phone, for the history filter; nil until first read.
  private var ownedIDs: SearchOwnedIDs?
  /// Plays per song and album over the last 60 days, read once per search (cleared when
  /// the field empties).
  private var playCounts: SearchMatcher.PlayCounts?
  /// What the GENRES grid shows now, so an unchanged summary does not rebuild it.
  private var genreSignature: [String]?
  /// The keyboard shortcut activated search; focus the field once it is presented.
  private var focusFieldWhenPresented = false

  private var optionsButton: UIBarButtonItem = .createOptionsBarButton()
  private var isSearchActive = false
  // cassette (UX review 2026-10-20): starting points shown before anyone types.
  private lazy var startView = makeStartView()
  /// A grouped table adds a gap above its first section when it has no header view; this
  /// near-zero header keeps the top card 8pt under the bar.
  private lazy var resultsHeaderSpacer = UIView(frame: CGRect(
    x: 0,
    y: 0,
    width: 0,
    height: CGFloat.leastNormalMagnitude
  ))
  private var accountObjectId: NSManagedObjectID?
  private let account: Account
  /// How many stations Search shows; the radio's own search lists every match.
  private static let stationLimit = 5

  init(account: Account) {
    self.account = account
    super.init(style: .grouped)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func createDiffableDataSource() -> SearchDiffableDataSource {
    let source =
      SearchDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
        guard let self else { return UITableViewCell() }
        return self.cell(for: row, at: indexPath, in: tableView)
      }
    source.searchVC = self
    return source
  }

  func updateDataSource(animated: Bool) {
    guard let dataSource = diffableDataSource else { return }
    var snapshot = NSDiffableDataSourceSnapshot<Int, SearchRow>()
    snapshot.appendSections(SearchSection.allCases.map(\.rawValue))
    snapshot.appendItems(
      searchHistory.map { .entity($0.managedObject.objectID) },
      toSection: SearchSection.History.rawValue
    )
    // The top card and the shelves keep one identity while what they show changes, so
    // they are rebuilt on every pass.
    var rebuilt = [SearchRow]()
    if let topResult {
      let row = SearchRow.top(topResult.objectID)
      snapshot.appendItems([row], toSection: SearchSection.Top.rawValue)
      rebuilt.append(row)
    }
    snapshot.appendItems(
      songs.map { .entity($0.managedObject.objectID) },
      toSection: SearchSection.Song.rawValue
    )
    if !albums.isEmpty {
      snapshot.appendItems([.albumShelf], toSection: SearchSection.Album.rawValue)
      rebuilt.append(.albumShelf)
    }
    if !artists.isEmpty {
      snapshot.appendItems([.artistShelf], toSection: SearchSection.Artist.rawValue)
      rebuilt.append(.artistShelf)
    }
    snapshot.appendItems(
      playlists.map { .entity($0.managedObject.objectID) },
      toSection: SearchSection.Playlist.rawValue
    )
    snapshot.appendItems(
      stations.map { .station($0.radio.id) },
      toSection: SearchSection.Station.rawValue
    )
    snapshot.appendItems(catalog.map { .catalog($0.id) }, toSection: SearchSection.Catalog.rawValue)
    let previous = dataSource.snapshot()
    let reloads = rebuilt.filter { previous.indexOfItem($0) != nil }
    if !reloads.isEmpty {
      snapshot.reloadItems(reloads)
    }
    // A section's heading is asked for only when the section itself reloads; applying new
    // items alone left the headings of sections that had just emptied in place, stacked on
    // top of each other over "No results" (BUG-748). Reload every section whose heading comes
    // or goes.
    let headed = Set(SearchSection.allCases.filter { headerHeight(for: $0) > 0 }.map(\.rawValue))
    let changed = headed.symmetricDifference(headedSections)
    headedSections = headed
    if !changed.isEmpty {
      snapshot.reloadSections(changed.sorted())
    }
    dataSource.apply(snapshot, animatingDifferences: animated)
  }

  /// The sections whose heading showed on the last pass.
  private var headedSections = Set<Int>()

  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.register(nibName: PlaylistTableCell.typeName)
    tableView.register(nibName: GenericTableCell.typeName)
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.register(
      SearchTopResultCell.self,
      forCellReuseIdentifier: SearchTopResultCell.reuseIdentifier
    )
    tableView.register(RadioStationCell.self, forCellReuseIdentifier: RadioStationCell.reuseId)
    tableView.register(CatalogHitCell.self, forCellReuseIdentifier: CatalogHitCell.reuseIdentifier)
    tableView.register(
      AlbumCarouselTableCell.self,
      forCellReuseIdentifier: AlbumCarouselTableCell.reuseIdentifier
    )
    tableView.register(
      SearchArtistShelfCell.self,
      forCellReuseIdentifier: SearchArtistShelfCell.reuseIdentifier
    )

    /// Store the data source in an instance property to make sure it's retained.
    diffableDataSource = createDiffableDataSource()
    /// Assign the data source to your collection view.
    tableView.dataSource = diffableDataSource

    accountObjectId = account.managedObject.objectID
    reloadHistory()
    updateDataSource(animated: false)
    // cassette (search fix): bind the search controller to THIS view controller's
    // own navigationItem EARLY (viewDidLoad, before the tab activates search), and
    // put `searchBarPlacementAllowsExternalIntegration` on the SAME navigationItem
    // that holds the searchController. iOS 26's UISearchTab hoists the search bar from
    // the VC's navigationItem and routes typing to its searchResultsUpdater.
    // Previously the flag was set on the NAVIGATION CONTROLLER's navigationItem (which
    // has no searchController) while the searchController itself was wired only later
    // in viewIsAppearing, so the tab's search field was never bound to
    // `updateSearchResults` and typing did nothing. configureSearchController
    // (viewIsAppearing) still refreshes the scope titles / placeholder on top of this.
    navigationItem.searchController = searchController
    searchController.searchResultsUpdater = self
    navigationItem.searchBarPlacementAllowsExternalIntegration = true
    applySearchTitleAppearance()

    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    // The table is grouped: without this the 28pt above each shout heading doubles.
    tableView.sectionHeaderTopPadding = 0
    // The founder's no-separators rule (2026-10-13); Search used to force lines back on.
    tableView.separatorStyle = .none
    tableView.backgroundColor = .backgroundColor
    tableView.tableHeaderView = startView

    containableAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      switch resolvedRow(at: indexPath) {
      case let .history(item): return item.searchedPlayableContainable
      case let .song(song): return song
      case let .playlist(playlist): return playlist
      case .top, .albumShelf, .artistShelf, .station, .catalog, .none: return nil
      }
    }
    playContextAtIndexPathCallback = { [weak self] indexPath in
      guard let self else { return nil }
      switch resolvedRow(at: indexPath) {
      case let .history(item):
        guard let container = item.searchedPlayableContainable else { return nil }
        return Self.onPhonePlayContext(container)
      case let .song(song):
        return PlayContext(containable: song)
      case let .playlist(playlist):
        return Self.onPhonePlayContext(playlist)
      case .top, .albumShelf, .artistShelf, .station, .catalog, .none:
        return nil
      }
    }
    swipeCallback = { [weak self] indexPath, completionHandler in
      guard let self else { completionHandler(nil); return }
      determSwipeActionContext(at: indexPath) { actionContext in
        completionHandler(actionContext)
      }
    }
    updateContentUnavailable()
    refreshOptionsButton()
    // phone-taste: no account avatar on Search (the approved start page is a bare
    // title). The avatar and its profile menu stay on Home and Library.
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    appDelegate.userStatistics.visited(.search)
    // cassette: the All/Cached scope is gated to Server Mode. In the default
    // on-device experience everything is already on the phone, so "All" already
    // means "Downloaded" and the toggle is a no-op, so it is hidden (nil scope titles).
    // In Server Mode it returns, with "Cached" relabeled to "Downloaded".
    let scopeButtonTitles: [String]? = CassetteLibraryFilterProvider.shared.isOnDeviceOnly
      ? nil
      : ["All", "Downloaded"]
    configureSearchController(
      placeholder: "Search your music",
      scopeButtonTitles: scopeButtonTitles
    )
    refreshOwnedIDs()
    refreshGenres()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The start page's height depends on the genre rows, not on Auto Layout.
    if !isSearchActive, startView.frame.height != startView.preferredHeight {
      relayoutStartView()
    }
  }

  /// The keyboard shortcut and Siri "search" (TabBarVC.displaySearch). Activates the search
  /// controller if it is not already active, then focuses the field: on the next turn of
  /// the main queue and again once the field is presented, since focusing a field that is
  /// not active yet can leave the start page up with no keyboard.
  public func activateSearchBar() {
    guard isViewLoaded else { return }
    if searchController.isActive {
      searchController.searchBar.becomeFirstResponder()
      return
    }
    focusFieldWhenPresented = true
    searchController.isActive = true
    DispatchQueue.main.async { [weak self] in
      self?.searchController.searchBar.becomeFirstResponder()
    }
  }

  @objc
  func didPresentSearchController(_ searchController: UISearchController) {
    guard focusFieldWhenPresented else { return }
    focusFieldWhenPresented = false
    searchController.searchBar.becomeFirstResponder()
  }

  override func configureSearchController(
    placeholder: String?,
    scopeButtonTitles: [String]? = nil
  ) {
    super.configureSearchController(
      placeholder: placeholder,
      scopeButtonTitles: scopeButtonTitles
    )

    // The options button (Clear Search History) shows only while there is history.
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu(children: [
      UIAction(title: "Clear Search History", image: .clear, handler: { [weak self] _ in
        guard let self else { return }
        appDelegate.storage.main.library.deleteSearchHistory()
        appDelegate.storage.main.library.saveContext()
        searchHistory = []
        updateDataSource(animated: true)
        updateContentUnavailable()
        refreshOptionsButton()
      }),
    ])
    refreshOptionsButton()
  }

  private func refreshOptionsButton() {
    navigationItem.rightBarButtonItem = searchHistory.isEmpty ? nil : optionsButton
  }

  /// phone-taste: the "Search" large title in Barlow ExtraBold 38 on this screen only. The
  /// rest of the bar is the global one (CassetteTheme.applyGlobalAppearance) attribute for
  /// attribute, so the bar never flashes a different style; Library and Genres keep the
  /// global large title.
  private func applySearchTitleAppearance() {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = .cassette(.surfaceBase)
    appearance.shadowColor = .cassette(.hairline)
    appearance.titleTextAttributes = [
      .font: UIFont.cassette(.navTitle),
      .foregroundColor: UIColor.cassette(.textPrimary),
    ]
    appearance.largeTitleTextAttributes = [
      .font: UIFont.cassetteDisplay(size: 38, weight: .extraBold),
      .foregroundColor: UIColor.cassette(.textPrimary),
    ]
    let barButton = UIBarButtonItemAppearance()
    barButton.normal.titleTextAttributes = [
      .foregroundColor: UIColor.cassette(.textSecondary),
      .font: UIFont.cassette(.rowTitle),
    ]
    appearance.buttonAppearance = barButton
    appearance.backButtonAppearance = barButton
    navigationItem.standardAppearance = appearance
    navigationItem.scrollEdgeAppearance = appearance.copy()
    navigationItem.compactAppearance = appearance.copy()
  }

  func headerShout(for section: Int) -> String? {
    guard let section = SearchSection(rawValue: section), headerHeight(for: section) > 0
    else { return nil }
    return section.shout
  }

  // MARK: - Rows

  /// A row with the entity behind it.
  private enum ResolvedRow {
    case history(SearchHistoryItem)
    case song(Song)
    case playlist(Playlist)
    case top(SearchTopResult)
    case albumShelf
    case artistShelf
    case station(RadioRow)
    case catalog(CatalogHit)
  }

  private func resolvedRow(at indexPath: IndexPath) -> ResolvedRow? {
    guard let row = diffableDataSource?.itemIdentifier(for: indexPath) else { return nil }
    return resolve(row, at: indexPath)
  }

  /// The entity behind `row`, which sits at `indexPath` (entity rows are found by their
  /// section's list).
  private func resolve(_ row: SearchRow, at indexPath: IndexPath) -> ResolvedRow? {
    switch row {
    case .top:
      return topResult.map { .top($0) }
    case .albumShelf:
      return .albumShelf
    case .artistShelf:
      return .artistShelf
    case let .station(id):
      return stations.first { $0.radio.id == id }.map { .station($0) }
    case let .catalog(id):
      return catalog.first { $0.id == id }.map { .catalog($0) }
    case let .entity(objectID):
      switch SearchSection(rawValue: indexPath.section) {
      case .History:
        return Self.entity(objectID, at: indexPath.row, in: searchHistory) {
          $0.managedObject.objectID
        }.map { .history($0) }
      case .Song:
        return Self.entity(objectID, at: indexPath.row, in: songs) {
          $0.managedObject.objectID
        }.map { .song($0) }
      case .Playlist:
        return Self.entity(objectID, at: indexPath.row, in: playlists) {
          $0.managedObject.objectID
        }.map { .playlist($0) }
      default:
        return nil
      }
    }
  }

  /// The element at `index` when it is `objectID`, else the one that is (the arrays and
  /// the snapshot change together, so the first test almost always holds).
  private static func entity<T>(
    _ objectID: NSManagedObjectID,
    at index: Int,
    in list: [T],
    id: (T) -> NSManagedObjectID
  )
    -> T? {
    if let item = list.element(at: index), id(item) == objectID {
      return item
    }
    return list.first { id($0) == objectID }
  }

  /// A play context holding only what this phone can play (OneTapPlay's rule), so a
  /// long-press or swipe Play, and the swipe queue actions (through OnPhoneContainable),
  /// never queue music that is not here. The long-press menu's queue and Add to Playlist
  /// actions apply the same rule themselves (EntityPreviewActionBuilder).
  private static func onPhonePlayContext(_ containable: PlayableContainable) -> PlayContext {
    if containable is Song { return PlayContext(containable: containable) }
    return PlayContext(
      containable: containable,
      index: 0,
      playables: OneTapPlay.playables(of: containable)
    )
  }

  func determSwipeActionContext(
    at indexPath: IndexPath,
    completionHandler: @escaping (_ actionContext: SwipeActionContext?) -> ()
  ) {
    switch resolvedRow(at: indexPath) {
    case let .history(history):
      guard let container = history.searchedPlayableContainable
      else { completionHandler(nil); return }
      if container is Song {
        completionHandler(SwipeActionContext(containable: container))
        return
      }
      Task { @MainActor in
        do {
          try await container.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          // cassette Patch 040: swipe-prefetch background sync.
          self.appDelegate.eventLogger.report(
            topic: "History Sync",
            error: error,
            isBackground: true
          )
        }
        // The queue swipes read the context's container, so it is the container as
        // seen through the phone (only its songs that are here).
        completionHandler(SwipeActionContext(
          containable: OnPhoneContainable(container),
          playContext: Self.onPhonePlayContext(container)
        ))
      }
    case let .playlist(playlist):
      Task { @MainActor in
        do {
          try await playlist.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(
            topic: "Playlist Sync",
            error: error,
            isBackground: true
          )
        }
        completionHandler(SwipeActionContext(
          containable: OnPhoneContainable(playlist),
          playContext: Self.onPhonePlayContext(playlist)
        ))
      }
    case let .song(song):
      completionHandler(SwipeActionContext(containable: song))
    case .top, .albumShelf, .artistShelf, .station, .catalog, .none:
      completionHandler(nil)
    }
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell) else { return nil }
    switch resolvedRow(at: indexPath) {
    case let .song(song):
      return PlayContext(containable: song)
    case let .history(history):
      guard let song = history.searchedPlayableContainable as? Song else { return nil }
      return PlayContext(containable: song)
    default:
      return nil
    }
  }

  // MARK: - Table view data source

  private func cell(
    for row: SearchRow,
    at indexPath: IndexPath,
    in tableView: UITableView
  )
    -> UITableViewCell {
    switch row {
    case .top:
      let cell = tableView.dequeueReusableCell(
        withIdentifier: SearchTopResultCell.reuseIdentifier,
        for: indexPath
      ) as! SearchTopResultCell
      if let topResult {
        let settings = appDelegate.storage.settings.accounts.getSetting(account.info).read
        cell.configure(
          top: topResult,
          query: currentQuery,
          theme: settings.themePreference,
          artworkSetting: settings.artworkDisplayPreference
        )
        let container = topResult.container
        // Plays only what is on this phone (never PlayContext(containable:) directly).
        cell.onPlay = { _ = OneTapPlay.play(container) }
      }
      return cell
    case .albumShelf:
      let cell = tableView.dequeueReusableCell(
        withIdentifier: AlbumCarouselTableCell.reuseIdentifier,
        for: indexPath
      ) as! AlbumCarouselTableCell
      cell.configure(
        albums: albums,
        onSelect: { [weak self] album in self?.open(album) },
        onPlay: { album in _ = OneTapPlay.play(album) },
        style: .mock
      )
      return cell
    case .artistShelf:
      let cell = tableView.dequeueReusableCell(
        withIdentifier: SearchArtistShelfCell.reuseIdentifier,
        for: indexPath
      ) as! SearchArtistShelfCell
      cell.configure(
        artists: artists,
        theme: appDelegate.storage.settings.accounts.getSetting(account.info).read.themePreference
      ) { [weak self] artist in self?.open(artist) }
      return cell
    case let .station(id):
      let cell = tableView.dequeueReusableCell(
        withIdentifier: RadioStationCell.reuseId,
        for: indexPath
      ) as! RadioStationCell
      guard let row = stations.first(where: { $0.radio.id == id }) else { return cell }
      let current = appDelegate.player.isPlaying ? appDelegate.player.currentlyPlaying as? Radio : nil
      cell.configure(row: row, playing: current?.id == row.radio.id)
      cell.onPlayTapped = { [weak self] in self?.play(row.radio) }
      return cell
    case let .catalog(id):
      let cell = tableView.dequeueReusableCell(
        withIdentifier: CatalogHitCell.reuseIdentifier,
        for: indexPath
      ) as! CatalogHitCell
      if let hit = catalog.first(where: { $0.id == id }) { cell.configure(hit) }
      return cell
    case .entity:
      switch resolve(row, at: indexPath) {
      case let .history(history):
        guard let container = history.searchedPlayableContainable else { return UITableViewCell() }
        if let playlist = container as? Playlist {
          let cell: PlaylistTableCell = dequeueCell(for: tableView, at: indexPath)
          cell.display(playlist: playlist, rootView: self)
          return cell
        } else if let song = container as? Song {
          let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
          cell.display(playable: song, playContextCb: convertCellViewToPlayContext, rootView: self)
          return cell
        } else {
          let cell: GenericTableCell = dequeueCell(for: tableView, at: indexPath)
          cell.display(container: container, rootView: self)
          return cell
        }
      case let .song(song):
        let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
        // "artist · album" under the title, so two songs of one name tell apart; the
        // app's 48pt art and 18/13 type stay. The 20pt gutter lines the rows up with
        // the SONGS heading and the shelves (the mock's page gutter).
        let subtitle = [song.creatorName, song.album?.name ?? ""]
          .filter { !$0.isEmpty }
          .joined(separator: " \(CommonString.oneMiddleDot) ")
        cell.display(
          playable: song,
          playContextCb: convertCellViewToPlayContext,
          rootView: self,
          options: PlayableCellOptions(
            horizontalMargin: CassetteHeading.sideInset,
            subtitleOverride: subtitle.isEmpty ? nil : subtitle
          )
        )
        return cell
      case let .playlist(playlist):
        let cell: PlaylistTableCell = dequeueCell(for: tableView, at: indexPath)
        cell.display(playlist: playlist, rootView: self)
        return cell
      default:
        return UITableViewCell()
      }
    }
  }

  private func headerHeight(for section: SearchSection) -> CGFloat {
    let shows: Bool
    switch section {
    case .History: shows = !isSearchActive && !searchHistory.isEmpty
    case .Top: shows = false
    case .Song: shows = isSearchActive && !songs.isEmpty
    case .Album: shows = isSearchActive && !albums.isEmpty
    case .Artist: shows = isSearchActive && !artists.isEmpty
    case .Playlist: shows = isSearchActive && !playlists.isEmpty
    case .Station: shows = isSearchActive && !stations.isEmpty
    case .Catalog: shows = isSearchActive && !catalog.isEmpty
    }
    return shows ? CassetteHeading.tableHeaderHeight : 0
  }

  /// A hidden heading is a hair, not 0: a grouped table can read 0 as "the default
  /// height", which would open gaps above the top card and between the shelves.
  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    guard let section = SearchSection(rawValue: section) else { return .leastNormalMagnitude }
    let height = headerHeight(for: section)
    return height > 0 ? height : .leastNormalMagnitude
  }

  /// The shout heading (SONGS, ALBUMS, ARTISTS, PLAYLISTS, RECENT): Barlow ExtraBold 26,
  /// 28pt above and 12pt below, in the page gutter. A plain view, so the base class's
  /// small-caps restyle of header views leaves it alone.
  override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    guard let section = SearchSection(rawValue: section), headerHeight(for: section) > 0
    else { return nil }
    return CassetteHeading.makeTableHeaderView(
      shout: section.shout,
      answer: section.answer,
      answerColor: .cassette(.textSecondary)
    )
  }

  override func tableView(
    _ tableView: UITableView,
    heightForFooterInSection section: Int
  )
    -> CGFloat {
    .leastNormalMagnitude
  }

  override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
    nil
  }

  override func tableView(
    _ tableView: UITableView,
    heightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch resolvedRow(at: indexPath) {
    case let .history(history):
      guard let container = history.searchedPlayableContainable else { return 0.0 }
      if container is Playlist {
        return PlaylistTableCell.rowHeight
      } else if container is Song {
        return PlayableTableCell.rowHeight
      } else {
        return GenericTableCell.rowHeight
      }
    case .top:
      return SearchTopResultCell.rowHeight
    case .song:
      return PlayableTableCell.rowHeight
    case .albumShelf:
      return AlbumShelfView.preferredHeight(for: .mock)
    case .artistShelf:
      return SearchArtistShelfCell.rowHeight
    case .playlist:
      return PlaylistTableCell.rowHeight
    case .station:
      return UITableView.automaticDimension
    case .catalog:
      return CatalogHitCell.rowHeight
    case .none:
      return 0.0
    }
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    switch resolvedRow(at: indexPath) {
    case let .history(history):
      guard let container = history.searchedPlayableContainable else { break }
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: container)
      if !(container is Song) {
        EntityPreviewActionBuilder(container: container, on: self).performPreviewTransition()
      }
      appDelegate.storage.main.library.saveContext()
    case let .playlist(playlist):
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: playlist)
      appDelegate.storage.main.library.saveContext()
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPlaylistDetail(account: account, playlist: playlist),
        animated: true
      )
    case let .top(top):
      switch top.kind {
      case let .artist(artist): open(artist)
      case let .album(album): open(album)
      }
    case let .song(song):
      let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: song)
      appDelegate.storage.main.library.saveContext()
    case let .station(row):
      // A station opens its page, as on the dial; one the registry doesn't know plays.
      if let info = row.info {
        navigationController?.pushViewController(
          RadioStationVC(account: account, station: info),
          animated: true
        )
      } else {
        play(row.radio)
      }
    case let .catalog(hit):
      open(hit)
    case .albumShelf, .artistShelf, .none:
      break
    }
    tableView.deselectRow(at: indexPath, animated: true)
  }

  /// A station keeps the dial's own long-press menu (Play, Save, its places).
  override func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  )
    -> UIContextMenuConfiguration? {
    guard case let .station(row)? = resolvedRow(at: indexPath) else {
      return super.tableView(tableView, contextMenuConfigurationForRowAt: indexPath, point: point)
    }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      MainActor.assumeIsolated { RadioDial.menu(for: row) { self?.play(row.radio) } }
    }
  }

  /// A station, then the stations like it, as its page plays it.
  private func play(_ radio: Radio) {
    let dial = RadioDial.radios(for: account, storage: appDelegate.storage)
    appDelegate.player.play(context: RadioDial.playContext(for: radio, in: dial))
    updateDataSource(animated: false)
  }

  // MARK: Cassette's catalog

  /// Asks the site's search for what isn't on this phone, a beat after typing stops, and
  /// shows it under the phone's own results (the founder, 2026-10-31: "searching for the
  /// beatles should produce something, but it should be clear the results aren't from their
  /// library"). Anything already in the phone's results for this query is left out.
  private func searchCatalog(_ query: String) {
    catalogTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2 else {
      if !catalog.isEmpty {
        catalog = []
        updateDataSource(animated: false)
        updateContentUnavailable()
      }
      return
    }
    catalogTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      let hits = await CatalogHit.search(trimmed)
      guard let self, !Task.isCancelled, query == searchController.searchBar.text else { return }
      catalog = hits.filter { !isOnPhone($0) }
      updateDataSource(animated: false)
      updateContentUnavailable()
    }
  }

  /// Already among the phone's own results for this query (by name; the catalog and the
  /// phone share no ids).
  private func isOnPhone(_ hit: CatalogHit) -> Bool {
    let same = { (a: String, b: String) in a.caseInsensitiveCompare(b) == .orderedSame }
    switch hit.kind {
    case .artist:
      return artists.contains { same($0.artist.name, hit.title) } ||
        appDelegate.storage.main.library.getArtistByExactName(for: account, name: hit.title) != nil
    case .album:
      return albums.contains { album in same(album.name, hit.title) && same(album.artist?.name ?? "", hit.artistName) }
    case .song:
      return songs.contains { same($0.title, hit.title) && same($0.creatorName, hit.artistName) }
    }
  }

  /// An artist's page, or the album (a song opens its album), as the site draws it inside the
  /// app; an album the person owns opens as their own (RecordOpener).
  private func open(_ hit: CatalogHit) {
    let push: (UIViewController) -> () = { [weak self] vc in
      self?.navigationController?.pushViewController(vc, animated: true)
    }
    switch hit.kind {
    case .artist:
      guard let slug = hit.artistSlug else { return }
      let path = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
      push(CassetteWebPageVC(path: "/artist/\(path)", title: hit.title, placeholder: nil))
    case .album, .song:
      guard let slug = hit.albumSlug else { return }
      RecordOpener.open(
        albumSlug: slug,
        title: hit.kind == .album ? hit.title : hit.albumTitle,
        placeholder: hit.imageUrl.flatMap {
          RadioArtLoader.shared.cachedImage(for: $0, maxPixel: RadioArtLoader.rowPixel)
        },
        account: account,
        show: push
      )
    }
  }

  /// Opens an album page and records it in the search history.
  private func open(_ album: Album) {
    let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: album)
    appDelegate.storage.main.library.saveContext()
    navigationController?.pushViewController(
      AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
      animated: true
    )
  }

  /// Opens an artist page and records it in the search history.
  private func open(_ artist: Artist) {
    let _ = appDelegate.storage.main.library.createOrUpdateSearchHistory(container: artist)
    appDelegate.storage.main.library.saveContext()
    navigationController?.pushViewController(
      AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist),
      animated: true
    )
  }

  // MARK: - Searching

  struct SearchResultObjectContainer: Sendable {
    var artistsIDs = [NSManagedObjectID]()
    var albumsIDs = [NSManagedObjectID]()
    var playlistsIDs = [NSManagedObjectID]()
    var songsIDs = [NSManagedObjectID]()
    var top: SearchTopPick?
    /// Per shelf artist, the records that can stand in for a missing photo, best first.
    var artistCoverIDs = [NSManagedObjectID: [NSManagedObjectID]]()
    var owned: SearchOwnedIDs?
    var playCounts: SearchMatcher.PlayCounts?
  }

  override func updateSearchResults(for searchController: UISearchController) {
    guard let searchText = searchController.searchBar.text, let accountObjectId else { return }
    // Cassette fork, Layer 3 Phase 3.2 (library filtering). In on-device-only mode
    // global search stays local and is constrained to owned items; the remote Subsonic
    // searches only run in Server Mode.
    let isOnDeviceOnly = CassetteLibraryFilterProvider.shared.isOnDeviceOnly
    // cassette: reflect the "searching" state SYNCHRONOUSLY. Result population and
    // the final isSearchActive=true happen inside the async pass below; if that
    // pass races (its `searchText == searchBar.text` guard drops a late completion)
    // or throws, isSearchActive would stay false and the start page would remain up
    // even though a query is typed.
    if !searchText.isEmpty {
      isSearchActive = true
    }
    // cassette (search fix, the real one): in on-device mode the scope bar is
    // hidden (scopeButtonTitles == nil), so `selectedScopeButtonIndex` is -1, NOT
    // 0. Treat anything that isn't the Downloaded scope (index 1) as the default
    // local search (0 OR -1).
    if !searchText.isEmpty, searchController.searchBar.selectedScopeButtonIndex != 1 {
      if !isOnDeviceOnly {
        Task { @MainActor in do {
          try await self.appDelegate.getMeta(self.account.info).librarySyncer
            .searchArtists(searchText: searchText)
        } catch {
          self.appDelegate.eventLogger.report(topic: "Artists Search", error: error)
        }}

        Task { @MainActor in do {
          try await self.appDelegate.getMeta(self.account.info).librarySyncer
            .searchAlbums(searchText: searchText)
        } catch {
          self.appDelegate.eventLogger.report(topic: "Albums Search", error: error)
        }}

        Task { @MainActor in do {
          try await self.appDelegate.getMeta(self.account.info).librarySyncer
            .searchSongs(searchText: searchText)
        } catch {
          self.appDelegate.eventLogger.report(topic: "Songs Search", error: error)
        }}
      }

      // The play log is read once per search: the first keystroke reads it, the rest
      // reuse it until the field empties.
      let knownCounts = playCounts
      let since = Date().addingTimeInterval(-Double(ListeningShelves.lookbackDays) * 86400)
      Task { @MainActor in do {
        let searchResult = try await appDelegate.storage.async.performAndGet { asyncCompanion in
          SearchMatcher.searchOnPhone(
            library: asyncCompanion.library,
            context: asyncCompanion.context,
            accountObjectId: accountObjectId,
            query: searchText,
            isOnDeviceOnly: isOnDeviceOnly,
            playsSince: since,
            knownCounts: knownCounts
          )
        }
        self.applySearchResult(searchResult, for: searchText, withStations: true)
        self.searchCatalog(searchText)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Local Search", error: error, isBackground: true)
        self.updateContentUnavailable()
      }}
    } else if !searchText.isEmpty, searchController.searchBar.selectedScopeButtonIndex == 1 {
      // Server Mode's Downloaded scope: matching unchanged (each entity's own name).
      Task { @MainActor in do {
        let searchResult = try await appDelegate.storage.async.performAndGet { asyncCompanion in
          let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
          let artists = asyncCompanion.library.searchArtists(
            for: accountAsync,
            searchText: searchText,
            onlyCached: true,
            displayFilter: .all
          )
          let albums = asyncCompanion.library.searchAlbums(
            for: accountAsync,
            searchText: searchText,
            onlyCached: true,
            displayFilter: .all
          )
          let playlists = asyncCompanion.library.searchPlaylists(
            for: accountAsync,
            searchText: searchText,
            playlistSearchCategory: .cached
          )
          let songs = asyncCompanion.library.searchSongs(
            for: accountAsync,
            searchText: searchText,
            onlyCached: true,
            displayFilter: .all
          )

          let rankedArtists = FuzzySearcher.findBestMatch(in: artists, search: searchText)
            .compactMap { $0 as? Artist }
          let rankedAlbums = FuzzySearcher.findBestMatch(in: albums, search: searchText)
            .compactMap { $0 as? Album }
          var result = SearchResultObjectContainer()
          result.artistsIDs = rankedArtists
            .prefix(SearchMatcher.artistLimit)
            .map { $0.managedObject.objectID }
          result.albumsIDs = rankedAlbums
            .prefix(SearchMatcher.albumLimit)
            .map { $0.managedObject.objectID }
          result.playlistsIDs = FuzzySearcher.findBestMatch(in: playlists, search: searchText)
            .prefix(upToAsArray: SearchMatcher.playlistLimit)
            .compactMap { $0 as? Playlist }
            .compactMap { $0.managedObject.objectID }
          result.songsIDs = FuzzySearcher.findBestMatch(in: songs, search: searchText)
            .prefix(upToAsArray: SearchMatcher.songLimit)
            .compactMap { $0 as? Song }
            .compactMap { $0.managedObject.objectID }
          result.top = SearchMatcher.topPick(
            artists: rankedArtists,
            albums: rankedAlbums,
            query: searchText,
            ownedAlbumIds: nil,
            ownedSongIds: nil
          )
          result.artistCoverIDs = SearchMatcher.artistCoverIDs(
            for: rankedArtists.prefix(SearchMatcher.artistLimit),
            shown: rankedAlbums,
            ownedAlbumIds: nil,
            ownedSongIds: nil
          )
          return result
        }
        self.applySearchResult(searchResult, for: searchText, withStations: false)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Local Search", error: error, isBackground: true)
        self.updateContentUnavailable()
      }}
    } else {
      isSearchActive = false
      currentQuery = ""
      playCounts = nil
      reloadHistory()
      artists = []
      albums = []
      playlists = []
      songs = []
      stations = []
      catalogTask?.cancel()
      catalog = []
      topResult = nil
      updateDataSource(animated: false)
      updateContentUnavailable()
      refreshOptionsButton()
    }
  }

  /// Shows a finished search pass, unless the field has moved on since it started. Stations show
  /// beside the music, but not in Downloaded (a station is never on the phone).
  private func applySearchResult(
    _ searchResult: SearchResultObjectContainer,
    for searchText: String,
    withStations: Bool
  ) {
    guard searchText == searchController.searchBar.text else { return }
    let context = appDelegate.storage.main.context
    isSearchActive = true
    currentQuery = searchText
    searchHistory = []
    if let owned = searchResult.owned { ownedIDs = owned }
    if let counts = searchResult.playCounts { playCounts = counts }
    artists = searchResult.artistsIDs
      .compactMap { (try? context.existingObject(with: $0)) as? ArtistMO }
      .map { Artist(managedObject: $0) }
      .map { artist in
        let showsPhoto = artist.hasOwnPhotoOnDisk
        return SearchArtistTile(
          artist: artist,
          showsPhoto: showsPhoto,
          coverAlbum: showsPhoto ? nil :
            firstCoverAlbum(searchResult.artistCoverIDs[artist.managedObject.objectID] ?? [])
        )
      }
    albums = searchResult.albumsIDs
      .compactMap { (try? context.existingObject(with: $0)) as? AlbumMO }
      .map { Album(managedObject: $0) }
    playlists = searchResult.playlistsIDs
      .compactMap { (try? context.existingObject(with: $0)) as? PlaylistMO }
      .map { Playlist(library: appDelegate.storage.main.library, managedObject: $0) }
    songs = searchResult.songsIDs
      .compactMap { (try? context.existingObject(with: $0)) as? SongMO }
      .map { Song(managedObject: $0) }
    stations = withStations ? RadioDial.rows(
      matching: searchText,
      in: RadioDial.radios(for: account, storage: appDelegate.storage),
      limit: Self.stationLimit
    ) : []
    topResult = resolveTop(searchResult.top)
    updateDataSource(animated: false)
    updateContentUnavailable()
    refreshOptionsButton()
  }

  /// The top pick on the main context. The card is lit by the first candidate album with a
  /// cover on disk; an artist shows their own photo only when `hasOwnPhotoOnDisk` (a shared
  /// artwork row can carry someone else's face).
  private func resolveTop(_ pick: SearchTopPick?) -> SearchTopResult? {
    guard let pick else { return nil }
    let context = appDelegate.storage.main.context
    let coverAlbum = firstCoverAlbum(pick.coverAlbumIDs)
    if pick.isArtist {
      guard let artistMO = (try? context.existingObject(with: pick.objectID)) as? ArtistMO
      else { return nil }
      let artist = Artist(managedObject: artistMO)
      return SearchTopResult(
        kind: .artist(artist),
        coverAlbum: coverAlbum,
        showsPhoto: artist.hasOwnPhotoOnDisk
      )
    }
    guard let albumMO = (try? context.existingObject(with: pick.objectID)) as? AlbumMO
    else { return nil }
    let album = Album(managedObject: albumMO)
    return SearchTopResult(kind: .album(album), coverAlbum: coverAlbum ?? album, showsPhoto: false)
  }

  /// The first of `ids` whose cover is on disk, else the first of them (its cover may
  /// still arrive), on the main context.
  private func firstCoverAlbum(_ ids: [NSManagedObjectID]) -> Album? {
    let context = appDelegate.storage.main.context
    let setting = appDelegate.storage.settings.accounts.getSetting(account.info).read
      .artworkDisplayPreference
    let candidates = ids
      .compactMap { (try? context.existingObject(with: $0)) as? AlbumMO }
      .map { Album(managedObject: $0) }
    return candidates.first { album in
      guard let path = album.imagePath(setting: setting) else { return false }
      return FileManager.default.fileExists(atPath: path)
    } ?? candidates.first
  }

  func updateContentUnavailable() {
    // cassette: the starting points replace the old "No search history" page.
    if isSearchActive {
      tableView.tableHeaderView = resultsHeaderSpacer
    } else {
      relayoutStartView()
    }
    if isSearchActive {
      if topResult == nil, artists.isEmpty, albums.isEmpty, playlists.isEmpty, songs.isEmpty,
         stations.isEmpty, catalog.isEmpty {
        // cassette Layer 3 Phase 3.2: in on-device-only mode search is scoped to
        // owned items.
        contentUnavailableConfiguration = CassetteLibraryFilterProvider.shared.isOnDeviceOnly ?
          cassetteOnDeviceNoResultsConfig : noSearchResultsConfig
      } else {
        contentUnavailableConfiguration = nil
      }
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  // MARK: - Start page

  private func makeStartView() -> SearchStartView {
    let account = account
    let push: (UIViewController) -> () = { [weak self] vc in
      self?.navigationController?.pushViewController(vc, animated: true)
    }
    return SearchStartView(starts: [
      .init(title: Self.shuffleAllTitle, icon: .shuffle) { [weak self] in self?.shuffleAll() },
      .init(title: "Albums", icon: .album) {
        push(AppStoryboard.Main.createAlbumsVC(account: account, style: .table, category: .all))
      },
      .init(title: "Playlists", icon: .playlist) {
        push(AppStoryboard.Main.segueToPlaylists(account: account))
      },
      .init(title: "Genres", icon: .genre) {
        push(AppStoryboard.Main.segueToGenres(account: account))
      },
      .init(title: "Radio", icon: .radio) {
        push(AppStoryboard.Main.segueToRadios(account: account))
      },
    ])
  }

  /// Sizes the start page to its content and puts it back as the table header (a table
  /// header only relayouts when it is reassigned).
  private func relayoutStartView() {
    let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
    startView.frame = CGRect(x: 0, y: 0, width: width, height: startView.preferredHeight)
    tableView.tableHeaderView = startView
  }

  /// The GENRES grid: the genres of the music on this phone, biggest first (up to six),
  /// each lit by one of its records. Counted off the main thread; the covers are picked
  /// on the main thread, where a cover can be read.
  private func refreshGenres() {
    Task { @MainActor in
      let summary: [DeviceOwnershipManager.OnPhoneGenre]
      do {
        // This task runs on the main actor, so the storage is read here directly.
        summary = try await self.appDelegate.storage.async.performAndGet { asyncCompanion in
          DeviceOwnershipManager(context: asyncCompanion.context).onPhoneGenreSummary()
        }
      } catch {
        self.appDelegate.eventLogger.report(topic: "Search Genres", error: error, isBackground: true)
        return
      }
      self.applyGenres(summary)
    }
  }

  private func applyGenres(_ summary: [DeviceOwnershipManager.OnPhoneGenre]) {
    let context = appDelegate.storage.main.context
    let setting = appDelegate.storage.settings.accounts.getSetting(account.info).read
      .artworkDisplayPreference
    var tiles = [SearchStartView.GenreTile]()
    var signature = [String]()
    for genreSummary in summary {
      guard let genreID = genreSummary.genreObjectID,
            let genreMO = (try? context.existingObject(with: genreID)) as? GenreMO
      else { continue }
      let genre = Genre(managedObject: genreMO)
      // The first sample record with a cover on disk.
      var cover: UIImage?
      var coverPath: String?
      for albumID in genreSummary.sampleAlbumObjectIDs {
        guard let albumMO = (try? context.existingObject(with: albumID)) as? AlbumMO
        else { continue }
        let album = Album(managedObject: albumMO)
        if let image = LibraryEntityImage.coverImage(
          libraryEntity: album,
          artworkDisplayPreference: setting,
          useCache: true
        ) {
          cover = image
          coverPath = album.imagePath(setting: setting)
          break
        }
      }
      signature.append("\(genreSummary.name)|\(genreSummary.albumCount)|\(coverPath ?? "")")
      tiles.append(SearchStartView.GenreTile(
        name: genreSummary.name,
        albumCount: genreSummary.albumCount,
        cover: cover,
        coverPath: coverPath
      ) { [weak self] in
        self?.openGenre(genre)
      })
    }
    guard signature != genreSignature else { return }
    genreSignature = signature
    startView.setGenres(tiles)
    if !isSearchActive {
      relayoutStartView()
    }
  }

  private func openGenre(_ genre: Genre) {
    navigationController?.pushViewController(
      AppStoryboard.Main.segueToGenreDetail(account: account, genre: genre),
      animated: true
    )
  }

  // MARK: - History

  /// Recently Searched, only what is still on this phone (on the phone; everything in
  /// Server Mode). Shown under GENRES before anyone types.
  private func reloadHistory() {
    let all = appDelegate.storage.main.library.getSearchHistory(for: account)
    guard CassetteLibraryFilterProvider.shared.isOnDeviceOnly else {
      searchHistory = all.filter { $0.searchedPlayableContainable != nil }
      return
    }
    // Until the on-phone sets are read, show none rather than something not here.
    guard let owned = ownedIDs else {
      searchHistory = []
      return
    }
    searchHistory = all.filter { item in
      guard let container = item.searchedPlayableContainable else { return false }
      if let song = container as? Song { return owned.songs.contains(song.id) }
      if let album = container as? Album { return owned.albums.contains(album.id) }
      if let artist = container as? Artist { return owned.artists.contains(artist.id) }
      return true
    }
  }

  /// Reads what is on this phone off the main thread, then refilters the history.
  private func refreshOwnedIDs() {
    guard CassetteLibraryFilterProvider.shared.isOnDeviceOnly else {
      if !isSearchActive {
        reloadHistory()
        updateDataSource(animated: false)
        refreshOptionsButton()
      }
      return
    }
    Task { @MainActor in
      let owned: SearchOwnedIDs
      do {
        owned = try await self.appDelegate.storage.async.performAndGet { asyncCompanion in
          let ownership = DeviceOwnershipManager(context: asyncCompanion.context)
          return SearchOwnedIDs(
            songs: ownership.fetchAllSubsonicTrackIds(),
            albums: ownership.fetchOwnedAlbumIds(),
            artists: ownership.fetchOwnedArtistIds()
          )
        }
      } catch {
        return
      }
      self.ownedIDs = owned
      // Nothing on the phone yet: Shuffle all would do nothing, so it isn't offered.
      self.startView.setStart(Self.shuffleAllTitle, hidden: owned.songs.isEmpty)
      guard !self.isSearchActive else { return }
      self.reloadHistory()
      self.updateDataSource(animated: false)
      self.refreshOptionsButton()
    }
  }

  private static let shuffleAllTitle = "Shuffle all"

  /// Shuffles the music on this phone (OneTapPlay's rule: the whole library in Server Mode,
  /// only cached songs while offline), capped so a big library does not build a queue of
  /// tens of thousands.
  private func shuffleAll() {
    let library: [AbstractPlayable] = appDelegate.storage.main.library.getSongs(for: account)
    let songs = OneTapPlay.playables(library)
    guard !songs.isEmpty else { return }
    let playables: [AbstractPlayable] = Array(songs.shuffled().prefix(500))
    appDelegate.player.playShuffled(context: PlayContext(name: "All music", playables: playables))
  }

  // cassette Layer 3 Phase 3.2: on-device-only search empty state.
  // cassette (BUG-419): copy and type come from the shared factory
  // (UtilitiesExtensions). There is no Server Mode toggle on the phone.
  lazy var cassetteOnDeviceNoResultsConfig: UIContentUnavailableConfiguration =
    .cassetteOnDeviceNoResults

  /// cassette Patch 020: Cassette-flavored empty states. The renderer
  /// for `UIContentUnavailableConfiguration` honors the
  /// `text/secondaryText/imageProperties` overrides we set here, so we
  /// can keep the native iOS 17+ container while swapping in
  /// `cassetteDisplay` typography and theme colors.
  lazy var noSearchResultsConfig: UIContentUnavailableConfiguration = {
    // cassette (BUG-419): type via the shared factory.
    UIContentUnavailableConfiguration.cassetteNoResults()
  }()
}

// MARK: - SearchMatcher

/// Search-local matching and ranking for the Search tab (phone-taste mock, data.ts
/// searchOf). The shared LibraryStorage search predicates stay as they are, because other
/// lists use them. Runs inside a background context's `performAndGet`.
enum SearchMatcher {
  /// Caps per section: five songs so the shelves land on the first screen, eight albums,
  /// six artists, ten playlists.
  static let songLimit = 5
  static let albumLimit = 8
  static let artistLimit = 6
  static let playlistLimit = 10
  /// Rows fetched per match tier before ranking.
  private static let tierFetchLimit = 300
  /// Two months of plays is about a thousand entries for a heavy listener.
  private static let playFetchLimit = 5000

  /// Plays per song id and per album id since a date, from the phone's own play log.
  struct PlayCounts: Sendable {
    var bySong = [String: Int]()
    var byAlbum = [String: Int]()
  }

  /// The default search: songs by title, artist or album; albums by name or artist; artists
  /// and playlists by name. On the phone, only what is on it. Ranked in three steps: the
  /// title (or name) holds the query, then plays over the last 60 days, then the fuzzy
  /// score.
  static func searchOnPhone(
    library: LibraryStorage,
    context: NSManagedObjectContext,
    accountObjectId: NSManagedObjectID,
    query: String,
    isOnDeviceOnly: Bool,
    playsSince: Date,
    knownCounts: PlayCounts?
  )
    -> SearchVC.SearchResultObjectContainer {
    let account = library.getAccount(managedObjectId: accountObjectId)
    var owned: SearchOwnedIDs?
    if isOnDeviceOnly {
      let ownership = DeviceOwnershipManager(context: context)
      owned = SearchOwnedIDs(
        songs: ownership.fetchAllSubsonicTrackIds(),
        albums: ownership.fetchOwnedAlbumIds(),
        artists: ownership.fetchOwnedArtistIds()
      )
    }
    let counts = knownCounts ?? playCounts(library: library, account: account, since: playsSince)

    // Artists: their own name, on the phone, best fuzzy match first (none dropped).
    var artists = library.searchArtists(
      for: account,
      searchText: query,
      onlyCached: false,
      displayFilter: .all
    )
    if let owned {
      artists = artists.filter { owned.artists.contains($0.id) }
    }
    let rankedArtists = rank(artists, query: query) { _ in 0 }

    // Albums: the name holds the query, or the artist's name does.
    let albumBase = library.getSearchAlbumsPredicate(
      for: account,
      searchText: "",
      onlyCached: false,
      displayFilter: .all
    )
    let ownedAlbums = owned.map { NSPredicate(format: "id IN %@", $0.albums) }
    let albumName = NSPredicate(format: "name CONTAINS[cd] %@", query)
    let albumArtist = NSPredicate(format: "artist.name CONTAINS[cd] %@", query)
    let namedAlbums = fetch(
      AlbumMO.fetchRequest() as NSFetchRequest<AlbumMO>,
      [albumBase, ownedAlbums, albumName],
      sortKey: "name",
      context: context
    ).map { Album(managedObject: $0) }
    let byArtistAlbums = fetch(
      AlbumMO.fetchRequest() as NSFetchRequest<AlbumMO>,
      [albumBase, ownedAlbums, albumArtist, NSCompoundPredicate(notPredicateWithSubpredicate: albumName)],
      sortKey: "name",
      context: context
    ).map { Album(managedObject: $0) }
    let albumPlays: (Album) -> Int = { counts.byAlbum[$0.id] ?? 0 }
    let rankedAlbums = rank(namedAlbums, query: query, plays: albumPlays)
      + rank(byArtistAlbums, query: query, plays: albumPlays)

    // Songs: the title holds the query, or the artist's or the album's name does.
    let songBase = library.getSearchSongsPredicate(
      for: account,
      searchText: "",
      onlyCached: false,
      displayFilter: .all
    )
    let ownedSongs = owned.map { NSPredicate(format: "id IN %@", $0.songs) }
    let songTitle = NSPredicate(format: "title CONTAINS[cd] %@", query)
    let songPeople = NSCompoundPredicate(orPredicateWithSubpredicates: [
      NSPredicate(format: "artist.name CONTAINS[cd] %@", query),
      NSPredicate(format: "album.name CONTAINS[cd] %@", query),
    ])
    let titledSongs = fetch(
      SongMO.fetchRequest() as NSFetchRequest<SongMO>,
      [songBase, ownedSongs, songTitle],
      sortKey: "title",
      context: context
    ).map { Song(managedObject: $0) }
    let otherSongs = fetch(
      SongMO.fetchRequest() as NSFetchRequest<SongMO>,
      [songBase, ownedSongs, songPeople, NSCompoundPredicate(notPredicateWithSubpredicate: songTitle)],
      sortKey: "title",
      context: context
    ).map { Song(managedObject: $0) }
    let songPlays: (Song) -> Int = { counts.bySong[$0.id] ?? 0 }
    let rankedSongs = rank(titledSongs, query: query, plays: songPlays)
      + rank(otherSongs, query: query, plays: songPlays)

    // Playlists: their own name (not ownership-scoped), as before.
    let playlists = library.searchPlaylists(
      for: account,
      searchText: query,
      playlistSearchCategory: .all
    )

    var result = SearchVC.SearchResultObjectContainer()
    result.artistsIDs = rankedArtists.prefix(artistLimit).map { $0.managedObject.objectID }
    result.albumsIDs = rankedAlbums.prefix(albumLimit).map { $0.managedObject.objectID }
    result.songsIDs = rankedSongs.prefix(songLimit).map { $0.managedObject.objectID }
    result.playlistsIDs = FuzzySearcher.findBestMatch(in: playlists, search: query)
      .prefix(upToAsArray: playlistLimit)
      .compactMap { $0 as? Playlist }
      .compactMap { $0.managedObject.objectID }
    result.top = topPick(
      artists: rankedArtists,
      albums: rankedAlbums,
      query: query,
      ownedAlbumIds: owned?.albums,
      ownedSongIds: owned?.songs
    )
    result.artistCoverIDs = artistCoverIDs(
      for: rankedArtists.prefix(artistLimit),
      shown: rankedAlbums,
      ownedAlbumIds: owned?.albums,
      ownedSongIds: owned?.songs
    )
    result.owned = owned
    result.playCounts = counts
    return result
  }

  /// The top result: the first artist whose name starts with the query (ignoring case and
  /// accents), else the first album, else none. An artist's card is lit by their records
  /// on the phone (see `coverAlbumIDs`).
  static func topPick(
    artists: [Artist],
    albums: [Album],
    query: String,
    ownedAlbumIds: Set<String>?,
    ownedSongIds: Set<String>?
  )
    -> SearchTopPick? {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return nil }
    if let artist = artists.first(where: {
      $0.name.range(of: needle, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
    }) {
      return SearchTopPick(
        isArtist: true,
        objectID: artist.managedObject.objectID,
        coverAlbumIDs: coverAlbumIDs(
          for: artist,
          shown: albums,
          ownedAlbumIds: ownedAlbumIds,
          ownedSongIds: ownedSongIds
        )
      )
    }
    if let album = albums.first {
      return SearchTopPick(
        isArtist: false,
        objectID: album.managedObject.objectID,
        coverAlbumIDs: [album.managedObject.objectID]
      )
    }
    return nil
  }

  /// How many of an artist's records the main context looks through for a cover on disk.
  private static let coverCandidateLimit = 12

  /// An artist's records on the phone in the artist page's lead-record order
  /// (`Artist.leadAlbum`): their own records (`Artist.isCredited`, among the album results
  /// and their other albums here) newest first; an artist with no record of their own (a
  /// featured artist) gets the records their songs here are on, newest first. The main
  /// context takes the first with a cover on disk, else the first, so the card is lit by
  /// the same record as the artist page it opens. They also stand in for an artist with no
  /// photo of their own, as the mock draws.
  static func coverAlbumIDs(
    for artist: Artist,
    shown albums: [Album],
    ownedAlbumIds: Set<String>?,
    ownedSongIds: Set<String>?
  )
    -> [NSManagedObjectID] {
    var seen = Set<String>()
    let credited = (
      albums.filter { artist.isCredited($0) }
        + artist.albums.filter { ownedAlbumIds?.contains($0.id) ?? true }
    )
    .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    var ordered = Artist.newestFirst(credited)
    if ordered.isEmpty {
      var appearances = [Album]()
      for song in artist.songs.compactMap(\.asSong)
        where ownedSongIds?.contains(song.id) ?? true {
        guard let album = song.album, !album.id.isEmpty,
              seen.insert(album.id).inserted else { continue }
        appearances.append(album)
      }
      ordered = Artist.newestFirst(appearances)
    }
    return ordered.prefix(coverCandidateLimit).map(\.managedObject.objectID)
  }

  /// `coverAlbumIDs` for each artist on the shelf.
  static func artistCoverIDs(
    for artists: ArraySlice<Artist>,
    shown albums: [Album],
    ownedAlbumIds: Set<String>?,
    ownedSongIds: Set<String>?
  )
    -> [NSManagedObjectID: [NSManagedObjectID]] {
    var covers = [NSManagedObjectID: [NSManagedObjectID]]()
    for artist in artists {
      covers[artist.managedObject.objectID] = coverAlbumIDs(
        for: artist,
        shown: albums,
        ownedAlbumIds: ownedAlbumIds,
        ownedSongIds: ownedSongIds
      )
    }
    return covers
  }

  private static func playCounts(library: LibraryStorage, account: Account, since: Date) -> PlayCounts {
    var counts = PlayCounts()
    for entry in library.getScrobbleEntries(for: account, since: since, fetchLimit: playFetchLimit) {
      guard let song = entry.playable?.asSong else { continue }
      counts.bySong[song.id, default: 0] += 1
      if let albumId = song.album?.id, !albumId.isEmpty {
        counts.byAlbum[albumId, default: 0] += 1
      }
    }
    return counts
  }

  private static func fetch<T: NSManagedObject>(
    _ request: NSFetchRequest<T>,
    _ predicates: [NSPredicate?],
    sortKey: String,
    context: NSManagedObjectContext
  )
    -> [T] {
    request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates.compactMap { $0 })
    request.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: true)]
    request.fetchLimit = tierFetchLimit
    request.returnsObjectsAsFaults = false
    return (try? context.fetch(request)) ?? []
  }

  /// Most played first, then the best fuzzy match on the item's own name, then the order
  /// they came in. Nothing is dropped: an artist's song whose title does not match stays.
  private static func rank<T: PlayableContainable>(
    _ items: [T],
    query: String,
    plays: (T) -> Int
  )
    -> [T] {
    guard items.count > 1 else { return items }
    let fuzzy = FuzzySearcher.findBestMatch(in: items.map { $0 as PlayableContainable }, search: query)
    var fuzzyIndex = [ObjectIdentifier: Int]()
    for (index, item) in fuzzy.enumerated() {
      fuzzyIndex[ObjectIdentifier(item as AnyObject)] = index
    }
    return items.enumerated()
      .map { (offset: $0.offset, item: $0.element, plays: plays($0.element)) }
      .sorted { lhs, rhs in
        if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
        let lf = fuzzyIndex[ObjectIdentifier(lhs.item as AnyObject)] ?? Int.max
        let rf = fuzzyIndex[ObjectIdentifier(rhs.item as AnyObject)] ?? Int.max
        if lf != rf { return lf < rf }
        return lhs.offset < rhs.offset
      }
      .map(\.item)
  }
}

// MARK: - SearchHighlight

/// The matched letters, lit (the mock's `Hit`). Used on the top card only tonight: rows
/// and artist names stay plain, since the mock's orange breaks the colour rule and a
/// per-row colour is the founder's call.
enum SearchHighlight {
  /// `text` in `style` (its font, tracking and capitals) with the first occurrence of
  /// `query`, ignoring case and accents, in `hitColor`. No match, no highlight.
  @MainActor
  static func attributed(
    _ text: String,
    query: String,
    style: CassetteTextStyle,
    color: UIColor,
    hitColor: UIColor
  )
    -> NSAttributedString {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty,
          let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
    else {
      return .cassette(text, style, color: color)
    }
    // Each run is cased on its own, so a capital that changes length never shifts the lit
    // letters.
    let result = NSMutableAttributedString()
    result.append(.cassette(String(text[..<range.lowerBound]), style, color: color))
    result.append(.cassette(String(text[range]), style, color: hitColor))
    result.append(.cassette(String(text[range.upperBound...]), style, color: color))
    return result
  }
}

// MARK: - SearchTopResultCell

/// The top result (`.topResult`): one card lit by its record, a cover (or the artist's own
/// photo), the kind, the name with the typed letters in the record's colour, and a play
/// disc that starts only what is on the phone. A tap anywhere else opens the page.
final class SearchTopResultCell: UITableViewCell {
  static let reuseIdentifier = "SearchTopResultCell"
  /// The card's margin (`.topResult` margin 8px 20px) and padding.
  private static let topInset: CGFloat = 8
  private static let sideInset: CGFloat = 20
  private static let padding: CGFloat = 14
  private static let imageSide: CGFloat = 96
  private static let discDiameter: CGFloat = 52
  static let rowHeight: CGFloat = topInset + 2 * padding + imageSide

  var onPlay: (() -> ())?

  private let card = UIView()
  private lazy var glow = CoverGlowView(recipe: .topResult)
  /// Carries the photo's soft shadow; the image itself clips to its shape.
  private let imageHost = UIView()
  private lazy var artworkView = EntityImageView(frame: CGRect(
    x: 0,
    y: 0,
    width: SearchTopResultCell.imageSide,
    height: SearchTopResultCell.imageSide
  ))
  /// The app's artist placeholder, for an artist with neither a photo of their own nor a
  /// record on the phone (never the artist's shared artwork, which can be someone else).
  private let placeholderView: UIImageView = {
    let imageView = UIImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFill
    imageView.layer.cornerRadius = CassetteRadius.artworkRow
    imageView.layer.masksToBounds = true
    imageView.isHidden = true
    return imageView
  }()
  private let kickerLabel = UILabel()
  private let nameLabel = UILabel()
  private let subtitleLabel = UILabel()
  private lazy var playButton: UIButton = {
    // The cream disc, 52pt with a 22pt glyph (`.bigPlay`), nudged 3pt for optical
    // centring.
    let button = LibraryElementDetailTableHeaderView.makeDetailPlayCTA(
      diameter: SearchTopResultCell.discDiameter,
      glyphScale: 0.43
    )
    button.configuration?.contentInsets = NSDirectionalEdgeInsets(
      top: 0,
      leading: 3,
      bottom: 0,
      trailing: 0
    )
    button.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .touchUpInside)
    return button
  }()

  private var name = ""
  private var query = ""
  /// A newer bind replaces the token, so a late colour read for a reused cell is dropped.
  private var tintToken = UUID()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    setUp()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setUp() {
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    selectionStyle = .none

    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = .cassette(.surfaceElevated)
    card.layer.cornerRadius = CassetteRadius.litCard
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 1
    card.clipsToBounds = true
    contentView.addSubview(card)

    glow.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(glow)

    imageHost.translatesAutoresizingMaskIntoConstraints = false
    imageHost.isUserInteractionEnabled = false
    imageHost.layer.shadowColor = UIColor.black.cgColor
    imageHost.layer.shadowOpacity = 0
    imageHost.layer.shadowRadius = 12
    imageHost.layer.shadowOffset = CGSize(width: 0, height: 10)
    imageHost.layer.shadowPath = UIBezierPath(ovalIn: CGRect(
      x: 0,
      y: 0,
      width: Self.imageSide,
      height: Self.imageSide
    )).cgPath
    artworkView.translatesAutoresizingMaskIntoConstraints = false
    imageHost.addSubview(artworkView)
    imageHost.addSubview(placeholderView)
    card.addSubview(imageHost)

    kickerLabel.numberOfLines = 1
    nameLabel.numberOfLines = 2
    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.adjustsFontForContentSizeCategory = false
    subtitleLabel.font = UIFont.cassette(.cardSubtitle)
    subtitleLabel.textColor = .cassette(.textSecondary)
    subtitleLabel.numberOfLines = 1
    subtitleLabel.lineBreakMode = .byTruncatingTail
    let textStack = UIStackView(arrangedSubviews: [kickerLabel, nameLabel, subtitleLabel])
    textStack.axis = .vertical
    textStack.alignment = .leading
    textStack.spacing = 4
    textStack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(textStack)

    playButton.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(playButton)

    let cardHeight = card.heightAnchor.constraint(equalToConstant: 2 * Self.padding + Self.imageSide)
    cardHeight.priority = UILayoutPriority(999)
    NSLayoutConstraint.activate([
      card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.topInset),
      card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.sideInset),
      card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Self.sideInset),
      cardHeight,

      glow.topAnchor.constraint(equalTo: card.topAnchor),
      glow.bottomAnchor.constraint(equalTo: card.bottomAnchor),
      glow.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      glow.trailingAnchor.constraint(equalTo: card.trailingAnchor),

      imageHost.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.padding),
      imageHost.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      imageHost.widthAnchor.constraint(equalToConstant: Self.imageSide),
      imageHost.heightAnchor.constraint(equalToConstant: Self.imageSide),
      artworkView.topAnchor.constraint(equalTo: imageHost.topAnchor),
      artworkView.bottomAnchor.constraint(equalTo: imageHost.bottomAnchor),
      artworkView.leadingAnchor.constraint(equalTo: imageHost.leadingAnchor),
      artworkView.trailingAnchor.constraint(equalTo: imageHost.trailingAnchor),
      placeholderView.topAnchor.constraint(equalTo: imageHost.topAnchor),
      placeholderView.bottomAnchor.constraint(equalTo: imageHost.bottomAnchor),
      placeholderView.leadingAnchor.constraint(equalTo: imageHost.leadingAnchor),
      placeholderView.trailingAnchor.constraint(equalTo: imageHost.trailingAnchor),

      playButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.padding),
      playButton.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      playButton.widthAnchor.constraint(equalToConstant: Self.discDiameter),
      playButton.heightAnchor.constraint(equalToConstant: Self.discDiameter),

      textStack.leadingAnchor.constraint(equalTo: imageHost.trailingAnchor, constant: Self.padding),
      textStack.trailingAnchor.constraint(
        lessThanOrEqualTo: playButton.leadingAnchor,
        constant: -Self.padding
      ),
      textStack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
    ])

    applyBorderColor()
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
      self.applyBorderColor()
    }
  }

  /// The card's faint inner ring (`.topResult` inset 1px at 6%).
  private func applyBorderColor() {
    card.layer.borderColor = UIColor.cassette(.textPrimary).withAlphaComponent(0.06).cgColor
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onPlay = nil
    tintToken = UUID()
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    card.alpha = highlighted ? 0.85 : 1
  }

  func configure(
    top: SearchTopResult,
    query: String,
    theme: ThemePreference,
    artworkSetting: ArtworkDisplayPreference
  ) {
    self.query = query
    let kind: String
    switch top.kind {
    case let .artist(artist):
      kind = "Artist"
      name = artist.name
      subtitleLabel.text = nil
      subtitleLabel.isHidden = true
    case let .album(album):
      kind = "Album"
      name = album.name
      let artistName = album.artist?.name ?? ""
      subtitleLabel.text = artistName
      subtitleLabel.isHidden = artistName.isEmpty
    }
    kickerLabel.attributedText = .cassette(kind, .kicker, color: .cassette(.textSecondary))

    // The image: an artist's own photo in a circle with a soft shadow; otherwise the
    // record (an artist with no photo shows their first record on the phone, as drawn).
    placeholderView.isHidden = true
    artworkView.isHidden = false
    if top.showsPhoto, case let .artist(artist) = top.kind {
      artworkView.shape = .circle
      artworkView.display(theme: theme, container: artist)
      imageHost.layer.shadowOpacity = 0.45
    } else if let coverAlbum = top.coverAlbum {
      artworkView.shape = .rounded(.small)
      artworkView.display(theme: theme, container: coverAlbum, cornerRadius: .small)
      imageHost.layer.shadowOpacity = 0
    } else {
      artworkView.isHidden = true
      placeholderView.image = UIImage.getGeneratedArtwork(theme: theme, artworkType: .artist)
      placeholderView.isHidden = false
      imageHost.layer.shadowOpacity = 0
    }

    // The light: the record's glow behind the card, and its colour on the typed letters
    // (the neutral tint until the cover is read; never orange).
    let coverPath = top.coverAlbum?.imagePath(setting: artworkSetting)
    glow.show(coverPath: coverPath)
    applyTint(coverPath: coverPath)

    accessibilityLabel = "\(kind), \(name)"
    playButton.accessibilityLabel = "Play \(name)"
  }

  private func applyTint(coverPath: String?) {
    tintToken = UUID()
    guard let coverPath, !coverPath.isEmpty else {
      renderName(hitColor: CoverTint.neutral.text)
      return
    }
    if let cached = CoverTint.cached(coverPath: coverPath) {
      renderName(hitColor: cached.text)
      return
    }
    renderName(hitColor: CoverTint.neutral.text)
    let token = tintToken
    Task { [weak self] in
      let tint = await CoverTint.resolve(coverPath: coverPath)
      guard let self, self.tintToken == token else { return }
      self.renderName(hitColor: (tint ?? .neutral).text)
    }
  }

  /// The name in the shout role (Barlow ExtraBold 26, capitals), the typed letters lit.
  private func renderName(hitColor: UIColor) {
    nameLabel.attributedText = SearchHighlight.attributed(
      name,
      query: query,
      style: .shout,
      color: .cassette(.textPrimary),
      hitColor: hitColor
    )
  }
}

// MARK: - SearchArtistShelfCell

/// The ARTISTS shelf: a row of 104pt circles with a centred name under each (`.artistTile`,
/// `.artistCircle`), in the 20pt gutter, 12pt apart (the mock's `.shelf` gap). A tap opens
/// the artist. No play disc (none drawn).
final class SearchArtistShelfCell: UITableViewCell, UICollectionViewDataSource,
  UICollectionViewDelegate {
  static let reuseIdentifier = "SearchArtistShelfCell"
  fileprivate static let diameter: CGFloat = 104
  private static let spacing: CGFloat = 12
  private static let sideInset: CGFloat = 20
  /// The circle, the 8pt gap and one name line, with a little air.
  static let rowHeight: CGFloat = diameter + 8 + 24

  private var artists: [SearchArtistTile] = []
  private var theme: ThemePreference = .defaultValue
  private var onSelect: ((Artist) -> ())?

  private lazy var collectionView: UICollectionView = {
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.itemSize = CGSize(width: Self.diameter, height: Self.rowHeight)
    layout.minimumLineSpacing = Self.spacing
    layout.minimumInteritemSpacing = Self.spacing
    layout.sectionInset = UIEdgeInsets(top: 0, left: Self.sideInset, bottom: 0, right: Self.sideInset)
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.backgroundColor = .clear
    collectionView.showsHorizontalScrollIndicator = false
    collectionView.alwaysBounceHorizontal = true
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.register(
      SearchArtistCircleCell.self,
      forCellWithReuseIdentifier: SearchArtistCircleCell.reuseIdentifier
    )
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    return collectionView
  }()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    selectionStyle = .none
    contentView.addSubview(collectionView)
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: contentView.topAnchor),
      collectionView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      collectionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    artists: [SearchArtistTile],
    theme: ThemePreference,
    onSelect: @escaping (Artist) -> ()
  ) {
    self.artists = artists
    self.theme = theme
    self.onSelect = onSelect
    collectionView.reloadData()
    collectionView.setContentOffset(.zero, animated: false)
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    artists.count
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  )
    -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: SearchArtistCircleCell.reuseIdentifier,
      for: indexPath
    ) as! SearchArtistCircleCell
    // Names stay plain (no lit letters on rows tonight; see SearchHighlight).
    cell.display(artists[indexPath.item], theme: theme)
    return cell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard indexPath.item < artists.count else { return }
    onSelect?(artists[indexPath.item].artist)
  }
}

// MARK: - SearchArtistCircleCell

/// One artist on the ARTISTS shelf, laid out as `ArtistCircleCollectionCell`'s compact
/// tile (a 104pt circle, the name centred 8pt under it in one line). Its own cell because
/// the circle follows the top card's photo rule, which the shared cell does not: the
/// artist's own photo only when `hasOwnPhotoOnDisk` (a shared artwork row can carry someone
/// else's face), else one of their records on the phone, as drawn, else the generated
/// artist placeholder.
final class SearchArtistCircleCell: UICollectionViewCell {
  static let reuseIdentifier = "SearchArtistCircleCell"

  private lazy var artworkView: EntityImageView = {
    let view = EntityImageView(frame: CGRect(
      x: 0,
      y: 0,
      width: SearchArtistShelfCell.diameter,
      height: SearchArtistShelfCell.diameter
    ))
    view.shape = .circle
    view.isUserInteractionEnabled = false
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let placeholderView: UIImageView = {
    let imageView = UIImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFill
    imageView.layer.cornerRadius = SearchArtistShelfCell.diameter / 2
    imageView.layer.masksToBounds = true
    imageView.isHidden = true
    return imageView
  }()

  private let nameLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.cassette(.miniTitle)
    label.textColor = UIColor.cassette(.textPrimary)
    label.textAlignment = .center
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.backgroundColor = .clear
    contentView.addSubview(artworkView)
    contentView.addSubview(placeholderView)
    contentView.addSubview(nameLabel)
    let diameter = SearchArtistShelfCell.diameter
    NSLayoutConstraint.activate([
      artworkView.topAnchor.constraint(equalTo: contentView.topAnchor),
      artworkView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      artworkView.widthAnchor.constraint(equalToConstant: diameter),
      artworkView.heightAnchor.constraint(equalToConstant: diameter),
      placeholderView.topAnchor.constraint(equalTo: artworkView.topAnchor),
      placeholderView.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor),
      placeholderView.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor),
      placeholderView.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
      nameLabel.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: 8),
      nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func display(_ tile: SearchArtistTile, theme: ThemePreference) {
    nameLabel.text = tile.artist.name
    accessibilityLabel = tile.artist.name
    isAccessibilityElement = true
    accessibilityTraits = .button
    if tile.showsPhoto {
      showArtwork(of: tile.artist, theme: theme)
    } else if let coverAlbum = tile.coverAlbum {
      showArtwork(of: coverAlbum, theme: theme)
    } else {
      artworkView.isHidden = true
      placeholderView.image = UIImage.getGeneratedArtwork(theme: theme, artworkType: .artist)
      placeholderView.isHidden = false
    }
  }

  private func showArtwork(of container: PlayableContainable, theme: ThemePreference) {
    placeholderView.isHidden = true
    artworkView.isHidden = false
    artworkView.shape = .circle
    artworkView.display(theme: theme, container: container)
  }
}

// MARK: - CatalogHit

/// An artist, album or song from Cassette's catalog, from the site's name search
/// (GET /api/search, apps/cassette/src/app/api/search/route.ts): the same ranking as the
/// website's type-ahead, the famous name first. Pictures come only from the image ladder (each
/// hit's `image`); a hit with none shows the empty square (BUG-964: the old `coverArtUrl` could
/// send the phone to archive.org for a cover with no grid size).
struct CatalogHit: Hashable, Sendable {
  enum Kind: Hashable, Sendable { case artist, album, song }

  let kind: Kind
  /// The kind and the catalog's id, unique across the three lists.
  let id: String
  let title: String
  let artistName: String
  let albumTitle: String?
  /// The picture at the 48pt row's ladder rung, or nil with no ladder picture.
  let imageUrl: String?
  let artistSlug: String?
  let albumSlug: String?

  /// "Artist", "Album · The Beatles", "Song · The Beatles".
  var subtitle: String {
    switch kind {
    case .artist: return "Artist"
    case .album: return "Album · \(artistName)"
    case .song: return "Song · \(artistName)"
    }
  }

  private static let artistLimit = 2
  private static let albumLimit = 4
  private static let songLimit = 4

  private struct Payload: Decodable {
    struct Artist: Decodable {
      let id: String
      let name: String
      let slug: String?
      let image: CassetteImageRef?
    }

    struct Album: Decodable {
      let id: String
      let title: String
      let slug: String?
      let artistName: String?
      let artistSlug: String?
      let image: CassetteImageRef?
    }

    struct Song: Decodable {
      let id: String
      let title: String
      let artistName: String?
      let artistSlug: String?
      let albumTitle: String?
      let albumSlug: String?
      let image: CassetteImageRef?
    }

    let artists: [Artist]
    let albums: [Album]
    let songs: [Song]
    /// The groups in the order the site shows them ("artists", "albums", "songs").
    let order: [String]?
  }

  private static let base = "https://www.cassette.digital"

  /// The address of `ref` at the rung a 48pt row needs on this screen (the kit's one pick rule).
  @MainActor
  private static func rowUrl(_ ref: CassetteImageRef?) -> String? {
    guard let ref else { return nil }
    let scale = UITraitCollection.current.displayScale
    let natural = [ref.w, ref.h].compactMap { $0 }.max()
    let rung = CassetteKitTokens.Images.pickRung(
      w: 48, h: 48, scale: Double(scale > 0 ? scale : 3),
      aspect: ref.kind == "photo" ? CassetteKitTokens.Images.assumedPhotoAspect : CassetteKitTokens.Images.assumedCoverAspect,
      natural: natural
    )
    return ref.url(rung: rung)
  }

  /// The best few of each kind, in the site's order; empty on any failure.
  @MainActor
  static func search(_ query: String) async -> [CatalogHit] {
    var parts = URLComponents(string: base + "/api/search")
    parts?.queryItems = [URLQueryItem(name: "q", value: String(query.prefix(120))), URLQueryItem(name: "perPage", value: "6")]
    guard let url = parts?.url else { return [] }
    var request = URLRequest(url: url)
    request.timeoutInterval = 8
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else { return [] }
    let artists = payload.artists.prefix(artistLimit).map {
      CatalogHit(
        kind: .artist, id: "artist:\($0.id)", title: $0.name, artistName: $0.name, albumTitle: nil,
        imageUrl: rowUrl($0.image), artistSlug: $0.slug, albumSlug: nil
      )
    }
    let albums = payload.albums.filter { $0.slug != nil }.prefix(albumLimit).map {
      CatalogHit(
        kind: .album, id: "album:\($0.id)", title: $0.title, artistName: $0.artistName ?? "",
        albumTitle: $0.title, imageUrl: rowUrl($0.image), artistSlug: $0.artistSlug, albumSlug: $0.slug
      )
    }
    let songs = payload.songs.filter { $0.albumSlug != nil }.prefix(songLimit).map {
      CatalogHit(
        kind: .song, id: "song:\($0.id)", title: $0.title, artistName: $0.artistName ?? "",
        albumTitle: $0.albumTitle, imageUrl: rowUrl($0.image), artistSlug: $0.artistSlug, albumSlug: $0.albumSlug
      )
    }
    let groups: [String: [CatalogHit]] = ["artists": Array(artists), "albums": Array(albums), "songs": Array(songs)]
    let order = (payload.order ?? []).filter { groups[$0] != nil }
    return (order.isEmpty ? ["artists", "albums", "songs"] : order).flatMap { groups[$0] ?? [] }
  }
}

// MARK: - CatalogHitCell

/// One catalog match: its picture (a circle for an artist), its name, and what it is.
final class CatalogHitCell: UITableViewCell {
  static let reuseIdentifier = "CatalogHitCell"
  static let rowHeight: CGFloat = 48 + 2 * CassetteTheme.Spacing.sm

  private let art = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private var represented: String?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    let selected = UIView()
    selected.backgroundColor = CassetteTheme.UIColors.bg3
    selectedBackgroundView = selected

    art.contentMode = .scaleAspectFill
    art.clipsToBounds = true
    art.backgroundColor = CassetteTheme.UIColors.bg3
    art.layer.cornerCurve = .continuous

    titleLabel.font = UIFont.cassette(.rowTitle)
    titleLabel.textColor = .cassette(.textPrimary)
    subtitleLabel.font = UIFont.cassette(.metadata)
    subtitleLabel.textColor = .cassette(.textSecondary)

    let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    text.axis = .vertical
    text.spacing = 2
    for v in [art, text] {
      v.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(v)
    }
    let m = CassetteHeading.sideInset
    NSLayoutConstraint.activate([
      art.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
      art.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      art.widthAnchor.constraint(equalToConstant: 48),
      art.heightAnchor.constraint(equalToConstant: 48),
      text.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: CassetteTheme.Spacing.md),
      text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
      text.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func prepareForReuse() {
    super.prepareForReuse()
    represented = nil
    art.image = nil
  }

  func configure(_ hit: CatalogHit) {
    titleLabel.text = hit.title
    subtitleLabel.text = hit.subtitle
    art.layer.cornerRadius = hit.kind == .artist ? 24 : CassetteRadius.small
    accessibilityLabel = "\(hit.title), \(hit.subtitle), not in your library"
    represented = hit.imageUrl
    guard let src = hit.imageUrl, !src.isEmpty else { return }
    // A 48pt square: decoded at the row's size, not the cover's (BUG-818).
    if let cached = RadioArtLoader.shared.cachedImage(for: src, maxPixel: RadioArtLoader.rowPixel) {
      art.image = cached
      return
    }
    Task { @MainActor [weak self] in
      let loaded = await RadioArtLoader.shared.image(for: src, maxPixel: RadioArtLoader.rowPixel)
      guard let self, represented == src else { return }
      art.image = loaded
    }
  }
}
