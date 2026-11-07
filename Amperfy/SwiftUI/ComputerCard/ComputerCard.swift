//
//  ComputerCard.swift
//  Amperfy
//
//  Cassette fork (BUG-899): the first-run Home's one card for the computer. Until the
//  phone has music, Home leads with it: the computer's name, its state in a few words, one
//  line on what happens next, and either the library strip (music on its way, or the
//  computer getting ready, or out of reach) or one button where the person can act. The
//  founder picked it 2026-11-07 ("it looks like a skeleton state taking action. Which is
//  assuring"). Built from the three parts only (BlurText, FadeText, LibraryStrip), so one
//  state turns into the next without anything sliding in: the headline changes word by
//  word, the rest crossfades, and the card eases to its new size.
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

struct ComputerCard: View {
  /// Where the computer and this phone stand, in the card's six states.
  enum Phase: String, CaseIterable, Sendable {
    /// Music on its way to the phone.
    case syncing
    /// The computer is still reading its library (or the cloud has not queued anything yet).
    case gettingReady
    /// The computer can't be reached.
    case outOfReach
    /// The computer has no music in Cassette.
    case noMusic
    /// The account syncs only chosen music, and nothing is chosen for this phone (BUG-898).
    case nothingChosen
    /// No computer on the account yet.
    case notSetUp
  }

  /// A button on the card: what it says and the site page it opens.
  struct Action: Equatable {
    let title: String
    let path: String
  }

  /// Everything the card draws.
  struct Content: Equatable {
    var phase: Phase
    /// The small label over the headline: the computer's name, or "Your computer" while
    /// there is none (the one fallback every surface uses, `CassetteSyncStatus.fallbackHubName`).
    var label: String
    /// Albums on this phone, and how many there will be once the albums waiting are in.
    var onPhone = 0
    var total = 0
    /// The newest albums on this phone, newest first.
    var covers: [LibraryStrip.Cover] = []

    var headline: String {
      switch phase {
      case .syncing: return "Syncing"
      case .gettingReady: return "Getting ready"
      case .outOfReach: return "Out of reach"
      case .noMusic: return "No music yet"
      case .nothingChosen: return "Nothing chosen"
      case .notSetUp: return "Not set up"
      }
    }

    var body: String {
      switch phase {
      case .syncing:
        return "\(onPhone) of \(max(total, onPhone)) \(max(total, onPhone) == 1 ? "album" : "albums") on this phone"
      case .gettingReady: return "Reading your library"
      case .outOfReach: return "New music arrives when it's back"
      case .noMusic: return "Add music to Cassette on your computer"
      case .nothingChosen: return "Pick the music for this phone in Cassette on your computer"
      case .notSetUp: return "Your music plays from Cassette on your computer"
      }
    }

    /// One button only where the person can act; none while they wait.
    var action: Action? {
      switch phase {
      case .syncing, .gettingReady, .outOfReach: return nil
      case .noMusic: return Action(title: "How to add music", path: "/help/adding-music")
      case .nothingChosen: return Action(title: "How to choose music", path: "/help/choose-albums-for-phone")
      case .notSetUp: return Action(title: "Get it for your computer", path: "/apps")
      }
    }

    /// The library strip's mode, or nil when the card shows its button instead.
    var stripMode: LibraryStrip.Mode? {
      switch phase {
      case .gettingReady: return .skeleton
      case .syncing: return covers.isEmpty ? .skeleton : .covers
      case .outOfReach: return covers.isEmpty ? .skeleton : .still
      case .noMusic, .nothingChosen, .notSetUp: return nil
      }
    }

    var progress: Double {
      guard total > 0 else { return 0 }
      return Double(onPhone) / Double(total)
    }
  }

  let content: Content
  var onAction: (Action) -> () = { _ in }

  /// The card's insets: 24 inside, as on the board.
  static let padding: CGFloat = 24
  static let radius: CGFloat = 20

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      FadeText(content.label, voice: .label)
      BlurText(content.headline)
        .padding(.top, 8)
      FadeText(content.body, voice: .body)
        .padding(.top, 8)
      media
        .padding(.top, 24)
    }
    .padding(Self.padding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        .fill(CardColors.card)
        .shadow(color: Color.black.opacity(0.05), radius: 1, y: 1)
        .shadow(color: Color.black.opacity(0.06), radius: 15, y: 10)
    }
    .accessibilityElement(children: .contain)
  }

  /// The strip or the button, crossfading in place; the slot eases to whichever is in.
  private var media: some View {
    VStack(spacing: 0) {
      if let mode = content.stripMode {
        LibraryStrip(mode: mode, covers: content.covers, progress: content.progress)
          .transition(CardMotion.group)
      }
      if let action = content.action {
        CardButton(action: action) { onAction(action) }
          .transition(CardMotion.group)
      }
    }
    .easedHeight()
  }
}

/// The card's one button: full width, 52 pt, ink with the page's colour on it, an arrow.
/// Across the states that have one it stays put; only its label fades.
private struct CardButton: View {
  let action: ComputerCard.Action
  let tap: () -> ()

  var body: some View {
    Button(action: tap) {
      HStack(spacing: 8) {
        FadeText(action.title, voice: .button, color: CardColors.onInk, inline: true)
        Image(systemName: "arrow.right")
          .font(.system(size: 15, weight: .bold))
          .foregroundStyle(CardColors.onInk)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 52)
      .background(Capsule().fill(CardColors.ink))
      .contentShape(Capsule())
    }
    .buttonStyle(CardButtonStyle())
    .accessibilityLabel(action.title)
    .accessibilityAddTraits(.isLink)
  }
}

private struct CardButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.82 : 1)
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
  }
}
