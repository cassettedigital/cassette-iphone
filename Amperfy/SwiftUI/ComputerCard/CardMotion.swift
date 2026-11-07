//
//  CardMotion.swift
//  Amperfy
//
//  Cassette fork (BUG-899): the timings, colours and the one sizing rule the first-run
//  computer card and its parts share (BlurText, FadeText, LibraryStrip, ComputerCard).
//  The founder's board, 2026-11-07: https://claude.ai/artifact/5XcemdnFoKSgAE5aShdoCc
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
import UIKit

enum CardMotion {
  /// The card's one sizing rule: every box eases to its contents' size over 600 ms on
  /// Apple's sheet curve, so a line that wraps to two opens gently instead of pushing
  /// everything under it at once (founder 2026-11-07: "more gently and intelligently sized
  /// up, rather than just snapping").
  static let sizingDuration: TimeInterval = 0.6
  static let sizing = Animation.timingCurve(0.32, 0.72, 0, 1, duration: sizingDuration)
  /// The same curve for UIKit (`UIViewPropertyAnimator`'s control points), so the rows
  /// under the card move with it.
  static let sizingControlPoint1 = CGPoint(x: 0.32, y: 0.72)
  static let sizingControlPoint2 = CGPoint(x: 0, y: 1)

  /// A group (the library strip, the button) coming in and going out: in after the old one
  /// has mostly gone, out quickly. Opacity only: nothing in the card slides vertically.
  static let groupIn = Animation.easeOut(duration: 0.52).delay(0.16)
  static let groupOut = Animation.easeOut(duration: 0.24)
  static var group: AnyTransition {
    .asymmetric(
      insertion: .opacity.animation(groupIn),
      removal: .opacity.animation(groupOut)
    )
  }
}

/// The card's colours, each with its dark twin (the app follows the phone's appearance).
enum CardColors {
  /// The card on the page (`surfaceRaised`), also the "negative space" the skeleton fades to.
  static let card = Color(CassetteTheme.UIColors.bg2)
  static let ink = Color(CassetteTheme.UIColors.ink)
  static let ink2 = Color(CassetteTheme.UIColors.ink2)
  /// The button's label, the page colour on ink.
  static let onInk = Color(CassetteTheme.UIColors.bg)
  /// An empty tile, and the empty bar while the computer is getting ready.
  static let emptyTile = Color(UIColor.cassetteFollowing(dark: 0x2E2920, light: 0xE4D9C6))
  /// The bar's track once anything is arriving.
  static let track = Color(UIColor.cassetteFollowing(dark: 0x2A261E, light: 0xE9DFCD))
  /// The bar filling.
  static let filling = Color(CassetteTheme.UIColors.orange)
  /// The bar paused, the computer out of reach.
  static let paused = Color(UIColor.cassetteFollowing(dark: 0x5C5343, light: 0xB8AC97))
}

// MARK: - The one sizing rule

/// A box that eases to its contents' natural height (or size, `inline`) instead of
/// snapping. The contents lay out at their own size; only the box around them animates,
/// and what sits under it follows. `clips` keeps text that is leaving inside the box while
/// it shrinks (off for blurred words, whose blur reaches past their box).
private struct EasedSize: ViewModifier {
  let inline: Bool
  let clips: Bool
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State
  private var size: CGSize?

  func body(content: Content) -> some View {
    content
      .fixedSize(horizontal: inline, vertical: true)
      .onGeometryChange(for: CGSize.self) { $0.size } action: { natural in
        guard natural != size else { return }
        if size == nil || reduceMotion {
          var quiet = Transaction()
          quiet.disablesAnimations = true
          withTransaction(quiet) { size = natural }
        } else {
          withAnimation(CardMotion.sizing) { size = natural }
        }
      }
      .frame(
        width: inline ? size?.width : nil,
        height: size?.height,
        alignment: .topLeading
      )
      .clipShape(Rectangle().inset(by: clips ? 0 : -24))
  }
}

extension View {
  /// The card's one sizing rule (see `CardMotion.sizing`).
  func easedHeight(clips: Bool = true) -> some View {
    modifier(EasedSize(inline: false, clips: clips))
  }

  /// The sizing rule on both axes, for a label that sits inline (the button's).
  func easedSize(clips: Bool = true) -> some View {
    modifier(EasedSize(inline: true, clips: clips))
  }
}
