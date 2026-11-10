//
//  ResumeCardCell.swift
//  Amperfy
//
//  cassette redesign (Surface 4): full-width "Resume" card that leads the
//  Home screen. Sourced from the lastPlayedDate FRCs via HomeManager (live
//  queue first, then most recently played).
//
//  phone-taste (approved phone mock, 2026-10-20): the card is lit by its own record.
//  No glass: a bg3 card with a hairline, the record's glow behind the content (the same
//  tiny pre-blurred cover Now Playing uses, CoverGlowView `.resumeCard`, never blurred at
//  render time), the artwork's shadow and the RESUME kicker in the record's colour
//  (CoverTint), a song on line 2, and the 52pt cream play disc. The mock's `.resume`,
//  `.resumeText` and `.bigPlay`.
//

import AmperfyKit
import UIKit

// MARK: - ResumeCardCell

final class ResumeCardCell: BasicCollectionCell {
  /// The mock's `.resume`: 76pt artwork plus 12pt of padding above and below.
  static let cardHeight: CGFloat = artworkSide + 2 * contentPadding
  private static let artworkSide: CGFloat = 76
  private static let playDiameter: CGFloat = 52
  /// The mock's `.resume` padding and gap.
  private static let contentPadding: CGFloat = 12
  private static let contentGap: CGFloat = 14
  private static let artworkCorner: CornerRadius = .small

  var onPlayTapped: (() -> ())?

  /// The card itself: bg3 at the lit-card radius, clipped so the glow and the artwork's
  /// shadow stay inside it. Its hairline is set in `display` (it needs the display scale).
  private let cardView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = UIColor.cassette(.surfaceElevated)
    view.layer.cornerRadius = CassetteRadius.litCard
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
    return view
  }()

  /// The record's glow and its warm scrim, the card's backmost layer.
  private let glowView: CoverGlowView = {
    let view = CoverGlowView(recipe: .resumeCard)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// Carries the artwork's tinted drop shadow (the artwork view clips its own corners, so
  /// it cannot cast one itself).
  private let artworkShadowHost: ResumeArtworkShadowView = {
    let view = ResumeArtworkShadowView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.artworkRadius = ResumeCardCell.artworkCorner.asCGFloat
    return view
  }()

  // cassette Patch 104: the broken artwork crop came from
  // `EntityImageView(frame: .zero)` - the view loads its nib content with
  // autoresizing masks scaled from the init frame, so a zero frame laid the
  // inner image out as garbage. Seed it with the real artwork square (the
  // constraints below keep it at that size).
  private let artworkView: EntityImageView = {
    let view = EntityImageView(
      frame: CGRect(
        x: 0,
        y: 0,
        width: ResumeCardCell.artworkSide,
        height: ResumeCardCell.artworkSide
      )
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let kickerLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 1
    return label
  }()

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  /// Line 2: a song (see HomeVC.resumeLine), DM Mono at the 13pt floor, ink2.
  private let lineLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.cassette(.cardSubtitle)
    label.textColor = UIColor.cassette(.textSecondary)
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  private lazy var textStack: UIStackView = {
    let stack = UIStackView(arrangedSubviews: [kickerLabel, titleLabel, lineLabel])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 4
    return stack
  }()

  // The cream disc shared with the detail header, at the mock's 52pt with a ~22pt glyph,
  // nudged right for optical centring (the mock's padding-left 3px).
  private lazy var playButton: UIButton = {
    let button = LibraryElementDetailTableHeaderView.makeDetailPlayCTA(
      diameter: Self.playDiameter,
      glyphScale: 0.43
    )
    button.configuration?.contentInsets = NSDirectionalEdgeInsets(
      top: 0,
      leading: 3,
      bottom: 0,
      trailing: 0
    )
    button.addAction(UIAction { [weak self] _ in self?.onPlayTapped?() }, for: .touchUpInside)
    return button
  }()

  // cassette: "Checking for updates" state. On a pull-to-refresh the card swaps its
  // resume content for this centered spinner + label at the SAME height, instead of
  // a pull spinner that opens and closes a gap at the top - the Home never changes
  // height. See HomeVC.setCheckingForUpdates.
  private let checkingSpinner: UIActivityIndicatorView = {
    let view = UIActivityIndicatorView(style: .medium)
    view.color = UIColor.cassette(.textSecondary)
    view.hidesWhenStopped = false
    return view
  }()

  private let checkingLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.cassette(.metadata)
    label.textColor = UIColor.cassette(.textSecondary)
    label.text = "Checking for updates"
    return label
  }()

  private lazy var checkingStack: UIStackView = {
    let stack = UIStackView(arrangedSubviews: [checkingSpinner, checkingLabel])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.spacing = 10
    stack.alignment = .center
    stack.isHidden = true
    return stack
  }()

  /// The record whose artwork is up (HomeManager's stable id).
  private var displayedContainerID: String?
  /// Which record's light the card shows (a cover path, a playlist's cover, or none).
  /// HomeVC redraws the card on every apply, so an unchanged key skips the work.
  private var coverKey: String?
  /// Replaced on every new record and on reuse: a tint read for an earlier record is
  /// dropped when it lands (the PopupPlayer staleness guard).
  private var tintToken = UUID()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupSubviews()
    observeCoverLanding()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupSubviews()
    observeCoverLanding()
  }

  /// The playlist the card shows and its artwork setting, so a picked cover that lands
  /// after the card lit from the preset lights it again at once (BUG-461), rather than at
  /// Home's next redraw.
  private var shownPlaylist: (playlist: Playlist, preference: ArtworkDisplayPreference)?

  private func observeCoverLanding() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(playlistCoverLanded(_:)),
      name: CassetteCloudPlaylistBridge.coverDidLand,
      object: nil
    )
  }

  @objc
  private func playlistCoverLanded(_ notification: Notification) {
    guard let shown = shownPlaylist, notification.object as? String == shown.playlist.id
    else { return }
    light(from: Self.coverSource(of: shown.playlist, artworkPreference: shown.preference))
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onPlayTapped = nil
    setChecking(false)
    displayedContainerID = nil
    shownPlaylist = nil
    coverKey = nil
    tintToken = UUID()
    glowView.clear()
    applyTint(.neutral)
  }

  /// Swap between the resume content and the "Checking for updates" state, in
  /// place, at the same card height. The caller (HomeVC) turns it on for the
  /// duration of a pull-to-refresh and off when the refresh settles.
  func setChecking(_ checking: Bool) {
    checkingStack.isHidden = !checking
    if checking { checkingSpinner.startAnimating() } else { checkingSpinner.stopAnimating() }
    artworkView.isHidden = checking
    artworkShadowHost.isHidden = checking
    textStack.isHidden = checking
    playButton.isHidden = checking
    isUserInteractionEnabled = !checking
  }

  private func setupSubviews() {
    contentView.backgroundColor = .clear
    contentView.addSubview(cardView)
    cardView.addSubview(glowView)
    cardView.addSubview(artworkShadowHost)
    cardView.addSubview(artworkView)
    cardView.addSubview(textStack)
    cardView.addSubview(playButton)
    cardView.addSubview(checkingStack)

    let pad = Self.contentPadding
    let gap = Self.contentGap
    NSLayoutConstraint.activate([
      cardView.topAnchor.constraint(equalTo: contentView.topAnchor),
      cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

      glowView.topAnchor.constraint(equalTo: cardView.topAnchor),
      glowView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
      glowView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
      glowView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),

      checkingStack.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
      checkingStack.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),

      artworkView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: pad),
      artworkView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
      artworkView.widthAnchor.constraint(equalToConstant: Self.artworkSide),
      artworkView.heightAnchor.constraint(equalToConstant: Self.artworkSide),

      artworkShadowHost.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor),
      artworkShadowHost.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
      artworkShadowHost.topAnchor.constraint(equalTo: artworkView.topAnchor),
      artworkShadowHost.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor),

      playButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -pad),
      playButton.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
      playButton.widthAnchor.constraint(equalToConstant: Self.playDiameter),
      playButton.heightAnchor.constraint(equalToConstant: Self.playDiameter),

      textStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: gap),
      textStack.trailingAnchor.constraint(
        lessThanOrEqualTo: playButton.leadingAnchor,
        constant: -gap
      ),
      textStack.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
    ])
    applyTint(.neutral)
  }

  /// `resumeLine` is the card's second line, a song (HomeVC works it out); nil hides it.
  func display(container: PlayableContainable, resumeLine: String?) {
    titleLabel.attributedText = NSAttributedString.cassette(
      container.name,
      .cardTitle,
      color: UIColor.cassette(.textPrimary)
    )
    lineLabel.text = resumeLine
    lineLabel.isHidden = (resumeLine ?? "").isEmpty
    let setting = appDelegate.storage.settings.accounts.getSetting(container.account?.info).read
    // HomeVC redraws the card on every apply (so line 2 follows the track); the artwork
    // only reloads when the record changes, so it never blinks (a playlist's picked
    // cover would otherwise refetch).
    let containerID = HomeManager.stableID(for: container)
    if containerID != displayedContainerID {
      displayedContainerID = containerID
      artworkView.display(
        theme: setting.themePreference,
        container: container,
        cornerRadius: Self.artworkCorner
      )
    }
    // One device pixel of ink: 6% around the card (the mock's inset hairline), 8% around
    // the artwork (the album cards' highlight).
    let pixel = 1.0 / max(traitCollection.displayScale, 1.0)
    cardView.layer.borderWidth = pixel
    cardView.cassetteOnAppearanceChange {
      $0.layer.borderColor = UIColor.cassette(.textPrimary).withAlphaComponent(0.06).cgColor
    }
    artworkView.layer.borderWidth = pixel
    artworkView.layer.borderColor = UIColor.cassette(.textPrimary)
      .withAlphaComponent(0.08).cgColor
    accessibilityLabel = ["Resume \(container.name)", resumeLine]
      .compactMap { $0 }
      .joined(separator: ", ")
    shownPlaylist = (container as? Playlist).map { ($0, setting.artworkDisplayPreference) }
    light(from: Self.coverSource(
      of: container,
      artworkPreference: setting.artworkDisplayPreference
    ))
  }

  // MARK: - The record's light

  private enum CoverSource {
    /// A cover file on disk (an album's cover, or an artist's own photo).
    case file(String)
    /// A playlist's own cover: the person's pick, else its preset (never album art).
    case playlist(id: String, key: String)
    case none

    var key: String {
      switch self {
      // The foundation's cover key (the path plus the file's date): a cover replaced at the
      // same path lights the card again, in the colour every other surface reads.
      case let .file(path): return CoverTint.cacheKey(forCoverPath: path)
      case let .playlist(_, key): return key
      case .none: return "none"
      }
    }
  }

  private static func coverSource(
    of container: PlayableContainable,
    artworkPreference: ArtworkDisplayPreference
  )
    -> CoverSource {
    if let playlist = container as? Playlist {
      guard !playlist.id.isEmpty else { return .none }
      let pick = CassetteCloudPlaylistBridge.storedCoverUrl(for: playlist.id) ?? "preset"
      // A pick not downloaded yet lights from the preset under its own key, so the pick's
      // colour is read fresh (not the preset's, cached) once it lands.
      let state = CassetteCloudPlaylistBridge.hasLocalCover(for: playlist.id) ? "own" : "pending"
      return .playlist(id: playlist.id, key: "playlist-cover:\(playlist.id):\(pick):\(state)")
    }
    let entity: AbstractLibraryEntity?
    if let artist = container as? Artist {
      // Only the artist's OWN photo: a shared artwork row can carry someone else's face.
      entity = artist.hasOwnPhotoOnDisk ? artist : nil
    } else {
      entity = container as? Album
    }
    guard let path = entity?.imagePath(setting: artworkPreference),
          FileManager.default.fileExists(atPath: path)
    else { return .none }
    return .file(path)
  }

  /// Light the card from `source`: the neutral tint at once, then the record's own glow
  /// and tint as they are read off the main thread. Nothing changes when the card already
  /// shows this record.
  private func light(from source: CoverSource) {
    guard source.key != coverKey else { return }
    coverKey = source.key
    let token = UUID()
    tintToken = token
    applyTint(.neutral)
    switch source {
    case let .file(path):
      glowView.show(coverPath: path)
      if let hit = CoverTint.cached(coverPath: path) {
        applyTint(hit)
        return
      }
      Task { @MainActor [weak self] in
        guard let tint = await CoverTint.resolve(coverPath: path) else { return }
        guard let self, tintToken == token else { return }
        applyTint(tint)
      }
    case let .playlist(id, key):
      Task { @MainActor [weak self] in
        let image = await Task.detached(priority: .utility) {
          CassetteCloudPlaylistBridge.displayCoverImage(for: id)
        }.value
        guard let self, tintToken == token else { return }
        guard let image else {
          glowView.clear()
          return
        }
        glowView.show(image: image, key: key)
        let tint = await CoverTint.resolve(image: image, key: key)
        guard tintToken == token else { return }
        applyTint(tint)
      }
    case .none:
      glowView.clear()
    }
  }

  /// The RESUME kicker (ink mixed 75/25 with the record's colour) and the artwork's
  /// shadow (the record's colour mixed 45% with black).
  private func applyTint(_ tint: CoverTint) {
    kickerLabel.attributedText = NSAttributedString.cassette(
      "Resume",
      .kicker,
      color: tint.kickerInk(inkShare: 0.75)
    )
    artworkShadowHost.shadowTint = tint.shadow(0.45)
  }
}

// MARK: - ResumeArtworkShadowView

/// A clear view the size of the Resume artwork that casts its shadow: the mock's
/// `box-shadow: 0 10px 24px` in the record's colour, with a path so it stays cheap.
private final class ResumeArtworkShadowView: UIView {
  var artworkRadius: CGFloat = 0 {
    didSet { setNeedsLayout() }
  }

  var shadowTint: UIColor = .clear {
    didSet { layer.shadowColor = shadowTint.cgColor }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = false
    layer.shadowOpacity = 1
    layer.shadowRadius = 12
    layer.shadowOffset = CGSize(width: 0, height: 10)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: artworkRadius).cgPath
  }
}
