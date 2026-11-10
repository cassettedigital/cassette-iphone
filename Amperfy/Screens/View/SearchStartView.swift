//
//  SearchStartView.swift
//  Amperfy
//
//  Cassette: what Search shows before anyone types (UX review 2026-10-20, item 5).
//  A row of quiet starting points instead of an empty "No search history" page:
//  shuffle what is on the phone, or jump to a way of browsing it.
//
//  phone-taste (2026-10-21): below the chips, the GENRES grid from the approved mock
//  (proto/phone-taste Screens.tsx SearchStartScreen; phone.module.css .chips,
//  .genreGrid, .genreTile, .genreCover): the genres of the music on this phone, biggest
//  first, each tile in the colour of one of its records.
//
//  Soft tiles (founder, 2026-11-02): the tile was its cover blurred into a glow, which
//  averaged most records to brown and made the grid three browns and three pastels. Each
//  tile now takes only the cover's hue, at one pale tone shared by every tile
//  (`CoverTint.tileFill`), with its words in the deep shade of that hue and no text shadow.
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

// MARK: - SearchStartView

@MainActor
final class SearchStartView: UIView {
  struct Start {
    let title: String
    let icon: CassetteIcon
    let action: () -> ()
  }

  /// One genre tile: the genre's name, how many of its albums are on the phone, and one of
  /// its records (cover image plus the cover's path, which keys the tile's colour).
  struct GenreTile {
    let name: String
    let albumCount: Int
    let cover: UIImage?
    let coverPath: String?
    let action: () -> ()
  }

  /// The mock's page gutter (`.chips` padding 16px 20px 0; `.genreGrid` padding 0 20px).
  private static let inset: CGFloat = 20
  private static let chipHeight: CGFloat = 36
  /// Air between the title and the chips (`.chips` padding-top).
  private static let chipTopGap: CGFloat = 16
  /// The grid's gaps, both ways (`.genreGrid` gap).
  private static let gridGap: CGFloat = 10

  private let scrollView = UIScrollView()
  private let stack = UIStackView()
  private let genresBlock = UIView()
  private let genresGrid = UIStackView()
  private var genreRowCount = 0
  /// The chips by title, so one can be hidden while it has nothing to act on.
  private var chipsByTitle = [String: UIButton]()

  init(starts: [Start]) {
    super.init(frame: CGRect(
      x: 0,
      y: 0,
      width: 320,
      height: Self.chipTopGap + Self.chipHeight
    ))
    backgroundColor = .clear

    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceHorizontal = true
    scrollView.contentInset = UIEdgeInsets(top: 0, left: Self.inset, bottom: 0, right: Self.inset)
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)

    stack.axis = .horizontal
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(stack)

    // GENRES: the shout heading (28 above, 12 below) and the two-column grid.
    let heading = CassetteHeading.makeTableHeaderView(
      shout: "GENRES",
      answer: nil,
      answerColor: .cassette(.textSecondary),
      sideInset: Self.inset
    )
    heading.translatesAutoresizingMaskIntoConstraints = false
    genresBlock.translatesAutoresizingMaskIntoConstraints = false
    genresBlock.isHidden = true
    genresBlock.addSubview(heading)
    genresGrid.axis = .vertical
    genresGrid.spacing = Self.gridGap
    genresGrid.translatesAutoresizingMaskIntoConstraints = false
    genresBlock.addSubview(genresGrid)
    addSubview(genresBlock)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.chipTopGap),
      scrollView.heightAnchor.constraint(equalToConstant: Self.chipHeight),
      stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

      genresBlock.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
      genresBlock.leadingAnchor.constraint(equalTo: leadingAnchor),
      genresBlock.trailingAnchor.constraint(equalTo: trailingAnchor),

      heading.topAnchor.constraint(equalTo: genresBlock.topAnchor),
      heading.leadingAnchor.constraint(equalTo: genresBlock.leadingAnchor),
      heading.trailingAnchor.constraint(equalTo: genresBlock.trailingAnchor),
      heading.heightAnchor.constraint(equalToConstant: CassetteHeading.tableHeaderHeight),

      genresGrid.topAnchor.constraint(equalTo: heading.bottomAnchor),
      genresGrid.leadingAnchor.constraint(equalTo: genresBlock.leadingAnchor, constant: Self.inset),
      genresGrid.trailingAnchor.constraint(
        equalTo: genresBlock.trailingAnchor,
        constant: -Self.inset
      ),
      genresGrid.bottomAnchor.constraint(equalTo: genresBlock.bottomAnchor),
    ])

    for start in starts {
      let chip = Self.chip(for: start)
      chipsByTitle[start.title] = chip
      stack.addArrangedSubview(chip)
    }
  }

  /// Shows or hides the chip titled `title` (Shuffle all, while the phone holds no music).
  func setStart(_ title: String, hidden: Bool) {
    guard let chip = chipsByTitle[title], chip.isHidden != hidden else { return }
    chip.isHidden = hidden
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// The height the view needs: the chips, plus the GENRES block when there are genres.
  /// A table header has no Auto Layout height, so the host sets this as its frame height.
  var preferredHeight: CGFloat {
    let chips = Self.chipTopGap + Self.chipHeight
    guard genreRowCount > 0 else { return chips }
    let rows = CGFloat(genreRowCount)
    let grid = rows * GenreTileView.height + (rows - 1) * Self.gridGap
    return chips + CassetteHeading.tableHeaderHeight + grid
  }

  /// Lays out the genre tiles two to a row, biggest first. An empty list hides the block.
  func setGenres(_ genres: [GenreTile]) {
    genresGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
    genreRowCount = 0
    genresBlock.isHidden = genres.isEmpty
    guard !genres.isEmpty else { return }
    var index = 0
    while index < genres.count {
      let row = UIStackView()
      row.axis = .horizontal
      row.distribution = .fillEqually
      row.spacing = Self.gridGap
      row.heightAnchor.constraint(equalToConstant: GenreTileView.height).isActive = true
      row.addArrangedSubview(GenreTileView(genre: genres[index]))
      if index + 1 < genres.count {
        row.addArrangedSubview(GenreTileView(genre: genres[index + 1]))
      } else {
        // An odd last tile keeps its column width.
        row.addArrangedSubview(UIView())
      }
      genresGrid.addArrangedSubview(row)
      genreRowCount += 1
      index += 2
    }
  }

  private static func chip(for start: Start) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.cornerStyle = .capsule
    config.image = start.icon.uiImage(size: .row)
    config.imagePadding = 6
    config.baseForegroundColor = .cassette(.textPrimary)
    // phone-taste: bg3 fill (`.chip` background), the ring as before.
    config.background.backgroundColor = .cassette(.surfaceElevated)
    config.background.strokeColor = .cassette(.hairline)
    config.background.strokeWidth = 1
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
    var attributes = AttributeContainer()
    attributes.font = UIFont.cassette(.miniTitle)
    config.attributedTitle = AttributedString(start.title, attributes: attributes)
    let button = UIButton(configuration: config, primaryAction: UIAction { _ in start.action() })
    button.heightAnchor.constraint(equalToConstant: chipHeight).isActive = true
    return button
  }
}

// MARK: - GenreTileView

/// One genre tile (`.genreTile`): 104pt tall, in the record's hue at the shared soft tone,
/// the record itself tipped into the top-right corner, the name and the album count at the
/// bottom. The whole tile is one button.
@MainActor
private final class GenreTileView: UIControl {
  static let height: CGFloat = 104
  private static let padding: CGFloat = 12
  private static let coverSide: CGFloat = 64

  private let coverHost = UIView()
  private let nameLabel = UILabel()
  private let countLabel = UILabel()
  private var tint: CoverTint = .neutral
  private let action: () -> ()

  init(genre: SearchStartView.GenreTile) {
    action = genre.action
    super.init(frame: .zero)
    layer.cornerRadius = CassetteRadius.genreTile
    layer.cornerCurve = .continuous
    clipsToBounds = true

    // The record (`.genreCover`): 64pt, pinned 8pt past the right edge and 10pt from the
    // top, turned 14 degrees, with a soft drop shadow in the tile's hue. The shadow sits on
    // a host view because the image clips to its corners.
    coverHost.translatesAutoresizingMaskIntoConstraints = false
    coverHost.isUserInteractionEnabled = false
    coverHost.isHidden = (genre.cover == nil)
    coverHost.layer.shadowOpacity = 0.45
    coverHost.layer.shadowRadius = 9
    coverHost.layer.shadowOffset = CGSize(width: 0, height: 8)
    coverHost.layer.shadowPath = UIBezierPath(
      roundedRect: CGRect(x: 0, y: 0, width: Self.coverSide, height: Self.coverSide),
      cornerRadius: CassetteRadius.artworkRow
    ).cgPath
    coverHost.transform = CGAffineTransform(rotationAngle: 14 * .pi / 180)
    let coverView = UIImageView(image: genre.cover)
    coverView.translatesAutoresizingMaskIntoConstraints = false
    coverView.contentMode = .scaleAspectFill
    coverView.layer.cornerRadius = CassetteRadius.artworkRow
    coverView.layer.masksToBounds = true
    coverHost.addSubview(coverView)
    addSubview(coverHost)

    // The name: Barlow ExtraBold 20 in capitals, at most 70% of the tile.
    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.font = UIFont.cassetteDisplay(size: 20, weight: .extraBold)
    nameLabel.text = genre.name.uppercased()
    nameLabel.numberOfLines = 2
    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.adjustsFontForContentSizeCategory = false
    addSubview(nameLabel)

    // The count: the bare number, mono at the 13pt floor (the mock's 11px is not used).
    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.font = UIFont.cassette(.caption)
    countLabel.text = "\(genre.albumCount)"
    addSubview(countLabel)

    NSLayoutConstraint.activate([
      coverHost.widthAnchor.constraint(equalToConstant: Self.coverSide),
      coverHost.heightAnchor.constraint(equalToConstant: Self.coverSide),
      coverHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 8),
      coverHost.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      coverView.topAnchor.constraint(equalTo: coverHost.topAnchor),
      coverView.bottomAnchor.constraint(equalTo: coverHost.bottomAnchor),
      coverView.leadingAnchor.constraint(equalTo: coverHost.leadingAnchor),
      coverView.trailingAnchor.constraint(equalTo: coverHost.trailingAnchor),

      countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
      countLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
      nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
      nameLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7),
      nameLabel.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -4),
      nameLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Self.padding),
    ])

    // The colour: from the cache when the cover has been read before (so the grid does not
    // flash neutral), else neutral until the read lands.
    if let coverPath = genre.coverPath, !coverPath.isEmpty {
      if let hit = CoverTint.cached(coverPath: coverPath) { tint = hit }
      Task { [weak self] in
        guard let read = await CoverTint.resolve(coverPath: coverPath) else { return }
        self?.apply(read)
      }
    } else if let cover = genre.cover {
      let key = "genre-tile:\(genre.name)"
      if let hit = CoverTint.cached(key: key) { tint = hit }
      Task { [weak self] in
        self?.apply(await CoverTint.resolve(image: cover, key: key))
      }
    }
    paint()
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
      self.paint()
    }

    isAccessibilityElement = true
    accessibilityTraits = .button
    accessibilityLabel = "\(genre.name), \(genre.albumCount) album\(genre.albumCount == 1 ? "" : "s")"
    addAction(UIAction { [weak self] _ in self?.action() }, for: .touchUpInside)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func apply(_ read: CoverTint) {
    guard read != tint else { return }
    tint = read
    paint()
  }

  /// The tile, its words and the record's shadow in the tint. The shadow is a CGColor, so it
  /// is resolved against the current appearance here and again when the appearance changes.
  private func paint() {
    backgroundColor = tint.tileFill
    nameLabel.textColor = tint.tileInk
    countLabel.textColor = tint.tileCount
    coverHost.layer.shadowColor = tint.tileShadow.resolvedColor(with: traitCollection).cgColor
  }

  override var isHighlighted: Bool {
    didSet {
      guard isHighlighted != oldValue else { return }
      UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.alpha = self.isHighlighted ? 0.7 : 1
      }
    }
  }
}
