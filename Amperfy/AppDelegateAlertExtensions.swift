//
//  AppDelegateAlertExtensions.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 13.10.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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
import Foundation
import NotificationBannerSwift
import OSLog
import UIKit
import WebKit

extension AppDelegate {
  static var mainSceneDelegate: SceneDelegate? {
    UIApplication.shared.connectedScenes
      // only scenes that are attached
      .filter { $0.activationState.rawValue >= 0 }
      // sort order: foregroundActive < foregroundInactive < background
      // this places the active tab first
      .sorted { $0.activationState.rawValue < $1.activationState.rawValue }
      // only "main" scene delegates
      .compactMap { $0.delegate as? SceneDelegate }.first
  }

  public func closeAllButActiveMainTabs() {
    var allMainScenes = UIApplication.shared.connectedScenes
      // only scenes that are attached
      .filter { $0.activationState.rawValue >= 0 }
      // sort order: foregroundActive < foregroundInactive < background
      // this places the active tab first
      .sorted { $0.activationState.rawValue < $1.activationState.rawValue }
      // only "main" scene delegates
      .filter { $0.delegate is SceneDelegate }
    if !allMainScenes.isEmpty {
      allMainScenes.removeFirst()
    }
    for scene in allMainScenes {
      terminateScene(scene)
    }
  }

  /// The one logout prompt (Settings > Account and the profile menu both use it). Logging
  /// out never decides for the person what happens to their music: the music synced from
  /// their hub can stay on the phone or be removed. Playlists, likes and listens live in
  /// the cloud either way, so the prompt says so.
  func presentLogoutChoice(for accountInfo: AccountInfo) {
    guard let topView = Self.topViewController() else { return }
    // The person's Cassette account, never the `cassette-*` machine login the hub mints.
    let name = CassetteSyncAPI.accountName ?? CassetteSyncAPI.accountEmail
    let alert = UIAlertController(
      title: name.map { "Sign out of \($0)?" } ?? "Sign out?",
      message: "Your playlists and listening history stay in your account. What should happen to the music on this phone?",
      preferredStyle: .alert
    )
    let keep = UIAlertAction(title: "Keep Music on This Phone", style: .default) { _ in
      self.logoutAccount(accountInfo, removeMusic: false)
    }
    alert.addAction(keep)
    alert.addAction(UIAlertAction(title: "Remove Music from This Phone", style: .destructive) { _ in
      self.logoutAccount(accountInfo, removeMusic: true)
    })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    // No preferredAction: iOS 26 fills it with the app tint (cream) and forces white text,
    // which is unreadable. Keep leads the list instead.
    topView.present(alert, animated: true)
  }

  /// Signing out signs out of Cassette (BUG-619): the sign-in pass and what the phone kept for the person
  /// go (CassetteSyncAPI.forgetAccount), the saved stations with them, and the in-app web pages
  /// (CassetteWebPageVC) forget their website session. Before this, "Log Out" showed the sign-in screen
  /// while the phone stayed signed in underneath, and the next sign-in re-paired without asking.
  /// The in-app web pages forget every site, not only cassette.digital: a YouTube or Google sign-in
  /// made inside a page stayed behind for whoever signed in next (BUG-891).
  private func forgetCassetteSignIn() {
    if let token = storage.settings.cassetteBearerToken {
      Task { await CassetteSyncAPI.revokeSignIn(token) }
    }
    storage.settings.cassetteBearerToken = nil
    CassetteSyncAPI.forgetAccount()
    RadioSaved.shared.forget()
    let site = WKWebsiteDataStore.default()
    Task { @MainActor in
      await site.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
  }

  /// Patch 111 (5): full account teardown, extracted from AccountSettingsView
  /// so the profile menu's "Log Out" can reuse it. Stops the account's manager,
  /// drops credentials, then either switches to the next account or returns to the
  /// login screen. Music synced from the hub (CassetteMusic + ownership records) and the
  /// account's cache (covers) are removed only when the person chose that; they used to be
  /// cache-deleted on every logout while the warning claimed all music went with it.
  public func logoutAccount(_ accountInfo: AccountInfo, removeMusic: Bool) {
    closeAllButActiveMainTabs()
    if storage.settings.accounts.allAccounts.count <= 1 {
      stopForInit()
    }

    let meta = getMeta(accountInfo)
    meta.stopManager()
    resetMeta(accountInfo)

    if removeMusic {
      do {
        try DeviceOwnershipManager(context: storage.main.context).removeAll()
      } catch {
        os_log("Logout: removing synced music failed: %{public}@", type: .error, "\(error)")
      }
      CacheFileManager.shared.deleteAccountCache(accountInfo: accountInfo)
    }
    storage.settings.accounts.logout(accountInfo)
    notificationHandler.post(name: .accountDeleted, object: nil, userInfo: nil)
    notificationHandler.post(name: .accountActiveChanged, object: nil, userInfo: nil)

    quickActionsManager.configureQuickActions()
    configureMainMenu()

    storage.settings.user.isOfflineMode = false
    let account = storage.main.library.getAccount(info: accountInfo)
    player.logout(account: account)
    if let newActiveAccountInfo = storage.settings.accounts.active {
      let newActiveAccount = storage.main.library.getAccount(info: newActiveAccountInfo)
      closeAllButActiveMainTabs()
      setAppTheme(color: UIColor.cassette(.textPrimary))
      applyAppThemeToAlreadyLoadedViews()
      guard let mainScene = AppDelegate.mainSceneDelegate else { return }
      mainScene.replaceMainRootViewController(
        vc: AppStoryboard.Main.segueToMainWindow(account: newActiveAccount)
      )
    } else {
      // Nobody is signed in now, so the phone forgets the Cassette sign-in too (BUG-619).
      forgetCassetteSignIn()
      storage.settings.app.isLibrarySynced = false
      let loginVC = AppStoryboard.Main.segueToLogin()
      AppDelegate.mainSceneDelegate?.replaceMainRootViewController(vc: loginVC)
    }
  }

  private func terminateScene(_ scene: UIScene) {
    UIApplication.shared.requestSceneSessionDestruction(
      scene.session,
      options: nil,
      errorHandler: { error in
        os_log(
          "AppDelegate: terminateScene failed: %s",
          log: self.log,
          type: .info,
          error.localizedDescription
        )
      }
    )
  }

  static var window: UIWindow? {
    mainSceneDelegate?.window
  }

  static func rootViewController() -> UIViewController? {
    Self.window?.rootViewController
  }

  static func topViewController(
    base: UIViewController? =
      window?.rootViewController
  )
    -> UIViewController? {
    if base?.presentedViewController is UIAlertController {
      return base
    }
    if let nav = base as? UINavigationController {
      return topViewController(base: nav.visibleViewController)
    }
    if let tab = base as? TabBarVC {
      return tab
    }
    if let splitVC = base as? SplitVC {
      return splitVC
    }
    if let presented = base?.presentedViewController {
      return topViewController(base: presented)
    }
    return base
  }

  static var mainWindowHostVC: MainSceneHostingViewController? {
    guard let topView = Self.topViewController(),
          (UIApplication.shared.delegate as! AppDelegate).storage.settings.app.isLibrarySynced
    else { return nil }
    return AppStoryboard.Main.checkForMainWindow(vc: topView)
  }
}

// MARK: - A computer for a phone that signed in without one (BUG-876, BUG-899)

extension AppDelegate {
  private static var computerCheckInFlight = false
  private static var lastComputerCheckAt: Date?

  /// A phone signed in before its account had a computer: ask the cloud whether one has
  /// signed in since and, when it has, connect to it on its own. Called every few seconds
  /// while Home shows "Not set up" and whenever the app comes back to the front; at most one
  /// question every 10 seconds, and never for a phone that has its computer.
  func connectComputerIfReady() {
    let accounts = storage.settings.accounts
    guard let standIn = accounts.active,
          CassetteSyncStatus.isNoComputer(serverUrl: accounts.activeSetting.read.loginCredentials?.serverUrl),
          !Self.computerCheckInFlight
    else { return }
    if let last = Self.lastComputerCheckAt, Date().timeIntervalSince(last) < 10 { return }
    #if DEBUG
      let debugComputer = Self.debugComputerCredentials()
    #else
      let debugComputer: LoginCredentials? = nil
    #endif
    let token = storage.settings.cassetteBearerToken
    guard token != nil || debugComputer != nil else { return }
    Self.computerCheckInFlight = true
    Self.lastComputerCheckAt = Date()
    Task { @MainActor in
      defer { Self.computerCheckInFlight = false }
      let answer: CassetteComputerLogin.Answer
      if let debugComputer {
        answer = .computer(debugComputer)
      } else {
        answer = await CassetteComputerLogin.fetch(token: token ?? "")
      }
      guard case let .computer(credentials) = answer,
            // Signed out or switched meanwhile: leave it.
            storage.settings.accounts.active == standIn
      else { return }
      await connectComputer(credentials, replacing: standIn)
    }
  }

  /// The sign-in's last step (LoginVC.loginWithCredentials) for the computer that just
  /// arrived, then the stand-in goes, and the phone reads the computer's library as after
  /// sign-in. Nothing of the person's lives in the stand-in: no computer ever filled it, the
  /// music on the phone belongs to the phone rather than to a login, and playlists, likes and
  /// listens are in the cloud. The Cassette sign-in itself stays.
  private func connectComputer(_ handedOver: LoginCredentials, replacing standIn: AccountInfo) async {
    var credentials = handedOver
    var accountInfo = Account.createInfo(credentials: credentials)
    let meta = getMeta(accountInfo)
    guard let apiType = try? await CassetteComputerLogin.authenticate(credentials, meta: meta),
          storage.settings.accounts.active == standIn
    else { return } // asked again next time
    credentials.backendApi = apiType
    accountInfo = Account.createInfo(credentials: credentials)
    meta.backendApi.selectedApi = apiType
    meta.account.assignInfo(info: accountInfo)
    storage.main.saveContext()

    // The stand-in, taken down the way Sign out takes an account down, minus the sign-in.
    closeAllButActiveMainTabs()
    stopForInit()
    let standInMeta = getMeta(standIn)
    standInMeta.stopManager()
    resetMeta(standIn)
    player.logout(account: storage.main.library.getAccount(info: standIn))
    storage.settings.accounts.logout(standIn)

    storage.settings.accounts.login(credentials)
    meta.backendApi.provideCredentials(credentials: credentials)
    notificationHandler.post(name: .accountDeleted, object: nil, userInfo: nil)
    notificationHandler.post(name: .accountAdded, object: nil, userInfo: nil)
    notificationHandler.post(name: .accountActiveChanged, object: nil, userInfo: nil)
    AmperfyAppShortcuts.updateAppShortcutParameters()
    quickActionsManager.configureQuickActions()
    configureMainMenu()
    DiagnosticLog.shared.log(.lifecycle, "computer arrived: stand-in sign-in replaced")

    AppDelegate.mainSceneDelegate?.replaceMainRootViewController(
      vc: AppStoryboard.Main.segueToSync(account: meta.account)
    )
  }

  #if DEBUG
    /// Simulator check only: `-cassette.debug.computerAppears "<address>|<user>|<password>"`
    /// stands in for the cloud's answer once a computer has signed in.
    private static func debugComputerCredentials() -> LoginCredentials? {
      let launch = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
      guard let raw = launch["cassette.debug.computerAppears"] as? String else { return nil }
      let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard parts.count == 3 else { return nil }
      var credentials = LoginCredentials(
        serverUrl: parts[0],
        username: parts[1],
        password: parts[2],
        backendApi: .subsonic
      )
      credentials.activeBackendServerUrl = parts[0]
      return credentials
    }
  #endif
}

// MARK: - AppDelegate + AlertDisplayable

extension AppDelegate: AlertDisplayable {
  func display(
    title: String,
    subtitle: String,
    style: LogEntryType,
    notificationBanner popupVC: UIViewController
  ) {
    guard NotificationBannerQueue.default.numberOfBanners < 1,
          let topView = Self.topViewController(),
          topView.presentedViewController == nil,
          let _ = UIApplication.shared.mainWindow
    else { return }

    let banner = FloatingNotificationBanner(
      title: title,
      subtitle: subtitle,
      titleFont: UIFont.cassette(CassetteBannerStyle.titleFont),
      titleColor: UIColor.cassette(CassetteBannerStyle.textColor),
      subtitleFont: UIFont.cassette(CassetteBannerStyle.messageFont),
      subtitleColor: UIColor.cassette(CassetteBannerStyle.textColor),
      style: BannerStyle.from(logType: style),
      colors: AmperfyBannerColors()
    )

    // cassette Patch 040: a 1pt frame painted on the banner's root layer
    // (NotificationBannerSwift's contentView is internal; the banner's
    // backgroundColor is forwarded to it). Wave 3 (BRW-4): the frame carries the
    // severity, which the shared raised surface had lost: an error is framed in
    // the danger accent, anything else in the hairline.
    let accent = CassetteBannerKind(logType: style).accent
    banner.cassetteOnAppearanceChange { $0.layer.borderColor = UIColor.cassette(accent).cgColor }
    banner.layer.borderWidth = CassetteBannerStyle.borderWidth
    // 4-second auto-dismiss; tap or swipe-up still dismiss instantly.
    banner.duration = 4

    banner.onTap = {
      guard let topView = Self.topViewController(),
            topView.presentedViewController == nil
      else { return }
      topView.present(popupVC, animated: true, completion: nil)
    }

    if UIDevice.current.userInterfaceIdiom == .pad {
      banner.bannerHeight = 80
    } else if UIDevice.current.userInterfaceIdiom == .phone {
      banner.bannerHeight = 180
    } else { // mac
      banner.bannerHeight = 140
    }

    let topViewInset = UIEdgeInsets(
      top: 40,
      left: 24,
      bottom: 24,
      right: 24
    )
    banner.show(
      queuePosition: QueuePosition.back,
      bannerPosition: BannerPosition.top,
      on: topView,
      edgeInsets: topViewInset,
      cornerRadius: CassetteBannerStyle.cornerRadius,
      shadowOpacity: 0.5,
      shadowBlurRadius: 5
    )
  }

  func display(popup popupVC: UIViewController) {
    guard let topView = Self.topViewController(),
          topView.presentedViewController == nil
    else { return }
    popupVC.modalPresentationStyle = .overCurrentContext
    popupVC.modalTransitionStyle = .crossDissolve
    topView.present(popupVC, animated: true, completion: nil)
  }

  func createPopupVC(
    topic: String,
    shortMessage: String,
    detailMessage: String,
    logType: LogEntryType
  )
    -> UIViewController {
    let popupVC = NotificationDetailVC()
    popupVC.display(title: topic, message: detailMessage, type: logType)
    return popupVC
  }
}
