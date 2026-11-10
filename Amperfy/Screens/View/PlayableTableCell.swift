//
//  SongTableCell.swift
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

typealias GetPlayContextFromTableCellCallback = (UITableViewCell) -> PlayContext?
typealias GetPlayerIndexFromTableCellCallback = (PlayableTableCell) -> PlayerIndex?

// MARK: - DisplayMode

enum DisplayMode {
  case normal
  case selection
  case reorder
  case add
}

// MARK: - PlayableTableCellStyle

enum PlayableTableCellStyle {
  case none
  case trackNumber
  case artwork
}

// MARK: - PlayableCellOptions

/// How one surface wants its song rows drawn, set per bind through
/// `PlayableTableCell.display(..., options:)`. Every field defaults to today's row, so a
/// call site that passes nothing is unchanged.
struct PlayableCellOptions: Equatable {
  /// The track number's colour; nil is `.textTertiary`. Lit pages pass `CoverTint.text`.
  var trackNumberColor: UIColor? = nil
  /// The row's side margins; nil is `UIView.defaultMarginCellX` (16).
  var horizontalMargin: CGFloat? = nil
  /// The row's top and bottom margins; nil is the track-list default (14). The row height
  /// is the host's: 48 + 2 x margin.
  var verticalMargin: CGFloat? = nil
  /// Shown in the subtitle line, always visible; wins over the contextual artist line and
  /// `hideArtistSubtitle`.
  var subtitleOverride: String? = nil
  /// Leaves the trailing duration out.
  var hidesDuration = false
  /// A clear row, for lists drawn over a lit page.
  var clearsBackground = false
  /// A rank in the number slot, beside a smaller (44pt) cover moved past it: the artist
  /// page's MOST PLAYED. The playing waveform replaces the cover, never the rank. nil is
  /// today's row.
  var rank: Int? = nil
  /// The rank's colour; nil is `.textTertiary`. Lit pages pass `CoverTint.text`.
  var rankColor: UIColor? = nil

  static let standard = PlayableCellOptions()
}

// MARK: - PlayableTableCell

@MainActor
class PlayableTableCell: BasicTableCell {
  @IBOutlet
  weak var titleLabel: UILabel!
  @IBOutlet
  weak var artistLabel: UILabel!
  @IBOutlet
  weak var durationLabel: UILabel!
  @IBOutlet
  weak var entityImage: EntityImageView!
  @IBOutlet
  weak var trackNumberLabel: UILabel!
  @IBOutlet
  weak var downloadProgress: UIProgressView! // depricated: replaced with a spinner in the accessoryView
  @IBOutlet
  weak private var cacheIconImage: UIImageView!
  @IBOutlet
  weak private var favoriteIconImage: UIImageView!

  @IBOutlet
  weak var titleContainerLeadingConstraint: NSLayoutConstraint!
  @IBOutlet
  weak var labelTrailingCellConstraint: NSLayoutConstraint!
  @IBOutlet
  weak var cacheTrailingCellConstaint: NSLayoutConstraint!
  @IBOutlet
  weak var durationTrailingCellConstraint: NSLayoutConstraint!
  @IBOutlet
  weak var optionsButton: UIButton!
  @IBOutlet
  weak var deleteButton: UIButton!
  @IBOutlet
  weak var playOverArtworkButton: UIButton!
  @IBOutlet
  weak var playOverNumberButton: UIButton!

  /// cassette Patch 028: animated bars shown in the leading column when this
  /// row is currently playing. Replaces both the muddy
  /// `orange.withAlphaComponent(0.04)` row-fill (Patch 019) and the legacy
  /// small VYPlayIndicator overlay (deleted in Patch 054) so there is a
  /// single, clear "this is the active row" signal. Since 2026-10-21 the
  /// bars, like the mini and popup scrubbers, are the playing record's
  /// colour (`CoverTint.nowPlaying`), no longer brand orange.
  private lazy var playingSymbolView: WaveformAnimatedView = {
    let view = WaveformAnimatedView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    return view
  }()

  /// cassette now-playing legibility: on the currently-playing row of an
  /// artwork-style list (e.g. artist popular songs) the orange waveform can
  /// wash out over a bright cover. This darkens just that row's thumbnail
  /// toward the warm near-black (`bg4`, not pure #000) with a light blur,
  /// fading in/out with the indicator so the waveform always reads. Artwork
  /// style only — the track-number style draws the indicator on a plain
  /// background and needs no scrim.
  private lazy var playingArtworkScrim: UIVisualEffectView = {
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    view.translatesAutoresizingMaskIntoConstraints = false
    view.contentView.backgroundColor = CassetteTheme.UIColors.bg4.withAlphaComponent(0.55)
    view.isUserInteractionEnabled = false
    view.clipsToBounds = true
    view.layer.cornerRadius = CornerRadius.small.asCGFloat
    view.isHidden = true
    view.alpha = 0
    return view
  }()

  private var didInstallArtworkScrim = false
  private var didInstallPlayingSymbol = false
  private var isPlayingSymbolNotificationRegistered = false

  /// cassette Patch 104: the per-row download badge is disabled for now —
  /// it rendered as a non-interactive marker and showed on on-device
  /// tracks. The scaffolding below (downloadButton, downloadPressed intent
  /// path, cached/owned state, trailing-slot constraint math) is preserved
  /// for the planned v2 streaming-gated download button: off-device +
  /// streaming on -> tap-to-play caches; the download button requests
  /// permanent-local via the dashboard.
  static let isDownloadButtonEnabled = false

  /// cassette redesign (Surface 2): trailing download affordance, shown only
  /// on off-device tracks. Replaces the old cached-check icon — on-device
  /// rows stay quiet (no marker at all). Native UIButton.Configuration with
  /// a 44pt hit target via insets.
  private lazy var downloadButton: UIButton = {
    var config = UIButton.Configuration.cassetteBare()
    config.image = UIImage(systemName: "arrow.down.circle")
    config.baseForegroundColor = CassetteTheme.UIColors.ink2
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 15,
      weight: .regular
    )
    config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    let button = UIButton(configuration: config)
    button.accessibilityLabel = "Download"
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isHidden = true
    button.addAction(UIAction { [weak self] _ in self?.downloadPressed() }, for: .touchUpInside)
    return button
  }()

  private var didInstallDownloadButton = false

  private func installDownloadButtonIfNeeded() {
    guard !didInstallDownloadButton else { return }
    didInstallDownloadButton = true
    contentView.addSubview(downloadButton)
    NSLayoutConstraint.activate([
      downloadButton.centerXAnchor.constraint(equalTo: cacheIconImage.centerXAnchor),
      downloadButton.centerYAnchor.constraint(equalTo: cacheIconImage.centerYAnchor),
    ])
  }

  private func downloadPressed() {
    guard let playable, !playable.isCached,
          let accountInfo = playable.account?.info else { return }
    Haptics.light.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    appDelegate.getMeta(accountInfo).playableDownloadManager.download(objects: [playable])
    downloadButton.isHidden = true
  }

  // Extra vertical room for track lists. Height and layoutMargins must agree —
  // bumping only rowHeight left 9pt BasicTableCell margins and dead air under
  // the content, so rows still felt tight/uneven.
  private static let trackListMarginY: CGFloat = 14
  static let rowHeight: CGFloat = 48 + trackListMarginY + trackListMarginY
  private static let touchAnimation = 0.4

  override var layoutMargins: UIEdgeInsets {
    get { margins(for: options) }
    set {}
  }

  private func margins(for options: PlayableCellOptions) -> UIEdgeInsets {
    let x = options.horizontalMargin ?? UIView.defaultMarginCellX
    let y = options.verticalMargin ?? Self.trackListMarginY
    return UIEdgeInsets(top: y, left: x, bottom: y, right: x)
  }

  /// The surface's row options (see `PlayableCellOptions`). Set through `display(...)`;
  /// reset to `.standard` on reuse.
  private var options = PlayableCellOptions.standard {
    didSet {
      guard margins(for: options) != margins(for: oldValue) else { return }
      // The getter above is what the row lays out with; pushing the value through
      // UIView's setter tells UIKit the margins moved so the content view re-lays.
      super.layoutMargins = margins(for: options)
      setNeedsLayout()
      contentView.setNeedsLayout()
    }
  }

  // MARK: Rank rows (phone-taste MOST PLAYED)

  /// The rank's 18pt box (the xib's track-number width), the gap after it, and the cover.
  private static let rankBoxWidth: CGFloat = 18
  private static let rankGap: CGFloat = 12
  private static let rankArtworkSide: CGFloat = 44
  /// The xib's artwork width (PdF-S9-lw7) and the favourite slot it is pinned after
  /// (Coh-TC-C5u, Eo4-gu-hwz).
  private static let standardArtworkSide: CGFloat = 48
  private static let favoriteSlotWidth: CGFloat = 16
  private var isRankLayoutApplied = false

  /// The artwork's leading constraint (xib Coh-TC-C5u: artwork.leading == favourite
  /// slot.trailing). The xib gives it no outlet, so it is found once at runtime.
  private lazy var artworkLeadingConstraint: NSLayoutConstraint? = contentView.constraints.first {
    ($0.firstItem as? UIView) === entityImage && $0.firstAttribute == .leading
  }

  /// The artwork's 48pt width (xib PdF-S9-lw7), found once at runtime.
  private lazy var artworkWidthConstraint: NSLayoutConstraint? = entityImage.constraints.first {
    ($0.firstItem as? UIView) === entityImage && $0.firstAttribute == .width && $0.secondItem == nil
  }

  private var style = PlayableTableCellStyle.none
  private var playerIndexCb: GetPlayerIndexFromTableCellCallback?
  private var playContextCb: GetPlayContextFromTableCellCallback?
  /// cassette (keep playing): what a tap does instead of playing a context or a queue
  /// index, for rows that are not in the queue yet (the queue's THEN songs).
  var cassetteTapAction: (() -> ())?
  private var playable: AbstractPlayable?
  private var download: Download?
  /// Weak: a cell lives in its page, so a strong page here kept it in memory (BUG-447).
  private weak var rootView: UIViewController?
  private var isDislayAlbumTrackNumberStyle: Bool = false
  private var hideArtistSubtitle = false
  /// Album/artist page primary — when set, subtitle is feat-aware vs this name.
  private var contextArtistName: String?
  private var displayMode: DisplayMode = .normal
  // Cassette fork — Layer 3 Phase 3.2 (library filtering). Detail views show
  // every track but dim the ones not on this phone. nil = not in a filtered
  // detail context (no dimming, the default for all existing call sites).
  private var cassetteIsOwned: Bool?
  #if targetEnvironment(macCatalyst) // ok
    private var hoverGestureRecognizer: UIHoverGestureRecognizer!
    private var doubleTapGestureRecognizer: UITapGestureRecognizer!
    private var isHovered = false
    private var isNotificationRegistered = false
  #else
    private var singleTapGestureRecognizer: UITapGestureRecognizer!
  #endif

  public var isMarked = false
  private var isDeleteButtonAllowedToBeVisible: Bool {
    (traitCollection.userInterfaceIdiom == .mac) && (playerIndexCb != nil)
  }

  override func awakeFromNib() {
    super.awakeFromNib()
    // This must be called in Main thread
    MainActor.assumeIsolated {
      playContextCb = nil
      #if targetEnvironment(macCatalyst) // ok
        hoverGestureRecognizer = UIHoverGestureRecognizer(
          target: self,
          action: #selector(hovering(_:))
        )
        self.addGestureRecognizer(hoverGestureRecognizer)
        isHovered = false
        doubleTapGestureRecognizer = UITapGestureRecognizer(
          target: self,
          action: #selector(doubleTap)
        )
        doubleTapGestureRecognizer.numberOfTapsRequired = 2
        self.addGestureRecognizer(doubleTapGestureRecognizer)
      #else
        singleTapGestureRecognizer = UITapGestureRecognizer(
          target: self,
          action: #selector(singleTap)
        )
        singleTapGestureRecognizer.numberOfTapsRequired = 1
        // to handle double and single tap recognizer in parallel:
        // singleTapGestureRecognizer.require(toFail: doubleTapGestureRecognizer)
        self.addGestureRecognizer(singleTapGestureRecognizer)
      #endif
      // Long-press overflow (web parity: duration stands in the trailing slot).
      addInteraction(UIContextMenuInteraction(delegate: self))

      style = PlayableTableCellStyle.none
      registerPlayingSymbolNotificationsIfNeeded()
      deleteButton.tintColor = .red
      playOverArtworkButton.layer.backgroundColor = UIColor.imageOverlayBackground.cgColor
      playOverArtworkButton.layer.cornerRadius = CornerRadius.small.asCGFloat
      selectionStyle = .none
      downloadProgress.isHidden = true
      // cassette Patch 032: route through the canonical scale.
      // Title is rowTitle (16pt semibold display); artist/duration/track
      // number all collapse onto metadata (12pt medium mono).
      // cassette (BUG-417): the fonts live in applyCassetteType() so they can
      // be re-stamped whenever UIKit re-applies the XIB's size-class
      // variations (a context-menu preview does); colours stay here because
      // applyCassetteOwnershipDimming() owns them after bind.
      applyCassetteType()
      titleLabel.textColor = UIColor.cassette(.textPrimary)
      artistLabel.textColor = UIColor.cassette(.textSecondary)
      durationLabel.textColor = UIColor.cassette(.textSecondary)
      trackNumberLabel.textColor = UIColor.cassette(.textTertiary)
      contentView.backgroundColor = UIColor.cassette(.surfaceBase)
      backgroundColor = UIColor.cassette(.surfaceBase)
      resetForReuse()
    }
  }

  // cassette Patch 054 (Phase I): rating stars removed from list rows.
  // `setupRatingStars`, `updateRatingDisplay`, `ratingStackView`, and
  // `ratingStarViews` deleted; row geometry is now driven entirely by
  // title + artist + duration + favorite icon. The rating data model
  // is preserved (`SongMO.rating` and the `isShowRating` user setting
  // still exist; the EntityPreviewVC context-menu rating action
  // remains the read/write surface for now).

  func resetForReuse() {
    hidePlayingSymbol()
    // Snap the scrim off instantly on reuse (the fade in hidePlayingSymbol is
    // for the live track-change case, not a recycled cell about to re-bind).
    if didInstallArtworkScrim {
      playingArtworkScrim.layer.removeAllAnimations()
      playingArtworkScrim.alpha = 0
      playingArtworkScrim.isHidden = true
    }
    deleteButton.isHidden = true
    playOverArtworkButton.isHidden = true
    playOverNumberButton.isHidden = true
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    cassetteTapAction = nil
    playingSymbolView.stopAnimating()
    resetForReuse()
    // Back to today's row: margins, track-number ink and the page background.
    options = .standard
    trackNumberLabel.textColor = UIColor.cassette(.textTertiary)
    applyBackground()
    // And today's geometry, so another list never inherits a rank row's layout.
    restoreStandardLayoutIfNeeded()
  }

  #if targetEnvironment(macCatalyst) // ok
    private func register() {
      guard !isNotificationRegistered else { return }
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(playerPlay(notification:)),
        name: .playerPlay,
        object: nil
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(playerPause(notification:)),
        name: .playerPause,
        object: nil
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(playerStop(notification:)),
        name: .playerStop,
        object: nil
      )
      isNotificationRegistered = true
    }
  #endif

  func display(
    playable: AbstractPlayable,
    displayMode: DisplayMode = .normal,
    playContextCb: GetPlayContextFromTableCellCallback?,
    rootView: UIViewController,
    playerIndexCb: GetPlayerIndexFromTableCellCallback? = nil,
    isDislayAlbumTrackNumberStyle: Bool = false,
    hideArtistSubtitle: Bool = false,
    contextArtistName: String? = nil,
    download: Download? = nil,
    isMarked: Bool = false,
    cassetteIsOwned: Bool? = nil,
    options: PlayableCellOptions = .standard
  ) {
    self.options = options
    self.playable = playable
    self.displayMode = displayMode
    self.playContextCb = playContextCb
    self.playerIndexCb = playerIndexCb
    self.rootView = rootView
    self.isDislayAlbumTrackNumberStyle = isDislayAlbumTrackNumberStyle
    self.hideArtistSubtitle = hideArtistSubtitle
    self.contextArtistName = contextArtistName
    self.download = download
    self.isMarked = isMarked
    self.cassetteIsOwned = cassetteIsOwned

    #if targetEnvironment(macCatalyst) // ok
      hoverGestureRecognizer.isEnabled = (displayMode == .normal)
      isHovered = false
      doubleTapGestureRecognizer.isEnabled = (displayMode == .normal)
      register()
    #else
      singleTapGestureRecognizer.isEnabled = (displayMode == .normal)
    #endif
    applyBackground()
    refresh()
  }

  /// The row's own background: the page, or clear over a lit page.
  private func applyBackground() {
    let background = options.clearsBackground ? UIColor.clear : UIColor.cassette(.surfaceBase)
    backgroundColor = background
    contentView.backgroundColor = background
  }

  /// Recolour the track number (or the rank) in place, e.g. when a page's cover tint
  /// arrives after the rows were bound. nil restores `.textTertiary`.
  func setTrackNumberColor(_ color: UIColor?) {
    options.trackNumberColor = color
    if options.rank != nil {
      options.rankColor = color
    }
    trackNumberLabel.textColor = color ?? UIColor.cassette(.textTertiary)
  }

  /// A rank row: the rank in the number slot (18pt box at the margin), the cover 12pt past
  /// it at 44pt, the title 12pt past the cover. Runs after `configureStyle`, which hides
  /// the number in the artwork style. Without a rank it puts today's geometry back.
  private func applyRankLayout() {
    guard let rank = options.rank else {
      restoreStandardLayoutIfNeeded()
      return
    }
    isRankLayoutApplied = true
    trackNumberLabel.text = "\(rank)"
    trackNumberLabel.isHidden = false
    trackNumberLabel.textColor = options.rankColor ?? UIColor.cassette(.textTertiary)
    let artworkX = Self.rankBoxWidth + Self.rankGap
    artworkLeadingConstraint?.constant = artworkX - Self.favoriteSlotWidth
    artworkWidthConstraint?.constant = Self.rankArtworkSide
    // titleContainerLeadingConstraint is measured from leftMargin and the title's inner
    // stack adds 4pt before the text.
    titleContainerLeadingConstraint.constant = artworkX + Self.rankArtworkSide + Self.rankGap - 4
  }

  /// Undo `applyRankLayout`: the artwork back after the favourite slot at 48pt, and the
  /// style re-applied on the next bind (which also resets the title's inset).
  private func restoreStandardLayoutIfNeeded() {
    guard isRankLayoutApplied else { return }
    isRankLayoutApplied = false
    artworkLeadingConstraint?.constant = 0
    artworkWidthConstraint?.constant = Self.standardArtworkSide
    style = .none
    if let playable {
      configureStyle(
        playable: playable,
        newStyle: isDislayAlbumTrackNumberStyle ? .trackNumber : .artwork
      )
    }
  }

  private func configureStyle(playable: AbstractPlayable, newStyle: PlayableTableCellStyle) {
    // adjust style only if it has changed
    guard newStyle != style else { return }

    switch newStyle {
    case .trackNumber:
      configureTrackNumberLabel()
      trackNumberLabel.isHidden = false
      entityImage.isHidden = true
      // cassette polish: the track number now starts at the cell's STANDARD
      // content margin (its leading is pinned to contentView.leftMargin in the
      // xib — no heart-slot gutter ahead of it). It's a tight 18pt box,
      // right-aligned within itself, so 9/10/11 stay column-aligned. The title
      // sits 10pt past the box's right edge. titleContainerLeadingConstraint is
      // measured from leftMargin and the title's inner stack adds 4pt before
      // the text, so: 18 (box) + 10 (gap) − 4 (inner inset) = 24.
      titleContainerLeadingConstraint.constant = 18 + 10 - 4
    case .artwork:
      trackNumberLabel.isHidden = true
      entityImage.isHidden = false
      titleContainerLeadingConstraint.constant = 10 + 48 + 8 // heart + artwork width + offset
    case .none:
      break // do nothing
    }
  }

  private func configurePlayIndicator(playable: AbstractPlayable?) {
    // cassette Patch 028 + 054: the "currently playing" row cue is a
    // static `waveform` SF Symbol shown over the artwork (or the track
    // number column when applicable). The legacy VYPlayIndicator-based
    // overlay was removed in Patch 054 along with its
    // willDisplayIndicatorCB / willHideIndicatorCB hooks; the static
    // symbol's visibility is toggled directly via showPlayingSymbol /
    // hidePlayingSymbol below.
    guard let playable = playable else {
      hidePlayingSymbol()
      return
    }

    let isCurrentlyPlaying = appDelegate.player.currentlyPlaying == playable
    guard isCurrentlyPlaying else {
      hidePlayingSymbol()
      return
    }

    if isDislayAlbumTrackNumberStyle {
      showPlayingSymbol(over: trackNumberLabel, replacingTrackNumber: true)
    } else {
      showPlayingSymbol(over: entityImage, replacingTrackNumber: false)
    }
  }

  private func installPlayingSymbolIfNeeded() {
    guard !didInstallPlayingSymbol else { return }
    didInstallPlayingSymbol = true
    contentView.addSubview(playingSymbolView)
    NSLayoutConstraint.activate([
      playingSymbolView.widthAnchor.constraint(equalToConstant: 24),
      playingSymbolView.heightAnchor.constraint(equalToConstant: 24),
    ])
  }

  private var playingSymbolCenterX: NSLayoutConstraint?
  private var playingSymbolCenterY: NSLayoutConstraint?

  private func showPlayingSymbol(over anchor: UIView, replacingTrackNumber: Bool) {
    installPlayingSymbolIfNeeded()
    playingSymbolCenterX?.isActive = false
    playingSymbolCenterY?.isActive = false
    playingSymbolCenterX = playingSymbolView.centerXAnchor
      .constraint(equalTo: anchor.centerXAnchor)
    playingSymbolCenterY = playingSymbolView.centerYAnchor
      .constraint(equalTo: anchor.centerYAnchor)
    playingSymbolCenterX?.isActive = true
    playingSymbolCenterY?.isActive = true
    playingSymbolView.isHidden = false
    updatePlayingSymbolAnimation()
    contentView.bringSubviewToFront(playingSymbolView)
    // cassette Patch 104: the playing indicator REPLACES the track number.
    // This used to be alpha-based, but applyCassetteOwnershipDimming() runs
    // later in refresh() and stomps alpha back to a visible value, drawing
    // the waveform over the number. isHidden is owned by the indicator /
    // style path only, so the dimming pass can't resurrect the label.
    if replacingTrackNumber {
      trackNumberLabel.isHidden = true
    } else {
      // Artwork style: fade the scrim in under the waveform so it stays legible
      // over bright covers.
      showArtworkScrim()
    }
  }

  private func showArtworkScrim() {
    installArtworkScrimIfNeeded()
    contentView.bringSubviewToFront(playingSymbolView)
    guard playingArtworkScrim.isHidden || playingArtworkScrim.alpha < 1 else { return }
    playingArtworkScrim.layer.removeAllAnimations()
    playingArtworkScrim.isHidden = false
    UIView.animate(withDuration: 0.25) { self.playingArtworkScrim.alpha = 1 }
  }

  private func installArtworkScrimIfNeeded() {
    guard !didInstallArtworkScrim, entityImage != nil else { return }
    didInstallArtworkScrim = true
    // Subview of the artwork so it inherits the rounded clip; under the
    // waveform (which lives in contentView and is brought to front).
    entityImage.addSubview(playingArtworkScrim)
    NSLayoutConstraint.activate([
      playingArtworkScrim.topAnchor.constraint(equalTo: entityImage.topAnchor),
      playingArtworkScrim.bottomAnchor.constraint(equalTo: entityImage.bottomAnchor),
      playingArtworkScrim.leadingAnchor.constraint(equalTo: entityImage.leadingAnchor),
      playingArtworkScrim.trailingAnchor.constraint(equalTo: entityImage.trailingAnchor),
    ])
  }

  private func hidePlayingSymbol() {
    if didInstallPlayingSymbol {
      playingSymbolView.stopAnimating()
      playingSymbolView.isHidden = true
    }
    if isDislayAlbumTrackNumberStyle {
      trackNumberLabel.isHidden = false
    }
    if didInstallArtworkScrim, !playingArtworkScrim.isHidden {
      UIView.animate(
        withDuration: 0.25,
        animations: { self.playingArtworkScrim.alpha = 0 },
        completion: { _ in
          if self.playingArtworkScrim.alpha == 0 { self.playingArtworkScrim.isHidden = true }
        }
      )
    }
  }

  private func registerPlayingSymbolNotificationsIfNeeded() {
    guard !isPlayingSymbolNotificationRegistered else { return }
    isPlayingSymbolNotificationRegistered = true
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(playingSymbolPlayerStateChanged),
      name: .playerPlay,
      object: nil
    )
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(playingSymbolPlayerStateChanged),
      name: .playerPause,
      object: nil
    )
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(playingSymbolPlayerStateChanged),
      name: .playerStop,
      object: nil
    )
  }

  @objc
  private func playingSymbolPlayerStateChanged(notification: Notification) {
    // Re-evaluate which row owns the indicator against the LIVE current track,
    // not just the animation. Previously this only restarted/stopped the
    // animation when this row was already the playing one, so on a track change
    // (auto-advance to the next track, or playback started elsewhere) the row
    // that started playback kept its indicator (stale) and the newly-playing
    // row never lit up. configurePlayIndicator shows the symbol only on the row
    // whose track == player.currentlyPlaying and hides it everywhere else;
    // updatePlayingSymbolAnimation (called within) then reflects play/pause.
    configurePlayIndicator(playable: playable)
  }

  private func updatePlayingSymbolAnimation() {
    if appDelegate.player.isPlaying {
      playingSymbolView.startAnimating()
    } else {
      playingSymbolView.stopAnimating()
    }
  }

  func refresh() {
    guard let playable = playable else { return }
    titleLabel.text = playable.title
    // Stamped on every refresh (it used to be set once, in awakeFromNib).
    trackNumberLabel.textColor = options.trackNumberColor ?? UIColor.cassette(.textTertiary)
    if let subtitleOverride = options.subtitleOverride {
      artistLabel.text = subtitleOverride
      artistLabel.isHidden = false
    } else if let context = contextArtistName {
      if let sub = CassetteTrackSubtitle.contextual(
        trackArtist: playable.creatorName,
        contextArtist: context
      ) {
        artistLabel.text = sub
        artistLabel.isHidden = false
      } else {
        artistLabel.isHidden = true
      }
    } else {
      artistLabel.text = playable.creatorName
      artistLabel.isHidden = hideArtistSubtitle
    }

    configureStyle(
      playable: playable,
      newStyle: isDislayAlbumTrackNumberStyle ? .trackNumber : .artwork
    )
    // The number is stamped on every bind: configureStyle only runs on a style change, so
    // a reused album row kept the number of the song it showed before (upstream re-set it
    // from the PlayIndicator callbacks that Patch 054 removed).
    if isDislayAlbumTrackNumberStyle {
      configureTrackNumberLabel()
    }
    applyRankLayout()
    // A station in a list: its own mark, never an empty square (BUG-751). Only the mark: the
    // generic artwork load finishes later and painted its empty placeholder over it.
    if let radio = playable.asRadio {
      entityImage.display(image: RadioMark.image(for: radio, side: 96).image)
    } else {
      entityImage.display(
        theme: appDelegate.storage.settings.accounts.getSetting(playable.account?.info).read
          .themePreference,
        container: playable
      )
    }
    configurePlayIndicator(playable: playable)

    if displayMode == .selection {
      // cassette Patch 051 (Phase F): selection checkmark drops the per-
      // account theme tint (orange / now-ink) for explicit ink (marked) /
      // ink3 (unmarked). Removes the indirection through ThemePreference
      // and makes the contrast intent obvious at the call site.
      let img = UIImageView(image: isMarked ? .checkmark : .circle)
      img.tintColor = isMarked ? UIColor.cassette(.textPrimary) : UIColor.cassette(.textTertiary)
      accessoryView = img
    } else if displayMode == .add {
      // cassette Patch 051 (Phase F): add-mode glyph uses ink (marked) /
      // ink3 (unmarked, the plus). See .selection rationale above.
      let img = UIImageView(image: isMarked ? .checkmark : .plusCircle)
      img.tintColor = isMarked ? UIColor.cassette(.textPrimary) : UIColor.cassette(.textTertiary)
      accessoryView = img
    } else if displayMode == .reorder || playerIndexCb != nil {
      let img = UIImageView(image: .bars)
      // Queue rows: the grip is quieter than the row (phone-taste). Playlist edit mode
      // (.reorder) keeps the full-ink grip.
      img.tintColor = (playerIndexCb != nil && displayMode != .reorder)
        ? UIColor.cassette(.textTertiary)
        : UIColor.cassette(.textPrimary)
      accessoryView = img
    } else if let download = download {
      if download.error != nil {
        let img = UIImageView(image: .exclamation)
        img.tintColor = UIColor.cassette(.textPrimary)
        accessoryView = img
      } else if download.isFinishedSuccessfully {
        let img = UIImageView(image: .check)
        img.tintColor = UIColor.cassette(.textPrimary)
        accessoryView = img
      } else if download.isDownloading {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.tintColor = UIColor.cassette(.textPrimary)
        accessoryView = spinner
      } else {
        accessoryView = nil
      }
    } else {
      accessoryView = nil
    }

    refreshSubtitleColor()
    refreshCacheAndDuration()
    applyCassetteOwnershipDimming()
    // cassette Patch 054 (Phase I): rating stars removed from rows. See
    // resetForReuse for full rationale; the user's `isShowRating`
    // preference no longer controls per-row display (data model intact).
  }

  /// Cassette fork — Layer 3 Phase 3.2 (library filtering). Detail views pass a
  /// non-nil `cassetteIsOwned`; non-owned rows are dimmed (ink alphas only, no
  /// new color tokens) so the user can see the full album/playlist while it's
  /// clear which tracks are actually on the phone. Default mode dims harder
  /// (0.4) than Server Mode (0.6) since non-owned tracks won't play in default
  /// mode. Rows stay tappable — a tap on a non-owned row hits the skip path.
  private func applyCassetteOwnershipDimming() {
    let alpha: CGFloat
    switch cassetteIsOwned {
    case .none, .some(true):
      alpha = 1.0
    case .some(false):
      alpha = CassetteLibraryFilterProvider.shared.currentFilter == .everything ? 0.6 : 0.4
    }
    titleLabel.alpha = alpha
    artistLabel.alpha = alpha
    durationLabel.alpha = alpha
    trackNumberLabel.alpha = alpha
    entityImage.alpha = alpha
  }

  private func configureTrackNumberLabel() {
    guard let playable = playable else { return }
    trackNumberLabel.text = playable.track > 0 ? "\(playable.track)" : ""
  }

  func refreshCacheAndDuration() {
    guard let playable = playable else { return }
    // cassette redesign (Surface 2): rows stay quiet — the per-row favorite
    // heart is gone. Favoriting lives in the row overflow menu and the
    // configurable swipe actions instead.
    favoriteIconImage.isHidden = true

    // Duration always stands in the trailing slot (unless the surface leaves it out);
    // overflow is long-press.
    let isDurationVisible = !playable.isRadio && !options.hidesDuration
    let cacheIconWidth = (traitCollection.horizontalSizeClass == .regular) ? 17.0 : 15.0
    let durationWidth = (
      traitCollection.horizontalSizeClass == .regular &&
        traitCollection.userInterfaceIdiom != .mac
    ) ? 49.0 : 40.0
    // Overflow icon retired - long-press via UIContextMenuInteraction.
    let isDisplayOptionButton = false
    let durationTrailing = 0.0

    // cassette redesign (Surface 2): download affordance only on off-device
    // tracks; on-device rows show nothing in this slot (the old cached-check
    // marker is retired). Patch 104: gated off entirely behind the v2 flag —
    // rows go quiet (number, title, overflow).
    let showsDownloadAffordance = Self.isDownloadButtonEnabled
      && isDisplayOptionButton
      && displayMode == .normal
      && !playable.isCached
      && playable.isDownloadAvailable
      && !playable.isRadio
      && appDelegate.storage.settings.user.isOnlineMode
    installDownloadButtonIfNeeded()
    downloadButton.isHidden = !showsDownloadAffordance

    optionsButton.isHidden = !isDisplayOptionButton
    if isDisplayOptionButton {
      optionsButton.showsMenuAsPrimaryAction = true
      optionsButton.imageView?.tintColor = CassetteTheme.UIColors.ink
      if let rootView = rootView {
        let playContext = playContextCb != nil ? { self.playContextCb?(self) } : nil
        let playIndex = playerIndexCb != nil ? { self.playerIndexCb?(self) } : nil
        optionsButton.menu = UIMenu.lazyMenu {
          EntityPreviewActionBuilder(
            container: playable,
            on: rootView,
            playContextCb: playContext,
            playerIndexCb: playIndex
          ).createMenuActions()
        }
      }
    }

    // macOS & iPadOS regular
    // |title|x|Cache|4|Duration| ... |
    // |title|        80        | 30  |
    // compact
    // |title|4|Cache|4|Duration| ... |
    // |title|4|  15 |4|   40   | 30  |
    // |title|4|  15 |-|   --   | 30  |
    // |title|8|  -- |-|   40   | 30  |
    // Calculate extra space needed for rating stars when duration is hidden
    // Stars are positioned at optionsButton.trailingAnchor - 4, extending left
    // Each star is 10pt with -2pt spacing: width = rating * 8 + 2
    // We only need extra space beyond what optionsButton area (30pt) already provides
    let songRating = playable.asSong?.rating ?? 0
    let isRatingVisible = appDelegate.storage.settings.user.isShowRating && songRating > 0
    let starWidth = CGFloat(songRating * 8 + 2) // Actual star width for this rating
    let ratingExtraSpace: CGFloat = isRatingVisible ? max(0, starWidth - 26) + 6 : 0.0

    if traitCollection.horizontalSizeClass == .regular {
      labelTrailingCellConstraint.constant = 80 + durationTrailing
    } else {
      var lableTrailing = durationTrailing
      if showsDownloadAffordance, isDurationVisible {
        lableTrailing += 4 + cacheIconWidth + 4 + durationWidth
      } else if showsDownloadAffordance {
        lableTrailing += 4 + cacheIconWidth
      } else if isDurationVisible {
        lableTrailing += 8 + durationWidth
      }
      // Add extra space for rating stars when duration is not visible
      if !isDurationVisible, isRatingVisible {
        lableTrailing += ratingExtraSpace
      }
      labelTrailingCellConstraint.constant = lableTrailing
    }

    durationTrailingCellConstraint.constant = durationTrailing
    // cassette: stays hard-hidden — NOT gated to Server Mode here on purpose.
    // Patch 104 retired the per-row `cacheIconImage` marker in favor of the
    // `downloadButton` affordance (also flag-gated off via isDownloadButtonEnabled).
    // `cacheIconImage` now only serves as a layout anchor for that button; the
    // trailing-slot width math (showsDownloadAffordance / lableTrailing above)
    // reserves no space for it and nothing configures its image/isCached state.
    // Un-hiding it for Server Mode would render a stale, unpositioned icon, so a
    // correct streaming-mode badge belongs in the v2 download-button path, not a
    // one-line gate here. Podcast-episode rows ARE gated (PodcastEpisodeTableCell).
    cacheIconImage.isHidden = true
    cacheTrailingCellConstaint
      .constant = durationTrailing + (isDurationVisible ? (4.0 + durationWidth) : 0.0)
    durationLabel.isHidden = !isDurationVisible
    if isDurationVisible {
      durationLabel.text = playable.duration.asColonDurationString
    }
  }

  /// The quiet line (artist, length, cache icon) is ink2 everywhere, the queue included
  /// (phone-taste: queue rows used to paint it full ink, as loud as the title).
  private func refreshSubtitleColor() {
    cacheIconImage.tintColor = UIColor.cassette(.textSecondary)
    artistLabel.textColor = UIColor.cassette(.textSecondary)
    durationLabel.textColor = UIColor.cassette(.textSecondary)
  }

  func playThisSong() {
    guard let playable = playable else { return }
    if let cassetteTapAction {
      cassetteTapAction()
    } else if let playerIndex = playerIndexCb?(self) {
      appDelegate.player.play(playerIndex: playerIndex)
    } else if let context = playContextCb?(self),
              playable.isCached || appDelegate.storage.settings.user.isOnlineMode {
      animateActivation()
      hideSearchBarKeyboardInRootView()
      Haptics.success.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
      appDelegate.player.play(context: context)
    }
  }

  private func hideSearchBarKeyboardInRootView() {
    if let basicRootView = rootView as? BasicTableViewController {
      basicRootView.searchController.searchBar.endEditing(true)
    }
  }

  /// cassette (BUG-417): the XIB declares every label as a system font with
  /// size-class variations. UIKit re-applies those variations on a trait
  /// change (the context-menu preview is one), which put a row back into SF Pro
  /// until it was reused. Fonts are stamped here and re-stamped on every trait
  /// change, the way AlbumCollectionCell already does.
  private func applyCassetteType() {
    titleLabel.font = UIFont.cassette(.rowTitle)
    artistLabel.font = UIFont.cassette(.metadata)
    durationLabel.font = UIFont.cassette(.metadata)
    trackNumberLabel.font = UIFont.cassette(.metadata)
    titleLabel.adjustsFontForContentSizeCategory = false
    artistLabel.adjustsFontForContentSizeCategory = false
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    // cassette (BUG-417): re-stamp the type after the nib's variations run.
    applyCassetteType()
  }

  #if targetEnvironment(macCatalyst) // ok
    @IBAction
    func deleteButtonPressed(_ sender: Any) {
      if let playerIndexCb = playerIndexCb,
         let playerIndex = playerIndexCb(self),
         let queueVC = rootView as? QueueVC,
         let tableView = queueVC.tableView {
        queueVC.tableView(tableView, commit: .delete, forRowAt: playerIndex.asIndexPath)
      }
      if let playerIndexCb = playerIndexCb,
         let playerIndex = playerIndexCb(self),
         let popupPlayerVC = rootView as? PopupPlayerVC,
         let tableView = popupPlayerVC.tableView {
        popupPlayerVC.tableView(tableView, commit: .delete, forRowAt: playerIndex.asIndexPath)
      }
    }

    @IBAction
    func playButtonPressed(_ sender: Any) {
      if appDelegate.player.currentlyPlaying == playable,
         appDelegate.player.isPlaying {
        appDelegate.player.pause()
      } else if appDelegate.player.currentlyPlaying == playable {
        appDelegate.player.play()
      } else {
        playThisSong()
      }
      refreshHoverStyle()
    }

    func refreshHoverStyle() {
      if isHovered {
        playIndicator?.reset()
        if isDeleteButtonAllowedToBeVisible {
          deleteButton.isHidden = false
        } else {
          var buttonImg = UIImage()
          if appDelegate.player.currentlyPlaying == playable,
             appDelegate.player.isPlaying {
            if appDelegate.player.isStopInsteadOfPause {
              buttonImg = UIImage.stop
            } else {
              buttonImg = UIImage.pause
            }
          } else {
            buttonImg = UIImage.play
          }
          if isDislayAlbumTrackNumberStyle {
            // cassette Patch 051 (Phase F): Mac play-over-track-number tint
            // pins to ink explicitly (was themePreference.asColor, which
            // resolves to ink post-Patch 046 but the indirection was
            // misleading on a per-row hot path).
            trackNumberLabel.isHidden = true
            playOverNumberButton.isHidden = false
            playOverNumberButton.imageView?.tintColor = CassetteTheme.UIColors.ink
            playOverNumberButton.setImage(buttonImg, for: UIControl.State.normal)
            playOverArtworkButton.isHidden = true
          } else {
            playOverArtworkButton.isHidden = false
            playOverArtworkButton.imageView?.tintColor = .white
            playOverArtworkButton.setImage(buttonImg, for: UIControl.State.normal)
            playOverNumberButton.isHidden = true
          }
        }
        // cassette Patch 051 (Phase F): Mac current-row cache + options
        // icons pin to ink2 explicitly. Quiet secondary affordances on the
        // active row; ink (used by the play overlay above) is reserved for
        // the primary playback action.
        cacheIconImage.tintColor = CassetteTheme.UIColors.ink2
        optionsButton.imageView?.tintColor = CassetteTheme.UIColors.ink2
        backgroundColor = (rootView is PopupPlayerVC) ?
          CassetteTheme.UIColors.bg2.withAlphaComponent(0.2) :
          CassetteTheme.UIColors.bg2
      } else {
        playOverArtworkButton.isHidden = true
        playOverNumberButton.isHidden = true
        if isDislayAlbumTrackNumberStyle {
          trackNumberLabel.isHidden = false
        }
        configurePlayIndicator(playable: playable)
        deleteButton.isHidden = true
        refreshSubtitleColor()
        optionsButton.imageView?.tintColor = CassetteTheme.UIColors.ink
        backgroundColor = .clear
      }
    }

    @objc
    func hovering(_ recognizer: UIHoverGestureRecognizer) {
      switch recognizer.state {
      case .began:
        isHovered = true
        refreshHoverStyle()
      case .ended:
        isHovered = false
        refreshHoverStyle()
      default:
        if !isHovered {
          isHovered = true
          refreshHoverStyle()
        }
      }
    }

    @objc
    func doubleTap(sender: UITapGestureRecognizer) {
      switch sender.state {
      case .ended:
        if displayMode == .normal {
          playThisSong()
        }
      default:
        break
      }
    }

    @objc
    private func playerPlay(notification: Notification) {
      guard isHovered else { return }
      refreshHoverStyle()
    }

    @objc
    private func playerPause(notification: Notification) {
      guard isHovered else { return }
      refreshHoverStyle()
    }

    @objc
    private func playerStop(notification: Notification) {
      guard isHovered else { return }
      refreshHoverStyle()
    }

  #else

    @objc
    func singleTap(sender: UITapGestureRecognizer) {
      switch sender.state {
      case .ended:
        if displayMode == .normal {
          playThisSong()
        }
      default:
        break
      }
    }
  #endif
}

// MARK: UIContextMenuInteractionDelegate

extension PlayableTableCell: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  )
    -> UIContextMenuConfiguration? {
    guard let playable = playable,
          let rootView = rootView,
          playContextCb != nil,
          playerIndexCb == nil,
          displayMode == .normal,
          !playable.isRadio
    else { return nil }
    // Same shape as the retired optionsButton menu: no-arg PlayContext look-up.
    let playContext = { [weak self] () -> PlayContext? in
      guard let self else { return nil }
      return playContextCb?(self)
    }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
      UIMenu(
        children: EntityPreviewActionBuilder(
          container: playable,
          on: rootView,
          playContextCb: playContext,
          playerIndexCb: nil
        ).createMenuActions()
      )
    }
  }
}

// MARK: - CassetteTrackSubtitle

/// Display-time track subtitle for album / artist contexts. Keep aligned with
/// apps/cassette/src/lib/dashboard/track-subtitle.ts.
enum CassetteTrackSubtitle {
  private static let featInfixPattern =
    #"^(.*?)\s+(feat\.|featuring|ft\.|with)\s+(.+)$"#
  private static let featParenPattern =
    #"^(.*?)\s*[\[({]\s*(feat\.|featuring|ft\.|with)\s+(.+?)\s*[\])}]\s*$"#

  static func contextual(trackArtist: String?, contextArtist: String?) -> String? {
    let track = trackArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if track.isEmpty { return nil }
    let ctx = contextArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if ctx.isEmpty { return track }

    // Exact match only — a normalize that strips "feat." would hide guests.
    if track.lowercased() == ctx.lowercased() { return nil }

    for pattern in [featInfixPattern, featParenPattern] {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      else { continue }
      let range = NSRange(track.startIndex ..< track.endIndex, in: track)
      guard let match = regex.firstMatch(in: track, options: [], range: range),
            match.numberOfRanges >= 4,
            let primaryRange = Range(match.range(at: 1), in: track),
            let guestsRange = Range(match.range(at: 3), in: track)
      else { continue }
      let primary = String(track[primaryRange]).trimmingCharacters(in: .whitespacesAndNewlines)
      let guests = String(track[guestsRange]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !primary.isEmpty, !guests.isEmpty, sameArtist(primary, ctx) {
        let collapsed = guests.replacingOccurrences(
          of: #"\s+"#,
          with: " ",
          options: .regularExpression
        )
        return "feat. \(collapsed)"
      }
    }
    if sameArtist(track, ctx) { return nil }
    return track
  }

  private static func sameArtist(_ a: String, _ b: String) -> Bool {
    a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
