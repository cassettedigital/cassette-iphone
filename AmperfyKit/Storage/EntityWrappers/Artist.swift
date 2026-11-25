//
//  Artist.swift
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

// MARK: - Artist

public class Artist: AbstractLibraryEntity {
  public let managedObject: ArtistMO

  public init(managedObject: ArtistMO) {
    self.managedObject = managedObject
    super.init(managedObject: managedObject)
  }

  /// Cassette Layer 1 (Identity): embedded MusicBrainz artist id from Subsonic (optional).
  public var musicBrainzId: String? {
    get { managedObject.musicBrainzId }
    set {
      if managedObject.musicBrainzId != newValue {
        managedObject.musicBrainzId = newValue
      }
    }
  }

  public var identifier: String {
    name
  }

  public var songCount: Int {
    Int(managedObject.songCount)
  }

  public var songs: [AbstractPlayable] {
    guard let songsSet = managedObject.songs,
          let songsMO = songsSet.array as? [SongMO] else { return [Song]() }
    var returnSongs = [Song]()
    for songMO in songsMO {
      returnSongs.append(Song(managedObject: songMO))
    }
    return returnSongs.sortByAlbum()
  }

  public var playables: [AbstractPlayable] { songs }

  public var name: String {
    get { managedObject.name ?? "Unknown Artist" }
    set {
      if managedObject.name != newValue {
        managedObject.name = newValue
        updateAlphabeticSectionInitial(section: newValue)
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

  public var remoteAlbumCount: Int {
    get {
      Int(managedObject.remoteAlbumCount)
    }
    set {
      guard Int16.isValid(value: newValue),
            managedObject.remoteAlbumCount != Int16(newValue) else { return }
      managedObject.remoteAlbumCount = Int16(newValue)
    }
  }

  public var albumCount: Int { Int(managedObject.albumCount) }

  public var albums: [Album] {
    guard let albumsSet = managedObject.albums,
          let albumsMO = albumsSet.array as? [AlbumMO] else { return [Album]() }
    var returnAlbums = [Album]()
    for albumMO in albumsMO {
      returnAlbums.append(Album(managedObject: albumMO))
    }
    return returnAlbums
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

  override public func getDefaultArtworkType() -> ArtworkType {
    .artist
  }

  /// phone-taste: an artist's picture is their OWN photo or nothing. Every surface that
  /// draws an artist through `LibraryEntityImage` (Home's artist circles, the Resume card,
  /// Library and genre rows, CarPlay tiles and rows) reads this, so a shared Artwork row
  /// that carries someone else's face never shows; with no photo of their own the surface
  /// draws the generated artist placeholder.
  override public func imagePath(setting: ArtworkDisplayPreference) -> String? {
    guard hasOwnPhotoOnDisk else { return nil }
    return super.imagePath(setting: setting)
  }

  /// True when this artist has its OWN photo on disk: an artwork row that belongs to this
  /// artist alone, is keyed to this artist (`(id, "artist")`), is a real custom image, and
  /// has its file present. The one test every surface uses before showing an artist's
  /// face (phone-taste). Never test `coverImage != nil` instead: a shared Artwork row can
  /// carry someone else's face. Mirrors IntentExecutor.onDeviceArtistPhotoMissing.
  public var hasOwnPhotoOnDisk: Bool {
    guard !id.isEmpty,
          let artwork,
          (artwork.managedObject.owners?.count ?? 0) <= 1,
          artwork.remoteInfo == ArtworkRemoteInfo(id: id, type: "artist"),
          artwork.status == .CustomImage,
          let path = artwork.imagePath
    else { return false }
    return FileManager.default.fileExists(atPath: path)
  }

  // MARK: The artist's lead record (phone-taste)

  /// Whether `album` is this artist's own record: its album artist is this artist, or one
  /// with the same name (the phone can hold one artist under several identities). The one
  /// test the artist page, Search and CarPlay share.
  public func isCredited(_ album: Album) -> Bool {
    guard let credited = album.artist else { return false }
    if credited.id == id { return true }
    let creditedName = ListeningShelves.normalizedArtistName(credited.name)
    return !creditedName.isEmpty && creditedName == ListeningShelves.normalizedArtistName(name)
  }

  /// `albums` newest first: by year (no year last), then by name.
  public static func newestFirst(_ albums: [Album]) -> [Album] {
    albums.sorted { lhs, rhs in
      let ly = lhs.year > 0 ? lhs.year : Int.min
      let ry = rhs.year > 0 ? rhs.year : Int.min
      if ly != ry { return ly > ry }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  /// The record that stands for this artist among `albums` (what the surface has on the
  /// phone): the newest credited album with a cover, else the newest credited album, else
  /// the newest album they appear on. A compilation never stands for them while a record of
  /// their own is here. `hasCover` says whether an album's cover file is on disk.
  public func leadAlbum(among albums: [Album], hasCover: (Album) -> Bool) -> Album? {
    let ordered = Self.newestFirst(albums)
    let credited = ordered.filter { isCredited($0) }
    return credited.first(where: hasCover) ?? credited.first ?? ordered.first
  }
}

// MARK: PlayableContainable

extension Artist: PlayableContainable {
  public var subtitle: String? { nil }
  public var subsubtitle: String? { nil }
  public func infoDetails(for api: ServerApiType?, details: DetailInfoType) -> [String] {
    var infoContent = [String]()
    // cassette Patch 104 (list metadata density): artist list rows drop the
    // "# Albums / # Songs" counts entirely — they read as noise next to the
    // name. The long (detail) variant below keeps the full breakdown.
    if details.type == .short {
      if details.isShowArtistDuration, duration > 0 {
        infoContent.append("\(duration.asDurationShortString)")
      }
      return infoContent
    }
    if let managedObjectContext = managedObject.managedObjectContext, let account {
      let library = LibraryStorage(context: managedObjectContext)
      let relatedAlbumCount = library.getAlbums(for: account, whichContainsSongsWithArtist: self)
        .count
      if relatedAlbumCount == 1 {
        infoContent.append("1 Album")
      } else if relatedAlbumCount > 1 {
        infoContent.append("\(relatedAlbumCount) Albums")
      }
    } else if albumCount == 1 {
      infoContent.append("1 Album")
    } else if albumCount > 1 {
      infoContent.append("\(albumCount) Albums")
    }

    if details.artistFilterSetting == .albumArtists,
       let managedObjectContext = managedObject.managedObjectContext, let account {
      let library = LibraryStorage(context: managedObjectContext)
      let relatedSongsCount = library.getSongs(for: account, whichContainsSongsWithArtist: self)
        .count
      if relatedSongsCount == 1 {
        infoContent.append("1 Song")
      } else if relatedSongsCount > 1 {
        infoContent.append("\(relatedSongsCount) Songs")
      }
    } else if songCount == 1 {
      infoContent.append("1 Song")
    } else if songCount > 1 {
      infoContent.append("\(songCount) Songs")
    }
    if details.type == .long {
      if let genre = genre {
        infoContent.append("Genre: \(genre.name)")
      }
      if duration > 0 {
        infoContent.append("\(duration.asDurationShortString)")
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
    isFavorite.toggle()
    let library = LibraryStorage(context: context)
    library.saveContext()
    try await syncer.setFavorite(artist: self, isFavorite: isFavorite)
  }

  @MainActor
  public func fetchFromServer(
    storage: PersistentStorage,
    librarySyncer: LibrarySyncer,
    playableDownloadManager: DownloadManageable
  ) async throws {
    try await librarySyncer.sync(artist: self)
  }

  /// D46 (design wave 6): an artist is always a circle, their photo, else one of their records,
  /// never a letter. With no photo of their own on the phone, the first of their records with a
  /// cover stands in (as the artist page's fan already does); only an artist with neither falls
  /// to the placeholder.
  public func getArtworkCollection(theme: ThemePreference) -> ArtworkCollection {
    if !hasOwnPhotoOnDisk,
       let record = albums.first(where: { album in
         album.artwork?.imagePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
       }) {
      return ArtworkCollection(defaultArtworkType: .artist, singleImageEntity: record)
    }
    return ArtworkCollection(defaultArtworkType: .artist, singleImageEntity: self)
  }

  public var containerIdentifier: PlayableContainerIdentifier { PlayableContainerIdentifier(
    type: .artist,
    objectID: managedObject.objectID.uriRepresentation().absoluteString
  ) }
}
