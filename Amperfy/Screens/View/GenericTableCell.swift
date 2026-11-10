//
//  GenericTableCell.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 20.02.22.
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
import UIKit

class GenericTableCell: BasicTableCell {
  @IBOutlet
  weak var titleLabel: UILabel!
  @IBOutlet
  weak var subtitleLabel: UILabel!
  @IBOutlet
  weak var entityImage: EntityImageView!
  @IBOutlet
  weak var infoLabel: UILabel!
  @IBOutlet
  weak var favoriteIconImage: UIImageView!

  @IBOutlet
  weak var infoLabelWidthConstraint: NSLayoutConstraint!

  static let rowHeight: CGFloat = 48.0 + margin.bottom + margin.top
  static let rowHeightWithoutImage: CGFloat = 28.0 + margin.bottom + margin.top

  private var container: PlayableContainable?
  /// Weak: a cell lives in its page, so a strong page here kept it in memory (BUG-447).
  private weak var rootView: UITableViewController?

  func display(
    container: PlayableContainable,
    rootView: UITableViewController,
    cassetteIsOwned: Bool? = nil
  ) {
    self.container = container
    self.rootView = rootView
    // cassette Polish 2 (A3/C1) + Patch 104 (Root 3): artist artwork is
    // circular app-wide. The shape is owned by EntityImageView now, so it
    // survives layout passes and async artwork loads.
    entityImage.shape = container is Artist ? .circle : .rounded(.small)
    selectionStyle = .none
    titleLabel.text = container.name
    subtitleLabel.isHidden = container.subtitle == nil
    subtitleLabel.text = container.subtitle
    entityImage.display(
      theme: appDelegate.storage.settings.accounts.getSetting(container.account?.info).read
        .themePreference,
      container: container
    )
    let infoText = container.info(
      for: container.account?.apiType.asServerApiType,
      details: DetailInfoType(type: .short, settings: appDelegate.storage.settings)
    )
    infoLabel.isHidden = infoText.isEmpty
    infoLabel.text = infoText
    infoLabel.textAlignment = (traitCollection.horizontalSizeClass == .regular) ? .right : .left
    // cassette: favorites removed — the per-row favorite icon is always hidden
    // (the isFavorite column is preserved but no longer surfaced on library rows).
    favoriteIconImage.isHidden = true

    if container is Album {
      infoLabelWidthConstraint.constant = 75
    } else if container is Artist {
      infoLabelWidthConstraint.constant = 230
    } else if container is Genre {
      infoLabelWidthConstraint.constant = 260
    } else if container is Podcast {
      infoLabelWidthConstraint.constant = 140
    }
    accessoryType = .disclosureIndicator
    // cassette Patch 032: route through the canonical scale. Title drops
    // 17pt -> 16pt rowTitle to match track and other library rows.
    // Subtitle is metadata (12pt medium mono); the trailing info column
    // is caption (12pt regular mono) — same size, lighter weight.
    backgroundColor = UIColor.cassette(.surfaceBase)
    contentView.backgroundColor = UIColor.cassette(.surfaceBase)
    titleLabel.font = UIFont.cassette(.rowTitle)
    titleLabel.textColor = UIColor.cassette(.textPrimary)
    subtitleLabel.font = UIFont.cassette(.metadata)
    subtitleLabel.textColor = UIColor.cassette(.textSecondary)
    infoLabel.font = UIFont.cassette(.caption)
    infoLabel.textColor = UIColor.cassette(.textTertiary)

    // cassette Layer 3 Phase 3.2 (library filtering). In Server Mode the list
    // shows the full catalog; non-owned rows are dimmed (ink alphas only) so
    // what's on the phone stays legible. nil = not in a filtered context (every
    // other call site), so no dimming applies.
    let ownershipAlpha: CGFloat
    switch cassetteIsOwned {
    case .none, .some(true):
      ownershipAlpha = 1.0
    case .some(false):
      ownershipAlpha = 0.6
    }
    titleLabel.alpha = ownershipAlpha
    subtitleLabel.alpha = ownershipAlpha
    infoLabel.alpha = ownershipAlpha
    entityImage.alpha = ownershipAlpha
  }

  /// cassette (BUG-417): the XIB carries 28 size-class variations, most of them
  /// system fonts; UIKit re-applies them on a trait change and the row drops
  /// back into SF Pro until the next bind. Re-stamp the type scale every time.
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    titleLabel.font = UIFont.cassette(.rowTitle)
    subtitleLabel.font = UIFont.cassette(.metadata)
    infoLabel.font = UIFont.cassette(.caption)
  }
}
