//
//  LibraryContainerVC.swift
//  Amperfy
//
//  Created by Cassette Patch 039.
//  Copyright (c) 2026 Cassette. All rights reserved.
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
import UIKit

// MARK: - LibraryContainerVC

/// cassette Patch 039: Library tab redesign. Replaces `LibraryVC`'s
/// intermediate category list. Opens directly to the user's last-
/// surfaced category, hosts a nav-bar dropdown for switching, and
/// inherits each category VC's native `UISearchController` so the
/// pull-down search keeps working in place.
///
/// `LibraryVC` is intentionally kept on disk — `pushLibraryCategory`
/// and other deep-link flows still rely on `segueToLibrary`.
@MainActor
final class LibraryContainerVC: UIViewController {
  // MARK: - Dropdown surface

  /// The categories that surface in the dropdown. Mirrors the
  /// shipping iOS information architecture; favorites / newest /
  /// recent / directories / downloads are deliberately excluded per
  /// spec (still reachable via the existing tab sub-items and the
  /// Mac sidebar's `LibraryNavigatorConfigurator`).
  /// cassette Patch 104: Radios is disabled for now — removed from the
  /// iOS dropdown only (the Mac sidebar configurator is untouched). A
  /// stale persisted `.radios` selection falls back to Artists via the
  /// allow-list check in `init`.
  /// cassette: Podcasts is hidden as a browse surface — dropped from the
  /// iOS dropdown. A stale persisted `.podcasts` selection falls back to
  /// Artists via the same allow-list check in `init` / `showCategory`.
  /// cassette 2026-10-06: Radios is BACK in the dropdown. The hub now carries a
  /// curated station list (docs/reference/CASSETTE_RADIO.md) and this screen is
  /// how the phone plays it; Patch 104's removal stands only in history.
  private static let dropdownCategories: [LibraryDisplayType] = [
    .artists,
    .albums,
    .songs,
    .playlists,
    .genres,
    .radios,
  ]

  // MARK: - State

  private let account: Account
  private var currentCategory: LibraryDisplayType
  private var embeddedChild: UIViewController?

  private var titleButton: UIButton?
  private var userButton: UIButton?
  private var userBarButtonItem: UIBarButtonItem?
  private var accountNotificationHandler: AccountNotificationHandler?

  // MARK: - Init

  init(account: Account) {
    self.account = account
    let appDelegate = (UIApplication.shared.delegate as! AppDelegate)
    let persisted = appDelegate.storage.settings.accounts
      .getSetting(account.info).read.lastLibraryCategory
    // Defensive fallback: if a stale persisted enum case isn't in
    // our dropdown allow-list (e.g. user previously deep-linked
    // into Downloads and we then renamed cases), reset to Artists.
    if Self.dropdownCategories.contains(persisted) {
      self.currentCategory = persisted
    } else {
      self.currentCategory = .artists
    }
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = CassetteTheme.UIColors.bg
    // The dropdown lives in `titleView`; we never want the navbar
    // to inflate to large-title height because the embedded VCs
    // are doing their own scroll-driven UI underneath us.
    navigationItem.largeTitleDisplayMode = .never

    setupTitleButton()

    accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForActiveAccountChange { [weak self] _ in
      guard let self else { return }
      setupUserNavButton(
        currentAccount: account,
        userButton: &userButton,
        userBarButtonItem: &userBarButtonItem
      )
    }
    setupUserNavButton(
      currentAccount: account,
      userButton: &userButton,
      userBarButtonItem: &userBarButtonItem
    )

    embedChild(category: currentCategory)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Override the child's own viewWillAppear which flips this on;
    // dropdown lives in titleView so large-title mode would just
    // squash our content under a doubled-up bar.
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  // MARK: - Title button + dropdown

  private func setupTitleButton() {
    // cassette Patch 104 (Root 1): UIButton(configuration:) + cassetteBare()
    // instead of UIButton(type: .system) + .plain() — the system-button
    // default picked up the iOS 26 glass capsule and drew a faint rounded
    // container behind the "Artists v" dropdown.
    let button = UIButton(configuration: .cassetteBare())
    button.showsMenuAsPrimaryAction = true
    button.menu = makeCategoryMenu()
    applyTitleButtonAppearance(button: button, label: currentCategory.displayName)
    titleButton = button
    navigationItem.titleView = button
  }

  private func applyTitleButtonAppearance(button: UIButton, label: String) {
    var config = UIButton.Configuration.cassetteBare()
    var titleContainer = AttributeContainer()
    // phone-taste: the inline nav-title face (Barlow SemiBold 18, the mock's `.navTitle`),
    // the same as every other inline title and Home's.
    titleContainer.font = UIFont.cassette(.navTitle)
    titleContainer.foregroundColor = UIColor.cassette(.textPrimary)
    config.attributedTitle = AttributedString(label, attributes: titleContainer)
    config.image = CassetteIcon.chevronDown.symbolImage
    config.imagePlacement = .trailing
    // Small beside the 18pt title (the founder, 2026-10-31: the row-size chevron read as big
    // as the word), the size Apple's own title menus use.
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: CassetteIconSize.small.rawValue,
      weight: .semibold
    )
    config.imagePadding = 4
    config.baseForegroundColor = UIColor.cassette(.textPrimary)
    // cassette Polish 2 (C4/H): Barlow Condensed has a tall bounding box; with
    // zero vertical insets + sizeToFit the glyph tops were clipped in the nav
    // titleView. Give the line vertical breathing room.
    config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
    button.configuration = config
    button.tintColor = UIColor.cassette(.textPrimary)
    // Force the button to size itself so the chevron sits next to
    // the title rather than centered awkwardly.
    button.sizeToFit()
  }

  private func makeCategoryMenu() -> UIMenu {
    let actions = Self.dropdownCategories.map { type -> UIAction in
      UIAction(
        title: type.displayName,
        image: type.image,
        state: type == currentCategory ? .on : .off,
        handler: { [weak self] _ in
          self?.switchCategory(type)
        }
      )
    }
    return UIMenu(title: "Library", children: actions)
  }

  // MARK: - Child embedding

  private func embedChild(category: LibraryDisplayType) {
    let child = category.controller(
      account: account,
      settings: appDelegate.storage.settings
    )
    embed(child: child)
  }

  /// Shared embedding mechanics. Touching `child.view` forces `viewDidLoad`
  /// on the child so its search controller and right-bar buttons exist
  /// before we copy them up: each shipping category VC installs
  /// `navigationItem.searchController` in `viewDidLoad`, and the album VCs
  /// populate their right-bar options button synchronously there too (via
  /// `applyFilter()` → `change(sortType:)` → `updateRightBarButtonItems()`).
  /// We never display the child's own navigation bar — the container owns it.
  private func embed(child: UIViewController) {
    addChild(child)
    child.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(child.view)
    NSLayoutConstraint.activate([
      child.view.topAnchor.constraint(equalTo: view.topAnchor),
      child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    child.didMove(toParent: self)
    embeddedChild = child
    tightenTop(of: child)
    // cassette (rail): the tab bar minimizes and expands by watching the
    // selected screen's content scroll view. A plain container has none, so
    // the bar never saw a scroll here and the manual reveal hack grew in its
    // place. Forward the child's.
    setContentScrollView(child.contentScrollView(for: .bottom), for: .bottom)

    navigationItem.searchController = child.navigationItem.searchController
    navigationItem.hidesSearchBarWhenScrolling = true
    navigationItem.rightBarButtonItems = child.navigationItem.rightBarButtonItems
    definesPresentationContext = true
  }

  /// One top for every Library list (I-V16, the founder 2026-10-31: "why is there such a
  /// large gap between the results and the header?"). A grouped table leaves about 35pt above
  /// its first section when it has no header view, plus its section top padding: Artists,
  /// Playlists and Genres started about 40pt under the bar while Albums started at once. A
  /// small header view of our own and no section padding put the first row (or heading) one
  /// small step under the bar on every list.
  private func tightenTop(of child: UIViewController) {
    guard let table = (child as? UITableViewController)?.tableView, table.style != .plain else { return }
    table.sectionHeaderTopPadding = 0
    if table.tableHeaderView == nil {
      table.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CassetteTheme.Spacing.sm))
    }
  }

  private func unembedCurrentChild() {
    guard let child = embeddedChild else { return }
    child.willMove(toParent: nil)
    child.view.removeFromSuperview()
    child.removeFromParent()
    embeddedChild = nil
    setContentScrollView(nil, for: .bottom)
    navigationItem.searchController = nil
    navigationItem.rightBarButtonItems = nil
  }

  /// cassette: swap the embedded album VC for a different display style
  /// (grid ⇄ list) in place, keeping this container — and therefore the
  /// dropdown title and right-bar controls it owns — intact. Previously the
  /// album grid/list toggle called `replaceCurrentlyActiveVC` on the shared
  /// nav stack, which dropped the container entirely and pushed a bare album
  /// VC with no dropdown header (the "header randomly stops rendering when I
  /// change the view type" bug). Category (`currentCategory`) and the
  /// dropdown title are unchanged — only the child's layout style differs.
  public func replaceEmbeddedChild(with newChild: UIViewController) {
    unembedCurrentChild()
    embed(child: newChild)
  }

  // MARK: - Category switching

  /// cassette Patch 042: external entry point for deep-linking into
  /// a specific Library category (e.g. tapping the Albums shelf
  /// header on Home). Mirrors the private `switchCategory(_:)` but
  /// guards against unknown enum cases the dropdown doesn't surface.
  public func showCategory(_ type: LibraryDisplayType) {
    guard Self.dropdownCategories.contains(type) else { return }
    switchCategory(type)
  }

  private func switchCategory(_ type: LibraryDisplayType) {
    guard type != currentCategory else { return }
    currentCategory = type

    if let accountInfo = appDelegate.storage.settings.accounts.active {
      appDelegate.storage.settings.accounts.updateSetting(accountInfo) { accountSettings in
        accountSettings.lastLibraryCategory = type
      }
    }

    unembedCurrentChild()
    embedChild(category: type)

    if let titleButton {
      applyTitleButtonAppearance(button: titleButton, label: type.displayName)
      // Rebuild menu so the new selection's `.on` state reflects
      // immediately on next open.
      titleButton.menu = makeCategoryMenu()
    }
  }
}

extension LibraryContainerVC {
  override var sceneTitle: String? { "Library" }
}
