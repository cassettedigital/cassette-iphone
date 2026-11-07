//
//  BlurText.swift
//  Amperfy
//
//  Cassette fork (BUG-899): the card's headline voice. A line that changes word by word:
//  the old words blur away in turn where they stood while the new ones come into focus in
//  turn, and the box eases to the new line (the card's one sizing rule). The board's
//  BlurText, one for one: out 300 ms, 50 ms apart, to an 8 pt blur; in 460 ms, starting
//  140 ms in and 80 ms apart. Reduce Motion swaps the line at once.
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

struct BlurText: View {
  let text: String
  var font: Font = .cassette(.heroTitle)
  var color: Color = CardColors.ink

  static let blur: CGFloat = 8
  static let outFor: TimeInterval = 0.3
  static let outStagger: TimeInterval = 0.05
  static let inFor: TimeInterval = 0.46
  static let inAfter: TimeInterval = 0.14
  static let inStagger: TimeInterval = 0.08

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  /// The line in place, and the one leaving (drawn over it, taking no room).
  @State
  private var current: Line
  @State
  private var leaving: Line?
  /// Flipped one frame after a change, so the new words are drawn hidden first.
  @State
  private var settled = true

  private struct Line: Equatable {
    var text: String
    var generation: Int
    var words: [String] { text.split(separator: " ").map(String.init) }
  }

  init(_ text: String, font: Font = .cassette(.heroTitle), color: Color = CardColors.ink) {
    self.text = text
    self.font = font
    self.color = color
    _current = State(initialValue: Line(text: text, generation: 0))
  }

  var body: some View {
    words(of: current, entering: true)
      // The full width, so the leaving line lays out as it stood (a shorter new line must
      // not squeeze the old one onto two lines over the text below).
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .topLeading) {
        if let leaving {
          words(of: leaving, entering: false)
            .accessibilityHidden(true)
        }
      }
      .easedHeight(clips: false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(current.text)
      .accessibilityAddTraits(.isHeader)
      .onChange(of: text) { _, new in change(to: new) }
  }

  private func words(of line: Line, entering: Bool) -> some View {
    WordFlow(spacing: wordSpace) {
      ForEach(Array(line.words.enumerated()), id: \.offset) { index, word in
        let hidden = entering ? !settled : settled
        Text(word)
          .font(font)
          .foregroundStyle(color)
          .opacity(hidden ? 0 : 1)
          .blur(radius: hidden ? Self.blur : 0)
          .animation(
            entering
              ? .easeOut(duration: Self.inFor).delay(Self.inAfter + Self.inStagger * Double(index))
              : .easeIn(duration: Self.outFor).delay(Self.outStagger * Double(index)),
            value: settled
          )
      }
    }
    .id(line.generation)
  }

  /// The space between words at this size (a third of the point size reads like a space).
  private var wordSpace: CGFloat { 8 }

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
      // One frame drawn with the new words hidden and the old ones whole, then both move.
      try? await Task.sleep(for: .milliseconds(24))
      guard current.generation == next.generation else { return }
      settled = true
      let done = Self.inAfter + Self.inStagger * Double(max(next.words.count, 1)) + Self.inFor
      try? await Task.sleep(for: .seconds(done))
      guard current.generation == next.generation else { return }
      withTransaction(quiet) { leaving = nil }
    }
  }
}

/// Words laid out like a line of text: left to right, wrapping when the next word does not
/// fit. A custom layout (not one Text) so each word can move on its own.
struct WordFlow: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.reduce(0) { $0 + $1.height }
    return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
        x += size.width + spacing
      }
      y += row.height
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows = [Row]()
    var row = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      if !row.indices.isEmpty, needed > width {
        rows.append(row)
        row = Row()
      }
      row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      row.height = max(row.height, size.height)
      row.indices.append(index)
    }
    if !row.indices.isEmpty { rows.append(row) }
    return rows
  }
}
