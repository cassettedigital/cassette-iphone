//
//  PlayerSettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 15.09.22.
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

// MARK: - PlaybackSettingsView

// cassette §G/§E: this is the "Playback" screen (file name kept as
// PlayerSettingsView.swift to avoid .pbxproj churn — rename deferred): the few
// playback prefs a normal listener would plausibly change. ReplayGain, Manual
// Playback, and Song Playback Resume were culled (§B/§D).
// Phone-taste: on iOS it is "Download quality", reached from the Settings root and from
// This Phone; the Equalizer moved up to its own root row.
struct PlaybackSettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  // cassette: the phone's "download quality" control. Reuses the existing
  // (previously hidden) cacheTranscodingFormatPreference, which the download
  // URL builder already honors: raw = the full-resolution original file,
  // mp3 = a smaller transcoded copy. Written straight through to the persisted
  // store, so no new SettingsHost binding is required.
  @State
  private var downloadQuality: CacheTranscodingFormatPreference = .raw

  // "Keep songs you stream" only makes sense in Server Mode (streaming the full
  // catalog). Outside it Cassette is download-first and nothing streams, so the
  // row is hidden. Reads the same flag the library filter uses.
  private var isServerModeOn: Bool {
    CassetteLibraryFilterProvider.shared.currentFilter == .everything
  }

  private static var title: String {
    #if targetEnvironment(macCatalyst)
      return "Playback"
    #else
      return "Download quality"
    #endif
  }

  private func downloadQualityLabel(_ pref: CacheTranscodingFormatPreference) -> String {
    switch pref {
    case .raw: return "Lossless (FLAC)"
    case .mp3, .serverConfig: return "High (MP3)"
    }
  }

  private func setDownloadQuality(_ pref: CacheTranscodingFormatPreference) {
    downloadQuality = pref
    appDelegate.storage.settings.user.cacheTranscodingFormatPreference = pref
    // Phase 2c: push the choice up to the hub (the web Devices page) and update
    // the key the download URL builder reads, so the web reflects it and the
    // next account sync won't clobber it. Fire-and-forget.
    let tier = pref == .raw ? "lossless" : "high"
    Task { try? await CassetteSyncAPI.shared.setDownloadQuality(tier) }
  }

  var body: some View {
    ZStack {
      SettingsList {
        SettingsSection(
          content: {
            SettingsRow(title: "Download quality") {
              Menu {
                Button("Lossless (FLAC)") { setDownloadQuality(.raw) }
                Button("High (MP3)") { setDownloadQuality(.mp3) }
              } label: {
                SettingsMenuValue(text: downloadQualityLabel(downloadQuality))
              }
            }
          },
          footer: "Sets the quality downloaded to this phone. Your computer always keeps the original files."
        )

        if isServerModeOn {
          SettingsSection(
            content: {
              SettingsCheckBoxRow(
                title: "Keep songs you stream",
                isOn: $settings.isPlayerAutoCachePlayedItems
              )
            },
            footer: "Save a copy on this device of anything you stream in Server Mode, so it's there next time without using data."
          )
        }

        // cassette §2 (decision answer): the Mac-only "Mini Player Always on
        // Top" control was collateral when the Display screen was removed.
        // Mac is shipping, so resurface it here — macCatalyst only.
        #if targetEnvironment(macCatalyst)
          SettingsSection(
            content: {
              SettingsCheckBoxRow(
                title: "Mini Player Always on Top",
                isOn: $settings.isMiniPlayerAlwaysOnTop
              )
            },
            footer: "Keep the mini player window floating above all other windows."
          )
        #endif
      }
    }
    .navigationTitle(Self.title)
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      appDelegate.userStatistics.visited(.settingsPlayer)
      // The account tier first: it is what the downloads follow (the download URL builder
      // reads it before the local choice), so the picker never shows Lossless while the
      // phone downloads MP3.
      if let tier = CassetteSyncAPI.downloadQualityTier {
        downloadQuality = tier == "lossless" ? .raw : .mp3
      } else {
        downloadQuality = appDelegate.storage.settings.user.cacheTranscodingFormatPreference
      }
    }
  }
}

// MARK: - PlaybackSettingsView_Previews

struct PlaybackSettingsView_Previews: PreviewProvider {
  @State
  static var settings = Settings()

  static var previews: some View {
    PlaybackSettingsView().environmentObject(settings)
  }
}
