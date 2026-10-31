//
//  BasicTableViewController.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 23.02.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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
import Foundation
import UIKit

extension UIViewController {
  func setNavBarTitle(title: String) {
    self.title = title
  }
}

// MARK: - TableViewPreviewInfo

public struct TableViewPreviewInfo: Codable {
  public var playableContainerIdentifier: PlayableContainerIdentifier?
  public var indexPath: IndexPath?

  static func create(fromIdentifier identifier: String) -> TableViewPreviewInfo? {
    guard let identifierData = identifier.data(using: .utf8),
          let tvIdentifier = try? JSONDecoder().decode(
            TableViewPreviewInfo.self,
            from: identifierData
          )
    else { return nil }
    return tvIdentifier
  }
}

public typealias ContainableAtIndexPathCallback = (IndexPath) -> PlayableContainable?
public typealias SwipeActionCallback = (
  IndexPath,
  _ completionHandler: @escaping (_ actionContext: SwipeActionContext?) -> ()
)
  -> ()
public typealias PlayContextAtIndexPathCallback = (IndexPath) -> PlayContext?

// MARK: - SwipeDisplaySettings

struct SwipeDisplaySettings {
  var playContextTypeOfElements: PlayerMode = .music

  func isAllowedToDisplay(
    actionType: SwipeActionType,
    containable: PlayableContainable,
    isOfflineMode: Bool
  )
    -> Bool {
    switch playContextTypeOfElements {
    case .music:
      if actionType == .addToPlaylist,
         containable.playables.count == 1,
         containable.playables[0].isRadio {
        return false
      }
      if actionType == .insertPodcastQueue ||
        actionType == .appendPodcastQueue {
        return false
      }
    case .podcast:
      if actionType == .playShuffled ||
        actionType == .addToPlaylist ||
        actionType == .insertContextQueue ||
        actionType == .appendContextQueue ||
        actionType == .insertUserQueue ||
        actionType == .appendUserQueue {
        return false
      }
    }
    if isOfflineMode,
       actionType == .addToPlaylist || actionType == .download || actionType == .favorite {
      return false
    }
    // Patch 111: Delete Cache (removeFromCache) is a streaming/server-mode
    // affordance, only meaningful when the row actually has cached files. Gate
    // it on the Cassette server-mode concept (server mode on == NOT
    // isOnDeviceOnly) — the same flag the Albums shelf uses — not the upstream
    // online/offline flag. Hide it in the default on-device-only mode and when
    // nothing is cached, so it can't appear from the swipe entry point either.
    if actionType == .removeFromCache,
       CassetteLibraryFilterProvider.shared.isOnDeviceOnly || !containable.playables
       .hasCachedItems {
      return false
    }
    // cassette: favorites feature removed. The .favorite swipe action is never
    // displayed (the enum case is kept for Codable/exhaustiveness only). A
    // legacy persisted swipe config that still lists it is filtered here.
    if actionType == .favorite {
      return false
    }
    return true
  }
}

// MARK: - BasicTableViewController

class BasicTableViewController: KeyCommandTableViewController, ListScreenChrome {
  let appearanceRefresh = ListAppearanceRefresh()

  // cassette (BUG-429): swipe buttons are brand surfaces, alternating so neighbours read as
  // separate buttons. They were iOS blue, orange, purple and grey by position. The icons are
  // white bitmaps (SwipeActionSettings), legible on both.
  private static let swipeButtonColors: [UIColor] = [
    .cassette(.surfaceElevated),
    .cassette(.hairline),
  ]

  let searchController = UISearchController(searchResultsController: nil)

  var swipeDisplaySettings = SwipeDisplaySettings()
  var containableAtIndexPathCallback: ContainableAtIndexPathCallback?
  var playContextAtIndexPathCallback: PlayContextAtIndexPathCallback?
  var swipeCallback: SwipeActionCallback?
  var isEditLockedDueToActiveSwipe = false
  var isSingleCellEditingModeActive = false

  /// cassette (header-pop fix, round 3): true for the WHOLE duration of an
  /// interactive pop (edge-swipe back) of a collapsing-header detail screen.
  /// While set, the collapsing-header layout is a NO-OP — the hero keeps its
  /// current (scrolled-collapsed) frame and the sticky-title alpha is held —
  /// so the hero rides off-screen with the transition instead of re-expanding
  /// ("popping in"). Re-expansion has MULTIPLE triggers during the pop (header
  /// re-layout as `adjustedContentInset` animates with the nav bar's large-title
  /// change, a `resizeToFit` re-measure, a `contentOffset` reset). Freezing for
  /// the entire transition is immune to which one fires. Only the collapsing-
  /// header detail VCs set this; every other screen ignores it.
  var isHeaderTransitionFrozen = false

  /// cassette (swipe-back band fix): the destination screen's real nav-bar
  /// appearance slots, held for the duration of an interactive pop so they can
  /// be put back exactly as they were. Deliberately a value the completion
  /// closure captures STRONGLY rather than a property on the popped view
  /// controller: a successful pop releases that controller, and a restore that
  /// depended on it would silently leave the destination's bar transparent
  /// forever.
  private struct DestinationBarAppearanceStash {
    let item: UINavigationItem
    let standard: UINavigationBarAppearance?
    let compact: UINavigationBarAppearance?
    let scrollEdge: UINavigationBarAppearance?
    let compactScrollEdge: UINavigationBarAppearance?

    /// Put the destination's real bar appearance back. Runs on completion
    /// whether the swipe finished or was reversed.
    func restore() {
      UIView.performWithoutAnimation {
        item.standardAppearance = standard
        item.compactAppearance = compact
        item.scrollEdgeAppearance = scrollEdge
        item.compactScrollEdgeAppearance = compactScrollEdge
      }
    }
  }

  /// cassette (swipe-back band fix): a translucent bar slid in over the album
  /// artwork during an edge-swipe back to Albums, but not back to Home.
  ///
  /// The detail screens draw their artwork UNDER the navigation bar
  /// (`contentInsetAdjustmentBehavior = .never` plus a header that only insets
  /// by the status-bar height), and they keep all four bar appearance slots
  /// transparent so the cover reads clean at rest. During a pop the navigation
  /// bar is shared: UIKit cross-fades its background to whatever the
  /// DESTINATION asks for while the outgoing detail view — artwork and all —
  /// is still filling most of the screen. So the destination's bar background
  /// paints over the cover on its way in, and mid-swipe it is at partial
  /// opacity, which is exactly the translucent band.
  ///
  /// Home never showed it because Home is the one list screen that overrides
  /// the bar with a system material (`configureWithDefaultBackground()`, no
  /// background colour, no shadow) — fading a blur of the cover in over the
  /// cover is invisible. Every other list screen, Albums included, inherits
  /// the global opaque proxy (solid `bg` + an `ink4` hairline), and a solid
  /// fill over artwork is very visible.
  ///
  /// Fix: hold the destination's bar background transparent for the length of
  /// the pop, then restore its real appearance the moment the transition ends.
  /// The restore is invisible because the destination's own content does not
  /// extend under the bar — the strip behind the bar is flat `bg` either way.
  /// Doing it here rather than in one list screen covers every route into a
  /// detail page (Albums, Artists, Search, Genre, Playlists).
  private func neutralizeDestinationBarBackground(
    using coordinator: UIViewControllerTransitionCoordinator
  )
    -> DestinationBarAppearanceStash? {
    guard let destination = coordinator.viewController(forKey: .to) else { return nil }
    let item = destination.navigationItem
    let stash = DestinationBarAppearanceStash(
      item: item,
      standard: item.standardAppearance,
      compact: item.compactAppearance,
      scrollEdge: item.scrollEdgeAppearance,
      compactScrollEdge: item.compactScrollEdgeAppearance
    )
    let transparent = UINavigationBarAppearance()
    transparent.configureWithTransparentBackground()
    item.standardAppearance = transparent
    item.compactAppearance = transparent
    item.scrollEdgeAppearance = transparent
    item.compactScrollEdgeAppearance = transparent
    return stash
  }

  /// cassette (header-pop fix, round 3): call from `viewWillDisappear` of a
  /// collapsing-header detail VC when `isMovingFromParent` (an actual pop,
  /// including the interactive edge-swipe). Freezes the header for the whole
  /// transition and clears the flag in the transition-coordinator completion.
  /// On CANCELLATION (a reversed partial swipe), `restoreOnCancel` is invoked
  /// so the normal scroll-driven layout/alpha resumes and a cancelled swipe
  /// behaves exactly as before. If there is no transition coordinator (a
  /// non-animated pop), the flag still clears synchronously.
  func freezeCollapsingHeaderForPopTransition(restoreOnCancel: @escaping () -> ()) {
    isHeaderTransitionFrozen = true
    // round 7f: freeze the LAYOUT ONLY. The title needs no pop-specific handling
    // anymore — updateAlpha hides the titleView (isHidden) whenever it is fully
    // transparent, so at the top it is genuinely ABSENT from the render tree and
    // UIKit has nothing to cross-fade during the pop. No detach, no re-attach, no
    // alpha fight (all of which UIKit kept overriding). Freezing the hero layout
    // (via the early-returns keyed on this flag) is the whole job; a cancelled
    // swipe just resumes normal scroll-driven updates.
    guard let coordinator = transitionCoordinator else {
      // No interactive/animated transition — release the freeze now.
      isHeaderTransitionFrozen = false
      return
    }
    // cassette (swipe-back band fix): hold the destination's bar background
    // transparent so it cannot paint over the outgoing artwork mid-swipe. The
    // stash is captured strongly by the completion below, so the restore runs
    // even once this (popped) controller is gone.
    let barStash = neutralizeDestinationBarBackground(using: coordinator)
    coordinator.animate(alongsideTransition: nil) { [weak self] context in
      barStash?.restore()
      guard let self else { return }
      isHeaderTransitionFrozen = false
      if context.isCancelled {
        // The swipe was reversed — resume normal scroll-driven layout/alpha.
        restoreOnCancel()
      }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.keyboardDismissMode = .onDrag
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

  override func tableView(
    _ tableView: UITableView,
    willDisplayHeaderView view: UIView,
    forSection section: Int
  ) {
    // cassette Patch 015: every table section header (Library, Search,
    // Playlists, etc.) gets the Cassette display face + warm ink colour.
    // Done at willDisplay so we don't have to override
    // viewForHeaderInSection in every subclass.
    if let header = view as? UITableViewHeaderFooterView {
      var config = header.defaultContentConfiguration()
      config.text = header.textLabel?.text ?? config.text
      // cassette Patch 032: section header routes through .sectionLabel
      // (13pt bold display, uppercased here). 13pt matches iOS section-
      // header conventions (Settings.app, Music.app sidebar).
      config.textProperties.font = UIFont.cassette(.sectionLabel)
      config.textProperties.color = UIColor.cassette(.textSecondary)
      config.textProperties.transform = .uppercase
      header.contentConfiguration = config
      header.contentView.backgroundColor = .clear
    }
  }

  override func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
    isSingleCellEditingModeActive = true
  }

  override func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
    isSingleCellEditingModeActive = false
  }

  override func tableView(
    _ tableView: UITableView,
    leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  )
    -> UISwipeActionsConfiguration? {
    guard let swipeCB = swipeCallback,
          let containableCB = containableAtIndexPathCallback,
          let containable = containableCB(indexPath)
    else { return UISwipeActionsConfiguration() }

    var createdActionsIndex = 0
    var actions = [UIContextualAction]()
    for actionType in appDelegate.storage.settings.user.swipeActionSettings.leading {
      if !swipeDisplaySettings.isAllowedToDisplay(
        actionType: actionType,
        containable: containable,
        isOfflineMode: appDelegate.storage.settings.user.isOfflineMode
      ) { continue }
      let buttonColor = Self.swipeButtonColors.element(at: createdActionsIndex) ?? Self
        .swipeButtonColors.last!
      actions.append(createSwipeAction(
        for: actionType,
        buttonColor: buttonColor,
        indexPath: indexPath,
        preCbContainable: containable,
        actionCallback: swipeCB
      ))
      createdActionsIndex += 1
    }
    return UISwipeActionsConfiguration(actions: actions)
  }

  override func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  )
    -> UISwipeActionsConfiguration? {
    // return nil here allows to display the "Delete" confirmation swipe action in edit mode (nil -> show default action -> delete is the default one)
    guard !(tableView.isEditing && !isSingleCellEditingModeActive) else { return nil }
    // this empty configuration ensures to only perform one "Delete" action at a time (no confirmation is displayed)
    guard !(tableView.isEditing && isSingleCellEditingModeActive)
    else { return UISwipeActionsConfiguration() }
    guard let swipeCB = swipeCallback,
          let containableCB = containableAtIndexPathCallback,
          let containable = containableCB(indexPath)
    else { return UISwipeActionsConfiguration() }
    var createdActionsIndex = 0
    var actions = [UIContextualAction]()
    for actionType in appDelegate.storage.settings.user.swipeActionSettings.trailing {
      if !swipeDisplaySettings.isAllowedToDisplay(
        actionType: actionType,
        containable: containable,
        isOfflineMode: appDelegate.storage.settings.user.isOfflineMode
      ) { continue }
      let buttonColor = Self.swipeButtonColors.element(at: createdActionsIndex) ?? Self
        .swipeButtonColors.last!
      actions.append(createSwipeAction(
        for: actionType,
        buttonColor: buttonColor,
        indexPath: indexPath,
        preCbContainable: containable,
        actionCallback: swipeCB
      ))
      createdActionsIndex += 1
    }
    return UISwipeActionsConfiguration(actions: actions)
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

  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    0.0
  }

  override func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
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

  override func tableView(
    _ tableView: UITableView,
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

  func createSwipeAction(
    for actionType: SwipeActionType,
    buttonColor: UIColor,
    indexPath: IndexPath,
    preCbContainable: PlayableContainable,
    actionCallback: @escaping SwipeActionCallback
  )
    -> UIContextualAction {
    let action = UIContextualAction(
      style: .normal,
      title: actionType.displayName
    ) { action, view, completionHandler in
      Haptics.success
        .vibrate(isHapticsEnabled: self.appDelegate.storage.settings.user.isHapticsEnabled)
      actionCallback(indexPath) { actionContext in
        guard let actionContext = actionContext else { return }
        switch actionType {
        case .insertUserQueue:
          self.appDelegate.player
            .insertUserQueue(
              playables: actionContext.playables
                .filterCached(dependigOn: self.appDelegate.storage.settings.user.isOfflineMode)
            )
        case .appendUserQueue:
          self.appDelegate.player
            .appendUserQueue(
              playables: actionContext.playables
                .filterCached(dependigOn: self.appDelegate.storage.settings.user.isOfflineMode)
            )
        case .insertContextQueue:
          self.appDelegate.player
            .insertContextQueue(
              playables: actionContext.playables
                .filterCached(dependigOn: self.appDelegate.storage.settings.user.isOfflineMode)
            )
        case .appendContextQueue:
          self.appDelegate.player
            .appendContextQueue(
              playables: actionContext.playables
                .filterCached(dependigOn: self.appDelegate.storage.settings.user.isOfflineMode)
            )
        case .download:
          if let account = actionContext.containable.account {
            self.appDelegate.getMeta(account.info).playableDownloadManager
              .download(objects: actionContext.playables)
          }
        case .removeFromCache:
          let alert = UIAlertController(
            title: nil,
            message: "Are you sure to delete the cached file\(actionContext.playables.count > 1 ? "s" : "")?",
            preferredStyle: .alert
          )
          alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { _ in
            if let account = actionContext.containable.account {
              self.appDelegate.getMeta(account.info).playableDownloadManager
                .removeFinishedDownload(for: actionContext.playables)
            }
            self.appDelegate.storage.main.library.deleteCache(of: actionContext.playables)
            self.appDelegate.storage.main.saveContext()
            if let cell = self.tableView.cellForRow(at: indexPath) as? PlayableTableCell {
              cell.refresh()
            }
          }))
          alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            // do nothing
          }))
          self.present(alert, animated: true, completion: nil)
        case .addToPlaylist:
          let filterSongs = actionContext.playables.filterSongs()
          if let account = filterSongs.first?.account {
            let selectPlaylistVC = AppStoryboard.Main
              .segueToPlaylistSelector(
                account: account,
                itemsToAdd: filterSongs
              )
            let selectPlaylistNav = UINavigationController(rootViewController: selectPlaylistVC)
            self.present(selectPlaylistNav, animated: true)
          }
        case .play:
          self.appDelegate.player.play(context: actionContext.playContext)
        case .playShuffled:
          var playContext = actionContext.playContext
          if actionContext.playables.count <= 1 {
            playContext.isKeepIndexDuringShuffle = true
          }
          self.appDelegate.player.playShuffled(context: playContext)
        case .insertPodcastQueue:
          self.appDelegate.player
            .insertPodcastQueue(
              playables: actionContext.playables
                .filterCached(dependigOn: self.appDelegate.storage.settings.user.isOfflineMode)
            )
        case .appendPodcastQueue:
          self.appDelegate.player
            .appendPodcastQueue(
              playables: actionContext.playables
                .filterCached(dependigOn: self.appDelegate.storage.settings.user.isOfflineMode)
            )
        case .favorite:
          Task { @MainActor in
            do {
              if let account = actionContext.containable.account {
                try await actionContext.containable
                  .remoteToggleFavorite(
                    syncer: self.appDelegate
                      .getMeta(account.info).librarySyncer
                  )
              }
            } catch {
              self.appDelegate.eventLogger.report(topic: "Toggle Favorite", error: error)
            }
            if let cell = self.tableView.cellForRow(at: indexPath) as? PlayableTableCell {
              cell.refresh()
            }
          }
        }
      }
      completionHandler(true)
    }
    action.backgroundColor = buttonColor
    if actionType == .favorite {
      action.image = preCbContainable.isFavorite
        ? UIImage.heartFill.withRenderingMode(.alwaysOriginal)
        : UIImage.heartEmpty.withRenderingMode(.alwaysOriginal)
    } else {
      action.image = actionType.image.withRenderingMode(.alwaysOriginal)
    }
    return action
  }
}

// MARK: UISearchResultsUpdating

extension BasicTableViewController: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {}
}

// MARK: UISearchBarDelegate

extension BasicTableViewController: UISearchBarDelegate {
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
  }

  func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) {
    updateSearchResults(for: searchController)
  }
}

// MARK: UISearchControllerDelegate

extension BasicTableViewController: UISearchControllerDelegate {}
