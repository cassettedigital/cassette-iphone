//
//  HomeVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 24.11.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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
import OSLog
import UIKit

// MARK: - HomeVC

final class HomeVC: UICollectionViewController {
  // MARK: - Properties

  private var dataSource: UICollectionViewDiffableDataSource<HomeSection, HomeItem>!
  private let log = OSLog(subsystem: "Amperfy", category: "HomeVC")

  /// phone-taste: the mock's 150pt tiles (`PlayTile`) in its 20pt gutter.
  private static let itemWidth: CGFloat = AlbumCarousel.mockItemWidth
  private static let shelfEstimatedHeight: CGFloat = AlbumShelfView.preferredHeight(for: .mock)

  private var userButton: UIButton?
  private var userBarButtonItem: UIBarButtonItem?
  private let account: Account
  private var accountNotificationHandler: AccountNotificationHandler?
  private let sharedHome: HomeManager
  // cassette: "Syncing your library" banner. Floats fixed at the top of Home
  // (pinned to the scroll view's safe-area guide, so it does not scroll) while a
  // download wave is moving, covering the Resume card. See updateSyncBannerPresentation.
  private let syncBanner = SyncBannerView()
  // cassette: custom pull-to-refresh state. The Resume card shows "Checking for
  // updates" in place (no height change) while a pull-triggered refresh runs.
  private var isCheckingForUpdates = false
  private var pullPastThreshold = false
  /// The Lately mix generation the Mood row was last drawn with (see applySnapshot).
  /// What the made-for-you row was last drawn from (HomeManager.madeForYouSignature).
  private var appliedMadeForYouSignature: [Int]?
  /// The made-for-you row's name it was last drawn under (One Home: the cloud names it).
  private var appliedMadeForYouHeading: String?
  /// Whether the reaching row was last laid out as Deep dive's big card (see applySnapshot).
  private var appliedReachIsDeepDive: Bool?
  /// Each row's name as last drawn ("SHOUT|answer"), so a renamed row gets its header redrawn.
  private var shownHeadings: [HomeSection: String] = [:]

  // MARK: - Init

  init(account: Account) {
    self.account = account
    let appDelegate = (UIApplication.shared.delegate as! AppDelegate)
    self.sharedHome = HomeManager(
      account: account,
      storage: appDelegate.storage,
      getMeta: appDelegate.getMeta,
      eventLogger: appDelegate.eventLogger,
      player: appDelegate.player,
      // cassette (Forgotten Albums): iOS Home builds the anti-recency shelf.
      buildsForgottenShelf: true
    )
    let layout = HomeVC.createLayout()
    super.init(collectionViewLayout: layout)
    HomeManager.live = sharedHome
    sharedHome.applySnapshotCB = { [weak self] in
      guard let self else { return }
      applySnapshot(animated: true)
    }
    // cassette (CarPlay off-window crash): while CarPlay drives playback the phone
    // Home stays alive but off-window; tell HomeManager to defer its rebuilds until
    // Home is actually on screen again (flushed in viewIsAppearing).
    sharedHome.isHostVisible = { [weak self] in self?.viewIfLoaded?.window != nil }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    // ensures that the collection view stops placing items under the sidebar
    collectionView.contentInsetAdjustmentBehavior = .scrollableAxes

    // Pull-to-refresh on Home. A CUSTOM over-pull (see scrollViewDidScroll /
    // scrollViewDidEndDragging) drives it instead of a UIRefreshControl: the stock
    // spinner opens and closes a ~60pt gap at the top on every refresh, and the Home
    // should never change height. The Resume card shows "Checking for updates" in
    // place for the duration instead.
    collectionView.backgroundColor = CassetteTheme.UIColors.bg
    title = "Home"

    accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForActiveAccountChange { [weak self] accountInfo in
      guard let self else { return }
      setupUserNavButton(
        currentAccount: account,
        userButton: &userButton,
        userBarButtonItem: &userBarButtonItem,
        extraLeadingMenuElements: makeHomeMenuExtras()
      )
    }

    configureHomeNavigationBar()
    // cassette Patch 035: the top-right Edit button is removed; the
    // "Edit Home" action lives in the account-button menu now (see
    // `setupUserNavButton` call above), and only the three Cassette
    // shelves remain visible/editable.
    configureCollectionView()
    configureDataSource()
    // cassette redesign (Surface 4): swap in the snapshot-aware layout so
    // the Resume section gets its full-width card geometry. Replaces the
    // raw-value section lookup (which broke once hidden-when-empty shelves
    // shifted the section indices).
    collectionView.setCollectionViewLayout(makeLayout(), animated: false)
    sharedHome.createFetchController()

    // cassette: the sync banner floats fixed at the top of the scroll view (pinned
    // to the safe-area guide, NOT the content guide, so it does not scroll away).
    // Content is inset below it only while it is visible; see updateSyncBannerPresentation.
    syncBanner.isHidden = true
    collectionView.addSubview(syncBanner)
    NSLayoutConstraint.activate([
      syncBanner.topAnchor.constraint(
        equalTo: collectionView.safeAreaLayoutGuide.topAnchor,
        constant: 8
      ),
      syncBanner.leadingAnchor.constraint(
        equalTo: collectionView.safeAreaLayoutGuide.leadingAnchor,
        constant: 16
      ),
      syncBanner.trailingAnchor.constraint(
        equalTo: collectionView.safeAreaLayoutGuide.trailingAnchor,
        constant: -16
      ),
    ])
    // Observe via NotificationCenter.default — that is where CassetteSyncStatus posts.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(cassetteSyncActiveChanged),
      name: .cassetteSyncActiveChanged,
      object: nil
    )

    applySnapshot(animated: false)
    // Reflect a wave that is already moving when Home first appears.
    updateSyncBannerPresentation(animated: false)

    appDelegate.notificationHandler.register(
      self,
      selector: #selector(refreshOfflineMode),
      name: .offlineModeChanged,
      object: nil
    )

    // cassette Layer 3 Phase 3.2: rebuild the Home shelves when Server Mode
    // toggles. The shelves reuse the library FRCs, so recreating their fetch
    // controllers picks up the new ownership predicate.
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(cassetteLibraryFilterChanged),
      name: CassetteLibraryFilterProvider.filterChangedNotification,
      object: nil
    )

    // cassette (BUG-348): re-apply Home when the Mixtape beta opt-in changes on an
    // account sync, so the Mood shelf appears or disappears without a relaunch.
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(cassetteBetaAccessChanged),
      name: CassetteBetaAccess.changedNotification,
      object: nil
    )

    // phone-taste: rebuild MOOD and MORE LIKE when the mood tags or the lately profile
    // arrive (posted on the main actor by LibraryMoods), instead of waiting for the next
    // unrelated recompute.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(cassetteLibraryMoodsChanged),
      name: .cassetteLibraryMoodsChanged,
      object: nil
    )
  }

  // cassette (manual eager tab-bar reveal): drive minimize/expand from scroll
  // direction (see TabBarVC.cassetteUpdateMinimizeForScroll).
  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    (tabBarController as? TabBarVC)?.cassetteUpdateMinimizeForScroll(scrollView)
    // Arm the custom pull-to-refresh once dragged past the threshold at the very top.
    if scrollView.isDragging {
      let pulled = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
      if pulled > Self.pullRefreshThreshold { pullPastThreshold = true }
    }
  }

  // MARK: - Pull to refresh (custom — no UIRefreshControl, so nothing reserves height)

  private static let pullRefreshThreshold: CGFloat = 92

  override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    pullPastThreshold = false
  }

  override func scrollViewDidEndDragging(
    _ scrollView: UIScrollView,
    willDecelerate decelerate: Bool
  ) {
    guard pullPastThreshold, !isCheckingForUpdates else { return }
    pullPastThreshold = false
    triggerCassetteRefresh()
  }

  private func triggerCassetteRefresh() {
    Task { @MainActor in
      setCheckingForUpdates(true)
      // A pull refreshes Home, nothing more (I-P2): it used to ask the computer to rescan its
      // disk and re-upload this phone's whole inventory, up to a minute and a half. Settings
      // keeps Resync Library for that.
      // One Home: a pull asks the cloud for Home now.
      await HomeStore.shared.refresh()
      // Also fold in plays made on
      // the user's OTHER devices so Recent catches up — otherwise cross-device
      // recency only lands on Home-appear / app-foreground, and a track just played
      // on Android won't surface here until then.
      sharedHome.updateFromRemote()
      setCheckingForUpdates(false)
    }
  }

  /// Put the Resume card into (or out of) its in-place "Checking for updates" state.
  /// No new section and no content-inset change, so the Home never changes height.
  /// A no-op when there is no Resume card (fresh install with no history) — the
  /// refresh still runs, just without the in-slot indicator.
  private func setCheckingForUpdates(_ checking: Bool) {
    isCheckingForUpdates = checking
    var snapshot = dataSource.snapshot()
    guard snapshot.sectionIdentifiers.contains(.resume) else { return }
    snapshot.reconfigureItems(snapshot.itemIdentifiers(inSection: .resume))
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  @objc
  private func cassetteLibraryFilterChanged() {
    // Music arrived or left (or Server Mode flipped): the mood index behind MORE LIKE and
    // the Lately tile is out of date. HomeManager rebuilds it off the main thread and
    // meanwhile drops anything that has left the phone.
    sharedHome.invalidateMoodIndex()
    sharedHome.createFetchController()
    applySnapshot(animated: false)
  }

  @objc
  private func cassetteBetaAccessChanged() {
    applySnapshot(animated: false)
  }

  /// New mood tags or a new lately profile: drop the cached mood index and rebuild the
  /// rows. HomeManager defers the rebuild while Home is off screen (isHostVisible), reads
  /// the index without blocking (it is rebuilt off the main thread), and the apply that
  /// follows redraws the Mood row when the Lately mix changed.
  @objc
  private func cassetteLibraryMoodsChanged() {
    sharedHome.invalidateMoodIndex()
    sharedHome.refreshListeningShelves()
  }

  @objc
  private func cassetteSyncActiveChanged() {
    updateSyncBannerPresentation(animated: true)
  }

  /// Show/hide the hub status line to match `CassetteSyncStatus` and inset the content
  /// below it while it is up. Resume stays: a single line does not cover it.
  private func updateSyncBannerPresentation(animated: Bool) {
    // The same name the avatar menu, Settings and the Mac page show (an IP pairing falls back
    // to the hostname the hub reported, then to "your computer").
    let hubName = CassetteSyncStatus.displayHubName(
      serverUrl: appDelegate.storage.settings.accounts.activeSetting.read.loginCredentials?.serverUrl
    )
    let line = CassetteSyncStatus.statusLine(hubName: hubName)
    let active = line != nil
    syncBanner.show(line, isSyncing: CassetteSyncStatus.isHubReachable)

    // The banner's height is content-driven; lay it out, then inset the content by
    // that height plus a small gap so the first shelf clears it.
    view.layoutIfNeeded()
    let topInset = active ? (syncBanner.frame.height + 8) : 0
    collectionView.contentInset.top = topInset
    collectionView.verticalScrollIndicatorInsets.top = topInset

    applySnapshot(animated: animated)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    configureHomeNavigationBar()
  }

  private func configureHomeNavigationBar() {
    title = "Home"
    // cassette: Home wears its name inline, the way Library wears "Albums".
    // The large title used to eat a full title-height band at the top and
    // then animate away on the first scroll - two different-looking Homes for
    // the same screen. Inline means the header never changes and the first shelf
    // sits that much higher. phone-taste: the inline title is `.navTitle`, the
    // mock's nav-bar title (`.navTitle`, SemiBold); the Library tab makes the same
    // change, so the two tabs' titles still match.
    navigationItem.largeTitleDisplayMode = .never
    navigationController?.navigationBar.prefersLargeTitles = false
    let appearance = UINavigationBarAppearance()
    appearance.configureWithDefaultBackground()
    appearance.titleTextAttributes = [
      .font: UIFont.cassette(.navTitle),
      .foregroundColor: UIColor.cassette(.textPrimary),
    ]
    navigationItem.standardAppearance = appearance
    navigationItem.scrollEdgeAppearance = appearance
    if #available(iOS 15.0, *) {
      navigationItem.compactAppearance = appearance
    }
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    // cassette (CarPlay off-window crash): run one coalesced recompute if any were
    // deferred while Home was off-window (e.g. a drive's worth of track changes).
    sharedHome.recomputeIfDeferred()
    sharedHome.updateFromRemote()
    // cassette (Forgotten Albums): opportunistic roll-off of aged hot-log rows
    // into the durable cold counters, then stamp the shelf's current impressions
    // now that Home is on screen.
    appDelegate.storage.main.library.rollOffAgedHomeShelfEvents(for: account)
    recordForgottenShelfImpressionIfVisible()
    // What's on at the Radio row's stations, read while Home is up (I-R1).
    if !watchingOnNow {
      watchingOnNow = true
      RadioOnNow.shared.begin()
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if watchingOnNow {
      watchingOnNow = false
      RadioOnNow.shared.end()
    }
  }

  private var watchingOnNow = false

  /// cassette (Forgotten Albums): stamp `lastSurfacedOnHomeDate` + write a hot-log
  /// "surfaced" row for the albums currently on the shelf. Only when actually on
  /// screen; the storage layer is per-day idempotent, so this is safe to call on
  /// every appearance / snapshot.
  private func recordForgottenShelfImpressionIfVisible() {
    guard viewIfLoaded?.window != nil else { return }
    let ids = (sharedHome.data[.forgottenAlbums] ?? [])
      .compactMap { ($0.playableContainable as? Album)?.id }
    guard !ids.isEmpty else { return }
    appDelegate.storage.main.library.recordForgottenAlbumsSurfaced(albumIds: ids, for: account)
  }

  // MARK: - Layout

  /// Placeholder used between init and viewDidLoad (before the diffable
  /// data source exists). Resolves sections by raw value, which is good
  /// enough for the empty first pass; `makeLayout()` replaces it.
  private static func createLayout() -> UICollectionViewCompositionalLayout {
    UICollectionViewCompositionalLayout { sectionIndex, _ in
      Self.sectionLayout(for: HomeSection(rawValue: sectionIndex))
    }
  }

  /// cassette redesign (Surface 4): snapshot-aware layout. Resolves the
  /// section enum from the data source (hidden-when-empty shelves shift
  /// indices) so the Resume section can take a full-width card row while
  /// the shelves keep the 160pt orthogonal carousel rhythm.
  private func makeLayout() -> UICollectionViewCompositionalLayout {
    UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
      let section = self?.dataSource.snapshot().sectionIdentifiers.element(at: sectionIndex)
      return Self.sectionLayout(
        for: section,
        reachIsDeepDive: self?.sharedHome.reachShelf?.isDeepDive ?? false
      )
    }
  }

  private static func sectionLayout(
    for section: HomeSection?,
    reachIsDeepDive: Bool = false
  )
    -> NSCollectionLayoutSection? {
    guard let section else { return nil }

    // cassette Patch 025 / Polish 2 (A2): top inset is 0 (the SectionHeaderView
    // owns the vertical rhythm) and supplementariesFollowContentInsets is false
    // so the header's own leading lines up with the first card column.
    // phone-taste: the mock's `.shelf` (padding 0 20 2); the next row's heading brings
    // its own 28pt of air (`.block`).
    let contentInsets = NSDirectionalEdgeInsets(
      top: 0,
      leading: AlbumCarousel.mockGutter,
      bottom: 2,
      trailing: AlbumCarousel.mockGutter
    )

    // cassette: .moodDoors is header-only (zero HomeItems — see
    // HomeSection.swift) — a near-zero item group, all real height comes
    // from the boundary header that hosts MoodDoorRow's SwiftUI content.
    // One Home: All shelves is header-only too, its heading and chevron the whole row.
    if section == .moodDoors || section == .allShelves {
      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .absolute(1)
      )
      let item = NSCollectionLayoutItem(layoutSize: itemSize)
      let groupSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .absolute(1)
      )
      let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
      let sectionLayout = NSCollectionLayoutSection(group: group)
      sectionLayout.contentInsets = NSDirectionalEdgeInsets(
        top: 0,
        leading: 0,
        bottom: 0,
        trailing: 0
      )
      sectionLayout.supplementariesFollowContentInsets = false
      // phone-taste: 28 above the heading, the heading, 12, a 150pt tile with its name and
      // song count under it (as an album tile), 2. All shelves is the heading alone.
      let headerSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(section == .allShelves ? CassetteHeading.tableHeaderHeight : 272)
      )
      let header = NSCollectionLayoutBoundarySupplementaryItem(
        layoutSize: headerSize,
        elementKind: UICollectionView.elementKindSectionHeader,
        alignment: .top
      )
      header.pinToVisibleBounds = false
      header.zIndex = 1
      sectionLayout.boundarySupplementaryItems = [header]
      return sectionLayout
    }

    // One Home: Deep dive's one record is a big card across the page (the sketch's 358pt
    // cover on a 390pt phone), under its heading. It sizes itself from its width.
    if section == .reach, reachIsDeepDive {
      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(440)
      )
      let item = NSCollectionLayoutItem(layoutSize: itemSize)
      let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
      let sectionLayout = NSCollectionLayoutSection(group: group)
      sectionLayout.contentInsets = contentInsets
      sectionLayout.supplementariesFollowContentInsets = false
      let header = NSCollectionLayoutBoundarySupplementaryItem(
        layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(44)),
        elementKind: UICollectionView.elementKindSectionHeader,
        alignment: .top
      )
      header.zIndex = 1
      sectionLayout.boundarySupplementaryItems = [header]
      return sectionLayout
    }

    // Patch 110 (3b): album/artist shelves use the shared carousel layout —
    // the same component the artist detail embeds (one carousel, two callers).
    guard section == .resume else {
      return AlbumCarousel.makeShelfSection(
        itemWidth: itemWidth,
        estimatedHeight: shelfEstimatedHeight,
        contentInsets: contentInsets,
        interGroupSpacing: 12,
        includeHeader: true
      )
    }

    // Resume: a single full-width card lit by its record (no orthogonal scrolling).
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .fractionalHeight(1.0)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)
    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .absolute(ResumeCardCell.cardHeight)
    )
    let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

    // phone-taste: no clock greeting above the card (the mock dropped it). The card
    // sits 18pt under the nav bar in the 20pt gutter (`.resume`, margin 18 20 0); the
    // first row's heading brings its own 28pt.
    let sectionLayout = NSCollectionLayoutSection(group: group)
    sectionLayout.contentInsets = NSDirectionalEdgeInsets(
      top: 18,
      leading: AlbumCarousel.mockGutter,
      bottom: 0,
      trailing: AlbumCarousel.mockGutter
    )
    return sectionLayout
  }

  // MARK: - CollectionView Setup

  private func configureCollectionView() {
    collectionView.backgroundColor = CassetteTheme.UIColors.bg
    collectionView.register(
      UINib(nibName: AlbumCollectionCell.typeName, bundle: .main),
      forCellWithReuseIdentifier: AlbumCollectionCell.typeName
    )
    // cassette Patch 038: ArtistCircleCollectionCell is purely
    // programmatic — register the class directly instead of a XIB.
    collectionView.register(
      ArtistCircleCollectionCell.self,
      forCellWithReuseIdentifier: ArtistCircleCollectionCell.typeName
    )
    // cassette redesign (Surface 4): full-width Resume glass card.
    collectionView.register(
      ResumeCardCell.self,
      forCellWithReuseIdentifier: ResumeCardCell.typeName
    )
    // cassette 2026-10-13: the Radio shelf's station card (programmatic).
    collectionView.register(
      RadioShelfCell.self,
      forCellWithReuseIdentifier: RadioShelfCell.typeName
    )
    collectionView.register(
      SectionHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: SectionHeaderView.reuseID
    )
    // cassette: the Mood shelf's header IS its content (zero HomeItems) —
    // a distinct reuse identifier from SectionHeaderView, not a style
    // variant of it, since it hosts SwiftUI rather than a title label.
    collectionView.register(
      MoodDoorsHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: MoodDoorsHeaderView.reuseID
    )
    // One Home: Deep dive's big card, and Nostalgia's mix among the reaching row's records.
    collectionView.register(
      DeepDiveCardCell.self,
      forCellWithReuseIdentifier: DeepDiveCardCell.typeName
    )
    collectionView.register(ReachMixCell.self, forCellWithReuseIdentifier: ReachMixCell.typeName)
  }

  // MARK: - Data Source

  private func configureDataSource() {
    dataSource = UICollectionViewDiffableDataSource<
      HomeSection,
      HomeItem
    >(collectionView: collectionView) { [unowned self] collectionView, indexPath, item in
      let section = dataSource.snapshot().sectionIdentifiers.element(at: indexPath.section)
      // phone-taste: every cover plays in one tap (approved phone mock 2026-10-20). The
      // Resume card's disc resumes; each album, playlist and artist tile below carries the
      // 34pt play disc, and its body still opens the page. Radio tiles tune in on a tap.
      if section == .resume {
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: ResumeCardCell.typeName,
          for: indexPath
        ) as! ResumeCardCell
        let containable = item.playableContainable
        // HomeManager works the line out once per recompute, so redrawing the card on
        // every apply costs nothing.
        let line = sharedHome.resumeLine.flatMap { $0.stableID == item.stableID ? $0.text : nil }
        cell.display(container: containable, resumeLine: line ?? containable.subtitle)
        // Reflect an in-flight pull-to-refresh: the card shows "Checking for
        // updates" in place instead of a height-changing pull spinner.
        cell.setChecking(isCheckingForUpdates)
        cell.onPlayTapped = { [weak self] in
          guard let self else { return }
          // Patch 110 (2b): resume the persisted queue at its last position
          // instead of restarting the container from track 0. The player
          // restores its queue + musicIndex on launch; play() resumes that
          // current track and we seek it to its saved playProgress (the
          // backend defers the seek until the item is ready). The seek is done
          // explicitly here so ONLY the Resume card resumes mid-track - the
          // global isPlayerSongPlaybackResumeEnabled setting is left untouched.
          //
          // phone-taste: the card plays what it shows. It resumes mid-track ONLY when
          // the player's current song belongs to the card's record (the same album, a
          // song in the playlist, a song by the artist). Anything else, a radio
          // station or a podcast included, plays the card's record from the top, with
          // only the songs on this phone.
          let player = appDelegate.player
          if player.playerMode == .music, let resumeTrack = currentSong(in: containable) {
            player.play()
            if resumeTrack.playProgress > 0 {
              player.seek(toSecond: Double(resumeTrack.playProgress))
            }
          } else {
            // One Home: a record last played on another device picks up at the song it
            // was on there.
            OneTapPlay.play(containable, startingAt: sharedHome.resumeStartSong)
          }
        }
        return cell
      }
      if section == .reach, let mixID = item.mixID {
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: ReachMixCell.typeName,
          for: indexPath
        ) as! ReachMixCell
        if let mix = sharedHome.reachMix(id: mixID) {
          cell.display(
            mix: mix,
            open: { [weak self] in self?.openMadeForYou(mix) },
            play: { MoodDoorRow.play(mix) }
          )
        }
        return cell
      }
      if section == .reach, sharedHome.reachShelf?.isDeepDive == true,
         let album = item.playableContainable as? Album {
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: DeepDiveCardCell.typeName,
          for: indexPath
        ) as! DeepDiveCardCell
        cell.display(album: album)
        cell.onPlayTapped = { OneTapPlay.play(album) }
        return cell
      }
      if let radio = item.playableContainable as? Radio {
        // cassette 2026-10-21: the tile opens the station's page (didSelectItemAt); the
        // disc tunes in, with the shelf as the context, like the record tiles.
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: RadioShelfCell.typeName,
          for: indexPath
        ) as! RadioShelfCell
        cell.display(radio: radio, info: RadioCatalog.shared.station(forStreamUrl: radio.url))
        cell.onPlayTapped = { [weak self] in self?.tuneIn(radio) }
        return cell
      }
      if let artist = item.playableContainable as? Artist {
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: ArtistCircleCollectionCell.typeName,
          for: indexPath
        ) as! ArtistCircleCollectionCell
        // The disc shuffles the artist (OneTapPlay); the circle opens the artist page.
        cell.onPlayTapped = { OneTapPlay.play(artist) }
        cell.display(artist: artist, showsPlayOverlay: true, metrics: .homeShelf)
        return cell
      }
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: AlbumCollectionCell.typeName,
        for: indexPath
      ) as! AlbumCollectionCell
      let container = item.playableContainable
      // Set before display(): the tile reads them while it binds, and prepareForReuse
      // clears them. The disc plays an album from the top and a playlist in order, and
      // Home stays put (the mini player appears).
      if container is Album || container is Playlist {
        cell.showsPlayOverlay = true
        cell.onPlayTapped = { OneTapPlay.play(container) }
      }
      cell.display(
        container: container,
        rootView: self,
        itemWidth: Self.itemWidth,
        initialIndexPath: indexPath
      )
      return cell
    }

    dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
      guard kind == UICollectionView.elementKindSectionHeader,
            let snapshotSection = self?.dataSource.snapshot().sectionIdentifiers
            .element(at: indexPath.section)
      else {
        return nil
      }

      if snapshotSection == .moodDoors {
        guard let moodHeader = collectionView.dequeueReusableSupplementaryView(
          ofKind: kind,
          withReuseIdentifier: MoodDoorsHeaderView.reuseID,
          for: indexPath
        ) as? MoodDoorsHeaderView, let self else { return nil }
        // phone-taste: the made-for-you tiles show and play the playlists HomeManager keeps.
        // The row never builds a mix or a mood index itself; a tile's picture opens it.
        let heading = Self.heading(for: .moodDoors, cloud: sharedHome.cloudHeadings[.moodDoors])
        moodHeader.configure(
          parentViewController: self,
          mixes: sharedHome.madeForYouMixes,
          shout: heading.shout,
          answer: heading.answer,
          onOpen: { [weak self] mix in self?.openMadeForYou(mix) }
        )
        return moodHeader
      }

      guard let header = collectionView.dequeueReusableSupplementaryView(
        ofKind: kind,
        withReuseIdentifier: SectionHeaderView.reuseID,
        for: indexPath
      ) as? SectionHeaderView
      else {
        return nil
      }
      // phone-taste: every row title in two voices, the shout and its answer. One Home: the
      // cloud's names, drawn as they come.
      let heading = Self.heading(for: snapshotSection, cloud: self?.sharedHome.cloudHeadings[snapshotSection])
      header.configure(shout: heading.shout, answer: heading.answer)
      // cassette Patch 035: every shelf is deterministic now; no
      // refresh button surfaces on any header.
      header.showsRefreshButton = false
      header.setRefreshHandler(nil)
      // cassette Patch 042: header tap navigates Playlists / Albums /
      // Artists into the matching Library category. Resume + Recent stay
      // presentational (handler nil → chevron hides). One Home: the reaching row and the
      // All shelves link open All shelves.
      header.tapHandler = self?.tapHandler(for: snapshotSection)
      return header
    }
  }

  /// phone-taste: a Home row's title in two voices (approved phone mock 2026-10-20: "rows
  /// of music, renamed and nothing else"). Home's own copy, deliberately not
  /// `HomeSection.title`: CarPlay, the Home editor and the Radio play context read that.
  /// Rows the mock does not draw get the shout alone.
  private static func heading(
    for section: HomeSection,
    cloud: (shout: String, answer: String)? = nil,
    now: Date = Date()
  )
    -> (shout: String, answer: String?) {
    // One Home: the cloud names every row it sends (no reason line under any of them).
    if let cloud {
      return (cloud.shout.uppercased(), cloud.answer.isEmpty ? nil : cloud.answer)
    }
    switch section {
    case .onRepeat: return ("ON REPEAT", "lately")
    case .aroundNow: return (ListeningShelves.aroundNowTitle(now: now).uppercased(), "around now")
    case .moreLikeLately: return ("MORE LIKE", "this month")
    case .fromYourMixes: return ("FROM", "your mixes")
    case .forgottenAlbums: return ("ALBUMS", nil)
    case .recent: return ("RECENT", nil)
    case .radios: return ("RADIO", nil)
    case .yourPlaylists: return ("PLAYLISTS", nil)
    case .recentlyPlayedArtists: return ("ARTISTS", nil)
    case .moodDoors: return ("PLAYLISTS", "made for you")
    default: return (section.title.uppercased(), nil)
    }
  }

  // MARK: - Made for you

  /// Opens a made-for-you playlist's page (founder, 2026-10-21: "I'd love to see what's
  /// inside!").
  private func openMadeForYou(_ mix: HomeManager.MadeForYouMix) {
    navigationController?.pushViewController(MixDetailVC(account: account, mix: mix), animated: true)
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  /// One Home: every shelf made today.
  private func openAllShelves() {
    navigationController?.pushViewController(
      AllShelvesVC(account: account, cloudHome: sharedHome.cloudHome),
      animated: true
    )
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  // MARK: - Resume

  /// The player's current song when it belongs to `container`: the same album, a song in
  /// the playlist, or a song by the artist (its own artist or its album's). Asked once,
  /// when the Resume disc is tapped. The card's second line comes from HomeManager.
  private func currentSong(in container: PlayableContainable) -> Song? {
    guard let song = appDelegate.player.currentMusicItem?.asSong,
          HomeManager.song(song, belongsTo: container)
    else { return nil }
    return song
  }

  /// cassette Patch 042: returns the handler that fires when the
  /// shelf header is tapped, or nil if the header is presentational.
  private func tapHandler(for section: HomeSection) -> (() -> ())? {
    if section == .reach || section == .allShelves {
      return { [weak self] in self?.openAllShelves() }
    }
    let category: LibraryDisplayType
    switch section {
    case .yourPlaylists: category = .playlists
    // cassette: the "Albums" shelf on Home is `.forgottenAlbums` (retitled),
    // not `.recentlyAdded` — that swap happened when the shelf was reworked
    // and this map was never updated, so the one shelf actually on screen
    // called "Albums" was the only typed shelf you couldn't tap into.
    // `.recentlyAdded` stays mapped for the legacy/editor path.
    case .forgottenAlbums, .recentlyAdded: category = .albums
    case .recentlyPlayedArtists: category = .artists
    case .radios: category = .radios
    // `.recent` is deliberately presentational: it mixes albums, playlists
    // and artists, so there is no single Library category to land on.
    default: return nil
    }
    return { [weak self] in
      AppDelegate.mainWindowHostVC?.switchToLibrary(category: category)
      _ = self
    }
  }

  /// cassette Patch 036: per-shelf hide-when-empty. We iterate the
  /// configured order but only append sections with content, so
  /// headers vanish for empty shelves (Resume, Your Playlists,
  /// Recently Added all hide independently). The full-screen empty
  /// state still kicks in when every shelf is empty.
  private func applySnapshot(animated: Bool = true) {
    var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeItem>()
    var totalItems = 0
    // cassette: a diffable snapshot HARD-crashes (SIGTRAP) on a duplicate section
    // or item identifier. Shelf builders already dedup by stableID, but guard the
    // one render chokepoint too so a single missed dedup upstream degrades to a
    // dropped repeat instead of taking the whole app down. Belt to updatePlaylists'
    // suspenders after the applySnapshot crash cluster (build 2.1.1(3)).
    var seenSections = Set<HomeSection>()
    for section in sharedHome.orderedVisibleSections {
      guard seenSections.insert(section).inserted else { continue }
      // cassette: .moodDoors is a static, always-present header-only
      // section (zero HomeItems by design — see HomeSection.swift) — append
      // it (beta accounts only, BUG-348) instead of via sharedHome.data, which it never
      // populates, and skip the empty-shelf guard below that every other
      // section relies on to hide itself when it has nothing to show.
      if section == .moodDoors {
        // cassette (BUG-348): the mood doors render only for accounts in the
        // Mixtape beta. The door API answers 404 otherwise, so an opted-out
        // account must never see tiles that can only fail.
        // phone-taste: the row shows only when there is a made-for-you playlist to play
        // (never an empty row). Founder, 2026-10-21: the mood mixes are built on the phone
        // now, so the row no longer depends on the Mixtape beta. This reads the playlists
        // HomeManager keeps (built from the mood index LatelyLibrary builds off the main
        // thread). Never call LatelyLibrary.snapshot here: on a cache miss it builds the
        // index on the main thread, and this also runs from the sync banner and beta paths.
        guard !sharedHome.madeForYouMixes.isEmpty else { continue }
        snapshot.appendSections([section])
        continue
      }
      // One Home: the All shelves link is header-only too, shown when today has a shelf
      // the phone holds records of.
      if section == .allShelves {
        guard sharedHome.allShelvesCount > 0 else { continue }
        snapshot.appendSections([section])
        continue
      }
      var seenItemIDs = Set<String>()
      let items = (sharedHome.data[section] ?? []).filter {
        seenItemIDs.insert($0.stableID).inserted
      }
      guard !items.isEmpty else { continue }
      snapshot.appendSections([section])
      snapshot.appendItems(items, toSection: section)
      totalItems += items.count
    }
    let current = dataSource.snapshot()
    // phone-taste: redraw the Resume card on every apply, so its song line follows the
    // track (a new track inside the same album keeps the item's identity). The line is
    // read from HomeManager, so this is cheap. Only items already on screen are
    // reconfigured; a new one is configured as it is inserted.
    if snapshot.sectionIdentifiers.contains(.resume) {
      let shown = snapshot.itemIdentifiers(inSection: .resume)
        .filter { current.indexOfItem($0) != nil }
      if !shown.isEmpty { snapshot.reconfigureItems(shown) }
    }
    // phone-taste: the Mood row is SwiftUI hosted in a header, so it only picks up a new
    // Lately mix when the header is rebuilt. Reload the section when the mix changed; its
    // generation moves only when its songs or its covers do, so a play, a pause or a cache
    // expiry never snaps the row back to its start.
    let madeForYouSignature = sharedHome.madeForYouSignature
    let madeForYouHeading = sharedHome.cloudHeadings[.moodDoors].map { "\($0.shout)|\($0.answer)" } ?? ""
    if madeForYouSignature != appliedMadeForYouSignature || madeForYouHeading != appliedMadeForYouHeading,
       snapshot.sectionIdentifiers.contains(.moodDoors),
       current.sectionIdentifiers.contains(.moodDoors) {
      snapshot.reloadSections([.moodDoors])
    }
    appliedMadeForYouSignature = madeForYouSignature
    appliedMadeForYouHeading = madeForYouHeading
    // One Home: the cloud renames rows during the day (the time-of-day row, the reaching
    // row's shelf), and a header is only redrawn when its section is reloaded.
    func headingKey(_ section: HomeSection) -> String {
      let heading = Self.heading(for: section, cloud: sharedHome.cloudHeadings[section])
      return "\(heading.shout)|\(heading.answer ?? "")"
    }
    let renamed = snapshot.sectionIdentifiers.filter { section in
      section != .moodDoors && section != .resume && current.sectionIdentifiers.contains(section)
        && shownHeadings[section] != nil && headingKey(section) != shownHeadings[section]
    }
    if !renamed.isEmpty { snapshot.reloadSections(renamed) }
    for section in snapshot.sectionIdentifiers {
      shownHeadings[section] = headingKey(section)
    }
    // The reaching row turning into Deep dive's big card (or back) is a new layout and new
    // cells, even for a record it keeps.
    let reachIsDeepDive = sharedHome.reachShelf?.isDeepDive ?? false
    let relayout = appliedReachIsDeepDive != nil && appliedReachIsDeepDive != reachIsDeepDive
    appliedReachIsDeepDive = reachIsDeepDive
    if relayout, snapshot.sectionIdentifiers.contains(.reach), current.sectionIdentifiers.contains(.reach),
       !renamed.contains(.reach) {
      snapshot.reloadSections([.reach])
    }
    // cassette (CarPlay off-window crash): never run the animated diff while Home is
    // off-window (CarPlay is the active scene). An animated apply against a collection
    // view that is not in any window is the production SIGTRAP; a non-animated apply
    // still keeps the data current for when Home reappears.
    let shouldAnimate = animated && (viewIfLoaded?.window != nil)
    dataSource.apply(snapshot, animatingDifferences: shouldAnimate)
    if relayout { collectionView.collectionViewLayout.invalidateLayout() }
    refreshEmptyLibraryState(hasItems: totalItems > 0)
    // cassette (Forgotten Albums): the shelf may have just populated while Home
    // is visible — record the impression (per-day idempotent).
    recordForgottenShelfImpressionIfVisible()
  }

  /// cassette Patch 020: Cassette-flavored "no music yet" empty state on
  /// the Home tab. Triggered when the library has no playable items
  /// across all visible sections (the player still shows up either way).
  private func refreshEmptyLibraryState(hasItems: Bool) {
    contentUnavailableConfiguration = hasItems ? nil : Self.emptyLibraryConfig
  }

  /// cassette Patch 036: only shows when Resume, Your Playlists, and Recently Added are all
  /// empty (fresh install, no library, no listening history). The lists' own empty line, from
  /// the shared empty state (I-W3).
  private static var emptyLibraryConfig: UIContentUnavailableConfiguration { .cassetteOnDeviceEmpty }

  @objc
  private func refreshOfflineMode() {
    os_log("HomeVC: OfflineModeChanged", log: self.log, type: .info)
    sharedHome.createFetchController()
  }

  /// cassette Patch 035: builds the Home tab's own entry in the account-button menu,
  /// "Edit Home", which now sits beside Settings (the account menu places it). Other
  /// tabs pass no extras and see the unmodified account menu.
  private func makeHomeMenuExtras() -> [UIMenuElement] {
    let editHome = UIAction(
      title: "Edit Home",
      image: CassetteIcon.adjust.uiImage,
      handler: { [weak self] _ in
        self?.presentSectionEditor()
      }
    )
    return [editHome]
  }

  /// cassette Patch 035: wired from the account-button menu's
  /// "Edit Home" entry. The legacy `editSectionsTapped` `@objc`
  /// wrapper went away with the top-right bar button.
  func presentSectionEditor() {
    let editor = HomeEditorVC(current: sharedHome.orderedVisibleSections) { [weak self] newOrder in
      guard let self else { return }
      // phone-taste: the editor only shows and hides the editable rows, so Done must
      // keep every other row (Resume, On Repeat, the time-of-day row, Mood, More Like,
      // Radio) where the default order puts them. It used to set [.resume] + the
      // editor's rows, which dropped all of those until the next launch.
      let merged = Self.homeSections(keepingEditable: newOrder)
      // One Home: the cloud orders Home; this only changes the phone's stand-in.
      sharedHome.standInSections = merged
      if let accountInfo = appDelegate.storage.settings.accounts.active {
        appDelegate.storage.settings.accounts.updateSetting(accountInfo) { accountSettings in
          accountSettings.homeSections = merged
        }
      }
      applySnapshot(animated: true)

      sharedHome.createFetchController()
      sharedHome.updateFromRemote()
    }
    let nav = UINavigationController(rootViewController: editor)
    nav.modalPresentationStyle = .formSheet
    present(nav, animated: true)
  }

  /// Home's rows after Edit Home: the default order, with the editable rows the person
  /// hid taken out and the default's editable slots filled, in order, by the editable
  /// rows they kept, in their order. Every other row stays where the default puts it.
  static func homeSections(keepingEditable kept: [HomeSection]) -> [HomeSection] {
    let editable = Set(HomeSection.editableSections)
    var seen = Set<HomeSection>()
    var queue = kept.filter { editable.contains($0) && seen.insert($0).inserted }
    var result = [HomeSection]()
    for section in HomeSection.defaultValue {
      if editable.contains(section) {
        if !queue.isEmpty { result.append(queue.removeFirst()) }
      } else {
        result.append(section)
      }
    }
    return result
  }

  // MARK: - Selection Handling

  override func collectionView(
    _ collectionView: UICollectionView,
    didSelectItemAt indexPath: IndexPath
  ) {
    guard let selectedItem = dataSource.itemIdentifier(for: indexPath) else { return }
    // One Home: Nostalgia's mix opens its page (its picture's own tap does the same).
    if let mixID = selectedItem.mixID {
      if let mix = sharedHome.reachMix(id: mixID) { openMadeForYou(mix) }
      return
    }
    let playableContainer = selectedItem.playableContainable

    // cassette (Forgotten Albums): "opened from shelf" intent stamp (hot-log row
    // only; Home navigates on tap, so this is not a confirmed play — play-origin
    // attribution is deferred by design).
    if selectedItem.section == .forgottenAlbums, let album = playableContainer as? Album {
      appDelegate.storage.main.library.recordForgottenAlbumOpened(albumId: album.id)
    }

    // cassette Patch 042: every Home card navigates to detail. The
    // bottom-right play overlay (Patch 043) is the dedicated
    // play affordance, and the mini player still resumes the live
    // queue. The legacy "Resume[0] tap = play" branch is gone with
    // the Resume shelf itself.
    if let album = playableContainer as? Album {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let artist = playableContainer as? Artist {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let playlist = playableContainer as? Playlist {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPlaylistDetail(account: account, playlist: playlist),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let podcastEpisode = playableContainer as? PodcastEpisode,
              let podcast = podcastEpisode.podcast {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPodcastDetail(
          account: account,
          podcast: podcast,
          episodeToScrollTo: podcastEpisode
        ),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let podcast = playableContainer as? Podcast {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPodcastDetail(account: account, podcast: podcast),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let radio = playableContainer as? Radio {
      // cassette 2026-10-21: a station opens its page; one the registry does not know
      // has none, so its tap still tunes in.
      if let info = RadioCatalog.shared.station(forStreamUrl: radio.url) {
        navigationController?.pushViewController(
          RadioStationVC(account: account, station: info),
          animated: true
        )
        navigationController?.navigationBar.prefersLargeTitles = false
      } else {
        tuneIn(radio)
      }
    } else if let genre = playableContainer as? Genre {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToGenreDetail(account: account, genre: genre),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    }
  }
}

extension HomeVC {
  /// Tune in with the whole Radio shelf as the context, so Next / Previous move along it.
  fileprivate func tuneIn(_ radio: Radio) {
    let shelf = dataSource.snapshot().itemIdentifiers(inSection: .radios)
      .compactMap { $0.playableContainable as? Radio }
    let index = shelf.firstIndex(where: { $0.id == radio.id }) ?? 0
    appDelegate.player.play(context: PlayContext(
      name: HomeSection.radios.title,
      index: index,
      playables: shelf.isEmpty ? [radio] : shelf
    ))
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemAt indexPath: IndexPath,
    point: CGPoint
  )
    -> UIContextMenuConfiguration? {
    guard let item = dataSource.itemIdentifier(for: indexPath), item.mixID == nil else { return nil }
    let containable = item.playableContainable

    let identifier = NSString(string: TableViewPreviewInfo(
      playableContainerIdentifier: containable.containerIdentifier,
      indexPath: indexPath
    ).asJSONString())
    return UIContextMenuConfiguration(identifier: identifier, previewProvider: {
      let vc = EntityPreviewVC()
      vc.display(container: containable, on: self)
      Task { @MainActor in
        do {
          try await containable.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          // a preview that couldn't refresh keeps what it had; nothing to tell the person (I-S5)
          self.appDelegate.eventLogger.report(topic: "Preview Sync", error: error, isBackground: true)
        }
        vc.refresh()
      }
      return vc
    }) { suggestedActions in
      // phone-taste: the long-press Play queues what the play disc would, only the
      // songs on this phone (OneTapPlay), never the record's whole server track list.
      let playIndexCB: GetPlayContextCallback = {
        PlayContext(
          containable: containable,
          index: 0,
          playables: OneTapPlay.playables(of: containable)
        )
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

// MARK: - SectionHeaderView

final class SectionHeaderView: UICollectionReusableView {
  static let reuseID = "SectionHeaderView"

  private let refreshButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.setImage(UIImage.refresh, for: .normal)
    // cassette Patch 048 (Phase C): refresh button in shelf headers pins
    // to ink2 explicitly. Previously inherited the window tint (orange);
    // now reads as a quiet secondary action consistent with the chevron
    // glyph on the other shelf headers.
    btn.tintColor = CassetteTheme.UIColors.ink2
    btn.isHidden = true
    btn.accessibilityLabel = "Refresh Randoms"
    return btn
  }()

  /// phone-taste: the row title in two voices on one line (CassetteHeading): the Barlow
  /// shout in ink, then the answer in the serif italic in brand orange (Home row answers
  /// only). It truncates at the tail rather than push the chevron off the row.
  private let titleLabel: UILabel = {
    let lbl = CassetteHeading.makeLabel()
    lbl.setContentHuggingPriority(.required, for: .horizontal)
    lbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return lbl
  }()

  // cassette Patch 042: chevron-right indicator that surfaces only
  // when the header has a `tapHandler` (Playlists / Albums / Artists
  // navigate to the matching Library category). Hidden on Recent so
  // it stays a presentational shelf.
  private let chevronImageView: UIImageView = {
    let iv = UIImageView()
    iv.translatesAutoresizingMaskIntoConstraints = false
    // cassette: the chevron was a hairline — default (regular) weight scaled
    // into a 12x16 box next to 22pt Barlow Condensed Bold, so it read as a
    // stray tick rather than an affordance. Bold at 13pt matches the stroke
    // of the title it sits beside, and ink (not ink2) stops it looking
    // half-disabled. The Library dropdown chevron is semibold/12 for the same
    // reason.
    iv.image = CassetteIcon.chevronRight.symbolImage(size: .small, weight: .bold)
    iv.tintColor = UIColor.cassette(.textPrimary)
    // `.center`, not `.scaleAspectFit`: aspect-fit would rescale the glyph to
    // the box and throw away the point size we just set.
    iv.contentMode = .center
    iv.isHidden = true
    return iv
  }()

  // cassette Patch 042: invisible UIControl spans title + chevron so
  // the entire trailing region is tappable, matching the Apple Music
  // / Files-style "tap whole header to see all" affordance.
  private lazy var tapButton: UIControl = {
    let ctl = UIControl()
    ctl.translatesAutoresizingMaskIntoConstraints = false
    ctl.addAction(UIAction { [weak self] _ in self?.tapHandler?() }, for: .touchUpInside)
    return ctl
  }()

  var showsRefreshButton: Bool {
    get { !refreshButton.isHidden }
    set { refreshButton.isHidden = !newValue }
  }

  func setRefreshHandler(_ handler: (() -> ())?) {
    refreshButton.removeTarget(nil, action: nil, for: .allEvents)
    guard let handler else { return }
    refreshButton.addAction(UIAction { _ in handler() }, for: .touchUpInside)
  }

  /// cassette Patch 042: per-shelf navigation hook. When non-nil,
  /// the chevron indicator surfaces, the header becomes a hit
  /// target, and tapping fires the handler (e.g. switch the Library
  /// tab to .albums).
  var tapHandler: (() -> ())? {
    didSet {
      let isTappable = tapHandler != nil
      chevronImageView.isHidden = !isTappable
      tapButton.isUserInteractionEnabled = isTappable
      tapButton.accessibilityTraits = isTappable ? .button : []
      // A hidden chevron gives its room back to the title (see setupSubviews).
      if isTappable {
        titleFitsRow.isActive = false
        chevronFitsRow.isActive = true
      } else {
        chevronFitsRow.isActive = false
        titleFitsRow.isActive = true
      }
    }
  }

  /// The row's trailing limit, on the chevron when there is one, else on the title. Only
  /// one is active: a hidden chevron still sits in Auto Layout, and pinning it would take
  /// 20pt from every chevron-less title (ON REPEAT, the time row, MORE LIKE, RECENT),
  /// enough to cut the answer off the longer time-of-day titles.
  private var chevronFitsRow: NSLayoutConstraint!
  private var titleFitsRow: NSLayoutConstraint!

  /// phone-taste: the row title in two voices, the SHOUT and its answer ("ON REPEAT
  /// lately"). `answer` nil draws the shout alone.
  func configure(shout: String, answer: String?) {
    titleLabel.attributedText = CassetteHeading.attributed(
      shout: shout,
      answer: answer,
      answerColor: UIColor.cassette(.accentAnswer)
    )
    // VoiceOver reads "On Repeat, lately", not a spelled-out run of capitals.
    let spoken = CassetteHeading.accessibilityLabel(shout: shout.capitalized, answer: answer)
    titleLabel.accessibilityLabel = spoken
    tapButton.accessibilityLabel = spoken
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupSubviews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupSubviews()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    tapHandler = nil
    setRefreshHandler(nil)
    showsRefreshButton = false
    titleLabel.attributedText = nil
    titleLabel.accessibilityLabel = nil
    tapButton.accessibilityLabel = nil
  }

  /// cassette Patch 025: give the section title room to breathe.
  /// phone-taste: the mock's `.block` / `.head` rhythm: 28pt above the heading, 12pt
  /// down to the row, in the 20pt gutter (CassetteHeading's spacing).
  ///
  /// cassette Patch 042: also hosts the optional chevron and the
  /// transparent tap target.
  private func setupSubviews() {
    addSubview(titleLabel)
    addSubview(chevronImageView)
    addSubview(refreshButton)
    addSubview(tapButton)
    // cassette Polish 2 (A2): the chevron now sits directly adjacent to the
    // title (6pt gap) instead of floating against the trailing edge. On Home
    // it reads "tap into this shelf"; in Library the same glyph (rotated to
    // chevron.down) reads "dropdown". The trailing region is intentionally
    // empty space. phone-taste: the title gives way first (its compression
    // resistance is low), so a long answer truncates before the chevron moves. A
    // row without a chevron lets the title run to the gutter instead.
    // The bottom pin sits just under required so the self-sizing pass, not the
    // estimated height, sets the header's height.
    let bottom = titleLabel.bottomAnchor.constraint(
      equalTo: bottomAnchor,
      constant: -CassetteHeading.bottomSpacing
    )
    bottom.priority = UILayoutPriority(999)
    chevronFitsRow = chevronImageView.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor,
      constant: -CassetteHeading.sideInset
    )
    titleFitsRow = titleLabel.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor,
      constant: -CassetteHeading.sideInset
    )
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: CassetteHeading.sideInset
      ),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: CassetteHeading.topSpacing),
      bottom,

      chevronImageView.leadingAnchor.constraint(
        equalTo: titleLabel.trailingAnchor,
        constant: 6
      ),
      // No chevron until a tapHandler arrives, so the title holds the trailing limit.
      titleFitsRow,
      chevronImageView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      chevronImageView.widthAnchor.constraint(equalToConstant: 14),
      chevronImageView.heightAnchor.constraint(equalToConstant: 18),

      refreshButton.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -CassetteHeading.sideInset
      ),
      refreshButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

      tapButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      tapButton.topAnchor.constraint(equalTo: titleLabel.topAnchor),
      tapButton.bottomAnchor.constraint(equalTo: titleLabel.bottomAnchor),
      tapButton.trailingAnchor.constraint(
        equalTo: chevronImageView.trailingAnchor,
        constant: 8
      ),
    ])
    // Default to non-tappable; supplementaryViewProvider sets a
    // handler per-shelf which flips this back on.
    tapButton.isUserInteractionEnabled = false
  }
}

extension UIFont {
  fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
    let descriptor = fontDescriptor.addingAttributes([
      UIFontDescriptor.AttributeName.traits: [UIFontDescriptor.TraitKey.weight: weight],
    ])
    return UIFont(descriptor: descriptor, size: pointSize)
  }
}

// MARK: - SyncBannerView

/// cassette: the hub status line. One quiet line at the top of Home, shown only while there
/// is something to say about the hub (the person's Cassette Player): music arriving
/// ("Syncing 3 of 12 albums from Michael's MacBook Pro") or the hub out of reach with
/// albums waiting ("Can't reach Michael's MacBook Pro · new music arrives when it's
/// back"). When everything is in sync it is hidden. Text comes from
/// `CassetteSyncStatus.statusLine`. It replaced the two-line "SYNCING YOUR LIBRARY" card
/// with its indeterminate bar (founder 2026-10-20: "clean and minimal").
///
/// Defined here rather than in its own file on purpose: HomeVC is the only caller.
final class SyncBannerView: UIView {
  private let spinner: UIActivityIndicatorView = {
    let view = UIActivityIndicatorView(style: .medium)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.color = UIColor.cassette(.textSecondary)
    view.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
    view.hidesWhenStopped = true
    return view
  }()

  /// Shown instead of the spinner when the hub cannot be reached.
  private let dot: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = UIColor.cassette(.textTertiary)
    view.layer.cornerRadius = 3
    return view
  }()

  private let label: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.cassette(.metadata)
    label.textColor = UIColor.cassette(.textSecondary)
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingMiddle
    return label
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    translatesAutoresizingMaskIntoConstraints = false
    addSubview(spinner)
    addSubview(dot)
    addSubview(label)
    NSLayoutConstraint.activate([
      spinner.leadingAnchor.constraint(equalTo: leadingAnchor),
      spinner.centerYAnchor.constraint(equalTo: label.centerYAnchor),
      spinner.widthAnchor.constraint(equalToConstant: 16),
      dot.centerXAnchor.constraint(equalTo: spinner.centerXAnchor),
      dot.centerYAnchor.constraint(equalTo: label.centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 6),
      dot.heightAnchor.constraint(equalToConstant: 6),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: CassetteTheme.Spacing.sm),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])
  }

  /// `text` nil hides the line. `isSyncing` picks the spinner (music moving) over the dot
  /// (hub out of reach).
  func show(_ text: String?, isSyncing: Bool) {
    label.text = text
    isHidden = text == nil
    dot.isHidden = text == nil || isSyncing
    if text != nil, isSyncing { spinner.startAnimating() } else { spinner.stopAnimating() }
  }
}
