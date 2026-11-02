//
//  PlayerUIHandler.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 01.08.25.
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
import MediaPlayer
import UIKit

// MARK: - PlayerUIStyle

enum PlayerUIStyle {
  case miniPlayerMac
  case popupPlayer
  case miniPlayeriOS
}

// MARK: - PlayerUIHandler

@MainActor
class PlayerUIHandler: NSObject {
  public static let playButtonImagePointSize: CGFloat = 25
  public static let bigButtonImagePointSize: CGFloat = 17
  public static let playAndNextiOSButtonImagePointSize: CGFloat = 15

  private var player: PlayerFacade
  private var style: PlayerUIStyle

  init(player: PlayerFacade, style: PlayerUIStyle) {
    self.player = player
    self.style = style
  }

  func playButtonPushed() {
    player.togglePlayPause()
  }

  func skipBackwardButtonPushed() {
    player.skipBackward(interval: player.skipBackwardMusicInterval)
  }

  func skipForwardButtonPushed() {
    player.skipForward(interval: player.skipForwardMusicInterval)
  }

  func previousButtonPushed() {
    switch player.playerMode {
    case .music:
      player.playPreviousOrReplay()
    case .podcast:
      player.skipBackward(interval: player.skipBackwardPodcastInterval)
    }
  }

  func nextButtonPushed() {
    switch player.playerMode {
    case .music:
      player.playNext()
    case .podcast:
      player.skipForward(interval: player.skipForwardPodcastInterval)
    }
  }

  func shuffleButtonPushed() {
    player.toggleShuffle()
  }

  func repeatButtonPushed() {
    player.setRepeatMode(player.repeatMode.nextMode)
  }

  func refreshPlayButton(_ button: UIButton) {
    var buttonImg = UIImage()
    if player.isPlaying {
      if player.isStopInsteadOfPause {
        buttonImg = UIImage.stop
      } else {
        buttonImg = UIImage.pause
      }
    } else {
      buttonImg = UIImage.play
    }

    switch style {
    case .miniPlayerMac:
      buttonImg = buttonImg
        .withConfiguration(UIImage.SymbolConfiguration(pointSize: Self.playButtonImagePointSize))
    case .miniPlayeriOS:
      buttonImg = buttonImg
        .withConfiguration(
          UIImage
            .SymbolConfiguration(pointSize: Self.playAndNextiOSButtonImagePointSize)
        )
    case .popupPlayer:
      break
    }

    button.setImage(buttonImg, for: UIControl.State.normal)
    button.configuration?.image = buttonImg
    // cassette (I-M2): VoiceOver says what the key does now.
    button.accessibilityLabel = player.isPlaying ? (player.isStopInsteadOfPause ? "Stop" : "Pause") : "Play"
  }

  func refreshSkipButtons(skipBackwardButton: UIButton, skipForwardButton: UIButton) {
    switch player.playerMode {
    case .music:
      skipBackwardButton.isHidden = !appDelegate.storage.settings.user.isShowMusicPlayerSkipButtons
      skipBackwardButton.isEnabled = player.isSkipAvailable
      skipBackwardButton.alpha = !appDelegate.storage.settings.user
        .isShowMusicPlayerSkipButtons ? 0.0 : 1.0
      skipForwardButton.isHidden = !appDelegate.storage.settings.user.isShowMusicPlayerSkipButtons
      skipForwardButton.isEnabled = player.isSkipAvailable
      skipForwardButton.alpha = !appDelegate.storage.settings.user
        .isShowMusicPlayerSkipButtons ? 0.0 : 1.0
    case .podcast:
      skipBackwardButton.isHidden = true
      skipBackwardButton.isEnabled = true
      skipForwardButton.isHidden = true
      skipForwardButton.isEnabled = true
    }
  }

  func refreshPrevNextButtons(previousButton: UIButton, nextButton: UIButton) {
    previousButton.imageView?.contentMode = .scaleAspectFit
    nextButton.imageView?.contentMode = .scaleAspectFit

    var previouseImg = UIImage()
    var nextImg = UIImage()
    switch player.playerMode {
    case .music:
      previouseImg = UIImage.backwardFill
      nextImg = UIImage.forwardFill
    case .podcast:
      previouseImg = UIImage.goBackward15
      nextImg = UIImage.goForward30
    }

    switch style {
    case .miniPlayerMac:
      previouseImg = previouseImg.withConfiguration(UIImage.SymbolConfiguration(scale: .medium))
      nextImg = nextImg.withConfiguration(UIImage.SymbolConfiguration(scale: .medium))
    case .popupPlayer:
      break
    case .miniPlayeriOS:
      previouseImg = previouseImg
        .withConfiguration(
          UIImage
            .SymbolConfiguration(pointSize: Self.playAndNextiOSButtonImagePointSize)
        )
      nextImg = nextImg
        .withConfiguration(
          UIImage
            .SymbolConfiguration(pointSize: Self.playAndNextiOSButtonImagePointSize)
        )
    }

    previousButton.setImage(previouseImg, for: UIControl.State.normal)
    previousButton.configuration?.image = previouseImg
    nextButton.setImage(nextImg, for: UIControl.State.normal)
    nextButton.configuration?.image = nextImg
  }

  func refreshRepeatButton(repeatButton: UIButton) {
    let isSelected = player.repeatMode != .off
    repeatButton.accessibilityLabel = "Repeat"
    repeatButton.accessibilityValue = switch player.repeatMode {
    case .off: "Off"
    case .all: "All"
    case .single: "One song"
    }
    var image: UIImage?
    switch player.repeatMode {
    case .off:
      image = .repeatMenu
    case .all:
      image = .repeatAll
    case .single:
      image = .repeatOne
    }

    switch style {
    case .miniPlayeriOS, .miniPlayerMac:
      // cassette Patch 047 (Phase B): port popup `.player(isSelected:)`
      // semantics to the mini player toggles. Selected = ink-filled pill
      // with the symbol painted in `bg`; unselected = ink-tinted symbol
      // on a clear background. Replaces the prior orange tint + 20%
      // orange wash so the mini chrome reads neutral.
      repeatButton.configuration?.image = image?
        .withConfiguration(UIImage.SymbolConfiguration(scale: .medium))
      repeatButton.tintColor = isSelected ? UIColor.cassette(.textOnFill) : UIColor.cassette(.textPrimary)
      repeatButton.backgroundColor = isSelected ? UIColor.cassette(.fillSelected) : .clear
    case .popupPlayer:
      // Keep playing (founder, 2026-11-02): shuffle, repeat and keep playing are one row
      // with one rule, so repeat lights orange when on like the other two.
      Self.applyQueueToggle(
        repeatButton,
        image: player.repeatMode == .single ? .repeatOne : .repeatAll,
        state: isSelected ? .on : .off
      )
      return
    }
    repeatButton.isSelected = isSelected
  }

  /// The queue head's three toggles (shuffle, repeat, keep playing): what each one shows.
  enum QueueToggleState {
    case off
    case on
    /// Keep playing while repeat is on: switched on, but repeat wins, so it waits.
    case waiting
  }

  /// One rule for the queue head's toggles (founder, 2026-11-02): the same bare 20pt
  /// symbol, quiet when off, orange when on (`.accentProgress`), faint while waiting, and
  /// never a box. `isSelected` stays false on purpose: a selected system button paints its
  /// own grey square behind the glyph (the "brutal" box on the founder's phone), so the
  /// state is told to VoiceOver as a trait instead.
  static func applyQueueToggle(_ button: UIButton, image: CassetteIcon, state: QueueToggleState) {
    var config = UIButton.Configuration.playerQuietToggle(
      isOn: state == .on,
      onColor: UIColor.cassette(.accentProgress)
    )
    if state == .waiting {
      config.baseForegroundColor = UIColor.cassette(.textTertiary)
    }
    // Three in a row beside the heading: a touch under the 20pt quiet toggle, so the
    // record's name keeps its room.
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17)
    config.image = image.symbolImage
    button.configuration = config
    button.configurationUpdateHandler = { button in
      button.configuration?.background = .clear()
    }
    button.isSelected = false
    if state == .on {
      button.accessibilityTraits.insert(.selected)
    } else {
      button.accessibilityTraits.remove(.selected)
    }
  }

  /// Keep playing: on, waiting while repeat is on, or off. A tap while it waits turns
  /// repeat off (keep playing takes over), as Apple Music's Autoplay does.
  func refreshKeepPlayingButton(keepPlayingButton: UIButton) {
    let keepPlaying = KeepPlaying.shared
    let state: QueueToggleState = !keepPlaying.isOn
      ? .off
      : (player.repeatMode == .off ? .on : .waiting)
    keepPlayingButton.accessibilityLabel = "Keep playing"
    keepPlayingButton.accessibilityValue = switch state {
    case .off: "Off"
    case .on: "On"
    case .waiting: "Waiting while repeat is on"
    }
    Self.applyQueueToggle(keepPlayingButton, image: .keepPlaying, state: state)
  }

  func keepPlayingButtonPushed() {
    let keepPlaying = KeepPlaying.shared
    if keepPlaying.isOn, player.repeatMode != .off {
      player.setRepeatMode(.off)
    } else {
      keepPlaying.isOn.toggle()
    }
  }

  func refreshShuffleButton(shuffleButton: UIButton) {
    shuffleButton.accessibilityLabel = "Shuffle"
    shuffleButton.accessibilityValue = player.isShuffle ? "On" : "Off"
    // phone-taste (live-state-orange): Shuffle on is live state, so its glyph lights orange
    // on a clear ground in every player. Off, the popup glyph is a quiet ink2; the mini
    // players keep today's ink so it matches the repeat toggle beside it.
    var config = UIButton.Configuration.playerShuffle(isOn: player.isShuffle)
    switch style {
    case .miniPlayeriOS, .miniPlayerMac:
      // The mini players keep their own glyph size and off colour (restyling them is a
      // separate pass); only Shuffle on changes, to orange.
      let medium = UIImage.SymbolConfiguration(scale: .medium)
      config.preferredSymbolConfigurationForImage = medium
      config.image = .shuffle.withConfiguration(medium)
      if !player.isShuffle {
        config.baseForegroundColor = UIColor.cassette(.textPrimary)
      }
      shuffleButton.configuration = config
      shuffleButton.backgroundColor = .clear
    case .popupPlayer:
      Self.applyQueueToggle(shuffleButton, image: .shuffle, state: player.isShuffle ? .on : .off)
      shuffleButton.isEnabled = appDelegate.storage.settings.user.isPlayerShuffleButtonEnabled
      return
    }
    shuffleButton.isEnabled = appDelegate.storage.settings.user.isPlayerShuffleButtonEnabled
    shuffleButton.isSelected = player.isShuffle
  }

  func refreshDisplayPlaylistButton(displayPlaylistButton: UIButton) {
    let isSelected = appDelegate.storage.settings.user.playerDisplayStyle == .compact

    switch style {
    case .miniPlayeriOS, .miniPlayerMac:
      // cassette Patch 047 (Phase B): selected = ink fill + bg glyph; unselected
      // = ink glyph on clear. Matches refreshRepeatButton / refreshShuffleButton.
      displayPlaylistButton.tintColor = isSelected ? UIColor.cassette(.textOnFill) : UIColor.cassette(.textPrimary)
      displayPlaylistButton.backgroundColor = isSelected ? UIColor.cassette(.fillSelected) : .clear
    case .popupPlayer:
      var config = UIButton.Configuration.player(isSelected: isSelected)
      config.image = .playlistDisplayStyle
      // phone-taste (foot-row): unselected, the queue glyph is ink2 like AirPlay beside it;
      // selected, it keeps the ink fill with a dark glyph.
      if !isSelected {
        config.baseForegroundColor = UIColor.cassette(.textSecondary)
      }
      displayPlaylistButton.isSelected = isSelected
      displayPlaylistButton.configuration = config
    }
  }

  func refreshDisplayLyrisButton(displayLyricsButton: UIButton) {
    let isSelected = appDelegate.storage.settings.user.isPlayerLyricsDisplayed

    switch style {
    case .miniPlayeriOS, .miniPlayerMac:
      // cassette Patch 047 (Phase B): see refreshDisplayPlaylistButton.
      displayLyricsButton.tintColor = isSelected ? UIColor.cassette(.textOnFill) : UIColor.cassette(.textPrimary)
      displayLyricsButton.backgroundColor = isSelected ? UIColor.cassette(.fillSelected) : .clear
    case .popupPlayer:
      break
    }
  }

  func refreshPlayerOptions(
    optionsButton: UIButton?,
    menuCreateCB: @escaping () -> [UIMenuElement]
  ) {
    optionsButton?.showsMenuAsPrimaryAction = true
    optionsButton?.menu = UIMenu.lazyMenu(title: "Player Options") {
      menuCreateCB()
    }
  }

  func refreshCurrentlyPlayingInfo(
    artworkImage: LibraryEntityImage,
    titleLabel: UILabel,
    artistLabel: UILabel,
    albumLabel: UILabel? = nil,
    albumButton: UIButton? = nil,
    albumContainerView: UIView? = nil
  ) {
    refreshArtwork(artworkImage: artworkImage)
    if let playableInfo = player.currentlyPlaying {
      if playableInfo.isRadio {
        // For radios, show stream metadata if available, otherwise show station name
        if let radioInfo = player.currentRadioNowPlaying, !radioInfo.isEmpty {
          titleLabel.text = radioInfo.title
          artistLabel.text = radioInfo.artist
        } else {
          titleLabel.text = playableInfo.title
          artistLabel.text = ""
        }
        // Station name in the album label, then the cloud's show and "until …
        // then …" when it knows them (cassette 2026-10-21).
        albumLabel?.text = [playableInfo.title, player.currentRadioDetail].compactMap { $0 }
          .joined(separator: " · ")
        albumButton?.isEnabled = false
        albumContainerView?.isHidden = false
      } else {
        titleLabel.text = playableInfo.title
        albumLabel?.text = playableInfo.asSong?.album?.name ?? ""
        albumButton?.isEnabled = playableInfo.isSong
        albumContainerView?.isHidden = !playableInfo.isSong
        artistLabel.text = playableInfo.creatorName
      }
    } else {
      switch player.playerMode {
      case .music:
        titleLabel.text = "No music playing"
      case .podcast:
        titleLabel.text = "No podcast playing"
      }
      albumLabel?.text = ""
      albumButton?.isEnabled = false
      albumContainerView?.isHidden = true
      artistLabel.text = ""
    }
  }

  func refreshArtwork(artworkImage: LibraryEntityImage) {
    if let playableInfo = player.currentlyPlaying {
      if playableInfo.isRadio, let liveArt = player.currentRadioArtwork {
        // cassette: the song's cover or the show's picture, from the cloud.
        artworkImage.display(image: liveArt)
        return
      }
      // cassette (BUG-751, the founder 2026-10-31): a station with no cover for what's on
      // shows its own mark (logo, else word art), never an empty square.
      if let radio = playableInfo.asRadio {
        artworkImage.display(image: RadioMark.image(for: radio, loadIfNeeded: { [weak self, weak artworkImage] in
          guard let self, let artworkImage else { return }
          refreshArtwork(artworkImage: artworkImage)
        }).image)
        return
      }
      artworkImage.display(entity: playableInfo)
    } else {
      switch player.playerMode {
      case .music:
        artworkImage.display(
          artworkType: .song
        )
      case .podcast:
        artworkImage.display(
          artworkType: .podcastEpisode
        )
      }
    }
  }

  func airplayButtonPushed(
    rootView: UIView,
    airplayButton: UIButton,
    airplayVolume: MPVolumeView? = nil
  ) {
    appDelegate.userStatistics.usedAction(.airplay)

    #if targetEnvironment(macCatalyst) // ok
      guard let airplayVolume else { return }
      // Position the popup correctly on macOS
      if let buttonCenter = airplayButton.superview?.convert(airplayButton.center, to: rootView) {
        airplayVolume.center = buttonCenter
      }

      for view: UIView in airplayVolume.subviews {
        if let button = view as? UIButton {
          button.sendActions(for: .touchUpInside)
          break
        }
      }
    #else
      let rect = CGRect(x: -100, y: 0, width: 0, height: 0)
      let airplayVolume = MPVolumeView(frame: rect)
      airplayVolume.showsVolumeSlider = false
      rootView.addSubview(airplayVolume)
      for view: UIView in airplayVolume.subviews {
        if let button = view as? UIButton {
          button.sendActions(for: .touchUpInside)
          break
        }
      }
      airplayVolume.removeFromSuperview()
    #endif
  }

  var isLyricsButtonAllowedToDisplay: Bool {
    // cassette polish Part 2: gated behind Cassette.lyricsEnabled.
    Cassette.lyricsEnabled && appDelegate.player.playerMode == .music && appDelegate.storage
      .settings.accounts
      .availableApiTypes.contains(.subsonic)
  }

  private var remainingTime: Int? {
    let duration = player.duration
    if player.currentlyPlaying != nil, duration.isNormal, !duration.isZero {
      return Int(player.elapsedTime - ceil(player.duration))
    }
    return nil
  }

  /// The song's length in whole seconds, when there is a song with a known length.
  private var songLength: Int? {
    let duration = player.duration
    if player.currentlyPlaying != nil, duration.isNormal, !duration.isZero {
      return Int(ceil(duration))
    }
    return nil
  }

  /// The right-hand time. phone-taste (time-right-length): the player sheet shows the
  /// song's length ("3:34"), as the mock does; the mini players keep the countdown.
  private var rightTimeText: String {
    switch style {
    case .popupPlayer:
      guard let songLength else { return "--:--" }
      return ClockTime(timeInSeconds: songLength).asShortString()
    case .miniPlayeriOS, .miniPlayerMac:
      guard let remainingTime else { return "--:--" }
      return ClockTime(timeInSeconds: remainingTime).asShortString()
    }
  }

  func timeSliderChanged(timeSlider: UISlider) {
    player.seek(toSecond: Double(timeSlider.value))
  }

  func timeSliderIsChanging(
    timeSlider: UISlider,
    elapsedTimeLabel: UILabel,
    remainingTimeLabel: UILabel
  ) {
    let elapsedClockTime = ClockTime(timeInSeconds: Int(timeSlider.value))
    elapsedTimeLabel.text = elapsedClockTime.asShortString()
    switch style {
    case .popupPlayer:
      // phone-taste: the length does not change while scrubbing.
      remainingTimeLabel.text = rightTimeText
    case .miniPlayeriOS, .miniPlayerMac:
      let remainingTime =
        ClockTime(timeInSeconds: Int(Double(timeSlider.value) - ceil(player.duration)))
      remainingTimeLabel.text = remainingTime.asShortString()
    }
  }

  // cassette polish Part 1: audioInfoLabel + playTypeIcon (the "MP3 2658 kbps"
  // line beneath the scrubber) are removed from the popup player. The params
  // are optional so the bitrate strip can be dropped from the hierarchy while
  // the Mac hover overlay still passes real labels.
  func refreshTimeInfo(
    timeSlider: UISlider,
    elapsedTimeLabel: UILabel,
    remainingTimeLabel: UILabel,
    audioInfoLabel: UILabel?,
    playTypeIcon: UIImageView?,
    liveLabel: UILabel
  ) {
    timeSlider.preferredBehavioralStyle = .pad
    timeSlider.sliderStyle = .thumbless
    if let currentlyPlaying = player.currentlyPlaying {
      let supportTimeInteraction = !currentlyPlaying.isRadio
      timeSlider.isEnabled = supportTimeInteraction && (style != .miniPlayeriOS)
      timeSlider.minimumValue = 0.0
      timeSlider.maximumValue = Float(player.duration)
      if !timeSlider.isTracking, supportTimeInteraction {
        let elapsedClockTime = ClockTime(timeInSeconds: Int(player.elapsedTime))
        elapsedTimeLabel.text = elapsedClockTime.asShortString()
        remainingTimeLabel.text = rightTimeText
        timeSlider.value = Float(player.elapsedTime)
      }

      if !supportTimeInteraction {
        audioInfoLabel?.isHidden = true
        playTypeIcon?.isHidden = true
        liveLabel.isHidden = false
        // a station: no empty track, the word LIVE after a dot in the live orange (the founder,
        // 2026-10-31: the radio sheet read as an empty album player)
        // set once: a label's new text asks for layout, and this runs on every refresh
        if style == .popupPlayer, liveLabel.attributedText?.string != "● LIVE" {
          timeSlider.alpha = 0
          let live = NSMutableAttributedString(
            string: "● ",
            attributes: [.foregroundColor: UIColor.cassette(.accentProgress), .font: liveLabel.font as Any]
          )
          live.append(NSAttributedString(
            string: "LIVE",
            attributes: [.foregroundColor: UIColor.cassette(.textSecondary), .font: liveLabel.font as Any, .kern: 1.2]
          ))
          liveLabel.attributedText = live
        }
        timeSlider.minimumValue = 0.0
        timeSlider.maximumValue = 1.0
        timeSlider.value = 0.0

        // make the middle part of the time slider transparent
        let mask = CAGradientLayer()
        mask.frame = timeSlider.bounds
        mask.colors = [
          UIColor.white.cgColor,
          UIColor.white.withAlphaComponent(0).cgColor,
          UIColor.white.withAlphaComponent(0).cgColor,
          UIColor.white.cgColor,
        ]
        mask.startPoint = CGPoint(x: 0.0, y: 0.0)
        mask.endPoint = CGPoint(x: 1.0, y: 0.0)
        mask.locations = [
          0.0, 0.4, 0.6, 1.0,
        ]
        timeSlider.layer.mask = mask

        elapsedTimeLabel.text = ""
        remainingTimeLabel.text = ""
      } else {
        audioInfoLabel?.isHidden = false
        playTypeIcon?.isHidden = false
        refreshAudioInfo(
          currentlyPlaying: currentlyPlaying,
          audioInfoLabel: audioInfoLabel,
          playTypeIcon: playTypeIcon
        )

        liveLabel.isHidden = true
        timeSlider.alpha = 1
        timeSlider.layer.mask = nil
      }
    } else {
      audioInfoLabel?.isHidden = true
      playTypeIcon?.isHidden = true
      liveLabel.isHidden = true
      timeSlider.layer.mask = nil
      elapsedTimeLabel.text = "--:--"
      remainingTimeLabel.text = "--:--"
      timeSlider.isEnabled = false
      timeSlider.minimumValue = 0.0
      timeSlider.maximumValue = 1.0
      timeSlider.value = 0.0
    }
  }

  private func refreshAudioInfo(
    currentlyPlaying: AbstractPlayable,
    audioInfoLabel: UILabel?,
    playTypeIcon: UIImageView?
  ) {
    guard let audioInfoLabel, let playTypeIcon else { return }
    guard let playType = player.playType else {
      playTypeIcon.image = nil
      playTypeIcon.isHidden = true
      audioInfoLabel.isHidden = true
      return
    }
    playTypeIcon.isHidden = false
    audioInfoLabel.isHidden = false
    var displayBitrateInKbps = 0
    var formatText = ""

    func getFormat(contentType: String?) -> String {
      guard let contentType else { return "" }
      var contentFormatText = ""
      // Display MIME type: "audio/mp3" -> "MP3"
      let components = contentType.split(separator: "/")
      if components.count > 1 {
        let format = String(components[1]).uppercased()
        // Format for display
        switch format {
        case "MP3", "MPEG":
          contentFormatText = "MP3"
        default:
          if format.contains("LOSSLESS") {
            contentFormatText = "LOSSLESS"
          } else if format.hasPrefix("X-"), format.count > "X-".count {
            contentFormatText = String(format.dropFirst("X-".count))
          } else {
            contentFormatText = format
          }
        }
      }
      return contentFormatText
    }

    if playType == .cache {
      playTypeIcon.image = UIImage.cache
      displayBitrateInKbps = currentlyPlaying.bitrate / 1000
      formatText = getFormat(contentType: currentlyPlaying.fileContentType)
    } else {
      playTypeIcon.image = UIImage.antenna
      let streamingBitrate = player.activeStreamingBitrate
      if let streamingBitrate {
        if streamingBitrate == .noLimit ||
          (streamingBitrate.rawValue > (currentlyPlaying.bitrate / 1000)) {
          displayBitrateInKbps = currentlyPlaying.bitrate / 1000
        } else {
          displayBitrateInKbps = streamingBitrate.rawValue
        }
      } else {
        displayBitrateInKbps = 0
      }

      let transcodingFormat = player.activeTranscodingFormat
      if let transcodingFormat {
        if transcodingFormat == .raw {
          // it is the format of the streamed file
          formatText = getFormat(contentType: currentlyPlaying.contentType)
        } else {
          formatText = transcodingFormat.shortInfo
        }
      } else {
        formatText = ""
      }
    }

    audioInfoLabel
      .text = (displayBitrateInKbps > 0) ? "\(formatText) \(displayBitrateInKbps) kbps" :
      "\(formatText)"
    playTypeIcon.tintColor = UIColor.cassette(.textSecondary)
  }
}
