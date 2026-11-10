//
//  LibraryElementDetailTableHeaderView.swift
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

typealias GetInfoCallback = () -> String

// MARK: - PlayShuffleInfoConfiguration

struct PlayShuffleInfoConfiguration {
  var infoCB: GetInfoCallback?
  var playContextCb: GetPlayContextCallback?
  var player: PlayerFacade
  let isInfoAlwaysHidden: Bool
  var customPlayName: String?
  var isShuffleHidden = false
  var isShuffleOnContextNeccessary: Bool = true
  var shuffleContextCb: GetPlayContextCallback?
  var isEmbeddedInOtherView: Bool = false
  /// cassette polish Part 4 / Polish 2 (D1): when true (set only by the Album /
  /// Artist / Playlist detail headers), the compact-width layout swaps the
  /// side-by-side bordered pair for two equal pills: `[PLAY] [SHUFFLE]`
  /// (phone-taste). List headers leave this false.
  var usesProminentPlayButton: Bool = false
  /// cassette Polish 2 (D1): the album/artist this header represents. Injected by
  /// GenericDetailTableHeader from its own DetailHeaderConfiguration; the header
  /// reads it to bind the Play/Pause CTA to this context (`isThisContextCurrent`).
  /// (Formerly also drove the action-bar heart — favorites feature removed.)
  var favoriteEntity: (any PlayableContainable)?
  /// Weak, so the play bar never keeps its page alive (BUG-447).
  weak var rootViewController: UIViewController?
}

// MARK: - LibraryElementDetailTableHeaderView

class LibraryElementDetailTableHeaderView: UIView {
  @IBOutlet
  weak var playAllButton: UIButton!
  @IBOutlet
  weak var playShuffledButton: UIButton!
  @IBOutlet
  weak var infoContainerView: UIView!
  @IBOutlet
  weak var infoLabel: UILabel!

  static let frameHeight: CGFloat = 40.0 + margin.top + margin.bottom
  /// The disc size `makeDetailPlayCTA` was built around (the Resume card still uses it).
  static let prominentPlayDiameter: CGFloat = 56.0
  /// phone-taste: the Play and Shuffle pills are 48pt tall (the mock's `.playPill`).
  static let pillHeight: CGFloat = 48
  /// The compact action bar's height: one row of pills.
  static let prominentBarHeight: CGFloat = pillHeight
  static let prominentFrameHeight: CGFloat = prominentBarHeight + margin.top + margin.bottom
  static let margin = UIView.defaultMarginMiddleElement

  private var config: PlayShuffleInfoConfiguration?

  private var prominentContainer: UIView?
  private var prominentPlayButton: UIButton?
  private var prominentShuffleButton: UIButton?

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    self.layoutMargins = UIEdgeInsets(
      top: 0.0,
      left: UIView.defaultMarginX,
      bottom: 0.0,
      right: UIView.defaultMarginX
    )

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.refresh()
      }
    )
  }

  public static func createTableHeader(
    rootView: BasicTableViewController,
    configuration: PlayShuffleInfoConfiguration
  )
    -> LibraryElementDetailTableHeaderView? {
    rootView.tableView.tableHeaderView = UIView(frame: CGRect(
      x: 0,
      y: 0,
      width: rootView.view.bounds.size.width,
      height: Self.frameHeight
    ))
    let genericDetailTableHeaderView = ViewCreator<LibraryElementDetailTableHeaderView>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: rootView.view.bounds.size.width,
        height: Self.frameHeight
      ))!
    genericDetailTableHeaderView.prepare(configuration: configuration)
    rootView.tableView.tableHeaderView?.addSubview(genericDetailTableHeaderView)
    return genericDetailTableHeaderView
  }

  func refresh() {
    guard let config = config else { return }
    if config.isEmbeddedInOtherView {
      layoutMargins = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
    } else {
      if traitCollection.horizontalSizeClass == .compact {
        layoutMargins = UIEdgeInsets(
          top: 0.0,
          left: UIView.defaultMarginCellX,
          bottom: 0.0,
          right: UIView.defaultMarginCellX
        )
      } else {
        layoutMargins = UIEdgeInsets(
          top: 0.0,
          left: UIView.defaultMarginX,
          bottom: 0.0,
          right: UIView.defaultMarginX
        )
      }
    }
    infoContainerView.isHidden = config
      .isInfoAlwaysHidden || (traitCollection.horizontalSizeClass == .compact)
    infoLabel.text = config.infoCB?() ?? ""

    // cassette polish Part 4 / Polish 2 (D1): the prominent action bar is
    // compact-width only; iPad/Mac (regular) and standalone list headers keep
    // the known-good bordered pair.
    let showProminent = config.usesProminentPlayButton &&
      traitCollection.horizontalSizeClass == .compact
    prominentContainer?.isHidden = !showProminent
    playAllButton.isHidden = showProminent
    playShuffledButton.isHidden = showProminent || config.isShuffleHidden

    if showProminent {
      // A hidden Shuffle lets Play fill the row (the stack view drops hidden views).
      prominentShuffleButton?.isHidden = config.isShuffleHidden
    }
    refreshPlayButtonState()
  }

  @IBAction
  func playAllButtonPressed(_ sender: Any) {
    Haptics.success.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    handlePlayCTATap()
  }

  @IBAction
  func addAllShuffledButtonPressed(_ sender: Any) {
    Haptics.success.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    shuffle()
  }

  private func play(isShuffled: Bool) {
    guard let playContext = config?.playContextCb?(), let player = config?.player else { return }
    isShuffled ? player.playShuffled(context: playContext) : player.play(context: playContext)
  }

  private func shuffle() {
    guard let player = config?.player else { return }
    if let shuffleContext = config?.shuffleContextCb?() {
      if config?.isShuffleOnContextNeccessary ?? true {
        player.playShuffled(context: shuffleContext)
      } else {
        player.play(context: shuffleContext)
      }
    } else {
      play(isShuffled: true)
    }
  }

  // cassette: the detail Play CTA reflects live player state and binds to THIS
  // album/artist context:
  //   - a track from this context is playing -> Pause icon, tap pauses
  //   - paused on this context               -> Play icon, tap resumes
  //   - a different context (or nothing)     -> Play icon, tap replaces playback
  // It stays in sync with playback started elsewhere (mini-player / lock screen)
  // via the player notifications registered in prepare().

  /// True when the player's current track belongs to this header's entity
  /// (album → song's album; artist → song's artist / album-artist), whether
  /// playing or paused.
  private var isThisContextCurrent: Bool {
    guard let current = config?.player.currentlyPlaying?.asSong else { return false }
    if let album = config?.favoriteEntity as? Album {
      return current.album == album
    }
    if let artist = config?.favoriteEntity as? Artist {
      return current.artist == artist || current.album?.artist == artist
    }
    // phone-taste: a playlist's Play pauses while that playlist plays. Its play context
    // carries the playlist's name; the song check keeps two playlists that share a name
    // apart.
    if let playlist = config?.favoriteEntity as? Playlist,
       let player = config?.player {
      return player.contextName == playlist.name
        && playlist.playables.contains { $0.id == current.id }
    }
    return false
  }

  private func handlePlayCTATap() {
    guard let player = config?.player else { return }
    if isThisContextCurrent {
      // Pause if playing this context, resume if paused on it.
      player.togglePlayPause()
    } else {
      // Different context (or nothing) → replace playback with this one.
      play(isShuffled: false)
    }
    refreshPlayButtonState()
  }

  /// Swap the Play/Pause glyph + title on both the Play pill and the
  /// bordered button to match live state.
  func refreshPlayButtonState() {
    let isPausable = isThisContextCurrent && (config?.player.isPlaying ?? false)
    let icon = isPausable ? CassetteIcon.pause : CassetteIcon.play
    let symbolName = icon.symbolName
    let label = isPausable ? "Pause" : "Play"

    if let pill = prominentPlayButton {
      Self.setPlayPill(pill, state: isPausable ? .pause : .play)
    }

    if playAllButton != nil {
      playAllButton.configuration?.image = UIImage(systemName: symbolName)
      playAllButton.configuration?.title = isPausable ? "Pause" : (config?.customPlayName ?? "Play")
      playAllButton.accessibilityLabel = label
    }
  }

  @objc
  private func playerStateChangedForPlayCTA() {
    refreshPlayButtonState()
  }

  private var didRegisterPlayerStateNotifications = false
  private func registerPlayerStateNotificationsIfNeeded() {
    guard !didRegisterPlayerStateNotifications else { return }
    didRegisterPlayerStateNotifications = true
    for name in [Notification.Name.playerPlay, .playerPause, .playerStop] {
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(playerStateChangedForPlayCTA),
        name: name,
        object: nil
      )
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  /// isShuffleOnContextNeccessary: In AlbumsVC the albums are shuffled, keep the order when shuffle button is pressed
  func prepare(configuration: PlayShuffleInfoConfiguration) {
    config = configuration
    Self.applyCassetteStyle(
      to: playAllButton,
      title: config?.customPlayName ?? "Play",
      systemImage: CassetteIcon.play.symbolName
    )
    Self.applyCassetteStyle(
      to: playShuffledButton,
      title: configuration.isShuffleOnContextNeccessary ? "Shuffle" : "Random",
      systemImage: CassetteIcon.shuffle.symbolName,
      isHidden: configuration.isShuffleHidden
    )
    // Wave 4 (BUG-427): the info line took its font and grey from the XIB; code only set
    // the text.
    CassetteIBStyle.label(infoLabel, .metadata, .textSecondary)
    setupProminentLayoutIfNeeded()
    activate()
    registerPlayerStateNotificationsIfNeeded()
    refreshPlayButtonState()
    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.refresh()
      }
    )
  }

  /// cassette Patch 034 (3B, Option A): switch from .tinted() to
  /// .borderedTinted(). Borderedtinted gives a slightly more defined
  /// edge that reads more like Apple Music's primary action buttons
  /// while staying native. Keep contentInsets / imagePadding / SF
  /// Symbol point size unchanged from Patch 027 — only the surface
  /// treatment changes. Drop the explicit baseBackgroundColor so iOS
  /// can paint the bordered-tinted default (a subtle tint of the
  /// foreground color) rather than the prior bg2 grey.
  private static func applyCassetteStyle(
    to button: UIButton,
    title: String,
    systemImage: String,
    isHidden: Bool = false
  ) {
    var config = UIButton.Configuration.borderedTinted()
    config.image = UIImage(systemName: systemImage)
    config.imagePadding = 6
    config.imagePlacement = .leading
    config.cornerStyle = .medium
    config.baseForegroundColor = UIColor.cassette(.textPrimary)
    config.contentInsets = NSDirectionalEdgeInsets(
      top: 8,
      leading: 16,
      bottom: 8,
      trailing: 16
    )
    config.title = title
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 15,
      weight: .semibold
    )
    button.configuration = config
    // Wave 4: the XIB carried a secondarySystemFill background under the configuration.
    button.backgroundColor = .clear
    button.isHidden = isHidden
  }

  // phone-taste: the compact action bar is two equal 48pt pills, toggled visible only
  // for compact width in refresh():
  //   [ > PLAY ] [ SHUFFLE ]
  // - Play is the cream pill (ink fill, dark label); Shuffle is the outlined ghost pill.
  // - Repeat is no longer here; it lives on Now Playing and the queue.
  // - Overflow is a navigation-bar item, wired by the detail view controllers.
  private func setupProminentLayoutIfNeeded() {
    guard config?.usesProminentPlayButton == true, prominentContainer == nil else { return }

    let play = Self.makePlayPill()
    play.addTarget(self, action: #selector(prominentPlayPressed), for: .touchUpInside)

    let shuffle = Self.makeShufflePill()
    shuffle.addTarget(self, action: #selector(prominentShufflePressed), for: .touchUpInside)

    let row = UIStackView(arrangedSubviews: [play, shuffle])
    row.axis = .horizontal
    row.distribution = .fillEqually
    row.alignment = .fill
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])

    prominentContainer = row
    prominentPlayButton = play
    prominentShuffleButton = shuffle
  }

  /// A pill label in the `.pill` role (Barlow Bold 16, tracked, capitals).
  private static func pillTitle(_ text: String, color: UIColor) -> AttributedString {
    AttributedString(NSAttributedString.cassette(text, .pill, color: color))
  }

  /// What a PLAY pill says: Play, or (once the player is on that page's music) Pause, or
  /// Stop for a live station, the way the player's own button reads.
  enum PlayPillState {
    case play, pause, stop
  }

  /// cassette 2026-10-21 (founder: "it has no idea it is playing that thing"): every hero's
  /// PLAY pill, here and on the made-for-you and station pages, reads the same way.
  static func setPlayPill(_ pill: UIButton, state: PlayPillState) {
    let (icon, label): (CassetteIcon, String) = switch state {
    case .play: (.play, "Play")
    case .pause: (.pause, "Pause")
    case .stop: (.stop, "Stop")
    }
    pill.configuration?.image = icon.symbolImage
    pill.configuration?.attributedTitle = pillTitle(label, color: .cassette(.textOnFill))
    pill.accessibilityLabel = label
  }

  /// The cream PLAY pill (the mock's `.playPill`): ink fill, dark label and glyph, 16pt
  /// icon with an 8pt gap, fully round ends.
  static func makePlayPill() -> UIButton {
    var config = UIButton.Configuration.filled()
    config.baseBackgroundColor = UIColor.cassette(.fillSelected)
    config.baseForegroundColor = UIColor.cassette(.textOnFill)
    config.cornerStyle = .capsule
    config.image = CassetteIcon.play.symbolImage
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16)
    config.imagePlacement = .leading
    config.imagePadding = 8
    config.attributedTitle = pillTitle("Play", color: .cassette(.textOnFill))
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Play"
    return button
  }

  /// The outlined SHUFFLE pill (the mock's `.ghostPill`): clear, a 1.5pt ink ring at 35%,
  /// ink label and glyph.
  static func makeShufflePill() -> UIButton {
    var config = UIButton.Configuration.plain()
    config.background.backgroundColor = .clear
    config.background.strokeColor = UIColor.cassette(.textPrimary).withAlphaComponent(0.35)
    config.background.strokeWidth = 1.5
    config.cornerStyle = .capsule
    config.baseForegroundColor = UIColor.cassette(.textPrimary)
    config.image = CassetteIcon.shuffle.symbolImage
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16)
    config.imagePlacement = .leading
    config.imagePadding = 8
    config.attributedTitle = pillTitle("Shuffle", color: .cassette(.textPrimary))
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Shuffle"
    return button
  }

  /// cassette redesign (Surface 1): visual style of the prominent detail
  /// play CTA. `.creamFill` is the approved default (brand ink disc);
  /// `.prominentGlass` is the Liquid Glass comparison variant — flip the
  /// static below to compare the two on-device.
  enum DetailPlayCTAStyle {
    case creamFill
    case prominentGlass
  }

  /// One-line switch for the cream-vs-glass play button comparison.
  static var detailPlayCTAStyle: DetailPlayCTAStyle = .creamFill

  /// Native circular play CTA. Replaces the skeuomorphic CassettePlayButton
  /// (hand-drawn CAShapeLayer rim/inner-shadow disc) with a stock
  /// UIButton.Configuration so pressed states, pointer effects, and — in the
  /// glass variant — Liquid Glass all come from the system.
  static func makeDetailPlayCTA(diameter: CGFloat, glyphScale: CGFloat = 0.35) -> UIButton {
    var config: UIButton.Configuration
    switch detailPlayCTAStyle {
    case .creamFill:
      config = .filled()
      config.baseBackgroundColor = UIColor.cassette(.fillSelected)
      config.baseForegroundColor = UIColor.cassette(.textOnFill)
    case .prominentGlass:
      config = .prominentGlass()
      config.baseForegroundColor = UIColor.cassette(.textPrimary)
    }
    config.cornerStyle = .capsule
    config.image = CassetteIcon.play.symbolImage
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: (diameter * glyphScale).rounded(),
      weight: .medium
    )
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Play"
    return button
  }

  @objc
  private func prominentPlayPressed() {
    Haptics.medium.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    handlePlayCTATap()
  }

  @objc
  private func prominentShufflePressed() {
    Haptics.light.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    shuffle()
  }

  func activate() {
    playAllButton.isEnabled = true
    playShuffledButton.isEnabled = !(config?.isShuffleOnContextNeccessary ?? true) || appDelegate
      .storage.settings.user.isPlayerShuffleButtonEnabled
    prominentPlayButton?.isEnabled = true
    prominentShuffleButton?.isEnabled = playShuffledButton.isEnabled
  }

  func deactivate() {
    playAllButton.isEnabled = false
    playShuffledButton.isEnabled = false
    prominentPlayButton?.isEnabled = false
    prominentShuffleButton?.isEnabled = false
  }
}
