//
//  FadeText.swift
//  Amperfy
//
//  Cassette fork (BUG-899): text that changes in place with a plain crossfade, for the
//  card's label, its body line and its button's label. The old line fades away where it
//  stood (280 ms) while the new one fades in (480 ms, 120 ms in), and the box eases to the
//  new text's size (the card's one sizing rule), so a line that wraps to two opens gently
//  instead of pushing everything under it at once. The board's FadeText, one for one.
//  Reduce Motion swaps the text at once.
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

struct FadeText: View {
  /// How the text is set. The card's three voices.
  enum Voice {
    /// The computer's name over the headline: Barlow Condensed Bold 13, tracked capitals.
    case label
    /// The one line under the headline: the system face, 17 on 24.
    case body
    /// The button's label: Barlow Condensed SemiBold 18.
    case button
  }

  let text: String
  var voice: Voice = .body
  var color: Color = CardColors.ink2
  /// Sits inline (the button's label): the box eases on both axes.
  var inline = false

  static let outFor: TimeInterval = 0.28
  static let inFor: TimeInterval = 0.48
  static let inAfter: TimeInterval = 0.12

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  @State
  private var current: Line
  @State
  private var leaving: Line?
  @State
  private var settled = true

  private struct Line: Equatable {
    var text: String
    var generation: Int
  }

  init(_ text: String, voice: Voice = .body, color: Color = CardColors.ink2, inline: Bool = false) {
    self.text = text
    self.voice = voice
    self.color = color
    self.inline = inline
    _current = State(initialValue: Line(text: text, generation: 0))
  }

  var body: some View {
    Group {
      if inline {
        styled(current.text)
          .opacity(settled ? 1 : 0)
          .animation(.easeOut(duration: Self.inFor).delay(Self.inAfter), value: settled)
          .id(current.generation)
          .overlay(alignment: .center) { leavingLine.fixedSize() }
          .easedSize()
      } else {
        styled(current.text)
          .opacity(settled ? 1 : 0)
          .animation(.easeOut(duration: Self.inFor).delay(Self.inAfter), value: settled)
          .id(current.generation)
          .frame(maxWidth: .infinity, alignment: .leading)
          .overlay(alignment: .topLeading) {
            leavingLine.fixedSize(horizontal: false, vertical: true)
          }
          .easedHeight()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(current.text)
    .onChange(of: text) { _, new in change(to: new) }
  }

  @ViewBuilder
  private var leavingLine: some View {
    if let leaving {
      styled(leaving.text)
        .opacity(settled ? 0 : 1)
        .animation(.easeOut(duration: Self.outFor), value: settled)
        .id(leaving.generation)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func styled(_ text: String) -> some View {
    switch voice {
    case .label:
      Text(text.uppercased())
        .font(.cassette(.sectionLabel))
        .tracking(1.4)
        .foregroundStyle(color)
    case .body:
      Text(text)
        .font(.system(size: 17))
        .lineSpacing(3)
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
    case .button:
      Text(text)
        .font(.cassette(.rowTitle))
        .foregroundStyle(color)
        .lineLimit(1)
    }
  }

  private func change(to new: String) {
    guard new != current.text else { return }
    let next = Line(text: new, generation: current.generation + 1)
    var quiet = Transaction()
    quiet.disablesAnimations = true
    if reduceMotion {
      withTransaction(quiet) {
        leaving = nil
        current = next
        settled = true
      }
      return
    }
    withTransaction(quiet) {
      leaving = current
      current = next
      settled = false
    }
    Task { @MainActor in
      // One frame drawn with the new text hidden and the old one whole, then both move.
      try? await Task.sleep(for: .milliseconds(24))
      guard current.generation == next.generation else { return }
      settled = true
      try? await Task.sleep(for: .seconds(Self.inAfter + Self.inFor + 0.1))
      guard current.generation == next.generation else { return }
      withTransaction(quiet) { leaving = nil }
    }
  }
}
