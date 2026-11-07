//
//  ComputerCardHeaderView.swift
//  Amperfy
//
//  Cassette fork (BUG-899): the computer card's place on Home, a header-only row like the
//  made-for-you row. Unlike that row it does not build its SwiftUI afresh on every
//  configure: Home keeps one hosting controller for the card and this view only lends it a
//  place, so the card's motion (the strip's wave, a headline mid-change) carries on through
//  every Home redraw.
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
import UIKit

final class ComputerCardHeaderView: UICollectionReusableView {
  static let reuseID = "ComputerCardHeaderView"

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    // The card eases to a new size inside the row while the row itself moves; let it draw
    // past the row's edge for those 600 ms.
    clipsToBounds = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Puts Home's one card here (moving it from wherever it was).
  func host(_ hosting: UIViewController, in parent: UIViewController) {
    if hosting.parent !== parent {
      hosting.willMove(toParent: nil)
      hosting.removeFromParent()
      parent.addChild(hosting)
      hosting.didMove(toParent: parent)
    }
    guard hosting.view.superview !== self else { return }
    hosting.view.removeFromSuperview()
    hosting.view.backgroundColor = .clear
    hosting.view.clipsToBounds = false
    hosting.view.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hosting.view)
    NSLayoutConstraint.activate([
      hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
      hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor),
      hosting.view.topAnchor.constraint(equalTo: topAnchor),
      hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
}
