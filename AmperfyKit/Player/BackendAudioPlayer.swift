//
//  BackendAudioPlayer.swift
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

import AudioStreaming
import AVFoundation
import Foundation
import os.log
import UIKit

// MARK: - BackendAudioPlayerNotifiable

@MainActor
protocol BackendAudioPlayerNotifiable {
  func didElapsedTimeChange()
  func didLyricsTimeChange(time: CMTime) // high refresh count
  func stop()
  func playPrevious()
  func playNext()
  func didItemFinishedPlaying()
  func notifyItemPreparationFinished()
  func notifyErrorOccurred(error: Error)
  func didReadStreamMetadata(_ metadata: [String: String])
}

// MARK: - AudioStreamingPlayer

public class AudioStreamingPlayer: AudioStreaming.AudioPlayer {
  /// cassette: the buffer the dial needs. The library's defaults start after
  /// ONE second of audio and resume after one second following a dropout, so
  /// a live stream over a wobbly connection stuttered. Local and cached songs
  /// fill these from disk instantly, so they are unaffected.
  public static func forCassette() -> AudioStreamingPlayer {
    AudioStreamingPlayer(configuration: AudioPlayerConfiguration(
      bufferSizeInSeconds: 20,
      secondsRequiredToStartPlaying: 2.5,
      gracePeriodAfterSeekInSeconds: 0.5,
      secondsRequiredToStartPlayingAfterBufferUnderrun: 3
    ))
  }

  public func elapsedTime() -> Double {
    progress
  }

  public func getState() -> AudioStreaming.AudioPlayerState {
    state
  }
}

// MARK: - PlayType

public enum PlayType {
  case stream
  case cache
}

public typealias CreateAudioStreamingPlayerCallback = () -> AudioStreamingPlayer
public typealias TriggerReinsertPlayableCallback = @MainActor () -> ()
typealias NextPlayablePreloadCallback = () -> AbstractPlayable?

// MARK: - BackendAudioQueueType

enum BackendAudioQueueType {
  case play
  case queue
}

// MARK: - BackendAudioPlayer

/// cassette (I-P3): the app sets this from its lyrics switch at launch (Cassette.lyricsEnabled);
/// off, no lyrics clock runs while music plays.
public enum PlayerLyricsClock {
  nonisolated(unsafe) public static var isWanted = true
}

@MainActor
class BackendAudioPlayer: NSObject {
  private let getPlayableDownloaderCB: GetPlayableDownloadManagerCallback
  private let cacheProxy: PlayableFileCachable
  private let getBackendApiCB: GetBackendApiCallback
  private let userStatistics: UserStatistics
  private let createAudioStreamingPlayerCB: CreateAudioStreamingPlayerCallback
  private let eventLogger: EventLogger
  private let networkMonitor: NetworkMonitorFacade
  private let updateElapsedTimeInterval = CMTime(
    seconds: 1.0,
    preferredTimescale: CMTimeScale(NSEC_PER_SEC)
  )
  private let updateLyricsTimeInterval = CMTime(
    seconds: 0.1,
    preferredTimescale: CMTimeScale(NSEC_PER_SEC)
  )
  private let fileManager = CacheFileManager.shared
  private var audioSessionHandler: AudioSessionHandler
  private var isTriggerReinsertPlayableAllowed = true
  private var wasPlayingBeforeErrorOccurred: Bool = false
  private var userDefinedPlaybackRate: PlaybackRate = .one
  private var currentPreparedUrl: String = ""
  private var currentPlayUrl: String = ""
  private var nextPreloadedPlayable: AbstractPlayable?
  private var nextPreloadedUrl: String = ""
  private var isPreviousPlaylableFinshed = true
  private var isAutoStartPlayback = true
  private var seekTimeWhenStarted: Double?
  private var timerElapsedTimeInterval: Timer?
  private var timerLyricsTimeInterval: Timer?
  private var volumePlayer: Float = 1.0

  private var player: AudioStreamingPlayer?
  private var equalizer: AVAudioUnitEQ?
  private var replayGainNode: AVAudioMixerNode?
  public private(set) var audioAnalyzer: AudioAnalyzer

  // EQ Settings
  private var equalizerVolumeCompensation: Float = 1.0
  private var isEqualizerEnabled: Bool = true
  private var currentEqualizerSetting: EqualizerSetting = .off

  public var isOfflineMode: Bool = false
  public var isAutoCachePlayedItems: Bool = true
  public var nextPlayablePreloadCB: NextPlayablePreloadCallback?
  public var triggerReinsertPlayableCB: TriggerReinsertPlayableCallback?
  public private(set) var isPlaying: Bool = false
  public private(set) var isErrorOccurred: Bool = false
  public private(set) var playType: PlayType?
  private var perloadedPlayType: PlayType?
  public private(set) var activeStreamingBitrate: StreamingMaxBitratePreference?
  private var perloadedStreamingBitrate: StreamingMaxBitratePreference?
  public private(set) var activeTranscodingFormat: StreamingFormatPreference?
  private var preloadTranscodingFormat: StreamingFormatPreference?
  public private(set) var streamingMaxBitrates = StreamingMaxBitrates()
  public func setStreamingMaxBitrates(to: StreamingMaxBitrates) {
    let oldBitrate = streamingMaxBitrates.getActive(networkMonitor: networkMonitor)
    let newBitrate = to.getActive(networkMonitor: networkMonitor)

    os_log(
      .default,
      "Update Streaming Max Bitrate: %s -> %s (for next stream)",
      oldBitrate.description,
      newBitrate.description
    )
    // Update the stored bitrates
    streamingMaxBitrates = to
  }

  public private(set) var streamingTranscodings = StreamingTranscodings()
  public func setStreamingTranscodings(to: StreamingTranscodings) {
    os_log(
      .default,
      "Update Streaming Transcoding: <Wifi: %s, Cellular: %s> -> <Wifi: %s, Cellular: %s> (for next stream)",
      streamingTranscodings.wifi.description,
      streamingTranscodings.cellular.description,
      to.wifi.description,
      to.cellular.description
    )
    // Update the stored bitrates
    streamingTranscodings = to
  }

  var responder: BackendAudioPlayerNotifiable?
  var volume: Float {
    get {
      volumePlayer
    }
    set {
      volumePlayer = newValue
      player?.volume = newValue
    }
  }

  var isStopped: Bool {
    playType == nil
  }

  var elapsedTime: Double {
    player?.elapsedTime() ?? 0.0
  }

  var duration: Double {
    player?.duration ?? 0.0
  }

  var playbackRate: PlaybackRate {
    userDefinedPlaybackRate
  }

  var canBeContinued: Bool {
    currentPlayUrl != "" &&
      (
        player?.getState() == .paused || player?.getState() == .playing || player?
          .getState() == .bufferring
      )
  }

  init(
    createAudioStreamingPlayerCB: @escaping CreateAudioStreamingPlayerCallback,
    audioSessionHandler: AudioSessionHandler,
    eventLogger: EventLogger,
    getBackendApiCB: @escaping GetBackendApiCallback,
    networkMonitor: NetworkMonitorFacade,
    getPlayableDownloaderCB: @escaping GetPlayableDownloadManagerCallback,
    cacheProxy: PlayableFileCachable,
    userStatistics: UserStatistics
  ) {
    self.createAudioStreamingPlayerCB = createAudioStreamingPlayerCB
    self.audioSessionHandler = audioSessionHandler
    self.getBackendApiCB = getBackendApiCB
    self.networkMonitor = networkMonitor
    self.eventLogger = eventLogger
    self.getPlayableDownloaderCB = getPlayableDownloaderCB
    self.cacheProxy = cacheProxy
    self.userStatistics = userStatistics
    self.audioAnalyzer = AudioAnalyzer()

    super.init()

    initAudioStreamingPlayerAndNodes()
  }

  private func startTimers() {
    stopTimers()
    timerElapsedTimeInterval = Timer.scheduledTimer(
      withTimeInterval: updateElapsedTimeInterval.seconds,
      repeats: true
    ) { [weak self] timer in
      Task { @MainActor in
        guard let self = self else { return }
        self.checkForPreloadNextPlayerItem()
        self.responder?.didElapsedTimeChange()
      }
    }
    // cassette (I-P3): the ten-a-second lyrics clock only runs when the app shows lyrics.
    guard PlayerLyricsClock.isWanted else { return }
    timerLyricsTimeInterval = Timer.scheduledTimer(
      withTimeInterval: updateLyricsTimeInterval.seconds,
      repeats: true
    ) { [weak self] timer in
      Task { @MainActor in
        guard let self = self else { return }
        let cmTime = CMTime(value: Int64(self.elapsedTime * 1_000), timescale: 1_000)
        self.responder?.didLyricsTimeChange(time: cmTime)
      }
    }
  }

  private func stopTimers() {
    timerElapsedTimeInterval?.invalidate()
    timerLyricsTimeInterval?.invalidate()
  }

  private func checkForPreloadNextPlayerItem() {
    guard isAutoStartPlayback else { return }
    if nextPreloadedPlayable == nil, elapsedTime.isFinite, elapsedTime > 0, duration.isFinite,
       duration > 0 {
      let remainingTime = duration - elapsedTime
      if remainingTime > 0, remainingTime < 10 {
        nextPreloadedPlayable = nextPlayablePreloadCB?()
        guard let nextPreloadedPlayable = nextPreloadedPlayable else { return }
        os_log(.default, "Preloading: %s", nextPreloadedPlayable.displayString)
        // Cassette fork — Patch 101 (Phase 3.3). Mirror handleRequest's dispatch
        // order (owned → on-device-only skip → cache → stream) when preloading the
        // NEXT track. Patch 097 taught handleRequest to play owned files but left
        // preload unaware of them: an owned-only next track has isCached == false
        // (relFilePath == nil), so it was flagged as nextPreloadedPlayable but
        // never queued. At the track boundary handleRequest sees
        // `playable == nextPreloadedPlayable` and no-ops (assumes it is queued) →
        // playback stops after each song (the per-album Bluetooth report). Any
        // path that cannot queue the item clears nextPreloadedPlayable so the
        // boundary performs a real dispatch instead of the "already queued"
        // short-circuit.
        if nextPreloadedPlayable.isSong,
           let ownedUrl = DeviceOwnershipManager(
             context: AmperKit.shared.storage.main.context
           ).localFileURL(forSubsonicTrackId: nextPreloadedPlayable.id) {
          insertOwnedPlayable(
            playable: nextPreloadedPlayable,
            fileURL: ownedUrl,
            queueType: .queue
          )
        } else if nextPreloadedPlayable.isSong,
                  CassetteLibraryFilterProvider.shared.currentFilter == .onDeviceOnly {
          // Non-owned song in on-device-only mode: don't preload-stream it. Clear
          // the phantom so handleRequest's skip-silently branch fires at the
          // boundary and the queue advances past it.
          self.nextPreloadedPlayable = nil
        } else if nextPreloadedPlayable.isCached {
          insertCachedPlayable(playable: nextPreloadedPlayable, queueType: .queue)
        } else if !isOfflineMode {
          Task { @MainActor in
            do {
              try await insertStreamPlayable(playable: nextPreloadedPlayable, queueType: .queue)
              if self.isAutoCachePlayedItems, nextPreloadedPlayable.isDownloadAvailable,
                 let accountInfo = nextPreloadedPlayable.account?.info {
                self.getPlayableDownloaderCB(accountInfo).download(object: nextPreloadedPlayable)
              }
            } catch {
              self.nextPreloadedPlayable = nil
              self.eventLogger.report(topic: "Player", error: error)
            }
          }
        } else {
          // Offline and the track is neither owned nor cached: nothing to queue.
          // Clear the phantom so the boundary does a real dispatch rather than the
          // no-op short-circuit.
          self.nextPreloadedPlayable = nil
        }
      }
    }
  }

  @MainActor
  private func itemFinishedPlaying() {
    isTriggerReinsertPlayableAllowed = true
    isPreviousPlaylableFinshed = true
    if nextPreloadedPlayable != nil {
      isPlaying = true
      startTimers()
    } else {
      isPlaying = false
      stopTimers()
    }
    responder?.didItemFinishedPlaying()
  }

  private func handleError(error: Error) {
    isErrorOccurred = true
    wasPlayingBeforeErrorOccurred = isPlaying
    pause()
    nextPreloadedPlayable = nil
    nextPreloadedUrl = ""
    isPreviousPlaylableFinshed = true
    activeStreamingBitrate = nil
    perloadedStreamingBitrate = nil
    activeTranscodingFormat = nil
    preloadTranscodingFormat = nil
    restartPlayer()
    eventLogger.report(topic: "Player Status", error: error)
    responder?.notifyErrorOccurred(error: error)
    if isTriggerReinsertPlayableAllowed {
      isTriggerReinsertPlayableAllowed = false
      triggerReinsertPlayableCB?()
    }
  }

  func continuePlay() {
    // cassette: reactivate the audio session on resume. We now release the session
    // when the CarPlay/car route disappears (AudioSessionHandler.deactivateSession),
    // and resume does not otherwise reconfigure it — so a play after a car unplug
    // would be silent. `configureBackgroundPlayback` is a guarded no-op when the
    // session is already active (and while an interruption is in progress), so this
    // is safe on every resume path.
    audioSessionHandler.configureBackgroundPlayback()
    isPlaying = true
    player?.resume()
    startTimers()
    player?.rate = Float(userDefinedPlaybackRate.asDouble)
    audioAnalyzer.play()
  }

  func pause() {
    isPlaying = false
    player?.pause()
    stopTimers()
    audioAnalyzer.stop()
  }

  func stop() {
    isPlaying = false
    clearPlayer()
    audioAnalyzer.stop()
  }

  func setPlaybackRate(_ newValue: PlaybackRate) {
    userDefinedPlaybackRate = newValue
    player?.rate = Float(newValue.asDouble)
  }

  func seek(toSecond: Double) {
    if currentPlayUrl != "", player?.getState() == .playing || player?.getState() == .paused {
      seekTimeWhenStarted = nil
      player?.seek(to: toSecond)
    } else {
      seekTimeWhenStarted = toSecond
    }
  }

  private func restartPlayer() {
    player = nil
    initAudioStreamingPlayerAndNodes()
  }

  private func initAudioStreamingPlayerAndNodes() {
    guard player == nil else { return }
    player = createAudioStreamingPlayerCB()

    equalizer = AVAudioUnitEQ(numberOfBands: 10)
    replayGainNode = AVAudioMixerNode()
    audioAnalyzer = AudioAnalyzer()

    guard let player,
          let eq = equalizer,
          let replayGain = replayGainNode
    else { return }

    player.volume = volumePlayer
    player.delegate = self

    player.attach(nodes: [eq, replayGain])

    audioAnalyzer.install(on: equalizer!)

    setupEqualizerBands()
    applyEqualizerSetting(eqSetting: currentEqualizerSetting)
    applyReplayGain()
    os_log(.debug, "Player setup completed with EQ and ReplayGain support")
  }

  var shouldPlaybackStart: Bool {
    (!isErrorOccurred && isAutoStartPlayback) || (isErrorOccurred && wasPlayingBeforeErrorOccurred)
  }

  func requestToPlay(
    playable: AbstractPlayable,
    playbackRate: PlaybackRate,
    autoStartPlayback: Bool
  ) {
    userDefinedPlaybackRate = playbackRate
    player?.rate = Float(userDefinedPlaybackRate.asDouble)
    isAutoStartPlayback = autoStartPlayback
    handleRequest(playable: playable)
  }

  private func handleRequest(playable: AbstractPlayable) {
    if isPreviousPlaylableFinshed, let nextPreloadedPlayable = nextPreloadedPlayable,
       nextPreloadedPlayable == playable {
      // Do nothing next preloaded playable has already been queued to player
      os_log(.default, "Play Preloaded: %s", nextPreloadedPlayable.displayString)
      currentPreparedUrl = ""
      currentPlayUrl = nextPreloadedUrl
      playType = perloadedPlayType
      perloadedPlayType = nil
      activeStreamingBitrate = perloadedStreamingBitrate
      perloadedStreamingBitrate = nil
      activeTranscodingFormat = preloadTranscodingFormat
      preloadTranscodingFormat = nil
      isPreviousPlaylableFinshed = false
      self.nextPreloadedPlayable = nil
      nextPreloadedUrl = ""
      responder?.notifyItemPreparationFinished()
    } else if playable.isSong,
              let ownedUrl = DeviceOwnershipManager(
                context: AmperKit.shared.storage.main.context
              ).localFileURL(forSubsonicTrackId: playable.id) {
      // Cassette fork — Layer 3 Phase 3.2 (playback dispatch). A Phase 3.1
      // owned file exists on disk for this song: play it directly. Works in
      // airplane mode and takes precedence over Amperfy's cache. The state
      // resets + guards mirror the cache branch below; the only difference is
      // the file URL source (CassetteMusic/ instead of cacheProxy).
      currentPlayUrl = ""
      nextPreloadedPlayable = nil
      nextPreloadedUrl = ""
      activeStreamingBitrate = nil
      perloadedStreamingBitrate = nil
      activeTranscodingFormat = nil
      preloadTranscodingFormat = nil
      guard playable.isPlayableOniOS else {
        reactToIncompatibleContentType(
          contentType: playable.fileContentType ?? "",
          playableDisplayTitle: playable.displayString
        )
        return
      }
      os_log(.default, "Cassette playback: serving local file for %s", playable.id)
      insertOwnedPlayable(playable: playable, fileURL: ownedUrl)
      isPlaying = shouldPlaybackStart
      responder?.notifyItemPreparationFinished()
    } else if playable.isSong,
              CassetteLibraryFilterProvider.shared.currentFilter == .onDeviceOnly {
      // Cassette fork — Layer 3 Phase 3.2 (library filtering). In on-device-only
      // mode a non-owned song reached the player — e.g. a mixed playlist, or a
      // queue built before its transfer finished. Don't stream it; skip silently
      // to the next item. The async hop avoids deep recursion when an entire
      // queue is non-owned; the queue advance (didItemFinishedPlaying) ends
      // gracefully once nothing playable remains.
      os_log(
        .default,
        "Cassette playback: skipping non-owned track in on-device-only mode (%s)",
        playable.id
      )
      clearPlayer()
      DispatchQueue.main.async { [weak self] in
        self?.responder?.didItemFinishedPlaying()
      }
    } else if let relFilePath = playable.relFilePath,
              fileManager.fileExits(relFilePath: relFilePath) {
      currentPlayUrl = ""
      nextPreloadedPlayable = nil
      nextPreloadedUrl = ""
      activeStreamingBitrate = nil
      perloadedStreamingBitrate = nil
      activeTranscodingFormat = nil
      preloadTranscodingFormat = nil
      guard playable.isPlayableOniOS else {
        reactToIncompatibleContentType(
          contentType: playable.fileContentType ?? "",
          playableDisplayTitle: playable.displayString
        )
        return
      }
      insertCachedPlayable(playable: playable)
      isPlaying = shouldPlaybackStart
      responder?.notifyItemPreparationFinished()
    } else if !isOfflineMode {
      currentPlayUrl = ""
      nextPreloadedPlayable = nil
      nextPreloadedUrl = ""
      activeStreamingBitrate = nil
      perloadedStreamingBitrate = nil
      activeTranscodingFormat = nil
      preloadTranscodingFormat = nil
      guard playable.isPlayableOniOS || streamingTranscodings
        .isTranscodingActive(networkMonitor: networkMonitor) else {
        reactToIncompatibleContentType(
          contentType: playable.fileContentType ?? "",
          playableDisplayTitle: playable.displayString
        )
        return
      }
      if let radio = playable.asRadio {
        // radios must have a valid URL
        guard let urlString = radio.url,
              URL(string: urlString) != nil
        else {
          reactToInvalidRadioUrl(playableDisplayTitle: playable.displayString)
          return
        }
      }

      Task { @MainActor in
        do {
          try await insertStreamPlayable(playable: playable)
          isPlaying = shouldPlaybackStart
          if self.isAutoCachePlayedItems, !playable.isRadio,
             let accountInfo = playable.account?.info {
            self.getPlayableDownloaderCB(accountInfo).download(object: playable)
          }
          self.responder?.notifyItemPreparationFinished()
        } catch {
          self.responder?.notifyErrorOccurred(error: error)
          self.responder?.notifyItemPreparationFinished()
          self.eventLogger.report(topic: "Player", error: error)
        }
      }
    } else {
      clearPlayer()
      responder?.notifyItemPreparationFinished()
    }
  }

  private func reactToIncompatibleContentType(contentType: String, playableDisplayTitle: String) {
    clearPlayer()
    eventLogger.info(
      topic: "Player Info",
      statusCode: .playerError,
      message: "\"\(playableDisplayTitle)\" can't play on this phone (its file type, \(contentType), isn't one it plays).",
      displayPopup: true
    )
    responder?.notifyItemPreparationFinished()
  }

  private func reactToInvalidRadioUrl(playableDisplayTitle: String) {
    clearPlayer()
    eventLogger.info(
      topic: "Player Info",
      statusCode: .playerError,
      message: "\(playableDisplayTitle) can't be tuned in right now.",
      displayPopup: true
    )
    responder?.notifyItemPreparationFinished()
  }

  private func clearPlayer() {
    isPreviousPlaylableFinshed = true
    currentPreparedUrl = ""
    currentPlayUrl = ""
    nextPreloadedPlayable = nil
    nextPreloadedUrl = ""
    playType = nil
    perloadedPlayType = nil
    activeStreamingBitrate = nil
    perloadedStreamingBitrate = nil
    activeTranscodingFormat = nil
    preloadTranscodingFormat = nil
    seekTimeWhenStarted = nil
    isPlaying = false
    playType = nil

    stopTimers()
    audioAnalyzer.stop()
    player?.stop()
  }

  /// Cassette fork — Layer 3 Phase 3.2. Play a Phase 3.1 owned file from
  /// `CassetteMusic/`. Identical to `insertCachedPlayable` except the URL is
  /// supplied by the caller (resolved from `DeviceOwnership`) rather than the
  /// cache proxy, so it routes through the same proven local-file play path.
  private func insertOwnedPlayable(
    playable: AbstractPlayable,
    fileURL: URL,
    queueType: BackendAudioQueueType = .play
  ) {
    if queueType == .play {
      playType = .cache
      perloadedPlayType = nil
      os_log(.default, "Play Owned: %s (%s)", playable.displayString, fileURL.absoluteString)
    } else {
      perloadedPlayType = .cache
      os_log(.default, "Insert Owned: %s (%s)", playable.displayString, fileURL.absoluteString)
    }
    if playable.isSong { userStatistics.playedSong(isPlayedFromCache: true) }
    insert(playable: playable, withUrl: fileURL, queueType: queueType)
  }

  private func insertCachedPlayable(
    playable: AbstractPlayable,
    queueType: BackendAudioQueueType = .play
  ) {
    guard let fileURL = cacheProxy.getFileURL(forPlayable: playable) else {
      return
    }
    if queueType == .play {
      playType = .cache
      perloadedPlayType = nil
      os_log(.default, "Play Cache: %s (%s)", playable.displayString, fileURL.absoluteString)
    } else {
      perloadedPlayType = .cache
      os_log(.default, "Insert Cache: %s (%s)", playable.displayString, fileURL.absoluteString)
    }
    if playable.isSong { userStatistics.playedSong(isPlayedFromCache: true) }
    insert(playable: playable, withUrl: fileURL, queueType: queueType)
  }

  @MainActor
  private func insertStreamPlayable(
    playable: AbstractPlayable,
    queueType: BackendAudioQueueType = .play
  ) async throws {
    let streamingMaxBitrate = streamingMaxBitrates.getActive(networkMonitor: networkMonitor)
    let streamingTranscodingFormat = streamingTranscodings.getActive(networkMonitor: networkMonitor)
    @MainActor
    func provideUrl() async throws -> URL {
      if let radio = playable.asRadio {
        guard let streamUrlString = radio.url,
              let streamUrl = URL(string: streamUrlString)
        else {
          throw BackendError.invalidUrl
        }
        playType = .stream
        return streamUrl
      } else {
        if queueType == .play {
          playType = .stream
          perloadedPlayType = nil
          activeStreamingBitrate = streamingMaxBitrate
          perloadedStreamingBitrate = nil
          activeTranscodingFormat = streamingTranscodingFormat
          preloadTranscodingFormat = nil
        } else {
          perloadedPlayType = .stream
          perloadedStreamingBitrate = streamingMaxBitrate
          preloadTranscodingFormat = streamingTranscodingFormat
        }
        guard let accountInfo = playable.account?.info else {
          throw BackendError.noCredentials
        }
        return try await getBackendApiCB(accountInfo).generateUrl(
          forStreamingPlayable: playable.info,
          maxBitrate: streamingMaxBitrate,
          formatPreference: streamingTranscodingFormat
        )
      }
    }
    let streamUrl = try await provideUrl()

    if queueType == .play {
      os_log(
        .default,
        "Play Stream: %s (%s)",
        playable.displayString,
        streamingMaxBitrate.description
      )
    } else {
      os_log(
        .default,
        "Insert Stream: %s (%s)",
        playable.displayString,
        streamingMaxBitrate.description
      )
    }
    if playable.isSong { userStatistics.playedSong(isPlayedFromCache: false) }
    insert(
      playable: playable,
      withUrl: streamUrl,
      streamingMaxBitrate: streamingMaxBitrate,
      queueType: queueType
    )
  }

  private func insert(
    playable: AbstractPlayable,
    withUrl url: URL,
    streamingMaxBitrate: StreamingMaxBitratePreference = .noLimit,
    queueType: BackendAudioQueueType
  ) {
    if queueType == .play {
      seekTimeWhenStarted = nil
      player?.pause()
      audioSessionHandler.configureBackgroundPlayback()
    }

    var asset: AVURLAsset?
    if let mimeType = playable.iOsCompatibleContentType {
      asset = AVURLAsset(url: url, options: ["AVURLAssetOutOfBandMIMETypeKey": mimeType])
    } else {
      asset = AVURLAsset(url: url)
    }
    playInPlayer(asset: asset, queueType: queueType)
  }

  private func playInPlayer(
    asset: AVURLAsset?,
    queueType: BackendAudioQueueType
  ) {
    guard let asset = asset else {
      clearPlayer()
      return
    }

    switch queueType {
    case .play:
      currentPreparedUrl = asset.url.absoluteString
      player?.play(url: asset.url)
    case .queue:
      nextPreloadedUrl = asset.url.absoluteString
      player?.queue(url: asset.url)
    }
  }

  // MARK: - EQ Implementation

  func updateEqualizerEnabled(isEnabled: Bool) {
    isEqualizerEnabled = isEnabled
    os_log(.debug, "Equalizer enabled: %s", isEnabled.description)
    applyEqualizerToActiveContent()
  }

  func updateEqualizerSetting(eqSetting: EqualizerSetting) {
    let oldSetting = currentEqualizerSetting
    currentEqualizerSetting = eqSetting
    os_log(
      .debug,
      "Equalizer changed from %s to %s",
      oldSetting.description,
      eqSetting.description
    )
    applyEqualizerToActiveContent()
  }

  private func applyEqualizerToActiveContent() {
    if isEqualizerEnabled {
      applyEqualizerSetting(eqSetting: currentEqualizerSetting)
    } else {
      applyEqualizerSetting(eqSetting: .off)
    }
    applyReplayGain()
  }

  private func setupEqualizerBands() {
    guard let equalizer else { return }

    for (index, frequency) in EqualizerSetting.frequencies.enumerated() {
      guard index < equalizer.bands.count else { break }

      let band = equalizer.bands[index]
      band.frequency = frequency
      band.bandwidth = 1.0
      band.filterType = .parametric
      band.gain = 0.0
      band.bypass = false
    }
  }

  private func applyEqualizerSetting(eqSetting: EqualizerSetting) {
    guard let equalizer else { return }

    // EQ band gains
    for (index, gain) in eqSetting.gains.enumerated() {
      guard index < equalizer.bands.count else { break }

      let band = equalizer.bands[index]

      band.filterType = .parametric
      band.bandwidth = 1.0
      band.gain = gain
      band.bypass = false
    }

    equalizerVolumeCompensation = isEqualizerEnabled ? eqSetting.compensatedVolume : 1.0

    os_log(.debug, "   EQ '%s'", eqSetting.description)
    os_log(
      .debug,
      "   EQ Gains: [%@] dB",
      eqSetting.gains.map { String(format: "%.1f", $0) }.joined(separator: ", ")
    )
    os_log(.debug, "   EQ Gain Compensation: %.1f dB", eqSetting.gainCompensation)
    os_log(.debug, "   EQ linear Volume Compensation: %.2f", eqSetting.compensatedVolume)
    os_log(.debug, "   Active EQ linear Volume Compensation: %.2f", equalizerVolumeCompensation)
  }

  // MARK: - Make-up Gain (formerly ReplayGain)

  // Cassette fork: ReplayGain was removed — 0% tag coverage made it inert and
  // the toggle left the Settings pane. This mixer node is retained because it
  // also carries the EQ make-up gain; without it the equalizer's level
  // compensation has nowhere to apply. Album-gain normalization is deferred.
  private func applyReplayGain() {
    guard let replayGain = replayGainNode else { return }
    replayGain.outputVolume = isEqualizerEnabled ? equalizerVolumeCompensation : 1.0
  }
}

// MARK: AudioStreaming.AudioPlayerDelegate

extension BackendAudioPlayer: AudioStreaming.AudioPlayerDelegate {
  nonisolated func audioPlayerDidStartPlaying(
    player: AudioStreaming.AudioPlayer,
    with entryId: AudioStreaming.AudioEntryId
  ) {
    let entryID = entryId.id
    Task { @MainActor in
      didStartPlaying(url: entryID)
    }
  }

  @MainActor
  public func didStartPlaying(url: String) {
    if currentPreparedUrl == url {
      if let sampleRate = player?.mainMixerNode.outputFormat(forBus: 0).sampleRate {
        audioAnalyzer.playing(sampleRate: Float(sampleRate))
      }

      currentPreparedUrl = ""
      currentPlayUrl = url
      if shouldPlaybackStart {
        continuePlay()
        audioAnalyzer.play()
      } else {
        pause()
        audioAnalyzer.stop()
      }

      if let seekTimeWhenStarted {
        player?.seek(to: seekTimeWhenStarted)
        self.seekTimeWhenStarted = nil
      }
    }
  }

  nonisolated func audioPlayerDidFinishBuffering(
    player: AudioStreaming.AudioPlayer,
    with entryId: AudioStreaming.AudioEntryId
  ) {}

  nonisolated func audioPlayerStateChanged(
    player: AudioStreaming.AudioPlayer,
    with newState: AudioStreaming.AudioPlayerState,
    previous: AudioStreaming.AudioPlayerState
  ) {}

  nonisolated func audioPlayerDidFinishPlaying(
    player: AudioStreaming.AudioPlayer,
    entryId: AudioStreaming.AudioEntryId,
    stopReason: AudioStreaming.AudioPlayerStopReason,
    progress: Double,
    duration: Double
  ) {
    let entryID = entryId.id
    Task { @MainActor in
      if self.currentPlayUrl == entryID {
        self.currentPlayUrl = ""
        self.itemFinishedPlaying()
      }
    }
  }

  nonisolated func audioPlayerUnexpectedError(
    player: AudioStreaming.AudioPlayer,
    error: AudioStreaming.AudioPlayerError
  ) {
    Task { @MainActor in
      self.handleError(error: error)
    }
  }

  nonisolated func audioPlayerDidCancel(
    player: AudioStreaming.AudioPlayer,
    queuedItems: [AudioStreaming.AudioEntryId]
  ) {
    Task { @MainActor in
      self.currentPlayUrl = ""
    }
  }

  nonisolated func audioPlayerDidReadMetadata(
    player: AudioStreaming.AudioPlayer,
    metadata: [String: String]
  ) {
    Task { @MainActor in
      self.responder?.didReadStreamMetadata(metadata)
    }
  }
}
