//
//  AlbumCollectionCell.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 21.01.22.
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

class AlbumCollectionCell: BasicCollectionCell {
  @IBOutlet
  weak var titleLabel: UILabel!
  @IBOutlet
  weak var subtitleLabel: UILabel!
  @IBOutlet
  weak var entityImage: EntityImageView!
  @IBOutlet
  weak var artworkImageWidthConstraint: NSLayoutConstraint!
  /// The XIB's text heights and the cover's centring, driven by `isCompact`. The centring
  /// is held strongly: it is switched off for compact tiles and back on afterwards.
  @IBOutlet
  weak var titleHeightConstraint: NSLayoutConstraint?
  @IBOutlet
  weak var subtitleHeightConstraint: NSLayoutConstraint?
  @IBOutlet
  weak var textStackHeightConstraint: NSLayoutConstraint?
  @IBOutlet
  weak var textStackView: UIStackView?
  @IBOutlet
  var artworkCenterYConstraint: NSLayoutConstraint?

  static let maxWidth: CGFloat = 250.0

  // MARK: Compact tile (phone-taste Library grid)

  /// The Library grid's smaller tile (the mock's `.gridItem`): a 15pt title and the 13pt
  /// mono artist, 2pt apart, under a cover pinned to the top with a small gap. Set only by
  /// AlbumsCollectionVC before `display`; Home shelves and carousels keep the regular tile.
  /// The flag is cleared in `prepareForReuse`; the constraints follow it on the next bind
  /// (`apply` runs `applyCassetteType`, which runs `applyDensity`), so a grid tile that is
  /// reused as a grid tile never passes through the regular values.
  var isCompact = false

  /// The mock's 5pt cover margin plus its 2pt row gap, less the 1pt taller ascender box a
  /// UILabel draws above the capitals: the title's capitals land where the mock's do.
  static let compactCoverGap: CGFloat = 6
  static let compactLineSpacing: CGFloat = 2
  /// One line of each label, measured from the fonts (Barlow SemiBold 15: 18pt, DM Mono
  /// 13: 17pt), so the tile height and the labels agree.
  static let compactTitleHeight: CGFloat = UIFont.cassette(.miniTitle).lineHeight.rounded(.up)
  static let compactSubtitleHeight: CGFloat = UIFont.cassette(.cardSubtitle).lineHeight
    .rounded(.up)
  static let compactTextStackHeight: CGFloat = compactTitleHeight + compactLineSpacing +
    compactSubtitleHeight
  /// What a compact tile adds under its square cover. AlbumsCollectionVC sizes tiles by it.
  static let compactTextBlockHeight: CGFloat = compactCoverGap + compactTextStackHeight

  /// The XIB's regular values, put back when a tile stops being compact.
  private static let regularTitleHeight: CGFloat = 22
  private static let regularSubtitleHeight: CGFloat = 16
  private static let regularLineSpacing: CGFloat = 4
  private func regularTextStackHeight() -> CGFloat {
    traitCollection.horizontalSizeClass == .regular ? 42 : 41
  }

  /// Whether the compact values are on the constraints now.
  private var isCompactApplied = false
  private var artworkTopConstraint: NSLayoutConstraint?

  private var container: PlayableContainable?
  /// Weak: the host owns the collection view that owns this cell, so a strong pointer
  /// back kept the host (and every cell) alive after it left the screen.
  private weak var rootView: UICollectionViewController?
  private weak var rootFlowLayout: UICollectionViewDelegateFlowLayout?
  private var itemWidth: CGFloat?

  /// Single type path for album cards. IB size-class font variations used to
  /// re-apply system SF after `display()`, so Home shelves mixed faces card
  /// to card. Fonts are owned here only - awakeFromNib, every bind, and any
  /// trait change - never by the XIB.
  private func applyCassetteType() {
    // phone-taste: the compact tile's title is the 15pt mini title (the mock's 14).
    titleLabel?.font = UIFont.cassette(isCompact ? .miniTitle : .rowTitle)
    titleLabel?.textColor = UIColor.cassette(.textPrimary)
    titleLabel?.adjustsFontForContentSizeCategory = false
    subtitleLabel?.font = UIFont.cassette(.cardSubtitle)
    subtitleLabel?.textColor = UIColor.cassette(.textSecondary)
    subtitleLabel?.adjustsFontForContentSizeCategory = false
    applyDensity()
  }

  /// Puts the compact or the regular text heights, spacing and cover pin on the XIB's
  /// constraints. A tile that was never compact is left to its XIB values.
  private func applyDensity() {
    guard let titleHeightConstraint, let subtitleHeightConstraint,
          let textStackHeightConstraint else { return }
    if isCompact {
      Self.set(titleHeightConstraint, Self.compactTitleHeight)
      Self.set(subtitleHeightConstraint, Self.compactSubtitleHeight)
      Self.set(textStackHeightConstraint, Self.compactTextStackHeight)
      if textStackView?.spacing != Self.compactLineSpacing {
        textStackView?.spacing = Self.compactLineSpacing
      }
      // The cover sits at the top of its box, so the spare height is the gap under it.
      if artworkTopConstraint == nil, let entityImage, let outerView = entityImage.superview {
        artworkTopConstraint = entityImage.topAnchor.constraint(equalTo: outerView.topAnchor)
      }
      if artworkCenterYConstraint?.isActive == true { artworkCenterYConstraint?.isActive = false }
      if artworkTopConstraint?.isActive == false { artworkTopConstraint?.isActive = true }
      isCompactApplied = true
    } else if isCompactApplied {
      Self.set(titleHeightConstraint, Self.regularTitleHeight)
      Self.set(subtitleHeightConstraint, Self.regularSubtitleHeight)
      Self.set(textStackHeightConstraint, regularTextStackHeight())
      if textStackView?.spacing != Self.regularLineSpacing {
        textStackView?.spacing = Self.regularLineSpacing
      }
      if artworkTopConstraint?.isActive == true { artworkTopConstraint?.isActive = false }
      if artworkCenterYConstraint?.isActive == false { artworkCenterYConstraint?.isActive = true }
      isCompactApplied = false
    }
  }

  private static func set(_ constraint: NSLayoutConstraint, _ constant: CGFloat) {
    if constraint.constant != constant { constraint.constant = constant }
  }

  override func awakeFromNib() {
    super.awakeFromNib()
    applyCassetteType()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    // IB variations can rewrite label fonts when size class / idiom shifts.
    // Re-stamp the Cassette faces so the shelf never falls back to SF.
    applyCassetteType()
  }

  // cassette Patch 043: play overlay split. Tap on the artwork
  // body still navigates (handled by the collection view's
  // didSelectItemAt); tap on the play disc fires the closure so the host
  // can start playback for the container.
  /// phone-taste: the mock's `.tilePlay`, a 34pt cream disc (was a 40pt glass button).
  static let playOverlayDiameter: CGFloat = CassetteKitTokens.Control.row
  private var playOverlay: UIButton?

  /// cassette Patch 043: HomeVC sets this in its cellProvider so
  /// tapping the overlay starts playback for the cell's container.
  /// Cleared in `prepareForReuse` so the closure doesn't outlive
  /// the bound container.
  var onPlayTapped: (() -> ())?
  /// Shows the one-tap play disc on the cover. Opt-in per surface ("every cover plays in
  /// one tap" on Home and the table-page shelves; the Library grid stays clean). Works
  /// whether it is set before or after `display`.
  var showsPlayOverlay = false {
    didSet {
      if showsPlayOverlay { setupPlayOverlayIfNeeded() }
      playOverlay?.isHidden = !showsPlayOverlay
    }
  }

  /// Replaces the container's own subtitle line when set (e.g. a year on an artist's
  /// album shelf). Set before `display`.
  var subtitleOverride: String?
  /// A clear card, for shelves drawn over a lit page. Set before `display`.
  var clearsBackground = false

  func display(
    container: PlayableContainable,
    rootView: UICollectionViewController,
    itemWidth: CGFloat,
    initialIndexPath: IndexPath
  ) {
    self.itemWidth = itemWidth
    rootFlowLayout = nil
    apply(
      container: container,
      rootView: rootView,
      initialIndexPath: initialIndexPath
    )
  }

  func display(
    container: PlayableContainable,
    rootView: UICollectionViewController,
    rootFlowLayout: UICollectionViewDelegateFlowLayout,
    initialIndexPath: IndexPath
  ) {
    self.rootFlowLayout = rootFlowLayout
    itemWidth = nil
    apply(
      container: container,
      rootView: rootView,
      initialIndexPath: initialIndexPath
    )
  }

  /// Patch 110 (3b): standalone use (e.g. AlbumCarouselTableCell) with a fixed
  /// item width and no hosting UICollectionViewController. The artwork is sized
  /// from `itemWidth`, so no rootView/flow-layout callback is needed.
  func display(container: PlayableContainable, itemWidth: CGFloat) {
    self.itemWidth = itemWidth
    rootFlowLayout = nil
    apply(
      container: container,
      rootView: nil,
      initialIndexPath: IndexPath(item: 0, section: 0)
    )
  }

  private func apply(
    container: PlayableContainable,
    rootView: UICollectionViewController?,
    initialIndexPath: IndexPath
  ) {
    self.container = container
    self.rootView = rootView
    titleLabel.text = container.name
    subtitleLabel.text = subtitleOverride ?? container.subtitle
    // Barlow title + mono artist (legible at the 13pt floor).
    applyCassetteType()
    contentView.backgroundColor = clearsBackground ? .clear : UIColor.cassette(.surfaceBase)
    // cassette: album covers get a minimal 3pt corner (.verySmall), matching the
    // album detail hero, so bordered / edge-to-edge cover art keeps crisp corners
    // instead of having its edge shaved by the rounding. (Was .big = 15pt.)
    entityImage.display(
      theme: appDelegate.storage.settings.accounts.getSetting(container.account?.info).read
        .themePreference,
      container: container,
      cornerRadius: .verySmall
    )
    // cassette redesign (Surface 3): subtle content-level highlight — a
    // hairline ink ring that lifts dark covers off the dark background.
    // Content styling the OS doesn't provide; not a material.
    entityImage.layer.borderWidth = 1.0 / max(traitCollection.displayScale, 1.0)
    entityImage.layer.borderColor = UIColor.cassette(.textPrimary)
      .withAlphaComponent(0.08).cgColor
    if showsPlayOverlay { setupPlayOverlayIfNeeded() }
    playOverlay?.isHidden = !showsPlayOverlay
    updateArtworkImageConstraint(indexPath: initialIndexPath)
    layoutIfNeeded()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onPlayTapped = nil
    showsPlayOverlay = false
    playOverlay?.isHidden = true
    subtitleOverride = nil
    clearsBackground = false
    // phone-taste: back to the regular tile until a host asks for compact again. Only the
    // flag: the next bind puts the matching type and heights on (see `isCompact`).
    isCompact = false
  }

  override func layoutSubviews() {
    // A size-class change can put the XIB's own heights back; keep a compact tile compact.
    if isCompact { applyDensity() }
    if let indexPath = rootView?.collectionView.indexPath(for: self) {
      updateArtworkImageConstraint(indexPath: indexPath)
    } else if itemWidth != nil {
      // Standalone (no hosting collection-view controller): width is fixed.
      updateArtworkImageConstraint(indexPath: IndexPath(item: 0, section: 0))
    }
    super.layoutSubviews()
  }

  /// Lazily install the play disc 8pt inside the artwork's bottom-right corner (the
  /// mock's `.tilePlay`: right 8, bottom 8). Idempotent.
  private func setupPlayOverlayIfNeeded() {
    guard playOverlay == nil else { return }
    let button = Self.makePlayOverlayButton()
    button.isHidden = !showsPlayOverlay
    button.addAction(UIAction { [weak self] _ in self?.onPlayTapped?() }, for: .touchUpInside)
    contentView.addSubview(button)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Self.playOverlayDiameter),
      button.heightAnchor.constraint(equalToConstant: Self.playOverlayDiameter),
      button.trailingAnchor.constraint(equalTo: entityImage.trailingAnchor, constant: -8),
      button.bottomAnchor.constraint(equalTo: entityImage.bottomAnchor, constant: -8),
    ])
    playOverlay = button
  }

  /// The one-tap play disc for covers (album tiles, artist circles; the mock's
  /// `.tilePlay`): a cream disc with a bold filled play glyph nudged 2pt for optical
  /// centring and a soft shadow. Draws at `playOverlayDiameter`; touches land on a 44pt
  /// circle around it. A UIButton cancels on pan, so scrolling a shelf never plays.
  /// The SwiftUI twin is `CassettePlayDisc`.
  static func makePlayOverlayButton() -> UIButton {
    var config = UIButton.Configuration.filled()
    config.baseBackgroundColor = UIColor.cassette(.fillSelected)
    config.baseForegroundColor = UIColor.cassette(.textOnFill)
    config.cornerStyle = .capsule
    config.image = CassetteIcon.play.symbolImage
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 15,
      weight: .bold
    )
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 0)
    let button = CassettePlayOverlayButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Play"
    button.clipsToBounds = false
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.45
    button.layer.shadowRadius = 6
    button.layer.shadowOffset = CGSize(width: 0, height: 4)
    return button
  }

  func updateArtworkImageConstraint(indexPath: IndexPath) {
    if let rootView, let rootFlowLayout = rootFlowLayout,
       let itemSize = rootFlowLayout.collectionView?(
         rootView.collectionView,
         layout: rootView.collectionView.collectionViewLayout,
         sizeForItemAt: indexPath
       ) {
      let newImageWidth = min(itemSize.width, itemSize.height)
      artworkImageWidthConstraint.constant = newImageWidth
    } else if let itemWidth {
      artworkImageWidthConstraint.constant = itemWidth
    }
  }
}

// MARK: - CassettePlayOverlayButton

/// The play disc's hit area grows to 44pt around its smaller drawn circle.
private final class CassettePlayOverlayButton: UIButton {
  private static let minimumHitSide: CGFloat = 44

  override func layoutSubviews() {
    super.layoutSubviews()
    // A shadow path keeps the soft shadow cheap in a scrolling shelf.
    layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let dx = min(0, (bounds.width - Self.minimumHitSide) / 2)
    let dy = min(0, (bounds.height - Self.minimumHitSide) / 2)
    return bounds.insetBy(dx: dx, dy: dy).contains(point)
  }
}
