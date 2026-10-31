//
//  LargeCurrentlyPlayingPlayerView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 07.02.24.
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
import MarqueeLabel
import MediaPlayer
import UIKit

import SwiftUI

// MARK: - LargeDisplayElement

enum LargeDisplayElement {
  case artwork
  case lyrics
  case visualizer
}

// MARK: - AudioAnalyzerView

struct AudioAnalyzerView: View {
  @EnvironmentObject
  var audioAnalyzer: AudioAnalyzer
  let visualizerType: VisualizerType

  var body: some View {
    Group {
      switch visualizerType {
      case .waveform:
        WaveformView(
          magnitudes: audioAnalyzer.magnitudes,
          rms: audioAnalyzer.rms
        )
      case .spectrumBars:
        SpectrumBarsView(
          magnitudes: audioAnalyzer.magnitudes,
          barCount: 32
        )
      case .generativeArt:
        GenerativeArtView(
          magnitudes: audioAnalyzer.magnitudes,
          rms: audioAnalyzer.rms
        )
      case .ring:
        AmplitudeSpectrumView(
          shapeType: .ring,
          magnitudes: audioAnalyzer.magnitudes,
          range: 0 ..< 75,
          rms: audioAnalyzer.rms
        )
      }
    }
    .padding()
  }
}

// MARK: - AudioAnalyzerWrapperView

struct AudioAnalyzerWrapperView: View {
  let visualizerType: VisualizerType

  var body: some View {
    VStack {
      AudioAnalyzerView(visualizerType: visualizerType)
        .environmentObject(appDelegate.player.audioAnalyzer)
    }
  }
}

// MARK: - SwiftUIContentView

class SwiftUIContentView: UIView {
  var hostingController: UIHostingController<AudioAnalyzerWrapperView>?

  public func setupSwiftUIView(
    parentVC: UIViewController,
    parentView: UIView,
    visualizerType: VisualizerType
  ) {
    let swiftUIView = AudioAnalyzerWrapperView(visualizerType: visualizerType)
    let hostingController = UIHostingController(rootView: swiftUIView)
    self.hostingController = hostingController

    parentVC.addChild(hostingController)
    parentView.addSubview(hostingController.view)

    hostingController.view.frame = parentView.frame
    hostingController.view.backgroundColor = .clear

    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    hostingController.didMove(toParent: parentVC)
  }

  public func updateVisualizerType(_ visualizerType: VisualizerType) {
    hostingController?.rootView = AudioAnalyzerWrapperView(visualizerType: visualizerType)
  }
}

// MARK: - LargeCurrentlyPlayingPlayerView

class LargeCurrentlyPlayingPlayerView: UIView, UIGestureRecognizerDelegate {
  static let rowHeight: CGFloat = 94.0
  static private let margin = UIEdgeInsets(
    top: 0,
    left: UIView.defaultMarginX,
    bottom: 20,
    right: UIView.defaultMarginX
  )

  private var rootView: PopupPlayerVC?
  private var lyricsView: LyricsView?
  private var visualizerHostingView: SwiftUIContentView?
  private var displayElement: LargeDisplayElement = .artwork
  // cassette Patch 054 (Phase I): popup rating view removed. The rating
  // data model is preserved (SongMO.rating + isShowRating user setting);
  // EntityPreviewVC retains the context-menu rating action as the
  // read/write surface.

  @IBOutlet
  weak var upperContainerView: UIView!
  @IBOutlet
  weak var artworkImage: LibraryEntityImage!
  @IBOutlet
  weak var detailsContainer: UIView!
  @IBOutlet
  weak var titleLabel: MarqueeLabel!
  @IBOutlet
  weak var albumLabel: MarqueeLabel!
  @IBOutlet
  weak var albumButton: UIButton!
  @IBOutlet
  weak var albumContainerView: UIView!
  @IBOutlet
  weak var artistLabel: MarqueeLabel!
  @IBOutlet
  weak var favoriteButton: UIButton!
  @IBOutlet
  weak var optionsButton: UIButton!

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    self.layoutMargins = Self.margin
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Force a layout to prevent wrong size on first appearance on macOS
    upperContainerView.layoutIfNeeded()

    lyricsView?.frame = upperContainerView.bounds
    visualizerHostingView?.hostingController?.view.frame = upperContainerView.bounds
  }

  func prepare(toWorkOnRootView: PopupPlayerVC?) {
    rootView = toWorkOnRootView
    // cassette: favorites removed. The artwork-row favorite button is kept in the
    // nib (its outlet + constraints anchor the options button) but permanently
    // hidden and no longer wired to any action. The per-track overflow
    // (optionsButton) stays in this row, and Share Song… lives inside it (CASSETTE_SHARING.md).
    favoriteButton.isHidden = true
    titleLabel.applyAmperfyStyle()
    albumLabel.applyAmperfyStyle()
    artistLabel.applyAmperfyStyle()
    // cassette polish: now-playing metadata is song + artist only — the album
    // line is dropped. The album container is an arranged subview of the
    // vertical metadata stack, so hiding it collapses the row with no gap.
    // refresh() also stops feeding the album outlets so nothing un-hides it.
    albumContainerView.isHidden = true
    // phone-taste (np-title-type, np-artist-voice): the song in the player's big condensed
    // capitals (Barlow ExtraBold 34; refresh() sets the capitals, so the mini player and
    // the lock screen keep mixed case), and the artist in the answer voice (New York italic
    // 23) in the record's colour. (Album style retained for completeness though the album
    // row is hidden above.)
    titleLabel.font = UIFont.cassette(.playerTitle)
    titleLabel.textColor = UIColor.cassette(.textPrimary)
    albumLabel.font = UIFont.cassette(.metadata)
    albumLabel.textColor = UIColor.cassette(.textSecondary)
    artistLabel.font = UIFont.cassette(.answerPlayer)
    applyCoverTint(rootView?.coverTint ?? .neutral)
    // phone-taste (np-cover-size): the Now Playing cover's own, rounder corner.
    artworkImage.layer.cornerRadius = CassetteRadius.playerArtwork

    lyricsView = LyricsView()
    lyricsView!.frame = upperContainerView.bounds
    lyricsView!.onLyricSelected = { [weak self] lyric in
      self?.appDelegate.player.seek(toSecond: lyric.startTime.seconds)
    }
    let lyricsTap = UITapGestureRecognizer(target: self, action: #selector(handleLyricsTap(_:)))
    lyricsTap.cancelsTouchesInView = false
    lyricsTap.delegate = self
    lyricsView!.addGestureRecognizer(lyricsTap)
    upperContainerView.addSubview(lyricsView!)

    visualizerHostingView = SwiftUIContentView()
    visualizerHostingView!.hostingController?.view.frame = upperContainerView.bounds
    if let toWorkOnRootView {
      visualizerHostingView!.setupSwiftUIView(
        parentVC: toWorkOnRootView,
        parentView: self,
        visualizerType: appDelegate.storage.settings.user.selectedVisualizerType
      )
    }

    addSwipeGesturesToArtwork()

    // cassette Patch 054 (Phase I): offline-mode observer removed; it only
    // toggled the popup rating view's interactive state, and the view
    // itself has been deleted.

    displayElement = getDisplayElementBasedOnConfig()
    refresh()
  }

  // cassette Patch 054 (Phase I): setupRatingView + the gap between artwork
  // bottom and details top now reads as breathing room rather than a
  // rating-stars hosting region.

  @objc
  private func handleLyricsTap(_ gesture: UITapGestureRecognizer) {
    // Toggle back to artwork when lyrics are tapped
    appDelegate.storage.settings.user.isPlayerLyricsDisplayed = false
    display(element: .artwork)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool {
    guard let lyricsView = lyricsView,
          gestureRecognizer is UITapGestureRecognizer
    else { return true }
    let location = touch.location(in: lyricsView)
    return lyricsView.indexPathForRow(at: location) == nil
  }

  private func addSwipeGesturesToArtwork() {
    func createLeftSwipe() -> UISwipeGestureRecognizer {
      let swipeLeft = UISwipeGestureRecognizer(
        target: self,
        action: #selector(handleSwipe(_:))
      )
      swipeLeft.direction = .left
      return swipeLeft
    }

    func createRightSwipe() -> UISwipeGestureRecognizer {
      let swipeRight = UISwipeGestureRecognizer(
        target: self,
        action: #selector(handleSwipe(_:))
      )
      swipeRight.direction = .right
      return swipeRight
    }

    artworkImage.isUserInteractionEnabled = true
    artworkImage.addGestureRecognizer(createLeftSwipe())
    artworkImage.addGestureRecognizer(createRightSwipe())
    visualizerHostingView?.hostingController?.view.isUserInteractionEnabled = true
    visualizerHostingView?.hostingController?.view.addGestureRecognizer(createRightSwipe())
    visualizerHostingView?.hostingController?.view.addGestureRecognizer(createLeftSwipe())
  }

  @objc
  private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
    switch gesture.direction {
    case .left:
      rootView?.controlView?.nextButtonPushed(self)
    case .right:
      rootView?.controlView?.previousButtonPushed(self)
    default:
      break
    }
  }

  func refreshLyricsTime(time: CMTime) {
    lyricsView?.scroll(toTime: time)
  }

  func initializeLyrics() {
    guard isLyricsViewAllowedToDisplay else {
      hideLyrics()
      return
    }

    guard let playable = rootView?.player.currentlyPlaying,
          let song = playable.asSong,
          let account = song.account,
          let lyricsRelFilePath = song.lyricsRelFilePath
    else {
      showLyricsAreNotAvailable()
      return
    }

    Task { @MainActor in do {
      let lyricsList = try await appDelegate.getMeta(account.info).librarySyncer
        .parseLyrics(relFilePath: lyricsRelFilePath)
      guard self.isLyricsViewAllowedToDisplay else {
        self.hideLyrics()
        return
      }

      if song == self.appDelegate.player.currentlyPlaying?.asSong,
         let structuredLyrics = lyricsList.getFirstSyncedLyricsOrUnsyncedAsDefault() {
        self.showLyrics(structuredLyrics: structuredLyrics)
      } else {
        self.showLyricsAreNotAvailable()
      }
    } catch {
      guard self.isLyricsViewAllowedToDisplay else {
        self.hideLyrics()
        return
      }
      self.showLyricsAreNotAvailable()
    }}
  }

  var isLyricsViewAllowedToDisplay: Bool {
    displayElement == .lyrics &&
      appDelegate.player.playerMode == .music &&
      appDelegate.storage.settings.accounts.availableApiTypes.contains(.subsonic)
  }

  var isLyricsButtonAllowedToDisplay: Bool {
    // cassette polish Part 2: lyrics scaffolding stays in code but every
    // user-facing entry point is gated behind Cassette.lyricsEnabled.
    Cassette.lyricsEnabled &&
      appDelegate.player.playerMode == .music &&
      appDelegate.storage.settings.accounts.availableApiTypes.contains(.subsonic)
  }

  public func getDisplayElementBasedOnConfig() -> LargeDisplayElement {
    // cassette: lyrics surface is hidden (Cassette.lyricsEnabled == false). Guard
    // here too so a persisted isPlayerLyricsDisplayed can't reopen the player in
    // lyrics mode while the feature is gated off. Feature stays wired in code.
    if Cassette.lyricsEnabled, appDelegate.storage.settings.user.isPlayerLyricsDisplayed {
      return .lyrics
    } else if appDelegate.storage.settings.user.isPlayerVisualizerDisplayed,
              !UIAccessibility.isReduceMotionEnabled {
      // cassette (I-M3): the moving visualizer gives way to the cover under Reduce Motion.
      return .visualizer
    } else {
      return .artwork
    }
  }

  public func display(element: LargeDisplayElement) {
    displayElement = element

    switch element {
    case .artwork:
      hideVisualizer()
      hideLyrics()
      showArtwork()
    case .lyrics:
      hideVisualizer()
      almostHideArtwork()
      initializeLyrics()
    case .visualizer:
      hideLyrics()
      almostHideArtwork()
      showVisualizer()
    }
  }

  public func almostHideArtwork() {
    artworkImage.alpha = 0.1
  }

  public func showArtwork() {
    artworkImage.alpha = 1
  }

  public func hideVisualizer() {
    visualizerHostingView?.hostingController?.view.isHidden = true
    appDelegate.player.audioAnalyzer.isActive = false
  }

  public func showVisualizer() {
    visualizerHostingView?.updateVisualizerType(
      appDelegate.storage.settings.user.selectedVisualizerType
    )
    visualizerHostingView?.hostingController?.view.isHidden = false
    appDelegate.player.audioAnalyzer
      .isActive = (appDelegate.storage.settings.user.playerDisplayStyle == .large)
  }

  private func hideLyrics() {
    lyricsView?.clear()
    lyricsView?.isHidden = true
  }

  private func showLyricsAreNotAvailable() {
    var notAvailableLyrics = StructuredLyrics()
    notAvailableLyrics.synced = false
    var line = LyricsLine()
    line.value = "No Lyrics"
    notAvailableLyrics.line.append(line)
    showLyrics(structuredLyrics: notAvailableLyrics)
    lyricsView?.highlightAllLyrics()
  }

  private func showLyrics(structuredLyrics: StructuredLyrics) {
    lyricsView?.display(
      lyrics: structuredLyrics,
      scrollAnimation: appDelegate.storage.settings.user.isLyricsSmoothScrolling
    )
    lyricsView?.isHidden = false
  }

  /// phone-taste: the artist line speaks in the record's colour (`.neutral` until one is
  /// read, never orange).
  func applyCoverTint(_ tint: CoverTint) {
    artistLabel.textColor = tint.text
  }

  /// The shared refresh writes the song title here in mixed case, and only its capitals
  /// reach the marquee. Writing both cases into the marquee would restart its scroll on
  /// every refresh, since it only skips a text it already shows.
  private lazy var mixedCaseTitle = UILabel()

  // MARK: Station line

  /// cassette 2026-10-21 (founder: "it's not uncommon for me to forget I'm on a radio
  /// station"): on the radio, a small line over the song names the station, its mark and
  /// its name in the kicker voice, so Next to another station never leaves you guessing.
  /// It floats in the room under the artwork, pinned just above the title stack rather
  /// than inside it, so the song and artist stay exactly where they sit for a record
  /// (founder: "without pushing the titles down"). Hidden for everything but a station.
  private let stationMark = StationArtView()
  private let stationLabel = UILabel()
  private lazy var stationRow: UIStackView = {
    stationMark.contentMode = .scaleAspectFill
    stationMark.clipsToBounds = true
    stationMark.layer.cornerCurve = .continuous
    stationMark.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stationMark.widthAnchor.constraint(equalToConstant: 22),
      stationMark.heightAnchor.constraint(equalToConstant: 22),
    ])
    stationLabel.numberOfLines = 1
    stationLabel.lineBreakMode = .byTruncatingTail
    stationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [stationMark, stationLabel, spacer])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 8
    row.isAccessibilityElement = true
    row.accessibilityTraits = .button
    row.isHidden = true
    // the station's name opens its page (what it just played, what's next, similar stations),
    // the way a record's title opens the record
    row.isUserInteractionEnabled = true
    row.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(stationRowPressed)))
    return row
  }()

  @objc
  private func stationRowPressed() {
    rootView?.openStationPage()
  }

  private func refreshStationRow() {
    guard let titleStack = albumContainerView.superview as? UIStackView else { return }
    if stationRow.superview == nil {
      stationRow.translatesAutoresizingMaskIntoConstraints = false
      // on the sheet itself, not the title's box: the row sits above that box, where its
      // taps never arrived
      addSubview(stationRow)
      NSLayoutConstraint.activate([
        stationRow.leadingAnchor.constraint(equalTo: titleStack.leadingAnchor),
        stationRow.trailingAnchor.constraint(lessThanOrEqualTo: titleStack.trailingAnchor),
        stationRow.bottomAnchor.constraint(equalTo: titleStack.topAnchor, constant: -12),
      ])
    }
    guard let radio = appDelegate.player.currentlyPlaying?.asRadio else {
      stationRow.isHidden = true
      return
    }
    let info = RadioCatalog.shared.station(forStreamUrl: radio.url)
    // the station's name and nothing else (the founder, 2026-10-31: the network and city were
    // fodder for truncation), in ink lit by the cover like the sheet's other small words
    let line = info?.name ?? radio.title
    let ink = (rootView?.coverTint ?? .neutral).kickerInk(inkShare: 0.7)
    stationLabel.attributedText = NSAttributedString.cassette(line, .kicker, color: ink)
    stationRow.accessibilityLabel = "Station: \(line)"
    stationMark.image = RadioMark.image(for: radio, side: 44) { [weak self] in
      self?.refreshStationRow()
    }.image
    stationRow.isHidden = false
  }

  func refresh() {
    // cassette polish: the album outlets are intentionally NOT passed so the
    // hidden album row (see prepare()) is never re-shown by the shared refresh
    // (which would otherwise un-hide albumContainerView for songs).
    rootView?.playerHandler?.refreshCurrentlyPlayingInfo(
      artworkImage: artworkImage,
      titleLabel: mixedCaseTitle,
      artistLabel: artistLabel
    )
    // phone-taste: capitals on this sheet only (the mock's text-transform); VoiceOver
    // still reads the title as written.
    titleLabel.text = mixedCaseTitle.text?.uppercased()
    titleLabel.accessibilityLabel = mixedCaseTitle.text
    refreshStationRow()
    rootView?.refreshOptionButton(button: optionsButton, rootView: rootView)
    // Share Song… in the ••• menu greys out for a song with no video. Asked as the song comes up
    // (ShareSongAvailability, once per song), so the menu already knows when it opens.
    if let song = rootView?.player.currentlyPlaying?.asSong,
       appDelegate.storage.settings.user.isOnlineMode,
       ShareSongAvailability.shared.known(song.id) == nil {
      Task { @MainActor in _ = await ShareSongAvailability.shared.check(song) }
    }
    // cassette Patch 054 (Phase I): refreshRating call removed; popup
    // rating view deleted.
    display(element: displayElement)
  }

  func refreshArtwork() {
    rootView?.playerHandler?.refreshArtwork(artworkImage: artworkImage)
  }

  @IBAction
  func artworkPressed(_ sender: Any) {
    rootView?.controlView?.displayPlaylistPressed()
  }

  @IBAction
  func titlePressed(_ sender: Any) {
    rootView?.displayAlbumDetail()
    rootView?.displayPodcastDetail()
  }

  @IBAction
  func albumPressed(_ sender: Any) {
    rootView?.displayAlbumDetail()
    rootView?.displayPodcastDetail()
  }

  @IBAction
  func artistNamePressed(_ sender: Any) {
    rootView?.displayArtistDetail()
    rootView?.displayPodcastDetail()
  }
}

// cassette Patch 054 (Phase I): RatingViewDelegate conformance removed
// along with the popup rating view. Rating mutation moved entirely to the
// EntityPreviewVC context-menu rating action; the local-then-server sync
// pattern below is preserved there.
