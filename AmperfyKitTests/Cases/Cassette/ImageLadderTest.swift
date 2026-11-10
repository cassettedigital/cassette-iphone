//
//  ImageLadderTest.swift
//  AmperfyKitTests
//
//  Cassette fork — the image ladder (docs/reference/CASSETTE_IMAGES.md). The kit's pick rule
//  agrees with every shared example (the TypeScript, Kotlin and Swift copies are generated from
//  one tokens.json; if one disagrees, the platforms have drifted), covers are decoded at the rung
//  their frame needs at the screen's scale, and the artwork manifest's ladder photo decodes beside
//  the old fields.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

@testable import AmperfyKit
import XCTest

class ImageLadderTest: XCTestCase {
  typealias Images = CassetteKitTokens.Images

  func testPickRuleMatchesEverySharedExample() {
    XCTAssertEqual(Images.pickExamples.count, 17)
    for e in Images.pickExamples {
      let fit: Images.Fit = e.fit
      XCTAssertEqual(
        Images.pickRung(
          w: e.w,
          h: e.h,
          scale: e.scale,
          aspect: e.aspect,
          fit: fit,
          natural: e.natural
        ),
        e.rung,
        "\(e.w)x\(e.h) @\(e.scale)x aspect \(e.aspect)"
      )
    }
  }

  func testTopRungIsWhatTheHubIsAskedFor() {
    XCTAssertEqual(CoverImageStore.topRung, 1200)
    XCTAssertTrue(Images.rungs.contains(CoverImageStore.thumbMaxPixel))
  }

  func testCoversDecodeAtTheirRungForTheScreen() {
    func rung(_ side: CGFloat, _ scale: CGFloat) -> Int {
      CoverImageStore.decodePixels(for: CGSize(width: side, height: side), scale: scale)
    }
    XCTAssertEqual(rung(40, 3), 120) // a small row
    XCTAssertEqual(rung(48, 3), 240) // a song row
    XCTAssertEqual(rung(48, 2), 120) // the same row on a 2x screen
    XCTAssertEqual(rung(160, 3), 480) // a carousel tile
    XCTAssertEqual(rung(180, 3), 800) // a two-column grid tile
    XCTAssertEqual(rung(240, 3), 800) // the album page hero
    XCTAssertEqual(rung(360, 3), 1200) // the now-playing hero
    XCTAssertEqual(rung(1000, 3), 1200) // never past the top rung
    // Not laid out: the top rung, which callers wait out rather than decode.
    XCTAssertEqual(CoverImageStore.decodePixels(for: .zero, scale: 3), 1200)
    // An unknown scale counts as 3x.
    XCTAssertEqual(rung(48, 0), 240)
    // A 3:2 artist photo cropped into a 150pt circle needs its width too.
    XCTAssertEqual(
      CoverImageStore.decodePixels(
        for: CGSize(width: 150, height: 150),
        scale: 3,
        aspect: Images.assumedPhotoAspect
      ),
      800
    )
  }

  func testTheThumbServesRungsItHolds() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImageLadderTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let full = dir.appendingPathComponent("al-1.jpg").path
    FileManager.default.createFile(atPath: full, contents: Data([0]))

    // No thumb yet: every rung reads the full cover.
    XCTAssertEqual(CoverImageStore.decodeKey(forFullPath: full, rung: 240).path, full)

    let thumb = CoverImageStore.thumbPath(forFullPath: full)
    FileManager.default.createFile(atPath: thumb, contents: Data([0]))
    XCTAssertEqual(CoverImageStore.decodeKey(forFullPath: full, rung: 120).path, thumb)
    XCTAssertEqual(CoverImageStore.decodeKey(forFullPath: full, rung: 480).path, thumb)
    XCTAssertEqual(CoverImageStore.decodeKey(forFullPath: full, rung: 800).path, full)
    XCTAssertEqual(CoverImageStore.decodeKey(forFullPath: full, rung: 1200).path, full)
    let hero = CoverImageStore.decodeKey(
      forFullPath: full,
      size: CGSize(width: 360, height: 360),
      scale: 3
    )
    XCTAssertEqual(hero, CoverDecodeKey(path: full, maxPixel: 1200))
  }

  func testManifestCarriesTheLadderPhotoBesideTheOldFields() throws {
    let json = """
    {"albums":[
      {"artist_name":"A","album_name":"X","artist_image_url":"https://media.cassette.digital/artists/a/original.jpg",
       "artist_thumb_url":null,"cover_url":null,"cover_thumb_url":null,"content_version":"v1",
       "artist_image":{"src":"https://media.cassette.digital/i/{rung}/m/artists/a/original.jpg?v=0123abcd","kind":"photo"}},
      {"artist_name":"B","album_name":"Y","artist_image_url":null,"artist_thumb_url":null,
       "cover_url":null,"cover_thumb_url":null,"content_version":"v2"}
    ]}
    """
    let response = try JSONDecoder().decode(
      CassetteDeviceArtworkResponse.self,
      from: Data(json.utf8)
    )
    let first = try XCTUnwrap(response.albums.first)
    XCTAssertEqual(
      first.artistImageUrl,
      "https://media.cassette.digital/artists/a/original.jpg"
    )
    XCTAssertEqual(
      first.artistImage?.url(rung: CoverImageStore.topRung),
      "https://media.cassette.digital/i/1200/m/artists/a/original.jpg?v=0123abcd"
    )
    XCTAssertNil(first.artistImage?.w)
    // An older server, or an album with no photo: no ladder field, still decodes.
    XCTAssertNil(response.albums[1].artistImage)
    // Not a ladder template: no address rather than a wrong one.
    XCTAssertNil(
      CassetteImageRef(src: "https://example.com/a.jpg", w: nil, h: nil, kind: nil)
        .url(rung: 1200)
    )
  }

  /// BUG-891: no Deezer, no Last.fm, ever. The phone refuses their picture hosts, every
  /// country domain and image host included, and leaves every other host alone.
  func testDeezerAndLastFmPictureHostsAreRefused() throws {
    for address in [
      "https://e-cdns-images.dzcdn.net/images/artist/abc/500x500.jpg",
      "https://cdn-images.dzcdn.net/images/cover/abc/1000x1000.jpg",
      "https://api.deezer.com/artist/27/image",
      "https://www.deezer.fr/x.jpg",
      "https://dzr.page.link/abc",
      "https://lastfm.freetls.fastly.net/i/u/300x300/abc.png",
      "https://lastfm-img2.akamaized.net/i/u/abc.png",
      "https://www.last.fm/music/x/+images/abc",
      "https://cn.last.fm/x.jpg",
      "https://www.lastfm.de/x.jpg",
      "https://ws.audioscrobbler.com/2.0/",
      "https://LASTFM.FREETLS.FASTLY.NET/i/u/abc.png",
    ] {
      let url = try XCTUnwrap(URL(string: address))
      XCTAssertTrue(CoverImageStore.isProhibitedPictureHost(url), address)
    }
    for address in [
      "https://media.cassette.digital/i/480/m/artists/a/original.jpg",
      "https://upload.wikimedia.org/wikipedia/commons/a/ab/x.jpg",
      "https://coverartarchive.org/release/abc/front",
      "https://blastfm.example.com/x.jpg",
      "https://notdeezer.com/x.jpg",
      "http://192.168.1.20:4533/rest/getCoverArt",
    ] {
      let url = try XCTUnwrap(URL(string: address))
      XCTAssertFalse(CoverImageStore.isProhibitedPictureHost(url), address)
    }
  }
}
