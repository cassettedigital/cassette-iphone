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

  /// BUG-582: a compilation whose files name each song's performer. The cloud keys the album
  /// to "Various Artists"; the first song's own artist row (JAY-Z) must not be re-keyed onto
  /// that identity, or the album reads as JAY-Z's and his songs hang off the compilation.
  func testCompilationDoesNotTakeAPerformersRow() throws {
    UserDefaults.standard.set(false, forKey: CassetteLibraryFilterProvider.serverModeDefaultsKey)

    let gatsby = seedAlbum(id: "subs-gatsby", name: "The Great Gatsby")
    let s1 = seedSong(id: "gatsby-1", album: gatsby, owned: true)
    let s2 = seedSong(id: "gatsby-2", album: gatsby, owned: true)
    let jay = library.createArtist(account: account)
    jay.id = "subs-jayz"
    jay.name = "JAY-Z"
    let lana = library.createArtist(account: account)
    lana.id = "subs-lana"
    lana.name = "Lana Del Rey"
    library.getSong(for: account, id: s1)?.artist = jay
    library.getSong(for: account, id: s2)?.artist = lana
    try context.save()

    let vaKey = "inherited-artist:various artists"
    let groupKey = "various artists\u{0}the great gatsby"
    let items = [
      item(
        sid: s1,
        key: groupKey,
        album: "The Great Gatsby",
        artist: "Various Artists",
        artistKey: vaKey
      ),
      item(
        sid: s2,
        key: groupKey,
        album: "The Great Gatsby",
        artist: "Various Artists",
        artistKey: vaKey
      ),
    ]
    _ = AlbumRegrouper(context: context).regroup(items: items, accountInfo: account.info)

    let identity = try XCTUnwrap(library.getArtist(for: account, id: vaKey))
    XCTAssertEqual(
      identity.name,
      "Various Artists",
      "the compilation's identity carries its own name"
    )
    let jayRow = try XCTUnwrap(library.getArtist(for: account, id: "subs-jayz"))
    XCTAssertEqual(jayRow.name, "JAY-Z", "the performer's row keeps its own identity")
    let album = library.getAlbum(for: account, id: groupKey, isDetailFaultResolution: false)
    XCTAssertEqual(album?.artist?.name, "Various Artists")
  }

  /// BUG-582: the same artist under another spelling still folds; another artist never does.
  func testOnlyTheSameNameMayTakeAnIdentity() {
    let fun = library.createArtist(account: account)
    fun.name = "fun."
    XCTAssertTrue(AlbumRegrouper.mayTakeIdentity(fun, named: "Fun"))
    let acdc = library.createArtist(account: account)
    acdc.name = "AC/DC"
    XCTAssertTrue(AlbumRegrouper.mayTakeIdentity(acdc, named: "ACDC"))
    let jay = library.createArtist(account: account)
    jay.name = "JAY-Z"
    XCTAssertFalse(AlbumRegrouper.mayTakeIdentity(jay, named: "Various Artists"))
    let nameless = library.createArtist(account: account)
    XCTAssertTrue(AlbumRegrouper.mayTakeIdentity(nameless, named: "Various Artists"))
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

  // MARK: BUG-104 seam 2: a purge must not take a survivor's picture

  /// The legacy album's working cover is handed to the group album, and then the emptied legacy
  /// album is deleted. The owner-to-artwork link cascades, so a cover that was shared instead of
  /// moved went with it and the group album lost it.
  func testCoverHandedToTheGroupAlbumSurvivesThePurgeOfItsLegacyAlbum() throws {
    UserDefaults.standard.set(false, forKey: CassetteLibraryFilterProvider.serverModeDefaultsKey)
    let legacy = seedAlbum(id: "subs-cover-legacy", name: "Cover Album")
    let sid = seedSong(id: "cover-1", album: legacy, owned: true)
    let rel = try XCTUnwrap(URL(string: "bug104-legacy-cover.png"))
    let abs = try XCTUnwrap(CacheFileManager.shared.getAbsoluteAmperfyPath(relFilePath: rel))
    try CacheFileManager.shared.writeDataExcludedFromBackup(
      data: Data([1, 2, 3]),
      to: abs,
      accountInfo: account.info
    )
    defer { try? FileManager.default.removeItem(at: abs) }
    let cover = library.createArtwork(account: account)
    cover.relFilePath = rel
    cover.status = .CustomImage
    legacy.artwork = cover
    try context.save()
    XCTAssertNotNil(legacy.artwork?.imagePath, "the legacy cover is on disk")

    let key = "cover band\u{0}cover album"
    _ = AlbumRegrouper(context: context).regroup(
      items: [item(sid: sid, key: key, album: "Cover Album", artist: "Cover Band")],
      accountInfo: account.info
    )

    XCTAssertNil(
      library.getAlbum(for: account, id: "subs-cover-legacy", isDetailFaultResolution: false),
      "the emptied legacy album is purged"
    )
    let group = try XCTUnwrap(library.getAlbum(
      for: account,
      id: key,
      isDetailFaultResolution: false
    ))
    XCTAssertNotNil(group.artwork, "the group album still has its artwork row")
    XCTAssertNotNil(group.artwork?.imagePath, "and its cover is still on disk")
  }

  /// A folded synthetic artist that shares a picture with the identity it folded into goes, and
  /// the identity keeps the picture.
  func testPurgingAFoldedArtistDoesNotTakeTheIdentitysPicture() throws {
    UserDefaults.standard.set(false, forKey: CassetteLibraryFilterProvider.serverModeDefaultsKey)
    let album = seedAlbum(id: "subs-share-a", name: "Shared Picture")
    let sid = seedSong(id: "share-1", album: album, owned: true)
    let artistKey = "inherited-artist:sharer"
    let winner = library.createArtist(account: account)
    winner.id = artistKey
    winner.name = "Sharer"
    let loser = library.createArtist(account: account)
    loser.id = "cassette-synth-artist:Sharer (old)"
    loser.name = "Sharer (old)"
    let photo = library.createArtwork(account: account)
    photo.remoteInfo = ArtworkRemoteInfo(id: artistKey, type: "artist")
    winner.artwork = photo
    loser.artwork = photo
    library.getSong(for: account, id: sid)?.artist = winner
    album.artist = winner
    try context.save()

    _ = AlbumRegrouper(context: context).regroup(
      items: [item(
        sid: sid,
        key: "sharer\u{0}shared picture",
        album: "Shared Picture",
        artist: "Sharer",
        artistKey: artistKey
      )],
      accountInfo: account.info
    )

    XCTAssertNil(
      library.getArtist(for: account, id: "cassette-synth-artist:Sharer (old)"),
      "the ownerless synthetic artist is purged"
    )
    let kept = try XCTUnwrap(library.getArtist(for: account, id: artistKey))
    XCTAssertNotNil(kept.artwork, "the identity keeps its picture row")
  }

  /// What only the purged row held goes with it, as before.
  func testPurgingAnArtistTakesItsOwnPictureWithIt() throws {
    UserDefaults.standard.set(false, forKey: CassetteLibraryFilterProvider.serverModeDefaultsKey)
    let album = seedAlbum(id: "subs-own-a", name: "Own Picture")
    let sid = seedSong(id: "own-1", album: album, owned: true)
    let loser = library.createArtist(account: account)
    loser.id = "cassette-synth-artist:Gone"
    loser.name = "Gone"
    let photo = library.createArtwork(account: account)
    photo.remoteInfo = ArtworkRemoteInfo(id: loser.id, type: "artist")
    loser.artwork = photo
    let photoID = photo.managedObject.objectID
    try context.save()

    _ = AlbumRegrouper(context: context).regroup(
      items: [item(sid: sid, key: "own\u{0}own picture", album: "Own Picture", artist: "Own")],
      accountInfo: account.info
    )

    XCTAssertNil(library.getArtist(for: account, id: "cassette-synth-artist:Gone"))
    XCTAssertNil(try? context.existingObject(with: photoID), "no orphaned artwork row is left")
  }
}
