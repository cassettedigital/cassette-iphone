//
//  MixDetailVC.swift
//  Amperfy
//
//  Cassette (founder, 2026-10-21): a made-for-you playlist's page. A tap on a Lately or mood
//  tile on Home opens it ("I'd love to see what's inside!"); the tile's disc still plays at
//  once.
//
//  The record pages' frame (DetailScreenChrome: the transparent bar, the sticky title, the
//  collapsed play button) around a hero like the album page's room: the playlist's picture,
//  240pt, up top between the back and more buttons, lit by its first record (a mood mix by
//  its own art), the name in capitals, its moods in the answer voice when it has them, the
//  song count and length, then Play and Shuffle. The songs follow, each with its record.
//  Everything here is on the phone: the page keeps the songs it was opened with, and checks
//  them against the phone again whenever it plays.
//

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - MixDetailVC

@MainActor
final class MixDetailVC: MultiSourceTableViewController {
  private let mix: HomeManager.MadeForYouMix
  private let songs: [AbstractPlayable]
  private let hero: MixHeroView
  private let lighter = DetailCoverLighter()
  private lazy var chrome = DetailScreenChrome(
    host: self,
    placement: .underBar,
    menu: { [weak self] in self?.menuElements() ?? [] },
    playContext: { [weak self] in self?.playContext(startingAt: nil) }
  )
  /// The width and top inset the hero was last laid out for.
  private var heroLayoutKey: (width: CGFloat, top: CGFloat)?

  init(account: Account, mix: HomeManager.MadeForYouMix) {
    self.mix = mix
    songs = OneTapPlay.playables(mix.songs)
    hero = MixHeroView(mix: mix, songs: OneTapPlay.playables(mix.songs))
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    chrome.prepareBeforeLoad()
    super.viewDidLoad()

    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.sectionHeaderHeight = 0
    tableView.estimatedSectionHeaderHeight = 0
    tableView.sectionFooterHeight = 0
    tableView.estimatedSectionFooterHeight = 0
    tableView.sectionHeaderTopPadding = 0
    tableView.backgroundColor = .backgroundColor
    // No row separators (the album page's clean block).
    tableView.separatorStyle = .none

    // Play pauses (and resumes) once the player is on this playlist.
    hero.onPlay = { [weak self] in
      guard let self else { return }
      if isThisMixCurrent {
        appDelegate.player.togglePlayPause()
      } else {
        play(shuffled: false)
      }
    }
    hero.onShuffle = { [weak self] in self?.play(shuffled: true) }
    tableView.tableHeaderView = hero
    chrome.install(header: nil, title: mix.title)

    lighter.apply = { [weak self] tint, glow, key in
      self?.hero.applyLight(tint: tint, glow: glow, key: key)
    }
    for name in [Notification.Name.playerPlay, .playerPause, .playerStop] {
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(Self.playerStateChanged),
        name: name,
        object: nil
      )
    }

    containableAtIndexPathCallback = { [weak self] indexPath in
      self?.songs.element(at: indexPath.row)?.asSong
    }
    playContextAtIndexPathCallback = { [weak self] indexPath in
      self?.playContext(startingAt: indexPath.row)
    }
    swipeCallback = { [weak self] indexPath, completionHandler in
      guard let self, let song = songs.element(at: indexPath.row)?.asSong else {
        completionHandler(nil)
        return
      }
      completionHandler(SwipeActionContext(
        containable: song,
        playContext: playContext(startingAt: indexPath.row)
      ))
    }
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    chrome.viewIsAppearing()
    lightUp()
    playerStateChanged()
  }

  /// The player is on this playlist: its context carries the playlist's title, and the
  /// song is one of the page's (two mixes can share a title across days).
  private var isThisMixCurrent: Bool {
    let player = appDelegate.player
    guard let current = player.currentlyPlaying, player.contextName == mix.title else { return false }
    return songs.contains { $0.id == current.id }
  }

  @objc
  private func playerStateChanged() {
    hero.setPlayState(isThisMixCurrent && appDelegate.player.isPlaying ? .pause : .play)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    chrome.viewDidLayoutSubviews()
    layoutHeroIfNeeded()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    chrome.viewWillDisappear(isMovingFromParent: isMovingFromParent)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    chrome.viewDidDisappear()
  }

  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    chrome.scrollViewDidScroll()
  }

  // No super in these two: unlike the album and playlist pages' parent, nothing above this
  // class implements them, and UIKit's table controller doesn't either, so the call crashes.
  override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    chrome.scrollDidSettle()
  }

  override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate {
      chrome.scrollDidSettle()
    }
  }

  // MARK: Table

  override func numberOfSections(in tableView: UITableView) -> Int {
    1
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    songs.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
    if let song = songs.element(at: indexPath.row) {
      // The page's 20pt gutter, as on the playlist page; each row shows its own record.
      cell.display(
        playable: song,
        playContextCb: { [weak self] cell in self?.playContext(for: cell) },
        rootView: self,
        options: PlayableCellOptions(horizontalMargin: CassetteHeading.sideInset)
      )
    }
    return cell
  }

  // MARK: Hero

  /// The hero is laid out by hand for the table's width and the status bar's height (the
  /// picture starts just under the status bar, between the back and more buttons, as the
  /// album page's cover does), and handed back to the table when either changes.
  private func layoutHeroIfNeeded() {
    guard !isHeaderTransitionFrozen else { return }
    let width = tableView.bounds.width
    let navBarMinY = navigationController?.navigationBar.frame.minY ?? 0
    let statusBar = navBarMinY > 0 ? navBarMinY : view.safeAreaInsets.top
    guard width > 0, statusBar > 0 else { return }
    let top = statusBar + CassetteTheme.Spacing.sm
    if let key = heroLayoutKey, key.width == width, key.top == top { return }
    heroLayoutKey = (width, top)
    let height = hero.layout(width: width, topInset: top)
    hero.frame = CGRect(x: 0, y: 0, width: width, height: height)
    tableView.tableHeaderView = hero
  }

  /// Lit by the playlist's first record with a cover on disk; a mood mix by its own art.
  private func lightUp() {
    if case .mood = mix.kind {
      // Lit by its drawn cover once that lands (the mood's own art until then).
      hero.onMoodArtChange = { [weak self] in self?.lightUp() }
      lighter.lightUp(image: hero.moodArtImage, key: hero.moodArtKey)
    } else {
      let path = MoodDoorRow.coverPaths(of: mix).first
      lighter.lightUp(coverPath: path, key: path ?? "made-for-you:\(mix.id)")
    }
  }

  // MARK: Playing

  /// What a play from here plays: the page's songs that are still on the phone, from
  /// `index` (a row) or from the top.
  private func playContext(startingAt index: Int?) -> PlayContext? {
    let playable = OneTapPlay.playables(songs)
    guard !playable.isEmpty else { return nil }
    var start = 0
    if let index, let song = songs.element(at: index) {
      guard let at = playable.firstIndex(where: { $0.id == song.id }) else { return nil }
      start = at
    }
    return PlayContext(name: mix.title, index: start, playables: playable)
  }

  private func playContext(for cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell) else { return nil }
    return playContext(startingAt: indexPath.row)
  }

  private func play(shuffled: Bool) {
    guard let context = playContext(startingAt: nil) else { return }
    if shuffled {
      appDelegate.player.playShuffled(context: context)
    } else {
      appDelegate.player.play(context: context)
    }
    Haptics.light.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
  }

  private func menuElements() -> [UIMenuElement] {
    [
      UIAction(title: "Play Next", image: .userQueueInsert) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.appDelegate.player.insertUserQueue(playables: OneTapPlay.playables(self.songs))
        }
      },
      UIAction(title: "Add to Queue", image: .userQueueAppend) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.appDelegate.player.appendUserQueue(playables: OneTapPlay.playables(self.songs))
        }
      },
    ]
  }
}

// MARK: - MixHeroView

/// The mix page's hero: the record page's room for a made-for-you playlist. Laid out by
/// hand (`layout(width:topInset:)` returns its height); lit by `applyLight`.
@MainActor
final class MixHeroView: UIView {
  static let artSide: CGFloat = 240
  static let gutter: CGFloat = CassetteHeading.sideInset

  var onPlay: (() -> ())?
  var onShuffle: (() -> ())?

  /// The mood mix's picture (nil for the other playlists), which also lights the page: its
  /// drawn cover (`MixCoverCache`), or the mood's own art until that lands.
  private(set) var moodArtImage: UIImage?
  /// What `moodArtImage` is, for the page's light: the cover's address, or the mood's art.
  private(set) var moodArtKey = ""
  /// Called when the drawn cover replaces the mood's art.
  var onMoodArtChange: (() -> ())?

  private let mix: HomeManager.MadeForYouMix
  private let glowClip = UIView()
  private let glow = CoverGlowView(recipe: .page)
  private let tintShadow = UIView()
  private let depthShadow = UIView()
  private let art = UIView()
  private var coverViews: [UIImageView] = []
  private let titleLabel = UILabel()
  private let answerLabel = UILabel()
  private let metaLabel = UILabel()
  private let playPill = LibraryElementDetailTableHeaderView.makePlayPill()
  private let shufflePill = LibraryElementDetailTableHeaderView.makeShufflePill()
  private var tint: CoverTint = .neutral

  init(mix: HomeManager.MadeForYouMix, songs: [AbstractPlayable]) {
    self.mix = mix
    super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 520))
    backgroundColor = .clear
    clipsToBounds = false

    // The glow, backmost, rising past the top for overscroll (as on the album page).
    glowClip.isUserInteractionEnabled = false
    glowClip.clipsToBounds = true
    glowClip.backgroundColor = .clear
    glowClip.addSubview(glow)
    addSubview(glowClip)

    for shadow in [tintShadow, depthShadow] {
      shadow.isUserInteractionEnabled = false
      shadow.backgroundColor = .clear
      addSubview(shadow)
    }
    tintShadow.layer.shadowOpacity = 1
    tintShadow.layer.shadowRadius = 30
    tintShadow.layer.shadowOffset = CGSize(width: 0, height: 30)
    tintShadow.layer.shadowColor = UIColor.black.cgColor
    depthShadow.layer.shadowColor = UIColor.black.cgColor
    depthShadow.layer.shadowOpacity = 0.5
    depthShadow.layer.shadowRadius = 9
    depthShadow.layer.shadowOffset = CGSize(width: 0, height: 8)

    art.clipsToBounds = true
    art.layer.cornerRadius = CassetteRadius.small
    art.layer.cornerCurve = .continuous
    art.backgroundColor = .cassette(.surfaceElevated)
    art.isAccessibilityElement = false
    addSubview(art)
    buildArt()

    titleLabel.numberOfLines = 0
    titleLabel.attributedText = NSAttributedString.cassette(
      mix.title.uppercased(),
      .pageTitle,
      color: .cassette(.textPrimary)
    )
    titleLabel.accessibilityTraits = .header
    addSubview(titleLabel)

    answerLabel.numberOfLines = 1
    answerLabel.isHidden = mix.subtitle == nil
    addSubview(answerLabel)
    applyAnswerColor()

    metaLabel.numberOfLines = 1
    metaLabel.attributedText = NSAttributedString.cassette(
      Self.metaText(songs: songs).uppercased(),
      .meta,
      color: .cassette(.textSecondary)
    )
    addSubview(metaLabel)

    playPill.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .primaryActionTriggered)
    shufflePill.addAction(UIAction { [weak self] _ in self?.onShuffle?() }, for: .primaryActionTriggered)
    for pill in [playPill, shufflePill] {
      pill.translatesAutoresizingMaskIntoConstraints = true
      addSubview(pill)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setPlayState(_ state: LibraryElementDetailTableHeaderView.PlayPillState) {
    LibraryElementDetailTableHeaderView.setPlayPill(playPill, state: state)
  }

  /// "30 songs · 1 hr 52 min"
  static func metaText(songs: [AbstractPlayable]) -> String {
    let seconds = songs.reduce(0) { $0 + $1.duration }
    let minutes = Int((Double(seconds) / 60).rounded())
    let length = minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    return "\(songs.count) song\(songs.count == 1 ? "" : "s") · \(length)"
  }

  /// Lays the hero out for `width`, the picture starting `topInset` from the top, and
  /// returns its height.
  func layout(width: CGFloat, topInset: CGFloat) -> CGFloat {
    let side = Self.artSide
    let artFrame = CGRect(x: (width - side) / 2, y: topInset, width: side, height: side)
    art.frame = artFrame
    layoutCovers()
    for shadow in [tintShadow, depthShadow] {
      shadow.frame = artFrame
      shadow.layer.shadowPath = UIBezierPath(
        roundedRect: shadow.bounds,
        cornerRadius: CassetteRadius.small
      ).cgPath
    }

    let textWidth = max(0, width - 2 * Self.gutter)
    var y = artFrame.maxY + 24
    func place(_ label: UILabel) {
      let height = label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
      label.frame = CGRect(x: Self.gutter, y: y, width: textWidth, height: ceil(height))
      y = label.frame.maxY
    }
    place(titleLabel)
    if !answerLabel.isHidden {
      y += 6
      place(answerLabel)
    }
    y += 10
    place(metaLabel)
    y += 18
    let pillWidth = (textWidth - 10) / 2
    playPill.frame = CGRect(x: Self.gutter, y: y, width: pillWidth, height: 48)
    shufflePill.frame = CGRect(x: Self.gutter + pillWidth + 10, y: y, width: pillWidth, height: 48)
    y += 48 + 16
    let height = ceil(y)

    let overscroll: CGFloat = 300
    glowClip.frame = CGRect(x: 0, y: -overscroll, width: width, height: height + overscroll)
    glow.frame = CGRect(x: 0, y: overscroll, width: width, height: height)
    return height
  }

  /// The record's colour and glow (`DetailCoverLighter`).
  func applyLight(tint: CoverTint, glow image: UIImage?, key: String) {
    self.tint = tint
    glow.show(image: image, key: key)
    tintShadow.layer.shadowColor = tint.shadow(0.4).cgColor
    applyAnswerColor()
  }

  private func applyAnswerColor() {
    guard let subtitle = mix.subtitle else { return }
    answerLabel.attributedText = NSAttributedString.cassette(subtitle, .answer, color: tint.text)
  }

  // MARK: Art

  private func buildArt() {
    if case let .mood(key, hexColor) = mix.kind {
      // The drawn cover when it is already here, else the mood's own art, crossfading to
      // the cover when it lands.
      // The page's own rung; the Home tile's copy (memory, else disk) shows until it lands.
      let address = MixCoverCache.address(for: mix, side: Self.artSide)
      let tile = MixCoverCache.address(for: mix)
      if let address, let cover = MixCoverCache.cached(address) {
        moodArtImage = cover
        moodArtKey = "made-for-you-cover:\(address.absoluteString)"
      } else if let tile,
                let cover = MixCoverCache.cached(tile)
                ?? MixCoverCache.diskImage(tile, maxPixelSize: CassetteImageLoader.rung(side: Self.artSide)) {
        moodArtImage = cover
        moodArtKey = "made-for-you-cover:\(tile.absoluteString)"
      } else {
        let renderer = ImageRenderer(
          content: MoodMixArt(key: key, hexColor: hexColor)
            .frame(width: Self.artSide, height: Self.artSide)
        )
        renderer.scale = 3
        moodArtImage = renderer.uiImage
        moodArtKey = "made-for-you-art:\(key)"
      }
      let view = UIImageView(image: moodArtImage)
      view.contentMode = .scaleAspectFill
      view.clipsToBounds = true
      art.addSubview(view)
      coverViews = [view]
      if let address, MixCoverCache.cached(address) == nil {
        Task { [weak self, weak view] in
          guard let cover = await MixCoverCache.load(address), let self, let view else { return }
          UIView.transition(with: view, duration: 0.3, options: .transitionCrossDissolve) {
            view.image = cover
          }
          moodArtImage = cover
          moodArtKey = "made-for-you-cover:\(address.absoluteString)"
          onMoodArtChange?()
        }
      }
      return
    }
    let paths = MoodDoorRow.coverPaths(of: mix)
    guard !paths.isEmpty else {
      let renderer = ImageRenderer(
        content: MoodMixArt(key: "lately", hexColor: "#B07AA1")
          .frame(width: Self.artSide, height: Self.artSide)
      )
      renderer.scale = 3
      let view = UIImageView(image: renderer.uiImage)
      view.contentMode = .scaleAspectFill
      view.clipsToBounds = true
      art.addSubview(view)
      coverViews = [view]
      return
    }
    // Four slots, filled in mix order and repeated to make four (the tile's mosaic).
    for slot in 0 ..< 4 {
      let path = paths[slot % paths.count]
      let view = UIImageView()
      view.contentMode = .scaleAspectFill
      view.clipsToBounds = true
      view.backgroundColor = .cassette(.surfaceElevated)
      view.image = LatelyCoverCache.cached(path)
      art.addSubview(view)
      coverViews.append(view)
      if view.image == nil {
        Task { [weak view] in
          let image = await LatelyCoverCache.load(path)
          view?.image = image
        }
      }
    }
  }

  private func layoutCovers() {
    let bounds = art.bounds
    if coverViews.count == 1 {
      coverViews[0].frame = bounds
      return
    }
    let half = bounds.width / 2
    for (slot, view) in coverViews.enumerated() {
      view.frame = CGRect(x: CGFloat(slot % 2) * half, y: CGFloat(slot / 2) * half, width: half, height: half)
    }
  }
}
