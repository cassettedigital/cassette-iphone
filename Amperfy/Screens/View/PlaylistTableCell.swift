//
//  PlaylistTableCell.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

class PlaylistTableCell: BasicTableCell {
  @IBOutlet
  weak var nameLabel: UILabel!
  @IBOutlet
  weak var entityImage: EntityImageView!
  @IBOutlet
  weak var infoLabel: UILabel!

  static let rowHeight: CGFloat = 70.0 + margin.bottom + margin.top

  private var playlist: Playlist?
  /// Weak: a cell lives in its page, so a strong page here kept it in memory (BUG-447).
  private weak var rootView: UITableViewController?

  override func awakeFromNib() {
    super.awakeFromNib()
    // cassette Patch 032: route through the canonical scale. Name drops
    // 17pt -> 16pt rowTitle to match track / generic / album-grid rows;
    // info line stays 12pt mono but now flows through .metadata.
    MainActor.assumeIsolated {
      applyCassetteType()
      nameLabel.textColor = UIColor.cassette(.textPrimary)
      infoLabel.textColor = UIColor.cassette(.textSecondary)
      contentView.backgroundColor = UIColor.cassette(.surfaceBase)
      backgroundColor = UIColor.cassette(.surfaceBase)
    }
  }

  /// cassette (BUG-417): fonts are re-stamped on every trait change because the
  /// XIB's size-class variations put system fonts back.
  private func applyCassetteType() {
    nameLabel.font = UIFont.cassette(.rowTitle)
    infoLabel.font = UIFont.cassette(.metadata)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    applyCassetteType()
  }

  func display(playlist: Playlist, rootView: UITableViewController?) {
    self.playlist = playlist
    self.rootView = rootView
    nameLabel.text = playlist.name
    entityImage.display(
      theme: appDelegate.storage.settings.accounts.getSetting(playlist.account?.info).read
        .themePreference,
      container: playlist
    )
    infoLabel.text = playlist.info(
      for: playlist.account?.apiType.asServerApiType,
      details: DetailInfoType(type: .short, settings: appDelegate.storage.settings)
    )
    infoLabel.textAlignment = (traitCollection.horizontalSizeClass == .regular) ? .right : .left
    accessoryType = .disclosureIndicator
    backgroundColor = UIColor.cassette(.surfaceBase)
  }
}
