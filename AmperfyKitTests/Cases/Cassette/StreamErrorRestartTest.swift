//
//  StreamErrorRestartTest.swift
//  AmperfyKitTests (Cassette fork)
//
//  BUG-746: a stream that won't connect could crash the app. AudioStreaming leaves its engine running after a
//  stream error and frees its buffers when released, so the player that failed must be stopped and cut loose
//  before a new one takes over. Real players, so the library's own stop is what's checked.
//

@testable import AmperfyKit
@preconcurrency @testable import AudioStreaming
import XCTest

@MainActor
final class StreamErrorRestartTest: XCTestCase {
  final class Made { var players: [AudioStreamingPlayer] = [] }

  func testAStreamErrorStopsTheFailedPlayerBeforeLettingItGo() async throws {
    let cdHelper = CoreDataHelper()
    let library = cdHelper.createSeededStorage()
    let storage =
      PersistentStorage(coreDataManager: MOCK_CoreDataManager(
        persistentContainer: cdHelper
          .persistentContainer
      ))
    let made = Made()
    let backend = BackendAudioPlayer(
      createAudioStreamingPlayerCB: {
        let p = AudioStreamingPlayer.forCassette()
        made.players.append(p)
        return p
      },
      audioSessionHandler: AudioSessionHandler(),
      eventLogger: EventLogger(storage: storage),
      getBackendApiCB: { _ in MOCK_BackendApi() },
      networkMonitor: MOCK_NetworkMonitor(),
      getPlayableDownloaderCB: { _ in MOCK_SongDownloader() },
      cacheProxy: library,
      userStatistics: library.getUserStatistics(appVersion: "")
    )
    XCTAssertEqual(made.players.count, 1)
    let failed = made.players[0]
    XCTAssertNotEqual(failed.state, .stopped)

    backend.audioPlayerUnexpectedError(
      player: failed,
      error: .networkError(.failure(URLError(.cannotConnectToHost)))
    )
    for _ in 0 ..< 100 where made.players.count < 2 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    XCTAssertEqual(made.players.count, 2, "a new player takes over from the one that failed")
    XCTAssertEqual(
      failed.state,
      .stopped,
      "the failed player's engine is stopped before it is let go"
    )
    XCTAssertNil(failed.delegate, "and it no longer reports to the app")
  }
}
