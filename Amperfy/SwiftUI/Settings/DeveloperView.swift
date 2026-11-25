//
//  DeveloperView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 14.06.24.
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

// MARK: - DeveloperView

struct DeveloperView: View {
  @EnvironmentObject
  private var settings: Settings

  func generateDefaultArtworks() {
    for artworkType in ArtworkType.allCases {
      for lightDarkMode in LightDarkModeType.allCases {
        for theme in ThemePreference.allCases {
          let name = theme.description + artworkType.description + lightDarkMode
            .description + ".png"
          let img = UIImage.generateArtwork(
            theme: theme,
            lightDarkMode: lightDarkMode,
            artworkType: artworkType
          )
          let fileURL = URL(string: name)!
          let absFilePath = CacheFileManager.shared.getAbsoluteAmperfyPath(relFilePath: fileURL)!
          try? CacheFileManager.shared.writeDataExcludedFromBackup(
            data: img.pngData()!,
            to: absFilePath,
            accountInfo: nil
          )
        }
      }
    }
  }

  // Cassette fork — Layer 3 Phase 3.1 debug affordances.

  /// Manually trigger the same poll the foreground timer runs. Logs whether a
  /// bearer token is present so the console makes the cause obvious.
  private func cassetteSyncNow() {
    let hasToken = appDelegate.storage.settings.cassetteBearerToken != nil
    print("Cassette poll: 'Sync now' tapped (bearer token present=\(hasToken))")
    Task { await IntentExecutor.shared.handlePendingIntents() }
  }

  /// Re-run the Cassette web-auth flow purely to mint + persist a fresh bearer
  /// token for the already-logged-in account, then kick off a sync.
  private func cassetteRelink() {
    print("Cassette re-link: 'Re-link Cassette' tapped")
    let reauth = CassetteTokenReauth()
    reauth.start { token in
      guard let token else { return }
      appDelegate.storage.settings.cassetteBearerToken = token
      print("Cassette re-link: token persisted, registering device + triggering immediate sync")
      Task {
        try? await CassetteSyncAPI.shared.registerDevice()
        await IntentExecutor.shared.handlePendingIntents()
      }
    }
  }

  var body: some View {
    ZStack {
      SettingsList {
        SettingsSection(content: {
          SettingsButtonRow(title: "Generate Default Artworks") {
            generateDefaultArtworks()
          }
        })

        // Cassette fork — Layer 3 Phase 3.1 sync debugging.
        SettingsSection(content: {
          SettingsButtonRow(title: "Sync now") {
            cassetteSyncNow()
          }
          SettingsButtonRow(title: "Re-link Cassette (get sync token)") {
            cassetteRelink()
          }
        })
      }
    }
    .cassetteSettingsTitle("Developer")
    .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - DeveloperView_Previews

struct DeveloperView_Previews: PreviewProvider {
  @State
  static var settings = Settings()

  static var previews: some View {
    DeveloperView().environmentObject(settings)
  }
}
