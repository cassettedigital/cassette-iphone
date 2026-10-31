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
  private func forgetCassetteSignIn() {
    storage.settings.cassetteBearerToken = nil
    CassetteSyncAPI.forgetAccount()
    RadioSaved.shared.forget()
    let site = WKWebsiteDataStore.default()
    Task { @MainActor in
      let all = WKWebsiteDataStore.allWebsiteDataTypes()
      let records = await site.dataRecords(ofTypes: all)
      await site.removeData(ofTypes: all, for: records.filter { $0.displayName.hasSuffix("cassette.digital") })
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
