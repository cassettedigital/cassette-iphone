//
//  PopupPlayerVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
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

import AmperfyKit
import CoreMedia
import SwiftUI
import UIKit

// MARK: - PopupPlayerVC

class PopupPlayerVC: UIViewController, UIScrollViewDelegate {
  @IBOutlet
  weak var tableView: UITableView!
  @IBOutlet
  weak var largePlayerPlaceholderView: UIView!
  @IBOutlet
  weak var controlPlaceholderView: UIView!
  @IBOutlet
  weak var backgroundImage: UIImageView!
  @IBOutlet
  weak var closeButtonPlaceholderView: UIView!

  @IBOutlet
  weak var controlPlaceholderHeightConstraint: NSLayoutConstraint!
  private let safetyMarginOnBottom = 20.0

  lazy var tableViewKeyCommandsController = TableViewKeyCommandsController(
    tableView: tableView,
    overrideFirstLastIndexPath: IndexPath(
      row: 0,
      section: PlayerSectionCategory.currentlyPlaying.rawValue
    )
  )

  var player: PlayerFacade!
  var playerHandler: PlayerUIHandler?
  var controlView: PlayerControlView?
  var largeCurrentlyPlayingView: LargeCurrentlyPlayingPlayerView?
  var accountNotificationHandler: AccountNotificationHandler?

  // Patch 112: ambient backlight — a soft blurred copy of the current cover,
  // hosted (SwiftUI) in the backmost backdrop slot. Driven via the model.
  let ambientBackdropModel = AmbientBackdropModel()
  private var ambientBackdropHost: UIHostingController<AmbientCoverBackdrop>?

  /// phone-taste: the record's colour, read once per cover from the same thumbnail the
  /// glow decodes (refreshBackgroundItemArtwork). A plain stored value, deliberately not on
  /// AmbientBackdropModel: a new tint must not re-render the glow or the EQ panel that
  /// observe that model. `.neutral` until a cover is read, and for a track without one.
  var coverTint: CoverTint = .neutral
  /// The look the sheet is showing (cover or Up Next), so a station can hold it on the cover.
  var shownDisplayStyle: PlayerDisplayStyle? {
    // Up Next's rows run to the top of the sheet: the glass thickens there while it shows
    didSet { ambientBackdropModel.isListShown = shownDisplayStyle == .compact }
  }

  /// What the sheet shows: the person's choice, except that a station has no Up Next to show
  /// (the founder, 2026-10-31: no queue when we can't see what's coming), so it shows the cover
  /// without changing the choice.
  var effectiveDisplayStyle: PlayerDisplayStyle {
    player.currentlyPlaying?.isRadio == true ? .large : appDelegate.storage.settings.user.playerDisplayStyle
  }

  var currentlyPlayingTableCell: CurrentlyPlayingTableCell?
  var contextPrevQueueSectionHeader: ContextQueuePrevSectionHeader?
  var userQueueSectionHeader: UserQueueSectionHeader?
  var contextNextQueueSectionHeader: ContextQueueNextSectionHeader?
  var activeDisplayedSectionHeader = Set<PlayerSectionCategory>()
  /// cassette (keep playing): what plays when the queue runs out, shown under THEN.
  /// Worked out on every reload; nil when keep playing is off, waiting on repeat, or has
  /// nothing that fits.
  var keepPlayingPick: KeepPlaying.Pick?
  lazy var clearEmptySectionFooter = {
    let view = UIView()
    view.backgroundColor = .clear
    view.isHidden = true
    return view
  }()

  override func viewDidLoad() {
    super.viewDidLoad()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keepPlayingChanged),
      name: KeepPlaying.didChange,
      object: nil
    )

    // cassette Patch 015e: warm-deep backing under the now-playing artwork.
    view.backgroundColor = UIColor.cassette(.surfaceSunken)
    tableView.backgroundColor = UIColor.cassette(.surfaceBase)
    tableView.delegate = self
    tableView.dataSource = self
    tableView.dragDelegate = self
    tableView.dropDelegate = self
    tableView.dragInteractionEnabled = true

    player = appDelegate.player
    player.addNotifier(notifier: self)
    playerHandler = PlayerUIHandler(player: player, style: .popupPlayer)

    // cassette Patch 029: the popup-player background is the flat bg4
    // colour set above. Patches 022/024 layered album art + blur +
    // gradient over it; the audit traced the persistent blue tint to
    // that stack and prescribed stripping it entirely. The XIB still
    // keeps `backgroundImage` so we can revisit a controlled artistic
    // backdrop later, but for now it sits empty.
    backgroundImage.image = nil
    backgroundImage.isHidden = true

    // Patch 112: install the ambient backlight in the backmost backdrop slot
    // (just above the now-empty `backgroundImage`, below all content). It is
    // non-interactive and full-bleed; the crisp cover + controls sit on top.
    let backdrop = UIHostingController(rootView: AmbientCoverBackdrop(model: ambientBackdropModel))
    backdrop.view.backgroundColor = .clear
    backdrop.view.isUserInteractionEnabled = false
    backdrop.view.translatesAutoresizingMaskIntoConstraints = false
    addChild(backdrop)
    view.insertSubview(backdrop.view, aboveSubview: backgroundImage)
    NSLayoutConstraint.activate([
      backdrop.view.topAnchor.constraint(equalTo: view.topAnchor),
      backdrop.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      backdrop.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      backdrop.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    backdrop.didMove(toParent: self)
    ambientBackdropHost = backdrop

    controlPlaceholderHeightConstraint.constant = PlayerControlView
      .frameHeight + safetyMarginOnBottom
    if let createdPlayerControlView = ViewCreator<PlayerControlView>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: controlPlaceholderView.bounds.size.width,
        height: controlPlaceholderView.bounds.size.height
      )) {
      controlView = createdPlayerControlView
      createdPlayerControlView.prepare(toWorkOnRootView: self)
      controlPlaceholderView.addSubview(createdPlayerControlView)
    }
    if let createdLargeCurrentlyPlayingView = ViewCreator<LargeCurrentlyPlayingPlayerView>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: largePlayerPlaceholderView.bounds.size.width,
        height: largePlayerPlaceholderView.bounds.size.height
      )) {
      largeCurrentlyPlayingView = createdLargeCurrentlyPlayingView
      createdLargeCurrentlyPlayingView.prepare(toWorkOnRootView: self)
      largePlayerPlaceholderView.addSubview(createdLargeCurrentlyPlayingView)
    }

    closeButtonPlaceholderView.isHidden = true

    setupTableView()
    fetchSongInfoAndUpdateViews()

    if let sectionView = ViewCreator<ContextQueuePrevSectionHeader>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: view.bounds.size.width,
        height: ContextQueuePrevSectionHeader.frameHeight
      )) {
      contextPrevQueueSectionHeader = sectionView
      contextPrevQueueSectionHeader?.display(name: "Previous")
    }
    if let sectionView = ViewCreator<UserQueueSectionHeader>.createFromNib(withinFixedFrame: CGRect(
      x: 0,
      y: 0,
      width: view.bounds.size.width,
      height: UserQueueSectionHeader.frameHeight
    )) {
      userQueueSectionHeader = sectionView
      userQueueSectionHeader?.display(name: "Next from Queue", buttonPressAction: clearUserQueue)
    }
    if let sectionView = ViewCreator<ContextQueueNextSectionHeader>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: view.bounds.size.width,
        height: ContextQueueNextSectionHeader.frameHeight
      )) {
      contextNextQueueSectionHeader = sectionView
      contextNextQueueSectionHeader?.prepare(toWorkOnRootView: self)
    }

    accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).artworkDownloadManager
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).playableDownloadManager
      )
    }

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.refresh()
      }
    )
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    refreshCellMasks()
    controlView?.refreshView()
    applyGradientBackground()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    appDelegate.userStatistics.visited(.popupPlayer)
    becomeFirstResponder()
    changeDisplayStyleVisually(to: effectiveDisplayStyle, animated: false)
    shownDisplayStyle = effectiveDisplayStyle
    reloadData()
    scrollToCurrentlyPlayingRow()
    controlView?.refreshView()
    refresh()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    resignFirstResponder()
  }

  override func viewWillLayoutSubviews() {
    adjustLayoutMargins()
  }

  func fetchSongInfoAndUpdateViews() {
    guard appDelegate.storage.settings.user.isOnlineMode,
          let song = player.currentlyPlaying?.asSong,
          let account = song.account
    else { return }

    Task { @MainActor in do {
      try await self.appDelegate.getMeta(account.info).librarySyncer.sync(song: song)
      self.refreshCurrentlyPlayingInfoView()
    } catch {
      self.appDelegate.eventLogger.report(topic: "Song Info", error: error)
    }}
  }

  func reloadData() {
    refreshKeepPlayingPick()
    tableView.reloadData()
    scrollToCurrentlyPlayingRow()
  }

  /// cassette (keep playing): music only, never under a station, never with repeat on.
  func refreshKeepPlayingPick() {
    guard player.playerMode == .music,
          KeepPlaying.shared.isActive(repeatMode: player.repeatMode),
          player.currentlyPlaying?.isRadio != true
    else {
      keepPlayingPick = nil
      return
    }
    keepPlayingPick = KeepPlaying.shared.upcoming(queue: player.keepPlayingQueue)
  }

  /// The pick changed (swapped, trimmed, switched, or the mood index landed): redraw THEN
  /// only, so the list does not jump back to the song on now.
  @objc
  func keepPlayingChanged() {
    guard isViewLoaded else { return }
    refreshKeepPlayingPick()
    tableView.reloadSections(IndexSet(integer: Self.keepPlayingSection), with: .fade)
  }

  func scrollToCurrentlyPlayingRow() {
    tableView.scrollToRow(
      at: IndexPath(row: 0, section: PlayerSectionCategory.currentlyPlaying.rawValue),
      at: .top,
      animated: false
    )
  }

  func displayArtistDetail() {
    if let song = player.currentlyPlaying?.asSong, let artist = song.artist,
       let account = artist.account {
      let artistDetailVC = AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist)
      closePopupPlayerAndDisplayInLibraryTab(vc: artistDetailVC)
    }
  }

  func displayAlbumDetail() {
    if let song = player.currentlyPlaying?.asSong, let album = song.album,
       let account = album.account {
      let albumDetailVC = AppStoryboard.Main.segueToAlbumDetail(
        account: account,
        album: album,
        songToScrollTo: song
      )
      closePopupPlayerAndDisplayInLibraryTab(vc: albumDetailVC)
    }
  }

  func displayPodcastDetail() {
    if let podcastEpisode = player.currentlyPlaying?.asPodcastEpisode,
       let podcast = podcastEpisode.podcast,
       let account = podcastEpisode.account {
      let podcastDetailVC = AppStoryboard.Main.segueToPodcastDetail(
        account: account,
        podcast: podcast,
        episodeToScrollTo: podcastEpisode
      )
      closePopupPlayerAndDisplayInLibraryTab(vc: podcastDetailVC)
    }
  }

  func closePopupPlayer() {
    guard let hostingSplitVC = AppDelegate.mainWindowHostVC else { return }
    hostingSplitVC.visualizePopupPlayer(direction: .close, animated: true)
  }

  /// The record the station's song matched on Cassette, if any: Now Playing's album key and
  /// its ⋯ menu's Go to Album both read it.
  var radioAlbumSlug: String? {
    guard player.currentlyPlaying?.isRadio == true else { return nil }
    return player.currentRadioLive?.albumSlug
  }

  /// Go to the record the station is playing, without leaving the app: the person's own copy
  /// when they have it, else its page, in the Library tab with the station still playing.
  func openRadioAlbum() {
    guard let slug = radioAlbumSlug,
          let account = player.currentlyPlaying?.account else { return }
    let live = player.currentRadioLive
    RecordOpener.open(
      albumSlug: slug,
      title: live?.albumTitle,
      placeholder: player.currentRadioArtwork,
      account: account
    ) { [weak self] vc in
      self?.closePopupPlayerAndDisplayInLibraryTab(vc: vc)
    }
  }

  /// The playing station's page (what it just played, what's next, similar stations, Save).
  func openStationPage() {
    guard let radio = player.currentlyPlaying?.asRadio,
          let account = radio.account,
          let info = RadioCatalog.shared.station(forStreamUrl: radio.url) else { return }
    closePopupPlayerAndDisplayInLibraryTab(vc: RadioStationVC(account: account, station: info))
  }

  func closePopupPlayerAndDisplayInLibraryTab(vc: UIViewController) {
    guard let hostingSplitVC = AppDelegate.mainWindowHostVC else { return }
    hostingSplitVC.visualizePopupPlayer(direction: .close, animated: true, completion: { () in
      hostingSplitVC.pushNavLibrary(vc: vc)
    })
  }

  func refreshUserQueueSectionHeader() {
    guard let userQueueSectionView = userQueueSectionHeader else { return }
    if player.userQueueCount == 0 {
      userQueueSectionView.hide()
    } else {
      userQueueSectionView.display(
        name: PlayerQueueType.user.description,
        buttonPressAction: clearUserQueue
      )
    }
  }

  func refreshContextQueueSectionHeader() {
    guard let contextNextQueueSectionHeader = contextNextQueueSectionHeader else { return }
    contextNextQueueSectionHeader.refresh()
  }

  /// phone-taste: keep a newly read record colour and hand it on. An unchanged colour stops
  /// here, so a refresh for the same cover touches no label.
  func updateCoverTint(_ tint: CoverTint) {
    CoverTint.nowPlaying = tint
    guard tint != coverTint else { return }
    coverTint = tint
    applyCoverTint()
  }

  /// phone-taste: push the record's colour to every label that speaks in it: the artist
  /// line on Now Playing, the queue's now row and the queue head. Each of them also reads
  /// `coverTint` itself when it is built or its traits change, because the now row is only
  /// made on the first visit to the queue.
  func applyCoverTint() {
    ambientBackdropModel.room = Color(uiColor: coverTint.room)
    controlView?.applyNowPlayingTint()
    largeCurrentlyPlayingView?.applyCoverTint(coverTint)
    currentlyPlayingTableCell?.applyCoverTint(coverTint)
    contextNextQueueSectionHeader?.applyCoverTint(coverTint)
  }

  // MARK: - UIScrollViewDelegate

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    refreshCellMasks()
  }

  func refreshCellMasks() {
    guard let topSection = Array(activeDisplayedSectionHeader)
      .sorted(by: { $0.rawValue < $1.rawValue }).first
    else { return }

    let topSectionHeight = tableView(tableView, heightForHeaderInSection: topSection.rawValue)
    let scrollOffset = tableView.contentOffset.y

    for cell in tableView.visibleCells {
      let hiddenFrameHeight = scrollOffset + topSectionHeight - cell.frame.origin.y
      if hiddenFrameHeight >= 0 || hiddenFrameHeight <= cell.frame.size.height {
        if let customCell = cell as? PlayableTableCell {
          customCell.maskCell(fromTop: hiddenFrameHeight)
        }
      }
    }
  }

  func refreshCellsContent() {
    for cell in tableView.visibleCells {
      guard let playableCell = cell as? PlayableTableCell else { continue }
      playableCell.refresh()
    }
  }
}

// MARK: MusicPlayable

extension PopupPlayerVC: MusicPlayable {
  func didStartPlayingFromBeginning() {
    fetchSongInfoAndUpdateViews()
    largeCurrentlyPlayingView?.initializeLyrics()
  }

  func didStartPlaying() {
    reloadData()
    refresh()
  }

  func didStopPlaying() {
    reloadData()
    refresh()
  }

  func didPlaylistChange() {
    reloadData()
    refresh()
  }

  func didPause() {
    // Patch 112: settle the ambient backlight intensity when paused.
    ambientBackdropModel.isPlaying = player.isPlaying
  }

  func didElapsedTimeChange() {}

  func didLyricsTimeChange(time: CMTime) {
    largeCurrentlyPlayingView?.refreshLyricsTime(time: time)
  }

  func didArtworkChange() {
    refreshCurrentlyPlayingArtworks()
  }

  func didNowPlayingInfoChange() {
    refreshCurrentlyPlayingInfoView()
    // a new song on a station may or may not have matched a record: the album key follows it
    controlView?.refreshView()
  }

  func didShuffleChange() {}
  func didRepeatChange() {
    keepPlayingChanged()
  }

  func didPlaybackRateChange() {}
}
