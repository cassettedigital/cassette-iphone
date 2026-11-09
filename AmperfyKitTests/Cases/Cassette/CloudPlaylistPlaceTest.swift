//
//  CloudPlaylistPlaceTest.swift
//  AmperfyKitTests (Cassette fork)
//
//  BUG-887: a song moved on the phone gets one new place in the playlist's whole order, which also holds
//  the songs this phone doesn't have, so every other song keeps its place on every device.
//

@testable import AmperfyKit
import XCTest

class CloudPlaylistPlaceTest: XCTestCase {
  // The cloud's whole list: a, x, b, y, c (x and y are not on this phone), 1024 apart as the cloud keeps them.
  let full: [(id: String, position: Double)] = [
    ("a", 1024), ("x", 2048), ("b", 3072), ("y", 4096), ("c", 5120),
  ]

  func testMovedDownLandsRightAfterTheSongNowAboveIt() {
    // phone a, b, c -> b, a, c: a goes right after b, before y
    let p = CassetteCloudPlaylistBridge.placeMoved("a", phoneOrder: ["b", "a", "c"], full: full)
    XCTAssertEqual(p, 3584)
  }

  func testMovedToTheTopLandsRightBeforeTheSongNowBelowIt() {
    // phone a, b, c -> c, a, b: c goes right before a, at the very top
    let p = CassetteCloudPlaylistBridge.placeMoved("c", phoneOrder: ["c", "a", "b"], full: full)
    XCTAssertEqual(p, 0)
  }

  func testMovedToTheEndLandsAfterTheLastSong() {
    // phone a, b, c -> b, c, a: a goes after c, the last song in the whole list
    let p = CassetteCloudPlaylistBridge.placeMoved("a", phoneOrder: ["b", "c", "a"], full: full)
    XCTAssertEqual(p, 5120 + 1024)
  }

  func testTheSongsThisPhoneDoesntHaveKeepTheirPlaces() {
    let p = CassetteCloudPlaylistBridge.placeMoved("c", phoneOrder: ["a", "c", "b"], full: full)!
    let order = (full.filter { $0.id != "c" } + [("c", p)]).sorted { $0.1 < $1.1 }.map(\.0)
    XCTAssertEqual(order, ["a", "c", "x", "b", "y"])
  }

  func testNoNeighbourInTheCloudPlacesNothing() {
    XCTAssertNil(CassetteCloudPlaylistBridge.placeMoved("a", phoneOrder: ["a"], full: full))
    XCTAssertNil(CassetteCloudPlaylistBridge.placeMoved("q", phoneOrder: ["a", "q"], full: full))
  }
}
