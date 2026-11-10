//
//  ArtistCircleCollectionCell.swift
//  Amperfy
//
//  Created by Cassette Patch 038.
//  Copyright (c) 2026 Cassette. All rights reserved.
//
//  cassette Patch 070: album-sized card with circular photo.
//  The redundant "Artist" caption under the name is retired - the circle
//  already says what it is; album cards don't label themselves "Album".
//

import AmperfyKit
import UIKit

// MARK: - ArtistCircleMetrics

/// The artist circle's size and name treatment for one surface.
struct ArtistCircleMetrics: Equatable {
  /// The photo circle's diameter.
  var diameter: CGFloat
  /// The square region the circle is centred in, above the name.
  var regionHeight: CGFloat
  /// Centre the name under the circle (compact tiles) instead of leading.
  var centeredName: Bool
  var nameStyle: CassetteTextStyle
  var nameLines: Int

  /// Today's card: a 152pt circle in a 160pt region, a two-line leading name.
  static let standard = ArtistCircleMetrics(
    diameter: 152,
    regionHeight: 160,
    centeredName: false,
    nameStyle: .rowTitle,
    nameLines: 2
  )
  /// The Home shelf, sized to the mock's 150pt tiles.
  static let homeShelf = ArtistCircleMetrics(
    diameter: 142,
    regionHeight: 150,
    centeredName: false,
    nameStyle: .rowTitle,
    nameLines: 2
  )

  /// A small round tile with a centred one-line name (artist rows on Search and detail).
  static func compact(diameter: CGFloat = 104) -> Self {
    ArtistCircleMetrics(
      diameter: diameter,
      regionHeight: diameter,
      centeredName: true,
      nameStyle: .miniTitle,
      nameLines: 1
    )
  }
}

// MARK: - ArtistCircleCollectionCell

final class ArtistCircleCollectionCell: BasicCollectionCell {
  static let artworkRegionHeight: CGFloat = ArtistCircleMetrics.standard.regionHeight
  // The circle nearly fills its 160pt cell (a hair of inset each side), matching
  // the album cards beside it and the Android artist grid, which fills its column
  // edge to edge. Was 120 in a 160 cell - a 20pt-per-side margin that left the
  // artist a small token in a sea of negative space.
  static let circleDiameter: CGFloat = ArtistCircleMetrics.standard.diameter

  private let artworkContainer: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    // cassette Polish 2 (A3): clear container. Previously a bg2 rounded-rect
    // tile sat behind the 120pt circle, so the square corners showed around
    // the photo and made the card read "uneven / broken". The circular photo
    // now floats directly on the cell background.
    view.backgroundColor = .clear
    return view
  }()

  private let entityImage: LibraryEntityImage = {
    let imageView = LibraryEntityImage(frame: .zero)
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    return imageView
  }()

  private let nameLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.cassette(.rowTitle)
    label.textColor = UIColor.cassette(.textPrimary)
    label.numberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  private var playOverlay: UIButton?
  var showsPlayOverlay = false
  var onPlayTapped: (() -> ())?

  private var metrics = ArtistCircleMetrics.standard
  private var regionHeightConstraint: NSLayoutConstraint!
  private var circleWidthConstraint: NSLayoutConstraint!
  private var circleHeightConstraint: NSLayoutConstraint!

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupSubviews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupSubviews()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onPlayTapped = nil
    showsPlayOverlay = false
    playOverlay?.isHidden = true
    apply(metrics: .standard)
  }

  private func setupSubviews() {
    // cassette Patch 104 (Root 3): the circle is deterministic - the photo
    // is constrained to a fixed square (the metrics' diameter), so the mask is set
    // from the constant instead of racing layout passes in layoutSubviews.
    entityImage.layer.cornerRadius = metrics.diameter / 2.0
    contentView.backgroundColor = UIColor.cassette(.surfaceBase)
    contentView.addSubview(artworkContainer)
    artworkContainer.addSubview(entityImage)
    contentView.addSubview(nameLabel)

    // Dropped just below required so the compositional layout's first
    // `.estimated`-height pass (which sizes the cell before it self-sizes to
    // content) can't force an unsatisfiable conflict - the artwork region
    // momentarily compresses instead of the required 160pt fighting a smaller
    // estimate. At the self-sized steady state nothing competes, so it resolves
    // at 160 exactly and the layout is unchanged.
    regionHeightConstraint = artworkContainer.heightAnchor
      .constraint(equalToConstant: metrics.regionHeight)
    regionHeightConstraint.priority = UILayoutPriority(999)
    circleWidthConstraint = entityImage.widthAnchor.constraint(equalToConstant: metrics.diameter)
    circleHeightConstraint = entityImage.heightAnchor.constraint(equalToConstant: metrics.diameter)

    NSLayoutConstraint.activate([
      artworkContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
      artworkContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      artworkContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      regionHeightConstraint,

      entityImage.centerXAnchor.constraint(equalTo: artworkContainer.centerXAnchor),
      entityImage.centerYAnchor.constraint(equalTo: artworkContainer.centerYAnchor),
      circleWidthConstraint,
      circleHeightConstraint,

      nameLabel.topAnchor.constraint(equalTo: artworkContainer.bottomAnchor, constant: 8),
      nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
    ])
  }

  /// `attributedName`, when given, replaces the plain name (e.g. a name lit by a cover).
  /// `standIn`, when given, is drawn in the circle instead: the record that stands for an
  /// artist with no photo of their own, as Search's artist cards draw it (BUG-451).
  func display(
    artist: Artist,
    standIn: Album? = nil,
    showsPlayOverlay: Bool = false,
    metrics: ArtistCircleMetrics = .standard,
    attributedName: NSAttributedString? = nil
  ) {
    apply(metrics: metrics)
    self.showsPlayOverlay = showsPlayOverlay
    if let attributedName {
      nameLabel.attributedText = attributedName
    } else {
      nameLabel.font = UIFont.cassette(metrics.nameStyle)
      nameLabel.textColor = UIColor.cassette(.textPrimary)
      nameLabel.text = artist.name
    }
    nameLabel.textAlignment = metrics.centeredName ? .center : .natural
    if let standIn {
      entityImage.displayAndUpdate(entity: standIn)
    } else {
      entityImage.displayAndUpdate(entity: artist)
    }
    if showsPlayOverlay { setupPlayOverlayIfNeeded() }
    playOverlay?.isHidden = !showsPlayOverlay
  }

  private func apply(metrics newMetrics: ArtistCircleMetrics) {
    nameLabel.numberOfLines = newMetrics.nameLines
    nameLabel.font = UIFont.cassette(newMetrics.nameStyle)
    nameLabel.textAlignment = newMetrics.centeredName ? .center : .natural
    guard newMetrics != metrics else { return }
    metrics = newMetrics
    regionHeightConstraint.constant = newMetrics.regionHeight
    circleWidthConstraint.constant = newMetrics.diameter
    circleHeightConstraint.constant = newMetrics.diameter
    entityImage.layer.cornerRadius = newMetrics.diameter / 2.0
    setNeedsLayout()
  }

  // phone-taste: the same cream play disc as the album tiles, pinned to the CIRCLE so it
  // straddles the photo's edge at the 45 degree point rather than the square's corner.
  private func setupPlayOverlayIfNeeded() {
    guard playOverlay == nil else { return }
    let button = AlbumCollectionCell.makePlayOverlayButton()
    button.isHidden = !showsPlayOverlay
    button.addAction(UIAction { [weak self] _ in self?.onPlayTapped?() }, for: .touchUpInside)
    artworkContainer.addSubview(button)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: AlbumCollectionCell.playOverlayDiameter),
      button.heightAnchor.constraint(equalToConstant: AlbumCollectionCell.playOverlayDiameter),
      button.trailingAnchor.constraint(equalTo: entityImage.trailingAnchor, constant: -4),
      button.bottomAnchor.constraint(equalTo: entityImage.bottomAnchor, constant: -4),
    ])
    playOverlay = button
  }
}
