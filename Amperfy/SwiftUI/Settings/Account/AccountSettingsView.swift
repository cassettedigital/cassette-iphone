//
//  AccountSettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 14.09.22.
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
import SwiftUI

// MARK: - AccountSettingsView

struct AccountSettingsView: View {
  let splitPercentage = 0.25

  @State
  var isPwUpdateDialogVisible = false
  @State
  var isShowResyncLibraryAlert = false
  @EnvironmentObject
  var settings: Settings

  func setThemePreference(preference: ThemePreference) {
    // cassette Patch 052 (Phase G): theme color pins to ink explicitly. The
    // ThemePreference enum is retained for Core Data migration safety but
    // all cases resolve to ink (SettingEnumerations.asColor); doing this
    // explicitly removes the indirection.
    settings.themePreference = preference
    appDelegate.setAppTheme(color: UIColor.cassette(.textPrimary))
    appDelegate.applyAppThemeToAlreadyLoadedViews()
  }

  private func resyncLibrary(accountInfo: AccountInfo) {
    appDelegate.closeAllButActiveMainTabs()
    if appDelegate.storage.settings.accounts.allAccounts.count <= 1 {
      appDelegate.stopForInit()
    }

    let meta = appDelegate.getMeta(accountInfo)
    meta.stopManager()
    appDelegate.resetMeta(accountInfo)

    // reset quick actions
    appDelegate.quickActionsManager.configureQuickActions()
    appDelegate.configureMainMenu()

    appDelegate.storage.settings.user.isOfflineMode = false
    let account = appDelegate.storage.main.library.getAccount(info: accountInfo)
    appDelegate.player.logout(account: account)
    let syncVC = AppStoryboard.Main.segueToSync(account: account)
    syncVC.modalPresentationStyle = .formSheet
    AppDelegate.mainSceneDelegate?.window?.rootViewController?.dismiss(animated: false)
    AppDelegate.mainSceneDelegate?.window?.rootViewController?.present(syncVC, animated: true)
  }

  /// Whether a Cassette account still resyncs here: only on Mac Catalyst, where the
  /// Settings root has no YOUR MAC group to carry the lighter resync.
  private static var keepsResyncForCassette: Bool {
    #if targetEnvironment(macCatalyst)
      return true
    #else
      return false
    #endif
  }

  /// cassette: a Cassette-paired account's Subsonic login is a `cassette-*`
  /// machine credential the desktop Player mints AND manages automatically at
  /// pairing. The stock "Update Password" screen is LOCAL-ONLY — it changes
  /// Navidrome + the on-device keychain but never the cloud — so a manual change
  /// here silently diverges from the authoritative cloud credential and breaks on
  /// the next re-pair. Hide it for Cassette accounts; manual (generic Subsonic)
  /// accounts still get it.
  private func isCassetteAccount(_ info: AccountInfo) -> Bool {
    (
      appDelegate.storage.settings.accounts.getSetting(info).read
        .loginCredentials?.username ?? ""
    ).hasPrefix("cassette-")
  }

  var body: some View {
    ZStack {
      SettingsList {
        if let activeAccountInfo = settings.activeAccountInfo {
          // cassette polish Part 6: server URL, transcoding, scrobble, Auto
          // Cache, backend/API-version rows, and Manage Server URLs are hidden.
          // Pairing owns the connection; protocol details don't surface here.
          // cassette: this row used to show the raw Subsonic machine login
          // (loginCredentials.username, e.g. "cassette-qsvdgam0") — a device
          // credential the desktop mints at pairing, NOT the user's identity, which
          // read as "that is not my username". Show the real Cassette account
          // instead: name, then email — the same identity the account menu already
          // leads with (CassetteSyncAPI, sourced from /api/sync/account). Falls back
          // to "Connected" before the first sync lands, and never surfaces the token.
          SettingsSection {
            SettingsRow(
              title: "Account",
              orientation: .vertical,
              splitPercentage: splitPercentage
            ) {
              SecondaryText(
                CassetteSyncAPI.accountName ?? CassetteSyncAPI
                  .accountEmail ?? "Connected"
              )
            }
            if CassetteSyncAPI.accountName != nil,
               let email = CassetteSyncAPI.accountEmail {
              SettingsRow(
                title: "Email",
                orientation: .vertical,
                splitPercentage: splitPercentage
              ) {
                SecondaryText(email)
              }
            }
          }

          // Phone-taste: on iOS a Cassette account resyncs from the YOUR MAC group on the
          // Settings root (the Mac rescans, the music keeps playing). This full re-read, which
          // stops playback and rebuilds the app, stays for generic Subsonic accounts, and on
          // Mac Catalyst, whose Settings has no YOUR MAC group.
          if !isCassetteAccount(activeAccountInfo) || Self.keepsResyncForCassette {
            SettingsSection {
              if !isCassetteAccount(activeAccountInfo) {
                SettingsButtonRow(title: "Update Password") {
                  withPopupAnimation { isPwUpdateDialogVisible = true }
                }
              }
              SettingsButtonRow(title: "Resync Library") {
                isShowResyncLibraryAlert = true
              }.alert(isPresented: $isShowResyncLibraryAlert) {
                Alert(
                  title: Text("Resync Library"),
                  message: Text(
                    "This reads your library again from your computer. The music on this phone stays.\n\nResync now?"
                  ),
                  primaryButton: .destructive(Text("Resync")) {
                    resyncLibrary(accountInfo: activeAccountInfo)
                  },
                  secondaryButton: .cancel()
                )
              }
            }
          }

          SettingsSection {
            SettingsButtonRow(title: "Sign Out", actionType: .destructive) {
              appDelegate.presentLogoutChoice(for: activeAccountInfo)
            }
          }

          // BUG-884: deleting the account starts here and happens on the website's Account
          // page, opened in the app (Apple 5.1.1(v)). Once it is gone, the phone's next call
          // is refused and it says it was signed out.
          if isCassetteAccount(activeAccountInfo) {
            SettingsSection {
              NavigationLink {
                CassetteWebPage(path: "/settings", title: "Account")
                  .ignoresSafeArea(edges: .bottom)
              } label: {
                Text("Delete Account")
                  .font(.cassette(.rowTitle))
                  .foregroundStyle(Color(uiColor: CoverTint.dangerText))
              }
            }
          }
        } else {
          // Not signed in yet
          SettingsSection {
            SecondaryText("You aren't signed in yet.")
          }
        }
      }
    }
    .navigationTitle("Account")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $isPwUpdateDialogVisible) {
      UpdatePasswordView(isVisible: $isPwUpdateDialogVisible)
    }
  }
}

// MARK: - AccountSettingsView_Previews

struct AccountSettingsView_Previews: PreviewProvider {
  static var previews: some View {
    AccountSettingsView()
  }
}
