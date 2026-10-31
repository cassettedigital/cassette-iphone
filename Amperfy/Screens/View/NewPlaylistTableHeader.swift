//
//  NewPlaylistTableHeader.swift
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

typealias PlaylistCreationResponder = (_ playlist: Playlist) -> ()

// MARK: - NewPlaylistTableHeader

class NewPlaylistTableHeader: UIView {
  @IBOutlet
  weak var nameTextField: UITextField!

  var account: Account!

  static let frameHeight: CGFloat = 40.0 + margin.top + margin.bottom
  static let margin = UIEdgeInsets(
    top: 10,
    left: UIView.defaultMarginX,
    bottom: 5,
    right: UIView.defaultMarginX
  )

  override init(frame: CGRect) {
    super.init(frame: frame)
  }

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    self.layoutMargins = Self.margin
  }

  override func awakeFromNib() {
    super.awakeFromNib()
    // cassette (BUG-422): the XIB ships a system rounded-rect field (which the
    // dark window painted pure black) and a system "Create" button. Restyle in
    // code: a bg2 field with a hairline ink4 rim, ink text, ink3 placeholder,
    // and a bare ink "Create" in the row-title face.
    MainActor.assumeIsolated {
      nameTextField.borderStyle = .none
      nameTextField.backgroundColor = UIColor.cassette(.surfaceRaised)
      nameTextField.textColor = UIColor.cassette(.textPrimary)
      nameTextField.tintColor = UIColor.cassette(.textPrimary)
      nameTextField.font = UIFont.cassette(.body)
      nameTextField.attributedPlaceholder = NSAttributedString(
        string: "New playlist name",
        attributes: [
          .foregroundColor: UIColor.cassette(.textTertiary),
          .font: UIFont.cassette(.body),
        ]
      )
      nameTextField.layer.cornerRadius = CassetteTheme.Radius.md
      nameTextField.layer.borderWidth = 1.0 / max(traitCollection.displayScale, 1.0)
      nameTextField.cassetteOnAppearanceChange { $0.layer.borderColor = UIColor.cassette(.hairline).cgColor }
      let inset = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
      nameTextField.leftView = inset
      nameTextField.leftViewMode = .always
      nameTextField.clearButtonMode = .whileEditing
      if let createButton = Self.firstButton(in: self) {
        // The nib button is a legacy `buttonType="system"` with a state title,
        // so the type is applied three ways: the configuration's attributed
        // title, a text-attributes transformer (covers the migrated state
        // title), and the legacy label font for whichever path UIKit takes.
        var config = UIButton.Configuration.cassetteBare()
        var attributes = AttributeContainer()
        attributes.font = UIFont.cassette(.rowTitle)
        attributes.foregroundColor = UIColor.cassette(.textPrimary)
        config.attributedTitle = AttributedString("Create", attributes: attributes)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
          var outgoing = incoming
          outgoing.font = UIFont.cassette(.rowTitle)
          outgoing.foregroundColor = UIColor.cassette(.textPrimary)
          return outgoing
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0)
        createButton.configuration = config
        createButton.tintColor = UIColor.cassette(.textPrimary)
        createButton.titleLabel?.font = UIFont.cassette(.rowTitle)
        createButton.setTitleColor(UIColor.cassette(.textPrimary), for: .normal)
      }
    }
  }

  /// The XIB nests the field and the button in a container, so a one-level
  /// subview scan misses the button; walk the tree.
  private static func firstButton(in view: UIView) -> UIButton? {
    for subview in view.subviews {
      if let button = subview as? UIButton { return button }
      if let nested = firstButton(in: subview) { return nested }
    }
    return nil
  }

  @IBAction
  func createPlaylistButtonPressed(_ sender: Any) {
    guard let playlistName = nameTextField.text, !playlistName.isEmpty else {
      return
    }
    let playlist = appDelegate.storage.main.library.createPlaylist(account: account)
    appDelegate.storage.main.saveContext()
    playlist.name = playlistName
    nameTextField.text = ""
    appDelegate.storage.main.saveContext()
    // cassette: create in cloud immediately so the empty playlist survives the
    // next cloud sync-down (Subsonic create used to wait until the first add).
    Task { @MainActor in
      do {
        try await appDelegate.getMeta(account.info).librarySyncer
          .syncUpload(playlistToUpdateName: playlist)
      } catch {
        appDelegate.eventLogger.report(topic: "Playlist Create", error: error)
      }
    }
  }
}
