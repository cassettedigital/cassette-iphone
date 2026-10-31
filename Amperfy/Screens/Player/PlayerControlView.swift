//
//  PlayerControlView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 07.02.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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
import MarqueeLabel
import MediaPlayer
import UIKit

// MARK: - PlayerControlView

class PlayerControlView: UIView {
  // cassette Patch 104: +12pt so the added breathing room between the
  // transport row and the airplay/queue row isn't squeezed out.
  // phone-taste (play-disc): +8pt (slider-to-transport gap 22 -> 30 in the XIB) so the
  // 78pt disc, which overhangs the 50pt transport row, clears the time labels.
  static let frameHeight: CGFloat = 195
  /// phone-taste: the cream play disc (the mock's .npPlay).
  static private let playDiscDiameter: CGFloat = 78
  /// phone-taste: the AirPlay and queue glyphs sit this far in from each edge (the mock's
  /// 26pt sheet padding plus the foot row's own 6pt).
  static private let footRowInset: CGFloat = 32
  static private let margin = UIEdgeInsets(
    top: 0,
    left: UIView.defaultMarginX,
    bottom: 20,
    right: UIView.defaultMarginX
  )

  private var player: PlayerFacade!
  private var rootView: PopupPlayerVC?
  private var playerHandler: PlayerUIHandler?
  #if targetEnvironment(macCatalyst) // ok
    var airplayVolume: MPVolumeView?
  #endif

  @IBOutlet
  weak var playButton: UIButton!
  @IBOutlet
  weak var previousButton: UIButton!
  @IBOutlet
  weak var nextButton: UIButton!
  @IBOutlet
  weak var skipBackwardButton: UIButton!
  @IBOutlet
  weak var skipForwardButton: UIButton!

  @IBOutlet
  weak var timeSlider: UISlider!
  @IBOutlet
  weak var elapsedTimeLabel: UILabel!
  @IBOutlet
  weak var remainingTimeLabel: UILabel!
  @IBOutlet
  weak var liveLabel: UILabel!
  @IBOutlet
  weak var audioInfoLabel: UILabel!
  @IBOutlet
  weak var playTypeIcon: UIImageView!

  @IBOutlet
  weak var optionsStackView: UIStackView!
  @IBOutlet
  weak var playerModeButton: UIButton!
  @IBOutlet
  weak var airplayButton: UIButton!
  @IBOutlet
  weak var displayPlaylistButton: UIButton!
  @IBOutlet
  weak var volumeButton: UIButton!
  @IBOutlet
  weak var optionsButton: UIButton!

  /// cassette transport polish: the previous/play/next buttons are re-pinned to
  /// the SAME equidistant quarter-point distribution the album action row uses
  /// (LibraryElementDetailTableHeaderView.setupProminentLayoutIfNeeded):
  /// centerX multipliers 0.5 / 1.0 / 1.5 against the full view width, so
  /// back/play/forward sit centered between the play disc and each screen edge
  /// — instead of the old fixed-width `fillEqually` cluster. Skip buttons (off
  /// by default in Cassette) flank at the eighth points (0.25 / 1.75). Set once.
  private var didSetupCassetteTransportLayout = false

  /// The scrubber's played part and thumb in the playing record's colour (founder,
  /// 2026-10-21), the colour of its artist name above, instead of brand orange.
  @objc
  func applyNowPlayingTint() {
    timeSlider.minimumTrackTintColor = CoverTint.nowPlaying.text
    timeSlider.thumbTintColor = CoverTint.nowPlaying.text
  }

  required init?(coder aDecoder: NSCoder) {
    #if targetEnvironment(macCatalyst) // ok
      self.airplayVolume = MPVolumeView(frame: .zero)
      airplayVolume!.showsVolumeSlider = false
      airplayVolume!.isHidden = true
    #endif

    super.init(coder: aDecoder)
    self.layoutMargins = Self.margin
    self.player = appDelegate.player
    player.addNotifier(notifier: self)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applyNowPlayingTint),
      name: .cassetteNowPlayingTintChanged,
      object: nil
    )

    #if targetEnvironment(macCatalyst) // ok
      addSubview(airplayVolume!)
    #endif
  }

  func prepare(toWorkOnRootView: PopupPlayerVC?) {
    rootView = toWorkOnRootView
    // cassette (I-M2): every key on the sheet says what it does (none did).
    previousButton.accessibilityLabel = "Previous"
    nextButton.accessibilityLabel = "Next"
    skipBackwardButton.accessibilityLabel = "Back 10 seconds"
    skipForwardButton.accessibilityLabel = "Forward 10 seconds"
    airplayButton.accessibilityLabel = "AirPlay"
    displayPlaylistButton.accessibilityLabel = "Up Next"
    playerModeButton.accessibilityLabel = "Music or podcasts"
    volumeButton.accessibilityLabel = "Volume"
    optionsButton.accessibilityLabel = "More"

    playerHandler = PlayerUIHandler(player: player, style: .popupPlayer)

    // phone-taste (play-disc): play/pause sits on the mock's cream disc again, a 78pt
    // ink circle (sized in setupCassetteTransportLayout) with a dark 30pt glyph, the
    // biggest target on the sheet. A filled configuration, not the iOS 26 system glass.
    // refreshPlayButton only swaps the image, so this configuration survives.
    var playConfig = UIButton.Configuration.filled()
    playConfig.baseBackgroundColor = UIColor.cassette(.fillSelected)
    playConfig.baseForegroundColor = UIColor.cassette(.surfaceSunken)
    playConfig.cornerStyle = .capsule
    let playSymbol = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)
    playConfig.preferredSymbolConfigurationForImage = playSymbol
    playButton.configuration = playConfig
    // The nib's state image carries its own 32pt symbol size; match it, whichever wins.
    playButton.setPreferredSymbolConfiguration(playSymbol, forImageIn: .normal)
    playButton.tintColor = UIColor.cassette(.textPrimary)
    // Prev and next take 28pt glyphs (the mock's 30px skip arrows) through their own
    // configuration; refreshPrevNextButtons swaps only their image.
    let skipSymbol = UIImage.SymbolConfiguration(pointSize: 28)
    for button in [previousButton, nextButton] {
      guard let button else { continue }
      var config = UIButton.Configuration.cassetteBare()
      config.baseForegroundColor = UIColor.cassette(.textPrimary)
      config.preferredSymbolConfigurationForImage = skipSymbol
      config.image = button.image(for: .normal)
      button.configuration = config
      button.setPreferredSymbolConfiguration(skipSymbol, forImageIn: .normal)
    }
    previousButton.tintColor = UIColor.cassette(.textPrimary)
    nextButton.tintColor = UIColor.cassette(.textPrimary)
    skipBackwardButton.tintColor = UIColor.cassette(.textPrimary)
    skipForwardButton.tintColor = UIColor.cassette(.textPrimary)
    // phone-taste (foot-row): the foot row goes quiet in ink2 (the mock's .npFoot), which
    // reverses Polish 2's uniform ink so the transport and the title lead. The queue
    // toggle's unselected glyph follows in refreshDisplayPlaylistButton; selected, it
    // keeps its ink fill.
    airplayButton.tintColor = UIColor.cassette(.textSecondary)
    playerModeButton.tintColor = UIColor.cassette(.textSecondary)
    pinFootRowToEdges()
    elapsedTimeLabel.font = UIFont.cassette(.metadata)
    elapsedTimeLabel.textColor = UIColor.cassette(.textSecondary)
    remainingTimeLabel.font = UIFont.cassette(.metadata)
    remainingTimeLabel.textColor = UIColor.cassette(.textSecondary)
    applyNowPlayingTint()
    timeSlider.maximumTrackTintColor = UIColor.cassette(.hairline)
    // Wave 4: the radio LIVE marker took boldSystem 14 from the XIB.
    CassetteIBStyle.label(liveLabel, .sectionLabel, .textSecondary)
    // cassette polish Part 1: drop the "MP3 2658 kbps" bitrate strip beneath the
    // scrubber. Removed from the hierarchy so the time row reads clean; the
    // refresh path keeps these as optionals and no longer un-hides them.
    audioInfoLabel?.removeFromSuperview()
    playTypeIcon?.removeFromSuperview()
    // cassette polish Part 2: kill the on-screen volume control (physical
    // buttons handle volume) and the player-level overflow menu. The bottom row
    // is now just AirPlay + Queue (the favorite heart was removed).
    volumeButton?.removeFromSuperview()
    optionsButton?.removeFromSuperview()
    setupCassetteTransportLayout()
    refreshPlayer()

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.playerHandler?.refreshTimeInfo(
          timeSlider: self.timeSlider,
          elapsedTimeLabel: self.elapsedTimeLabel,
          remainingTimeLabel: self.remainingTimeLabel,
          audioInfoLabel: self.audioInfoLabel,
          playTypeIcon: self.playTypeIcon,
          liveLabel: self.liveLabel
        )
      }
    )
  }

  @IBAction
  func swipeHandler(_ gestureRecognizer: UISwipeGestureRecognizer) {
    if gestureRecognizer.state == .ended {
      rootView?.closePopupPlayer()
    }
  }

  @IBAction
  func playButtonPushed(_ sender: Any) {
    playerHandler?.playButtonPushed()
    playerHandler?.refreshPlayButton(playButton)
  }

  @IBAction
  func previousButtonPushed(_ sender: Any) {
    playerHandler?.previousButtonPushed()
    // Patch 113: optimistic now-playing update — refresh the hero
    // (title/artist/cover) from the just-advanced queue item now, not on the
    // trailing didStartPlaying callback. (This control bar refreshes its own
    // transport buttons; the hero lives on the popup VC.)
    rootView?.optimisticallyRefreshNowPlaying()
  }

  @IBAction
  func nextButtonPushed(_ sender: Any) {
    playerHandler?.nextButtonPushed()
    // Patch 113: optimistic now-playing update (see previousButtonPushed).
    rootView?.optimisticallyRefreshNowPlaying()
  }

  @IBAction
  func skipBackwardButtonPushed(_ sender: Any) {
    playerHandler?.skipBackwardButtonPushed()
  }

  @IBAction
  func skipForwardButtonPushed(_ sender: Any) {
    playerHandler?.skipForwardButtonPushed()
  }

  @IBAction
  func timeSliderChanged(_ sender: Any) {
    playerHandler?.timeSliderChanged(timeSlider: timeSlider)
  }

  @IBAction
  func timeSliderIsChanging(_ sender: Any) {
    playerHandler?.timeSliderIsChanging(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel
    )
  }

  @IBAction
  func airplayButtonPushed(_ sender: UIButton) {
    #if targetEnvironment(macCatalyst) // ok
      playerHandler?.airplayButtonPushed(
        rootView: self,
        airplayButton: airplayButton,
        airplayVolume: airplayVolume
      )
    #else
      playerHandler?.airplayButtonPushed(rootView: self, airplayButton: airplayButton)
    #endif
  }

  // cassette polish Part 2: the on-screen volume control is removed (physical
  // buttons own volume). The button is dropped from the bottom row; this stub
  // preserves the XIB action connection and does nothing.
  @IBAction
  func volumeButtonPressed(_ sender: Any) {}

  /// cassette transport polish: re-pin back/play/forward to the album action
  /// row's equidistant distribution (centerX multipliers 0.5 / 1.0 / 1.5 of the
  /// full view width). The transport buttons ship inside a fixed-width
  /// `fillEqually` stack (`SoI-ny-Hw0`); that clusters them more tightly than
  /// the album row's play/shuffle and isn't a true equidistant-around-
  /// center layout once the skip buttons toggle. We lift the 5 buttons out of
  /// that stack into `self` and pin each by centerX multiplier, keeping the now-
  /// empty stack as the (unchanged) vertical anchor so the time row above and
  /// the AirPlay/queue row below keep their existing spacing.
  private func setupCassetteTransportLayout() {
    guard !didSetupCassetteTransportLayout else { return }
    guard let transportStack = playButton.superview else { return }
    didSetupCassetteTransportLayout = true

    // The stack stays in the hierarchy (its top/centerX/width/height constraints
    // anchor the row vertically) but no longer lays out the buttons.
    let rowCenterY = transportStack.centerYAnchor

    func pin(_ button: UIButton?, centerXMultiplier: CGFloat) {
      guard let button else { return }
      button.removeFromSuperview()
      button.translatesAutoresizingMaskIntoConstraints = false
      addSubview(button)
      NSLayoutConstraint.activate([
        NSLayoutConstraint(
          item: button,
          attribute: .centerX,
          relatedBy: .equal,
          toItem: self,
          attribute: .centerX,
          multiplier: centerXMultiplier,
          constant: 0
        ),
        button.centerYAnchor.constraint(equalTo: rowCenterY),
      ])
    }

    // Primary three — identical multipliers to the album action row.
    pin(previousButton, centerXMultiplier: 0.5)
    pin(playButton, centerXMultiplier: 1.0)
    pin(nextButton, centerXMultiplier: 1.5)
    // Skip buttons (default-hidden in Cassette) flank symmetrically further out.
    pin(skipBackwardButton, centerXMultiplier: 0.25)
    pin(skipForwardButton, centerXMultiplier: 1.75)

    // phone-taste (play-disc): the disc is a fixed 78pt circle, centred on the row.
    NSLayoutConstraint.activate([
      playButton.widthAnchor.constraint(equalToConstant: Self.playDiscDiameter),
      playButton.heightAnchor.constraint(equalToConstant: Self.playDiscDiameter),
    ])
  }

  /// phone-taste (foot-row): AirPlay and the queue toggle move out toward the edges (the
  /// mock's space-between foot row) instead of sitting in a centred 300pt row. The nib's
  /// width constraint on the row (dMH-9W-9do) has no outlet, so it is found by its shape.
  private func pinFootRowToEdges() {
    guard let stack = optionsStackView else { return }
    // The stack's own layout constraints carry a "UISV-" identifier; the nib's do not.
    for constraint in stack.constraints
      where constraint.firstItem === stack && constraint.secondItem == nil
      && constraint.firstAttribute == .width
      && !(constraint.identifier?.hasPrefix("UISV") ?? false) {
      constraint.isActive = false
    }
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.footRowInset),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.footRowInset),
    ])
  }

  @IBAction
  func displayPlaylistPressed() {
    rootView?.switchDisplayStyleOptionPersistent()
    playerHandler?.refreshDisplayPlaylistButton(displayPlaylistButton: displayPlaylistButton)
  }

  @IBAction
  func playerModeChangePressed(_ sender: Any) {
    switch player.playerMode {
    case .music:
      appDelegate.player.setPlayerMode(.podcast)
    case .podcast:
      appDelegate.player.setPlayerMode(.music)
    }
    refreshPlayerModeChangeButton()
  }

  func refreshView() {
    refreshPlayer()
  }

  func refreshPlayer() {
    playerHandler?.refreshSkipButtons(
      skipBackwardButton: skipBackwardButton,
      skipForwardButton: skipForwardButton
    )
    playerHandler?.refreshPlayButton(playButton)
    playerHandler?.refreshTimeInfo(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel,
      audioInfoLabel: audioInfoLabel,
      playTypeIcon: playTypeIcon,
      liveLabel: liveLabel
    )
    playerHandler?.refreshPrevNextButtons(previousButton: previousButton, nextButton: nextButton)
    playerHandler?.refreshDisplayPlaylistButton(displayPlaylistButton: displayPlaylistButton)
    refreshPlayerModeChangeButton()
  }

  func refreshPlayerModeChangeButton() {
    playerModeButton.isHidden = appDelegate.player.podcastItemCount == 0 && appDelegate.player
      .playerMode != .podcast
    switch player.playerMode {
    case .music:
      playerModeButton.setImage(UIImage.musicalNotes, for: .normal)
    case .podcast:
      playerModeButton.setImage(UIImage.podcast, for: .normal)
    }
    optionsStackView.layoutIfNeeded()
  }
}

// MARK: MusicPlayable

extension PlayerControlView: MusicPlayable {
  func didStartPlayingFromBeginning() {}

  func didStartPlaying() {
    refreshPlayer()
  }

  func didPause() {
    refreshPlayer()
  }

  func didStopPlaying() {
    refreshPlayer()
    playerHandler?.refreshSkipButtons(
      skipBackwardButton: skipBackwardButton,
      skipForwardButton: skipForwardButton
    )
  }

  func didElapsedTimeChange() {
    playerHandler?.refreshTimeInfo(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel,
      audioInfoLabel: audioInfoLabel,
      playTypeIcon: playTypeIcon,
      liveLabel: liveLabel
    )
  }

  func didPlaylistChange() {
    refreshPlayer()
  }

  func didArtworkChange() {}

  func didShuffleChange() {}

  func didRepeatChange() {}

  func didPlaybackRateChange() {}
}
