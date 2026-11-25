//
//  DisplaySettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 30.12.23.
//  Copyright (c) 2023 Maximilian Bauer. All rights reserved.
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

// MARK: - AppIconSettingsView

// cassette §F: the App Icon picker (file name kept as DisplaySettingsView.swift
// to avoid .pbxproj churn — rename deferred). Replaces the old System/Light/Dark
// Appearance picker; the app is dark-locked at the Info.plist level (handled in
// the §F asset pass). The grid auto-discovers the primary icon plus any
// alternates declared in Info.plist (CFBundleIcons → CFBundleAlternateIcons),
// so dropping the founder's PNGs into the asset catalog + declaring them is all
// that's needed — no code change here.
struct AppIconSettingsView: View {
  @State
  private var selectedIconName: String? = nil // nil == primary icon

  private let columns = [GridItem(.adaptive(minimum: 84), spacing: 16)]

  var body: some View {
    ZStack {
      SettingsList {
        SettingsSection(
          content: {
            LazyVGrid(columns: columns, spacing: 16) {
              ForEach(AppIconOption.all) { option in
                iconCell(option)
              }
            }
            .padding(.vertical, 8)
          },
          footer: AppIconOption.all.count > 1
            ?
            "Choose how Cassette looks on your Home Screen. iOS shows a brief confirmation when the icon changes."
            : "More icons are on the way."
        )
      }
    }
    .cassetteSettingsTitle("App Icon")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      selectedIconName = UIApplication.shared.alternateIconName
    }
  }

  @ViewBuilder
  private func iconCell(_ option: AppIconOption) -> some View {
    let isSelected = option.alternateName == selectedIconName
    Button {
      setIcon(option.alternateName)
    } label: {
      VStack(spacing: 6) {
        Group {
          if let image = option.previewImage {
            Image(uiImage: image).resizable().scaledToFill()
          } else {
            RoundedRectangle(cornerRadius: 14).fill(Color.cassette(.surfaceElevated))
          }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
          RoundedRectangle(cornerRadius: 14)
            .stroke(isSelected ? Color.cassette(.fillSelected) : Color.clear, lineWidth: 2)
        )
        Text(option.label)
          .font(.caption)
          .foregroundStyle(isSelected ? Color.cassette(.textPrimary) : Color.cassette(.textTertiary))
          .lineLimit(1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func setIcon(_ name: String?) {
    guard UIApplication.shared.supportsAlternateIcons else { return }
    guard name != UIApplication.shared.alternateIconName else { return }
    UIApplication.shared.setAlternateIconName(name) { error in
      Task { @MainActor in
        if error == nil {
          selectedIconName = name
        }
      }
    }
  }
}

// MARK: - AppIconOption

private struct AppIconOption: Identifiable {
  let alternateName: String? // nil == primary
  let label: String
  let iconFileName: String?

  var id: String { alternateName ?? "__primary__" }

  var previewImage: UIImage? {
    guard let iconFileName else { return nil }
    return UIImage(named: iconFileName)
  }

  /// Auto-discovered from Info.plist: primary first, then each alternate.
  static var all: [AppIconOption] {
    var options: [AppIconOption] = []
    let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]

    let primaryFiles = (icons?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"]
      as? [String]
    options.append(AppIconOption(
      alternateName: nil,
      label: "Classic",
      iconFileName: primaryFiles?.last
    ))

    if let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any] {
      for key in alternates.keys.sorted() {
        let files = (alternates[key] as? [String: Any])?["CFBundleIconFiles"] as? [String]
        options.append(AppIconOption(
          alternateName: key,
          label: key,
          iconFileName: files?.last
        ))
      }
    }
    return options
  }
}

// MARK: - AppIconSettingsView_Previews

struct AppIconSettingsView_Previews: PreviewProvider {
  static var previews: some View {
    AppIconSettingsView()
  }
}
