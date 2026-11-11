//
//  CarPlayNowPlayingExtension.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 31.01.24.
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
import CarPlay
import Foundation

extension CarPlaySceneDelegate {
  static let queueButtonText = NSLocalizedString(
    "Queue",
    comment: "Button title on CarPlay player to display queue"
  )

  func updatePlayerQueueSection() {
    // No car, no queue to draw: the player notifier can still fire during teardown.
    guard interfaceController != nil else { return }
    playerQueueSection.updateSections(createPlayerQueueSections())
  }

  func configureNowPlayingTemplate() {
    // The now-playing button SET depends ONLY on the player mode (music →
    // shuffle+repeat, podcast → repeat+playback-rate), never on the track. The
    // MusicPlayable.didStartPlaying observer calls this on every track change;
    // pushing a fresh button array via updateNowPlayingButtons then tears down and
    // recreates the button row, flashing the active repeat/shuffle selection and
    // re-rendering the template (which takes the scrubber with it). So rebuild the
    // buttons ONLY when the mode actually changes; otherwise the existing buttons
    // persist untouched and nothing flashes on a track advance.
    let mode = appDelegate.player.playerMode
    guard mode != lastConfiguredNowPlayingMode else { return }
    lastConfiguredNowPlayingMode = mode

    var buttons: [CPNowPlayingButton] = []
    let repeatButton = CPNowPlayingRepeatButton(handler: { [weak self] button in
      guard let self = self else { return }
      appDelegate.player.setRepeatMode(appDelegate.player.repeatMode.nextMode)
    })
    if appDelegate.player.playerMode == .music {
      // phone-taste: Shuffle first, then Repeat (the car mock's transport, and the usual
      // Shuffle-left, Repeat-right layout).
      buttons.append(
        CPNowPlayingShuffleButton(handler: { [weak self] button in
          guard let self = self else { return }
          appDelegate.player.toggleShuffle()
        })
      )
      buttons.append(repeatButton)
      // cassette (favorites rip-out): the CarPlay now-playing favorite (heart)
      // button was removed. Shuffle + repeat remain.
      // cassette (keep playing): ∞ after Repeat, as the phone's queue head has the three. Lit
      // while keep playing acts (on, repeat off); a press follows the phone's rule.
      let keepPlayingButton = CPNowPlayingImageButton(
        image: CassetteIcon.keepPlaying.symbolImage
      ) { [weak self] _ in
        self?.keepPlayingButtonPressed()
      }
      keepPlayingButton.isSelected = KeepPlaying.shared.isActive(repeatMode: appDelegate.player.repeatMode)
      keepPlayingNowPlayingButton = keepPlayingButton
      buttons.append(keepPlayingButton)
    } else {
      buttons.append(repeatButton)
      keepPlayingNowPlayingButton = nil
    }
    // Cassette CarPlay: the playback-speed multiplier only makes sense for
    // spoken-word content. Cassette surfaces podcasts as a real, playable
    // content type (separate `.podcast` player mode with its own persisted
    // `podcastPlaybackRate`), so expose the rate control ONLY while a podcast /
    // audiobook is the current Now Playing item — never for music, where a
    // speed control is just clutter that risks an accidental pitch-shift.
    if appDelegate.player.playerMode == .podcast {
      buttons.append(
        CPNowPlayingPlaybackRateButton(handler: { [weak self] button in
          guard let self = self else { return }
          let availablePlaybackRates: [CPListItem] = PlaybackRate.allCases
            .compactMap { playbackRate in
              let listItem = CPListItem(text: playbackRate.description, detailText: nil)
              listItem.handler = { [weak self] item, completion in
                guard let self = self else { completion(); return }
                appDelegate.player.setPlaybackRate(playbackRate)
                interfaceController?.popTemplate(animated: true) { _, _ in }
                completion()
              }
              return listItem
            }
          let playbackRateTemplate = CPListTemplate(title: "Playback Rate", sections: [
            CPListSection(items: availablePlaybackRates),
          ])
          pushTemplateIfAllowed(playbackRateTemplate, animated: true)

        })
      )
    }
    nowPlayingButtons = buttons
    CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    CPNowPlayingTemplate.shared.isUpNextButtonEnabled = true
    // cassette 2026-10-20 (driving pass): the artist and album line on Now Playing is a
    // button, and it opens the playing artist's page: get around from what is on.
    CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = mode == .music
  }

  /// The phone's rule (PlayerUIHandler.keepPlayingButtonPushed): while keep playing waits on
  /// repeat, a press turns repeat off so keep playing takes over; otherwise it flips the switch.
  func keepPlayingButtonPressed() {
    let keepPlaying = KeepPlaying.shared
    if keepPlaying.isOn, appDelegate.player.repeatMode != .off {
      appDelegate.player.setRepeatMode(.off)
    } else {
      keepPlaying.isOn.toggle()
    }
    refreshKeepPlayingButton()
  }

  /// Light the ∞ as keep playing and repeat now stand. Only when its state changed is the row
  /// handed to CarPlay again (with the same buttons), so a track change never redraws it.
  func refreshKeepPlayingButton() {
    guard interfaceController != nil, let button = keepPlayingNowPlayingButton else { return }
    let lit = KeepPlaying.shared.isActive(repeatMode: appDelegate.player.repeatMode)
    guard button.isSelected != lit else { return }
    button.isSelected = lit
    CPNowPlayingTemplate.shared.updateNowPlayingButtons(nowPlayingButtons)
  }

  /// Keep playing switched anywhere (posted on the main actor).
  @objc
  func keepPlayingChanged() {
    refreshKeepPlayingButton()
  }

  func displayNowPlaying(immediately: Bool = false, completion: @escaping (() -> ())) {
    configureNowPlayingTemplate()
    if immediately {
      interfaceController?
        .pushTemplate(CPNowPlayingTemplate.shared, animated: false) { _, _ in }
      completion()
    } else {
      Task { @MainActor in
        let _ = try? await interfaceController?.popToRootTemplate(animated: false)
        let _ = try? await self.interfaceController?
          .pushTemplate(CPNowPlayingTemplate.shared, animated: true)
        completion()
      }
    }
  }
}

// MARK: - CarPlaySceneDelegate + CPNowPlayingTemplateObserver

extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
  nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    MainActor.assumeIsolated {
      self.pushTemplateIfAllowed(playerQueueSection, animated: true)
    }
  }

  nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(
    _ nowPlayingTemplate: CPNowPlayingTemplate
  ) {
    MainActor.assumeIsolated {
      guard let song = self.appDelegate.player.currentlyPlaying?.asSong else { return }
      if let artist = song.artist,
         let template = self.makeArtistDetailTemplate(for: artist, onlyCached: self.isOfflineMode) {
        self.pushTemplateIfAllowed(template, animated: true)
      } else if let album = song.album {
        self.pushTemplateIfAllowed(
          self.makeAlbumDetailTemplate(for: album, onlyCached: self.isOfflineMode),
          animated: true
        )
      }
    }
  }

  func createPlayerQueueSections() -> [CPListSection] {
    var queueSection = [CPListSection]()
    // One leaf limit for the whole queue (both sections share the car's item count).
    let limit = carPlayLeafItemLimit(reserved: 0)

    let userQueueCount = appDelegate.player.userQueueCount
    let userQueueMax = min(userQueueCount - 1, limit - 1)
    let userQueue = appDelegate.player.getUserQueueItems(from: 0, to: userQueueMax)
    if userQueueCount > 0 {
      var userQueueItems = [CPListItem]()
      for (index, userQueueItem) in userQueue.enumerated() {
        let playerIndex = PlayerIndex(queueType: .user, index: index)
        let listItem = createQueueItem(for: userQueueItem, playerIndex: playerIndex)
        userQueueItems.append(listItem)
        if userQueueItems.count >= limit {
          break
        }
      }
      let userQueueSection = CPListSection(
        items: userQueueItems,
        header: "Next in Queue",
        sectionIndexTitle: nil
      )
      queueSection.append(userQueueSection)
    }

    if userQueueCount < limit {
      let nextQueueCount = appDelegate.player.nextQueueCount
      let nextQueueMax = min(nextQueueCount - 1, limit - 1)
      let nextQueue = appDelegate.player.getNextQueueItems(from: 0, to: nextQueueMax)
      if !nextQueue.isEmpty {
        var nextQueueItems = [CPListItem]()
        for (index, nextQueueItem) in nextQueue.enumerated() {
          let playerIndex = PlayerIndex(queueType: .next, index: index)
          let listItem = createQueueItem(for: nextQueueItem, playerIndex: playerIndex)
          nextQueueItems.append(listItem)
          if (userQueue.count + nextQueueItems.count) >= limit {
            break
          }
        }
        let nextQueueSection = CPListSection(
          items: nextQueueItems,
          header: "Next from: \(appDelegate.player.contextName)",
          sectionIndexTitle: nil
        )
        queueSection.append(nextQueueSection)
      }
    }
    return queueSection
  }

  private func createQueueItem(
    for playable: AbstractPlayable,
    playerIndex: PlayerIndex
  )
    -> CPListItem {
    // Cassette CarPlay: cloud/"cached" badge on queue rows gated to Server Mode.
    // In the default on-device-only experience the queue is local content, so
    // the badge is noise; in streaming mode it marks cached rows.
    let accessoryType: CPListItemAccessoryType = CassetteLibraryFilterProvider.shared
      .isOnDeviceOnly ? .none : (playable.isCached ? .cloud : .none)
    let image = style.artwork(
      for: playable,
      artworkDisplayPreference: getPreference(playable.account?.info).artworkDisplayPreference
    )
    let listItem = CPListItem(
      text: playable.title,
      detailText: playable.subtitle,
      image: image,
      accessoryImage: nil,
      accessoryType: accessoryType
    )
    listItem.handler = { [weak self] item, completion in
      guard let self = self else { completion(); return }
      appDelegate.player.play(playerIndex: playerIndex)
      Task { @MainActor in
        // Complete on every path: a pop that fails used to return early and leave the
        // tapped row spinning (CPS-8).
        _ = try? await interfaceController?.popTemplate(animated: true)
        completion()
      }
    }
    return listItem
  }
}

// MARK: - CarPlaySceneDelegate + MusicPlayable

extension CarPlaySceneDelegate: MusicPlayable {
  func didStartPlayingFromBeginning() {}
  func didStartPlaying() {
    configureNowPlayingTemplate()
    updatePlayerQueueSection()
  }

  func didPause() {}
  func didStopPlaying() {}
  func didElapsedTimeChange() {}
  func didPlaylistChange() {
    updatePlayerQueueSection()
    // phone-taste: something else started (or the queue was edited): a Mood door still
    // loading drops its result instead of taking over.
    noteQueueChangedForDoorLoad()
  }

  func didArtworkChange() {}
  func didShuffleChange() {}
  /// Repeat on holds keep playing back (its ∞ goes dark); repeat off lets it act again.
  func didRepeatChange() {
    refreshKeepPlayingButton()
  }
  func didPlaybackRateChange() {}
}

// MARK: - CarPlaySceneDelegate + CPSessionConfigurationDelegate

extension CarPlaySceneDelegate: CPSessionConfigurationDelegate {
  /// The car started or stopped limiting lists. Pages already on screen keep their form;
  /// the next page opened is built for the new state (see `isDriving`).
  nonisolated func sessionConfiguration(
    _ sessionConfiguration: CPSessionConfiguration,
    limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
  ) {
    let driving = limitedUserInterfaces.contains(.lists)
    MainActor.assumeIsolated {
      DiagnosticLog.shared.log(.carplay, "CarPlay lists limited", context: ["driving": String(driving)])
    }
  }
}
