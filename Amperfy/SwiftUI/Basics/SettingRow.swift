//
//  SettingRow.swift
//  Amperfy
//
//  The one settings row on the iPhone, the twin of the kit's Panel rows (the account panes'
//  setting rows; design wave 6): the setting's name in the Settings sheet's face, its answer in
//  the quiet typewriter face at the row's end, and one trailing mark that says what a tap does.
//  Every Settings page draws its rows, its two-voice heads and its title through these, so the
//  pages under the front one stop speaking another app's voice (IOS-05).
//

import AmperfyKit
import SwiftUI

// MARK: - SettingRowTrailing

/// What a tap on the row does, said by its one trailing mark.
enum SettingRowTrailing {
  /// Opens another page: the kit's chevron.
  case opens
  /// Opens a small menu of choices in place: the up-and-down mark Apple's own menus wear, never
  /// the next-page chevron (IOS-15).
  case chooses
  /// Nothing, or something on the row itself.
  case none
}

// MARK: - SettingRowLabel

/// A setting: its name in Barlow, its answer in DM Mono ink2 at the end, then its trailing mark.
struct SettingRowLabel: View {
  let title: String
  var value: String?
  var trailing: SettingRowTrailing = .opens
  var tone: SettingRowTone = .normal

  var body: some View {
    HStack(spacing: 12) {
      Text(title)
        .font(.cassette(.rowTitle))
        .foregroundStyle(tone.color)
        .lineLimit(1)
      Spacer(minLength: 8)
      if let value, !value.isEmpty {
        Text(value)
          .font(.cassette(.caption))
          .foregroundStyle(Color.cassette(.textSecondary))
          .lineLimit(1)
      }
      SettingRowMark(trailing: trailing)
    }
    .frame(maxWidth: .infinity, minHeight: 50)
    .contentShape(Rectangle())
  }
}

// MARK: - SettingRowTone

/// A row's voice: a setting, or the one that can't be undone (in the kit's danger ink).
enum SettingRowTone {
  case normal
  case destructive

  var color: Color {
    switch self {
    case .normal: Color.cassette(.textPrimary)
    case .destructive: Color(uiColor: CoverTint.dangerText)
    }
  }
}

// MARK: - SettingRowMark

/// The row's trailing mark in ink3.
struct SettingRowMark: View {
  let trailing: SettingRowTrailing

  var body: some View {
    switch trailing {
    case .opens:
      Image(uiImage: CassetteIcon.chevronRight.uiImage(size: .row, weight: .semibold))
        .renderingMode(.template)
        .foregroundStyle(Color.cassette(.textTertiary))
        .accessibilityHidden(true)
    case .chooses:
      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.cassette(.textTertiary))
        .accessibilityHidden(true)
    case .none:
      EmptyView()
    }
  }
}

// MARK: - SettingLink

/// A setting row that opens `destination`, with the kit's chevron (the system one is hidden
/// with the link).
struct SettingLink<Destination: View>: View {
  let title: String
  let value: String?
  let destination: () -> Destination

  init(
    _ title: String,
    value: String? = nil,
    @ViewBuilder destination: @escaping () -> Destination
  ) {
    self.title = title
    self.value = value
    self.destination = destination
  }

  var body: some View {
    ZStack {
      NavigationLink(destination: destination) { EmptyView() }
        .opacity(0)
      SettingRowLabel(title: title, value: value)
    }
  }
}

// MARK: - SettingAction

/// A setting row that does one thing when tapped (Sign out, Resync library).
struct SettingAction: View {
  let title: String
  var tone: SettingRowTone = .normal
  let action: () -> ()

  var body: some View {
    Button(action: action) {
      SettingRowLabel(title: title, trailing: .none, tone: tone)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - SettingsHead

/// A two-voice section head on a Settings page: the shout in ink, the answer in the kit's
/// italic, orange (R-orange-accent: the phones' quiet tan answers on tool screens are drift and
/// go orange). One line, 20pt from the screen edge.
struct SettingsHead: View {
  let shout: String
  let answer: String?

  var body: some View {
    CassetteHeadingText(
      shout: shout,
      answer: answer,
      answerColor: Color.cassette(.accentAnswer)
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 16)
    .padding(.bottom, 10)
    .padding(.leading, 4)
    .listRowInsets(EdgeInsets())
    .textCase(nil)
  }
}

// MARK: - The page's title

extension View {
  /// A Settings page's title in the sheet's own face (the kit's navTitle, Barlow 18), where
  /// SwiftUI's bar would otherwise set it in Apple's (IOS-05). The plain title stays for the
  /// back button and VoiceOver.
  func cassetteSettingsTitle(_ title: String) -> some View {
    navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Text(title)
            .font(.cassette(.navTitle))
            .foregroundStyle(Color.cassette(.textPrimary))
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
        }
      }
  }
}
