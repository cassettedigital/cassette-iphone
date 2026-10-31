//
//  MiniPlayerView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 31.07.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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

// MARK: - MiniPlayerView

class MiniPlayerView: UIView {
  private var player: PlayerFacade
  private var playerHandler: PlayerUIHandler?

  private var hoverOverlayView: UIView?

  static let mediumButtonSize: CGFloat = 20.0

  #if targetEnvironment(macCatalyst) // ok
    var airplayVolume: MPVolumeView?
  #endif

  fileprivate lazy var artworkOverlay: UIView = {
    let view = UIView()
    // cassette Patch 033: drop pure black at 40% (which reads as a hard
    // grey on the mini-player's warm chrome). Use bg4 at 60% so the
    // overlay tints toward the Cassette neutral palette.
    view.backgroundColor = UIColor.cassette(.surfaceSunken).withAlphaComponent(0.6)
    view.isHidden = true

    let imageView = UIImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFit
    imageView.tintColor = .white
    imageView.image = .miniPlayer.withRenderingMode(.alwaysTemplate)

    view.addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      imageView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
      imageView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.8),
    ])

    return view
  }()

  fileprivate lazy var artworkImage: LibraryEntityImage = {
    let imageView = LibraryEntityImage(frame: .zero)
    imageView.backgroundColor = .clear
    #if targetEnvironment(macCatalyst) // ok
      artworkOverlay.translatesAutoresizingMaskIntoConstraints = false
      imageView.addSubview(artworkOverlay)
      NSLayoutConstraint.activate([
        artworkOverlay.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
        artworkOverlay.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
        artworkOverlay.widthAnchor.constraint(equalTo: imageView.widthAnchor),
        artworkOverlay.heightAnchor.constraint(equalTo: imageView.heightAnchor),
      ])

      imageView.isUserInteractionEnabled = true
      let miniPlayerHoverGesture = UIHoverGestureRecognizer(
        target: self,
        action: #selector(artworkHovered(_:))
      )
      let miniPlayerTapGesture = UITapGestureRecognizer(
        target: self,
        action: #selector(artworkClicked(_:))
      )
      imageView.addGestureRecognizer(miniPlayerTapGesture)
      imageView.addGestureRecognizer(miniPlayerHoverGesture)
    #endif
    return imageView
  }()

  fileprivate lazy var titleLabel: UILabel = {
    let label = MarqueeLabel(frame: .zero)
    label.applyAmperfyStyle()
    // cassette (I-M2): VoiceOver reaches Now Playing through the song's name: a double tap
    // lands on the view's own tap, which opens the player.
    label.accessibilityTraits.insert(.button)
    label.accessibilityHint = "Opens Now Playing"
    label.textAlignment = .center
    label.backgroundColor = .clear
    label.numberOfLines = 1
    // cassette: mini-player (liquid glass) typography, sized explicitly rather
    // than via the shared roles so the glass pill reads larger without lifting
    // those roles app-wide. Title 18pt Barlow; artist mono (see refreshForTraitChange).
    label.font = UIFont.cassetteDisplay(size: 18, weight: .semibold)
    label.textColor = UIColor.cassette(.textPrimary)
    return label
  }()

  fileprivate lazy var subtitleLabel: UILabel = {
    let label = MarqueeLabel(frame: .zero)
    label.applyAmperfyStyle()
    label.backgroundColor = .clear
    label.textAlignment = .center
    label.numberOfLines = 1
    // Quiet artist line - mono (matches album-card subtext).
    label.font = UIFont.cassetteMono(size: 14, weight: .regular)
    label.textColor = UIColor.cassette(.textSecondary)
    return label
  }()

  fileprivate lazy var timeSlider: SeekableTimeSlider = {
    let slider = SeekableTimeSlider(frame: .zero)
    slider.preferredBehavioralStyle = .pad
    // cassette Patch 046: set the scrubber's colours locally, so the global tint cascade
    // (ink) never reaches it. Its played part and thumb are the playing record's colour
    // (founder, 2026-10-21; was brand orange), kept current by `applyNowPlayingTint`, and
    // the unfilled track matches the popup player.
    slider.minimumTrackTintColor = CoverTint.nowPlaying.text
    slider.maximumTrackTintColor = UIColor.cassette(.hairline)
    slider.thumbTintColor = CoverTint.nowPlaying.text
    return slider
  }()

  @objc
  func artworkHovered(_ sender: UIHoverGestureRecognizer) {
    switch sender.state {
    case .began:
      artworkOverlay.isHidden = false
    case .cancelled, .ended, .failed:
      artworkOverlay.isHidden = true
    default:
      break
    }
  }

  @objc
  func artworkClicked(_ sender: UITapGestureRecognizer) {
    switch sender.state {
    case .ended:
      appDelegate.closeMainWindow()
      appDelegate.showMiniPlayer()
    default:
      break
    }
  }

  @objc
  func timeSliderChanged(_ slider: UISlider) {
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

  fileprivate lazy var elapsedTimeLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = UIColor.cassette(.textSecondary)
    label.font = UIFont.cassette(.metadata)
    return label
  }()

  fileprivate lazy var remainingTimeLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textAlignment = .right
    label.textColor = UIColor.cassette(.textSecondary)
    label.font = UIFont.cassette(.metadata)
    return label
  }()

  fileprivate lazy var liveLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.text = "LIVE"
    label.font = UIFont.cassette(.metadata)
    // cassette Patch 047 (Phase B): LIVE indicator drops to ink2. Orange is
    // reserved for the time scrubber sitting immediately behind this label;
    // doubling up made the label compete with the playback affordance.
    label.textColor = UIColor.cassette(.textSecondary)
    label.textAlignment = .center
    return label
  }()

  fileprivate lazy var audioInfoLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.font = UIFont.cassette(.metadata)
    label.textColor = UIColor.cassette(.textSecondary)
    return label
  }()

  fileprivate lazy var playTypeIcon: UIImageView = {
    let imageView = UIImageView(frame: .zero)
    imageView.tintColor = UIColor.cassette(.textSecondary)
    return imageView
  }()

  fileprivate lazy var moreButton: UIButton = {
    let button = UIButton()
    // A Lucide glyph ignores SymbolConfiguration, so this drew at its intrinsic 24pt beside
    // 17pt symbols (audit ICO-2); the registry draws it at the same size as its neighbours.
    button.setImage(CassetteIcon.more.uiImage(size: .control), for: .normal)
    button.imageView?.tintColor = UIColor.cassette(.textPrimary)
    button.showsMenuAsPrimaryAction = true
    return button
  }()

  fileprivate lazy var playButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .play
      .withConfiguration(
        UIImage
          .SymbolConfiguration(pointSize: PlayerUIHandler.playButtonImagePointSize)
      )
    let button = MiniPlayerKey(configuration: config)
    button.tintColor = UIColor.cassette(.textPrimary)
    button.accessibilityLabel = "Play"
    button.addTarget(self, action: #selector(Self.playButtonPushed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func playButtonPushed(_ sender: Any) {
    playerHandler?.playButtonPushed()
    playerHandler?.refreshPlayButton(playButton)
  }

  fileprivate lazy var previousButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .backwardFill.withConfiguration(UIImage.SymbolConfiguration(scale: .large))
    let button = MiniPlayerKey(configuration: config)
    button.accessibilityLabel = "Previous"
    button.tintColor = UIColor.cassette(.textPrimary)
    button.addTarget(self, action: #selector(Self.previousButtonPushed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func previousButtonPushed(_ sender: Any) {
    playerHandler?.previousButtonPushed()
    // Patch 113: optimistic label/cover update — the queue pointer advances
    // synchronously, so refresh from the new currently-playing item now rather
    // than waiting for the (async) didStartPlaying callback. Cover loads via
    // LibraryEntityImage (cache hit / placeholder + async swap; never blocks).
    refreshPlayer()
  }

  fileprivate lazy var nextButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .forwardFill.withConfiguration(UIImage.SymbolConfiguration(scale: .large))
    let button = MiniPlayerKey(configuration: config)
    button.tintColor = UIColor.cassette(.textPrimary)
    button.accessibilityLabel = "Next"
    button.addTarget(self, action: #selector(Self.nextButtonPushed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func nextButtonPushed(_ sender: Any) {
    playerHandler?.nextButtonPushed()
    // Patch 113: optimistic label/cover update (see previousButtonPushed).
    refreshPlayer()
  }

  fileprivate lazy var repeatButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .repeatMenu.withConfiguration(UIImage.SymbolConfiguration(scale: .medium))
    let button = UIButton(configuration: config)
    button.addTarget(self, action: #selector(Self.repeatButtonPushed), for: .touchUpInside)
    button
      .cornerConfiguration =
      .corners(radius: UICornerRadius(floatLiteral: Self.mediumButtonSize / 2))
    return button
  }()

  @IBAction
  func repeatButtonPushed(_ sender: Any) {
    playerHandler?.repeatButtonPushed()
    playerHandler?.refreshRepeatButton(repeatButton: repeatButton)
  }

  fileprivate lazy var shuffleButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .shuffle.withConfiguration(UIImage.SymbolConfiguration(scale: .medium))
    let button = UIButton(configuration: config)
    button.addTarget(self, action: #selector(Self.shuffleButtonPushed), for: .touchUpInside)
    button
      .cornerConfiguration =
      .corners(radius: UICornerRadius(floatLiteral: Self.mediumButtonSize / 2))
    return button
  }()

  @IBAction
  func shuffleButtonPushed(_ sender: Any) {
    playerHandler?.shuffleButtonPushed()
    playerHandler?.refreshShuffleButton(shuffleButton: shuffleButton)
  }

  fileprivate lazy var lyricsButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .lyrics
      .withConfiguration(
        UIImage
          .SymbolConfiguration(pointSize: PlayerUIHandler.bigButtonImagePointSize)
      )
    let button = UIButton(configuration: config)
    button.tintColor = UIColor.cassette(.textPrimary)
    button.addTarget(self, action: #selector(Self.lyricsPressed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func lyricsPressed() {
    appDelegate.storage.settings.user.isPlayerLyricsDisplayed.toggle()
    if appDelegate.storage.settings.user.isPlayerLyricsDisplayed {
      appDelegate.storage.settings.user.playerDisplayStyle = .large
    }
    playerHandler?.refreshDisplayLyrisButton(displayLyricsButton: lyricsButton)
    playerHandler?.refreshDisplayPlaylistButton(displayPlaylistButton: playlistButton)

    guard let host = AppDelegate.mainWindowHostVC as? SplitVC else { return }
    host.displayOrHideInspector()
  }

  fileprivate lazy var playlistButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .playlist
      .withConfiguration(
        UIImage
          .SymbolConfiguration(pointSize: PlayerUIHandler.bigButtonImagePointSize)
      )
    let button = UIButton(configuration: config)
    button.tintColor = UIColor.cassette(.textPrimary)
    button.addTarget(self, action: #selector(Self.playlistPressed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func playlistPressed() {
    appDelegate.storage.settings.user.playerDisplayStyle.switchToNextStyle()
    if appDelegate.storage.settings.user.playerDisplayStyle == .compact {
      appDelegate.storage.settings.user.isPlayerLyricsDisplayed = false
    }
    playerHandler?.refreshDisplayPlaylistButton(displayPlaylistButton: playlistButton)
    playerHandler?.refreshDisplayLyrisButton(displayLyricsButton: lyricsButton)

    guard let host = AppDelegate.mainWindowHostVC as? SplitVC else { return }
    host.displayOrHideInspector()
  }

  fileprivate lazy var airplayButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .airplayaudio
      .withConfiguration(
        UIImage
          .SymbolConfiguration(pointSize: PlayerUIHandler.bigButtonImagePointSize)
      )
    let button = UIButton(configuration: config)
    button.tintColor = UIColor.cassette(.textPrimary)
    button.addTarget(self, action: #selector(Self.airplayButtonPushed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func airplayButtonPushed(_ sender: UIButton) {
    #if targetEnvironment(macCatalyst) // ok
      playerHandler?.airplayButtonPushed(
        rootView: self,
        airplayButton: airplayButton,
        airplayVolume: airplayVolume
      )
    #endif
  }

  fileprivate lazy var volumeButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .volumeMax
      .withConfiguration(
        UIImage
          .SymbolConfiguration(pointSize: PlayerUIHandler.bigButtonImagePointSize)
      )
    let button = UIButton(configuration: config)
    button.tintColor = UIColor.cassette(.textPrimary)
    button.addTarget(self, action: #selector(Self.volumeButtonPushed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func volumeButtonPushed(_ sender: UIButton) {
    showVolumeSliderMenu()
  }

  public lazy var infoView: UIView = {
    let view = UIView(frame: .zero)

    self.titleLabel.translatesAutoresizingMaskIntoConstraints = false
    (subtitleLabel).translatesAutoresizingMaskIntoConstraints = false
    (artworkImage).translatesAutoresizingMaskIntoConstraints = false
    (moreButton).translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(titleLabel)
    view.addSubview(subtitleLabel)
    view.addSubview(artworkImage)
    view.addSubview(moreButton)

    NSLayoutConstraint.activate([
      artworkImage.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
      artworkImage.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
      artworkImage.widthAnchor.constraint(equalTo: artworkImage.heightAnchor),
      artworkImage.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      self.titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
      self.titleLabel.heightAnchor.constraint(equalTo: self.subtitleLabel.heightAnchor),
      self.titleLabel.leadingAnchor.constraint(equalTo: artworkImage.trailingAnchor, constant: 10),
      self.titleLabel.trailingAnchor.constraint(
        equalTo: self.moreButton.leadingAnchor,
        constant: 0
      ),
      self.subtitleLabel.topAnchor.constraint(equalTo: self.titleLabel.bottomAnchor),
      self.subtitleLabel.leadingAnchor.constraint(
        equalTo: self.artworkImage.trailingAnchor,
        constant: 10
      ),
      self.subtitleLabel.trailingAnchor.constraint(
        equalTo: self.moreButton.leadingAnchor,
        constant: 0
      ),
      self.subtitleLabel.bottomAnchor.constraint(
        equalTo: view.bottomAnchor,
        constant: -3
      ),

      self.moreButton.widthAnchor.constraint(equalToConstant: 30),
      self.moreButton.heightAnchor.constraint(equalToConstant: 30),
      self.moreButton.trailingAnchor.constraint(
        equalTo: view.trailingAnchor,
        constant: 0
      ),
      self.moreButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    return view
  }()

  public lazy var sliderAndinfoView: UIView = {
    let view = UIView(frame: .zero)

    let hoverContainer = UIView()

    self.infoView.translatesAutoresizingMaskIntoConstraints = false
    (timeSlider).translatesAutoresizingMaskIntoConstraints = false
    (liveLabel).translatesAutoresizingMaskIntoConstraints = false
    (hoverContainer).translatesAutoresizingMaskIntoConstraints = false

    let hoverGesture = UIHoverGestureRecognizer(
      target: self,
      action: #selector(handleHoverContainerHover(_:))
    )
    hoverContainer.addGestureRecognizer(hoverGesture)

    hoverContainer.addSubview(timeSlider)
    view.addSubview(infoView)
    view.addSubview(liveLabel)
    view.addSubview(hoverContainer)

    NSLayoutConstraint.activate([
      timeSlider.bottomAnchor.constraint(equalTo: hoverContainer.bottomAnchor, constant: -5),
      timeSlider.leadingAnchor.constraint(equalTo: hoverContainer.leadingAnchor),
      timeSlider.trailingAnchor.constraint(
        equalTo: hoverContainer.trailingAnchor,
        constant: 0
      ),
      timeSlider.heightAnchor.constraint(equalToConstant: 3),

      liveLabel.centerXAnchor.constraint(equalTo: timeSlider.centerXAnchor, constant: 0),
      liveLabel.centerYAnchor.constraint(equalTo: timeSlider.centerYAnchor, constant: 0),

      infoView.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
      infoView.bottomAnchor.constraint(equalTo: timeSlider.topAnchor, constant: -5),
      infoView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
      infoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      hoverContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0),
      hoverContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hoverContainer.trailingAnchor.constraint(
        equalTo: view.trailingAnchor,
        constant: 0
      ),
      hoverContainer.heightAnchor.constraint(equalToConstant: 17),
    ])

    return view
  }()

  public lazy var leadingButtonsView: UIView = {
    NSLayoutConstraint.activate([
      shuffleButton.heightAnchor.constraint(equalToConstant: Self.mediumButtonSize),
      shuffleButton.widthAnchor.constraint(equalTo: shuffleButton.heightAnchor, constant: 3),
      repeatButton.heightAnchor.constraint(equalToConstant: Self.mediumButtonSize),
      repeatButton.widthAnchor.constraint(equalTo: repeatButton.heightAnchor, constant: 3),
    ])

    self.shuffleButton.translatesAutoresizingMaskIntoConstraints = false
    self.previousButton.translatesAutoresizingMaskIntoConstraints = false
    self.playButton.translatesAutoresizingMaskIntoConstraints = false
    self.nextButton.translatesAutoresizingMaskIntoConstraints = false
    self.repeatButton.translatesAutoresizingMaskIntoConstraints = false

    let stack = UIStackView(arrangedSubviews: [
      shuffleButton,
      previousButton,
      playButton,
      nextButton,
      repeatButton,
    ])
    stack.axis = .horizontal
    stack.distribution = .equalSpacing
    stack.alignment = .center
    return stack
  }()

  public lazy var trailingButtonsView: UIStackView = {
    self.lyricsButton.translatesAutoresizingMaskIntoConstraints = false
    self.playlistButton.translatesAutoresizingMaskIntoConstraints = false
    self.airplayButton.translatesAutoresizingMaskIntoConstraints = false
    self.volumeButton.translatesAutoresizingMaskIntoConstraints = false

    let stack = UIStackView(arrangedSubviews: [
      lyricsButton,
      playlistButton,
      airplayButton,
      volumeButton,
    ])
    stack.axis = .horizontal
    stack.distribution = .equalSpacing
    stack.alignment = .center
    return stack
  }()

  public func refreshTrailingButtons() {
    guard let playerHandler else { return }
    if playerHandler.isLyricsButtonAllowedToDisplay {
      lyricsButton.isHidden = false
      trailingButtonsViewWidthConstraint?.constant = 140
    } else {
      lyricsButton.isHidden = true
      trailingButtonsViewWidthConstraint?.constant = 100
    }
  }

  func refreshMoreButton() {
    let currentlyPlaying = player.currentlyPlaying
    let hasPlayable = currentlyPlaying != nil

    moreButton.isEnabled = hasPlayable

    if let currentlyPlaying,
       let hostVC = AppDelegate.mainWindowHostVC as? UIViewController {
      moreButton.menu = UIMenu.lazyMenu {
        EntityPreviewActionBuilder(container: currentlyPlaying, on: hostVC).createMenuActions()
      }
    }
  }

  private var trailingButtonsViewWidthConstraint: NSLayoutConstraint?

  init(player: PlayerFacade) {
    self.player = player

    #if targetEnvironment(macCatalyst) // ok
      self.airplayVolume = MPVolumeView(frame: .zero)
      airplayVolume!.showsVolumeSlider = false
      airplayVolume!.isHidden = true
    #endif

    super.init(frame: .zero)
    #if targetEnvironment(macCatalyst) // ok
      addSubview(airplayVolume!)
    #endif

    player.addNotifier(notifier: self)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applyNowPlayingTint),
      name: .cassetteNowPlayingTintChanged,
      object: nil
    )

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.refreshPlayer()
      }
    )

    registerForTraitChanges([UITraitTabAccessoryEnvironment.self]) { (
      self: Self,
      previousTraitCollection: UITraitCollection
    ) in
      // cassette (rail): the pill itself is the same in both slots (see the
      // play button's trailing constraint in configureForiOS); only the host
      // (TabBarVC) has anything to do here, for its container constraints.
      self.tabAccessoryTraitChangeCB?()
    }
  }

  public var tabAccessoryTraitChangeCB: VoidFunctionCallback?

  public func configureForMac() {
    playerHandler = PlayerUIHandler(player: player, style: .miniPlayerMac)
    sliderAndinfoView.translatesAutoresizingMaskIntoConstraints = false
    leadingButtonsView.translatesAutoresizingMaskIntoConstraints = false
    trailingButtonsView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(sliderAndinfoView)
    addSubview(leadingButtonsView)
    addSubview(trailingButtonsView)

    trailingButtonsViewWidthConstraint = trailingButtonsView.widthAnchor
      .constraint(equalToConstant: 160)

    timeSlider.addTarget(self, action: #selector(timeSliderChanged(_:)), for: .valueChanged)
    timeSlider.addTarget(self, action: #selector(timeSliderIsChanging(_:)), for: .touchDragInside)
    timeSlider.addTarget(self, action: #selector(timeSliderIsChanging(_:)), for: .touchDragOutside)

    NSLayoutConstraint.activate([
      leadingButtonsView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      leadingButtonsView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
      leadingButtonsView.bottomAnchor.constraint(equalTo: bottomAnchor),
      leadingButtonsView.widthAnchor.constraint(equalToConstant: 150),

      sliderAndinfoView.leadingAnchor.constraint(
        equalTo: leadingButtonsView.trailingAnchor,
        constant: 10
      ),
      sliderAndinfoView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
      sliderAndinfoView.bottomAnchor.constraint(equalTo: bottomAnchor),
      sliderAndinfoView.trailingAnchor.constraint(
        equalTo: trailingButtonsView.leadingAnchor,
        constant: -10
      ),

      trailingButtonsView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
      trailingButtonsView.bottomAnchor.constraint(equalTo: bottomAnchor),
      trailingButtonsViewWidthConstraint!,
      trailingButtonsView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
    ])
    refreshPlayer()
  }

  public func configureForiOS() {
    playerHandler = PlayerUIHandler(player: player, style: .miniPlayeriOS)
    let miniPlayerGotTouchedView = UIView()
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(miniPlayerGotTouched))
    addGestureRecognizer(tapGesture)

    miniPlayerGotTouchedView.translatesAutoresizingMaskIntoConstraints = false
    artworkImage.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    timeSlider.translatesAutoresizingMaskIntoConstraints = false
    liveLabel.translatesAutoresizingMaskIntoConstraints = false
    playButton.translatesAutoresizingMaskIntoConstraints = false
    nextButton.translatesAutoresizingMaskIntoConstraints = false

    addSubview(miniPlayerGotTouchedView)
    addSubview(artworkImage)
    // cassette (BUG-420): title + artist in a stack with their own intrinsic
    // heights. The old layout split the pill on the play button's centre line
    // (8pt..centre for an 18pt face, centre..bottom-11 for a 14pt one), which
    // cut every descender: "My" read as "Mv", "playing" as "plavina".
    let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    textStack.axis = .vertical
    textStack.alignment = .fill
    textStack.spacing = 0
    // cassette (rail): the text sits against the cover, not centred in the
    // space left. The pill changes width when it moves between its two slots,
    // and centred text re-centres across that change, which UIKit's crossfade
    // shows as doubled words; leading text stays put beside the cover.
    titleLabel.textAlignment = .left
    subtitleLabel.textAlignment = .left
    // cassette (rail): no marquee in the pill. UIKit's morph crossfades a
    // snapshot of the pill into the live one, and a scrolling title is at one
    // offset in the snapshot and restarts from the start in the live label,
    // so the words doubled for the first frames of every move. A long title
    // truncates here, as in Music's pill; the full title is on the player.
    (titleLabel as? MarqueeLabel)?.labelize = true
    (subtitleLabel as? MarqueeLabel)?.labelize = true
    titleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.lineBreakMode = .byTruncatingTail
    textStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(textStack)
    addSubview(timeSlider)
    addSubview(liveLabel)
    addSubview(playButton)
    addSubview(nextButton)
    // cassette (BUG-420): the pill's scrubber is a 3pt track; a thumb at 0:00
    // hung off the capsule's bottom-left corner. No thumb on the phone pill
    // (the Mac mini player keeps its own layout).
    timeSlider.setThumbImage(UIImage(), for: .normal)

    NSLayoutConstraint.activate([
      miniPlayerGotTouchedView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
      miniPlayerGotTouchedView.heightAnchor.constraint(equalTo: heightAnchor),
      miniPlayerGotTouchedView.bottomAnchor.constraint(equalTo: bottomAnchor),
      miniPlayerGotTouchedView.trailingAnchor.constraint(
        equalTo: playButton.leadingAnchor,
        constant: -8
      ),

      // cassette (BUG-420): inset by the capsule radius so the track runs
      // along the pill's straight edge instead of under its curve.
      timeSlider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
      timeSlider.heightAnchor.constraint(equalToConstant: 3),
      timeSlider.bottomAnchor.constraint(equalTo: bottomAnchor),
      timeSlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

      liveLabel.centerXAnchor.constraint(equalTo: timeSlider.centerXAnchor, constant: 0),
      liveLabel.centerYAnchor.constraint(equalTo: timeSlider.centerYAnchor, constant: 0),
      liveLabel.widthAnchor.constraint(equalToConstant: 0),
      liveLabel.heightAnchor.constraint(equalTo: liveLabel.widthAnchor),

      // cassette (BUG-420): the cover is a square inset 8pt top and bottom and
      // 14pt from the leading edge, clear of the 24pt capsule curve that used
      // to shave its corners at 10pt.
      artworkImage.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      artworkImage.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      artworkImage.widthAnchor.constraint(equalTo: artworkImage.heightAnchor),
      artworkImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

      textStack.leadingAnchor.constraint(equalTo: artworkImage.trailingAnchor, constant: 10),
      textStack.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -8),
      textStack.centerYAnchor.constraint(equalTo: artworkImage.centerYAnchor),
      textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 3),
      textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -3),

      playButton.centerYAnchor.constraint(equalTo: artworkImage.centerYAnchor, constant: 0),
      playButton.widthAnchor.constraint(equalToConstant: 30),
      playButton.heightAnchor.constraint(equalTo: playButton.widthAnchor),
      // cassette (rail): the pill is ONE capsule in both of its slots, the
      // floating one above the bar and the inline one inside the minimized
      // bar. Measured on 26.4 at 60fps: the minimized bar gives the accessory
      // no glass of its own (the slot between the tab circle and the search
      // circle is transparent), so an inline layout that dropped our glass,
      // the artist line, the scrubber and the next button sent the cover,
      // title and play button naked onto the scrolling covers on every swipe
      // down, and UIKit's morph then crossfaded that bare one-line snapshot
      // into the full pill on every reveal. That was the "collapses and
      // breaks for a beat". Same elements, same glass, same constraints in
      // both states: the morph is a capsule changing width and nothing else.
      playButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -5),

      nextButton.centerYAnchor.constraint(equalTo: artworkImage.centerYAnchor, constant: 0),
      nextButton.widthAnchor.constraint(equalToConstant: 30),
      nextButton.heightAnchor.constraint(equalTo: nextButton.widthAnchor),
      nextButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
    ])
    refreshPlayer()
    refreshForTraitChange(horizontalSizeClass: traitCollection.horizontalSizeClass)
  }

  public func refreshForTraitChange(horizontalSizeClass: UIUserInterfaceSizeClass) {
    // Barlow title + mono artist. Re-stamp on trait change so IB/size-class
    // shifts can't leave a mixed face on the pill.
    titleLabel.font = UIFont.cassetteDisplay(size: 18, weight: .semibold)
    subtitleLabel.font = UIFont.cassetteMono(size: 14, weight: .regular)
  }

  @objc
  private func miniPlayerGotTouched(_ recognizer: UITapGestureRecognizer) {
    openPlayerView()
  }

  public func openPlayerView(completion: (() -> ())? = nil) {
    guard let hostVC = AppDelegate.mainWindowHostVC as? UIViewController else { return }
    let popupPlayer = PopupPlayerVC()
    // Now Playing stays the dim room lit by the cover in both looks, as Apple Music's player
    // does (2026-10-31, I-T1); the rest of the app follows light or dark.
    popupPlayer.overrideUserInterfaceStyle = .dark
    popupPlayer.modalPresentationStyle = .pageSheet
    if let sheet = popupPlayer.sheetPresentationController {
      sheet.detents = [.large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 24
    }
    hostVC.present(popupPlayer, animated: true, completion: completion)
  }

  @objc
  private func handleHoverContainerHover(_ recognizer: UIHoverGestureRecognizer) {
    switch recognizer.state {
    case .began, .changed:
      if hoverOverlayView == nil {
        showHoverOverlay()
      }
    case .cancelled, .ended:
      hideHoverOverlay()
    default:
      break
    }
  }

  private func showHoverOverlay() {
    guard hoverOverlayView == nil, liveLabel.isHidden else { return }
    let overlay = createHoverOverlayView()
    addSubview(overlay)
    // Position overlay above artwork/title/subtitle area
    overlay.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      overlay.leadingAnchor.constraint(equalTo: infoView.leadingAnchor, constant: 0),
      overlay.trailingAnchor.constraint(equalTo: infoView.trailingAnchor, constant: 0),
      overlay.topAnchor.constraint(equalTo: infoView.topAnchor, constant: 0),
      overlay.heightAnchor.constraint(equalTo: infoView.heightAnchor),
    ])
    hoverOverlayView = overlay
  }

  private func hideHoverOverlay() {
    guard let overlay = hoverOverlayView else { return }
    overlay.removeFromSuperview()
    hoverOverlayView = nil
    infoView.layer.mask = nil
  }

  private func createHoverOverlayView() -> UIView {
    // make the info view transparent
    let mask = CAGradientLayer()
    mask.frame = infoView.bounds
    mask.colors = [
      UIColor.white.withAlphaComponent(0).cgColor,
      UIColor.white.withAlphaComponent(0).cgColor,
    ]
    mask.startPoint = CGPoint(x: 0.0, y: 0.0)
    mask.endPoint = CGPoint(x: 1.0, y: 0.0)
    mask.locations = [
      0.0, 1.0,
    ]
    infoView.layer.mask = mask

    let overlay = UIView()
    overlay.isUserInteractionEnabled = false

    let innerView = UIView(frame: .zero)
    innerView.addSubview(playTypeIcon)
    innerView.addSubview(audioInfoLabel)

    let outerView = UIView(frame: .zero)
    outerView.addSubview(innerView)

    overlay.addSubview(elapsedTimeLabel)
    overlay.addSubview(outerView)
    overlay.addSubview(remainingTimeLabel)

    innerView.translatesAutoresizingMaskIntoConstraints = false
    outerView.translatesAutoresizingMaskIntoConstraints = false
    elapsedTimeLabel.translatesAutoresizingMaskIntoConstraints = false
    playTypeIcon.translatesAutoresizingMaskIntoConstraints = false
    audioInfoLabel.translatesAutoresizingMaskIntoConstraints = false
    remainingTimeLabel.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      playTypeIcon.leadingAnchor.constraint(equalTo: innerView.leadingAnchor, constant: 0),
      playTypeIcon.centerYAnchor.constraint(equalTo: innerView.centerYAnchor, constant: 0),
      playTypeIcon.trailingAnchor.constraint(equalTo: audioInfoLabel.leadingAnchor, constant: -8),
      playTypeIcon.widthAnchor.constraint(equalToConstant: 14),
      playTypeIcon.heightAnchor.constraint(equalToConstant: 14),
      audioInfoLabel.centerYAnchor.constraint(equalTo: innerView.centerYAnchor, constant: 0),
      audioInfoLabel.trailingAnchor.constraint(equalTo: innerView.trailingAnchor, constant: 0),

      innerView.centerXAnchor.constraint(equalTo: outerView.centerXAnchor, constant: 0),
      innerView.centerYAnchor.constraint(equalTo: outerView.centerYAnchor, constant: 0),
      innerView.heightAnchor.constraint(equalTo: outerView.heightAnchor, constant: 0),

      outerView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: 0),
      outerView.heightAnchor.constraint(equalTo: overlay.heightAnchor, constant: 0),
      elapsedTimeLabel.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 0),
      elapsedTimeLabel.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: 0),
      elapsedTimeLabel.widthAnchor.constraint(equalToConstant: 60),
      outerView.leadingAnchor.constraint(equalTo: elapsedTimeLabel.trailingAnchor, constant: 0),
      outerView.trailingAnchor.constraint(equalTo: remainingTimeLabel.leadingAnchor, constant: 0),
      remainingTimeLabel.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: 0),
      remainingTimeLabel.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: 0),
      remainingTimeLabel.widthAnchor.constraint(equalToConstant: 60),
    ])
    return overlay
  }

  /// Reads the playing record's colour into `CoverTint.nowPlaying` (the bars on its row and
  /// both scrubbers), the way Now Playing reads it; neutral with no cover on disk. The mini
  /// player is up whenever something plays, so it keeps the colour current on every track.
  private func refreshNowPlayingTint() {
    guard let path = nowPlayingCoverPath() else {
      CoverTint.nowPlaying = .neutral
      return
    }
    Task { @MainActor [weak self] in
      let tint = await CoverTint.resolve(coverPath: path) ?? .neutral
      // A newer track may have started while the cover was read.
      guard let self, self.nowPlayingCoverPath() == path else { return }
      CoverTint.nowPlaying = tint
    }
  }

  private func nowPlayingCoverPath() -> String? {
    guard let playable = player.currentlyPlaying else { return nil }
    let setting = appDelegate.storage.settings.accounts.getSetting(playable.account?.info).read
    guard let path = playable.imagePath(setting: setting.artworkDisplayPreference),
          FileManager.default.fileExists(atPath: path)
    else { return nil }
    return path
  }

  @objc
  private func applyNowPlayingTint() {
    timeSlider.minimumTrackTintColor = CoverTint.nowPlaying.text
    timeSlider.thumbTintColor = CoverTint.nowPlaying.text
  }

  func refreshPlayer() {
    // cassette Patch 016: hold the Cassette ink tokens regardless of the
    // system's reported userInterfaceStyle (the app is forced dark anyway).
    titleLabel.textColor = UIColor.cassette(.textPrimary)
    subtitleLabel.textColor = UIColor.cassette(.textSecondary)
    playerHandler?.refreshCurrentlyPlayingInfo(
      artworkImage: artworkImage,
      titleLabel: titleLabel,
      artistLabel: subtitleLabel,
      albumLabel: nil,
      albumButton: nil,
      albumContainerView: nil
    )
    playerHandler?.refreshArtwork(artworkImage: artworkImage)
    refreshNowPlayingTint()
    playerHandler?.refreshPlayButton(playButton)
    playerHandler?.refreshPrevNextButtons(previousButton: previousButton, nextButton: nextButton)
    // a station: no Next here either (it changed station), as on the full player
    nextButton.isHidden = appDelegate.player.currentlyPlaying?.isRadio == true
    playerHandler?.refreshDisplayPlaylistButton(displayPlaylistButton: playlistButton)
    playerHandler?.refreshRepeatButton(repeatButton: repeatButton)
    playerHandler?.refreshShuffleButton(shuffleButton: shuffleButton)
    playerHandler?.refreshTimeInfo(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel,
      audioInfoLabel: audioInfoLabel,
      playTypeIcon: playTypeIcon,
      liveLabel: liveLabel
    )
    refreshMoreButton()
    refreshTrailingButtons()
    playablePresenceChangeCB?()
  }

  /// cassette 2026-10-20: told after every refresh, so the host can hide the pill while
  /// nothing is queued (TabBarVC.refreshMiniPlayerPresence) instead of showing a
  /// "No music playing" bar with buttons that do nothing.
  public var playablePresenceChangeCB: VoidFunctionCallback?

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private lazy var miniPlayerGlassEffect: UIGlassEffect = {
    let glassEffect = UIGlassEffect(style: .regular)
    glassEffect.isInteractive = false
    return glassEffect
  }()

  public lazy var glassContainer: UIVisualEffectView = {
    let container = UIVisualEffectView()
    container.effect = miniPlayerGlassEffect
    container.contentView.addSubview(self)

    container.translatesAutoresizingMaskIntoConstraints = false
    self.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
      container.trailingAnchor.constraint(equalTo: trailingAnchor),
      container.topAnchor.constraint(equalTo: topAnchor, constant: 0),
      container.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    return container
  }()

  func showVolumeSliderMenu() {
    let popoverContentController = SliderMenuPopover()
    let sliderMenuView = popoverContentController.sliderMenuView
    sliderMenuView.frame = CGRect(x: 0, y: 0, width: 250, height: 50)

    sliderMenuView.slider.minimumValue = 0
    sliderMenuView.slider.maximumValue = 100
    sliderMenuView.slider.value = appDelegate.player.volume * 100

    sliderMenuView.sliderValueChangedCB = {
      self.appDelegate.player.volume = Float(sliderMenuView.slider.value) / 100.0
    }

    popoverContentController.modalPresentationStyle = .popover
    popoverContentController.preferredContentSize = sliderMenuView.frame.size

    if let popoverPresentationController = popoverContentController.popoverPresentationController {
      popoverPresentationController.permittedArrowDirections = .up
      popoverPresentationController.delegate = popoverContentController
      popoverPresentationController.sourceView = volumeButton
      (AppDelegate.mainWindowHostVC as? UIViewController)?.present(
        popoverContentController,
        animated: true,
        completion: nil
      )
    }
  }
}

// MARK: MusicPlayable

extension MiniPlayerView: MusicPlayable {
  func didStartPlayingFromBeginning() {}

  func didStartPlaying() {
    refreshPlayer()
  }

  func didPause() {
    refreshPlayer()
  }

  func didStopPlaying() {
    refreshPlayer()
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

  func didArtworkChange() {
    playerHandler?.refreshCurrentlyPlayingInfo(
      artworkImage: artworkImage,
      titleLabel: titleLabel,
      artistLabel: subtitleLabel,
      albumLabel: nil,
      albumButton: nil,
      albumContainerView: nil
    )
  }

  func didNowPlayingInfoChange() {
    playerHandler?.refreshCurrentlyPlayingInfo(
      artworkImage: artworkImage,
      titleLabel: titleLabel,
      artistLabel: subtitleLabel,
      albumLabel: nil,
      albumButton: nil,
      albumContainerView: nil
    )
  }

  func didShuffleChange() {
    playerHandler?.refreshShuffleButton(shuffleButton: shuffleButton)
  }

  func didRepeatChange() {
    playerHandler?.refreshRepeatButton(repeatButton: repeatButton)
  }

  func didPlaybackRateChange() {}
}

// MARK: - MiniPlayerKey

/// cassette (I-M2): the mini player's 30pt keys answer a touch anywhere in a 44pt square, Apple's
/// smallest target, without growing what's drawn (Play and Next sit 5pt apart, so their squares
/// meet in the middle and each still gets the half nearest it).
private final class MiniPlayerKey: UIButton {
  private static let minimumHitSide: CGFloat = 44

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let dx = max(0, (Self.minimumHitSide - bounds.width) / 2)
    let dy = max(0, (Self.minimumHitSide - bounds.height) / 2)
    return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
  }
}
