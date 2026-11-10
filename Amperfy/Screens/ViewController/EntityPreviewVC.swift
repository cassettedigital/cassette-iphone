//
//  EntityPreviewVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 12.02.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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
import MarqueeLabel
import UIKit

typealias GetPlayContextCallback = () -> PlayContext?
typealias GetPlayerIndexCallback = () -> PlayerIndex?

// MARK: - EntityPreviewActionBuilder

@MainActor
class EntityPreviewActionBuilder {
  private var entityContainer: PlayableContainable
  private var rootView: UIViewController
  private var playContextCb: GetPlayContextCallback?
  private var playerIndexCb: GetPlayerIndexCallback?
  private var appDelegate: AppDelegate

  /// What the menu's Play, Shuffle, queue and Add to Playlist actions act on. Music is only
  /// what this phone can play (OneTapPlay's rule: in on-device mode the songs on this phone,
  /// cached or not), so a long-press on any surface never queues a song that is not here.
  /// Read when an action is chosen, not when the menu is built.
  private var entityPlayables: [AbstractPlayable] {
    switch entityContainer.playContextType {
    case .music:
      return OneTapPlay.playables(of: entityContainer)
        .filter { $0.asSong?.isAvailableToUser() ?? $0.asRadio?.isAvailableToUser() ?? false }
    case .podcast:
      return entityContainer.playables
        .filterCached(dependigOn: appDelegate.storage.settings.user.isOfflineMode)
    }
  }

  // configure states
  private var isPlay = false
  private var isShuffle = false
  private var isMusicQueue = false
  private var isPodcastQueue = false
  private var isShowAlbum = false
  private var isShowArtist = false
  private var isAddToPlaylist = false
  private var isDownloadPossible: Bool {
    !(
      entityContainer.playables.isCachedCompletely ||
        appDelegate.storage.settings.user.isOfflineMode ||
        !entityContainer.isDownloadAvailable
    )
  }

  private var isDeleteOnServer = false
  private var isGoToSiteUrl = false
  private var isShowPodcastDetails = false
  private var isShowSongDetails = false
  /// cassette: "Start Mixtape from this track" — POST /api/mixtape/radio,
  /// then open the mixtape preview sheet (never auto-plays). Same online-only
  /// gating as the retired Instant Mix, which this replaces in spirit.
  private var isStartMixtape = false
  /// cassette: "Share Song…" (CASSETTE_SHARING.md): the share sheet, then Apple's share sheet. Songs only,
  /// never a radio stream or a podcast; it needs the network, because the link is saved in the cloud.
  private var isShareSong = false

  init(
    container: PlayableContainable,
    on rootView: UIViewController,
    playContextCb: GetPlayContextCallback? = nil,
    playerIndexCb: GetPlayerIndexCallback? = nil
  ) {
    self.appDelegate = (UIApplication.shared.delegate as! AppDelegate)
    self.entityContainer = container
    self.rootView = rootView
    self.playContextCb = playContextCb
    self.playerIndexCb = playerIndexCb
  }

  public func createMenu() -> UIMenu {
    UIMenu(children: createMenuActions())
  }

  public func createMenuActions() -> [UIMenuElement] {
    var menuActions = [UIMenuElement]()

    configureUI()

    var playActions = [UIMenuElement]()
    var gotoActions = [UIMenuElement]()
    var elementHandlingActions = [UIMenuElement]()

    if isPlay {
      playActions.append(createPlayAction())
    }
    if isShuffle {
      playActions.append(createPlayShuffledAction())
    }
    // cassette Polish 2 (G4): Instant Mix removed from every context menu.
    if isStartMixtape {
      playActions.append(createMixtapeAction())
    }
    if !playActions.isEmpty {
      menuActions.append(UIMenu(options: .displayInline, children: playActions))
    }
    if isMusicQueue {
      menuActions.append(createMusicQueueAction())
    }
    if isPodcastQueue {
      menuActions.append(createPodcastQueueAction())
    }
    if isShowAlbum {
      gotoActions.append(createShowAlbumAction())
    }
    if isShowArtist {
      gotoActions.append(createShowArtistAction())
    }
    if isShowSongDetails,
       let song = (entityContainer as? AbstractPlayable)?.asSong,
       let lyricsShowAction = createShowLyricsAction(song: song) {
      gotoActions.append(lyricsShowAction)
    }
    if isShowPodcastDetails,
       let podcastEpisode = (entityContainer as? AbstractPlayable)?.asPodcastEpisode {
      gotoActions.append(createShowEpisodeDetailsAction(podcastEpisode: podcastEpisode))
    }
    if isShowPodcastDetails, let podcast = entityContainer as? Podcast {
      gotoActions.append(createShowPodcastDetailsAction(podcast: podcast))
    }
    if !gotoActions.isEmpty {
      menuActions.append(UIMenu(options: .displayInline, children: gotoActions))
    }
    // cassette Polish 2 (G4): Rating removed from every context menu.
    // cassette: favorites feature removed — no Favorite entry in the overflow menu.
    if isAddToPlaylist {
      elementHandlingActions.append(createAddToPlaylistAction())
    }
    // cassette Polish 2 (G4): Download removed from every context menu.
    // Patch 111: Delete Cache is a streaming/server-mode affordance. Gate it on
    // the SAME Cassette server-mode concept the Albums shelf uses — server mode
    // on == NOT CassetteLibraryFilterProvider.isOnDeviceOnly — not the upstream
    // `isOnlineMode` (which is true whenever connected, so it leaked the action
    // into the default on-device-only mode). hasCachedItems keeps it to tracks
    // that are actually cached.
    if !CassetteLibraryFilterProvider.shared.isOnDeviceOnly,
       entityContainer.playables.hasCachedItems {
      elementHandlingActions.append(createDeleteCacheAction())
    }
    // cassette (UX review 2026-10-20): the phone's own way to drop an album. Files go
    // now; the album stays on the computer and is kept off this phone until it is sent
    // back from the device page in Cassette Player (PhoneRemoval).
    if CassetteLibraryFilterProvider.shared.isOnDeviceOnly, let album = entityContainer as? Album {
      elementHandlingActions.append(createRemoveFromPhoneAction(album: album))
    }
    if isDeleteOnServer {
      elementHandlingActions.append(createDeleteOnServerAction())
    }
    if isGoToSiteUrl, let radio = (entityContainer as? AbstractPlayable)?.asRadio {
      // a station the dial knows gets the dial's places (its site and where to support it, StationPlaces)
      if let info = RadioCatalog.shared.station(forStreamUrl: radio.url) {
        elementHandlingActions.append(contentsOf: StationPlaces.actions(for: info))
      } else if let url = radio.siteURL {
        elementHandlingActions.append(createGoToSiteUrl(url: url))
      }
    }
    if !elementHandlingActions.isEmpty {
      menuActions.append(UIMenu(options: .displayInline, children: elementHandlingActions))
    }
    // cassette: its own group near the end of the menu, where Apple Music keeps Share Song…
    if isShareSong, let song = (entityContainer as? AbstractPlayable)?.asSong {
      menuActions.append(UIMenu(options: .displayInline, children: [createShareSongElement(songId: song.id)]))
    }
    if appDelegate.storage.settings.user.isShowDetailedInfo {
      menuActions.append(createCopyIdToClipboardAction())
    }

    return menuActions
  }

  public func performPreviewTransition() {
    if let playable = entityContainer as? AbstractPlayable {
      if let _ = playable.asSong, !(rootView is AlbumDetailVC) {
        showAlbum()
      } else if let _ = playable.asPodcastEpisode, !(rootView is PodcastDetailVC) {
        showArtist()
      }
    } else if let album = entityContainer as? Album, let account = album.account {
      rootView.navigationController?.pushViewController(
        AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
        animated: true
      )
    } else if let artist = entityContainer as? Artist, let account = artist.account {
      rootView.navigationController?.pushViewController(
        AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist),
        animated: true
      )
    } else if let genre = entityContainer as? Genre, let account = genre.account {
      rootView.navigationController?.pushViewController(
        AppStoryboard.Main.segueToGenreDetail(account: account, genre: genre),
        animated: true
      )
    } else if let playlist = entityContainer as? Playlist, let account = playlist.account {
      rootView.navigationController?.pushViewController(
        AppStoryboard.Main.segueToPlaylistDetail(account: account, playlist: playlist),
        animated: true
      )
    } else if let podcast = entityContainer as? Podcast, let account = podcast.account {
      rootView.navigationController?.pushViewController(
        AppStoryboard.Main.segueToPodcastDetail(account: account, podcast: podcast),
        animated: true
      )
    } else if let directory = entityContainer as? Directory, let account = directory.account {
      rootView.navigationController?.pushViewController(
        AppStoryboard.Main.segueToDirectories(account: account, directory: directory),
        animated: true
      )
    }
  }

  private func configureUI() {
    if let playable = entityContainer as? AbstractPlayable {
      if let song = playable.asSong {
        configureFor(song: song)
      } else if let podcastEpisode = playable.asPodcastEpisode {
        configureFor(podcastEpisode: podcastEpisode)
      } else if let radio = playable.asRadio {
        configureFor(radio: radio)
      }
    } else if let album = entityContainer as? Album {
      configureFor(album: album)
    } else if let artist = entityContainer as? Artist {
      configureFor(artist: artist)
    } else if let genre = entityContainer as? Genre {
      configureFor(genre: genre)
    } else if let playlist = entityContainer as? Playlist {
      configureFor(playlist: playlist)
    } else if let podcast = entityContainer as? Podcast {
      configureFor(podcast: podcast)
    } else if let directory = entityContainer as? Directory {
      configureFor(directory: directory)
    }
  }

  private func configureFor(song: Song) {
    isPlay = !(
      (playContextCb == nil) ||
        (!song.isCached && appDelegate.storage.settings.user.isOfflineMode)
    )
    isShuffle = !(
      (playContextCb == nil) ||
        playerIndexCb != nil ||
        (!song.isCached && appDelegate.storage.settings.user.isOfflineMode)
    ) &&
      appDelegate.storage.settings.user.isPlayerShuffleButtonEnabled
    isMusicQueue = !(
      (playContextCb == nil) ||
        playerIndexCb != nil ||
        (!song.isCached && appDelegate.storage.settings.user.isOfflineMode)
    )
    isPodcastQueue = false
    isShowAlbum = !(rootView is AlbumDetailVC)
    isShowArtist = !(rootView is ArtistDetailVC)
    isAddToPlaylist = appDelegate.storage.settings.user.isOnlineMode
    isDeleteOnServer = false
    isGoToSiteUrl = false
    isShowPodcastDetails = false
    isShowSongDetails = true
    // cassette (BUG-348): "Start Mixtape" only for accounts in the Mixtape beta;
    // the radio API answers 404 otherwise.
    isStartMixtape = appDelegate.storage.settings.user.isOnlineMode &&
      CassetteBetaAccess.isBetaTester
    isShareSong = appDelegate.storage.settings.user.isOnlineMode
  }

  private func configureFor(podcastEpisode: PodcastEpisode) {
    isPlay = !(
      (playContextCb == nil) ||
        (!podcastEpisode.isAvailableToUser() && appDelegate.storage.settings.user.isOnlineMode) ||
        (!podcastEpisode.isCached && appDelegate.storage.settings.user.isOfflineMode)
    )
    isShuffle = false
    isMusicQueue = false
    isPodcastQueue = !(
      (playContextCb == nil) ||
        (playerIndexCb != nil) ||
        (!podcastEpisode.isAvailableToUser() && appDelegate.storage.settings.user.isOnlineMode) ||
        (!podcastEpisode.isCached && appDelegate.storage.settings.user.isOfflineMode)
    )
    isShowAlbum = false
    isShowArtist = !(rootView is PodcastDetailVC)
    isAddToPlaylist = false
    isDeleteOnServer = podcastEpisode.podcastStatus != .deleted && appDelegate.storage.settings.user
      .isOnlineMode
    isGoToSiteUrl = false
    isShowPodcastDetails = true
    isShowSongDetails = false
  }

  private func configureFor(radio: Radio) {
    isPlay = !((playContextCb == nil) || appDelegate.storage.settings.user.isOfflineMode)
    isShuffle = false
    isMusicQueue = !(
      (playContextCb == nil) ||
        playerIndexCb != nil ||
        (appDelegate.storage.settings.user.isOfflineMode)
    )
    isPodcastQueue = false
    isAddToPlaylist = false
    isDeleteOnServer = false
    isGoToSiteUrl = radio.siteURL != nil || RadioCatalog.shared.station(forStreamUrl: radio.url) != nil
    isShowPodcastDetails = false
    isShowSongDetails = false
  }

  private func configureFor(playlist: Playlist) {
    isPlay = appDelegate.storage.settings.user.isOnlineMode || entityContainer.playables
      .hasCachedItems
    isShuffle = (
      appDelegate.storage.settings.user.isOnlineMode || entityContainer.playables
        .hasCachedItems
    ) &&
      appDelegate.storage.settings.user.isPlayerShuffleButtonEnabled
    isMusicQueue = true
    isPodcastQueue = false
    isShowAlbum = false
    isShowArtist = false
    isAddToPlaylist = appDelegate.storage.settings.user.isOnlineMode
    isDeleteOnServer = false
    isGoToSiteUrl = false
    isShowPodcastDetails = false
    isShowSongDetails = false
  }

  private func configureFor(genre: Genre) {
    isPlay = appDelegate.storage.settings.user.isOnlineMode || entityContainer.playables
      .hasCachedItems
    isShuffle = (
      appDelegate.storage.settings.user.isOnlineMode || entityContainer.playables
        .hasCachedItems
    ) &&
      appDelegate.storage.settings.user.isPlayerShuffleButtonEnabled
    isMusicQueue = true
    isPodcastQueue = false
    isShowAlbum = false
    isShowArtist = false
    isAddToPlaylist = appDelegate.storage.settings.user.isOnlineMode
    isDeleteOnServer = false
    isGoToSiteUrl = false
    isShowPodcastDetails = false
    isShowSongDetails = false
  }

  private func configureFor(podcast: Podcast) {
    isPlay = (
      appDelegate.storage.settings.user.isOnlineMode || entityContainer.playables
        .hasCachedItems
    ) &&
      appDelegate.storage.settings.user.isPlayerShuffleButtonEnabled
    isShuffle = false
    isMusicQueue = false
    isShowAlbum = false
    isShowArtist = false
    isPodcastQueue = true
    isAddToPlaylist = false
    isDeleteOnServer = false
    isGoToSiteUrl = false
    isShowPodcastDetails = true
    isShowSongDetails = false
  }

  private func configureFor(artist: Artist) {
    isPlay = appDelegate.storage.settings.user.isOnlineMode || entityContainer.playables
      .hasCachedItems
    isShuffle = (
      appDelegate.storage.settings.user.isOnlineMode || entityContainer.playables
        .hasCachedItems
    ) &&
      appDelegate.storage.settings.user.isPlayerShuffleButtonEnabled
    isMusicQueue = true
    isPodcastQueue = false
    isShowAlbum = false
    isShowArtist = false
    isAddToPlaylist = appDelegate.storage.settings.user.isOnlineMode
    isDeleteOnServer = false
    isGoToSiteUrl = false
    isShowPodcastDetails = false
    isShowSongDetails = false
  }

  private func configureFor(album: Album) {
    isPlay = appDelegate.storage.settings.user.isOnlineMode || entityContainer.playables
      .hasCachedItems
    isShuffle = (
      appDelegate.storage.settings.user.isOnlineMode || entityContainer.playables
        .hasCachedItems
    ) &&
      appDelegate.storage.settings.user.isPlayerShuffleButtonEnabled
    isMusicQueue = true
    isPodcastQueue = false
    isShowAlbum = false
    isShowArtist = !(rootView is ArtistDetailVC)
    isAddToPlaylist = appDelegate.storage.settings.user.isOnlineMode
    isDeleteOnServer = false
    isGoToSiteUrl = false
    isShowPodcastDetails = false
    isShowSongDetails = false
  }

  private func configureFor(directory: Directory) {
    isPlay = appDelegate.storage.settings.user.isOnlineMode || entityContainer.playables
      .hasCachedItems
    isShuffle = (
      appDelegate.storage.settings.user.isOnlineMode || entityContainer.playables
        .hasCachedItems
    ) &&
      appDelegate.storage.settings.user.isPlayerShuffleButtonEnabled
    isMusicQueue = true
    isPodcastQueue = false
    isShowAlbum = false
    isShowArtist = false
    isAddToPlaylist = appDelegate.storage.settings.user.isOnlineMode && !entityContainer.playables
      .isEmpty
    isDeleteOnServer = false
    isGoToSiteUrl = false
    isShowPodcastDetails = false
    isShowSongDetails = false
  }

  private func createPlayAction() -> UIAction {
    UIAction(title: "Play", image: .play) { action in
      guard !self.entityPlayables.isEmpty else { return }
      if let playerIndex = self.playerIndexCb?() {
        self.appDelegate.player.play(playerIndex: playerIndex)
      } else if let context = self.playContextCb?() {
        self.appDelegate.player.play(context: context)
      } else {
        self.appDelegate.player.play(context: PlayContext(
          containable: self.entityContainer,
          playables: self.entityPlayables
        ))
      }
    }
  }

  private func createPlayShuffledAction() -> UIAction {
    UIAction(title: "Shuffle", image: .shuffle) { action in
      guard !self.entityPlayables.isEmpty else { return }
      if let context = self.playContextCb?() {
        self.appDelegate.player.playShuffled(context: context)
      } else {
        self.appDelegate.player.playShuffled(context: PlayContext(
          containable: self.entityContainer,
          playables: self.entityPlayables
        ))
      }
    }
  }

  // cassette: "Start Mixtape from this track" — the live replacement for
  // the retired Instant Mix (removed with its similar-songs call, BUG-891),
  // backed by the cloud mixtape engine (POST /api/mixtape/radio) instead of
  // Subsonic similar-songs, and opens the preview sheet rather than playing immediately —
  // generating a mixtape must never yank audio out from under whatever's
  // already playing.
  private func createMixtapeAction() -> UIAction {
    UIAction(title: "Start Mixtape", image: CassetteIcon.sparkles.uiImage) { [weak self] _ in
      guard let self,
            let song = (entityContainer as? AbstractPlayable)?.asSong
      else { return }
      Task { @MainActor in
        await self.createAndPresentMixtape(from: song)
      }
    }
  }

  /// Share Song…, greyed out with the reason when the song has no video to send. When that isn't
  /// known yet it is asked as the menu opens (ShareSongAvailability), the way Apple's menus load an item.
  private func createShareSongElement(songId: String) -> UIMenuElement {
    if let known = ShareSongAvailability.shared.known(songId) {
      return createShareSongAction(shareable: known)
    }
    return UIDeferredMenuElement.uncached { [weak self] completion in
      Task { @MainActor in
        guard let self, let song = (self.entityContainer as? AbstractPlayable)?.asSong else {
          completion([])
          return
        }
        let answer = await ShareSongAvailability.shared.check(song)
        completion([self.createShareSongAction(shareable: answer ?? true)])
      }
    }
  }

  private func createShareSongAction(shareable: Bool) -> UIAction {
    UIAction(
      title: "Share Song…",
      subtitle: shareable ? nil : "No video to share yet",
      image: UIImage(systemName: "square.and.arrow.up"),
      attributes: shareable ? [] : .disabled
    ) { [weak self] _ in
      guard let self,
            let song = (entityContainer as? AbstractPlayable)?.asSong
      else { return }
      rootView.presentShareSong(song)
    }
  }

  private func createAndPresentMixtape(from song: Song) async {
    do {
      let mixtape = try await CassetteSyncAPI.shared.startMixtapeRadio(
        cassetteLocalId: CassetteCloudPlaylistBridge.cassetteLocalId(for: song),
        mbid: song.musicBrainzId,
        subsonicTrackId: song.id
      )
      rootView.presentMixtapePreview(mixtape)
    } catch {
      appDelegate.eventLogger.report(topic: "Mixtape", error: error)
    }
  }

  /// The two queue verbs, in the words the made-for-you page and the Mac's menus use (the founder,
  /// 2026-10-29): Play Next (the front of Up Next) and Add to Queue (its end). Amperfy's four context and
  /// user queue items ("Insert Context Queue" and the rest, under "Music Queue") fold into these two.
  private func createMusicQueueAction() -> UIMenuElement {
    UIMenu(options: .displayInline, children: [
      UIAction(title: "Play Next", image: .userQueueInsert) { action in
        guard !self.entityPlayables.isEmpty else { return }
        self.appDelegate.player.insertUserQueue(playables: self.entityPlayables)
      },
      UIAction(title: "Add to Queue", image: .userQueueAppend) { action in
        guard !self.entityPlayables.isEmpty else { return }
        self.appDelegate.player.appendUserQueue(playables: self.entityPlayables)
      },
    ])
  }

  private func createPodcastQueueAction() -> UIMenuElement {
    UIMenu(image: .listBullet, options: .displayInline, children: [
      UIAction(title: "Insert Podcast Queue", image: .podcastQueueInsert) { action in
        guard !self.entityPlayables.isEmpty else { return }
        self.appDelegate.player.insertPodcastQueue(playables: self.entityPlayables)
      },
      UIAction(title: "Append Podcast Queue", image: .podcastQueueAppend) { action in
        guard !self.entityPlayables.isEmpty else { return }
        self.appDelegate.player.appendPodcastQueue(playables: self.entityPlayables)
      },
    ])
  }

  private func createRatingMenu(libraryEntity: AbstractLibraryEntity) -> UIMenu {
    let rating = libraryEntity
      .rating == 0 ? "Not rated" :
      "\(libraryEntity.rating) Star\(libraryEntity.rating > 1 ? "s" : "")"
    let menuIcon = libraryEntity
      .rating == 0 ? UIImage.starEmpty : UIImage.starFill
    let children = [
      UIAction(title: "No Rating", image: .ban) { action in self.setRating(rating: 0) },
      UIAction(
        title: "1 Star",
        image: libraryEntity.rating >= 1 ? .starFill : .starEmpty
      ) { action in
        self.setRating(rating: 1)
      },
      UIAction(
        title: "2 Stars",
        image: libraryEntity.rating >= 2 ? .starFill : .starEmpty
      ) { action in self
        .setRating(rating: 2)
      },
      UIAction(
        title: "3 Stars",
        image: libraryEntity.rating >= 3 ? .starFill : .starEmpty
      ) { action in self
        .setRating(rating: 3)
      },
      UIAction(
        title: "4 Stars",
        image: libraryEntity.rating >= 4 ? .starFill : .starEmpty
      ) { action in self
        .setRating(rating: 4)
      },
      UIAction(
        title: "5 Stars",
        image: libraryEntity.rating >= 5 ? .starFill : .starEmpty
      ) { action in self
        .setRating(rating: 5)
      },
    ]

    return UIMenu(
      title: "Rating: \(rating)",
      image: menuIcon,
      options: .displayAsPalette,
      children: children
    )
  }

  private func setRating(rating: Int) {
    guard appDelegate.storage.settings.user.isOnlineMode,
          let account = entityContainer.account else { return }
    if let song = (entityContainer as? AbstractPlayable)?.asSong {
      song.rating = rating
      appDelegate.storage.main.saveContext()
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(account.info).librarySyncer.setRating(
          song: song,
          rating: rating
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Song Rating Sync", error: error)
      }}
    } else if let album = entityContainer as? Album {
      album.rating = rating
      appDelegate.storage.main.saveContext()
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(account.info).librarySyncer.setRating(
          album: album,
          rating: rating
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Album Rating Sync", error: error)
      }}
    } else if let artist = entityContainer as? Artist {
      artist.rating = rating
      appDelegate.storage.main.saveContext()
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(account.info).librarySyncer.setRating(
          artist: artist,
          rating: rating
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Artist Rating Sync", error: error)
      }}
    }
  }

  private func createAddToPlaylistAction() -> UIAction {
    UIAction(title: "Add to Playlist", image: .playlistPlus) { action in
      guard !self.entityPlayables.isEmpty,
            let account = self.entityContainer.account else { return }
      let selectPlaylistVC = AppStoryboard.Main
        .segueToPlaylistSelector(account: account, itemsToAdd: self.entityPlayables.filterSongs())
      let selectPlaylistNav = UINavigationController(rootViewController: selectPlaylistVC)
      self.rootView.present(selectPlaylistNav, animated: true)
    }
  }

  private func createShowAlbumAction() -> UIAction {
    UIAction(title: "Go to Album", image: .album) { action in
      self.showAlbum()
    }
  }

  private func showAlbum() {
    let playable = entityContainer as? AbstractPlayable
    let album = playable?.asSong?.album
    guard let album = album, let account = album.account else { return }
    appDelegate.userStatistics.usedAction(.alertGoToAlbum)
    let albumDetailVC = AppStoryboard.Main.segueToAlbumDetail(
      account: account,
      album: album,
      songToScrollTo: playable?.asSong
    )
    if let popupPlayer = rootView as? PopupPlayerVC {
      popupPlayer.closePopupPlayerAndDisplayInLibraryTab(vc: albumDetailVC)
    } else if let navController = rootView.navigationController {
      navController.pushViewController(albumDetailVC, animated: true)
    } else {
      guard let hostingSplitVC = AppDelegate.mainWindowHostVC else { return }
      hostingSplitVC.pushNavLibrary(vc: albumDetailVC)
    }
  }

  private func createShowArtistAction() -> UIAction {
    let title = ((entityContainer as? AbstractPlayable)?.isPodcastEpisode ?? false) ?
      "Go to Podcast" : "Go to Artist"
    let image = ((entityContainer as? AbstractPlayable)?.isPodcastEpisode ?? false) ? UIImage
      .squareArrow : UIImage.artist
    return UIAction(title: title, image: image) { action in
      self.showArtist()
    }
  }

  private func showArtist() {
    let playable = entityContainer as? AbstractPlayable
    let album = entityContainer as? Album
    if let artist = playable?.asSong?.artist ?? album?.artist, let account = artist.account {
      appDelegate.userStatistics.usedAction(.alertGoToArtist)
      let artistDetailVC = AppStoryboard.Main.segueToArtistDetail(
        account: account,
        artist: artist,
        albumToScrollTo: album
      )
      if let popupPlayer = rootView as? PopupPlayerVC {
        popupPlayer.closePopupPlayerAndDisplayInLibraryTab(vc: artistDetailVC)
      } else if let navController = rootView.navigationController {
        navController.pushViewController(artistDetailVC, animated: true)
      } else {
        guard let hostingSplitVC = AppDelegate.mainWindowHostVC else { return }
        hostingSplitVC.pushNavLibrary(vc: artistDetailVC)
      }
    } else if let podcast = playable?.asPodcastEpisode?.podcast, let account = podcast.account {
      appDelegate.userStatistics.usedAction(.alertGoToPodcast)
      let podcastDetailVC = AppStoryboard.Main.segueToPodcastDetail(
        account: account,
        podcast: podcast,
        episodeToScrollTo: playable?.asPodcastEpisode
      )
      if let popupPlayer = rootView as? PopupPlayerVC {
        popupPlayer.closePopupPlayerAndDisplayInLibraryTab(vc: podcastDetailVC)
      } else if let navController = rootView.navigationController {
        navController.pushViewController(podcastDetailVC, animated: true)
      } else {
        guard let hostingSplitVC = AppDelegate.mainWindowHostVC else { return }
        hostingSplitVC.pushNavLibrary(vc: podcastDetailVC)
      }
    }
  }

  private func createDownloadAction() -> UIAction {
    UIAction(title: "Download", image: .download) { action in
      if !self.entityPlayables.isEmpty,
         let accountInfo = self.entityPlayables.first?.account?.info {
        self.appDelegate.getMeta(accountInfo).playableDownloadManager
          .download(objects: self.entityPlayables)
      }
    }
  }

  private func createDeleteCacheAction() -> UIAction {
    UIAction(title: "Delete Cache", image: .trash) { action in
      guard self.entityPlayables.hasCachedItems,
            let account = self.entityContainer.account else { return }

      let alert = UIAlertController(
        title: nil,
        message: "Are you sure to delete the cached file\(self.entityPlayables.count > 1 ? "s" : "")?",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { _ in
        self.appDelegate.getMeta(account.info).playableDownloadManager
          .removeFinishedDownload(for: self.entityPlayables)
        self.appDelegate.storage.main.library.deleteCache(of: self.entityPlayables)
        self.appDelegate.storage.main.saveContext()
        self.reloadRootView()
      }))
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
        // do nothing
      }))
      self.rootView.present(alert, animated: true, completion: nil)
    }
  }

  private func createRemoveFromPhoneAction(album: Album) -> UIAction {
    UIAction(title: "Remove from This Phone", image: .trash, attributes: .destructive) { _ in
      let alert = UIAlertController(
        title: "Remove \u{201C}\(album.name)\u{201D} from this phone?",
        message: "It stays on your computer.",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in
        PhoneRemoval.remove(
          songIds: Set(album.playables.map(\.id)),
          context: self.appDelegate.storage.main.context
        )
        if self.rootView is AlbumDetailVC {
          self.rootView.navigationController?.popViewController(animated: true)
        } else {
          self.reloadRootView()
        }
      })
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      self.rootView.present(alert, animated: true)
    }
  }

  private func createDeleteOnServerAction() -> UIAction {
    UIAction(title: "Delete on Server", image: .cloudX) { action in
      guard let playable = self.entityContainer as? AbstractPlayable,
            let podcastEpisode = playable.asPodcastEpisode,
            let account = podcastEpisode.account
      else { return }

      let alert = UIAlertController(
        title: nil,
        message: "Are you sure to delete the podcast episode on the server?",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { _ in
        Task { @MainActor in do {
          try await self.appDelegate.getMeta(account.info).librarySyncer
            .requestPodcastEpisodeDelete(podcastEpisode: podcastEpisode)
          guard let podcast = podcastEpisode.podcast else { return }
          try await self.appDelegate.getMeta(account.info).librarySyncer
            .sync(podcast: podcast)
        } catch {
          self.appDelegate.eventLogger.report(topic: "Podcast Episode Delete Sync", error: error)
        }}
      }))
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
        // do nothing
      }))
      self.rootView.present(alert, animated: true, completion: nil)
    }
  }

  /// cassette 2026-10-21 (founder: "Go to site" said nothing): names the place it goes,
  /// "Go to kexp.org", "Go to somafm.com".
  private func createGoToSiteUrl(url: URL) -> UIAction {
    let host = url.host()?.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
    let title = host.map { $0.isEmpty ? "Go to Website" : "Go to \($0)" } ?? "Go to Website"
    return UIAction(title: title, image: .followLink) { action in
      UIApplication.shared.open(url)
    }
  }

  private func createShowPodcastDetailsAction(podcast: Podcast) -> UIAction {
    UIAction(title: "Show Podcast Description", image: .info) { action in
      self.showPodcastDetails()
    }
  }

  private func createShowEpisodeDetailsAction(podcastEpisode: PodcastEpisode) -> UIAction {
    UIAction(title: "Show Episode Description", image: .info) { action in
      self.showPodcastDetails()
    }
  }

  private func showPodcastDetails() {
    var descriptionVC: PlainDetailsVC?
    if let playable = entityContainer as? AbstractPlayable,
       let podcastEpisode = playable.asPodcastEpisode {
      descriptionVC = PlainDetailsVC()
      descriptionVC?.display(podcastEpisode: podcastEpisode, on: rootView)
    } else if let podcast = entityContainer as? Podcast {
      descriptionVC = PlainDetailsVC()
      descriptionVC?.display(podcast: podcast, on: rootView)
    }

    if let descriptionVC = descriptionVC {
      rootView.present(descriptionVC, animated: true)
    }
  }

  private func createShowLyricsAction(song: Song) -> UIAction? {
    // cassette (UX review 2026-10-20): lyrics live in the overflow menu, and only when
    // the hub sent a lyrics file for this song. The in-player lyrics toggle stays behind
    // Cassette.lyricsEnabled.
    guard let playable = entityContainer as? AbstractPlayable,
          let song = playable.asSong,
          let lyricsRelFilePath = song.lyricsRelFilePath,
          let lyricsAccount = song.account
    else { return nil }

    return UIAction(title: "Lyrics", image: .lyrics) { action in
      self.showLyrics(lyricsRelFilePath: lyricsRelFilePath, lyricsAccount: lyricsAccount)
    }
  }

  private func showLyrics(lyricsRelFilePath: URL, lyricsAccount: Account) {
    let lyricsVC = PlainDetailsVC()
    lyricsVC.display(
      lyricsRelFilePath: lyricsRelFilePath,
      lyricsAccount: lyricsAccount,
      on: rootView
    )
    rootView.present(lyricsVC, animated: true)
  }

  private func createCopyIdToClipboardAction() -> UIMenu {
    UIMenu(
      options: .displayInline,
      children: [UIAction(title: "Copy ID to Clipboard", image: .clipboard) { action in
        if !self.entityContainer.id.isEmpty {
          UIPasteboard.general.string = self.entityContainer.id
        }
      }]
    )
  }

  private func reloadRootView() {
    if let rootTableView = rootView as? UITableViewController {
      rootTableView.tableView.reloadData()
    } else if let popupPlayer = rootView as? PopupPlayerVC {
      popupPlayer.tableView.reloadData()
    }
    if let splitVC = rootView as? SplitVC,
       let queueVC = splitVC.viewController(for: .inspector) as? QueueVC {
      queueVC.tableView?.reloadData()
    }
  }
}

// MARK: - EntityPreviewVC

class EntityPreviewVC: UIViewController {
  override var sceneTitle: String? { entityContainer?.name }

  static let margin = UIEdgeInsets(
    top: UIView.defaultMarginX,
    left: UIView.defaultMarginX,
    bottom: UIView.defaultMarginX,
    right: UIView.defaultMarginX
  )

  @IBOutlet
  weak var titleLabel: MarqueeLabel!
  @IBOutlet
  weak var artistLabel: MarqueeLabel!
  @IBOutlet
  weak var infoLabel: MarqueeLabel!
  @IBOutlet
  weak var entityImageView: EntityImageView!
  @IBOutlet
  weak var gotoDetailsSymbol: UIImageView!

  private var rootView: UIViewController?
  private var entityContainer: PlayableContainable?

  var isNavigationDisallowed: Bool {
    ((entityContainer as? AbstractPlayable)?.isSong ?? false) && (rootView is AlbumDetailVC) ||
      ((entityContainer as? AbstractPlayable)?.isPodcastEpisode ?? false) &&
      (rootView is PodcastDetailVC)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // cassette: the context-menu preview card was the XIB's system 19/17/16 on
    // a system material. Same deck as a row: bg2 card, display-face title,
    // mono artist, quiet caption, ink2 chevron.
    view.backgroundColor = UIColor.cassette(.surfaceRaised)
    titleLabel.applyAmperfyStyle()
    artistLabel.applyAmperfyStyle()
    infoLabel.applyAmperfyStyle()
    applyCassetteType()
    gotoDetailsSymbol.isHidden = isNavigationDisallowed
    gotoDetailsSymbol.tintColor = UIColor.cassette(.textSecondary)

    // The preview will size to the preferredContentSize, which can be useful
    // for displaying a preview with the dimension of an image, for example.
    // Unlike peek and pop, it doesn't seem to automatically scale down for you.

    if traitCollection.userInterfaceIdiom == .phone {
      preferredContentSize = CGSize(
        width: view.bounds.width,
        height: 150 + Self.margin.top + Self.margin.bottom
      )
    } else if traitCollection.userInterfaceIdiom == .pad {
      preferredContentSize = CGSize(
        width: view.bounds.width,
        height: 190 + Self.margin.top + Self.margin.bottom
      )
    } else {
      preferredContentSize = CGSize(
        width: view.bounds.width,
        height: 190 + Self.margin.top + Self.margin.bottom
      )
    }
  }

  override func viewIsAppearing(_ animated: Bool) {
    refresh()
  }

  private func applyCassetteType() {
    titleLabel.font = UIFont.cassette(.rowTitle)
    titleLabel.textColor = UIColor.cassette(.textPrimary)
    artistLabel.font = UIFont.cassette(.cardSubtitle)
    artistLabel.textColor = UIColor.cassette(.textSecondary)
    infoLabel.font = UIFont.cassette(.caption)
    infoLabel.textColor = UIColor.cassette(.textTertiary)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    applyCassetteType()
  }

  func display(container: PlayableContainable, on rootView: UIViewController) {
    self.rootView = rootView
    entityContainer = container
  }

  func refresh() {
    guard let entityContainer = entityContainer else { return }
    entityImageView.display(
      theme: appDelegate.storage.settings.accounts.getSetting(entityContainer.account?.info).read
        .themePreference,
      container: entityContainer
    )
    titleLabel.text = entityContainer.name
    artistLabel.text = entityContainer.subtitle
    artistLabel.isHidden = entityContainer.subtitle == nil
    if let playable = entityContainer as? AbstractPlayable {
      // cassette: a song's preview line is year and length. The upstream `.long`
      // detail appended "Bitrate 320000", which is plumbing, not information.
      var parts = [String]()
      if playable.year > 0 { parts.append(String(playable.year)) }
      if playable.duration > 0 { parts.append(playable.duration.asDurationString) }
      infoLabel.text = parts.joined(separator: " · ")
    } else {
      infoLabel.text = entityContainer.info(
        for: entityContainer.account?.apiType.asServerApiType,
        details: DetailInfoType(type: .long, settings: appDelegate.storage.settings)
      )
    }
  }
}
