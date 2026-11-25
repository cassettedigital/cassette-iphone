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
  /// A record head's keys: the kit's head step (48, the website's head row; C-play-sizes).
  static let pillHeight: CGFloat = CassetteKitTokens.Control.head
  /// The compact action bar's height: one row of pills.
  static let prominentBarHeight: CGFloat = pillHeight
  static let prominentFrameHeight: CGFloat = prominentBarHeight + margin.top + margin.bottom
  static let margin = UIView.defaultMarginMiddleElement

  private var config: PlayShuffleInfoConfiguration?

  private var prominentContainer: CassetteKeyRow?
  private var prominentPlayButton: CassetteKeyButton?
  private var prominentShuffleButton: CassetteKeyButton?

  /// Where the head's keys sit: under a left-set name, or centred under a centred one.
  var keyAlignment: CassetteKeyRow.Alignment = .leading {
    didSet { prominentContainer?.alignment = keyAlignment }
  }

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

  // The compact action bar: the website's head row (C-rows-model, design wave 6), each key at
  // its own width, 12 apart, under the head's words:
  //   [ > PLAY ]  [ x SHUFFLE ]
  // - Play is the one primary dark (ink fill); Shuffle is the outlined key, and gives up its
  //   word for its glyph first when a row runs short. Play holds its word.
  // - Repeat is no longer here; it lives on Now Playing and the queue.
  // - Overflow is a navigation-bar item, wired by the detail view controllers.
  private func setupProminentLayoutIfNeeded() {
    guard config?.usesProminentPlayButton == true, prominentContainer == nil else { return }

    let play = Self.makePlayPill()
    play.addTarget(self, action: #selector(prominentPlayPressed), for: .touchUpInside)

    let shuffle = Self.makeShufflePill()
    shuffle.addTarget(self, action: #selector(prominentShufflePressed), for: .touchUpInside)

    let row = CassetteKeyRow(alignment: keyAlignment)
    row.setKeys([play, shuffle], givesWay: [shuffle])
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

  /// What a PLAY key says: Play, or (once the player is on that page's music) Pause, or
  /// Stop for a live station, the way the player's own button reads. A station's idle key
  /// says Tune in, as the website's does (its RadioTuneInKey).
  enum PlayPillState {
    case play, pause, stop, tuneIn
  }

  /// cassette 2026-10-21 (founder: "it has no idea it is playing that thing"): every hero's
  /// PLAY key, here and on the made-for-you and station pages, reads the same way.
  static func setPlayPill(_ pill: CassetteKeyButton, state: PlayPillState) {
    let (icon, label): (CassetteIcon, String) = switch state {
    case .play: (.play, "Play")
    case .pause: (.pause, "Pause")
    case .stop: (.stop, "Stop")
    case .tuneIn: (.play, "Tune in")
    }
    pill.setWords(label, icon: icon)
  }

  /// The PLAY key: the one primary dark at the record head's height.
  static func makePlayPill() -> CassetteKeyButton {
    CassetteKey.make(.fill, words: "Play", icon: .play, height: pillHeight)
  }

  /// The SHUFFLE key: the outlined key at the record head's height.
  static func makeShufflePill() -> CassetteKeyButton {
    CassetteKey.make(.line, words: "Shuffle", icon: .shuffle, height: pillHeight)
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
