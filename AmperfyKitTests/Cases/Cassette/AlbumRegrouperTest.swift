//
//  AlbumRegrouperTest.swift
//  AmperfyKitTests
//
//  Cassette fork — Phase 1 (Gap 1): device album grouping. Proves the Job 4
//  outcomes against the in-memory Core Data stack: a split album collapses to
//  one group-key album, a box-set pair stays two albums (catalog-blind), the
//  owned-track count is invariant, and an unowned "ghost" album is untouched.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

@testable import AmperfyKit
import CoreData
import XCTest

@MainActor
class AlbumRegrouperTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var context: NSManagedObjectContext!

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    context = cdHelper.persistentContainer.viewContext
  }

  // A library album as materialization produces it: keyed by a Subsonic id.
  @discardableResult
  private func seedAlbum(id: String, name: String) -> Album {
    let a = library.createAlbum(account: account)
    a.id = id
    a.name = name
    return a
  }

  // A song on `album`. When owned, a DeviceOwnership row carries its Subsonic id
  // (SongMO.id == DeviceOwnership.subsonicTrackId). Returns the Subsonic id.
  @discardableResult
  private func seedSong(id: String, album: Album, owned: Bool) -> String {
    let s = library.createSong(account: account)
    s.id = id
    s.album = album
    if owned {
      let mo = DeviceOwnershipMO(context: context)
      mo.cassetteLocalId = "lid-\(id)"
      mo.subsonicTrackId = id
      mo.mbid = nil
      mo.filePath = "lid-\(id).mp3"
      mo.downloadedAt = Date()
      mo.fileSizeBytes = 0
    }
    return id
  }

  // Build a grouping item directly. The group key carries a real NUL separator
  // (as buildAlbumGroupKey emits) — fine in a Swift String, so the synthesized
  // memberwise init (internal, reachable via @testable) is used rather than JSON
  // (JSON rejects an unescaped control character).
  private func item(
    sid: String, key: String, album: String, artist: String, artistKey: String? = nil
  )
    -> CassetteDeviceGroupingItem {
    CassetteDeviceGroupingItem(
      cassetteLocalId: "lid-\(sid)",
      subsonicTrackId: sid,
      groupKey: key,
      displayAlbum: album,
      displayArtist: artist,
      artistGroupKey: artistKey,
      albumArtRef: nil,
      trackTitle: nil,
      duration: nil,
      discTrackIndex: nil,
      year: nil
    )
  }

  // NUL-separated keys, exactly as buildAlbumGroupKey emits them.
  private let laufeyKey = "laufey\u{0}a matter of time the final hour"
  private let hybridKey = "linkin park\u{0}hybrid theory"
  private let meteoraKey = "linkin park\u{0}meteora"

  /// Seed the Job 4 scenario and return the grouping payload + the owned set.
  private func seedScenario() -> [CassetteDeviceGroupingItem] {
    var items: [CassetteDeviceGroupingItem] = []

    // Laufey: TWO Subsonic albums (main 3 tracks + a 1-track "Clockwork" split)
    // that share ONE group key.
    let laMain = seedAlbum(id: "subs-la-main", name: "A Matter of Time: The Final Hour")
    let laClock = seedAlbum(id: "subs-la-clock", name: "Clockwork")
    for i in 1 ... 3 {
      let sid = seedSong(id: "la-\(i)", album: laMain, owned: true)
      items.append(item(
        sid: sid,
        key: laufeyKey,
        album: "A Matter of Time: The Final Hour",
        artist: "Laufey"
      ))
    }
    let lc = seedSong(id: "la-clock", album: laClock, owned: true)
    items.append(item(
      sid: lc,
      key: laufeyKey,
      album: "A Matter of Time: The Final Hour",
      artist: "Laufey"
    ))

    // Linkin Park: Hybrid Theory + Meteora → DISTINCT keys (must NOT merge).
    let ht = seedAlbum(id: "subs-ht", name: "Hybrid Theory")
    let me = seedAlbum(id: "subs-me", name: "Meteora")
    let htS = seedSong(id: "ht-1", album: ht, owned: true)
    items.append(item(sid: htS, key: hybridKey, album: "Hybrid Theory", artist: "Linkin Park"))
    let meS = seedSong(id: "me-1", album: me, owned: true)
    items.append(item(sid: meS, key: meteoraKey, album: "Meteora", artist: "LINKIN PARK"))

    // Eve 6 GHOST: an album with an UNOWNED song, absent from the payload. The
    // regroup must leave it entirely alone (Phase 2 prunes ghosts, not Phase 1).
    let eve = seedAlbum(id: "subs-eve", name: "Horrorscope")
    _ = seedSong(id: "eve-ghost", album: eve, owned: false)

    try! context.save()
    return items
  }

  // The present-key path: two spellings of one artist ("Fun"/"fun.") resolve to ONE
  // cloud identity; existing synthetic rows are re-keyed/folded onto it and the emptied
  // loser is purged. Guards the CORE of the artist-identity anchor — the other tests
  // pass a nil key and so exercise only the legacy fallback.
  func testArtistIdentityAnchorFoldsSpellingsAndPurgesSynthetic() throws {
    // On-device-only mode is the anchor's precondition (Server Mode never re-keys).
    UserDefaults.standard.set(false, forKey: CassetteLibraryFilterProvider.serverModeDefaultsKey)

    let albA = seedAlbum(id: "subs-fun-a", name: "Some Nights")
    let albB = seedAlbum(id: "subs-fun-b", name: "Aim and Ignite")
    let sA = seedSong(id: "fun-a", album: albA, owned: true)
    let sB = seedSong(id: "fun-b", album: albB, owned: true)
    // Pre-anchor world: each spelling is its OWN synthetic artist, owning its song+album.
    let synthFun = library.createArtist(account: account)
    synthFun.id = "cassette-synth-artist:Fun"
    synthFun.name = "Fun"
    let synthFunDot = library.createArtist(account: account)
    synthFunDot.id = "cassette-synth-artist:fun."
    synthFunDot.name = "fun."
    library.getSong(for: account, id: sA)?.artist = synthFun
    library.getSong(for: account, id: sB)?.artist = synthFunDot
    albA.artist = synthFun
    albB.artist = synthFunDot
    // BUG-98: what the person gave each spelling. "fun." is the one that folds away.
    let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    let later = Date(timeIntervalSince1970: 1_750_000_000)
    synthFun.rating = 2
    synthFun.playCount = 3
    synthFun.starredDate = later
    synthFunDot.rating = 4
    synthFunDot.playCount = 7
    synthFunDot.starredDate = earlier
    synthFunDot.isFavorite = true
    try context.save()

    let artistKey = "inherited-artist:fun"
    let items = [
      item(
        sid: sA,
        key: "fun\u{0}some nights",
        album: "Some Nights",
        artist: "Fun",
        artistKey: artistKey
      ),
      item(
        sid: sB,
        key: "fun\u{0}aim and ignite",
        album: "Aim and Ignite",
        artist: "fun.",
        artistKey: artistKey
      ),
    ]

    let summary = AlbumRegrouper(context: context).regroup(items: items, accountInfo: account.info)

    // Exactly ONE artist under the cloud identity; both synthetic rows gone.
    XCTAssertNotNil(
      library.getArtist(for: account, id: artistKey),
      "anchored on the cloud identity"
    )
    XCTAssertNil(
      library.getArtist(for: account, id: "cassette-synth-artist:Fun"),
      "Fun re-keyed onto identity"
    )
    XCTAssertNil(
      library.getArtist(for: account, id: "cassette-synth-artist:fun."),
      "fun. folded + purged"
    )
    XCTAssertGreaterThanOrEqual(summary.purgedArtists, 1, "the emptied loser synthetic is purged")

    // BUG-98: the folded spelling's annotations live on in the identity, not lost with it.
    let identity = try XCTUnwrap(library.getArtist(for: account, id: artistKey))
    XCTAssertEqual(identity.rating, 4, "highest rating kept")
    XCTAssertEqual(identity.playCount, 10, "plays added up")
    XCTAssertEqual(identity.starredDate, earlier, "earliest star kept")
    XCTAssertTrue(identity.isFavorite, "a favourite on either stays a favourite")

    // Both group albums' artist line resolves to that one identity.
    let gotA = library.getAlbum(
      for: account,
      id: "fun\u{0}some nights",
      isDetailFaultResolution: false
    )
    let gotB = library.getAlbum(
      for: account,
      id: "fun\u{0}aim and ignite",
      isDetailFaultResolution: false
    )
    XCTAssertEqual(gotA?.artist?.id, artistKey)
    XCTAssertEqual(gotB?.artist?.id, artistKey)

    // Idempotent: a second pass folds nothing, purges nothing.
    let again = AlbumRegrouper(context: context).regroup(items: items, accountInfo: account.info)
    XCTAssertEqual(again.movedSongs, 0, "steady state: no moves")
    XCTAssertEqual(again.purgedArtists, 0, "steady state: nothing to purge")
    XCTAssertEqual(
      library.getArtist(for: account, id: artistKey)?.playCount,
      10,
      "plays never counted twice"
    )
  }

  func testRegroupCollapsesSplitKeepsBoxSetSeparatePreservesGhost() throws {
    let items = seedScenario()
    let manager = DeviceOwnershipManager(context: context)
    let ownedBefore = manager.fetchAllSubsonicTrackIds()
    XCTAssertEqual(ownedBefore.count, 6) // Laufey 4 + Hybrid 1 + Meteora 1
    let songsBefore = library.getSongs(for: account).count

    let summary = AlbumRegrouper(context: context).regroup(items: items, accountInfo: account.info)

    // Laufey → ONE album, all 4 owned tracks (live tracklist + cached count),
    // label == display_album.
    let laufey = library.getAlbum(for: account, id: laufeyKey, isDetailFaultResolution: false)
    XCTAssertNotNil(laufey, "Laufey group album exists")
    XCTAssertEqual(laufey?.songs.count, 4, "all Laufey tracks collapse onto one album")
    XCTAssertEqual(laufey?.songCount, 4, "cached song count refreshed")
    XCTAssertEqual(laufey?.name, "A Matter of Time: The Final Hour")
    // The split legacy albums are emptied and removed.
    XCTAssertNil(library.getAlbum(for: account, id: "subs-la-main", isDetailFaultResolution: false))
    XCTAssertNil(library.getAlbum(
      for: account,
      id: "subs-la-clock",
      isDetailFaultResolution: false
    ))

    // Hybrid Theory and Meteora stay TWO separate albums.
    let ht = library.getAlbum(for: account, id: hybridKey, isDetailFaultResolution: false)
    let me = library.getAlbum(for: account, id: meteoraKey, isDetailFaultResolution: false)
    XCTAssertNotNil(ht)
    XCTAssertNotNil(me)
    XCTAssertEqual(ht?.songCount, 1)
    XCTAssertEqual(me?.songCount, 1)
    XCTAssertNotEqual(hybridKey, meteoraKey)

    // Eve 6 ghost untouched — proves nothing was removed.
    XCTAssertNotNil(
      library.getAlbum(for: account, id: "subs-eve", isDetailFaultResolution: false),
      "Eve 6 ghost still present"
    )

    // Owned-track count + total song count invariant.
    XCTAssertEqual(manager.fetchAllSubsonicTrackIds(), ownedBefore, "owned set unchanged")
    XCTAssertEqual(library.getSongs(for: account).count, songsBefore, "no song added/removed")
    XCTAssertEqual(summary.movedSongs, 6)
    XCTAssertEqual(summary.groups, 3)
    // The 4 emptied legacy Subsonic albums (2 Laufey + Hybrid + Meteora) are
    // purged; purge sweeps ALL empties, so seeded fixtures may add a few more.
    XCTAssertGreaterThanOrEqual(summary.purgedAlbums, 4)
    XCTAssertNil(library.getAlbum(for: account, id: "subs-ht", isDetailFaultResolution: false))
    XCTAssertNil(library.getAlbum(for: account, id: "subs-me", isDetailFaultResolution: false))
  }

  func testRegroupIsIdempotent() throws {
    let items = seedScenario()
    let regrouper = AlbumRegrouper(context: context)
    _ = regrouper.regroup(items: items, accountInfo: account.info)
    let second = regrouper.regroup(items: items, accountInfo: account.info)
    XCTAssertEqual(second.movedSongs, 0, "second run is a no-op")
    XCTAssertEqual(second.purgedAlbums, 0, "nothing left to purge on a second run")
    XCTAssertEqual(
      library.getAlbum(for: account, id: laufeyKey, isDetailFaultResolution: false)?.songCount,
      4
    )
  }
}
