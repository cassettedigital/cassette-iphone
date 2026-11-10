//
//  GenericDetailTableHeader.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 19.02.22.
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

// MARK: - DetailHeroStyle

/// How a detail header draws its hero (phone-taste record pages). Every style is compact
/// width only: on iPad and Mac (regular width) each one keeps the classic side-by-side
/// layout.
enum DetailHeroStyle {
  /// Today's centred header (Genre, Podcast, Playlist edit).
  case classic
  /// The record room (album, playlist): the 240pt cover centred up top between the back
  /// and more buttons, then a left-aligned caps title, the answer line in the record's
  /// colour and the tracked meta line.
  case room
  /// The artist page: a full-bleed photo when the artist has their own, else a fan of
  /// their newest covers, else today's circle; the name in large caps.
  case artistHero
}

// MARK: - DetailHeaderConfiguration

struct DetailHeaderConfiguration {
  var entityContainer: PlayableContainable
  var rootView: UIViewController
  var tableView: UITableView
  var playShuffleInfoConfig: PlayShuffleInfoConfiguration?
  var descriptionText: String?
  /// cassette Patch 104 (Root 2): album/artist detail extend the scroll
  /// under the navigation bar so the artwork is the first content and the
  /// nav (back/overflow) floats over it. The header pads its top by the
  /// root view's safe-area inset instead of relying on the bar pushing
  /// the content down. Other detail screens leave this false and keep
  /// the below-the-bar layout.
  var extendsUnderNavigationBar: Bool = false
  /// phone-taste: the hero's look. `.classic` (the default) is today's header.
  var heroStyle: DetailHeroStyle = .classic
}

// MARK: - DetailSubtitleButton

/// Artist line on album detail: keeps the visual size of the title, but
/// expands the touch target vertically so it clears ~44pt.
private final class DetailSubtitleButton: UIButton {
  private let verticalHitSlop: CGFloat = 12

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: 0, dy: -verticalHitSlop).contains(point)
  }
}

// MARK: - DetailAnswerLabel

/// The room's answer line (an album's artist, a playlist's own description), in the answer
/// voice over up to three lines. A UIButton's configuration title cannot be held to a line
/// count, so the room draws the line here and keeps the artist link's behaviour: the same
/// 12pt vertical hit slop as DetailSubtitleButton, the link trait, and the push.
private final class DetailAnswerLabel: UILabel {
  private let verticalHitSlop: CGFloat = 12
  /// Set when the line is a link (the album artist).
  var onActivate: (() -> ())?

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: 0, dy: -verticalHitSlop).contains(point)
  }

  override func accessibilityActivate() -> Bool {
    guard let onActivate else { return false }
    onActivate()
    return true
  }
}

// MARK: - DetailCoverShadowView

/// One of the two shadows under a lit hero cover. EntityImageView clips to its corners, so
/// the shadow lives on its own view behind the cover, the same size, with a path that
/// follows the cover's real shape (rounded rect, or an ellipse for the artist circle).
private final class DetailCoverShadowView: UIView {
  /// The cover's outline for a bounds.
  var outline: ((CGRect) -> UIBezierPath)?

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.shadowPath = outline?(bounds).cgPath
  }
}

// MARK: - DetailArtistPhotoView

/// The artist's own photo, full bleed: aspect fill biased toward the top quarter of the
/// picture (the mock's `object-position: 50% 25%`), fading out over its lower half.
private final class DetailArtistPhotoView: UIView {
  private let fade = CAGradientLayer()

  var image: UIImage? {
    didSet {
      layer.contents = image?.cgImage
      setNeedsLayout()
    }
  }

  /// Show `image`, cross-fading it in when it arrives after the hero is already laid out
  /// (the photo's geometry is in place from the first pass; only the picture is late).
  func show(_ image: UIImage?, fading: Bool) {
    if fading, window != nil {
      let fadeIn = CATransition()
      fadeIn.type = .fade
      fadeIn.duration = 0.25
      layer.add(fadeIn, forKey: "contents")
    }
    self.image = image
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true
    layer.contentsGravity = .resize
    // The mock's mask: solid to 55%, clear at the bottom edge.
    fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
    fade.locations = [0, 0.55, 1]
    layer.mask = fade
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fade.frame = bounds
    layer.contentsRect = Self.contentsRect(imageSize: image?.size ?? .zero, in: bounds.size)
    CATransaction.commit()
  }

  /// The part of the image that fills `size`: the full width or height, the other axis
  /// cropped, centred horizontally and 25% down vertically.
  static func contentsRect(imageSize: CGSize, in size: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0
    else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
    let imageAspect = imageSize.width / imageSize.height
    let viewAspect = size.width / size.height
    if imageAspect < viewAspect {
      // Taller than the frame: show the full width and a band of the height.
      let shown = imageAspect / viewAspect
      return CGRect(x: 0, y: (1 - shown) * 0.25, width: 1, height: shown)
    }
    let shown = viewAspect / imageAspect
    return CGRect(x: (1 - shown) * 0.5, y: 0, width: shown, height: 1)
  }
}

// MARK: - DetailCoverFanView

/// No photo: the artist's own newest records, up to three covers fanned 46pt over each
/// other, the second raised 14pt and in front (the mock's `.artistCovers`).
private final class DetailCoverFanView: UIView {
  static let coverSide: CGFloat = 150
  static let overlap: CGFloat = 46
  static let raise: CGFloat = 14
  static var height: CGFloat { coverSide + raise }

  private var hosts: [UIView] = []
  private(set) var albumIDs: [String] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show(albums: [Album], theme: ThemePreference) {
    let shown = Array(albums.prefix(3))
    albumIDs = shown.map(\.id)
    hosts.forEach { $0.removeFromSuperview() }
    hosts = shown.map { album in
      let host = DetailCoverShadowView(frame: CGRect(
        x: 0,
        y: 0,
        width: Self.coverSide,
        height: Self.coverSide
      ))
      host.backgroundColor = .clear
      host.layer.shadowColor = UIColor.black.cgColor
      host.layer.shadowOpacity = 0.5
      host.layer.shadowRadius = 20
      host.layer.shadowOffset = CGSize(width: 0, height: 18)
      host.outline = { bounds in
        UIBezierPath(roundedRect: bounds, cornerRadius: CornerRadius.small.asCGFloat)
      }
      let cover = EntityImageView(frame: host.bounds)
      cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      cover.shape = .rounded(.small)
      cover.display(theme: theme, container: album)
      host.addSubview(cover)
      return host
    }
    // The second cover sits in front of its neighbours.
    for (index, host) in hosts.enumerated() where index != 1 {
      addSubview(host)
    }
    if hosts.count > 1 { addSubview(hosts[1]) }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let count = CGFloat(hosts.count)
    guard count > 0 else { return }
    let step = Self.coverSide - Self.overlap
    let total = Self.coverSide + step * (count - 1)
    var x = (bounds.width - total) / 2
    for (index, host) in hosts.enumerated() {
      let y = index == 1 ? 0 : Self.raise
      host.frame = CGRect(x: x, y: y, width: Self.coverSide, height: Self.coverSide)
      x += step
    }
  }
}

// MARK: - GenericDetailTableHeader

/// cassette Patch 104 (Root 2): rebuilt programmatically. The old XIB was a
/// fixed-height block (424pt of hand-tuned constants) whose artwork lived in
/// a nested stack below the navigation bar — it could never be the top of
/// the scroll, and its IB-instantiated plain buttons + systemBackground
/// artwork backing leaked the iOS 26 default glass treatment (Root 1).
/// The header now self-sizes, owns no fixed frame constants, and the
/// artwork is the first content of the scroll view.
class GenericDetailTableHeader: UIView {
  /// The page title's bottom edge in this view's coordinates (nil while it is hidden): the bar
  /// and its small title arrive as this edge slides under the bar (DetailStickyHeaderSupport).
  var titleBottom: CGFloat? {
    guard !titleLabel.isHidden, titleLabel.superview != nil else { return nil }
    return titleLabel.convert(titleLabel.bounds, to: self).maxY
  }

  // MARK: Subviews

  let entityImage = EntityImageView(
    frame: CGRect(
      x: 0,
      y: 0,
      width: GenericDetailTableHeader.artworkSide,
      height: GenericDetailTableHeader.artworkSide
    )
  )

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.cassette(.heroTitle)
    label.textColor = UIColor.cassette(.textPrimary)
    label.numberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
  }()

  private let nameTextField: UITextField = {
    let field = UITextField()
    field.font = UIFont.cassette(.heroTitle)
    field.textColor = UIColor.cassette(.textPrimary)
    field.isHidden = true
    field.setContentCompressionResistancePriority(.required, for: .vertical)
    return field
  }()

  // Patch 104 (Root 1): the XIB's invisible full-width system button behind
  // the subtitle label picked up the iOS 26 glass capsule. The subtitle is
  // now a single bare-configured button (label + action in one view).
  private let subtitleButton: UIButton = {
    let button = DetailSubtitleButton(configuration: .cassetteBare())
    button.configuration?.contentInsets = .zero
    return button
  }()

  /// phone-taste: the room's answer line (see DetailAnswerLabel).
  private let answerLabel: DetailAnswerLabel = {
    let label = DetailAnswerLabel()
    label.numberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    label.isHidden = true
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
  }()

  private let infoLabel: UILabel = {
    let label = UILabel()
    // Quiet mono caption (year / album·song counts) — not Barlow.
    label.font = UIFont.cassette(.caption)
    label.textColor = UIColor.cassette(.textSecondary)
    label.numberOfLines = 2
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
  }()

  private let descriptionLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.cassette(.body)
    label.textColor = UIColor.cassette(.textSecondary)
    label.numberOfLines = 0
    label.isHidden = true
    return label
  }()

  private let artworkWrap = UIView()
  private let playSlot: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    return stack
  }()

  private let contentColumn: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = CassetteTheme.Spacing.xs
    return stack
  }()

  private let mainStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = CassetteTheme.Spacing.md
    return stack
  }()

  // MARK: phone-taste lighting

  /// Clips the record's glow at the header's bottom edge while letting it rise 300pt above
  /// the top for overscroll. The glow view inside spans exactly the header, so its scrim
  /// reaches the solid page at the header's bottom edge.
  private var glowClip: UIView?
  private var glowView: CoverGlowView?
  /// The two cover shadows (the mock's `.heroCover` box-shadow pair), behind entityImage.
  private var tintShadow: DetailCoverShadowView?
  private var depthShadow: DetailCoverShadowView?
  /// The artist's own photo, full bleed (artist hero only).
  private var artistPhotoView: DetailArtistPhotoView?
  /// The fan of the artist's newest covers (artist hero, no photo).
  private let fanView = DetailCoverFanView()
  private var fanConstraints: [NSLayoutConstraint] = []
  /// Artist hero with a photo: the hidden circle keeps only a horizontal position, so
  /// nothing asks the hidden artwork block for a height (the stack holds it at zero).
  private var photoConstraints: [NSLayoutConstraint] = []

  /// The record colour this page is lit with; nil until a host lights it (unlit pages,
  /// Genre/Podcast/Playlist edit, never are). Until then a lit style reads `.neutral`.
  private(set) var coverTint: CoverTint?

  /// Whether the artist's own photo is on the phone. Set synchronously from the file, so
  /// the hero opens in the photo's geometry; the picture fades in when it is decoded.
  private var hasArtistPhoto = false
  /// The photo file (and its modification date) shown or being decoded, and one that would
  /// not decode, so it is not tried again on every appearance.
  private var artistPhotoKey: String?
  private var unreadableArtistPhotoKey: String?
  /// Recently decoded artist photos by file and modification date, so opening an artist
  /// again shows the photo in the first frame. A few full-width photos at most.
  @MainActor
  private static let artistPhotoCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 3
    return cache
  }()
  /// The artist's newest credited records, for the fan when there is no photo.
  private var fanAlbums: [Album] = []

  var playShuffleInfoView: LibraryElementDetailTableHeaderView?
  var isEditing = false

  /// Optional one-line metadata that replaces the auto-generated info
  /// text (e.g. "2024 · 23m"). Detail VCs set this in their existing
  /// refresh path; nil falls back to the entity's default
  /// `info(for:details:)` output.
  ///
  /// cassette: an EMPTY string is meaningful and distinct from nil — it
  /// means "this screen has nothing worth putting on the line, show no
  /// line." Previously empty was treated like nil and fell through to the
  /// verbose default, so a record with no year and no duration couldn't
  /// end up with a clean header.
  var metadataOverride: String? {
    didSet { refresh() }
  }

  /// phone-taste: the line under the title when it is not the entity's own subtitle (a
  /// playlist's description, shown verbatim). nil falls back to the entity's subtitle (an
  /// album's artist).
  var answerLine: String? {
    didSet {
      guard answerLine != oldValue else { return }
      refresh()
    }
  }

  // MARK: Layout constants

  /// Square artwork side (album / playlist / genre / podcast).
  private static let artworkSide: CGFloat = 240.0
  /// Artist photos render as a slightly smaller circle so the tightened
  /// picture/title/subtitle block reads as one unit.
  private static let artistCircleDiameter: CGFloat = 200.0

  /// The record room's measures (phone.module.css .room, .albumHead, .artistLine, .meta,
  /// .metaAlone, .actions).
  private enum Room {
    static let sideMargin: CGFloat = 22
    static let coverToTitle: CGFloat = 24
    static let titleToLine: CGFloat = 6
    static let lineToMeta: CGFloat = 10
    static let titleToMetaAlone: CGFloat = 10
    static let metaToActions: CGFloat = 18
    static let bottom: CGFloat = 24
    /// The artist name sits 8pt over its meta line (.artistName margin-bottom).
    static let nameToMeta: CGFloat = 8
  }

  /// The artist hero's measures (.artistPhoto, .artistHead, .artistCovers).
  private enum ArtistHero {
    static let photoHeight: CGFloat = 400
    /// The name climbs this far up into the photo's faded foot.
    static let photoOverlap: CGFloat = 92
    /// Space between the fan and the name.
    static let fanToHead: CGFloat = 22
  }

  /// How the hero is drawn right now: the configured style resolved against the width
  /// and, for an artist, what is on the phone.
  private enum HeroLayout {
    case classic
    case room
    case artistPhoto
    case artistFan
    case artistCircle

    var isLit: Bool { self != .classic }
    var isArtist: Bool { self == .artistPhoto || self == .artistFan || self == .artistCircle }
  }

  private var heroLayout: HeroLayout {
    guard let config, isCompactWidth else { return .classic }
    switch config.heroStyle {
    case .classic:
      return .classic
    case .room:
      return .room
    case .artistHero:
      if hasArtistPhoto { return .artistPhoto }
      if !fanAlbums.isEmpty { return .artistFan }
      return .artistCircle
    }
  }

  private var config: DetailHeaderConfiguration?

  private var artworkWidthConstraint: NSLayoutConstraint!
  private var playSlotHeightConstraint: NSLayoutConstraint!
  private var compactConstraints: [NSLayoutConstraint] = []
  private var regularConstraints: [NSLayoutConstraint] = []
  private var lastLayoutWidth: CGFloat = 0

  // MARK: Creation

  public static func createTableHeader(configuration: DetailHeaderConfiguration)
    -> GenericDetailTableHeader? {
    let header = GenericDetailTableHeader(frame: CGRect(
      x: 0,
      y: 0,
      width: configuration.rootView.view.bounds.size.width,
      height: 1000 // corrected in viewDidLayoutSubviews once nav bar geometry is available
    ))
    header.prepare(configuration: configuration)
    configuration.tableView.tableHeaderView = header
    header.resizeToFit()
    return header
  }

  func prepare(configuration: DetailHeaderConfiguration) {
    config = configuration
    config?.playShuffleInfoConfig?.isEmbeddedInOtherView = true
    // cassette Polish 2 (D1): hand the embedded action bar the entity + root VC
    // so its heart can favorite the container and its overflow can open the
    // entity context menu — no per-VC wiring needed.
    config?.playShuffleInfoConfig?.favoriteEntity = configuration.entityContainer
    config?.playShuffleInfoConfig?.rootViewController = configuration.rootView

    buildHierarchyIfNeeded()

    if let playShuffleInfoConfig = config?.playShuffleInfoConfig {
      playShuffleInfoView = ViewCreator<LibraryElementDetailTableHeaderView>.createFromNib()
      playSlot.addArrangedSubview(playShuffleInfoView!)
      playShuffleInfoView?.prepare(configuration: playShuffleInfoConfig)
      playSlot.isHidden = false
    } else {
      playSlot.isHidden = true
    }

    if let descriptionText = configuration.descriptionText {
      descriptionLabel.text = descriptionText
      descriptionLabel.isHidden = false
    } else {
      descriptionLabel.isHidden = true
    }

    configureArtworkPresentation()
    if configuration.heroStyle == .artistHero {
      refreshArtistPhoto()
    }
    applyLayout()
    refresh()
    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, _: UITraitCollection) in
        self.applyLayout()
        self.refresh()
        self.resizeToFit()
      }
    )
  }

  private var didBuildHierarchy = false

  private func buildHierarchyIfNeeded() {
    guard !didBuildHierarchy else { return }
    didBuildHierarchy = true

    backgroundColor = .clear
    // The header sits under the status/navigation bars at rest, so UIKit
    // propagates that covered region into its safeAreaInsets; with the
    // default insetsLayoutMarginsFromSafeArea the layoutMarginsGuide would
    // add it ON TOP of the manual bar clearance from resizeToFit, doubling
    // the gap above the artwork (and re-measuring it during scroll).
    insetsLayoutMarginsFromSafeArea = false
    directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: CassetteTheme.Spacing.md,
      leading: UIView.defaultMarginX,
      bottom: CassetteTheme.Spacing.lg,
      trailing: UIView.defaultMarginX
    )

    subtitleButton.addTarget(self, action: #selector(subtitleButtonPressed), for: .touchUpInside)
    answerLabel.addGestureRecognizer(UITapGestureRecognizer(
      target: self,
      action: #selector(subtitleButtonPressed)
    ))

    entityImage.translatesAutoresizingMaskIntoConstraints = false
    artworkWrap.translatesAutoresizingMaskIntoConstraints = false
    mainStack.translatesAutoresizingMaskIntoConstraints = false
    fanView.translatesAutoresizingMaskIntoConstraints = false

    artworkWrap.addSubview(entityImage)
    artworkWrap.addSubview(fanView)
    fanView.isHidden = true

    contentColumn.addArrangedSubview(titleLabel)
    contentColumn.addArrangedSubview(nameTextField)
    contentColumn.addArrangedSubview(subtitleButton)
    contentColumn.addArrangedSubview(answerLabel)
    contentColumn.addArrangedSubview(infoLabel)
    contentColumn.addArrangedSubview(playSlot)
    contentColumn.addArrangedSubview(descriptionLabel)
    // Breathing room: tight type block, then air before the action bar and
    // the optional description.
    contentColumn.setCustomSpacing(CassetteTheme.Spacing.lg, after: infoLabel)
    contentColumn.setCustomSpacing(CassetteTheme.Spacing.lg, after: playSlot)

    mainStack.addArrangedSubview(artworkWrap)
    mainStack.addArrangedSubview(contentColumn)
    addSubview(mainStack)

    artworkWidthConstraint = entityImage.widthAnchor
      .constraint(equalToConstant: Self.artworkSide)
    playSlotHeightConstraint = playSlot.heightAnchor.constraint(
      equalToConstant: LibraryElementDetailTableHeaderView.prominentBarHeight
    )

    // The horizontal stack-to-margins pins are dropped just below required so
    // the transient UITableView layout pass that sizes the header at width 0
    // ('UIView-Encapsulated-Layout-Width == 0', before it knows the real
    // width) can't force an unsatisfiable conflict against the 25pt side
    // margins + the 240pt artwork. At the real width nothing competes with
    // them, so they resolve exactly and layout is unchanged. The vertical
    // pins stay required — they drive the self-sizing height and never
    // conflict with a width-0 pass.
    let leadingPin = mainStack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor)
    let trailingPin = mainStack.trailingAnchor
      .constraint(equalTo: layoutMarginsGuide.trailingAnchor)
    leadingPin.priority = UILayoutPriority(999)
    trailingPin.priority = UILayoutPriority(999)

    NSLayoutConstraint.activate([
      mainStack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
      mainStack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
      leadingPin,
      trailingPin,

      entityImage.widthAnchor.constraint(equalTo: entityImage.heightAnchor),
      entityImage.topAnchor.constraint(equalTo: artworkWrap.topAnchor),
      artworkWidthConstraint,
      playSlotHeightConstraint,
    ])

    compactConstraints = [
      entityImage.centerXAnchor.constraint(equalTo: artworkWrap.centerXAnchor),
      entityImage.bottomAnchor.constraint(equalTo: artworkWrap.bottomAnchor),
    ]
    regularConstraints = [
      entityImage.leadingAnchor.constraint(equalTo: artworkWrap.leadingAnchor),
      entityImage.bottomAnchor.constraint(lessThanOrEqualTo: artworkWrap.bottomAnchor),
      artworkWrap.widthAnchor.constraint(equalToConstant: Self.artworkSide),
    ]
    // Artist hero without a photo: the fan sets the artwork block's height; the (hidden)
    // circle only keeps a horizontal position.
    fanConstraints = [
      entityImage.centerXAnchor.constraint(equalTo: artworkWrap.centerXAnchor),
      fanView.topAnchor.constraint(equalTo: artworkWrap.topAnchor),
      fanView.bottomAnchor.constraint(equalTo: artworkWrap.bottomAnchor),
      fanView.leadingAnchor.constraint(equalTo: artworkWrap.leadingAnchor),
      fanView.trailingAnchor.constraint(equalTo: artworkWrap.trailingAnchor),
      fanView.heightAnchor.constraint(equalToConstant: DetailCoverFanView.height),
    ]
    photoConstraints = [
      entityImage.centerXAnchor.constraint(equalTo: artworkWrap.centerXAnchor),
    ]
  }

  // cassette redesign (Surface 1) + Patch 104 (Root 3): the artist photo is
  // a clean circular crop owned by EntityImageView's shape — correct on
  // layout and after async image loads. Everything else keeps the squared
  // rounded crop.
  private func configureArtworkPresentation() {
    guard let entityContainer = config?.entityContainer else { return }
    // cassette: the artist photo is a circular crop. Album covers use a much
    // smaller corner radius (.verySmall = 3pt, vs the .small = 5pt everything
    // else uses) so a bordered / framed cover keeps crisp corners instead of
    // having its border shaved off by the rounding. Other non-artist entities
    // (playlists, podcasts, genres) keep the standard .small.
    if entityContainer is Artist {
      entityImage.shape = .circle
    } else {
      entityImage.shape = .rounded(heroCornerRadius(for: entityContainer))
    }
  }

  /// The hero's corner: an album's 3pt, everything else 5pt. `refresh()` hands it to
  /// `display`, which otherwise puts every cover back to 5pt (BUG-454).
  private func heroCornerRadius(for entityContainer: PlayableContainable) -> CornerRadius {
    entityContainer is Album ? .verySmall : .small
  }

  private var isCompactWidth: Bool {
    traitCollection.horizontalSizeClass == .compact
  }

  private func applyLayout() {
    let compact = isCompactWidth
    let layout = heroLayout
    NSLayoutConstraint.deactivate(
      regularConstraints + compactConstraints + fanConstraints + photoConstraints
    )
    if !compact {
      NSLayoutConstraint.activate(regularConstraints)
    } else if layout == .artistFan {
      NSLayoutConstraint.activate(fanConstraints)
    } else if layout == .artistPhoto {
      // The artwork block is hidden in the stack (height 0). Pinning the 200pt circle's
      // bottom to it, as compactConstraints do, would fight that on every layout pass.
      NSLayoutConstraint.activate(photoConstraints)
    } else {
      NSLayoutConstraint.activate(compactConstraints)
    }
    mainStack.axis = compact ? .vertical : .horizontal
    mainStack.alignment = compact ? .fill : .top
    switch layout {
    case .room:
      mainStack.spacing = Room.coverToTitle
    case .artistFan:
      mainStack.spacing = ArtistHero.fanToHead
    case .classic, .artistPhoto, .artistCircle:
      mainStack.spacing = compact ? CassetteTheme.Spacing.md : CassetteTheme.Spacing.xl
    }
    // The page gutter: 22 in the lit styles, today's 25 otherwise. The top margin is
    // resizeToFit's (the bar clearance), so it is kept as it is.
    let side = layout.isLit ? Room.sideMargin : UIView.defaultMarginX
    let bottom = layout.isLit ? Room.bottom : CassetteTheme.Spacing.lg
    let margins = NSDirectionalEdgeInsets(
      top: directionalLayoutMargins.top,
      leading: side,
      bottom: bottom,
      trailing: side
    )
    if directionalLayoutMargins != margins {
      directionalLayoutMargins = margins
    }
    // The artist hero draws its photo or its fan in place of the circle.
    artworkWrap.isHidden = layout == .artistPhoto
    entityImage.isHidden = layout == .artistFan
    fanView.isHidden = layout != .artistFan
    artistPhotoView?.isHidden = layout != .artistPhoto
    applyShadowVisibility()
    artworkWidthConstraint.constant = (compact && config?.entityContainer is Artist)
      ? Self.artistCircleDiameter
      : Self.artworkSide
    let isProminent = config?.playShuffleInfoConfig?.usesProminentPlayButton ?? false
    playSlotHeightConstraint.constant = (compact && isProminent)
      ? LibraryElementDetailTableHeaderView.prominentBarHeight
      : 40.0
  }

  /// Self-sizing replacement for the old fixed-height constant zoo. Sizes the
  /// header as topInset + mainStackHeight + bottomInset so the margin and the
  /// frame always land together — no transient constraint break, no
  /// "Unable to simultaneously satisfy constraints" from Auto Layout.
  func resizeToFit() {
    guard let config else { return }
    // cassette (header-pop fix, round 3): hard freeze for the whole pop. While
    // the host VC is mid-transition out of the stack, ANY re-measure here would
    // reset the table's content layout and snap the scrolled-collapsed hero back
    // to expanded ("pops in"). The reassignment guard below (round 2) covered
    // only one trigger; this covers all of them for the transition's duration.
    if (config.rootView as? BasicTableViewController)?.isHeaderTransitionFrozen == true {
      return
    }
    let tableWidth = config.tableView.bounds.width > 0
      ? config.tableView.bounds.width
      : config.rootView.view.bounds.width
    guard tableWidth > 0 else { return }

    // Determine the desired top clearance.
    // For screens that extend under the nav bar the inset is the STATUS-BAR
    // height (= nav bar's minY in window space) so art starts at the button
    // line, not below it. Guard: if neither value is available yet (early
    // viewDidLoad call before the window hierarchy is settled) return — the
    // VC's viewDidLayoutSubviews will call us back with correct geometry.
    let topInset: CGFloat
    if config.extendsUnderNavigationBar {
      let navBarMinY = config.rootView.navigationController?.navigationBar.frame.minY ?? 0
      let safeTop = config.rootView.view.safeAreaInsets.top
      guard navBarMinY > 0 || safeTop > 0 else { return }
      let statusBarH = navBarMinY > 0 ? navBarMinY : safeTop
      switch heroLayout {
      case .artistPhoto:
        // phone-taste: the photo starts at y = 0 under the status bar and the name
        // climbs 92pt into its faded foot (.artistHead margin-top -92).
        topInset = ArtistHero.photoHeight - ArtistHero.photoOverlap
      case .artistFan:
        // The fan starts just under the back and more buttons (.artistCovers).
        topInset = statusBarH + 44
      case .classic, .room, .artistCircle:
        topInset = statusBarH + CassetteTheme.Spacing.sm
      }
    } else {
      topInset = directionalLayoutMargins.top
    }
    let bottomInset = directionalLayoutMargins.bottom

    // Measure the main content stack independently of the header's current
    // frame and margins so topInset + stackHeight + bottomInset are computed
    // together. Setting margins.top on a small frame first, then calling
    // systemLayoutSizeFitting on the whole view, creates a window where the
    // layout engine sees e.g. margins.top=70 inside a frame.height=100 — the
    // artwork's 240×240 + labels are crushed to ~14pt and a constraint breaks.
    let hInset = directionalLayoutMargins.leading + directionalLayoutMargins.trailing
    let innerWidth = max(0, tableWidth - hInset)
    let stackH = mainStack.systemLayoutSizeFitting(
      CGSize(width: innerWidth, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    ).height
    let newHeight = ceil(topInset + stackH + bottomInset)

    // Apply margin and frame together — they're always in sync from here on.
    if directionalLayoutMargins.top != topInset {
      directionalLayoutMargins.top = topInset
    }

    guard newHeight != frame.height || tableWidth != lastLayoutWidth else { return }
    // Defer mid-scroll re-measures: re-assigning tableHeaderView while dragging
    // mutates frame.maxY mid-flight, giving updateAlpha a spurious progress
    // spike → title flashes in then drops. The scroll-end hooks in both detail
    // VCs land the deferred size once the scroll settles.
    if config.tableView.isDragging || config.tableView.isDecelerating { return }

    // cassette: do NOT re-measure while the host VC is leaving the stack (a pop,
    // including the interactive edge-swipe). For the screens that extend under
    // the nav bar, `topInset` is derived from the nav bar's minY / the view's
    // top safe-area inset (see above) — both of which SHIFT mid-pop as UIKit
    // transitions the bar toward the destination's large-title layout. That
    // makes `newHeight` differ, and re-assigning `tableHeaderView` here resets
    // the table's content layout, snapping the scrolled-collapsed hero back to
    // expanded ("pops in") for the duration of the swipe. The VC is leaving, so
    // its header never needs a new size; skip. (Push-in sizing is unaffected —
    // the pushed VC is moving TO, not FROM, its parent. A cancelled pop
    // self-heals: viewIsAppearing recomputes the sticky-title alpha from the
    // preserved offset, and the next settled layout re-measures if needed.)
    if config.rootView.isMovingFromParent || config.rootView.isBeingDismissed { return }

    lastLayoutWidth = tableWidth
    UIView.performWithoutAnimation {
      frame = CGRect(x: 0, y: 0, width: tableWidth, height: newHeight)
      // Re-assigning makes the table view pick up the new frame.
      config.tableView.tableHeaderView = self
    }
  }

  func refresh() {
    guard let config = config else { return }
    let entityContainer = config.entityContainer
    let theme = appDelegate.storage.settings.accounts.getSetting(entityContainer.account?.info).read
      .themePreference
    entityImage.display(
      theme: theme,
      container: entityContainer,
      cornerRadius: heroCornerRadius(for: entityContainer)
    )

    let layout = heroLayout
    let tint = coverTint ?? .neutral
    applyTitle(name: entityContainer.name, layout: layout)

    // The line under the title: a playlist's own description, else the entity's subtitle
    // (an album's artist, the tappable link).
    let lineText = answerLine ?? entityContainer.subtitle
    let lineIsLink = entityContainer is Album && answerLine == nil
    if layout.isLit {
      // phone-taste: the answer voice in the record's colour (never brand orange), up to
      // two lines for an album and three for a playlist.
      subtitleButton.isHidden = true
      if let lineText, !lineText.isEmpty {
        answerLabel.attributedText = NSAttributedString.cassette(
          lineText,
          .answer,
          color: tint.text,
          lineHeightMultiple: 1.05
        )
        answerLabel.numberOfLines = entityContainer is Album ? 2 : 3
        answerLabel.isHidden = false
        answerLabel.isUserInteractionEnabled = lineIsLink
        answerLabel.accessibilityTraits = lineIsLink ? .link : .staticText
        answerLabel.onActivate = lineIsLink ? { [weak self] in self?.subtitleButtonPressed() } : nil
      } else {
        answerLabel.isHidden = true
      }
    } else {
      answerLabel.isHidden = true
      // Album artist is the tappable link (Barlow). Other entities keep quiet mono
      // under the title. Year lives on infoLabel in mono caption. A lit page (an album
      // at regular width) colours the link from its record instead of brand orange.
      var subtitleAttributes = AttributeContainer()
      subtitleAttributes.font = UIFont.cassette(lineIsLink ? .rowTitle : .cardSubtitle)
      subtitleAttributes.foregroundColor = lineIsLink
        ? (coverTint ?? .neutral).text // the warm neutral, never orange, before the cover is read (I-T4)
        : UIColor.cassette(.textSecondary)
      if let lineText {
        subtitleButton.configuration?.attributedTitle = AttributedString(
          lineText,
          attributes: subtitleAttributes
        )
        subtitleButton.isHidden = false
        subtitleButton.isUserInteractionEnabled = lineIsLink
        subtitleButton.accessibilityTraits = lineIsLink ? .link : .staticText
      } else {
        subtitleButton.isHidden = true
      }
    }

    let infoText: String
    if let metadataOverride {
      // Patch 026: detail VCs supply a curated metadata line (e.g.
      // "2024 · 23m") so we skip the verbose default info text. Empty is a
      // deliberate "no line" (see the property doc), not a fall-through.
      infoText = metadataOverride
    } else {
      var isCountInfoHidden = false
      if let playShuffleInfoConfig = config.playShuffleInfoConfig {
        isCountInfoHidden = !playShuffleInfoConfig.isInfoAlwaysHidden && playShuffleInfoConfig
          .isShuffleHidden && !isCompactWidth
      }
      let detailLevel = isCountInfoHidden ? DetailType.noCountInfo : DetailType.long
      infoText = entityContainer.info(
        for: entityContainer.account?.apiType.asServerApiType,
        details: DetailInfoType(type: detailLevel, settings: appDelegate.storage.settings)
      )
    }
    infoLabel.isHidden = infoText.isEmpty
    if layout.isLit {
      // phone-taste: the tracked mono meta in capitals, ink2.
      infoLabel.attributedText = NSAttributedString.cassette(
        infoText,
        .meta,
        color: .cassette(.textSecondary)
      )
    } else {
      infoLabel.attributedText = nil
      infoLabel.font = UIFont.cassette(.caption)
      infoLabel.textColor = UIColor.cassette(.textSecondary)
      infoLabel.text = infoText
    }

    if layout.isLit {
      applyLitSpacing(layout: layout, hasMeta: !infoText.isEmpty)
    } else {
      contentColumn.setCustomSpacing(UIStackView.spacingUseDefault, after: titleLabel)
      // Quiet meta (year) sits tight under the artist. When that line is absent,
      // keep real air between artist and the play controls — a hidden infoLabel
      // collapses its trailing spacing and used to leave play crushed under the
      // artist (stack default xs).
      if !subtitleButton.isHidden {
        if infoText.isEmpty {
          contentColumn.setCustomSpacing(CassetteTheme.Spacing.lg, after: subtitleButton)
        } else {
          // Year under artist: stack default xs (4) was too tight against the
          // UIButton subtitle's intrinsic padding; 2 was worse. Match the air
          // between title and artist (xs) plus a little — 8pt reads as one
          // quiet meta line, not glued to the name.
          contentColumn.setCustomSpacing(8, after: subtitleButton)
        }
      }
      contentColumn.setCustomSpacing(CassetteTheme.Spacing.lg, after: infoLabel)
    }

    // phone-taste: the lit styles read left-aligned under a centred cover. Their labels
    // carry natural alignment in their attributed text (with the line height), so the
    // label-wide alignment is only set for the classic header.
    let centred = isCompactWidth && !layout.isLit
    let textAlignment: NSTextAlignment = centred ? .center : .left
    if !layout.isLit {
      titleLabel.textAlignment = textAlignment
      infoLabel.textAlignment = textAlignment
    }
    nameTextField.textAlignment = textAlignment
    descriptionLabel.textAlignment = centred ? .center : .natural
    subtitleButton.contentHorizontalAlignment = centred ? .center : .leading

    if isEditing {
      titleLabel.isHidden = true
      nameTextField.isHidden = false
      nameTextField.text = entityContainer.name
    } else {
      titleLabel.isHidden = false
      nameTextField.isHidden = true
    }

    playShuffleInfoView?.refresh()
    resizeToFit()
  }

  /// The title in the header's voice: today's Barlow Bold 30, the room's 36pt ExtraBold
  /// capitals, or the artist hero's 46pt name with a soft shadow.
  private func applyTitle(name: String, layout: HeroLayout) {
    switch layout {
    case .classic:
      titleLabel.attributedText = nil
      titleLabel.font = UIFont.cassette(.heroTitle)
      titleLabel.textColor = UIColor.cassette(.textPrimary)
      titleLabel.text = name
      titleLabel.numberOfLines = 2
      titleLabel.adjustsFontSizeToFitWidth = false
      titleLabel.accessibilityLabel = nil
      titleLabel.layer.shadowOpacity = 0
    case .room:
      // Line height 0.92 as in the mock. Unverified on a device: if the caps clip at the
      // top, drop the multiple and use a small baselineOffset instead.
      titleLabel.attributedText = NSAttributedString.cassette(
        name,
        .pageTitle,
        color: .cassette(.textPrimary),
        lineHeightMultiple: 0.92
      )
      titleLabel.numberOfLines = 3
      titleLabel.adjustsFontSizeToFitWidth = false
      titleLabel.accessibilityLabel = name
      titleLabel.layer.shadowOpacity = 0
    case .artistPhoto, .artistFan, .artistCircle:
      titleLabel.attributedText = NSAttributedString.cassette(
        name,
        .heroName,
        color: .cassette(.textPrimary),
        lineHeightMultiple: 0.9
      )
      titleLabel.numberOfLines = 3
      titleLabel.adjustsFontSizeToFitWidth = true
      titleLabel.minimumScaleFactor = 0.6
      titleLabel.accessibilityLabel = name
      // The mock's text-shadow: 0 2px 18px rgba(0,0,0,.5).
      titleLabel.layer.shadowColor = UIColor.black.cgColor
      titleLabel.layer.shadowOpacity = 0.5
      titleLabel.layer.shadowRadius = 9
      titleLabel.layer.shadowOffset = CGSize(width: 0, height: 2)
    }
  }

  /// The lit styles' rhythm: title to line 6, line to meta 10 (meta 10 under the title
  /// when there is no line), meta to the pills 18. The artist name sits 8 over its meta.
  private func applyLitSpacing(layout: HeroLayout, hasMeta: Bool) {
    let hasLine = !answerLabel.isHidden
    let afterTitle: CGFloat
    if layout.isArtist {
      afterTitle = hasMeta ? Room.nameToMeta : Room.metaToActions
    } else if hasLine {
      afterTitle = Room.titleToLine
    } else {
      afterTitle = hasMeta ? Room.titleToMetaAlone : Room.metaToActions
    }
    contentColumn.setCustomSpacing(afterTitle, after: titleLabel)
    contentColumn.setCustomSpacing(hasMeta ? Room.lineToMeta : Room.metaToActions, after: answerLabel)
    contentColumn.setCustomSpacing(Room.metaToActions, after: infoLabel)
  }

  // MARK: phone-taste lighting

  /// Lights the header with its record: the glow behind it, the tinted cover shadow and the
  /// answer line's colour. `glowImage` is a small decode of the cover (nil shows no glow),
  /// cached under `glowKey`; an unchanged key leaves the glow as it is. The glow sits
  /// outside mainStack and never re-measures the header.
  func applyCoverLight(tint: CoverTint, glowImage: UIImage?, glowKey: String) {
    coverTint = tint
    installGlowIfNeeded()
    glowView?.show(image: glowImage, key: glowKey)
    installShadowsIfNeeded()
    tintShadow?.layer.shadowColor = tint.shadow(0.4).cgColor
    applyShadowVisibility()
    refresh()
  }

  private func installGlowIfNeeded() {
    guard glowClip == nil else { return }
    let clip = UIView()
    clip.translatesAutoresizingMaskIntoConstraints = false
    clip.isUserInteractionEnabled = false
    clip.backgroundColor = .clear
    clip.clipsToBounds = true
    let glow = CoverGlowView(recipe: .page)
    glow.translatesAutoresizingMaskIntoConstraints = false
    clip.addSubview(glow)
    // Backmost: behind the photo, the cover and the text.
    insertSubview(clip, at: 0)
    let overscroll: CGFloat = 300
    NSLayoutConstraint.activate([
      clip.topAnchor.constraint(equalTo: topAnchor, constant: -overscroll),
      clip.bottomAnchor.constraint(equalTo: bottomAnchor),
      clip.leadingAnchor.constraint(equalTo: leadingAnchor),
      clip.trailingAnchor.constraint(equalTo: trailingAnchor),
      glow.topAnchor.constraint(equalTo: topAnchor),
      glow.bottomAnchor.constraint(equalTo: bottomAnchor),
      glow.leadingAnchor.constraint(equalTo: leadingAnchor),
      glow.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
    glowClip = clip
    glowView = glow
  }

  /// The mock's `.heroCover` pair: 0 30 60 in the tint mixed 40% into black, and 0 8 18
  /// black at 50%. Both sit behind entityImage at its size, inside artworkWrap (which spans
  /// the full width in compact layout, so the shadow can never go on artworkWrap itself).
  private func installShadowsIfNeeded() {
    guard tintShadow == nil else { return }
    let outline: (CGRect) -> UIBezierPath = { [weak self] bounds in
      guard let self else { return UIBezierPath(rect: bounds) }
      if case .circle = entityImage.shape {
        return UIBezierPath(ovalIn: bounds)
      }
      // The radius actually drawn (an album's 3pt, else 5pt).
      return UIBezierPath(roundedRect: bounds, cornerRadius: entityImage.layer.cornerRadius)
    }
    let tinted = DetailCoverShadowView()
    // Half strength (founder, 2026-10-21): at full strength a saturated cover's halo read as
    // a second, brighter glow on top of the page's. Now Playing has none; this keeps a hint.
    tinted.layer.shadowOpacity = 0.5
    tinted.layer.shadowRadius = 30
    tinted.layer.shadowOffset = CGSize(width: 0, height: 30)
    let depth = DetailCoverShadowView()
    depth.layer.shadowColor = UIColor.black.cgColor
    depth.layer.shadowOpacity = 0.5
    depth.layer.shadowRadius = 9
    depth.layer.shadowOffset = CGSize(width: 0, height: 8)
    for host in [tinted, depth] {
      host.outline = outline
      host.backgroundColor = .clear
      host.isUserInteractionEnabled = false
      host.translatesAutoresizingMaskIntoConstraints = false
      artworkWrap.insertSubview(host, belowSubview: entityImage)
      NSLayoutConstraint.activate([
        host.topAnchor.constraint(equalTo: entityImage.topAnchor),
        host.bottomAnchor.constraint(equalTo: entityImage.bottomAnchor),
        host.leadingAnchor.constraint(equalTo: entityImage.leadingAnchor),
        host.trailingAnchor.constraint(equalTo: entityImage.trailingAnchor),
      ])
    }
    tintShadow = tinted
    depthShadow = depth
  }

  /// The cover shadows show under a visible cover only.
  private func applyShadowVisibility() {
    let hidden = entityImage.isHidden || artworkWrap.isHidden
    tintShadow?.isHidden = hidden
    depthShadow?.isHidden = hidden
    tintShadow?.setNeedsLayout()
    depthShadow?.setNeedsLayout()
  }

  // MARK: Artist hero

  /// The artist's newest credited records (newest first), for the fan when the artist has
  /// no photo of their own. Rebuilds the fan when the set changed.
  func setArtistFan(albums: [Album]) {
    guard config?.heroStyle == .artistHero else { return }
    let shown = Array(albums.prefix(3))
    guard shown.map(\.id) != fanAlbums.map(\.id) || fanView.albumIDs != shown.map(\.id)
    else { return }
    fanAlbums = shown
    let theme = appDelegate.storage.settings.accounts
      .getSetting(config?.entityContainer.account?.info).read.themePreference
    fanView.show(albums: shown, theme: theme)
    applyLayout()
    refresh()
  }

  /// Shows the artist's own photo full bleed when it is on the phone (the one test every
  /// surface uses, `Artist.hasOwnPhotoOnDisk`; a shared artwork row can carry someone
  /// else's face). Call again when an artwork download finishes: a photo that lands
  /// replaces the fan.
  ///
  /// The layout is chosen here, synchronously, from the file: the header measures in the
  /// photo's geometry from its first pass instead of opening as the fan and re-laying out
  /// when the decode lands. The picture comes from the cache at once on a second open, and
  /// otherwise fades in when it is decoded off the main thread.
  func refreshArtistPhoto() {
    guard config?.heroStyle == .artistHero, let artist = config?.entityContainer as? Artist
    else { return }
    guard artist.hasOwnPhotoOnDisk, let path = artist.artwork?.imagePath else {
      clearArtistPhoto()
      return
    }
    let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
      as? Date
    let key = "\(path)|\(modified?.timeIntervalSince1970 ?? 0)"
    guard key != artistPhotoKey else { return }
    guard key != unreadableArtistPhotoKey else {
      clearArtistPhoto()
      return
    }
    artistPhotoKey = key
    installArtistPhotoIfNeeded()
    let cached = Self.artistPhotoCache.object(forKey: key as NSString)
    artistPhotoView?.show(cached, fading: false)
    if !hasArtistPhoto {
      hasArtistPhoto = true
      applyLayout()
      refresh()
    }
    guard cached == nil else { return }
    // About 3x the width of a phone, decoded off the main thread.
    let maxPixel = Int((max(bounds.width, 430) * 3).rounded())
    Task { @MainActor [weak self] in
      let decoded = await Task.detached(priority: .userInitiated) {
        AmbientSourceDecoder.thumbnail(contentsOfFile: path, maxPixelSize: maxPixel)
      }.value
      guard let self, artistPhotoKey == key else { return }
      guard let decoded else {
        // Unreadable: back to the fan (or the circle), and not tried again for this file.
        unreadableArtistPhotoKey = key
        clearArtistPhoto()
        return
      }
      Self.artistPhotoCache.setObject(decoded, forKey: key as NSString)
      artistPhotoView?.show(decoded, fading: true)
    }
  }

  /// Back to the fan (or the circle): no photo on the phone, or one that would not decode.
  private func clearArtistPhoto() {
    guard hasArtistPhoto || artistPhotoKey != nil else { return }
    artistPhotoKey = nil
    hasArtistPhoto = false
    artistPhotoView?.show(nil, fading: false)
    applyLayout()
    refresh()
  }

  private func installArtistPhotoIfNeeded() {
    guard artistPhotoView == nil else { return }
    let photo = DetailArtistPhotoView()
    photo.translatesAutoresizingMaskIntoConstraints = false
    // Above the glow, below the name.
    if let glowClip {
      insertSubview(photo, aboveSubview: glowClip)
    } else {
      insertSubview(photo, at: 0)
    }
    NSLayoutConstraint.activate([
      photo.topAnchor.constraint(equalTo: topAnchor),
      photo.leadingAnchor.constraint(equalTo: leadingAnchor),
      photo.trailingAnchor.constraint(equalTo: trailingAnchor),
      photo.heightAnchor.constraint(equalToConstant: ArtistHero.photoHeight),
    ])
    artistPhotoView = photo
  }

  func startEditing() {
    isEditing = true
    refresh()
  }

  func endEditing() {
    isEditing = false
    defer { refresh() }
    guard let nameText = nameTextField.text, let playlist = config?.entityContainer as? Playlist,
          nameText != playlist.name, let account = playlist.account else { return }
    playlist.name = nameText
    titleLabel.text = nameText
    guard appDelegate.storage.settings.user.isOnlineMode else { return }

    Task { @MainActor in do {
      try await self.appDelegate.getMeta(account.info).librarySyncer
        .syncUpload(playlistToUpdateName: playlist)
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlist Update Name", error: error)
    }}
  }

  @objc
  private func subtitleButtonPressed() {
    guard let album = config?.entityContainer as? Album,
          answerLine == nil,
          let artist = album.artist,
          let account = album.account,
          let navController = config?.rootView.navigationController
    else { return }
    appDelegate.userStatistics.usedAction(.alertGoToAlbum)
    navController.pushViewController(
      AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist),
      animated: true
    )
  }
}
