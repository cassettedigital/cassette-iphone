//
//  KeepPlaying.swift
//  AmperfyKit
//
//  cassette (founder, 2026-11-02): when the queue runs out, the music keeps going. What
//  started it decides how: an album carries on with another whole album, anything else
//  (a mix, a playlist, one song from search, an artist on shuffle) carries on with songs.
//  The pick is the cloud's (POST /api/sync/keep-playing: the made-for-you recipe seeded from
//  the queue, founder 2026-11-02), and so is the call between album and songs and the words
//  under THEN: one algorithm for every surface (apps/cassette/src/lib/keep-playing/contract.ts).
//  The phone sends what started the queue and asks as each song starts, so the answer is held
//  before the queue runs out. Until it comes, and whenever it cannot (offline, an error), the phone picks from its own
//  music with the maths the album page's MORE LIKE and the old Lately draw use, so it still
//  works in the car. Repeat wins: with repeat on, keep playing steps aside until repeat is off.
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

import Foundation

@MainActor
public final class KeepPlaying {
  public static let shared = KeepPlaying()

  /// Posted on the main actor when what comes next may read differently: the switch moved,
  /// a pick was swapped or trimmed, or the phone's mood index landed.
  public static let didChange = Notification.Name("cassette.keepPlayingChanged")

  public enum Kind: String {
    case album
    case songs
  }

  /// What plays when the queue runs out.
  public struct Pick {
    public let kind: Kind
    /// The record that plays next (album kind only).
    public let album: Album?
    /// What plays, in order, all of it on this phone.
    public let songs: [AbstractPlayable]
    /// The heading's answer: "a record like it", "more by Laufey", "more like this".
    public let answer: String
  }

  /// The queue as it stands: what has played, what plays now, what is queued by hand and
  /// what comes next from the context.
  public struct Queue {
    public let prev: [AbstractPlayable]
    public let current: AbstractPlayable?
    public let user: [AbstractPlayable]
    public let next: [AbstractPlayable]

    public init(
      prev: [AbstractPlayable],
      current: AbstractPlayable?,
      user: [AbstractPlayable],
      next: [AbstractPlayable]
    ) {
      self.prev = prev
      self.current = current
      self.user = user
      self.next = next
    }

    /// Songs in play order, oldest first.
    var songs: [Song] {
      (prev + [current].compactMap { $0 } + user + next).compactMap(\.asSong)
    }

    /// The song the context ends on: the one the next pick has to follow.
    var lastSong: Song? {
      (next.last ?? current)?.asSong
    }
  }

  /// The app's rule for what this phone can play (`OneTapPlay.playables`), set at launch.
  /// The kit cannot see it, and nothing that is not on the phone may be queued.
  public var playableFilter: @MainActor ([AbstractPlayable]) -> [AbstractPlayable] = { $0 }

  private static let onKey = "cassette.keepPlaying"
  private static let kindKey = "cassette.keepPlaying.kind"
  private static let startedKey = "cassette.keepPlaying.started"
  /// How many songs one songs pick holds; the next pick follows on when they run out.
  private static let songsPerPick = 20
  /// Albums ranked for one album pick; Swap walks down them.
  private static let albumsPerPick = 8

  /// On unless the person turned it off (the default is on, as Apple Music's Autoplay is).
  public var isOn: Bool {
    get { UserDefaults.standard.object(forKey: Self.onKey) as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.onKey)
      changed()
    }
  }

  /// Whether keep playing acts now: on, and repeat off.
  public func isActive(repeatMode: RepeatMode) -> Bool {
    isOn && repeatMode == .off
  }

  /// What started the queue (or the last pick added), by song id, kept across launches with the
  /// queue: the cloud reads album or songs from it.
  private var startedSongIDs: [String] {
    get { UserDefaults.standard.stringArray(forKey: Self.startedKey) ?? [] }
    set { UserDefaults.standard.set(newValue, forKey: Self.startedKey) }
  }

  /// How the queue was started, by the phone's own rule: for its stand-in pick only (the cloud
  /// decides for itself from `startedSongIDs`). Kept across launches with the queue.
  public private(set) var kind: Kind {
    get { Kind(rawValue: UserDefaults.standard.string(forKey: Self.kindKey) ?? "") ?? .songs }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.kindKey) }
  }

  /// The ranked albums or drawn songs for one seed, so the THEN row holds still while the
  /// queue plays and Swap has somewhere to go.
  private struct Entry {
    let key: String
    var albums: [(album: Album, songs: [AbstractPlayable])]
    /// The words under THEN: the cloud's when it answered, else the phone's own.
    var heading: String
    var cursor: Int
    var songs: [AbstractPlayable]
    /// The cloud's answer, not the phone's stand-in.
    var fromCloud = false
  }

  private var entry: Entry?
  /// The cloud's answer for the last seed asked about, kept apart so Swap can come back to it.
  private var cloudEntry: Entry?
  /// Seeds already asked about: one ask per seed, answered or not.
  private var askedCloud = Set<String>()
  /// Whether the last answer came back empty only because the mood index was still building.
  private var waitingForIndex = false

  private init() {
    NotificationCenter.default.addObserver(
      forName: .cassetteMoodIndexReady,
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        guard KeepPlaying.shared.waitingForIndex else { return }
        KeepPlaying.shared.waitingForIndex = false
        KeepPlaying.shared.changed()
      }
    }
  }

  /// A queue was started from `playables`: two or more songs from one record make it an
  /// album (tapping any song on an album page plays the whole record), anything else songs.
  public func noteStarted(playables: [AbstractPlayable]) {
    let songs = playables.compactMap(\.asSong)
    let albums = Set(songs.compactMap { $0.album?.id })
    kind = songs.count >= 2 && albums.count == 1 ? .album : .songs
    startedSongIDs = songs.map(\.id)
    entry = nil
    cloudEntry = nil
    askedCloud.removeAll()
  }

  /// What plays when `queue` runs out, or nil when there is nothing that fits (or the
  /// phone's mood index is still building; `didChange` follows when it lands). Never
  /// blocks: for the queue sheet.
  public func upcoming(queue: Queue) -> Pick? {
    pick(for: queue, waitForIndex: false)
  }

  /// A song has started: work the pick out now (the cloud is asked once per queue end, the
  /// phone's index builds off the main thread), so it is held well before the queue runs out,
  /// even if the phone goes offline in between.
  public func prepare(queue: Queue) {
    _ = pick(for: queue, waitForIndex: false)
  }

  /// The pick for `queue`, read in full if the index is not built yet, and forgotten once
  /// taken: the player appends it to the queue.
  public func take(queue: Queue) -> Pick? {
    let result = pick(for: queue, waitForIndex: true)
    entry = nil
    return result
  }

  /// Swap: the next album down the list, or a fresh draw of songs.
  public func swap() {
    guard var current = entry else { return }
    if current.albums.isEmpty {
      entry = nil
    } else {
      current.cursor += 1
      entry = current.cursor < current.albums.count ? current : nil
    }
    changed()
  }

  /// Leave one song out of the songs to come.
  public func skip(songID: String) {
    guard var current = entry else { return }
    current.songs.removeAll { $0.asSong?.id == songID }
    entry = current
    changed()
  }

  // MARK: - Picking

  private func changed() {
    NotificationCenter.default.post(name: Self.didChange, object: nil)
  }

  private func pick(for queue: Queue, waitForIndex: Bool) -> Pick? {
    guard let seed = queue.lastSong else { return nil }
    let key = seedKey(queue: queue, seed: seed)
    askCloud(key: key, queue: queue, seed: seed)
    if entry?.key != key {
      if let cloudEntry, cloudEntry.key == key {
        entry = cloudEntry
      } else {
        guard let built = build(key: key, queue: queue, seed: seed, waitForIndex: waitForIndex)
        else { return nil }
        entry = built
      }
    }
    guard let entry else { return nil }
    if !entry.albums.isEmpty {
      guard entry.cursor < entry.albums.count else { return nil }
      let choice = entry.albums[entry.cursor]
      return Pick(kind: .album, album: choice.album, songs: choice.songs, answer: entry.heading)
    }
    guard !entry.songs.isEmpty else { return nil }
    return Pick(kind: .songs, album: nil, songs: entry.songs, answer: entry.heading)
  }

  // MARK: - The cloud's pick

  /// Ask the cloud once per seed. Its answer replaces the phone's stand-in when it lands (if
  /// the queue still ends the same way), and THEN redraws.
  private func askCloud(key: String, queue: Queue, seed: Song) {
    guard !askedCloud.contains(key), let account = seed.account else { return }
    askedCloud.insert(key)
    let localIDBySongID = Self.localIDsBySongID()
    let songs = queue.songs
    let seedIDs = songs.suffix(10).compactMap { localIDBySongID[$0.id] }
    guard !seedIDs.isEmpty else { return }
    let exclude = songs.compactMap { localIDBySongID[$0.id] }
    let started = startedSongIDs.compactMap { localIDBySongID[$0] }
    let kind = kind
    Task { @MainActor in
      let answer: KeepPlayingAnswer
      do {
        answer = try await CassetteSyncAPI.shared.postKeepPlaying(
          kind: kind.rawValue,
          started: started,
          seed: seedIDs,
          exclude: exclude,
          timeZone: TimeZone.current.identifier
        )
      } catch {
        // the phone's own pick stands; a later seed asks again
        print("Cassette keep playing: cloud ask failed - \(error.localizedDescription)")
        return
      }
      guard let built = self.entry(from: answer, key: key, account: account, seed: seed) else { return }
      self.cloudEntry = built
      guard self.entry == nil || self.entry?.key == key else { return }
      self.entry = built
      self.changed()
    }
  }

  /// The cloud's answer as songs on this phone: each record by any of its songs the phone
  /// holds (played as the phone holds the record), songs in the cloud's order. Nil when the
  /// phone holds none of it.
  private func entry(from answer: KeepPlayingAnswer, key: String, account: Account, seed: Song) -> Entry? {
    let songIDByLocalID = Self.songIDsByLocalID()
    let library = AmperKit.shared.storage.main.library
    switch answer.kind {
    case "album":
      var seen: Set<String> = [seed.album?.id ?? ""]
      var albums = [(album: Album, songs: [AbstractPlayable])]()
      for record in answer.records ?? [] {
        let ids = Set(record.songs.compactMap { songIDByLocalID[$0] })
        guard let album = library.getSongsByID(for: account, ids: ids).values
          .sorted(by: { $0.id < $1.id })
          .lazy.compactMap(\.album).first,
          seen.insert(album.id).inserted
        else { continue }
        let songs = playableFilter(album.playables)
        if !songs.isEmpty { albums.append((album, songs)) }
      }
      guard !albums.isEmpty else { return nil }
      let heading = answer.heading?.answer ?? (answer.answer == "more-by"
        ? "more by \(seed.album?.artist?.name ?? seed.creatorName)"
        : "a record like it")
      return Entry(key: key, albums: albums, heading: heading, cursor: 0, songs: [], fromCloud: true)
    case "songs":
      let ids = (answer.songs ?? []).compactMap { songIDByLocalID[$0] }
      let byID = library.getSongsByID(for: account, ids: Set(ids))
      let songs = playableFilter(ids.compactMap { byID[$0] })
      guard !songs.isEmpty else { return nil }
      return Entry(
        key: key,
        albums: [],
        heading: answer.heading?.answer ?? "more like this",
        cursor: 0,
        songs: songs,
        fromCloud: true
      )
    default:
      return nil
    }
  }

  /// The phone's song id for each cassette_local_id it holds (newest download first, the rule
  /// every cloud answer is matched by).
  private static func songIDsByLocalID() -> [String: String] {
    var out = [String: String]()
    for row in (try? DeviceOwnershipManager(context: AmperKit.shared.storage.main.context).fetchAll()) ?? [] {
      let localID = row.cassetteLocalId
      guard !localID.isEmpty, let songID = row.subsonicTrackId, out[localID] == nil else { continue }
      out[localID] = songID
    }
    return out
  }

  private static func localIDsBySongID() -> [String: String] {
    var out = [String: String]()
    for (localID, songID) in songIDsByLocalID() where out[songID] == nil {
      out[songID] = localID
    }
    return out
  }

  /// Albums follow the record the queue ends on; songs follow the last few songs.
  private func seedKey(queue: Queue, seed: Song) -> String {
    switch kind {
    case .album:
      return "album|\(seed.album?.id ?? seed.id)"
    case .songs:
      return "songs|" + queue.songs.suffix(8).map(\.id).joined(separator: ",")
    }
  }

  private func build(key: String, queue: Queue, seed: Song, waitForIndex: Bool) -> Entry? {
    let storage = AmperKit.shared.storage
    guard let account = seed.account else { return nil }
    let index: LatelyLibrary.MoodIndex? = waitForIndex
      ? LatelyLibrary.moodIndex(storage: storage, account: account)
      : LatelyLibrary.moodIndexIfReady(storage: storage, account: account)
    guard let index else {
      waitingForIndex = !waitForIndex
      return nil
    }
    switch kind {
    case .album:
      // With no record that fits, songs like it beat stopping.
      return buildAlbums(key: key, queue: queue, seed: seed, index: index)
        ?? buildSongs(key: key, queue: queue, index: index)
    case .songs:
      return buildSongs(key: key, queue: queue, index: index)
    }
  }

  /// Other artists' records on the phone that sound like the one the queue ends on, best
  /// first, one per artist (the album page's MORE LIKE, matched as loosely as a
  /// playlist's). With none, the same artist's other records, newest first. Records
  /// already in this queue are left out, so it never circles back.
  private func buildAlbums(
    key: String,
    queue: Queue,
    seed: Song,
    index: LatelyLibrary.MoodIndex
  )
    -> Entry? {
    guard let seedAlbum = seed.album else { return nil }
    let heard = Set(queue.songs.compactMap { $0.album?.id })
    let nameOf: (String) -> String = { id in
      ListeningShelves.normalizedArtistName(index.artistNameByAlbumID[id] ?? "")
    }
    let seedArtist = ListeningShelves.normalizedArtistName(
      seedAlbum.artist?.name ?? nameOf(seedAlbum.id)
    )

    var ranked = [Album]()
    var answer = "a record like it"
    if let own = index.albumCandidates.first(where: { $0.albumID == seedAlbum.id }) {
      var profile = ListeningShelves.TagVector()
      for tags in own.songTags { ListeningShelves.add(tags, into: &profile) }
      var excluding = heard
      for candidate in index.albumCandidates {
        let name = nameOf(candidate.albumID)
        if name.isEmpty || name == seedArtist || name == "various artists" {
          excluding.insert(candidate.albumID)
        }
      }
      ranked = ListeningShelves.moreLike(
        profile: profile,
        albums: index.albumCandidates,
        excluding: excluding,
        minMatch: 0.7,
        perArtist: 1,
        limit: Self.albumsPerPick,
        artistKey: { nameOf($0.albumID) }
      ).compactMap { index.albumsByID[$0] }
    }
    if ranked.isEmpty, !seedArtist.isEmpty {
      ranked = index.albumsByID.values
        .filter { !heard.contains($0.id) && nameOf($0.id) == seedArtist }
        .sorted { $0.year != $1.year ? $0.year > $1.year : $0.id < $1.id }
      answer = "more by \(seedAlbum.artist?.name ?? index.artistNameByAlbumID[seedAlbum.id] ?? "them")"
    }
    let playable: [(album: Album, songs: [AbstractPlayable])] = ranked.compactMap { album in
      let songs = playableFilter(album.playables)
      return songs.isEmpty ? nil : (album, songs)
    }
    guard !playable.isEmpty else { return nil }
    return Entry(key: key, albums: playable, heading: answer, cursor: 0, songs: [])
  }

  /// Songs on the phone close to the last few songs (Lately's draw: the closest pool, at
  /// most three per album and per artist), spaced so no artist comes back within a few
  /// songs, and never opening on the artist the queue ends on. Songs already in this queue
  /// are left out.
  private func buildSongs(key: String, queue: Queue, index: LatelyLibrary.MoodIndex) -> Entry? {
    let tagsByID = Dictionary(
      index.songCandidates.map { ($0.songID, $0.tags) },
      uniquingKeysWith: { first, _ in first }
    )
    let artistByID = Dictionary(
      index.songCandidates.map { ($0.songID, $0.artistKey) },
      uniquingKeysWith: { first, _ in first }
    )
    var profile = ListeningShelves.TagVector()
    for song in queue.songs.suffix(8) {
      if let tags = tagsByID[song.id] { ListeningShelves.add(tags, into: &profile) }
    }
    guard !profile.isEmpty else { return nil }
    var rng = SystemRandomNumberGenerator()
    let drawn = ListeningShelves.latelyMix(
      index.songCandidates,
      profile: profile,
      playedRecently: Set(queue.songs.map(\.id)),
      count: Self.songsPerPick,
      using: &rng
    )
    var ids = ListeningShelves.spacedByArtist(drawn, artistOf: { artistByID[$0] ?? "" })
    if let last = queue.lastSong.flatMap({ artistByID[$0.id] }), !last.isEmpty,
       let first = ids.first, artistByID[first] == last,
       let swapAt = ids.firstIndex(where: { artistByID[$0] != last }) {
      ids.swapAt(0, swapAt)
    }
    let songs = playableFilter(ids.compactMap { index.songsByID[$0] })
    guard !songs.isEmpty else { return nil }
    return Entry(key: key, albums: [], heading: "more like this", cursor: 0, songs: songs)
  }
}
