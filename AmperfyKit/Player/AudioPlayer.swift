//
//  AudioPlayer.swift
//  AmperfyKit
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

import AVFoundation
import Foundation
import MediaPlayer
import os.log
import UIKit

// MARK: - WeakMusicPlayable

final class WeakMusicPlayable {
  weak var value: MusicPlayable?
  init(_ value: MusicPlayable) {
    self.value = value
  }
}

// MARK: - AudioPlayer

@MainActor
public class AudioPlayer: NSObject, BackendAudioPlayerNotifiable {
  public static let replayInsteadPlayPreviousTimeInSec = 5.0
  static let progressTimeStartThreshold: Double = 15.0
  static let progressTimeEndThreshold: Double = 15.0

  var currentlyPlaying: AbstractPlayable? {
    queueHandler.currentlyPlaying
  }

  var currentMusicItem: AbstractPlayable? {
    queueHandler.currentMusicItem
  }

  var currentPodcastItem: AbstractPlayable? {
    queueHandler.currentPodcastItem
  }

  var isShouldPauseAfterFinishedPlaying = false

  private var playerStatus: PlayerStatusPersistent
  private var queueHandler: PlayQueueHandler
  private let backendAudioPlayer: BackendAudioPlayer
  private let settings: AmperfySettings
  private let userStatistics: UserStatistics
  private var notifierList: [WeakMusicPlayable] = []
  /// What the stream itself says is playing (its in-band StreamTitle).
  private var streamNowPlaying: RadioNowPlayingInfo?
  private var lastRadioStreamTitle: String?
  /// cassette: what the cloud says is on, and its picture (see RadioLiveInfo).
  public private(set) var radioLive: RadioLiveInfo?
  public private(set) var radioLiveArtwork: UIImage?

  /// The station's song or show for every surface: the cloud's song first,
  /// then the in-stream title, then the show itself (title = show, artist =
  /// host). An in-stream title that only repeats the show's name is skipped.
  public var currentRadioNowPlaying: RadioNowPlayingInfo? {
    if let live = radioLive, let song = live.songTitle, !song.isEmpty {
      return RadioNowPlayingInfo(title: song, artist: live.songArtist ?? "")
    }
    let show = radioLive?.show ?? ""
    if let stream = streamNowPlaying, !stream.isEmpty,
       show.isEmpty || stream.title.caseInsensitiveCompare(show) != .orderedSame {
      return stream
    }
    if !show.isEmpty {
      return RadioNowPlayingInfo(title: show, artist: radioLive?.host ?? "")
    }
    return streamNowPlaying
  }

  /// The line under it: the show (when a song leads), then when it ends and
  /// what comes next. Nil when the cloud has nothing to add.
  public var currentRadioDetail: String? {
    guard let live = radioLive else { return nil }
    let leading = currentRadioNowPlaying?.title ?? ""
    let show = live.show.flatMap { $0.caseInsensitiveCompare(leading) == .orderedSame ? nil : $0 }
    let parts = [show, live.whenLine].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// cassette: the app's radio feed hands over what the cloud knows, for the
  /// station at `streamUrl`. Ignored if another station is playing by now; nil
  /// clears it.
  public func setRadioLive(_ info: RadioLiveInfo?, artwork: UIImage?, forStreamUrl streamUrl: String?) {
    if info != nil {
      guard let radio = currentlyPlaying?.asRadio, radio.url == streamUrl else { return }
    }
    let artChanged = radioLive?.artworkURL != info?.artworkURL || (radioLiveArtwork == nil) != (artwork == nil)
    guard info != radioLive || artChanged else { return }
    radioLive = info
    radioLiveArtwork = info == nil ? nil : artwork
    notifyNowPlayingInfoChanged()
    if artChanged { notifyArtworkChanged() }
  }

  init(
    coreData: PlayerStatusPersistent,
    queueHandler: PlayQueueHandler,
    backendAudioPlayer: BackendAudioPlayer,
    settings: AmperfySettings,
    userStatistics: UserStatistics
  ) {
    self.playerStatus = coreData
    self.queueHandler = queueHandler
    self.backendAudioPlayer = backendAudioPlayer
    self.backendAudioPlayer.isAutoCachePlayedItems = coreData.isAutoCachePlayedItems
    self.settings = settings
    self.userStatistics = userStatistics
    super.init()
    self.backendAudioPlayer.responder = self
    self.backendAudioPlayer.nextPlayablePreloadCB = { () in
      guard !self.isShouldPauseAfterFinishedPlaying else { return nil }
      guard self.playerStatus.repeatMode != .single else { return nil }
      guard let nextPlayerIndex = self.nextPlayerIndex else { return nil }
      return self.queueHandler.getPlayable(at: nextPlayerIndex)
    }
  }

  private func shouldCurrentItemReplayedInsteadOfPrevious() -> Bool {
    if let currentlyPlaying = currentlyPlaying,
       currentlyPlaying.isRadio {
      return false
    }
    if !backendAudioPlayer.canBeContinued {
      return false
    }
    return backendAudioPlayer.elapsedTime >= Self.replayInsteadPlayPreviousTimeInSec
  }

  private func replayCurrentItem() {
    os_log(.debug, "Replay")
    if let currentPlayable = currentlyPlaying {
      insertIntoPlayer(playable: currentPlayable)
    }
    notifyItemStartedPlayingFromBeginning()
  }

  private func insertIntoPlayer(playable: AbstractPlayable) {
    userStatistics.playedItem(
      repeatMode: playerStatus.repeatMode,
      isShuffle: playerStatus.isShuffle
    )
    // Patch 113 (step 3a): defer the play-count write off the synchronous skip
    // path. countPlayed mutates lastTimePlayed/playCount on the main Core Data
    // context, which cascades NSFetchedResultsController reloads (Home
    // "Recent", ArtistDetail "Popular", library lists) — that must not block
    // the tap. Counting a beat later (next main-actor turn) is fine: the write
    // and the resulting shelf updates still happen, just not inline with the
    // skip. Stays on the main context (no cross-context races).
    Task { @MainActor in playable.countPlayed() }
    // cassette (keep playing): the queue's last song is starting, so the pick is worked out
    // now rather than in the gap after it.
    if queueHandler.nextQueueCount == 0, queueHandler.userQueueCount == 0,
       playerStatus.playerMode == .music, !playable.isRadio,
       KeepPlaying.shared.isActive(repeatMode: playerStatus.repeatMode) {
      KeepPlaying.shared.prepare(queue: keepPlayingQueue)
    }
    backendAudioPlayer.requestToPlay(
      playable: playable,
      playbackRate: playerStatus.playbackRate,
      autoStartPlayback: !settings.user.isPlaybackStartOnlyOnPlay
    )
  }

  // BackendAudioPlayerNotifiable
  func notifyItemPreparationFinished() {
    handleRadioStartIfNeeded()
    notifyItemStartedPlayingFromBeginning()
    notifyItemStartedPlaying()
  }

  // BackendAudioPlayerNotifiable
  func didItemFinishedPlaying() {
    if isShouldPauseAfterFinishedPlaying {
      isShouldPauseAfterFinishedPlaying = false
      pause()
    } else if playerStatus
      .repeatMode == .single ||
      (
        // repeat mode all and only one song is in player -> repeat
        playerStatus.repeatMode == .all && queueHandler.prevQueueCount == 0 && queueHandler
          .userQueueCount == 0 && queueHandler
          .nextQueueCount == 0
      ) {
      replayCurrentItem()
    } else if !settings.user.isPlaybackStartOnlyOnPlay {
      playNext()
    }
  }

  func play() {
    if !backendAudioPlayer.canBeContinued {
      if let currentPlayable = currentlyPlaying {
        insertIntoPlayer(playable: currentPlayable)
      }
    } else {
      backendAudioPlayer.continuePlay()
      notifyItemStartedPlaying()
    }
  }

  public func play(context: PlayContext) {
    guard let activePlayable = context.getActivePlayable() else { return }
    let topUserQueueItem = queueHandler.getUserQueueItem(at: 0)
    let wasUserQueuePlaying = queueHandler.isUserQueuePlaying
    queueHandler.clearActiveQueue()
    queueHandler.appendActiveQueue(playables: context.playables)
    if context.type == .music {
      queueHandler.setContextName(context.name)
      KeepPlaying.shared.noteStarted(playables: context.playables)
    }

    if queueHandler.isUserQueuePlaying {
      play(playerIndex: PlayerIndex(queueType: .next, index: context.index))
      if !wasUserQueuePlaying, let topUserQueueItem = topUserQueueItem {
        queueHandler.insertUserQueue(playables: [topUserQueueItem])
      }
    } else if context.index == 0 {
      insertIntoPlayer(playable: activePlayable)
    } else {
      play(playerIndex: PlayerIndex(queueType: .next, index: context.index - 1))
    }
  }

  func play(playerIndex: PlayerIndex) {
    guard let playable = queueHandler.markAndGetPlayableAsPlaying(at: playerIndex) else {
      stop()
      return
    }
    insertIntoPlayer(playable: playable)
  }

  /// cassette (BUG-437): drop every queued item `isRejected` matches, so the player never
  /// holds songs that are not on the phone (a queue saved before a removal, or from Server
  /// Mode). If the current item goes, it stops and the next kept item becomes current
  /// without starting playback; with nothing left, the queue clears and the player stops.
  /// Returns whether anything changed.
  @discardableResult
  func removeQueuedItems(where isRejected: (AbstractPlayable) -> Bool) -> Bool {
    var changed = false
    func prune(_ type: PlayerQueueType, _ items: [AbstractPlayable]) {
      for index in items.indices.reversed() where isRejected(items[index]) {
        queueHandler.removePlayable(at: PlayerIndex(queueType: type, index: index))
        changed = true
      }
    }
    prune(.user, queueHandler.getAllUserQueueItems())
    prune(.next, queueHandler.getAllNextQueueItems())
    prune(.prev, queueHandler.getAllPrevQueueItems())

    if let current = queueHandler.currentlyPlaying, isRejected(current) {
      backendAudioPlayer.stop()
      let currentID = current.objectID
      if let next = nextPlayerIndex, queueHandler.markAndGetPlayableAsPlaying(at: next) != nil {
        // The old item now sits behind (or, with repeat, ahead of) the new current one.
        if let index = queueHandler.getAllPrevQueueItems().lastIndex(where: { $0.objectID == currentID }) {
          queueHandler.removePlayable(at: PlayerIndex(queueType: .prev, index: index))
        } else if let index = queueHandler.getAllNextQueueItems().firstIndex(where: { $0.objectID == currentID }) {
          queueHandler.removePlayable(at: PlayerIndex(queueType: .next, index: index))
        }
      } else {
        queueHandler.removeAllItems()
        playerStatus.stop()
      }
      notifyPlayerStopped()
      changed = true
    }
    if changed { notifyPlaylistUpdated() }
    return changed
  }

  func playPreviousOrReplay() {
    if shouldCurrentItemReplayedInsteadOfPrevious() {
      replayCurrentItem()
    } else {
      playPrevious()
    }
  }

  // BackendAudioPlayerNotifiable
  func playPrevious() {
    if queueHandler.prevQueueCount > 0 {
      play(playerIndex: PlayerIndex(queueType: .prev, index: queueHandler.prevQueueCount - 1))
    } else if playerStatus.repeatMode == .all, queueHandler.nextQueueCount > 0 {
      play(playerIndex: PlayerIndex(queueType: .next, index: queueHandler.nextQueueCount - 1))
    } else {
      replayCurrentItem()
    }
  }

  // BackendAudioPlayerNotifiable
  func playNext() {
    if let nextPlayerIndex = nextPlayerIndex {
      play(playerIndex: nextPlayerIndex)
    } else if appendKeepPlaying() {
      play(playerIndex: PlayerIndex(queueType: .next, index: 0))
    } else {
      stop()
    }
  }

  /// cassette (keep playing): the queue as KeepPlaying reads it.
  var keepPlayingQueue: KeepPlaying.Queue {
    KeepPlaying.Queue(
      prev: queueHandler.getAllPrevQueueItems(),
      current: queueHandler.currentlyPlaying,
      user: queueHandler.getAllUserQueueItems(),
      next: queueHandler.getAllNextQueueItems()
    )
  }

  /// cassette (keep playing): the queue has run out, so append what KeepPlaying picks (an
  /// album names the queue after itself). Music only, never after a station, never with
  /// repeat on. Returns whether anything was appended; it then sits at the head of the
  /// next queue.
  @discardableResult
  func appendKeepPlaying() -> Bool {
    guard playerStatus.playerMode == .music,
          KeepPlaying.shared.isActive(repeatMode: playerStatus.repeatMode),
          currentlyPlaying?.isRadio != true,
          let pick = KeepPlaying.shared.take(queue: keepPlayingQueue)
    else { return false }
    queueHandler.appendActiveQueue(playables: pick.songs)
    // An album names the queue after itself; songs from all over have no one name, so the
    // head reads just UP NEXT rather than the playlist they came after.
    queueHandler.setContextName(pick.album?.name ?? "")
    notifyPlaylistUpdated()
    return queueHandler.nextQueueCount > 0
  }

  private var nextPlayerIndex: PlayerIndex? {
    if queueHandler.userQueueCount > 0 {
      return PlayerIndex(queueType: .user, index: 0)
    } else if queueHandler.nextQueueCount > 0 {
      return PlayerIndex(queueType: .next, index: 0)
    } else if playerStatus.repeatMode == .all, queueHandler.prevQueueCount > 0 {
      return PlayerIndex(queueType: .prev, index: 0)
    } else {
      return nil
    }
  }

  func pause() {
    if let currentlyPlaying = currentlyPlaying,
       currentlyPlaying.isRadio {
      stopButRemainIndex()
    } else {
      backendAudioPlayer.pause()
      notifyItemPaused()
    }
  }

  // BackendAudioPlayerNotifiable
  func stop() {
    backendAudioPlayer.stop()
    playerStatus.stop()
    notifyPlayerStopped()
  }

  func stopButRemainIndex() {
    backendAudioPlayer.stop()
    notifyPlayerStopped()
  }

  func togglePlayPause() {
    if backendAudioPlayer.isPlaying {
      pause()
    } else {
      play()
    }
  }

  private func seekToLastStoppedPlayTime() {
    if let playable = currentlyPlaying,
       playable.playProgress > 0,
       playable
       .isPodcastEpisode ||
       (
         (playable.isSong || backendAudioPlayer.isErrorOccurred) && settings.user
           .isPlayerSongPlaybackResumeEnabled
       ) {
      backendAudioPlayer.seek(toSecond: Double(playable.playProgress))
    }
  }

  // BackendAudioPlayerNotifiable
  func didElapsedTimeChange() {
    notifyElapsedTimeChanged()
    if let currentItem = currentlyPlaying {
      savePlayInformation(of: currentItem)
    }
  }

  // BackendAudioPlayerNotifiable
  func didLyricsTimeChange(time: CMTime) {
    notifyLyricsTimeChanged(time: time)
  }

  // BackendAudioPlayerNotifiable
  func didReadStreamMetadata(_ metadata: [String: String]) {
    guard let radio = currentlyPlaying?.asRadio else { return }
    updateRadioNowPlaying(from: metadata, radio: radio)
  }

  private func savePlayInformation(of playable: AbstractPlayable) {
    let playDuration = backendAudioPlayer.duration
    let playProgress = backendAudioPlayer.elapsedTime
    if playDuration != 0.0, playProgress != 0.0, playable == currentlyPlaying {
      playable.playDuration = Int(playDuration)
      if playProgress > Self.progressTimeStartThreshold,
         playProgress < (playDuration - Self.progressTimeEndThreshold) {
        playable.playProgress = Int(playProgress)
      } else {
        playable.playProgress = 0
      }
    }
  }

  var audioAnalyzer: AudioAnalyzer { backendAudioPlayer.audioAnalyzer }

  // cassette (BUG-426): an object already registered is skipped, so a caller that registers
  // on every connect (CarPlay) is notified once per event, not once per connect.
  func addNotifier(notifier: MusicPlayable) {
    notifierList = notifierList.filter { $0.value != nil }
    guard !notifierList.contains(where: { $0.value === notifier }) else { return }
    notifierList.append(WeakMusicPlayable(notifier))
  }

  func removeNotifier(notifier: MusicPlayable) {
    notifierList = notifierList.filter { $0.value != nil && $0.value !== notifier }
  }

  func removeAllNotifier() {
    notifierList.removeAll()
  }

  func notifyItemStartedPlayingFromBeginning() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didStartPlayingFromBeginning()
    }
    seekToLastStoppedPlayTime()
  }

  func notifyItemStartedPlaying() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didStartPlaying()
    }
  }

  // BackendAudioPlayerNotifiable
  func notifyErrorOccurred(error: Error) {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.errorOccurred(error: error)
    }
  }

  func notifyItemPaused() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didPause()
    }
  }

  func notifyPlayerStopped() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didStopPlaying()
    }
  }

  func notifyArtworkChanged() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didArtworkChange()
    }
  }

  func notifyElapsedTimeChanged() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didElapsedTimeChange()
    }
  }

  func notifyLyricsTimeChanged(time: CMTime) {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didLyricsTimeChange(time: time)
    }
  }

  func notifyPlaylistUpdated() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didPlaylistChange()
    }
  }

  func notifyNowPlayingInfoChanged() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didNowPlayingInfoChange()
    }
  }

  func notifyShuffleUpdated() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didShuffleChange()
    }
  }

  func notifyRepeatUpdated() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didRepeatChange()
    }
  }

  func notifyPlaybackRateUpdated() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didPlaybackRateChange()
    }
  }

  private func handleRadioStartIfNeeded() {
    guard currentlyPlaying?.asRadio != nil else {
      if streamNowPlaying != nil || radioLive != nil {
        streamNowPlaying = nil
        lastRadioStreamTitle = nil
        radioLive = nil
        radioLiveArtwork = nil
        notifyNowPlayingInfoChanged()
      }
      return
    }

    streamNowPlaying = nil
    lastRadioStreamTitle = nil
    radioLive = nil
    radioLiveArtwork = nil
    notifyNowPlayingInfoChanged()
  }

  private func updateRadioNowPlaying(from metadata: [String: String], radio: Radio) {
    guard let currentRadio = currentlyPlaying?.asRadio,
          currentRadio.managedObject == radio.managedObject else { return }
    let streamTitleKey = metadata.keys.first { $0.lowercased() == "streamtitle" }
    guard let streamTitleKey,
          let rawStreamTitle = metadata[streamTitleKey]
    else { return }
    let streamTitle = rawStreamTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !streamTitle.isEmpty else { return }
    guard streamTitle != lastRadioStreamTitle else { return }

    // cassette (BUG-758): between songs some stations send their own name, often with a dangling
    // separator ("The Current-"). That isn't a song: the line falls back to the station's own.
    if Self.isStationName(streamTitle, radio: radio) {
      lastRadioStreamTitle = streamTitle
      if streamNowPlaying != nil {
        streamNowPlaying = nil
        notifyNowPlayingInfoChanged()
      }
      return
    }

    let parsedInfo = parseStreamTitle(streamTitle)
    guard let parsedInfo, !parsedInfo.isEmpty else { return }

    lastRadioStreamTitle = streamTitle
    streamNowPlaying = parsedInfo
    notifyNowPlayingInfoChanged()
  }

  /// The quotes and separators a stream title can be left with at either end ("The Current-", "- KEXP |").
  private static let dangling = CharacterSet.whitespacesAndNewlines
    .union(CharacterSet(charactersIn: "\"'-–—|·:"))

  /// Whether a stream title is only the station's own name, once its dangling separators are gone.
  static func isStationName(_ streamTitle: String, radio: Radio) -> Bool {
    let squash = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
    let left = squash(streamTitle.trimmingCharacters(in: dangling))
    let name = squash(radio.title)
    return !left.isEmpty && left == name
  }

  private func parseStreamTitle(_ streamTitle: String) -> RadioNowPlayingInfo? {
    let cleaned = streamTitle.trimmingCharacters(in: Self.dangling)
    let parts = cleaned.components(separatedBy: " - ")
    if parts.count >= 2 {
      let artist = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let title = parts.dropFirst().joined(separator: " - ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return RadioNowPlayingInfo(title: title, artist: artist)
    }
    return RadioNowPlayingInfo(title: cleaned, artist: "")
  }
}
