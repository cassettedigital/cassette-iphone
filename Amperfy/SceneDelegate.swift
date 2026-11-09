//
//  SceneDelegate.swift
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
import OSLog
import UIKit

// MARK: - MainSceneHostingViewController

@MainActor
protocol MainSceneHostingViewController {
  func pushNavLibrary(vc: UIViewController)
  func pushLibraryCategory(vc: UIViewController)
  func pushTabCategory(tabCategory: TabNavigatorItem)
  // cassette Patch 042: deep-link into a specific Library tab
  // category from outside the Library hierarchy (e.g. Home shelf
  // header tap). Implementations switch to the Library tab,
  // unwind any pushed children, and tell the LibraryContainerVC
  // to surface the requested category.
  func switchToLibrary(category: LibraryDisplayType)
  func displaySearch()

  func visualizePopupPlayer(
    direction: PopupPlayerDirection,
    animated: Bool,
    completion completionBlock: (() -> ())?
  )

  func getSafeAreaExtension() -> CGFloat
  var miniPlayer: MiniPlayerView? { get }
}

extension MainSceneHostingViewController {
  func visualizePopupPlayer(
    direction: PopupPlayerDirection,
    animated: Bool,
    completion completionBlock: (() -> ())? = nil
  ) {
    guard let topView = AppDelegate.topViewController(),
          let hostVC = AppDelegate.mainWindowHostVC
    else { return }

    if let presentedViewController = topView.presentedViewController {
      presentedViewController.dismiss(animated: animated) {
        if direction == .open {
          hostVC.miniPlayer?.openPlayerView(completion: completionBlock)
        } else {
          completionBlock?()
        }
      }
    } else {
      if direction == .open || direction == .toggle {
        hostVC.miniPlayer?.openPlayerView(completion: completionBlock)
      } else {
        completionBlock?()
      }
    }
  }
}

// MARK: - SceneDelegate

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  #if false // set to true to adjust Main window to App Connect compatible screen size for screenshots
    static let mainWindowSize = CGSizeMake(1168, 688) // 2560 x 1600
  #endif

  public lazy var log = {
    AmperKit.shared.log
  }()

  var window: UIWindow?

  // Cassette fork — Layer 3 (Phase 3.1): foreground polling for sync intents.
  // ADAPTIVE cadence — see scheduleNextCassettePoll. Background polling is still
  // out of scope; foregrounding and pull-to-refresh are the responsive triggers.
  private var cassetteIntentPollTimer: Timer?
  /// While work is in flight (intents executing, artwork still converging) — keeps a
  /// transfer's completion snappy.
  private static let cassetteActivePollInterval: TimeInterval = 30
  /// Once a poll does nothing. A settled library needs no chatter; a gesture or a
  /// foreground brings it back instantly.
  private static let cassetteIdlePollInterval: TimeInterval = 15 * 60
  // Cassette fork — graceful unpair handling: when the bearer token starts
  // 401ing (the device was removed on the dashboard), show one reconnect
  // alert per launch instead of silently going dead.
  private var cassetteTokenRejectedObserver: NSObjectProtocol?
  private var cassetteReconnectAlertShown = false
  private var cassetteReauth: CassetteTokenReauth?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    os_log("willConnectTo", log: self.log, type: .info)
    /** Process the quick action if the user selected one to launch the app.
         Grab a reference to the shortcutItem to use in the scene.
     */
    if let shortcutItem = connectionOptions.shortcutItem {
      // Save it off for later when we become active.
      appDelegate.quickActionsManager.savedShortCutItemForLaterUse(savedShortCutItem: shortcutItem)
    }
    // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
    // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
    // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
    guard let windowScene = scene as? UIWindowScene else { return }
    window = UIWindow(windowScene: windowScene)
    // Light or dark as the person chose (Auto follows the phone, I-T1); the warm paper behind.
    window?.overrideUserInterfaceStyle = appDelegate.storage.settings.user.appearanceMode
    window?.backgroundColor = UIColor.cassette(.surfaceBase)
    appDelegate.window = window
    var initialViewController: UIViewController?

    #if false
      windowScene.sizeRestrictions?.minimumSize = Self.mainWindowSize
    #endif
    if let activeAccountInfo = AmperKit.shared.storage.settings.accounts.active {
      let account = appDelegate.storage.main.library.getAccount(info: activeAccountInfo)
      if !AmperKit.shared.storage.settings.app.isLibrarySynced {
        initialViewController = AppStoryboard.Main.segueToSync(account: account)
      } else if AmperKit.shared.libraryUpdater.isVisualUpadateNeeded {
        initialViewController = AppStoryboard.Main.segueToUpdate()
      } else {
        initialViewController = AppStoryboard.Main.segueToMainWindow(account: account)
      }
    } else {
      initialViewController = AppStoryboard.Main.segueToLogin()
    }
    replaceMainRootViewController(vc: initialViewController!)

    window?.makeKeyAndVisible()

    appDelegate.setAppAppearanceMode(style: appDelegate.storage.settings.user.appearanceMode)
    AmperfyAppShortcuts.updateAppShortcutParameters()
  }

  func replaceMainRootViewController(vc: UIViewController) {
    window?.rootViewController = vc
  }

  /** Called when the user activates your application by selecting a shortcut on the Home Screen,
       and the window scene is already connected.
   */
  /// - Tag: PerformAction
  func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> ()
  ) {
    os_log("windowScene shortcutItem", log: self.log, type: .info)
    guard appDelegate.isNormalInteraction else {
      return completionHandler(false)
    }
    let handled = appDelegate.quickActionsManager.handleShortCutItem(shortcutItem: shortcutItem)
    completionHandler(handled)
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not neccessarily discarded (see `application:didDiscardSceneSessions` instead).
    os_log("sceneDidDisconnect", log: self.log, type: .info)
    appDelegate.rebuildMainMenu()
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    // Called when the scene has moved from an inactive state to an active state.
    // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    os_log("sceneDidBecomeActive", log: self.log, type: .info)
    guard appDelegate.isNormalInteraction else {
      return
    }
    appDelegate.quickActionsManager.handleSavedShortCutItemIfSaved()
    appDelegate.rebuildMainMenu()
    observeCassetteTokenRejection()
    startCassetteIntentPolling()
  }

  // MARK: - Cassette intent polling (Phase 3.1)

  private func startCassetteIntentPolling() {
    // Poll once immediately, then every 30s while in the foreground.
    // cassette: debug-only console tracing (gated so it doesn't ship / add
    // main-thread I/O in release).
    #if DEBUG
      print("Cassette poll: app became active -> triggering poll")
    #endif
    Task { @MainActor in
      await IntentExecutor.shared.handlePendingIntents()
      self.scheduleNextCassettePoll()
    }
  }

  /// ADAPTIVE cadence, not a fixed interval.
  ///
  /// The old timer polled every 30s for the life of the foreground session — two
  /// network round-trips a minute, forever, on battery, long after a settled library
  /// had nothing left to do. (It was labelled "for testing" and never revisited.)
  ///
  /// But a flat long interval is wrong too: a transfer only flips to "completed" when
  /// a LATER poll finds every track present, so a 10-minute timer would leave a
  /// finished download showing "syncing" for ten minutes.
  ///
  /// So: poll briskly only while something is actually in flight, and back off hard
  /// once a poll does no work. A user gesture (pull-to-refresh) or foregrounding the
  /// app always polls immediately, which is what makes the idle interval affordable.
  private func scheduleNextCassettePoll() {
    cassetteIntentPollTimer?.invalidate()
    let didWork = IntentExecutor.shared.lastPollDidWork
    let interval: TimeInterval = didWork
      ? Self.cassetteActivePollInterval
      : Self.cassetteIdlePollInterval
    #if DEBUG
      print("Cassette poll: next in \(Int(interval))s (\(didWork ? "active" : "idle"))")
    #endif
    cassetteIntentPollTimer = Timer.scheduledTimer(
      withTimeInterval: interval,
      repeats: false
    ) { _ in
      Task { @MainActor in
        await IntentExecutor.shared.handlePendingIntents()
        self.scheduleNextCassettePoll()
      }
    }
  }

  private func stopCassetteIntentPolling() {
    #if DEBUG
      print("Cassette poll: backgrounded -> timer stopped")
    #endif
    cassetteIntentPollTimer?.invalidate()
    cassetteIntentPollTimer = nil
  }

  // MARK: - Cassette token revocation (unpair) handling

  /// When sync requests start 401ing, the device was unpaired from the
  /// account on the dashboard (its tokens were revoked) or the token
  /// expired. Offer to reconnect — once per launch, never silently.
  private func observeCassetteTokenRejection() {
    guard cassetteTokenRejectedObserver == nil else { return }
    cassetteTokenRejectedObserver = NotificationCenter.default.addObserver(
      forName: .cassetteTokenRejected,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.presentCassetteReconnectAlert()
      }
    }
  }

  @MainActor
  private func presentCassetteReconnectAlert() {
    guard !cassetteReconnectAlertShown else { return }
    guard let topVC = AppDelegate.topViewController() else { return }
    cassetteReconnectAlertShown = true
    #if DEBUG
      print("Cassette sync: token rejected -> showing reconnect alert")
    #endif

    let alert = UIAlertController(
      title: "Signed out",
      message: "This phone isn't signed in to Cassette anymore: it was signed out from your account, or went unused for 90 days. Sign in again to keep your music syncing.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Not now", style: .cancel))
    alert.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak self] _ in
      guard let self else { return }
      let reauth = CassetteTokenReauth()
      cassetteReauth = reauth
      reauth.start { token in
        Task { @MainActor in
          self.cassetteReauth = nil
          guard let token else {
            // Let a later 401 re-offer the alert if the user bailed out.
            self.cassetteReconnectAlertShown = false
            return
          }
          self.appDelegate.storage.settings.cassetteBearerToken = token
          #if DEBUG
            print("Cassette sync: reconnected, re-registering device")
          #endif
          Task {
            try? await CassetteSyncAPI.shared.registerDevice()
            await IntentExecutor.shared.handlePendingIntents()
          }
        }
      }
    })
    topVC.present(alert, animated: true)
  }

  func sceneWillResignActive(_ scene: UIScene) {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
    os_log("sceneWillResignActive", log: self.log, type: .info)
    guard appDelegate.isNormalInteraction else {
      return
    }
    appDelegate.quickActionsManager.configureQuickActions()
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
    os_log("sceneWillEnterForeground", log: self.log, type: .info)
    DiagnosticLog.shared.log(.lifecycle, "will enter foreground")
    AmperKit.shared.threadPerformanceMonitor.isInForeground = true
    // One Home: back at the front (or just opened), ask the cloud for Home again.
    Task { @MainActor in await HomeStore.shared.refresh() }
    // Signed in before the account had a computer: back from setting it up, connect (BUG-899).
    appDelegate.connectComputerIfReady()
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.

    // Save changes in the application's managed object context when the application transitions to the background.
    os_log("sceneDidEnterBackground", log: self.log, type: .info)
    // Cassette — Diagnostics Phase 1: this is a scene-based app, so the real
    // background hook is here (NOT AppDelegate.applicationDidEnterBackground,
    // which UIKit doesn't call once scenes are adopted). Flush immediately so
    // the trace pairs with a crash report if we're killed while backgrounded.
    DiagnosticLog.shared.log(.lifecycle, "entered background")
    DiagnosticLog.shared.flushNow()
    AmperKit.shared.threadPerformanceMonitor.isInForeground = false
    // cassette (BUG-039): durably persist any buffered device-ownership rows before
    // iOS suspends us, so a just-completed copy burst isn't lost (files-on-disk with
    // no ownership row = albums that never appear in the on-device library). Guarded
    // by a background-task assertion so the async flush has time to finish.
    let ownershipFlushTask = UIApplication.shared
      .beginBackgroundTask(withName: "digital.cassette.ownership-flush")
    Task {
      await CassetteTransferSession.shared.flushPending()
      await MainActor.run {
        if ownershipFlushTask !=
          .invalid { UIApplication.shared.endBackgroundTask(ownershipFlushTask) }
      }
    }
    stopCassetteIntentPolling()
    // cassette 2026-10-31 (I-P3): no wake-up every 45 minutes. Amperfy booked a background
    // refresh here that only fetched podcast episodes, which the app doesn't show; it woke the
    // app in the background for nothing (BUG-753 is a run of background kills, not proven
    // related).
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    os_log("openURLContexts", log: self.log, type: .info)
    guard appDelegate.isNormalInteraction else {
      return
    }
    for URLContext in URLContexts {
      _ = appDelegate.intentManager.handleIncoming(url: URLContext.url)
    }
  }

  // This is the NSUserActivity that will be used to restore state when the Scene reconnects.
  // It can be the same activity used for handoff or spotlight, or it can be a separate activity
  // with a different activity type and/or userInfo.
  // After this method is called, and before the activity is actually saved in the restoration file,
  // if the returned NSUserActivity has a delegate (NSUserActivityDelegate), the method
  // userActivityWillSave is called on the delegate. Additionally, if any UIResponders
  // have the activity set as their userActivity property, the UIResponder updateUserActivityState
  // method is called to update the activity. This is done synchronously and ensures the activity
  // has all info filled in before it is saved.
  func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
    os_log("stateRestorationActivity", log: self.log, type: .info)
    return nil
  }

  // This will be called after scene connection, but before activation, and will provide the
  // activity that was last supplied to the stateRestorationActivityForScene callback, or
  // set on the UISceneSession.stateRestorationActivity property.
  // Note that, if it's required earlier, this activity is also already available in the
  // UISceneSession.stateRestorationActivity at scene connection time.
  func scene(
    _ scene: UIScene,
    restoreInteractionStateWith stateRestorationActivity: NSUserActivity
  ) {
    os_log("restoreInteractionStateWith", log: self.log, type: .info)
  }

  func scene(_ scene: UIScene, willContinueUserActivityWithType userActivityType: String) {
    os_log("willContinueUserActivityWithType", log: self.log, type: .info)
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    os_log(
      "scene launch via userActivity: %s",
      log: self.log,
      type: .info,
      userActivity.activityType
    )
  }

  func scene(
    _ scene: UIScene,
    didFailToContinueUserActivityWithType userActivityType: String,
    error: Error
  ) {
    os_log("didFailToContinueUserActivityWithType", log: self.log, type: .info)
  }

  func scene(_ scene: UIScene, didUpdate userActivity: NSUserActivity) {
    os_log("didUpdate userActivity: %s", log: self.log, type: .info, userActivity.activityType)
  }
}
