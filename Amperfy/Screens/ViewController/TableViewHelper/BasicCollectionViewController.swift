//
//  BasicCollectionViewController.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 27.09.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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

// MARK: - BasicCollectionViewController

class BasicCollectionViewController: UICollectionViewController, ListScreenChrome {
  let appearanceRefresh = ListAppearanceRefresh()

  let searchController = UISearchController(searchResultsController: nil)

  var containableAtIndexPathCallback: ContainableAtIndexPathCallback?
  var playContextAtIndexPathCallback: PlayContextAtIndexPathCallback?
  var isIndexTitelsHidden = false
  var refreshControl: UIRefreshControl?

  override func viewDidLoad() {
    super.viewDidLoad()
    collectionView.keyboardDismissMode = .onDrag

    guard let sceneTitle else { return }
    setNavBarTitle(title: sceneTitle)
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    // cassette (BUG-428): refresh on first appearance, after an offline-mode change or a
    // library-filter change, never on a plain pop back (see ListAppearanceRefresh).
    let isOfflineMode = appDelegate.storage.settings.user.isOfflineMode
    switch appearanceRefresh.decide(isOfflineMode: isOfflineMode) {
    case .none:
      return
    case .resetScopeAndRefresh:
      if searchController.searchBar.scopeButtonTitles?.count ?? 0 > 1, isOfflineMode {
        searchController.searchBar.selectedScopeButtonIndex = 1
      } else {
        searchController.searchBar.selectedScopeButtonIndex = 0
      }
    case .refresh:
      break
    }
    updateSearchResults(for: searchController)
  }

  func configureSearchController(
    placeholder: String?,
    scopeButtonTitles: [String]? = nil
  ) {
    searchController.searchResultsUpdater = self
    searchController.searchBar.autocapitalizationType = .none
    #if !targetEnvironment(macCatalyst)
      // On mac catalyist scopeButtonTitle together with fullscreen will trigger the following exception:
      // FAULT: NSInternalInconsistencyException: titlebarViewController not supported for this window style;
      searchController.searchBar.scopeButtonTitles = scopeButtonTitles
    #endif
    searchController.searchBar.placeholder = placeholder

    navigationItem.searchController = searchController
    navigationItem.hidesSearchBarWhenScrolling = true
    #if targetEnvironment(macCatalyst)
      navigationItem.preferredSearchBarPlacement = .integrated
    #else
      navigationItem.preferredSearchBarPlacement = .automatic
    #endif

    searchController.delegate = self
    searchController.obscuresBackgroundDuringPresentation = false
    searchController.searchBar.delegate = self // Monitor when the search button is tapped.
    definesPresentationContext = true
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemAt indexPath: IndexPath,
    point: CGPoint
  )
    -> UIContextMenuConfiguration? {
    guard let containableCB = containableAtIndexPathCallback,
          let containable = containableCB(indexPath)
    else { return nil }

    let identifier = NSString(string: TableViewPreviewInfo(
      playableContainerIdentifier: containable.containerIdentifier,
      indexPath: indexPath
    ).asJSONString())
    return UIContextMenuConfiguration(identifier: identifier, previewProvider: {
      let vc = EntityPreviewVC()
      vc.display(container: containable, on: self)
      Task { @MainActor in
        do {
          if let account = containable.account {
            try await containable.fetch(
              storage: self.appDelegate.storage,
              librarySyncer: self.appDelegate.getMeta(account.info).librarySyncer,
              playableDownloadManager: self.appDelegate.getMeta(account.info)
                .playableDownloadManager
            )
          }
        } catch {
          // a preview that couldn't refresh keeps what it had; nothing to tell the person (I-S5)
          self.appDelegate.eventLogger.report(topic: "Preview Sync", error: error, isBackground: true)
        }
        vc.refresh()
      }
      return vc
    }) { suggestedActions in
      var playIndexCB: (() -> PlayContext?)?
      if let playContextAtIndexPathCP = self.playContextAtIndexPathCallback {
        playIndexCB = { playContextAtIndexPathCP(indexPath) }
      }
      return EntityPreviewActionBuilder(
        container: containable,
        on: self,
        playContextCb: playIndexCB
      ).createMenu()
    }
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionCommitAnimating
  ) {
    animator.addCompletion {
      if let identifier = configuration.identifier as? String,
         let tvPreviewInfo = TableViewPreviewInfo.create(fromIdentifier: identifier),
         let containerIdentifier = tvPreviewInfo.playableContainerIdentifier,
         let container = self.appDelegate.storage.main.library
         .getContainer(identifier: containerIdentifier) {
        EntityPreviewActionBuilder(container: container, on: self).performPreviewTransition()
      }
    }
  }
}

// MARK: UISearchResultsUpdating, UISearchBarDelegate, UISearchControllerDelegate

extension BasicCollectionViewController: UISearchResultsUpdating, UISearchBarDelegate,
  UISearchControllerDelegate {
  func updateSearchResults(for searchController: UISearchController) {}

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
  }

  func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) {
    updateSearchResults(for: searchController)
  }
}

// MARK: - SingleSnapshotFetchedResultsCollectionViewController

@MainActor
class SingleSnapshotFetchedResultsCollectionViewController<ResultType>:
  BasicCollectionViewController,
  @preconcurrency NSFetchedResultsControllerDelegate where ResultType: NSFetchRequestResult {
  var diffableDataSource: BasicUICollectionViewDiffableDataSource?
  var snapshotDidChange: (() -> ())?
  /// cassette Patch 059: hide duplicate ArtistMO/AlbumMO rows by server id at render time.
  var suppressDuplicateLibraryEntityIds = false
  /// phone-taste: reshapes each fetched snapshot (after the duplicate filter) before it is
  /// applied, e.g. the Library grid's own letter sections. It must read only
  /// `itemIdentifiers`: the fetch's section ids are NSString underneath and crash when read
  /// as Int. Changed covers are found against the reshaped order, so they still repaint.
  var snapshotTransform: (
    (NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>, NSManagedObjectContext)
      -> NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>
  )?
  let account: Account

  init(collectionViewLayout: UICollectionViewLayout, account: Account) {
    self.account = account
    super.init(collectionViewLayout: collectionViewLayout)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    /// Store the data source in an instance property to make sure it's retained.
    diffableDataSource = createDiffableDataSource()
    /// Assign the data source to your collection view.
    collectionView.dataSource = diffableDataSource
  }

  /// need to be overriden in child class
  func createDiffableDataSource() -> BasicUICollectionViewDiffableDataSource {
    fatalError("Should have been overriden in child class")
  }

  /// This will override the NSFetchedResultsController handling of the super class -> Only use snapshots
  func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>,
    didChangeContentWith snapshot: NSDiffableDataSourceSnapshotReference
  ) {
    MainActor.assumeIsolated {
      guard let dataSource = collectionView?.dataSource as? UICollectionViewDiffableDataSource<
        Int,
        NSManagedObjectID
      > else {
        assertionFailure("The data source has not implemented snapshot support while it should")
        return
      }
      var snapshot = snapshot as NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>
      let currentSnapshot = dataSource.snapshot() as NSDiffableDataSourceSnapshot<
        Int,
        NSManagedObjectID
      >

      if suppressDuplicateLibraryEntityIds {
        snapshot = LibrarySnapshotDedup.suppressingDuplicateServerIds(
          snapshot: snapshot,
          context: controller.managedObjectContext
        )
      }
      if let snapshotTransform {
        snapshot = snapshotTransform(snapshot, controller.managedObjectContext)
      }

      // Repaint items whose object changed but whose place did not. Compared against the
      // snapshot that is about to be applied (filtered and reshaped), since that is the
      // order the current snapshot was applied in too.
      let reloadIdentifiers: [NSManagedObjectID] = snapshot.itemIdentifiers
        .compactMap { itemIdentifier in
          guard let currentIndex = currentSnapshot.indexOfItem(itemIdentifier),
                let index = snapshot.indexOfItem(itemIdentifier), index == currentIndex else {
            return nil
          }
          guard let existingObject = try? controller.managedObjectContext
            .existingObject(with: itemIdentifier), existingObject.isUpdated else { return nil }
          return itemIdentifier
        }
      snapshot.reconfigureItems(reloadIdentifiers)

      dataSource.apply(
        snapshot as NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>,
        animatingDifferences: false
      )
      self.snapshotDidChange?()
    }
  }
}
