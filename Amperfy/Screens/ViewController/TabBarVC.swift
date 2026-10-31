//
//  TabBarVC.swift
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
import UIKit

// MARK: - TabBarVC

class TabBarVC: UITabBarController {
  private var libraryGroup: UITabGroup?
  private var searchTab: UISearchTab?
  private var homeTab: UITab?
  private let account: Account

  init(account: Account) {
    self.account = account
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var welcomePopupPresenter = WelcomePopupPresenter()
  var miniPlayer: MiniPlayerView?

  override func viewDidLoad() {
    super.viewDidLoad()
    var fixTabs = [UITab]()

    searchTab = UISearchTab { _ in
      UINavigationController(
        rootViewController: TabNavigatorItem.search
          .getController(account: self.account)
      )
    }
    // Apple's convention (founder, 2026-10-21: follow Apple where it has a strong mobile
    // pattern): selecting the tab focuses the field with the keyboard up. The start page
    // (chips, genres) shows under it until something is typed.
    searchTab!.automaticallyActivatesSearch = true
    fixTabs.append(searchTab!)

    // cassette Patch 053 (Phase H): tabs start with the outline icon. The
    // filled icon is swapped in for the currently-selected tab by the
    // `tabBarController(_:didSelectTab:previousTab:)` delegate callback
    // below, plus the initial `applySelectedTabIcon` after `selectedTab`
    // is set in `viewIsAppearing`. Selection cue is structural
    // (outline/filled) rather than chromatic.
    homeTab = UITab(
      title: TabNavigatorItem.home.title,
      image: TabNavigatorItem.home.outlineIcon,
      identifier: "Tabs.\(TabNavigatorItem.home.title)"
    ) { _ in
      UINavigationController(
        rootViewController: TabNavigatorItem.home
          .getController(account: self.account)
      )
    }
    fixTabs.append(homeTab!)

    var libraryTabs = [UITab]()
    let libraryTabsShown = appDelegate.storage.settings.accounts
      .getSetting(account.info).read
      .libraryDisplaySettings.inUse
      .compactMap { item in
        let tab = UITab(
          title: item.displayName,
          image: item.outlineImage,
          identifier: "Tabs.\(item.displayName)"
        ) { tab in
          item.controller(account: self.account, settings: self.appDelegate.storage.settings)
        }
        tab.allowsHiding = true
        return tab
      }
    libraryTabs.append(contentsOf: libraryTabsShown)

    let libraryTabsHidden = appDelegate.storage.settings.accounts
      .getSetting(account.info).read
      .libraryDisplaySettings.notUsed
      .compactMap { item in
        let tab = UITab(
          title: item.displayName,
          image: item.outlineImage,
          identifier: "Tabs.\(item.displayName)"
        ) { tab in
          item.controller(account: self.account, settings: self.appDelegate.storage.settings)
        }
        tab.allowsHiding = true
        tab.isHiddenByDefault = true
        return tab
      }
    libraryTabs.append(contentsOf: libraryTabsHidden)

    libraryGroup = UITabGroup(
      title: "Library",
      image: .musicLibraryOutline,
      identifier: "Tabs.Library",
      children: libraryTabs
    ) { tab in
      // cassette Patch 039: route the Library tab root to the new
      // dropdown container instead of the legacy intermediate
      // category list. LibraryVC stays reachable via direct
      // `segueToLibrary` callers (pushLibraryCategory, Mac sidebar).
      AppStoryboard.Main.segueToLibraryContainer(account: self.account)
    }
    libraryGroup!.managingNavigationController = UINavigationController()
    libraryGroup!.allowsReordering = true
    fixTabs.append(libraryGroup!)

    delegate = self
    tabs = fixTabs

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleLibraryItemsChanged(notification:)),
      name: .LibraryItemsChanged,
      object: nil
    )

    // cassette: `.onScrollDown` minimizes the tab bar as the user scrolls DOWN and
    // brings it back the moment they scroll UP (the Reddit feel). `.automatic`
    // resolved to no-minimize for our tab-bar-with-mini-player config, so we set
    // the explicit behavior. Options: `.onScrollDown` (this), `.never` (pinned),
    // `.automatic` (system default → no-shrink here), `.onScrollUp`.
    tabBarMinimizeBehavior = .onScrollDown

    miniPlayer = MiniPlayerView(player: appDelegate.player)
    miniPlayer!.configureForiOS()
    miniPlayer!.glassContainer.translatesAutoresizingMaskIntoConstraints = false

    let accessory = UITabAccessory(contentView: miniPlayer!.glassContainer)
    miniPlayerAccessory = accessory
    bottomAccessory = accessory

    heightConstraint = miniPlayer!.glassContainer.heightAnchor.constraint(equalToConstant: 48.0)
    // cassette (rail): UIKit owns the accessory slot. Everything we say about
    // the pill's size is a preference below required, so it can never fight a
    // slot that UIKit sizes differently on some device and break its layout.
    heightConstraint?.priority = UILayoutPriority(999)
    heightConstraint?.isActive = true
    if let host = miniPlayer!.glassContainer.superview {
      compactWidthConstraint = miniPlayer!.glassContainer.widthAnchor
        .constraint(equalTo: host.widthAnchor)
      compactWidthConstraint?.priority = UILayoutPriority(999)
    }

    miniPlayer!.tabAccessoryTraitChangeCB = configureTraitChangesForMiniPlayer
    configureTraitChangesForMiniPlayer()
    miniPlayer!.playablePresenceChangeCB = { [weak self] in self?.refreshMiniPlayerPresence(animated: true) }
    refreshMiniPlayerPresence(animated: false)

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.miniPlayer?
          .refreshForTraitChange(horizontalSizeClass: self.traitCollection.horizontalSizeClass)
        self.configureTraitChangesForMiniPlayer()
      }
    )

    if appDelegate.storage.settings.user.isOfflineMode {
      appDelegate.eventLogger.info(topic: "Reminder", message: "Offline Mode is active.")
    }
  }

  // MARK: - Rail

  /// cassette (rail): the bottom rail is Apple's, as shipped. `.onScrollDown`
  /// is set once in viewDidLoad and never written again; the mini player is
  /// the bar's bottom accessory and UIKit moves it between its floating and
  /// inline slots. What that gives on iOS 26.4, measured: the bar minimizes
  /// on a downward drag, comes back at the top of a list, toggles by itself
  /// at the end of one, and animates its own 0.47s morph. Driving the
  /// behaviour from scroll events to get more than that (a mid-list reveal)
  /// was tried in every form between 2026-10-19 and 10-20, see BUG-423, and
  /// every form fought that morph; the founder's call is the native bar, so
  /// that Apple's changes to it arrive on their own. The only things of ours
  /// in the rail are the pill (MiniPlayerView, one capsule in both slots) and
  /// the container constraints below.
  ///
  /// Kept as a no-op only for the two scroll call sites left in files with
  /// uncommitted founder work (ArtistDetailVC, HomeVC); the other five were
  /// removed in Wave 0 of the 2026-10-20 design-system audit. Remove this with
  /// those two once that work lands.
  func cassetteUpdateMinimizeForScroll(_ scrollView: UIScrollView) {}

  private func mainContent() -> UIView {
    // Attempt to find the main content view controller's view if the sidebar is visible.
    // Fallback to self.view.safeAreaLayoutGuide.leadingAnchor otherwise.
    if traitCollection.horizontalSizeClass == .regular, let selectedViewController {
      return selectedViewController.view
    }
    return view
  }

  var centerConstraint: NSLayoutConstraint?
  var regularWidthConstraint: NSLayoutConstraint?
  var heightConstraint: NSLayoutConstraint?
  var compactWidthConstraint: NSLayoutConstraint?
  var inlineHeightConstraint: NSLayoutConstraint?

  private enum RailLayout: Equatable { case inline, regularWide(CGFloat), compact }
  private var appliedRailLayout: RailLayout?

  func configureTraitChangesForMiniPlayer() {
    guard let miniPlayer else { return }
    // cassette (rail): one read of the accessory trait decides the container
    // constraints, idempotently, so UIKit's minimize/expand animation is never
    // fought by a constraint pass that disagrees with it halfway through. The
    // pill's own content is the same in both slots (MiniPlayerView).
    let isInline = miniPlayer.glassContainer.traitCollection.tabAccessoryEnvironment == .inline
    let wanted: RailLayout
    if isInline {
      wanted = .inline
    } else if traitCollection.horizontalSizeClass == .regular {
      let mainContentView = mainContent()
      let playerWidth = min(
        mainContentView.frame.width - mainContentView.safeAreaInsets.left
          - mainContentView.safeAreaInsets.right,
        600
      )
      wanted = .regularWide(playerWidth)
    } else {
      wanted = .compact
    }
    guard wanted != appliedRailLayout else { return }
    appliedRailLayout = wanted

    switch wanted {
    case .inline:
      // Inline means inside the minimized tab bar, where the system sizes the
      // accessory slot. Fill the slot it gives: width AND height from the
      // host, no fixed 48.
      heightConstraint?.isActive = false
      centerConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      compactWidthConstraint?.isActive = true
      if inlineHeightConstraint == nil, let host = miniPlayer.glassContainer.superview {
        inlineHeightConstraint = miniPlayer.glassContainer.heightAnchor
          .constraint(equalTo: host.heightAnchor)
        inlineHeightConstraint?.priority = UILayoutPriority(999)
      }
      inlineHeightConstraint?.isActive = true
    case let .regularWide(playerWidth):
      inlineHeightConstraint?.isActive = false
      centerConstraint?.isActive = false
      centerConstraint = miniPlayer.glassContainer.safeAreaLayoutGuide.centerXAnchor.constraint(
        equalTo: mainContent().safeAreaLayoutGuide.centerXAnchor,
        constant: 0
      )
      compactWidthConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      regularWidthConstraint = miniPlayer.glassContainer.widthAnchor
        .constraint(equalToConstant: playerWidth)
      regularWidthConstraint?.priority = UILayoutPriority(999)
      centerConstraint?.priority = UILayoutPriority(999)
      regularWidthConstraint?.isActive = true
      centerConstraint?.isActive = true
      heightConstraint?.constant = 60.0
      heightConstraint?.isActive = true
    case .compact:
      inlineHeightConstraint?.isActive = false
      heightConstraint?.constant = 48.0
      heightConstraint?.isActive = true
      centerConstraint?.isActive = false
      regularWidthConstraint?.isActive = false
      compactWidthConstraint?.isActive = true
    }

    miniPlayer.glassContainer.setNeedsLayout()
    miniPlayer.glassContainer.layoutIfNeeded()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    configureTraitChangesForMiniPlayer()
  }

  // MARK: - Mini player presence

  /// The one accessory the mini player lives in, kept while it is off screen.
  private var miniPlayerAccessory: UITabAccessory?

  /// cassette 2026-10-20: the mini player shows only while something is queued. With an
  /// empty queue (nothing played yet, or everything left the phone, BUG-437) the bar's
  /// accessory slot is removed rather than showing "No music playing".
  func refreshMiniPlayerPresence(animated: Bool) {
    guard let miniPlayerAccessory else { return }
    let wanted = appDelegate.player.currentlyPlaying != nil
    let shown = bottomAccessory != nil
    guard wanted != shown else { return }
    setBottomAccessory(wanted ? miniPlayerAccessory : nil, animated: animated)
    guard wanted, let miniPlayer, let host = miniPlayer.glassContainer.superview else { return }
    // Back in a slot: the host-relative constraints point at the old host, so remake them
    // and let the rail pass choose the layout again.
    compactWidthConstraint?.isActive = false
    compactWidthConstraint = miniPlayer.glassContainer.widthAnchor.constraint(equalTo: host.widthAnchor)
    compactWidthConstraint?.priority = UILayoutPriority(999)
    inlineHeightConstraint?.isActive = false
    inlineHeightConstraint = nil
    appliedRailLayout = nil
    configureTraitChangesForMiniPlayer()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    refresh()
    selectedTab = homeTab
    // cassette Patch 053 (Phase H): the initial selection in viewIsAppearing
    // does not fire `tabBarController(_:didSelectTab:previousTab:)`, so we
    // sync the filled-vs-outline icon swap manually for first paint.
    applySelectedTabIcon(selected: selectedTab)
    welcomePopupPresenter.displayInfoPopupsIfNeeded()
  }

  // cassette Patch 053 (Phase H): swap the selected tab's image to its
  // filled variant and reset every other root tab to its outline variant.
  // This is the structural selection cue that replaces the prior color-
  // only differentiation (selected glyph was orange-tinted; now selected =
  // filled SF Symbol, inactive = outline). For LibraryDisplayType items
  // without a filled SF Symbol pair (artists, songs, playlists, etc.),
  // `image` and `outlineImage` are identical so the only selection cue is
  // the existing label weight bump (semibold -> bold) set in CassetteTheme.
  private func applySelectedTabIcon(selected: UITab?) {
    if let homeTab {
      homeTab
        .image = (homeTab === selected) ? TabNavigatorItem.home.selectedIcon : TabNavigatorItem
        .home
        .outlineIcon
    }
    if let libraryGroup {
      // The library group itself is selectable as the "Library" entry.
      libraryGroup.image = (libraryGroup === selected) ? .musicLibrary : .musicLibraryOutline
      // When a descendant library category is the selected tab, also flip
      // that tab's icon to filled and reset its siblings to outline.
      for child in libraryGroup.children {
        guard let item = LibraryDisplayType.createByDisplayName(name: child.title) else { continue }
        child.image = (child === selected) ? item.image : item.outlineImage
      }
    }
    if let searchTab {
      // Search has no filled/outline SF Symbol pair; weight bump on the
      // selected label (set in CassetteTheme.applyGlobalAppearance) is the
      // structural cue for that tab.
      searchTab
        .image = (searchTab === selected) ? TabNavigatorItem.search.selectedIcon : TabNavigatorItem
        .search
        .outlineIcon
    }
  }

  @objc
  func handleLibraryItemsChanged(notification: Notification) {
    refresh()
  }

  func refresh() {
    guard let libraryGroup else { return }
    let config = appDelegate.storage.settings.accounts.getSetting(account.info).read
      .libraryDisplaySettings
    libraryGroup.displayOrderIdentifiers = config.inUse.compactMap { "Tabs.\($0.displayName)" }
    for tab in libraryGroup.displayOrder {
      guard let item = LibraryDisplayType.createByDisplayName(name: tab.title) else { continue }
      if let _ = config.inUse.first(where: { $0 == item }) {
        tab.isHidden = false
      } else {
        tab.isHidden = true
      }
    }
  }

  public func push(vc: UIViewController) {
    guard let libraryGroup else { return }
    // Library first, then the screen on top of it. Pushed into a Library tab that hadn't been
    // opened since launch, the screen became the tab's first and only screen: no back key, and
    // tapping Library didn't lead home (the founder, 2026-10-31, from Now Playing's Go to Album).
    let isLoaded = !(libraryGroup.managingNavigationController?.viewControllers.isEmpty ?? true)
    selectedTab = libraryGroup
    if isLoaded {
      libraryGroup.managingNavigationController?.pushViewController(vc, animated: true)
    } else {
      DispatchQueue.main.async {
        libraryGroup.managingNavigationController?.pushViewController(vc, animated: true)
      }
    }
  }
}

// MARK: UITabBarControllerDelegate

extension TabBarVC: UITabBarControllerDelegate {
  // cassette Patch 053 (Phase H): iOS 18+ tab selection callback. Fires
  // after the user taps any root tab or any descendant in a UITabGroup;
  // we use it to swap the structural filled/outline icon for the newly
  // selected tab and reset its siblings.
  func tabBarController(
    _ tabBarController: UITabBarController,
    didSelectTab selectedTab: UITab,
    previousTab: UITab?
  ) {
    applySelectedTabIcon(selected: selectedTab)
  }

  func tabBarControllerDidEndEditing(_ tabBarController: UITabBarController) {
    var visibleItems = [LibraryDisplayType]()
    guard let libraryGroup else { return }
    for tab in libraryGroup.displayOrder {
      guard let item = LibraryDisplayType.createByDisplayName(name: tab.title) else { continue }
      if !tab.isHidden {
        visibleItems.append(item)
      }
    }
    appDelegate.storage.settings.accounts
      .updateSetting(account.info) { accountSettings in
        accountSettings.libraryDisplaySettings = LibraryDisplaySettings(inUse: visibleItems)
      }
    NotificationCenter.default.post(name: .LibraryItemsChanged, object: nil, userInfo: nil)
  }
}

// MARK: MainSceneHostingViewController

extension TabBarVC: MainSceneHostingViewController {
  public func pushNavLibrary(vc: UIViewController) {
    push(vc: vc)
  }

  public func pushLibraryCategory(vc: UIViewController) {
    guard let libraryGroup else { return }
    libraryGroup.managingNavigationController?.popToRootViewController(animated: false)
    push(vc: vc)
  }

  /// cassette Patch 042: deep-link from Home shelf headers into a
  /// specific Library category. Pops any pushed detail views off
  /// the Library nav stack, asks the root LibraryContainerVC to
  /// switch its dropdown, and selects the Library tab so the user
  /// lands on the requested category in one tap.
  public func switchToLibrary(category: LibraryDisplayType) {
    guard let libraryGroup else { return }
    // The Library screen is built on the tab's first visit and opens on the last category
    // used, so a request made before that visit (Home's RADIO header, right after launch)
    // was dropped and Library opened on, say, Albums. Store the category first: a screen
    // built now opens on it, and one already built switches below.
    appDelegate.storage.settings.accounts.updateSetting(account.info) { accountSettings in
      accountSettings.lastLibraryCategory = category
    }
    let nav = libraryGroup.managingNavigationController
    nav?.popToRootViewController(animated: false)
    if let container = nav?.viewControllers.first as? LibraryContainerVC {
      container.showCategory(category)
    }
    selectedTab = libraryGroup
  }

  func pushTabCategory(tabCategory: TabNavigatorItem) {
    switch tabCategory {
    case .home:
      selectedTab = homeTab
    case .search:
      selectedTab = searchTab
    }
    configureTraitChangesForMiniPlayer()
  }

  func displaySearch() {
    guard let searchTab else { return }
    visualizePopupPlayer(direction: .close, animated: true) {
      self.selectedTab = searchTab
      // The tab's view controller IS the navigation controller (it has no navigation
      // controller of its own), so SearchVC is its root. Reading `.navigationController`
      // here returned nil, and the shortcut never reached the field.
      (searchTab.viewController as? UINavigationController)?
        .popToRootViewController(animated: false)
      Task {
        try await Task.sleep(nanoseconds: 500_000_000)
        if let searchTabVC = (searchTab.viewController as? UINavigationController)?
          .viewControllers.first as? SearchVC {
          searchTabVC.activateSearchBar()
        }
      }
    }
  }

  func getSafeAreaExtension() -> CGFloat {
    0.0
  }
}
