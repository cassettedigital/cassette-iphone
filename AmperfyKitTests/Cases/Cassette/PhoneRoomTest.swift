//
//  PhoneRoomTest.swift
//  AmperfyKitTests (Cassette fork)
//
//  BUG-883: music never fills the phone past its 1 GB reserve; a song is budgeted at CD quality before it arrives.
//

@testable import AmperfyKit
import XCTest

class PhoneRoomTest: XCTestCase {
  let gb: Int64 = 1_000_000_000

  func testASongIsBudgetedAtCDQuality() {
    XCTAssertEqual(CassetteTransferSession.budget(seconds: 240), 240 * 176_400)
    XCTAssertEqual(
      CassetteTransferSession.budget(seconds: nil),
      300 * 176_400,
      "unknown length counts as five minutes"
    )
  }

  func testTheReserveIsNeverSpent() {
    let song = CassetteTransferSession.budget(seconds: 240) // about 42 MB
    let reserve = CassetteTransferSession.reserveBytes
    XCTAssertTrue(CassetteTransferSession.fits(
      budget: song,
      free: reserve + song,
      alreadyBudgeted: 0
    ))
    XCTAssertFalse(CassetteTransferSession.fits(
      budget: song,
      free: reserve + song - 1,
      alreadyBudgeted: 0
    ))
  }

  func testSongsInFlightCountAgainstTheRoom() {
    let song = CassetteTransferSession.budget(seconds: 240)
    let reserve = CassetteTransferSession.reserveBytes
    XCTAssertTrue(CassetteTransferSession.fits(
      budget: song,
      free: reserve + 2 * song,
      alreadyBudgeted: song
    ))
    XCTAssertFalse(CassetteTransferSession.fits(
      budget: song,
      free: reserve + 2 * song,
      alreadyBudgeted: song + 1
    ))
  }

  func testUnreadableFreeSpaceNeverBlocks() {
    XCTAssertTrue(CassetteTransferSession.fits(budget: gb, free: nil, alreadyBudgeted: 10 * gb))
  }
}
