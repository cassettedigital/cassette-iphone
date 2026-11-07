//
//  HomeSection.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 26.11.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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

public enum HomeSection: Int, Sendable, CaseIterable, Codable {
  // add new section always at the end to keep the Int consitent
  case lastTimePlayedPlaylists
  case recentlyPlayedAlbums
  case newestAlbums
  case randomAlbums
  case newestPodcastEpisodes
  case podcasts
  case radios
  case randomArtists
  case randomGenres
  case randomSongs
  // cassette Patch 035: three-shelf IA. New cases appended so the
  // raw-Int ordinals of the legacy cases stay stable — any persisted
  // `accountSettings.homeSections` data continues to Codable-decode.
  // Only `editableSections` is surfaced to the editor going forward.
  case resume
  case yourPlaylists
  case recentlyAdded
  // cassette Patch 038: fourth shelf — artists ordered by recent
  // song play activity. Appended (ordinal 13) for Codable backwards-
  // compat; surfaced in defaultValue/editableSections between
  // resume and yourPlaylists.
  case recentlyPlayedArtists
  // cassette Patch 042: heterogeneous "Recent" shelf merging recently-
  // played albums, playlists, artists, and freshly-added albums into
  // one row sorted by interaction date. Appended (ordinal 14) so
  // legacy `accountSettings.homeSections` Codable payloads keep
  // decoding; .resume left in the enum but no longer rendered.
  case recent
  // cassette (Forgotten Albums): owned albums the user has drifted from — the
  // anti-recency shelf. Appended (ordinal 15) so legacy Codable `homeSections`
  // payloads keep decoding.
  case forgottenAlbums

  // cassette: the six Mood tiles (Get Pumped, Focus, ...) — a HEADER-ONLY
  // section (zero HomeItems; see HomeVC's supplementary-view handling for
  // .moodDoors). A mood door isn't a PlayableContainable — it's a static
  // preset that generates a mixtape on tap, not a real library entity — so
  // it deliberately does NOT flow through the HomeItem/diffable-snapshot
  // pipeline the way every other shelf does. Appended (ordinal 16) per this
  // enum's own append-only Codable-compat rule.
  case moodDoors

  // cassette 2026-10-20: two rows from the phone's own play log (AmperfyKit/Home/
  // ListeningShelves.swift). Appended (ordinals 17, 18) per the append-only rule.
  case onRepeat
  case aroundNow
  // cassette 2026-10-20: albums on the phone matching the mood of recent listening.
  // Ordinal 19. Takes the Albums row's place on Home when it has anything to show.
  case moreLikeLately
  // cassette 2026-10-21: records you heard a song or two of lately (mostly from the
  // made-for-you playlists), a nudge to go deeper. Ordinal 20. Took over the one idea in
  // Recent that no other row carried.
  case fromYourMixes
  // cassette 2026-10-26: Put something on (founder: "its own row under Resume"). REMOVED from
  // Home 2026-10-28 (One Home, founder). The case stays, unused, so saved `homeSections`
  // that name ordinal 21 still decode.
  case putSomethingOn
  // cassette 2026-10-28 (One Home): the reaching row, the one shelf the moment picked (Loud
  // ones, Deep dive, Nostalgia, ...). Deep dive draws its record as one big card. Ordinal 22.
  case reach
  // cassette 2026-10-28 (One Home): the way to every shelf made today, at the end of Home.
  // Header-only. Ordinal 23.
  case allShelves
  // cassette 2026-11-07 (BUG-899): the first-run computer card, leading Home until the
  // phone's music is in. Header-only, phone Home only: never in the cloud's rows, the stand-in
  // line-up, the Home editor or CarPlay. Ordinal 24.
  case computer

  // cassette redesign (Surface 4): Resume leads the Home IA again - a
  // single full-width card sourced from the lastPlayedDate FRCs.
  //
  // cassette 2026-10-28 (One Home): the cloud makes Home (GET /api/sync/home) and the phone
  // and the car draw its rows in its order. This list is only the phone's stand-in, drawn
  // while no answer has ever been held, in the same line-up as far as the phone's own rows
  // go: Resume, On Repeat, around now, made for you, your playlists, Radio, one reaching row
  // (More Like Lately, else Albums: HomeManager clears Albums while More Like has rows),
  // From Your Mixes, Artists.
  public static let defaultValue: [HomeSection] = [
    .resume,
    .onRepeat,
    .aroundNow,
    .moodDoors,
    .yourPlaylists,
    .radios,
    .moreLikeLately,
    .forgottenAlbums,
    .fromYourMixes,
    .recentlyPlayedArtists,
  ]

  /// cassette Patch 035: the sections the home-editor UI is allowed
  /// to surface. Keeps legacy enum cases reachable for Codable
  /// backwards-compat without letting users resurrect the old
  /// random/podcast/radio carousels.
  public static let editableSections: [HomeSection] = [
    .recent,
    .yourPlaylists,
    .forgottenAlbums,
    .recentlyPlayedArtists,
  ]

  public var title: String {
    switch self {
    case .recentlyPlayedAlbums: return "Recently Played Albums"
    case .newestAlbums: return "Newest Albums"
    case .randomAlbums: return "Random Albums"
    case .lastTimePlayedPlaylists: return "Recently Played Playlists"
    case .newestPodcastEpisodes: return "Newest Podcast Episodes"
    case .podcasts: return "Podcasts"
    case .radios: return "Radio"
    case .randomArtists: return "Random Artists"
    case .randomGenres: return "Random Genres"
    case .randomSongs: return "Random Songs"
    case .resume: return "Resume"
    // cassette Patch 042: shelf retitle. Enum case names stay so
    // Codable decoding of legacy AccountSetting payloads doesn't
    // break; only the user-facing title changes.
    case .yourPlaylists: return "Playlists"
    case .recentlyAdded: return "Recently Added Albums" // retired from Home; retitled to avoid a duplicate "Albums"
    case .recentlyPlayedArtists: return "Artists"
    case .recent: return "Recent"
    case .forgottenAlbums: return "Albums" // the from-your-collection / anti-recency shelf, surfaced as "Albums"
    case .moodDoors: return "Mood" // accessibility fallback only — MoodDoorsHeaderView owns the visible header
    case .onRepeat: return "On Repeat"
    case .aroundNow: return ListeningShelves.aroundNowTitle(now: Date())
    case .moreLikeLately: return "More Like Lately"
    case .fromYourMixes: return "From Your Mixes"
    case .putSomethingOn: return "Put Something On"
    case .reach: return "Shelf"
    case .allShelves: return "All Shelves"
    case .computer: return "Your Computer"
    }
  }

  public static func create(fromTitle: String) -> HomeSection? {
    allCases.first(where: { $0.title == fromTitle })
  }

  public var isRandomSection: Bool {
    switch self {
    case .recentlyPlayedAlbums: return false
    case .newestAlbums: return false
    case .randomAlbums: return true
    case .lastTimePlayedPlaylists: return false
    case .newestPodcastEpisodes: return false
    case .podcasts: return false
    case .radios: return false
    case .randomArtists: return true
    case .randomGenres: return true
    case .randomSongs: return true
    case .resume: return false
    case .yourPlaylists: return false
    case .recentlyAdded: return false
    case .recentlyPlayedArtists: return false
    case .recent: return false
    case .forgottenAlbums: return false
    case .moodDoors: return false
    case .onRepeat: return false
    case .aroundNow: return false
    case .moreLikeLately: return false
    case .fromYourMixes: return false
    case .putSomethingOn: return false
    case .reach: return false
    case .allShelves: return false
    case .computer: return false
    }
  }
}
