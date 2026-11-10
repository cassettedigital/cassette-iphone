//
//  CarPlaySceneDelegate.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 17.08.22.
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
@preconcurrency import CarPlay
import CoreData
import Foundation
import OSLog
import UIKit

// MARK: - CarPlayShortPreference

struct CarPlayShortPreference {
  let artworkDisplayPreference: ArtworkDisplayPreference
}

// MARK: - CarPlaySceneDelegate

@MainActor
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  static let maxTreeDepth = 4

  // cassette (BUG-337): not private, so the CarPlay extension files can log through it.
  let log = OSLog(subsystem: "Amperfy", category: "CarPlay")
  private static let assistantConfig = CPAssistantCellConfiguration(
    position: .top,
    visibility: .always,
    assistantAction: .playMedia
  )
  var isOfflineMode: Bool {
    appDelegate.storage.settings.user.isOfflineMode
  }

  func getPreference(_ accountInfo: AccountInfo?) -> CarPlayShortPreference {
    CarPlayShortPreference(
      artworkDisplayPreference: appDelegate.storage.settings.accounts.getSetting(accountInfo).read
        .artworkDisplayPreference
    )
  }

  var activeAccountInfo: AccountInfo!
  var activeAccount: Account!
  var accountNotificationHandler: AccountNotificationHandler?
  /// One Home: the cloud's Home rows found on the phone, the same instance the phone's Home
  /// draws from.
  var cloudHome: CloudHome?

  /// The player mode the now-playing button row was last built for. The button
  /// SET depends only on the mode (music: shuffle+repeat; podcast: repeat+rate),
  /// never the track — so `configureNowPlayingTemplate()` skips the rebuild when
  /// this is unchanged, avoiding the on-track-change flash of the active
  /// repeat/shuffle selection + scrubber. Reset on disconnect so a fresh connect
  /// re-pushes the buttons onto the new template.
  var lastConfiguredNowPlayingMode: PlayerMode?

  var interfaceController: CPInterfaceController?
  var traits: UITraitCollection {
    interfaceController?.carTraitCollection ?? UITraitCollection.maxDisplayScale
  }

  /// Every CarPlay image goes through this (BUG-424); see `CarPlayStyle`.
  var style: CarPlayStyle { CarPlayStyle(traits: traits) }

  /// CarPlay raises an uncaught exception when the navigation hierarchy grows
  /// past its hard limit (~5 templates including the root). Route every
  /// `pushTemplate` through this so a deep Library drill-down
  /// (type → artist → album → songs) fails safe by declining the push instead
  /// of crashing. `maxTreeDepth` caps the on-screen stack.
  @discardableResult
  func pushTemplateIfAllowed(_ template: CPTemplate, animated: Bool) -> Bool {
    guard let interfaceController else { return false }
    guard interfaceController.templates.count < Self.maxTreeDepth else {
      os_log(
        "CarPlay: push declined — navigation depth limit (%i) reached",
        log: self.log,
        type: .info,
        Self.maxTreeDepth
      )
      return false
    }
    interfaceController.pushTemplate(template, animated: animated, completion: nil)
    return true
  }

  /// CarPlay connected
  nonisolated func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    Task { @MainActor in
      os_log("CarPlay: didConnect", log: self.log, type: .info)
      DiagnosticLog.shared.log(.carplay, "CarPlay connected")
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(refreshSort),
        name: .fetchControllerSortChanged,
        object: nil
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(refreshOfflineMode),
        name: .offlineModeChanged,
        object: nil
      )
      // cassette: the owned/materialized library grows AFTER CarPlay's owned-set
      // fetch controllers are built, and each bakes `id IN fetchOwnedAlbumIds()`
      // as a snapshot frozen at construction time. The phone's VCs rebuild their
      // identical FRCs on this notification; CarPlay must too, or its Albums /
      // Artists panes stay frozen at whatever set was owned when first constructed
      // (the "~20 of 73 albums" bug). Posted on the main thread by
      // CassetteOwnershipNotifier.
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(refreshOwnedLibrary),
        name: CassetteLibraryFilterProvider.filterChangedNotification,
        object: nil
      )
      // phone-taste: the Mood row's doors follow the Mixtape beta flag, and its Lately tile
      // follows the mood tags, which can both arrive mid-drive.
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(refreshMoodRow),
        name: CassetteBetaAccess.changedNotification,
        object: nil
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(libraryMoodsChanged),
        name: .cassetteLibraryMoodsChanged,
        object: nil
      )
      accountNotificationHandler = AccountNotificationHandler(
        storage: appDelegate.storage,
        notificationHandler: appDelegate.notificationHandler
      )
      accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
        guard let self else { return }
        let meta = appDelegate.getMeta(accountInfo)
        appDelegate.notificationHandler.register(
          self,
          selector: #selector(downloadFinishedSuccessful(notification:)),
          name: .downloadFinishedSuccess,
          object: meta.artworkDownloadManager
        )
        appDelegate.notificationHandler.register(
          self,
          selector: #selector(downloadFinishedSuccessful(notification:)),
          name: .downloadFinishedSuccess,
          object: meta.playableDownloadManager
        )
      }

      appDelegate.player.addNotifier(notifier: self)
      CPNowPlayingTemplate.shared.add(self)
      self.interfaceController = interfaceController
      sessionConfiguration = CPSessionConfiguration(delegate: self)
      // cassette (JOB 1, BUG-337): record what this head unit reports at connect, and the
      // browse budget the app derived from it, so the diagnostics export can answer whether
      // the car draws what it reports (section 8.3 of the BUG-337 spec).
      let carTraits = interfaceController.carTraitCollection
      let shelfImage = CPListImageRowItemRowElement.maximumImageSize
      let rowImage = CPListItem.maximumImageSize
      let budgetContext: [String: String] = [
        "maxItems": String(CPListTemplate.maximumItemCount),
        "maxSections": String(CPListTemplate.maximumSectionCount),
        "maxTabs": String(CPTabBarTemplate.maximumTabCount),
        "shelfImage": "\(Int(shelfImage.width))x\(Int(shelfImage.height))",
        "rowImage": "\(Int(rowImage.width))x\(Int(rowImage.height))",
        "scale": String(describing: carTraits.displayScale),
        "browseBudget": String(carPlayBrowseItemBudget),
        "browseCeiling": String(Self.carPlayBrowseBudgetCeiling),
      ]
      DiagnosticLog.shared.log(.carplay, "CarPlay budget", context: budgetContext)
      os_log(
        "CarPlay: budget maxItems=%i maxSections=%i maxTabs=%i browse=%i scale=%{public}@",
        log: self.log,
        type: .info,
        CPListTemplate.maximumItemCount,
        CPListTemplate.maximumSectionCount,
        CPTabBarTemplate.maximumTabCount,
        carPlayBrowseItemBudget,
        String(describing: carTraits.displayScale)
      )
      self.interfaceController?.delegate = self
      self.configureNowPlayingTemplate()

      // Bind the CarPlay root deterministically the moment we connect. The INITIAL
      // root must not hinge on the async active-account callback landing cleanly:
      // after a crash-triggered relaunch the scene can connect while storage /
      // account restore is still in flight, and if that path doesn't complete,
      // CarPlay is left with no root template — a blank screen that clears only on a
      // physical unplug/replug (observed 2026-07-09). Applying the current active
      // account synchronously here guarantees the scene is usable on connect.
      applyActiveAccount(appDelegate.storage.settings.accounts.active)

      accountNotificationHandler?
        .registerCallbackForActiveAccountChange { [weak self] accountInfo in
          guard let self else { return }

          // B3: the initial bind already happened synchronously above, so react
          // only to a real account-identity change. A repeat event for the same
          // account, or a transient `.accountActiveChanged(nil)` (auth blip) while
          // accounts still exist, must NOT resetFetchController / setRootTemplate —
          // that's the mid-drive "reset to Home, audio off" symptom.
          let current: AccountInfo? = activeAccountInfo
          if accountInfo == current { return }
          if accountInfo == nil,
             !appDelegate.storage.settings.accounts.allAccounts.isEmpty {
            os_log(
              "CarPlay: transient nil active account ignored (accounts remain)",
              log: self.log,
              type: .info
            )
            return
          }
          applyActiveAccount(accountInfo)
        }

      if let current = self.appDelegate.player.currentlyPlaying, self.appDelegate.player.isPlaying {
        self.updatePlayerQueueSection()
        self.displayNowPlaying(immediately: true) {}
        // cassette (CarPlay cover on reconnect): after unplug→replug→resume-same-track
        // the now-playing hero can be a stale placeholder — didConnect refreshes the
        // template but never rebuilds the now-playing INFO/artwork, and the cover
        // download may have been cancelled while disconnected. Re-request the
        // ALBUM-FIRST cover (owned covers live on the album). Because Artwork.isCached
        // is hardcoded false the request re-completes, and .downloadFinishedSuccess
        // then drives NowPlayingInfoCenterHandler to rebuild the hero with the real art.
        // cassette (C09): repaint the hero from the on-disk album cover IMMEDIATELY,
        // no network. The re-request below is only a belt-and-suspenders refresh for
        // the online case; in a car with no signal it never completes, and the hero
        // rebuild guard is now album-aware so a late completion also lands.
        self.appDelegate.player.notifyNowPlayingInfoChanged()
        let heroArtwork = (current as? Song)?.album?.artwork ?? current.artwork
        if let heroArtwork, let accountInfo = heroArtwork.account?.info {
          self.appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: heroArtwork)
        }
      }
    }
  }

  /// Bind an active account to the CarPlay scene: rebuild the owned-set fetch
  /// controllers, wire up Home, and set the root template. Called synchronously on
  /// `didConnect` (so the scene is never left blank if the account callback races
  /// app init after a crash-relaunch) and again on any genuine active-account
  /// change. Safe to call repeatedly; the same account simply rebinds.
  private func applyActiveAccount(_ accountInfo: AccountInfo?) {
    // A different account must not inherit the last one's Home rows or artwork index.
    endSession()
    activeAccountInfo = accountInfo
    guard let accountInfo else {
      os_log(
        "CarPlay: no account available -> display Disconnected",
        log: self.log,
        type: .info
      )
      activeAccount = nil
      interfaceController?.setRootTemplate(
        disconnectedTemplate,
        animated: true,
        completion: nil
      )
      return
    }
    activeAccount = appDelegate.storage.main.library.getAccount(info: accountInfo)
    // One Home: the car draws the cloud's Home from the instance the phone's Home reads (no
    // Home of its own any more), and redraws when its rows change.
    cloudHome = CloudHome.shared(
      account: activeAccount,
      storage: appDelegate.storage,
      player: appDelegate.player
    )
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(cloudHomeChanged),
      name: CloudHome.didChange,
      object: nil
    )
    cloudHome?.refresh()
    Task { @MainActor in await HomeStore.shared.refreshIfDue() }
    interfaceController?.setRootTemplate(
      rootBarTemplate,
      animated: false,
      completion: nil
    )
    Task { @MainActor in
      self.refreshOfflineMode()
    }
  }

  /// CarPlay disconnected
  nonisolated func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    Task { @MainActor in
      os_log("CarPlay: didDisconnect", log: self.log, type: .info)
      DiagnosticLog.shared.log(.carplay, "CarPlay disconnected")
      // cassette (SCENE-2): teardown must be symmetric with the UNCONDITIONAL setup in
      // didConnect. The old `guard account != nil else { return }` leaked the observers
      // and interfaceController whenever CarPlay connected with no active account. Every
      // removal below is idempotent, so run them regardless of account state.
      self.interfaceController = nil
      appDelegate.notificationHandler.remove(self, name: .fetchControllerSortChanged, object: nil)
      appDelegate.notificationHandler.remove(self, name: .offlineModeChanged, object: nil)
      appDelegate.notificationHandler.remove(
        self,
        name: CassetteLibraryFilterProvider.filterChangedNotification,
        object: nil
      )
      appDelegate.notificationHandler.remove(
        self,
        name: CassetteBetaAccess.changedNotification,
        object: nil
      )
      appDelegate.notificationHandler.remove(self, name: .cassetteLibraryMoodsChanged, object: nil)
      accountNotificationHandler?.performOnAllRegisteredAccounts { [weak self] accountInfo in
        guard let self else { return }
        let meta = appDelegate.getMeta(accountInfo)
        appDelegate.notificationHandler.remove(
          self,
          name: .downloadFinishedSuccess,
          object: meta.artworkDownloadManager
        )
        appDelegate.notificationHandler.remove(
          self,
          name: .downloadFinishedSuccess,
          object: meta.playableDownloadManager
        )
      }

      // cassette (BUG-426): symmetric with addNotifier in didConnect, so an unplugged car
      // stops rebuilding the queue on every track change.
      appDelegate.player.removeNotifier(notifier: self)
      CPNowPlayingTemplate.shared.remove(self)
      // Force the next connect to re-push the button row onto the fresh template.
      lastConfiguredNowPlayingMode = nil

      endSession()
      // Nothing account-scoped outlives the connection: without this the handler kept
      // re-binding Home (a new HomeManager with its own fetch controllers) on account
      // events while the car was unplugged (CPS-7). didConnect creates a fresh one.
      accountNotificationHandler = nil
    }
  }

  /// Release everything one connection (or one account binding) built: Home and its fetch
  /// controllers, which otherwise keep recomputing shelves, decoding covers and requesting
  /// artwork while no car is attached (CPS-7); the Home rows and artwork index (CPS-4); the
  /// playlist detail; every browse fetch controller and page.
  private func endSession() {
    appDelegate.notificationHandler.remove(self, name: CloudHome.didChange, object: nil)
    cloudHome = nil
    session = SessionState()
    // The rows on the Home tab belong to the session just ended; an empty Home in the next
    // one would otherwise early-out and leave them on screen.
    homeTab.updateSections([])
    playlistDetailSection = nil
    resetFetchController()
    resetBrowsePages()
  }

  lazy var playerQueueSection = {
    let queueTemplate = CPListTemplate(title: Self.queueButtonText, sections: [CPListSection]())
    queueTemplate.emptyViewTitleVariants = ["Nothing up next"]
    return queueTemplate
  }()

  lazy var disconnectedTemplate = {
    let disconnectedList = CPListTemplate(title: "Disconnected", sections: [])
    // Shown only with no account on the phone; say what to do about it (CPS-11).
    disconnectedList.emptyViewTitleVariants = ["Sign in on your phone to get started"]
    return disconnectedList
  }()

  lazy var rootBarTemplate = {
    // D5: no "Cached" tab. The music is on the phone, not "cached" — offline
    // filtering happens automatically inside the Library lists (onlyCached:
    // isOfflineMode), so there's no separate surface and no "cache" wording.
    //
    // cassette (CarPlay feel-good, Job 3): album-forward, driving-safe IA.
    // Albums & Artists are promoted to top-level tabs (were nested under the
    // "Library" tab) so the most-reached categories are one tap from the root.
    // Library's other children (Genres, Favorite Songs) are intentionally not
    // surfaced on CarPlay — album/artist/playlist is enough behind the wheel.
    // 4 tabs, under the 5-tab ceiling.
    let bar = CPTabBarTemplate(templates: [
      homeTab,
      albumsSection,
      artistsSection,
      playlistTab,
    ].prefix(upToAsArray: CPTabBarTemplate.maximumTabCount))
    return bar
  }()

  lazy var playlistTab = {
    let playlistTab = CPListTemplate(title: "Playlists", sections: [CPListSection]())
    playlistTab.tabImage = UIImage.playlist
    // A browse list since Wave 1 of the design-system audit: it pages past the budget.
    playlistTab.userInfo = CarPlayBrowseDescriptor(kind: .playlists, bucket: nil)
    playlistTab.emptyViewTitleVariants = ["No playlists on this phone yet"]
    return playlistTab
  }()

  lazy var homeTab = {
    let homeTab = CPListTemplate(title: "Home", sections: [])
    homeTab.tabImage = UIImage.home
    homeTab.assistantCellConfiguration = CarPlaySceneDelegate.assistantConfig
    return homeTab
  }()

  struct EntityImageRowContainer {
    let entity: AbstractLibraryEntity
    let item: HomeItem
    var homeRow: [CPListImageRowItemRowElement]
  }

  /// What one CarPlay connection builds up and nothing outlives: the Home shelf rows, the
  /// data they were built from, and the artwork index that repaints their tiles. Replaced
  /// wholesale by `endSession()` on disconnect and on an account change, so a replug into a
  /// different head unit never shows rows built at the old car's scale (design-system audit
  /// Wave 1, CPS-4).
  struct SessionState {
    var homeImageRows: [HomeSection: CPListImageRowItem] = [:]
    var homeRowData: [HomeSection: [HomeItem]] = [:]
    var homeArtworkUpdate: [String: EntityImageRowContainer] = [:] // String is Artwork.uniqueID
    /// phone-taste: the Mood row is built outside the HomeItem pipeline (a door is not a
    /// library entity). The tiles it shows, in order, are what a tap resolves against; the
    /// signature (Lately lead album ids, whether the doors show, the door keys) is what
    /// `updateHomeSections` compares, so the row's art is drawn only when it changes.
    var moodRow: CPListImageRowItem?
    var moodTiles: [CarMoodTile] = []
    /// Each record tile's four covers by tile ("lately" or a mix id), decoded once per
    /// signature (the Made for You list reuses them).
    var moodCovers: [String: [UIImage]] = [:]
    var moodSignature: String?
    /// The artwork ids of the record tiles' lead albums whose covers were not on the phone
    /// when the row was drawn. When one of them lands, the row is drawn again, so the Lately
    /// tile shows as its covers arrive instead of at Home's next recompute (BUG-460).
    var moodAwaitedArtworkIDs: Set<String> = []
    var moodRedrawPending = false
    /// The rows' order and names as last rendered, so a change of name alone gets through the
    /// early-out (Weekday Evenings becomes Weekday Nights with the same albums; the reaching
    /// row turns from one shelf to another).
    var homeLayout: String?
    /// The door mix being fetched (one at a time), and whether something else played since
    /// the tap, in which case its result is dropped.
    var doorLoad: UUID?
    var doorLoadOvertaken = false
  }

  var session = SessionState()

  /// cassette 2026-10-20 (driving pass): what the car allows right now. When it limits
  /// lists (the car is moving), pages are built in their short form.
  var sessionConfiguration: CPSessionConfiguration?
  var isDriving: Bool {
    sessionConfiguration?.limitedUserInterfaces.contains(.lists) ?? false
  }

  lazy var artistsSection = {
    let template = CPListTemplate(title: "Artists", sections: [
      CPListSection(items: [CPListTemplateItem]()),
    ])
    // cassette (Job 3): promoted to a top-level CarPlay tab.
    template.tabImage = UIImage.artist
    // cassette (BUG-337): the tab is a browse list; its descriptor lives in userInfo.
    template.userInfo = CarPlayBrowseDescriptor(kind: .artists, bucket: nil)
    template.emptyViewTitleVariants = ["No artists on this phone yet"]
    return template
  }()

  lazy var albumsSection = {
    let template = CPListTemplate(title: "Albums", sections: [
      CPListSection(items: [CPListTemplateItem]()),
    ])
    // cassette (Job 3): promoted to a top-level CarPlay tab.
    template.tabImage = UIImage.album
    // cassette (BUG-337): the tab is a browse list; its descriptor lives in userInfo.
    template.userInfo = CarPlayBrowseDescriptor(kind: .albums, bucket: nil)
    template.emptyViewTitleVariants = ["No albums on this phone yet"]
    return template
  }()

  var playlistDetailSection: CPListTemplate?

  var playlistFetchController: PlaylistFetchedResultsController?
  var artistsFetchController: ArtistFetchedResultsController?
  var albumsFetchController: AlbumFetchedResultsController?
  var playlistDetailFetchController: PlaylistItemsFetchedResultsController?

  private func resetFetchController() {
    playlistFetchController?.delegate = nil
    playlistFetchController = nil
    artistsFetchController?.delegate = nil
    artistsFetchController = nil
    albumsFetchController?.delegate = nil
    albumsFetchController = nil
    playlistDetailFetchController?.delegate = nil
    playlistDetailFetchController = nil
  }

  /// cassette (BUG-337): fresh browse descriptors (page 0, no log signature) on the two
  /// tabs. Called on account bind (setRootTemplate then discards any pushed range list) and
  /// on disconnect (the stack is released). Nothing else holds browse state.
  /// Back to the first page of one browse tab (a new sort order starts from the top).
  private func resetBrowsePage(_ template: CPListTemplate) {
    guard var descriptor = template.userInfo as? CarPlayBrowseDescriptor else { return }
    descriptor.page = 0
    template.userInfo = descriptor
  }

  private func resetBrowsePages() {
    albumsSection.userInfo = CarPlayBrowseDescriptor(kind: .albums, bucket: nil)
    artistsSection.userInfo = CarPlayBrowseDescriptor(kind: .artists, bucket: nil)
    playlistTab.userInfo = CarPlayBrowseDescriptor(kind: .playlists, bucket: nil)
  }

  @objc
  private func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification)
    else { return }
    guard let templates = interfaceController?.templates else { return }

    // BUG-460: a cover a record tile was waiting for; draw the Made for You row again,
    // once for a burst of covers (redrawMoodRowForArrivedCovers).
    if session.moodAwaitedArtworkIDs.contains(downloadNotification.id), !session.moodRedrawPending {
      session.moodRedrawPending = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        guard let self else { return }
        session.moodRedrawPending = false
        redrawMoodRowForArrivedCovers()
      }
    }

    // refresh Home image rows
    // cassette (BUG-338): the pushed shelf detail is a plain CPListTemplate of library rows
    // now, so it is refreshed by the "refresh List items" walk below like every other list;
    // only the single-line Home shelf still tracks image-row elements here.
    if let container = session.homeArtworkUpdate[downloadNotification.id] {
      let image = style.artwork(
        for: container.entity,
        artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference,
        slot: .shelf
      )
      for rowImage in container.homeRow {
        rowImage.image = image
      }
    }

    // refresh List items
    for template in templates {
      var sections: [CPListSection]?

      if let listTemplate = template as? CPListTemplate {
        sections = listTemplate.sections
      } else if let tabBarTemplate = template as? CPTabBarTemplate,
                let selectedTemplate = tabBarTemplate.selectedTemplate as? CPListTemplate {
        sections = selectedTemplate.sections
      }

      guard let sections = sections else { continue }
      for section in sections {
        for listTemplateItem in section.items {
          guard let item = listTemplateItem as? CPListItem,
                let userInfo = item.userInfo as? [String: Any]
          else { continue }

          // Match on the IDs first; only a row that belongs to this download pays for a
          // Core Data lookup. The walk used to resolve the owner of EVERY visible row before
          // checking, once per finished download (CPS-3).
          let rowIDs = [
            CarPlayListUserInfoKeys.playableDownloadID,
            CarPlayListUserInfoKeys.artworkDownloadID,
          ].compactMap { userInfo[$0.rawValue] as? String }
          guard rowIDs.contains(downloadNotification.id),
                let ownerType = userInfo[CarPlayListUserInfoKeys.artworkOwnerType.rawValue]
                as? ArtworkType,
                let objectID = userInfo[CarPlayListUserInfoKeys.artworkOwnerObjectID.rawValue]
                as? NSManagedObjectID
          else { continue }
          let isTrackDisplayed = (
            userInfo[CarPlayListUserInfoKeys.isTrackDisplayed.rawValue] as? Bool
          ) ?? false
          let preference = getPreference(activeAccountInfo).artworkDisplayPreference
          switch artworkOwner(type: ownerType, objectID: objectID) {
          case let .playable(playable):
            item.setImage(style.artwork(
              for: playable,
              isTrackDisplayed: isTrackDisplayed,
              artworkDisplayPreference: preference
            ))
          case let .entity(entity):
            item.setImage(style.artwork(for: entity, artworkDisplayPreference: preference))
          case .none:
            break
          }
        }
      }
    }
  }

  private enum ArtworkOwner {
    case playable(AbstractPlayable)
    case entity(AbstractLibraryEntity)
  }

  /// The live library object behind a row's `userInfo`, or nil when it is gone (regrouped or
  /// deleted since the row was built).
  private func artworkOwner(type: ArtworkType, objectID: NSManagedObjectID) -> ArtworkOwner? {
    let object = try? appDelegate.storage.main.context.existingObject(with: objectID)
    switch type {
    case .song:
      return (object as? SongMO).map { .playable(Song(managedObject: $0)) }
    case .podcastEpisode:
      return (object as? PodcastEpisodeMO).map { .playable(PodcastEpisode(managedObject: $0)) }
    case .radio:
      return (object as? RadioMO).map { .playable(Radio(managedObject: $0)) }
    case .album:
      return (object as? AlbumMO).map { .entity(Album(managedObject: $0)) }
    case .artist:
      return (object as? ArtistMO).map { .entity(Artist(managedObject: $0)) }
    case .podcast:
      return (object as? PodcastMO).map { .entity(Podcast(managedObject: $0)) }
    default:
      return nil
    }
  }

  /// cassette (DRIFT-1): albumsSection/artistsSection are top-level TABS in
  /// rootBarTemplate, not pushed templates — so `interfaceController.templates`
  /// never contains them, and the old `templates.contains(...)` gate was always
  /// false (a mid-drive sync never refreshed the visible Albums/Artists tab). A
  /// tab child is reached via the tab bar's selectedTemplate, mirroring the
  /// playlistTab/homeTab checks already used here.
  private func isSelectedRootTab(_ template: CPListTemplate) -> Bool {
    (interfaceController?.rootTemplate as? CPTabBarTemplate)?.selectedTemplate == template
  }

  @objc
  private func refreshSort() {
    guard interfaceController != nil else { return }
    // cassette (SCENE-1): building a fetch controller force-unwraps activeAccount. If
    // CarPlay connected with no active account (activeAccount == nil), a sort-changed
    // notification would trap here — bail.
    guard activeAccount != nil else { return }

    // The Albums and Artists tabs sort by their own fixed order (BUG-337 browse), so
    // only the Playlists tab follows the sort setting.
    if let root = interfaceController?.rootTemplate as? CPTabBarTemplate,
       root.selectedTemplate == playlistTab,
       playlistFetchController?.sortType != appDelegate.storage.settings.user.playlistsSortSetting {
      os_log("CarPlay: RefreshSort: PlaylistFetchController", log: self.log, type: .info)
      createPlaylistFetchController()
      resetBrowsePage(playlistTab)
      renderBrowseList(playlistTab)
    }
  }

  // cassette: the owned/materialized library changed (a sync materialized more
  // owned SongMOs, or a removal reaped some). Every owned-set-scoped CarPlay fetch
  // controller baked `id IN fetchOwnedAlbumIds()` at build time, so it is frozen
  // to the old set. Drop them all (resetFetchController), then re-render whatever
  // section is on screen via refreshOfflineMode() — its create*FetchController
  // calls re-snapshot the CURRENT owned set. Sections not currently presented stay
  // nil and rebuild lazily on their next templateWillAppear. This is what lets
  // CarPlay converge from ~20 to the full 73 owned albums the phone shows.
  @objc
  private func refreshOwnedLibrary() {
    os_log(
      "CarPlay: owned library changed -> rebuild owned fetch controllers",
      log: self.log,
      type: .info
    )
    resetFetchController()
    refreshOfflineMode()
  }

  /// phone-taste: the Mixtape beta flag changed, so the doors appear or go (the Mood row's
  /// signature carries the flag).
  @objc
  private func refreshMoodRow() {
    updateHomeSections()
  }

  /// phone-taste: new mood tags or a new lately profile. One Home: the car's rows come from
  /// the cloud, which already read them; just look again.
  @objc
  private func libraryMoodsChanged() {
    cloudHome?.refresh()
  }

  /// One Home: the cloud's rows on the phone changed (a new answer, music came or went,
  /// something started playing).
  @objc
  private func cloudHomeChanged() {
    updateHomeSections()
  }

  @objc
  private func refreshOfflineMode() {
    os_log("CarPlay: OfflineModeChanged", log: self.log, type: .info)
    guard let templates = interfaceController?.templates else { return }

    cloudHome?.refresh()

    if let root = interfaceController?.rootTemplate as? CPTabBarTemplate,
       root.selectedTemplate == homeTab {
      os_log("CarPlay: OfflineModeChanged: HomeSections", log: self.log, type: .info)
      updateHomeSections()
    }
    if let root = interfaceController?.rootTemplate as? CPTabBarTemplate,
       root.selectedTemplate == playlistTab {
      os_log("CarPlay: OfflineModeChanged: playlistFetchController", log: self.log, type: .info)
      createPlaylistFetchController()
      renderBrowseList(playlistTab)
    }
    if isSelectedRootTab(artistsSection) {
      os_log(
        "CarPlay: OfflineModeChanged: artistsFetchController",
        log: self.log,
        type: .info
      )
      createArtistsFetchController()
      renderBrowseList(artistsSection)
    }
    if isSelectedRootTab(albumsSection) {
      os_log(
        "CarPlay: OfflineModeChanged: albumsFetchController",
        log: self.log,
        type: .info
      )
      createAlbumsFetchController()
      renderBrowseList(albumsSection)
    }
    // cassette (BUG-337): every pushed range list re-renders from its own keys against the
    // rebuilt fetch controller (grew past the budget -> pages; keys reaped -> empty view).
    // Unconditional; each no-ops when no list of that kind is on the stack.
    refreshPushedBrowseLists(kind: .artists, in: templates)
    refreshPushedBrowseLists(kind: .albums, in: templates)
    if let playlistDetailSection = playlistDetailSection, templates.contains(playlistDetailSection),
       let playlistDetailFetchController = playlistDetailFetchController {
      os_log("CarPlay: OfflineModeChanged: playlistDetailSection", log: self.log, type: .info)
      playlistDetailFetchController.search(onlyCachedSongs: isOfflineMode)
      playlistDetailSection
        .updateSections(
          [CPListSection(items: createPlaylistDetailItems(from: playlistDetailFetchController))]
        )
    }
  }
}

extension CarPlaySceneDelegate: @preconcurrency NSFetchedResultsControllerDelegate {
  func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
    // fetch controller is created on Main thread -> Runtime Error if this function call is not on Main thread
    MainActor.assumeIsolated {
      guard let templates = self.interfaceController?.templates else { return }
      if let root = self.interfaceController?.rootTemplate as? CPTabBarTemplate,
         root.selectedTemplate == playlistTab,
         let playlistFetchController = playlistFetchController,
         controller == playlistFetchController.fetchResultsController {
        os_log("CarPlay: FetchedResults: playlistFetchController", log: self.log, type: .info)
        renderBrowseList(playlistTab)
      }
      if isSelectedRootTab(artistsSection),
         let artistsFetchController = artistsFetchController,
         controller == artistsFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: artistsFetchController",
          log: self.log,
          type: .info
        )
        renderBrowseList(artistsSection)
      }
      // cassette (BUG-337): pushed Artists range lists refresh on the FRC identity alone.
      if let artistsFetchController,
         controller == artistsFetchController.fetchResultsController {
        refreshPushedBrowseLists(kind: .artists, in: templates)
      }
      if isSelectedRootTab(albumsSection),
         let albumsFetchController = albumsFetchController,
         controller == albumsFetchController.fetchResultsController {
        os_log(
          "CarPlay: FetchedResults: albumsFetchController",
          log: self.log,
          type: .info
        )
        renderBrowseList(albumsSection)
      }
      // cassette (BUG-337): pushed Albums range lists refresh on the FRC identity alone.
      if let albumsFetchController,
         controller == albumsFetchController.fetchResultsController {
        refreshPushedBrowseLists(kind: .albums, in: templates)
      }
      if let playlistDetailSection = playlistDetailSection,
         templates.contains(playlistDetailSection),
         let playlistDetailFetchController = playlistDetailFetchController,
         controller == playlistDetailFetchController.fetchResultsController {
        os_log("CarPlay: FetchedResults: playlistDetailSection", log: self.log, type: .info)
        playlistDetailSection
          .updateSections(
            [CPListSection(items: createPlaylistDetailItems(from: playlistDetailFetchController))]
          )
      }
    }
  }
}

// MARK: CPInterfaceControllerDelegate

extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
  nonisolated func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
    Task { @MainActor in
      DiagnosticLog.shared.log(
        .carplay,
        "template will appear",
        context: ["template": String(describing: type(of: aTemplate))]
      )
      if aTemplate == playerQueueSection {
        os_log("CarPlay: templateWillAppear playerQueueSection", log: self.log, type: .info)
        playerQueueSection.updateSections(createPlayerQueueSections())
      } else if aTemplate == homeTab {
        os_log("CarPlay: templateWillAppear: homeTab", log: self.log, type: .info)
        self.updateHomeSections()
      } else if aTemplate == playlistTab {
        os_log("CarPlay: templateWillAppear playlistTab", log: self.log, type: .info)
        Task { @MainActor in do {
          try await self.appDelegate.getMeta(activeAccountInfo).librarySyncer
            .syncDownPlaylistsWithoutSongs()
        } catch {
          // cassette Patch 040: CarPlay browse-appear background sync.
          self.appDelegate.eventLogger.report(
            topic: "CarPlay: Playlists Sync",
            error: error,
            isBackground: true
          )
        }}
        renderBrowseList(playlistTab)
      } else if aTemplate == artistsSection {
        os_log(
          "CarPlay: templateWillAppear artistsSection",
          log: self.log,
          type: .info
        )
        if artistsFetchController ==
          nil { createArtistsFetchController() }
        renderBrowseList(artistsSection)
      } else if aTemplate == albumsSection {
        os_log("CarPlay: templateWillAppear albumsSection", log: self.log, type: .info)
        if albumsFetchController == nil { createAlbumsFetchController() }
        renderBrowseList(albumsSection)
      } else if aTemplate == playlistDetailSection,
                let playlistDetailFetchController = playlistDetailFetchController {
        os_log("CarPlay: templateWillAppear playlistDetailSection", log: self.log, type: .info)
        Task { @MainActor in do {
          try await playlistDetailFetchController.playlist.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.activeAccountInfo).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.activeAccountInfo)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(
            topic: "Playlist Sync",
            error: error,
            isBackground: true
          )
        }}
        playlistDetailSection?
          .updateSections(
            [CPListSection(items: createPlaylistDetailItems(from: playlistDetailFetchController))]
          )
      } else if let list = aTemplate as? CPListTemplate,
                let d = list.userInfo as? CarPlayBrowseDescriptor, d.bucket != nil {
        // cassette (BUG-337): a pushed range list re-renders from its own keys on push and
        // on every pop back to it (an album or artist detail closed after a mid-drive change).
        os_log("CarPlay: templateWillAppear browse range list", log: self.log, type: .info)
        renderBrowseList(list)
      }
    }
  }

  nonisolated func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {}
  nonisolated func templateWillDisappear(_ aTemplate: CPTemplate, animated: Bool) {}

  nonisolated func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
    Task { @MainActor in
      if aTemplate == playlistDetailSection {
        os_log("CarPlay: templateDidDisappear playlistDetailSection", log: self.log, type: .info)
        playlistDetailFetchController = nil
        playlistDetailSection = nil
      }
    }
  }
}
