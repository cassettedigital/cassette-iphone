//
//  Album.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 31.12.19.
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

import CoreData
import Foundation
import UIKit

// MARK: - Album

public class Album: AbstractLibraryEntity {
  public let managedObject: AlbumMO

  public init(managedObject: AlbumMO) {
    self.managedObject = managedObject
    super.init(managedObject: managedObject)
  }

  /// Cassette Layer 1 (Identity): embedded MusicBrainz release id from Subsonic (optional).
  public var musicBrainzId: String? {
    get { managedObject.musicBrainzId }
    set {
      if managedObject.musicBrainzId != newValue {
        managedObject.musicBrainzId = newValue
      }
    }
  }

  override public func imagePath(setting: ArtworkDisplayPreference) -> String? {
    super.imagePath(setting: setting)
  }

  private var embeddedArtworkImagePath: String? {
    songs.lazy.compactMap { $0.embeddedArtwork }.first?.imagePath
  }

  public var identifier: String {
    name
  }

  public var name: String {
    get { managedObject.name ?? "Unknown Album" }
    set {
      if managedObject.name != newValue {
        managedObject.name = newValue
        updateAlphabeticSectionInitial(section: newValue)
      }
    }
  }

  public var year: Int {
    get { Int(managedObject.year) }
    set {
      guard Int16.isValid(value: newValue), managedObject.year != Int16(newValue) else { return }
      managedObject.year = Int16(newValue)
    }
  }

  /// Display label for the album release type, e.g. "Album", "EP", "Single", "Compilation".
  /// Falls back to "Album" when no OpenSubsonic releaseTypes were parsed.
  public var albumType: String {
    managedObject.albumType ?? "Album"
  }

  /// Raw nullable accessor used by the parser to write the parsed value.
  /// UI should prefer `albumType`, which provides the human-readable fallback.
  public var albumTypeRaw: String? {
    get { managedObject.albumType }
    set {
      if managedObject.albumType != newValue {
        managedObject.albumType = newValue
      }
    }
  }

  public var duration: Int { Int(managedObject.duration) }

  public var remoteDuration: Int {
    get { Int(managedObject.remoteDuration) }
    set {
      if managedObject.remoteDuration != Int64(newValue) {
        managedObject.remoteDuration = Int64(newValue)
      }
      if managedObject.duration != Int64(newValue) {
        managedObject.duration = Int64(newValue)
      }
    }
  }

  public var isCached: Bool {
    get { managedObject.isCached }
    set {
      if managedObject.isCached != newValue {
        managedObject.isCached = newValue
      }
    }
  }

  public var artist: Artist? {
    get {
      guard let artistMO = managedObject.artist else { return nil }
      return Artist(managedObject: artistMO)
    }
    set {
      if managedObject.artist != newValue?
        .managedObject { managedObject.artist = newValue?.managedObject }
    }
  }

  public var genre: Genre? {
    get {
      guard let genreMO = managedObject.genre else { return nil }
      return Genre(managedObject: genreMO)
    }
    set {
      if managedObject.genre != newValue?
        .managedObject { managedObject.genre = newValue?.managedObject }
    }
  }

  public var isSongsMetaDataSynced: Bool {
    get { managedObject.isSongsMetaDataSynced }
    set { managedObject.isSongsMetaDataSynced = newValue }
  }

  public func updateIsNewestInfo(index: Int) {
    guard Int16.isValid(value: index), managedObject.newestIndex != index else { return }
    managedObject.newestIndex = Int16(index)
  }

  public func markAsNotNewAnymore() {
    managedObject.newestIndex = 0
  }

  public func updateIsRecentInfo(index: Int) {
    guard Int16.isValid(value: index), managedObject.recentIndex != index else { return }
    managedObject.recentIndex = Int16(index)
  }

  public func markAsNotRecentAnymore() {
    managedObject.recentIndex = 0
  }

  public var remoteSongCount: Int {
    get {
      Int(managedObject.remoteSongCount)
    }
    set {
      guard Int16.isValid(value: newValue),
            managedObject.remoteSongCount != Int16(newValue) else { return }
      managedObject.remoteSongCount = Int16(newValue)
    }
  }

  public var songCount: Int {
    let moSongCount = Int(managedObject.songCount)
    let moRemoteSongCount = Int(managedObject.remoteSongCount)
    return moSongCount != 0 ? moSongCount : moRemoteSongCount
  }

  public var songs: [AbstractPlayable] {
    guard let songsSet = managedObject.songs,
          let songsMO = songsSet.array as? [SongMO] else { return [Song]() }
    var returnSongs = [Song]()
    for songMO in songsMO {
      returnSongs.append(Song(managedObject: songMO))
    }
    return returnSongs.sortByTrackNumber()
  }

  public var playables: [AbstractPlayable] { songs }

  // cassette (Forgotten Albums, v53): turnover state + cold-tier feedback
  // primitives. lastSurfacedOnHomeDate is read by the shelf's turnover selection;
  // the two counters are the durable lifetime primitives folded from the hot log.
  public var lastSurfacedOnHomeDate: Date? {
    get { managedObject.lastSurfacedOnHomeDate }
    set { managedObject.lastSurfacedOnHomeDate = newValue }
  }

  public var timesSurfacedLifetime: Int32 {
    get { managedObject.timesSurfacedLifetime }
    set { managedObject.timesSurfacedLifetime = newValue }
  }

  public var timesOpenedFromShelfLifetime: Int32 {
    get { managedObject.timesOpenedFromShelfLifetime }
    set { managedObject.timesOpenedFromShelfLifetime = newValue }
  }

  public var isOrphaned: Bool {
    identifier == "Unknown (Orphaned)"
  }

  override public func getDefaultArtworkType() -> ArtworkType {
    .album
  }

  public func markAsRemoteDeleted() {
    remoteStatus = .deleted
    songs.forEach {
      $0.remoteStatus = .deleted
    }
  }
}

// MARK: PlayableContainable

extension Album: PlayableContainable {
  public var subtitle: String? { artist?.name }
  public var subsubtitle: String? { nil }
  // cassette 2026-10-31 (I-V6): one way to write an album's facts, the album page's:
  // "2007 · 8 songs · 32 min" (was "8 Songs · Year 2007 · Genre: Rock · 32m" here).
  public func infoDetails(for api: ServerApiType?, details: DetailInfoType) -> [String] {
    var infoContent = [String]()
    if details.type == .long, year > 0 {
      infoContent.append("\(year)")
    }
    if songCount == 1 {
      infoContent.append("1 song")
    } else if songCount > 1 {
      infoContent.append("\(songCount) songs")
    }
    if details.type == .short, details.isShowAlbumDuration, duration > 0 {
      infoContent.append(duration.asRecordMinutes)
    }
    if details.type == .long {
      if duration > 0 {
        infoContent.append(duration.asRecordMinutes)
      }
      if isCached {
        infoContent.append("Downloaded")
      }
      if details.isShowDetailedInfo {
        infoContent.append("ID: \(!id.isEmpty ? id : "-")")
      }
    }
    return infoContent
  }

  public var playContextType: PlayerMode { .music }
  public var isRateable: Bool { true }
  public var isFavoritable: Bool { true }
  @MainActor
  public func remoteToggleFavorite(syncer: LibrarySyncer) async throws {
    guard let context = managedObject.managedObjectContext else {
      throw BackendError.persistentSaveFailed
    }
    // cassette Patch 040: optimistic toggle with rollback. Same
    // pattern as AbstractPlayable.remoteToggleFavorite — flip
    // eagerly so the heart in EntityPreviewVC / album header feels
    // instant, then restore the prior value if the server call
    // fails so the UI ends up in sync with the server.
    let originalValue = isFavorite
    isFavorite.toggle()
    let library = LibraryStorage(context: context)
    library.saveContext()
    do {
      try await syncer.setFavorite(album: self, isFavorite: isFavorite)
    } catch {
      isFavorite = originalValue
      library.saveContext()
      throw error
    }
  }

  @MainActor
  public func fetchFromServer(
    storage: PersistentStorage,
    librarySyncer: LibrarySyncer,
    playableDownloadManager: DownloadManageable
  ) async throws {
    try await librarySyncer.sync(album: self)
  }

  public func getArtworkCollection(theme: ThemePreference) -> ArtworkCollection {
    ArtworkCollection(defaultArtworkType: getDefaultArtworkType(), singleImageEntity: self)
  }

  public var containerIdentifier: PlayableContainerIdentifier { PlayableContainerIdentifier(
    type: .album,
    objectID: managedObject.objectID.uriRepresentation().absoluteString
  ) }
}
