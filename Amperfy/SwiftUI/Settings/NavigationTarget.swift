//
//  NavigationTarget.swift
//  Amperfy
//
//  Created by David Klopp on 15.08.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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
import SwiftUI

@MainActor
enum NavigationTarget: String, CaseIterable, @MainActor Identifiable {
  // cassette §G: settings restructured to Account · Playback · App Icon ·
  // Storage · Support · About · Advanced. Several destination views are
  // repurposed in place (the file names still reflect their old role — a
  // file-rename cleanup is deferred to avoid .pbxproj churn):
  //   Playback  → PlaybackSettingsView   (Player/PlayerSettingsView.swift)
  //   App Icon  → AppIconSettingsView    (DisplaySettingsView.swift)
  //   Storage   → StorageSettingsView    (LibrarySettingsView.swift)
  //   About     → AboutSettingsView      (LicenseSettingsView.swift)
  //   Advanced  → AdvancedSettingsView   (XCallbackURLsSetttingsView.swift)
  case general
  case account
  case playback
  case equalizer
  case appIcon
  case storage
  case support
  case about
  case advanced
  #if DEBUG
    case developer = "developer"
  #endif

  var id: String { rawValue }

  func view() -> any View {
    switch self {
    case .general: SettingsView()
    case .account: AccountSettingsView()
    case .playback: PlaybackSettingsView()
    case .equalizer: EqualizerSettingsView()
    case .appIcon: AppIconSettingsView()
    case .storage: StorageSettingsView()
    case .support: SupportSettingsView()
    case .about: AboutSettingsView()
    case .advanced: AdvancedSettingsView()
    #if DEBUG
      case .developer: DeveloperView()
    #endif
    }
  }

  var displayName: String {
    switch self {
    case .general: "General"
    case .account: "Account"
    case .playback: "Playback"
    case .equalizer: "Equalizer"
    case .appIcon: "App Icon"
    case .storage: "Storage"
    // the one Feedback door every surface names (the founder, 2026-11-20)
    case .support: "Feedback"
    case .about: "About"
    case .advanced: "Advanced"
    #if DEBUG
      case .developer: "Developer (debug)"
    #endif
    }
  }

  @MainActor
  var icon: UIImage {
    switch self {
    case .general: .settings
    case .account: .userPerson
    case .playback: .playCircle
    case .equalizer: .equalizer
    case .appIcon: .photo
    case .storage: .musicLibrary
    case .support: .person
    case .about: .doc
    case .advanced: .settings
    #if DEBUG
      case .developer: .hammer
    #endif
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gear"
    case .account: "person.fill"
    case .playback: "play.circle.fill"
    case .equalizer: "chart.bar.xaxis"
    case .appIcon: "app.badge.fill"
    case .storage: "internaldrive.fill"
    case .support: "person.circle"
    case .about: "info.circle.fill"
    case .advanced: "gearshape.2.fill"
    #if DEBUG
      case .developer: "hammer.circle.fill"
    #endif
    }
  }
}
