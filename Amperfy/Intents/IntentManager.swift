//
//  IntentManager.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 06.06.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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

import AmperfyKit
import Foundation
import Ifrit
import Intents
import OSLog

extension RepeatMode {
  static func fromIntent(type: RepeatTypeAppEnum) -> RepeatMode {
    switch type {
    case .single:
      return .single
    case .all:
      return .all
    case .off:
      return .off
    }
  }
}

extension PlayerMode {
  static func fromIntent(type: PlaybackModeAppEnum) -> PlayerMode {
    switch type {
    case .music:
      return .music
    case .podcast:
      return .podcast
    }
  }
}

extension PlayableContainerTypeAppEnum {
  public static func from(string: String) -> PlayableContainerTypeAppEnum? {
    switch string {
    case "artist":
      return .artist
    case "song":
      return .song
    case "podcastEpisode":
      return .podcastEpisode
    case "playlist":
      return .playlist
    case "album":
      return .album
    case "genre":
      return .genre
    case "podcast":
      return .podcast
    default:
      return nil
    }
  }

  public static var allCasesDescription: String {
    "artist, song, podcastEpisode, playlist, album, genre, podcast"
  }
}

// MARK: - AmperfyAppIntentError

enum AmperfyAppIntentError: Error, LocalizedError {
  case notFound
  case accountNotValid
  case changesOnlyInOnlineMode
  case noItemIsPlaying
  case serverSyncFailed

  var errorDescription: String? {
    switch self {
    case .notFound:
      return "I couldn’t find an element with the provided information."
    case .accountNotValid:
      return "The provided account is not valid."
    case .changesOnlyInOnlineMode:
      return "Can only be changed in online mode."
    case .noItemIsPlaying:
      return "There is currently no item playing."
    case .serverSyncFailed:
      return "Changes could not be send to server."
    }
  }

  var failureReason: String? {
    errorDescription
  }
}

// MARK: - IntentManager

@MainActor
public class IntentManager {
  private let storage: PersistentStorage
  private let getLibrarySyncerCB: GetLibrarySyncerCallback
  private let getPlayableDownloadManagerCB: GetPlayableDownloadManagerCallback
  private let library: LibraryStorage
  private let getActiveAccountCallback: GetActiveAccountCallback
  private let player: PlayerFacade
  private let networkMonitor: NetworkMonitorFacade
  private let eventLogger: EventLogger
  private var lastResult: AmperfyMediaIntentItemResult?

  init(
    storage: PersistentStorage,
    getLibrarySyncerCB: @escaping GetLibrarySyncerCallback,
    getPlayableDownloadManagerCB: @escaping GetPlayableDownloadManagerCallback,
    library: LibraryStorage,
    getActiveAccountCallback: @escaping GetActiveAccountCallback,
    player: PlayerFacade,
    networkMonitor: NetworkMonitorFacade,
    eventLogger: EventLogger
  ) {
    self.storage = storage
    self.getLibrarySyncerCB = getLibrarySyncerCB
    self.getPlayableDownloadManagerCB = getPlayableDownloadManagerCB
    self.library = library
    self.getActiveAccountCallback = getActiveAccountCallback
    self.player = player
    self.networkMonitor = networkMonitor
    self.eventLogger = eventLogger
  }

  public lazy var log = {
    OSLog(subsystem: "Amperfy", category: "IntentManager")
  }()

  @MainActor
  public struct AmperfyMediaIntentItemResult {
    var playableContainer: PlayableContainable?
    var playableElements: [AbstractPlayable]?
    var item: INMediaItem
  }

  public func handleIncomingPlayMediaIntent(playMediaIntent: INPlayMediaIntent)
    -> AmperfyMediaIntentItemResult? {
    guard let account = getActiveAccountCallback() else {
      eventLogger.info(topic: "Siri Play Media Intent", message: "Error: not yet logged in")
      return nil
    }
    // intent interpretion is only working if media search is provided
    guard let mediaSearch = playMediaIntent.mediaSearch else {
      eventLogger.debug(topic: "Siri Play Media Intent", message: "Error: No media search provided")
      return nil
    }

    eventLogger.debug(
      topic: "Siri Play Media Intent",
      message: "Request details:\n \(playMediaIntent.description)\n\(mediaSearch.description)"
    )

    var result: AmperfyMediaIntentItemResult?
    let playableContainerType = PlayableContainerTypeAppEnum
      .fromINMediaItemType(type: mediaSearch.mediaType)
    if playableContainerType != nil ||
      mediaSearch.mediaType == .music {
      // media type is provided by user
      // "play music" => mediaType: 18
      // "play podcasts" => mediaType: 6
      // "play song <blub> by <artist>" => mediaType: 1; mediaName: blub; artistNames: artist
      // "play song <blub>" => mediaType: 1; mediaName: blub; artistNames: -
      // "play album <blub>" => mediaType: 2; mediaName: blub; artistNames: -
      // "play artist <blub>" => mediaType: 3; mediaName: blub; artistNames: -
      // "play <Rock>" => mediaType: 4; mediaName: -; artistNames: -; genreNames: Rock
      // "play playlist <blub>" => mediaType: 5; mediaName: blub; artistNames: -
      // "play podcast <blub>" => mediaType: 6; mediaName: blub; artistNames: -
      // "play radio <blub>" => mediaType: 16; mediaName: blub; artistNames: -
      if mediaSearch.mediaType == .music {
        os_log("Play Music", log: self.log, type: .info)
        let playableElements = library.getRandomSongs(
          for: account,
          onlyCached: storage.settings.user.isOfflineMode
        )
        result = AmperfyMediaIntentItemResult(
          playableElements: playableElements,
          item: INMediaItem(
            identifier: nil,
            title: "Random Songs",
            type: INMediaItemType.music,
            artwork: nil
          )
        )
      } else if mediaSearch.mediaType == .podcastShow ||
        mediaSearch.mediaType == .podcastEpisode ||
        mediaSearch.mediaType == .podcastStation ||
        mediaSearch.mediaType == .podcastPlaylist {
        os_log("Play Podcasts", log: self.log, type: .info)
        let playableElements = library.getNewestPodcastEpisode(for: account, count: 1)
        if !playableElements.isEmpty {
          result = AmperfyMediaIntentItemResult(
            playableElements: playableElements,
            item: INMediaItem(
              identifier: nil,
              title: playableElements[0].title,
              type: INMediaItemType.podcastEpisode,
              artwork: nil,
              artist: playableElements[0].creatorName
            )
          )
        }
      } else if mediaSearch.mediaName == nil,
                mediaSearch.mediaType == .musicStation || mediaSearch.mediaType == .radioStation ||
                mediaSearch.mediaType == .station {
        os_log("Play random Radio", log: self.log, type: .info)
        let randomRadio = library.getRadios(for: account).randomElement()
        if let randomRadio {
          result = AmperfyMediaIntentItemResult(
            playableElements: [randomRadio],
            item: INMediaItem(
              identifier: nil,
              title: "Random radio \(randomRadio.title)",
              type: INMediaItemType.radioStation,
              artwork: nil,
              artist: nil
            )
          )
        }
      } else if let mediaName = mediaSearch.mediaName {
        os_log(
          "Search explicitly in %ss: <%s>",
          log: self.log,
          type: .info,
          playableContainerType?.description ?? "unknown",
          mediaName
        )
        if let playableContainer = getPlayableContainer(
          searchTerm: mediaName,
          searchCategory: playableContainerType,
          account: account
        ) {
          result = AmperfyMediaIntentItemResult(
            playableContainer: playableContainer,
            item: INMediaItem(
              identifier: nil,
              title: playableContainer.name,
              type: mediaSearch.mediaType,
              artwork: nil,
              artist: playableContainer.subsubtitle
            )
          )
        }
      } else if let genres = mediaSearch.genreNames {
        os_log(
          "Search explicitly in genres: <%s>",
          log: self.log,
          type: .info,
          genres.joined(separator: ", ")
        )
        for genre in genres {
          guard result == nil else { break }
          os_log("Search explicitly in genre: <%s>", log: self.log, type: .info, genre)
          if let playableContainer = getPlayableContainer(
            searchTerm: genre,
            searchCategory: .genre,
            account: account
          ) {
            result = AmperfyMediaIntentItemResult(
              playableContainer: playableContainer,
              item: INMediaItem(
                identifier: nil,
                title: genre,
                type: INMediaItemType.genre,
                artwork: nil
              )
            )
          }
        }
      }
    } else {
      // Do a full search due to missing media type
      if let mediaName = mediaSearch.mediaName {
        // "play <title>" => mediaType: 0; mediaName: title; artistNames: -
        // "play <title> by <artist>" => mediaType: 0; mediaName: title; artistNames: artist
        if let artistName = mediaSearch.artistName {
          os_log(
            "Search implicitly in songs: <%s> - <%s>",
            log: self.log,
            type: .info,
            artistName,
            mediaName
          )
          if let playableContainer = getSong(
            account: account,
            songName: mediaName,
            artistName: artistName
          ) {
            result = AmperfyMediaIntentItemResult(
              playableContainer: playableContainer,
              item: INMediaItem(
                identifier: nil,
                title: playableContainer.name,
                type: INMediaItemType.song,
                artwork: nil,
                artist: playableContainer.subtitle
              )
            )
          }
        }
        if result == nil {
          os_log("Search implicitly in playlists: <%s>", log: self.log, type: .info, mediaName)
          if let playableContainer = getPlayableContainer(
            searchTerm: mediaName,
            searchCategory: .playlist,
            account: account
          ) {
            result = AmperfyMediaIntentItemResult(
              playableContainer: playableContainer,
              item: INMediaItem(
                identifier: nil,
                title: playableContainer.name,
                type: INMediaItemType.playlist,
                artwork: nil
              )
            )
          }
        }
        if result == nil {
          os_log("Search implicitly in artists: <%s>", log: self.log, type: .info, mediaName)
          if let playableContainer = getPlayableContainer(
            searchTerm: mediaName,
            searchCategory: .artist,
            account: account
          ) {
            result = AmperfyMediaIntentItemResult(
              playableContainer: playableContainer,
              item: INMediaItem(
                identifier: nil,
                title: playableContainer.name,
                type: INMediaItemType.artist,
                artwork: nil
              )
            )
          }
        }
        if result == nil {
          os_log("Search implicitly in podcasts: <%s>", log: self.log, type: .info, mediaName)
          if let playableContainer = getPlayableContainer(
            searchTerm: mediaName,
            searchCategory: .podcast,
            account: account
          ) {
            result = AmperfyMediaIntentItemResult(
              playableContainer: playableContainer,
              item: INMediaItem(
                identifier: nil,
                title: playableContainer.name,
                type: INMediaItemType.podcastShow,
                artwork: nil
              )
            )
          }
        }
        if result == nil {
          os_log("Search implicitly in albums: <%s>", log: self.log, type: .info, mediaName)
          if let playableContainer = getPlayableContainer(
            searchTerm: mediaName,
            searchCategory: .album,
            account: account
          ) {
            result = AmperfyMediaIntentItemResult(
              playableContainer: playableContainer,
              item: INMediaItem(
                identifier: nil,
                title: playableContainer.name,
                type: INMediaItemType.album,
                artwork: nil
              )
            )
          }
        }
        if result == nil {
          os_log("Search implicitly in songs: <%s>", log: self.log, type: .info, mediaName)
          if let playableContainer = getPlayableContainer(
            searchTerm: mediaName,
            searchCategory: .song,
            account: account
          ) {
            result = AmperfyMediaIntentItemResult(
              playableContainer: playableContainer,
              item: INMediaItem(
                identifier: nil,
                title: playableContainer.name,
                type: INMediaItemType.song,
                artwork: nil,
                artist: playableContainer.subtitle
              )
            )
          }
        }
        if result == nil {
          os_log("Search implicitly in radios: <%s>", log: self.log, type: .info, mediaName)
          if let playableContainer = getPlayableContainer(
            searchTerm: mediaName,
            searchCategory: .radio,
            account: account
          ) {
            result = AmperfyMediaIntentItemResult(
              playableContainer: playableContainer,
              item: INMediaItem(
                identifier: nil,
                title: playableContainer.name,
                type: INMediaItemType.radioStation,
                artwork: nil,
                artist: nil
              )
            )
          }
        }
        if result == nil {
          os_log(
            "Search implicitly in podcastEpisodes: <%s>",
            log: self.log,
            type: .info,
            mediaName
          )
          if let playableContainer = getPlayableContainer(
            searchTerm: mediaName,
            searchCategory: .podcastEpisode,
            account: account
          ) {
            result = AmperfyMediaIntentItemResult(
              playableContainer: playableContainer,
              item: INMediaItem(
                identifier: nil,
                title: playableContainer.name,
                type: INMediaItemType.podcastEpisode,
                artwork: nil,
                artist: playableContainer.subtitle
              )
            )
          }
        }
      } else if let genres = mediaSearch.genreNames {
        os_log(
          "Search implicitly in genres: <%s>",
          log: self.log,
          type: .info,
          genres.joined(separator: ", ")
        )
        for genre in genres {
          guard result == nil else { break }
          os_log("Search implicitly in genre: <%s>", log: self.log, type: .info, genre)
          if let playableContainer = getPlayableContainer(
            searchTerm: genre,
            searchCategory: .genre,
            account: account
          ) {
            result = AmperfyMediaIntentItemResult(
              playableContainer: playableContainer,
              item: INMediaItem(
                identifier: nil,
                title: playableContainer.name,
                type: INMediaItemType.genre,
                artwork: nil
              )
            )
          }
        }
      }
    }
    if let result = result {
      var playableDetailString = "-"
      if let playableContainer = result.playableContainer {
        playableDetailString = String(describing: playableContainer)
        playableDetailString += ": " + playableContainer.name
        if let subtitle = playableContainer.subtitle {
          playableDetailString += " - " + subtitle
        }
        if let subsubtitle = playableContainer.subsubtitle {
          playableDetailString += " - " + subsubtitle
        }
      }
      eventLogger.debug(
        topic: "Siri Play Media Intent",
        message: "Response:\n\(result.item.description)\nLibrary Element: \(playableDetailString)\nShuffle/Random Items Count: \(result.playableElements?.count ?? 0)"
      )
    } else {
      os_log("No playable container found", log: self.log, type: .info)
      eventLogger.debug(topic: "Siri Play Media Intent", message: "Response: No media found")
    }
    lastResult = result
    return result
  }

  func getAccount(fromIntent accountIntent: AccountAppEntity?) -> Account? {
    if let accountIntentId = accountIntent?.id,
       let account = library.getAccount(ident: accountIntentId) {
      return account
    }
    return getActiveAccountCallback()
  }

  func getPlayableContainer(
    searchTerm: String,
    searchCategory: PlayableContainerTypeAppEnum?,
    account: Account
  )
    -> PlayableContainable? {
    guard let searchCategory else { return nil }
    var playableContainer: PlayableContainable?

    switch searchCategory {
    case .song:
      playableContainer = FuzzySearcher.findBestMatch(
        in: library.getSongs(for: account),
        search: searchTerm
      )
      .first
    case .artist:
      playableContainer = FuzzySearcher.findBestMatch(
        in: library.getArtists(for: account),
        search: searchTerm
      )
      .first
    case .podcastEpisode:
      playableContainer = FuzzySearcher.findBestMatch(
        in: library.getPodcastEpisodes(for: account),
        search: searchTerm
      ).first
    case .playlist:
      playableContainer = FuzzySearcher
        .findBestMatch(in: library.getPlaylists(for: account), search: searchTerm).first
    case .album:
      playableContainer = FuzzySearcher.findBestMatch(
        in: library.getAlbums(for: account),
        search: searchTerm
      )
      .first
    case .genre:
      playableContainer = FuzzySearcher.findBestMatch(
        in: library.getGenres(for: account),
        search: searchTerm
      )
      .first
    case .podcast:
      playableContainer = FuzzySearcher.findBestMatch(
        in: library.getPodcasts(for: account),
        search: searchTerm
      )
      .first
    case .radio:
      playableContainer = FuzzySearcher.findBestMatch(
        in: library.getRadios(for: account),
        search: searchTerm
      )
      .first
    }
    return playableContainer
  }

  private func getSong(
    account: Account,
    songName: String,
    artistName: String
  )
    -> PlayableContainable? {
    let foundPlayables = FuzzySearcher.findBestMatch(
      in: library.getSongs(for: account),
      search: songName
    )
    let foundSongs = foundPlayables.compactMap { $0 as? Song }
    let artists = foundSongs.compactMap { $0.artist }
    let matchingArtistsRaw = FuzzySearcher.findBestMatch(in: artists, search: artistName)
    let matchingArtists = matchingArtistsRaw.compactMap { $0 as? Artist }
    let foundSong = foundSongs.lazy
      .filter { song in matchingArtists.contains(where: { artist in song.artist == artist }) }.first
    return foundSong
  }

  func getPlayableContainer(
    account: Account,
    id: String,
    libraryElementType: PlayableContainerTypeAppEnum
  )
    -> PlayableContainable? {
    var playableContainer: PlayableContainable?

    switch libraryElementType {
    case .song:
      playableContainer = library.getSong(for: account, id: id)
    case .artist:
      switch account.apiType.asServerApiType {
      case .ampache:
        playableContainer = library.getArtist(for: account, id: id)
      case .subsonic:
        playableContainer = library.getArtist(for: account, id: id)
        if playableContainer == nil {
          playableContainer = library.getArtistLocal(for: account, name: id)
        }
      case .none:
        break // do nothing
      }
    case .podcastEpisode:
      playableContainer = library.getPodcastEpisode(for: account, id: id)
    case .playlist:
      playableContainer = library.getPlaylist(for: account, id: id)
    case .album:
      playableContainer = library.getAlbum(for: account, id: id, isDetailFaultResolution: false)
    case .genre:
      switch account.apiType.asServerApiType {
      case .ampache:
        playableContainer = library.getGenre(for: account, id: id)
      case .subsonic:
        playableContainer = library.getGenre(for: account, name: id)
      case .none:
        break // do nothing
      }
    case .podcast:
      playableContainer = library.getPodcast(for: account, id: id)
    case .radio:
      playableContainer = library.getRadio(for: account, id: id)
    }
    return playableContainer
  }

  @MainActor
  public func playLastResult(
    shuffleOption: Bool,
    repeatOption: RepeatMode
  ) async
    -> Bool {
    guard let lastResult = lastResult else { return false }
    self.lastResult = nil

    if let playableContainer = lastResult.playableContainer {
      os_log(
        "Play container <%s> (shuffle: %s, repeat: %s)",
        log: self.log,
        type: .info,
        playableContainer.name,
        shuffleOption.description,
        repeatOption.description
      )
      return await play(
        container: playableContainer,
        shuffleOption: shuffleOption,
        repeatOption: repeatOption
      )
    } else if let playableElements = lastResult.playableElements {
      os_log(
        "Play Music (shuffle: %s, repeat: %s)",
        log: self.log,
        type: .info,
        shuffleOption.description,
        repeatOption.description
      )
      return play(
        context: PlayContext(name: "Siri Intent", playables: playableElements),
        shuffleOption: shuffleOption,
        repeatOption: repeatOption
      )
    } else {
      return false
    }
  }

  @MainActor
  func play(
    container: PlayableContainable?,
    shuffleOption: Bool,
    repeatOption: RepeatMode
  ) async
    -> Bool {
    guard let container = container else { return false }
    do {
      if let containerPlaylist = container as? Playlist,
         let accountInfo = containerPlaylist.account?.info {
        if storage.settings.user.isOnlineMode, networkMonitor.isWifiOrEthernet {
          os_log(
            "Fetch playlist start: %s",
            log: self.log,
            type: .info,
            container.name
          )
          let librarySyncer = getLibrarySyncerCB(accountInfo)
          let playableDownloadManager = getPlayableDownloadManagerCB(accountInfo)
          try await container.fetch(
            storage: storage,
            librarySyncer: librarySyncer,
            playableDownloadManager: playableDownloadManager
          )
          os_log(
            "Fetch playlist done: %s",
            log: self.log,
            type: .info,
            container.name
          )
        } else {
          os_log(
            "No fetch for playlist needed: %s",
            log: self.log,
            type: .info,
            container.name
          )
        }
      } else {
        os_log(
          "No fetch required for: %s",
          log: self.log,
          type: .info,
          container.name
        )
      }
    } catch {
      // do nothing
    }
    return play(
      context: PlayContext(containable: container),
      shuffleOption: shuffleOption,
      repeatOption: repeatOption
    )
  }

  func play(context: PlayContext, shuffleOption: Bool, repeatOption: RepeatMode) -> Bool {
    if shuffleOption {
      player.playShuffled(context: context)
    } else {
      player.play(context: context)
    }
    player.setRepeatMode(repeatOption)
    return true
  }
}

extension PlayableContainerTypeAppEnum {
  public var description: String {
    switch self {
    case .artist:
      return "artist"
    case .song:
      return "song"
    case .podcastEpisode:
      return "podcastEpisode"
    case .playlist:
      return "playlist"
    case .album:
      return "album"
    case .genre:
      return "genre"
    case .podcast:
      return "podcast"
    case .radio:
      return "radio"
    }
  }
}

extension PlayableContainerTypeAppEnum {
  static public func fromINMediaItemType(type: INMediaItemType) -> PlayableContainerTypeAppEnum? {
    switch type {
    case .unknown:
      return nil
    case .song:
      return .song
    case .album:
      return .album
    case .artist:
      return .artist
    case .genre:
      return .genre
    case .playlist:
      return .playlist
    case .podcastShow:
      return .podcast
    case .podcastEpisode:
      return .podcastEpisode
    case .podcastPlaylist:
      return .podcast
    case .musicStation:
      return .radio
    case .audioBook:
      return nil
    case .movie:
      return nil
    case .tvShow:
      return nil
    case .tvShowEpisode:
      return nil
    case .musicVideo:
      return nil
    case .podcastStation:
      return .podcast
    case .radioStation:
      return .radio
    case .station:
      return .radio
    case .music:
      return nil
    case .algorithmicRadioStation:
      return nil
    case .news:
      return nil
    @unknown default:
      return nil
    }
  }
}
