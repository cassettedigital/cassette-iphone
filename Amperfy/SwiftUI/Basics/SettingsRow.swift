//
//  SettingsRow.swift
//  Amperfy
//
//  Created by David Klopp on 14.08.24.
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

import AmperfyKit
import Foundation
import SwiftUI

// MARK: - SettingsRow

struct SettingsRow<Content: View>: View {
  enum Orientation {
    case vertical
    case horizontal
  }

  let title: String?
  let detail: () -> Content
  let orientation: Orientation
  let splitPercentage: CGFloat

  init(
    title: String? = nil,
    orientation: Orientation = .horizontal,
    splitPercentage: CGFloat = 0.4,
    @ViewBuilder detail: @escaping () -> Content
  ) {
    self.title = title
    self.detail = detail
    self.orientation = orientation
    self.splitPercentage = min(max(splitPercentage, 0.0), 1.0)
  }

  // cassette 2026-10-31 (I-S11): the row title in the Settings sheet's own face (`.rowTitle`,
  // as its front page draws "Albums on this phone"), so the pages under it stop reading as
  // another app. Was `.body`, the system font (Patch 032), from before the sheet was redrawn.
  private func titleText(_ value: String) -> some View {
    Text(value)
      .font(.cassette(.rowTitle))
      .foregroundColor(Color.cassette(.textPrimary))
  }

  var body: some View {
    if orientation == .horizontal {
      HStack {
        if let title {
          titleText(title)
        }
        Spacer()
        detail()
      }
    } else {
      VStack(alignment: .leading) {
        if let title {
          titleText(title)
            .padding([.bottom], 2)
        }
        detail()
      }
    }
  }
}

// MARK: - SettingsCheckBoxRow

struct SettingsCheckBoxRow: View {
  let title: String
  let isOn: Binding<Bool>
  let splitPercentage: CGFloat

  init(title: String, splitPercentage: CGFloat = 0.4, isOn: Binding<Bool>) {
    self.title = title
    self.isOn = isOn
    self.splitPercentage = splitPercentage
  }

  var body: some View {
    SettingsRow(title: title, splitPercentage: splitPercentage) {
      Toggle(isOn: isOn) {}
        .toggleStyle(.switch)
    }
  }
}

// MARK: - SettingsButtonRow

struct SettingsButtonRow: View {
  enum ActionType {
    case normal
    case destructive
    case done

    var foregroundColor: Color? {
      switch self {
      case .normal: nil
      case .destructive: Color(uiColor: CoverTint.dangerText)
      case .done: Color.cassette(.textPrimary)
      }
    }
  }

  let title: String
  let actionType: ActionType
  let action: () -> ()
  let splitPercentage: CGFloat

  init(
    title: String,
    actionType: ActionType = .normal,
    splitPercentage: CGFloat = 0.4,
    action: @escaping () -> ()
  ) {
    self.title = title
    self.actionType = actionType
    self.action = action
    self.splitPercentage = splitPercentage
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.cassette(.rowTitle))
    }.foregroundColor(actionType.foregroundColor)
  }
}
