//
//  KeepPlayingAlbumCell.swift
//  Amperfy
//
//  cassette (keep playing, founder 2026-11-02): the record that plays when the album on now
//  ends, as one card under THEN in the queue: its cover, its name, its artist in the
//  playing record's colour, and Swap for the next one down the list. A tap plays it now.
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

final class KeepPlayingAlbumCell: UITableViewCell {
  static let reuseIdentifier = "KeepPlayingAlbumCell"
  static let artworkSide: CGFloat = 56
  /// The card (56 + 10 above and below) and 4 of air either side of it.
  static let rowHeight: CGFloat = artworkSide + 2 * 10 + 2 * 4

  var onSwap: (() -> ())?
  var onPlay: (() -> ())?

  private let cardView = UIView()
  private let artworkView = EntityImageView(
    frame: CGRect(x: 0, y: 0, width: artworkSide, height: artworkSide)
  )
  private let titleLabel = UILabel()
  private let artistLabel = UILabel()
  private let swapButton = UIButton(type: .system)
  private var displayedAlbumID: String?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    selectionStyle = .none

    cardView.translatesAutoresizingMaskIntoConstraints = false
    cardView.layer.cornerRadius = 12
    cardView.layer.cornerCurve = .continuous
    contentView.addSubview(cardView)

    artworkView.translatesAutoresizingMaskIntoConstraints = false
    cardView.addSubview(artworkView)

    for label in [titleLabel, artistLabel] {
      label.translatesAutoresizingMaskIntoConstraints = false
      label.numberOfLines = 1
      label.lineBreakMode = .byTruncatingTail
      label.adjustsFontForContentSizeCategory = false
    }
    let textStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
    textStack.translatesAutoresizingMaskIntoConstraints = false
    textStack.axis = .vertical
    textStack.spacing = 2
    cardView.addSubview(textStack)

    var swap = UIButton.Configuration.playerQuietToggle(
      isOn: false,
      onColor: UIColor.cassette(.textPrimary)
    )
    swap.image = CassetteIcon.refresh.symbolImage
    swapButton.configuration = swap
    swapButton.translatesAutoresizingMaskIntoConstraints = false
    swapButton.accessibilityLabel = "Swap for another record"
    swapButton.addTarget(self, action: #selector(swapPressed), for: .touchUpInside)
    cardView.addSubview(swapButton)

    let margin = UIView.defaultMarginX
    NSLayoutConstraint.activate([
      cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin - 10),
      cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -(margin - 10)),
      cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

      artworkView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 10),
      artworkView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
      artworkView.widthAnchor.constraint(equalToConstant: Self.artworkSide),
      artworkView.heightAnchor.constraint(equalToConstant: Self.artworkSide),

      textStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 12),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: swapButton.leadingAnchor, constant: -8),
      textStack.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),

      swapButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -6),
      swapButton.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
      swapButton.widthAnchor.constraint(equalToConstant: 44),
      swapButton.heightAnchor.constraint(equalToConstant: 44),
    ])
    cardView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cardTapped)))
    cardView.cassetteOnAppearanceChange {
      $0.backgroundColor = UIColor.cassette(.textPrimary).withAlphaComponent(0.06)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func display(album: Album, artistColor: UIColor) {
    titleLabel.attributedText = NSAttributedString.cassette(
      album.name,
      .rowTitle,
      color: UIColor.cassette(.textPrimary)
    )
    let artist = album.artist?.name ?? ""
    artistLabel.attributedText = NSAttributedString.cassette(artist, .answerCompact, color: artistColor)
    artistLabel.isHidden = artist.isEmpty
    // Only a new record reloads the cover, so a queue refresh never blinks it.
    if album.id != displayedAlbumID {
      displayedAlbumID = album.id
      let setting = appDelegate.storage.settings.accounts.getSetting(album.account?.info).read
      artworkView.display(theme: setting.themePreference, container: album, cornerRadius: .small)
    }
    isAccessibilityElement = true
    accessibilityLabel = ["Then", album.name, artist].filter { !$0.isEmpty }.joined(separator: ", ")
    accessibilityTraits = .button
    accessibilityHint = "Plays it now"
    accessibilityCustomActions = [
      UIAccessibilityCustomAction(name: "Play it now") { [weak self] _ in
        self?.onPlay?()
        return true
      },
      UIAccessibilityCustomAction(name: "Swap for another record") { [weak self] _ in
        self?.onSwap?()
        return true
      },
    ]
  }

  override func accessibilityActivate() -> Bool {
    onPlay?()
    return true
  }

  @objc
  private func cardTapped() {
    onPlay?()
  }

  @objc
  private func swapPressed() {
    onSwap?()
  }
}
