//
//  CarPlayHomeTabExtension.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 02.01.26.
//  Copyright (c) 2026 Maximilian Bauer. All rights reserved.
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
import CarPlay
import CoreData
import Foundation

// MARK: - CarMoodTile

/// phone-taste: one tile of the car's Made for You row (was Mood). A tap resolves to one of
/// these (stored in the session when the row is drawn), never to live data.
enum CarMoodTile: Equatable {
  /// The Lately mix (HomeManager.latelyMix): songs on this phone that match recent listening.
  case lately
  /// A mood door: POST /api/mixtape/door, cut to the songs on this phone. No longer offered
  /// (founder, 2026-10-21: the phone's own mood mixes replace the doors); kept so a door
  /// load in flight still resolves.
  case door(key: String, label: String, hexColor: String)
  /// One of Home's other made-for-you playlists (HomeManager.otherMixes), by id: this part
  /// of the day, Been a While or a mood mix, all built on the phone.
  case mix(id: String, title: String, hexColor: String?)
}

// MARK: - CarPlaySceneDelegate + Home

extension CarPlaySceneDelegate {
  /// One Home (founder, 2026-10-28): the car draws the cloud's Home, the same rows in the same
  /// order and under the same names as the phone, from the one CloudHome the phone's Home
  /// reads, each row holding what the phone holds. Resume has no card in the car: it rides as
  /// the first tile of On Repeat. All shelves is a plain row at the end. (This replaced the
  /// car's own row list and its own HomeManager, which had drifted from the phone since 10-21.)
  private var carPlayHomeRows: [HomeSection] {
    guard let cloudHome else { return [] }
    var sections = [HomeSection]()
    for row in cloudHome.rows {
      let section = row.section == .resume ? HomeSection.onRepeat : row.section
      if !sections.contains(section) { sections.append(section) }
    }
    return sections
  }

  /// The Lately tile needs four covers for its picture (the mock shows it at four or more).
  private static let latelyCoverCount = 4
  /// A mood mix's drawn cover is decoded this large for the car (its biggest slot at 3x).
  private static let drawnCoverPixels = 480

  /// The items a CarPlay Home row shows. On Repeat carries Resume's record first.
  private func carPlayItems(_ section: HomeSection) -> [HomeItem]? {
    guard let cloudHome else { return nil }
    func items(_ source: HomeSection) -> [HomeItem] {
      guard let row = cloudHome.row(source) else { return [] }
      if source == .reach, let shelf = row.shelf {
        guard CloudHome.isDrawable(shelf) else { return [] }
        var tiles = [HomeItem]()
        if !shelf.isDeepDive, let mix = shelf.mix, let art = mix.leadAlbums.first ?? shelf.albums.first {
          tiles.append(HomeItem(section: section, stableID: "mix-\(mix.id)", playableContainable: art, mixID: mix.id))
        }
        return tiles + shelf.albums.prefix(shelf.isDeepDive ? 1 : 12).map {
          HomeItem(section: section, stableID: HomeManager.stableID(for: $0), playableContainable: $0)
        }
      }
      return row.items.map {
        HomeItem(section: section, stableID: HomeManager.stableID(for: $0), playableContainable: $0)
      }
    }
    guard section == .onRepeat else { return items(section) }
    let resume = items(.resume)
    let shown = Set(resume.map(\.stableID))
    return resume + items(.onRepeat).filter { !shown.contains($0.stableID) }
  }

  /// A row's name as the car shows it: the cloud's two voices in one line, in title case
  /// ("From Your Mixes", "On Repeat Lately").
  private func carPlayTitle(_ section: HomeSection) -> String {
    guard let row = cloudHome?.row(section) ?? (section == .onRepeat ? cloudHome?.row(.resume) : nil)
    else { return section.title }
    return Self.titleCase([row.shout, row.answer].filter { !$0.isEmpty }.joined(separator: " "))
  }

  private static let smallWords: Set<String> = ["a", "an", "and", "at", "by", "for", "in", "of", "on", "the", "to"]

  static func titleCase(_ text: String) -> String {
    text.split(separator: " ").enumerated().map { index, word in
      let lower = word.lowercased()
      if index > 0, smallWords.contains(lower) { return lower }
      return word.prefix(1).uppercased() + word.dropFirst()
    }.joined(separator: " ")
  }

  /// The made-for-you row's playlists from the cloud: Lately, and the rest in its order.
  private var carLatelyMix: HomeManager.MadeForYouMix? {
    cloudHome?.row(.moodDoors)?.mixes.first { $0.kind == .lately }
  }

  private var carOtherMixes: [HomeManager.MadeForYouMix] {
    cloudHome?.row(.moodDoors)?.mixes.filter { $0.kind != .lately } ?? []
  }

  /// The reaching row's Nostalgia mix, by its id.
  private func carReachMix(_ id: String) -> HomeManager.MadeForYouMix? {
    cloudHome?.row(.reach)?.shelf?.mix.flatMap { $0.id == id ? $0 : nil }
  }

  /// A Home tile plays straight away and shows Now Playing (founder, 2026-10-20: one tap
  /// to music behind the wheel). An album plays from the top, an artist shuffled. Browsing
  /// stays one tap away on the row's title.
  ///
  /// phone-taste: only what is on this phone is queued (the foundation's OneTapPlay rule). A
  /// station plays as itself. Nothing of it on the phone: nothing plays and Now Playing stays
  /// shut (Home rows hold only records on the phone, so this is the rare race with a removal).
  private func playFromHome(_ containable: PlayableContainable) {
    if containable is Radio {
      appDelegate.player.play(context: PlayContext(containable: containable))
      displayNowPlaying {}
      return
    }
    let playables = onPhonePlayables(of: containable)
    guard !playables.isEmpty else { return }
    let context = PlayContext(containable: containable, playables: playables)
    if containable is Artist {
      appDelegate.player.playShuffled(context: context)
    } else {
      appDelegate.player.play(context: context)
    }
    displayNowPlaying {}
  }

  func updateHomeSections() {
    guard interfaceController != nil, let cloudHome else { return }
    // cassette: compare only the sections CarPlay actually renders.
    let sections = carPlayHomeRows
    let renderedNow = sections.map { session.homeRowData[$0] ?? [] }
    let requestedNow = sections.map { carPlayItems($0) ?? [] }
    // phone-taste: the Mood row is not made of HomeItems, so its signature is compared too;
    // One Home: and the rows' order and names (the cloud renames the time-of-day row and
    // the reaching row during the day), and how many shelves All shelves holds.
    let layout = sections.map { "\($0.rawValue)=\(carPlayTitle($0))" }.joined(separator: "|")
      + "|shelves=\(cloudHome.shelves.count)"
    guard renderedNow != requestedNow
      || moodSignature() != session.moodSignature
      || layout != session.homeLayout
    else {
      return
    }
    var homeRows: [CPListTemplateItem] = createHomeImageRows()
    if let allShelves = makeAllShelvesRow() { homeRows.append(allShelves) }
    session.homeLayout = layout
    let homeSection = CPListSection(items: homeRows, header: nil, sectionIndexTitle: nil)
    homeTab.updateSections([homeSection])
    homeTab.emptyViewTitleVariants = HomeStore.shared.answer == nil
      ? ["Home arrives once your phone is online"]
      : ["Nothing of Home is on this phone yet"]
    pruneHomeArtworkIndex()
  }

  /// Drop tiles that are no longer on screen from the artwork index. A shelf rebuild replaces
  /// its elements, and the index used to keep every element ever built, so it grew on every
  /// track change for the life of the process (CPS-4).
  private func pruneHomeArtworkIndex() {
    let live = Set(
      session.homeImageRows.values
        .flatMap { ($0.elements as? [CPListImageRowItemRowElement]) ?? [] }
        .map { ObjectIdentifier($0) }
    )
    for (artworkID, var container) in session.homeArtworkUpdate {
      container.homeRow.removeAll { !live.contains(ObjectIdentifier($0)) }
      session.homeArtworkUpdate[artworkID] = container.homeRow.isEmpty ? nil : container
    }
  }

  func createHomeImageRows() -> [CPListImageRowItem] {
    guard cloudHome != nil else { return [] }
    var imageRows = [CPListImageRowItem]()
    for section in carPlayHomeRows {
      // All shelves is a plain row after the image rows (makeAllShelvesRow).
      if section == .allShelves { continue }
      // phone-taste: the Mood row has no HomeItems by design (HomeSection.moodDoors), so it
      // is built before the empty-shelf guard below, which would always hide it.
      if section == .moodDoors {
        if let row = makeMoodRow() { imageRows.append(row) }
        continue
      }
      // cassette: hide-when-empty on CarPlay (mirrors HomeVC Patch 036 at
      // HomeVC.swift:399). Skip shelves with no items and clear any stale
      // rendered snapshot so `updateHomeSections`' change-detection settles
      // rather than rebuilding on every callback while the shelf stays empty.
      guard let sectionItems = carPlayItems(section), !sectionItems.isEmpty else {
        session.homeRowData[section] = []
        continue
      }
      if let row = session.homeImageRows[section] {
        let alreadyCreatedData = session.homeRowData[section]
        let requestedData = carPlayItems(section)
        if alreadyCreatedData !=
          requestedData {
          let imageRowElements = createHomeRowImageElements(section: section)
          row.elements = imageRowElements
        }
        // phone-taste: a reused row takes its current title (the time-of-day row turns
        // from Evenings to Nights mid-drive).
        row.text = carPlayTitle(section)
        imageRows.append(row)
      } else if let row = createHomeRow(section: section) {
        session.homeImageRows[section] = row
        imageRows.append(row)
      }
    }
    return imageRows
  }

  func createHomeRow(section: HomeSection) -> CPListImageRowItem? {
    guard cloudHome != nil else { return nil }
    let alreadyCreatedData = session.homeRowData[section]
    let requestedData = carPlayItems(section)
    if alreadyCreatedData ==
      requestedData {
      return session.homeImageRows[section]
    }

    let imageRowElements = createHomeRowImageElements(section: section)
    let row = CPListImageRowItem(
      text: carPlayTitle(section),
      elements: imageRowElements,
      allowsMultipleLines: false
    )
    // handler CB is called when user pressed the section title
    row.handler = { [weak self] selectedRow, completion in
      guard let self else { completion(); return }
      Task { @MainActor in
        // cassette (BUG-338): the shelf title opens a plain row list of the shelf's items,
        // never a wrapped tile grid (see makeHomeShelfListTemplate).
        self.pushTemplateIfAllowed(
          self.makeHomeShelfListTemplate(section: section),
          animated: true
        )
        completion()
      }
    }
    // listImageRowHandler CB is called when user pressed on a image inside the row
    row.listImageRowHandler = { [weak self] item, index, completion in
      guard let self else { completion(); return }
      // Resolve the tap against the snapshot that backs the *visible* elements,
      // not the live shelf data: CloudHome rebuilds its rows
      // on every play/pause/stop and FRC change, so re-indexing it can hit nil
      // or the wrong item (the dead tap). That snapshot is session.homeRowData[section]
      // (kept in lockstep with row.elements). Match by stableID, preferring the
      // live item so playback uses a current managed object when one still exists.
      let renderedItems = session.homeRowData[section] ?? []
      guard index >= 0, index < renderedItems.count else { completion(); return }
      let tappedID = renderedItems[index].stableID
      // One Home: Nostalgia's mix among the reaching row's records plays as a playlist.
      if let mixID = renderedItems[index].mixID {
        Task { @MainActor in
          self.playReachMix(mixID, completion: completion)
        }
        return
      }
      let liveItem = carPlayItems(section)?.first { $0.stableID == tappedID }
      let selectedPlayable = (liveItem ?? renderedItems[index]).playableContainable
      Task { @MainActor in
        self.playFromHome(selectedPlayable)
        completion()
      }
    }
    return row
  }

  func createHomeRowImageElements(section: HomeSection) -> [CPListImageRowItemRowElement] {
    guard cloudHome != nil else { return [] }

    let alreadyCreatedData = session.homeRowData[section]
    let requestedData = carPlayItems(section)
    if alreadyCreatedData ==
      requestedData {
      return session.homeImageRows[section]?.elements as? [CPListImageRowItemRowElement] ?? []
    }
    session.homeRowData[section] = requestedData

    var imageRowElements = [CPListImageRowItemRowElement]()
    let items = requestedData ?? []
    for item in items {
      // One Home: Nostalgia's mix, as the Made for You row draws a record playlist.
      if let mixID = item.mixID, let mix = carReachMix(mixID) {
        imageRowElements.append(makeReachMixElement(mix))
        continue
      }
      // phone-taste: a station is dressed from the radio catalog (its own name, its network
      // or "Live", its logo or a word picture in its colour). Checked before the library
      // entity cast, which a Radio also passes, and never registered for artwork updates.
      if let radio = item.playableContainable as? Radio {
        imageRowElements.append(makeRadioElement(radio))
        continue
      }
      var image: UIImage?
      var artwork: Artwork?
      var entity: AbstractLibraryEntity?
      if let libEntity = item.playableContainable as? AbstractLibraryEntity {
        image = LibraryEntityImage.coverImage(
          libraryEntity: libEntity,
          artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference,
          useCache: false
        )
        if let entityArtwork = libEntity.artwork, let accountInfo = entityArtwork.account?.info {
          artwork = entityArtwork
          entity = libEntity
          // trigger download only once
          if session.homeArtworkUpdate[entityArtwork.uniqueID] == nil {
            appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: entityArtwork)
          }
        }
      } else if let playlist = item.playableContainable as? Playlist {
        // cassette (Wave 2b): a Playlist is NOT an AbstractLibraryEntity, so the
        // cast above missed and the Home tile fell to a placeholder. Resolve its
        // LOCAL cover (bundled preset or materialized pick) so playlists show art; a pick
        // not downloaded yet shows the preset (phone-taste: the shared fallback).
        image = CassetteCloudPlaylistBridge.displayCoverImage(for: playlist.id)
      }
      // cassette: artist tiles render as circles on CarPlay to match iOS (albums, playlists,
      // etc. stay square), real art and placeholder alike. A tile without art gets the
      // placeholder with the item's initial (BUG-421), like the library rows.
      let displayImage = style.artwork(
        image,
        kind: style.artworkKind(of: item.playableContainable),
        name: item.playableContainable.name,
        circle: item.playableContainable is Artist,
        slot: .shelf
      )

      let element = CPListImageRowItemRowElement(
        image: displayImage,
        title: item.playableContainable.name,
        subtitle: item.playableContainable.subtitle
      )
      if let artwork, let entity {
        if session.homeArtworkUpdate[artwork.uniqueID] == nil {
          session.homeArtworkUpdate[artwork.uniqueID] = EntityImageRowContainer(
            entity: entity,
            item: item,
            homeRow: [element]
          )
        } else {
          session.homeArtworkUpdate[artwork.uniqueID]?.homeRow.append(element)
        }
      }
      imageRowElements.append(element)
    }
    return imageRowElements
  }

  /// cassette (BUG-338): the shelf detail is a plain row list, never a wrapped tile grid, because the
  /// phone cannot learn the head unit's column count. Rows are the library's own detail rows, so a
  /// tap opens the same view a Home tile tap opens, and artwork lands through the "refresh List items"
  /// walk in downloadFinishedSuccessful because the rows carry userInfo. Built at push time as a
  /// snapshot of the shelf, like the grid was.
  func makeHomeShelfListTemplate(section: HomeSection) -> CPListTemplate {
    // One Home: within the car's browse budget (24), like every other list a row opens.
    let items = (carPlayItems(section) ?? []).prefix(carPlayBrowseItemBudget)
    var rows = [CPListItem]()
    for item in items {
      let containable = item.playableContainable
      if let mixID = item.mixID {
        if let mix = carReachMix(mixID) { rows.append(makeReachMixRow(mix)) }
        continue
      }
      if let album = containable as? Album {
        rows.append(createDetailTemplate(for: album, onlyCached: isOfflineMode))
      } else if let artist = containable as? Artist {
        rows.append(createDetailTemplate(for: artist, onlyCached: isOfflineMode))
      } else if let playlist = containable as? Playlist {
        rows.append(createPlaylistRow(playlist))
      } else if let radio = containable as? Radio {
        rows.append(makeRadioRow(radio))
      } else {
        // Reached by no CarPlay shelf today (albums, artists, playlists and stations have
        // their own rows); exists so nothing is ever silently skipped if a shelf of another
        // kind is added.
        rows.append(makePlayContainableRow(containable))
      }
    }
    let template = CPListTemplate(title: carPlayTitle(section), sections: [CPListSection(items: rows)])
    template.emptyViewTitleVariants = ["Nothing here yet"]
    return template
  }

  /// cassette (BUG-338): the fallback row for a shelf item without a detail view: the old
  /// tile behaviour, play the item then show Now Playing. Generated artwork only.
  private func makePlayContainableRow(_ containable: PlayableContainable) -> CPListItem {
    let row = CPListItem(
      text: containable.name,
      detailText: containable.subtitle,
      image: style.artwork(nil, kind: style.artworkKind(of: containable), name: containable.name),
      accessoryImage: nil,
      accessoryType: .none
    )
    row.handler = { [weak self] _, completion in
      guard let self = self else { completion(); return }
      appDelegate.player.play(context: PlayContext(containable: containable))
      displayNowPlaying { completion() }
    }
    return row
  }
}

// MARK: - Mood row (phone-taste)

extension CarPlaySceneDelegate {
  /// What decides the Made for You row's tiles and art: the Lately mix's lead albums (when
  /// it has songs), and each other playlist's id, title and lead albums. Cheap: no image is
  /// decoded here.
  func moodSignature() -> String {
    var parts = [String]()
    if let mix = carLatelyMix, !mix.songs.isEmpty {
      parts.append("lately:" + mix.leadAlbums.map(\.id).joined(separator: ","))
    }
    parts.append("title:" + carPlayTitle(.moodDoors))
    for mix in carOtherMixes {
      parts.append("\(mix.id)=\(mix.title):" + mix.leadAlbums.map(\.id).joined(separator: ","))
      // A mood mix's drawn cover, and whether it has landed (the tile swaps it in).
      if let address = MixCoverCache.address(for: mix) {
        parts.append("\(address.absoluteString)=\(MixCoverCache.isOnDisk(address))")
      }
    }
    return parts.joined(separator: "|")
  }

  /// The Mood row, rebuilt (tiles, covers, art) only when its signature changed, or nil when
  /// it has no tiles. The row object is kept for the session, so a tile list that empties
  /// and fills again reuses it.
  fileprivate func makeMoodRow() -> CPListImageRowItem? {
    let signature = moodSignature()
    if signature != session.moodSignature {
      session.moodSignature = signature
      rebuildMoodTiles()
      let elements = session.moodTiles.map { makeMoodElement($0) }
      if let row = session.moodRow {
        row.elements = elements
        row.text = carPlayTitle(.moodDoors)
      } else if !elements.isEmpty {
        session.moodRow = createMoodRow(elements: elements)
      }
    }
    return session.moodTiles.isEmpty ? nil : session.moodRow
  }

  /// BUG-460: covers a record tile was waiting for have landed. The row's tiles are rebuilt
  /// in place when the row is on screen (no Home redraw, which a cover burst on the first
  /// drive would repeat, BUG-435); Home is redrawn only when the row isn't there yet.
  func redrawMoodRowForArrivedCovers() {
    guard interfaceController != nil else { return }
    session.moodSignature = nil
    if session.moodRow != nil {
      _ = makeMoodRow()
    } else {
      updateHomeSections()
    }
  }

  /// The Lately tile when the mix has songs and four of its lead albums have a cover on disk
  /// (decoded here, once per signature), then Home's other made-for-you playlists: a mood
  /// mix as its drawn cover once that is on disk (its colour and name until then), the others
  /// as their records with the name across them (shown only with four covers on disk, like
  /// Lately). The server's mood doors are no longer offered (founder, 2026-10-21): the
  /// phone's mood mixes replace them, with no beta.
  private func rebuildMoodTiles() {
    var tiles = [CarMoodTile]()
    var coversByTile = [String: [UIImage]]()
    var awaited = Set<String>()
    let preference = getPreference(activeAccountInfo).artworkDisplayPreference
    func fourCovers(_ albums: [Album]) -> [UIImage]? {
      let covers = albums.compactMap { album -> UIImage? in
        let cover = LibraryEntityImage.coverImage(
          libraryEntity: album,
          artworkDisplayPreference: preference,
          useCache: false
        )
        // Not on the phone yet: draw the row again when it lands (BUG-460).
        if cover == nil, let artworkID = album.artwork?.uniqueID { awaited.insert(artworkID) }
        return cover
      }
      return covers.count >= Self.latelyCoverCount ? Array(covers.prefix(Self.latelyCoverCount)) : nil
    }
    if let mix = carLatelyMix, !mix.songs.isEmpty, let covers = fourCovers(mix.leadAlbums) {
      tiles.append(.lately)
      coversByTile["lately"] = covers
    }
    for mix in carOtherMixes {
      if case let .mood(_, hexColor) = mix.kind {
        tiles.append(.mix(id: mix.id, title: mix.title, hexColor: hexColor))
        // Its drawn cover when it is on disk (never fetched here); its colour and name until then.
        if let address = MixCoverCache.address(for: mix),
           let cover = MixCoverCache.diskImage(address, maxPixelSize: Self.drawnCoverPixels) {
          coversByTile[mix.id] = [cover]
        }
      } else if let covers = fourCovers(mix.leadAlbums) {
        tiles.append(.mix(id: mix.id, title: mix.title, hexColor: nil))
        coversByTile[mix.id] = covers
      }
    }
    session.moodTiles = tiles
    session.moodCovers = coversByTile
    session.moodAwaitedArtworkIDs = awaited
  }

  /// A tile's picture and title. Lately and the other record playlists: their records in a
  /// square with the name across them. A mood mix: its drawn cover, else (or a door) its
  /// colour and its name.
  private func moodArt(_ tile: CarMoodTile, slot: CarPlayStyle.Slot) -> (image: UIImage, title: String) {
    switch tile {
    case .lately:
      return (style.mosaicArt(covers: session.moodCovers["lately"] ?? [], word: "Lately", slot: slot), "Lately")
    case let .door(_, label, hexColor):
      let color = UIColor(cassetteHexString: hexColor) ?? UIColor.cassette(.surfaceElevated)
      return (style.wordArt(word: label, color: color, slot: slot), label)
    case let .mix(id, title, hexColor):
      if let hexColor {
        if let cover = session.moodCovers[id]?.first {
          return (style.drawnCover(cover, slot: slot), title)
        }
        let color = UIColor(cassetteHexString: hexColor) ?? UIColor.cassette(.surfaceElevated)
        return (style.wordArt(word: title, color: color, slot: slot), title)
      }
      return (style.mosaicArt(covers: session.moodCovers[id] ?? [], word: title, slot: slot), title)
    }
  }

  private func makeMoodElement(_ tile: CarMoodTile) -> CPListImageRowItemRowElement {
    let art = moodArt(tile, slot: .shelf)
    return CPListImageRowItemRowElement(image: art.image, title: art.title, subtitle: "Playlist")
  }

  private func createMoodRow(elements: [CPListImageRowItemRowElement]) -> CPListImageRowItem {
    let row = CPListImageRowItem(text: carPlayTitle(.moodDoors), elements: elements, allowsMultipleLines: false)
    // The title opens the tiles as a plain list (the same art at row size).
    row.handler = { [weak self] _, completion in
      guard let self else { completion(); return }
      Task { @MainActor in
        self.pushTemplateIfAllowed(self.makeMoodListTemplate(), animated: true)
        completion()
      }
    }
    // A tile plays at once. The tap resolves against the tiles the row was drawn from.
    row.listImageRowHandler = { [weak self] _, index, completion in
      guard let self else { completion(); return }
      Task { @MainActor in
        let tiles = self.session.moodTiles
        guard index >= 0, index < tiles.count else { completion(); return }
        self.playMoodTile(tiles[index], completion: completion)
      }
    }
    return row
  }

  /// The Mood row's title tap: one row per tile, detail "Mix". A row plays, as the tile does.
  private func makeMoodListTemplate() -> CPListTemplate {
    let rows: [CPListItem] = session.moodTiles.map { tile in
      let art = moodArt(tile, slot: .row)
      let item = CPListItem(
        text: art.title,
        detailText: "Playlist",
        image: art.image,
        accessoryImage: nil,
        accessoryType: .none
      )
      item.handler = { [weak self] _, completion in
        guard let self else { completion(); return }
        Task { @MainActor in
          self.playMoodTile(tile, completion: completion)
        }
      }
      return item
    }
    let template = CPListTemplate(title: carPlayTitle(.moodDoors), sections: [CPListSection(items: rows)])
    template.emptyViewTitleVariants = ["Nothing here yet"]
    return template
  }

  private func playMoodTile(_ tile: CarMoodTile, completion: @escaping () -> ()) {
    switch tile {
    case .lately:
      playLately(completion: completion)
    case let .door(key, label, _):
      playDoor(key: key, label: label, completion: completion)
    case let .mix(id, title, _):
      playMix(id: id, title: title, completion: completion)
    }
  }

  /// One of Home's other made-for-you playlists, played at once from the songs still on the
  /// phone.
  private func playMix(id: String, title: String, completion: @escaping () -> ()) {
    let mix = carOtherMixes.first(where: { $0.id == id })
    let songs = OneTapPlay.playables(mix?.songs ?? [])
    guard !songs.isEmpty else {
      presentCarAlert("\(title) has nothing on this phone right now", completion: completion)
      return
    }
    appDelegate.player.play(context: PlayContext(name: title, playables: songs))
    displayNowPlaying { completion() }
  }

  /// The Lately mix Home built with the tile (songs on this phone matching recent listening),
  /// played at once.
  private func playLately(completion: @escaping () -> ()) {
    let songs = OneTapPlay.playables(carLatelyMix?.songs ?? [])
    guard !songs.isEmpty else {
      presentCarAlert("Not enough music on this phone matches lately yet", completion: completion)
      return
    }
    appDelegate.player.play(context: PlayContext(name: "Lately", playables: songs))
    displayNowPlaying { completion() }
  }

  /// A door's mix, fetched and played at once (the car has no preview sheet). One door loads
  /// at a time; a result that arrives after something else started playing is dropped, so a
  /// slow network never yanks away what the driver chose since. `completion` runs on every
  /// path.
  private func playDoor(key: String, label: String, completion: @escaping () -> ()) {
    guard session.doorLoad == nil else { completion(); return }
    let token = UUID()
    session.doorLoad = token
    session.doorLoadOvertaken = false
    Task { @MainActor [weak self] in
      let outcome = await MixtapePlayback.makeDoorMix(doorKey: key)
      // A disconnect or an account change replaced the session: drop it.
      guard let self, self.session.doorLoad == token else { completion(); return }
      let overtaken = self.session.doorLoadOvertaken
      self.session.doorLoad = nil
      self.session.doorLoadOvertaken = false
      guard !overtaken else { completion(); return }
      switch outcome {
      case let .ok(name, songs):
        self.appDelegate.player.play(context: PlayContext(name: name, playables: songs))
        self.displayNowPlaying { completion() }
      case .notEnough:
        self.presentCarAlert("Not enough of your music fits \(label) yet", completion: completion)
      case .nothingOnPhone:
        self.presentCarAlert("None of \(label) is on this phone yet", completion: completion)
      case .unavailable:
        self.presentCarAlert("Can't make \(label) right now", completion: completion)
      }
    }
  }

  /// The player's queue changed (anything played, from the car or the phone): a door mix
  /// still loading must not take over when it lands. Called from the player notifier.
  func noteQueueChangedForDoorLoad() {
    if session.doorLoad != nil { session.doorLoadOvertaken = true }
  }

  /// A one-line car alert with a single OK that dismisses it. Always presented with a
  /// completion, so a refused present is reported rather than raised.
  func presentCarAlert(_ message: String, completion: @escaping () -> ()) {
    guard let interfaceController else { completion(); return }
    let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
      self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
    }
    let alert = CPAlertTemplate(titleVariants: [message], actions: [ok])
    interfaceController.presentTemplate(alert, animated: true) { _, _ in }
    completion()
  }
}

// MARK: - The reaching row and All shelves (One Home)

extension CarPlaySceneDelegate {
  /// Nostalgia's mix as a tile: its records with its name across them (as the Made for You
  /// row draws a record playlist).
  fileprivate func makeReachMixElement(_ mix: HomeManager.MadeForYouMix) -> CPListImageRowItemRowElement {
    CPListImageRowItemRowElement(image: reachMixArt(mix, slot: .shelf), title: mix.title, subtitle: "Playlist")
  }

  fileprivate func makeReachMixRow(_ mix: HomeManager.MadeForYouMix) -> CPListItem {
    let item = CPListItem(
      text: mix.title,
      detailText: "Playlist",
      image: reachMixArt(mix, slot: .row),
      accessoryImage: nil,
      accessoryType: .none
    )
    item.handler = { [weak self] _, completion in
      guard let self else { completion(); return }
      Task { @MainActor in self.playReachMix(mix.id, completion: completion) }
    }
    return item
  }

  private func reachMixArt(_ mix: HomeManager.MadeForYouMix, slot: CarPlayStyle.Slot) -> UIImage {
    let preference = getPreference(activeAccountInfo).artworkDisplayPreference
    let covers = mix.leadAlbums.compactMap {
      LibraryEntityImage.coverImage(libraryEntity: $0, artworkDisplayPreference: preference, useCache: false)
    }
    return style.mosaicArt(covers: Array(covers.prefix(Self.latelyCoverCount)), word: mix.title, slot: slot)
  }

  /// The reaching row's mix, played at once from the songs still on the phone.
  fileprivate func playReachMix(_ id: String, completion: @escaping () -> ()) {
    guard let mix = carReachMix(id) else { completion(); return }
    let songs = OneTapPlay.playables(mix.songs)
    guard !songs.isEmpty else {
      presentCarAlert("\(mix.title) has nothing on this phone right now", completion: completion)
      return
    }
    appDelegate.player.play(context: PlayContext(name: mix.title, playables: songs))
    displayNowPlaying { completion() }
  }

  /// The way to every shelf made today, a plain row after Home's image rows; nil when today
  /// has no shelf the phone holds records of.
  func makeAllShelvesRow() -> CPListItem? {
    guard let cloudHome, cloudHome.row(.allShelves)?.isFilled == true else { return nil }
    let item = CPListItem(
      text: carPlayTitle(.allShelves),
      detailText: nil,
      image: nil,
      accessoryImage: nil,
      accessoryType: .disclosureIndicator
    )
    item.handler = { [weak self] _, completion in
      guard let self else { completion(); return }
      Task { @MainActor in
        self.pushTemplateIfAllowed(self.makeAllShelvesTemplate(), animated: true)
        completion()
      }
    }
    return item
  }

  /// Today's shelves, the one on Home first: a shelf opens as a list of its records.
  private func makeAllShelvesTemplate() -> CPListTemplate {
    let preference = getPreference(activeAccountInfo).artworkDisplayPreference
    let shelves = (cloudHome?.shelves ?? []).prefix(carPlayBrowseItemBudget)
    let rows: [CPListItem] = shelves.map { shelf in
      let title = Self.titleCase([shelf.shout, shelf.answer].filter { !$0.isEmpty }.joined(separator: " "))
      let cover = shelf.albums.first.flatMap {
        LibraryEntityImage.coverImage(libraryEntity: $0, artworkDisplayPreference: preference, useCache: false)
      }
      let count = shelf.albums.count == 1 ? "1 album" : "\(shelf.albums.count) albums"
      let item = CPListItem(
        text: title,
        detailText: shelf.onHome ? "On Home" : (shelf.mix == nil ? count : "A playlist and \(count)"),
        image: style.artwork(cover, kind: .album, name: title, slot: .row),
        accessoryImage: nil,
        accessoryType: .disclosureIndicator
      )
      let shelfID = shelf.id
      item.handler = { [weak self] _, completion in
        guard let self else { completion(); return }
        Task { @MainActor in
          if let template = self.makeShelfTemplate(id: shelfID) {
            self.pushTemplateIfAllowed(template, animated: true)
          }
          completion()
        }
      }
      return item
    }
    let template = CPListTemplate(title: carPlayTitle(.allShelves), sections: [CPListSection(items: rows)])
    template.emptyViewTitleVariants = ["No shelves today"]
    return template
  }

  /// One shelf's records (Nostalgia's mix first), within the car's browse budget.
  private func makeShelfTemplate(id: String) -> CPListTemplate? {
    guard let shelf = cloudHome?.shelves.first(where: { $0.id == id }) else { return nil }
    var rows = [CPListItem]()
    if let mix = shelf.mix { rows.append(makeReachMixRow(mix)) }
    for album in shelf.albums.prefix(max(0, carPlayBrowseItemBudget - rows.count)) {
      rows.append(createDetailTemplate(for: album, onlyCached: isOfflineMode))
    }
    let title = Self.titleCase([shelf.shout, shelf.answer].filter { !$0.isEmpty }.joined(separator: " "))
    let template = CPListTemplate(title: title, sections: [CPListSection(items: rows)])
    template.emptyViewTitleVariants = ["Nothing here yet"]
    return template
  }
}

// MARK: - Radio tiles and rows (phone-taste)

extension CarPlaySceneDelegate {
  /// A station's words from the bundled radio catalog: its own name (else the hub's), and its
  /// network, or "Live" when the network is the station itself (nil for a station the catalog
  /// does not know).
  private func radioWords(_ radio: Radio) -> (name: String, line: String?, info: RadioCatalogStation?) {
    let info = RadioCatalog.shared.station(forStreamUrl: radio.url)
    let name = info?.name ?? radio.title
    let line = info.map { $0.sourceLabel != $0.name ? $0.sourceLabel : "Live" }
    return (name, line, info)
  }

  /// The station's logo when it is already in memory, else a word picture in its colour.
  private func radioArt(info: RadioCatalogStation?, name: String, slot: CarPlayStyle.Slot) -> UIImage {
    if let url = info?.image, !url.isEmpty, let logo = RadioArtLoader.shared.cachedImage(for: url) {
      return style.artwork(logo, kind: .radio, name: name, slot: slot)
    }
    let color = info.flatMap { UIColor(cassetteHexString: $0.accent) }
      ?? UIColor.cassette(.surfaceElevated)
    return style.wordArt(word: name, color: color, slot: slot)
  }

  /// Fetches the station's logo when it has one that is not in memory yet, and hands it over
  /// drawn for `slot`. Offline the word picture simply stays.
  private func loadRadioLogo(
    info: RadioCatalogStation?,
    name: String,
    slot: CarPlayStyle.Slot,
    apply: @escaping (UIImage) -> ()
  ) {
    guard let url = info?.image, !url.isEmpty, RadioArtLoader.shared.cachedImage(for: url) == nil
    else { return }
    Task { @MainActor [weak self] in
      guard let logo = await RadioArtLoader.shared.image(for: url), let self else { return }
      apply(self.style.artwork(logo, kind: .radio, name: name, slot: slot))
    }
  }

  fileprivate func makeRadioElement(_ radio: Radio) -> CPListImageRowItemRowElement {
    let words = radioWords(radio)
    let element = CPListImageRowItemRowElement(
      image: radioArt(info: words.info, name: words.name, slot: .shelf),
      title: words.name,
      subtitle: words.line
    )
    loadRadioLogo(info: words.info, name: words.name, slot: .shelf) { [weak element] logo in
      element?.image = logo
    }
    return element
  }

  /// The Radio row's list: the same name, line and picture at row size. A tap plays the
  /// station and shows Now Playing, as the tile does.
  fileprivate func makeRadioRow(_ radio: Radio) -> CPListItem {
    let words = radioWords(radio)
    let item = CPListItem(
      text: words.name,
      detailText: words.line,
      image: radioArt(info: words.info, name: words.name, slot: .row),
      accessoryImage: nil,
      accessoryType: .none
    )
    loadRadioLogo(info: words.info, name: words.name, slot: .row) { [weak item] logo in
      item?.setImage(logo)
    }
    item.handler = { [weak self] _, completion in
      guard let self else { completion(); return }
      appDelegate.player.play(context: PlayContext(containable: radio))
      displayNowPlaying { completion() }
    }
    return item
  }
}
