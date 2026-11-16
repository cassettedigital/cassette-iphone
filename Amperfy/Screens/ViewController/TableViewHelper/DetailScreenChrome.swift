//
//  DetailScreenChrome.swift
//  Amperfy
//
//  Cassette: the one detail-page frame (design-system audit 2026-10-20, Wave 3, DET-1).
//
//  Album, Artist and Playlist carried ~110 near-identical lines each of navigation-bar and
//  collapse choreography, and every fix to the header fade (rounds 3 to 7f, Patches 064 to
//  109) had to land in each copy; Playlist had already drifted (DET-2, DET-4). This object
//  owns all of it. A detail screen creates one, hands it the hero, and forwards five
//  lifecycle calls. The rules it enforces live here once:
//
//  - The bar is transparent in every appearance slot at rest, and its background fades in
//    with the title as the hero slides under it (Patch 109). Starting from the global opaque
//    appearance instead is what made a below-bar hero flash as the fade began.
//  - The title is the sticky header view only; `title` and `navigationItem.title` stay nil
//    (round 7c), and it is shown by `isHidden`, not just alpha (round 7f).
//  - The hero re-measures on every layout pass and when a scroll settles, never mid-scroll.
//  - Nothing recomputes while the screen is being popped (round 3).
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
import UIKit

// MARK: - DetailCoverLighter

/// Lights a record page with its own record (phone-taste): reads the cover's colour
/// (`CoverTint`) and a small decode for the glow, off the main thread, and hands both to
/// `apply`. Keyed, so asking again with an unchanged key does nothing; a newer request
/// drops an older one still in flight. While the page is on screen, a finished artwork
/// download that is one of `watchedArtworkIDs` calls `relight`, so a cover that arrives
/// late still lights the page. DetailScreenChrome owns one for the album page; the artist
/// page, which has no chrome, owns its own.
@MainActor
final class DetailCoverLighter: NSObject {
  /// The record's colour; `.neutral` until a cover is read (never brand orange).
  private(set) var tint: CoverTint = .neutral
  /// Called with the tint, the glow's small source image (nil: no glow) and its key.
  var apply: ((CoverTint, UIImage?, String) -> ())?
  /// Asked again when one of `watchedArtworkIDs` finishes downloading: the host lights up
  /// from its current cover (a no-op while the key is unchanged).
  var relight: (() -> ())?
  /// The artwork rows (`Artwork.uniqueID`) whose download can change this page's light:
  /// the record's own cover, or for an artist their records' covers and their photo. Every
  /// other download is ignored, so an artwork backfill of thousands of covers costs a set
  /// lookup each, not a relight.
  var watchedArtworkIDs: Set<String> = []

  private var key: String?
  private var token = UUID()
  private var isObservingDownloads = false

  /// Start listening for `account`'s artwork downloads. Call from viewIsAppearing and stop
  /// in viewDidDisappear: record pages stay alive in the navigation stack (and past a pop),
  /// and a page nobody can see has no light to update.
  func startObservingArtworkDownloads(account: Account?) {
    guard !isObservingDownloads, let info = account?.info else { return }
    isObservingDownloads = true
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(artworkDownloadFinished(notification:)),
      name: .downloadFinishedSuccess,
      object: appDelegate.getMeta(info).artworkDownloadManager
    )
  }

  func stopObservingArtworkDownloads() {
    guard isObservingDownloads else { return }
    isObservingDownloads = false
    appDelegate.notificationHandler.remove(self, name: .downloadFinishedSuccess, object: nil)
  }

  /// Light from a cover file on disk. A file is keyed by the foundation
  /// (`CoverTint.cacheKey`: its path plus the file's date), so a cover replaced at the same
  /// path lights the page again when its download lands; `key` names the no-file state. No
  /// file: no glow and the neutral colour, never the generated placeholder.
  func lightUp(coverPath: String?, key fallbackKey: String) {
    let coverPath = coverPath.flatMap { $0.isEmpty ? nil : $0 }
    let key = coverPath.map { CoverTint.cacheKey(forCoverPath: $0) } ?? fallbackKey
    guard key != self.key else { return }
    self.key = key
    let token = UUID()
    self.token = token
    guard let coverPath else {
      land(.neutral, glow: nil, key: key)
      return
    }
    // A page opened before: both are cached, so it lights in the same frame.
    if let cachedTint = CoverTint.cached(key: key),
       let cachedGlow = AmbientBackdropCache.cachedTiny(for: key) {
      land(cachedTint, glow: cachedGlow, key: key)
      return
    }
    Task { @MainActor [weak self] in
      let tint = await CoverTint.resolve(coverPath: coverPath) ?? .neutral
      let glow = await Task.detached(priority: .utility) {
        AmbientSourceDecoder.thumbnail(contentsOfFile: coverPath, maxPixelSize: 64)
      }.value
      guard let self, self.token == token else { return }
      land(tint, glow: glow, key: key)
    }
  }

  /// Light from an image already in hand (a playlist's pick or preset), keyed by `key`.
  /// nil: no glow and the neutral colour.
  func lightUp(image: UIImage?, key: String) {
    guard key != self.key else { return }
    self.key = key
    let token = UUID()
    self.token = token
    guard let image else {
      land(.neutral, glow: nil, key: key)
      return
    }
    if let cachedTint = CoverTint.cached(key: key) {
      land(cachedTint, glow: image, key: key)
      return
    }
    Task { @MainActor [weak self] in
      let tint = await CoverTint.resolve(image: image, key: key)
      guard let self, self.token == token else { return }
      land(tint, glow: image, key: key)
    }
  }

  private func land(_ tint: CoverTint, glow: UIImage?, key: String) {
    self.tint = tint
    apply?(tint, glow, key)
  }

  @objc
  private func artworkDownloadFinished(notification: Notification) {
    guard let download = DownloadNotification.fromNotification(notification),
          watchedArtworkIDs.contains(download.id)
    else { return }
    relight?()
  }
}

// MARK: - DetailScreenChrome

@MainActor
final class DetailScreenChrome {
  /// Where the hero sits relative to the navigation bar.
  enum HeroPlacement {
    /// The artwork runs up under a transparent bar, centred between the back and more
    /// buttons (album, artist, playlist). The table's insets are mirrored by hand and the
    /// iOS 26 top scroll-edge scrim is hidden so the artwork is clean at rest.
    case underBar
    /// The hero starts below the bar with automatic insets. No record page uses it since
    /// the playlist page dropped pull-to-refresh (phone-taste; it re-syncs on every
    /// appear); kept for a screen that needs a refresh spinner at the top edge.
    case belowBar
  }

  let stickyHeader = DetailStickyHeaderView()
  let optionsItem: UIBarButtonItem
  let collapsedPlayItem: UIBarButtonItem
  private(set) var header: GenericDetailTableHeader?

  private weak var host: BasicTableViewController?
  private let placement: HeroPlacement

  // MARK: phone-taste lighting

  private let lighter = DetailCoverLighter()
  /// The record's colour; `.neutral` until the cover is read.
  var tint: CoverTint { lighter.tint }
  /// Called after a tint lands, so hosts can recolour their own headings.
  var onTintChanged: ((CoverTint) -> ())?
  /// Called when one of `watchedArtworkIDs` finishes downloading while the page is on
  /// screen: the host lights up again from its current cover, so a cover that arrives late
  /// still lights the page.
  var relight: (() -> ())? {
    get { lighter.relight }
    set { lighter.relight = newValue }
  }

  /// The artwork rows whose download can change the light (the record's own cover).
  var watchedArtworkIDs: Set<String> {
    get { lighter.watchedArtworkIDs }
    set { lighter.watchedArtworkIDs = newValue }
  }

  /// The account whose artwork downloads `relight` the page; nil: none do.
  private var artworkAccount: Account?

  /// When true (the album page) a landed tint recolours the visible rows' track numbers in
  /// place. Rows bound later read `tint` themselves.
  var tintsTrackNumbers = false

  /// - Parameters:
  ///   - menu: the overflow menu's actions, built on open.
  ///   - playContext: what the collapsed bar play button plays (the same context the hero's
  ///     own play button uses).
  init(
    host: BasicTableViewController,
    placement: HeroPlacement,
    menu: @escaping () -> [UIMenuElement],
    playContext: @escaping () -> PlayContext?
  ) {
    self.host = host
    self.placement = placement
    optionsItem = UIBarButtonItem.createOptionsBarButton()
    optionsItem.menu = UIMenu.lazyMenu(builder: menu)
    collapsedPlayItem = UIBarButtonItem(
      image: CassetteIcon.play.symbolImage,
      primaryAction: UIAction { _ in
        MainActor.assumeIsolated {
          guard let context = playContext() else { return }
          (UIApplication.shared.delegate as? AppDelegate)?.player.play(context: context)
        }
      }
    )
    collapsedPlayItem.accessibilityLabel = "Play"
    collapsedPlayItem.isHidden = true
    lighter.apply = { [weak self] tint, glow, key in
      self?.landLight(tint: tint, glow: glow, key: key)
    }
  }

  // MARK: Lighting

  /// Light the page from a cover file on disk (keyed by `CoverTint.cacheKey`, its path plus
  /// the file's date; `key` names the no-file state). No file: no glow, the neutral colour.
  /// An unchanged key does nothing.
  func lightUp(coverPath: String?, key: String) {
    lighter.lightUp(coverPath: coverPath, key: key)
  }

  /// Light the page from an image already in hand (a playlist's pick or preset).
  func lightUp(image: UIImage?, key: String) {
    lighter.lightUp(image: image, key: key)
  }

  /// Call `relight` when one of `watchedArtworkIDs` finishes downloading for `account`. It
  /// listens only while the page is on screen (`viewIsAppearing` to `viewDidDisappear`).
  func observeArtworkDownloads(account: Account) {
    artworkAccount = account
    if host?.viewIfLoaded?.window != nil {
      lighter.startObservingArtworkDownloads(account: account)
    }
  }

  private func landLight(tint: CoverTint, glow: UIImage?, key: String) {
    header?.applyCoverLight(tint: tint, glowImage: glow, glowKey: key)
    if tintsTrackNumbers, let tableView = host?.tableView {
      // In place: a reload would restart the playing row's waveform, and
      // reconfigureRows is the wrong tool on this diffable table.
      for case let cell as PlayableTableCell in tableView.visibleCells {
        cell.setTrackNumberColor(tint.text)
      }
    }
    onTintChanged?(tint)
  }

  /// Whether the hero header should extend under the bar (`DetailHeaderConfiguration`).
  var extendsUnderNavigationBar: Bool { placement == .underBar }

  // MARK: viewDidLoad

  /// Before `super.viewDidLoad()`: pin the inline title so the parent's large title does not
  /// flash through the push (Patch 037).
  func prepareBeforeLoad() {
    host?.navigationItem.largeTitleDisplayMode = .never
  }

  /// After the hero is built: bar appearance, insets, the sticky title and the trailing items.
  func install(header: GenericDetailTableHeader?, title: String?) {
    guard let host else { return }
    self.header = header
    let tableView = host.tableView!
    if placement == .underBar {
      tableView.contentInsetAdjustmentBehavior = .never
      if #available(iOS 26.0, *) {
        tableView.topEdgeEffect.isHidden = true
      }
    }
    let transparentBar = UINavigationBarAppearance()
    transparentBar.configureWithTransparentBackground()
    let item = host.navigationItem
    item.standardAppearance = transparentBar
    item.compactAppearance = transparentBar
    item.scrollEdgeAppearance = transparentBar
    item.compactScrollEdgeAppearance = transparentBar

    DetailStickyHeaderSupport.install(
      stickyHeader: stickyHeader,
      in: host,
      overflowItem: optionsItem,
      collapsedPlayItem: collapsedPlayItem
    )
    setTitle(title)
    tableView.layoutIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.stickyHeader.alpha = 0
    }
  }

  /// The collapsed title. Call again whenever the entity's name can have changed.
  func setTitle(_ title: String?) {
    stickyHeader.configure(title: title ?? "", subtitle: nil)
  }

  /// Extra trailing bar items after the overflow and the collapsed play (none today: the
  /// playlist's Edit moved into the overflow menu, phone-taste).
  func setExtraTrailingItems(_ items: [UIBarButtonItem]) {
    host?.navigationItem.rightBarButtonItems = [optionsItem, collapsedPlayItem] + items
  }

  // MARK: Lifecycle forwarding

  func viewIsAppearing() {
    // Restores the right alpha when popping back to a scrolled screen.
    updateCollapse()
    lighter.startObservingArtworkDownloads(account: artworkAccount)
  }

  /// A hidden or popped page stops listening for downloads; it lights up from its current
  /// cover again on its next appearance.
  func viewDidDisappear() {
    lighter.stopObservingArtworkDownloads()
  }

  func viewDidLayoutSubviews() {
    guard let host, !host.isHeaderTransitionFrozen else { return }
    if placement == .underBar {
      // With contentInsetAdjustmentBehavior == .never the safe areas are mirrored by hand
      // (bottom = tab bar + mini player); top stays 0 so the artwork reaches the top edge.
      host.tableView.contentInset.bottom = host.view.safeAreaInsets.bottom
      host.tableView.verticalScrollIndicatorInsets.top = host.view.safeAreaInsets.top
      host.tableView.verticalScrollIndicatorInsets.bottom = host.view.safeAreaInsets.bottom
    }
    // Width-keyed inside: a rotation or iPad resize re-measures; a no-op otherwise (DET-4).
    header?.resizeToFit()
  }

  func viewWillDisappear(isMovingFromParent: Bool) {
    guard let host else { return }
    if !isMovingFromParent {
      // Pushing a child: start its bar clean.
      stickyHeader.alpha = 0
    } else {
      // Popping (including the interactive edge swipe): hold everything as it is so the
      // hero rides off-screen instead of re-expanding. A cancelled swipe resumes.
      host.freezeCollapsingHeaderForPopTransition { [weak self] in
        self?.header?.resizeToFit()
        self?.updateCollapse()
      }
    }
  }

  func scrollViewDidScroll() {
    updateCollapse()
  }

  /// A scroll came to rest: land any re-measure `resizeToFit` deferred mid-scroll.
  func scrollDidSettle() {
    header?.resizeToFit()
  }

  private func updateCollapse() {
    guard let host else { return }
    DetailStickyHeaderSupport.updateAlpha(
      stickyHeader: stickyHeader,
      scrollView: host.tableView,
      tableHeaderView: host.tableView.tableHeaderView,
      in: host,
      collapsedPlayItem: collapsedPlayItem
    )
  }
}

extension DetailScreenChrome {
  /// The song count under an album or playlist title. When only part of it is on this
  /// phone (the rest stays on the hub), it says so: "8 of 12 songs on this phone".
  static func songCountText(onPhone: Int, total: Int) -> String {
    if CassetteLibraryFilterProvider.shared.isOnDeviceOnly, onPhone < total {
      return "\(onPhone) of \(total) songs on this \(UIDevice.cassetteDeviceWord)"
    }
    return "\(total) Song\(total == 1 ? "" : "s")"
  }

  /// A quiet line under an album or playlist whose songs are only partly on this phone,
  /// or nil when everything is here (or in Server Mode, where nothing is hidden).
  static func onPhoneFooter(onPhone: Int, total: Int) -> UIView? {
    guard CassetteLibraryFilterProvider.shared.isOnDeviceOnly, onPhone < total else { return nil }
    let label = UILabel()
    label.text = onPhone == 0
      ? "None of these \(total) songs are on this \(UIDevice.cassetteDeviceWord) yet"
      : "\(onPhone) of \(total) songs on this \(UIDevice.cassetteDeviceWord)"
    label.font = .cassette(.metadata)
    label.textColor = .cassette(.textSecondary)
    label.textAlignment = .center
    label.numberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    let footer = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 64))
    footer.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
      label.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
      label.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
    ])
    return footer
  }
}

// MARK: - DetailShelfBlock

/// One shelf under a record page's songs (phone-taste): a two-voice heading ("MORE BY"
/// and the artist, "MORE LIKE" and the playlist) over a row of covers that each play in one
/// tap. Every album in it is on the phone; `onPlay` goes through OneTapPlay.
struct DetailShelfBlock {
  let shout: String
  let answer: String?
  let albums: [Album]
  let onSelect: (Album) -> ()
  let onPlay: (Album) -> ()
}

// MARK: - DetailRecordFooter

/// The table footer of a record page: the on-phone line when part of the record is still
/// on the hub, then its shelves. Sized by the caller (`DetailScreenChrome.makeRecordFooter`).
final class DetailRecordFooter: UIView {
  fileprivate var headings: [(label: UILabel, shout: String, answer: String?)] = []

  /// Recolour the headings' answers in place, e.g. when the page's tint lands.
  func setAnswerColor(_ color: UIColor) {
    for heading in headings {
      heading.label.attributedText = CassetteHeading.attributed(
        shout: heading.shout,
        answer: heading.answer,
        answerColor: color
      )
    }
  }
}

extension DetailScreenChrome {
  /// The footer for a record page, `width` wide and sized to its content: the on-phone line
  /// ("8 of 12 songs on this phone", only when part of it is on the hub), then each shelf
  /// that has albums. nil when there is nothing to show.
  static func makeRecordFooter(
    width: CGFloat,
    onPhone: Int,
    total: Int,
    shelves: [DetailShelfBlock],
    answerColor: UIColor
  )
    -> DetailRecordFooter? {
    let blocks = shelves.filter { !$0.albums.isEmpty }
    let showsLine = CassetteLibraryFilterProvider.shared.isOnDeviceOnly && onPhone < total
    guard showsLine || !blocks.isEmpty, width > 0 else { return nil }

    let footer = DetailRecordFooter(frame: CGRect(x: 0, y: 0, width: width, height: 64))
    footer.backgroundColor = .clear
    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    footer.addSubview(stack)
    // Air under the last shelf; the on-phone line alone keeps its own 64pt block.
    let bottomAir: CGFloat = blocks.isEmpty ? 0 : 16
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: footer.topAnchor),
      stack.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -bottomAir),
    ])

    if showsLine {
      let label = UILabel()
      label.text = onPhone == 0
        ? "None of these \(total) songs are on this \(UIDevice.cassetteDeviceWord) yet"
        : "\(onPhone) of \(total) songs on this \(UIDevice.cassetteDeviceWord)"
      label.font = .cassette(.metadata)
      label.textColor = .cassette(.textSecondary)
      label.textAlignment = .center
      label.numberOfLines = 0
      label.translatesAutoresizingMaskIntoConstraints = false
      let lineBlock = UIView()
      lineBlock.addSubview(label)
      NSLayoutConstraint.activate([
        lineBlock.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
        label.leadingAnchor.constraint(equalTo: lineBlock.leadingAnchor, constant: 16),
        label.trailingAnchor.constraint(equalTo: lineBlock.trailingAnchor, constant: -16),
        label.centerYAnchor.constraint(equalTo: lineBlock.centerYAnchor),
        label.topAnchor.constraint(greaterThanOrEqualTo: lineBlock.topAnchor, constant: 8),
      ])
      stack.addArrangedSubview(lineBlock)
    }

    for block in blocks {
      let label = CassetteHeading.makeLabel()
      label.attributedText = CassetteHeading.attributed(
        shout: block.shout,
        answer: block.answer,
        answerColor: answerColor
      )
      label.accessibilityLabel = CassetteHeading.accessibilityLabel(
        shout: block.shout,
        answer: block.answer
      )
      let head = UIView()
      head.addSubview(label)
      NSLayoutConstraint.activate([
        label.topAnchor.constraint(equalTo: head.topAnchor, constant: CassetteHeading.topSpacing),
        label.bottomAnchor.constraint(
          equalTo: head.bottomAnchor,
          constant: -CassetteHeading.bottomSpacing
        ),
        label.leadingAnchor.constraint(
          equalTo: head.leadingAnchor,
          constant: CassetteHeading.sideInset
        ),
        label.trailingAnchor.constraint(
          lessThanOrEqualTo: head.trailingAnchor,
          constant: -CassetteHeading.sideInset
        ),
      ])
      stack.addArrangedSubview(head)
      footer.headings.append((label, block.shout, block.answer))

      let shelf = AlbumShelfView()
      shelf.translatesAutoresizingMaskIntoConstraints = false
      shelf.heightAnchor.constraint(equalToConstant: AlbumShelfView.preferredHeight(for: .mock))
        .isActive = true
      shelf.configure(
        albums: block.albums,
        onSelect: block.onSelect,
        onPlay: block.onPlay,
        style: .mock
      )
      stack.addArrangedSubview(shelf)
    }

    let height = footer.systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    ).height
    footer.frame = CGRect(x: 0, y: 0, width: width, height: ceil(max(height, 1)))
    return footer
  }
}
