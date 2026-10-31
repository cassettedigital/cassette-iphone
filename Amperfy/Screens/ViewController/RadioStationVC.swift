//
//  RadioStationVC.swift
//  Amperfy
//
//  Cassette (founder, 2026-10-21): a radio station's page. Tap a station on the dial or
//  in Home's Radio row and land here: Play and Save up top, then what's on air, what it
//  just played (where the station publishes its list), and stations like it. Its website and
//  where to support it are in the "…" menu (StationPlaces); its about text stays hidden (the
//  founder, 2026-10-29: people don't come to read about a station).
//
//  The web's /radio/<slug> shows the same things from the same route
//  (GET /api/radio/station/<slug>, apps/cassette/src/lib/radio/station-page.ts). The page
//  opens at once from the registry copy the app carries (name, art, about, similar), and
//  the live parts fill in from the cloud, read again every 30 seconds while it is on
//  screen and as soon as the radio hears the song change, paused or playing, so the log
//  keeps moving and never falls back to the song that was on when the page opened, nor,
//  after Stop, to an answer older than the song it just played (BUG-750). Save
//  is the web's save (RadioSaved). Lit like the record pages: the station's mark (or its
//  word picture) is the glow and the colour of the headings' answers.
//
//  2026-10-28 (the founder, on the Mac's station panel, carried here): each thing said
//  once. The line under the name says the network, the city and Live, so About holds the
//  station's sentence and no longer repeats where it's from. Every song in the log, and
//  the one on now, leads onto Cassette: a tap opens its record (or looks for it when we
//  don't have it), a long press offers the record, the artist, a search and a copy.
//

import AmperfyKit
import UIKit

// MARK: - RadioStationPagePayload

/// The web route's shape, the parts the page shows.
struct RadioStationPagePayload: Decodable {
  struct Show: Decodable {
    let name: String
    let host: String?
    let tagline: String?
    let starts: String?
    let until: String?
    let image: String?
  }

  struct Track: Decodable {
    let artist: String
    let title: String
    let album: String?
    let coverUrl: String?
    let comment: String?
    let playedAt: String?
    /// The record on Cassette it came from (recent plays, servers from 2026-10-28).
    let match: RadioLiveMatch?

    /// One song, however the station spelled its case or spacing.
    var key: String {
      "\(artist.trimmingCharacters(in: .whitespaces).lowercased())\u{0}\(title.trimmingCharacters(in: .whitespaces).lowercased())"
    }
  }

  struct Live: Decodable {
    let match: RadioLiveMatch?
    let show: Show?
    let track: Track?
    let next: [Show]?
    let nextTracks: [Track]?
  }

  let live: Live?
  let recent: [Track]?
  let similar: [RadioCatalogStation]?
}

// MARK: - RadioStationVC

@MainActor
final class RadioStationVC: UIViewController, UIScrollViewDelegate, MusicPlayable {
  private static let artSide: CGFloat = 240
  private static let gutter = CassetteHeading.sideInset
  private static let refreshEvery: TimeInterval = 30

  private static var base: String {
    #if DEBUG
      // A debug build can read a local web server before the route ships:
      // SIMCTL_CHILD_CASSETTE_RADIO_BASE=http://localhost:3000 xcrun simctl launch …
      if let base = ProcessInfo.processInfo.environment["CASSETTE_RADIO_BASE"], !base.isEmpty {
        return base
      }
    #endif
    return "https://cassette.digital"
  }

  private let account: Account
  private let station: RadioCatalogStation
  /// The record Play plays (RadioDial).
  private var radio: Radio?

  private let scrollView = UIScrollView()
  private let stack = UIStackView()
  private let glow = CoverGlowView(recipe: .page)
  private let lighter = DetailCoverLighter()
  private var tint: CoverTint = .neutral

  private let art = StationArtView()
  private let nameLabel = UILabel()
  private let kickerLabel = UILabel()
  private let playPill = LibraryElementDetailTableHeaderView.makePlayPill()
  private let savePill = UIButton(configuration: .plain())

  private let onAirBlock = UIStackView()
  private let similarBlock = UIStackView()
  private var headings: [(label: UILabel, shout: String, answer: String?)] = []
  private var similar: [RadioCatalogStation] = []
  private lazy var similarCollection: UICollectionView = {
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.itemSize = CGSize(width: AlbumCarousel.mockItemWidth, height: AlbumCarousel.mockItemWidth + 52)
    layout.minimumLineSpacing = 14
    layout.sectionInset = UIEdgeInsets(top: 0, left: Self.gutter, bottom: 0, right: Self.gutter)
    let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
    view.backgroundColor = .clear
    view.showsHorizontalScrollIndicator = false
    view.register(RadioShelfCell.self, forCellWithReuseIdentifier: RadioShelfCell.typeName)
    view.dataSource = self
    view.delegate = self
    return view
  }()

  private var refreshTimer: Timer?
  private var loadedOnce = false
  /// The last answers the cloud gave; a miss keeps them up.
  private var live: RadioStationPagePayload.Live?
  private var recent: [RadioStationPagePayload.Track] = []
  /// The song the radio last heard on this station, to read the page again when it changes.
  private var heardKey: String?
  /// The last song the radio heard here and when (stamped again when it stops). After Stop it
  /// stays the song on now until a read asked for well after that moment comes back, so the
  /// page never falls back to an older answer than the one it just played (BUG-750).
  private var lastHeard: (track: RadioStationPagePayload.Track, at: Date)?
  /// When the read behind `live` was asked for.
  private var liveAskedAt: Date?
  private var wasPlaying = false
  /// How long the cloud's answers can lag (the route's edge cache: 15 s plus 5 s stale).
  private static let cloudLag: TimeInterval = 20
  /// What On air last drew, so a read that changes nothing leaves it (and an open menu) alone.
  private var drawn: String?

  init(account: Account, station: RadioCatalogStation) {
    self.account = account
    self.station = station
    super.init(nibName: nil, bundle: nil)
    navigationItem.largeTitleDisplayMode = .never
    // The glow runs up under a clear bar, as on the record pages; the name joins the bar
    // only once the hero's own name has scrolled under it.
    let clearBar = UINavigationBarAppearance()
    clearBar.configureWithTransparentBackground()
    navigationItem.standardAppearance = clearBar
    navigationItem.compactAppearance = clearBar
    navigationItem.scrollEdgeAppearance = clearBar
    navigationItem.compactScrollEdgeAppearance = clearBar
    // "…": the station's website and where to support it, out of the way (StationPlaces)
    let places = StationPlaces.actions(for: station)
    if !places.isEmpty {
      let more = UIBarButtonItem.createOptionsBarButton()
      more.menu = UIMenu(children: places)
      navigationItem.rightBarButtonItem = more
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .backgroundColor
    radio = dialRadio(for: station)

    glow.isUserInteractionEnabled = false
    view.addSubview(glow)

    scrollView.delegate = self
    scrollView.alwaysBounceVertical = true
    scrollView.backgroundColor = .clear
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scrollView)

    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(stack)
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
      stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
    ])

    buildHero()
    onAirBlock.axis = .vertical
    onAirBlock.spacing = 12
    onAirBlock.isHidden = true
    stack.addArrangedSubview(onAirBlock)
    similarBlock.axis = .vertical
    stack.addArrangedSubview(similarBlock)

    lighter.apply = { [weak self] tint, image, key in
      guard let self else { return }
      self.tint = tint
      glow.show(image: image, key: key)
      recolourHeadings()
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(Self.savedDidChange),
      name: RadioSaved.didChange,
      object: nil
    )
    for name in [Notification.Name.playerPlay, .playerPause, .playerStop] {
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(Self.playerStateChanged),
        name: name,
        object: nil
      )
    }
    appDelegate.player.addNotifier(notifier: self)

    showSimilar(RadioCatalog.shared.similarSlugs(for: station).compactMap { RadioCatalog.shared.station(slug: $0) })
    loadArt()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    applySaveState()
    playerStateChanged()
    refreshLive()
    refreshTimer?.invalidate()
    // .common, so a read still lands while a finger is on the page.
    let timer = Timer(timeInterval: Self.refreshEvery, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshLive() }
    }
    RunLoop.main.add(timer, forMode: .common)
    refreshTimer = timer
    Task { await RadioSaved.shared.refresh() }
    // What's on at the stations like this one (their tiles' second line).
    if !watchingOnNow {
      watchingOnNow = true
      RadioOnNow.shared.begin()
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    refreshTimer?.invalidate()
    refreshTimer = nil
    if watchingOnNow {
      watchingOnNow = false
      RadioOnNow.shared.end()
    }
  }

  private var watchingOnNow = false

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutGlow()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    layoutGlow()
    let nameBottom = nameLabel.convert(nameLabel.bounds, to: view).maxY
    let barBottom = view.safeAreaInsets.top
    let title = nameBottom < barBottom ? station.name : nil
    if navigationItem.title != title { navigationItem.title = title }
  }

  /// The glow sits behind the page, under the bar, and scrolls with the hero.
  private func layoutGlow() {
    let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
    let height: CGFloat = Self.artSide + 360
    glow.frame = CGRect(x: 0, y: -offset, width: view.bounds.width, height: height + max(0, -offset))
  }

  // MARK: Dial

  /// The whole dial as the player's records (RadioDial, BUG-617), read once for the page: every
  /// station plays, whether or not the computer holds it.
  private lazy var dial = RadioDial.radios(for: account, storage: appDelegate.storage)

  private func dialRadio(for station: RadioCatalogStation) -> Radio? {
    RadioDial.radio(for: station, in: dial)
  }

  // MARK: Hero

  private func buildHero() {
    let hero = UIView()
    art.contentMode = .scaleAspectFill
    art.clipsToBounds = true
    art.layer.cornerCurve = .continuous
    art.backgroundColor = RadioTile.fill(accent: station.accent)
    art.accessibilityIgnoresInvertColors = true

    nameLabel.numberOfLines = 0
    nameLabel.textAlignment = .center
    nameLabel.attributedText = NSAttributedString.cassette(
      station.name.uppercased(),
      .pageTitle,
      color: .cassette(.textPrimary)
    )
    nameLabel.accessibilityTraits = .header

    kickerLabel.numberOfLines = 0
    kickerLabel.textAlignment = .center
    kickerLabel.attributedText = NSAttributedString.cassette(
      station.kicker.uppercased(),
      .meta,
      color: .cassette(.textSecondary)
    )

    playPill.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      // Stop (a live stream has no pause) once this station is on; Play otherwise.
      if isThisStationPlaying {
        appDelegate.player.pause()
      } else {
        play()
      }
    }, for: .primaryActionTriggered)
    playPill.isEnabled = radio != nil
    savePill.configuration?.background.backgroundColor = .clear
    savePill.configuration?.background.strokeColor = UIColor.cassette(.textPrimary).withAlphaComponent(0.35)
    savePill.configuration?.background.strokeWidth = 1.5
    savePill.configuration?.cornerStyle = .capsule
    savePill.configuration?.baseForegroundColor = UIColor.cassette(.textPrimary)
    savePill.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16)
    savePill.configuration?.imagePlacement = .leading
    savePill.configuration?.imagePadding = 8
    savePill.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      RadioSaved.shared.toggle(station.slug)
    }, for: .primaryActionTriggered)
    applySaveState()

    let pills = UIStackView(arrangedSubviews: [playPill, savePill])
    pills.axis = .horizontal
    pills.spacing = 10
    pills.distribution = .fillEqually

    for v in [art, nameLabel, kickerLabel, pills] {
      v.translatesAutoresizingMaskIntoConstraints = false
      hero.addSubview(v)
    }
    let g = Self.gutter
    NSLayoutConstraint.activate([
      art.topAnchor.constraint(equalTo: hero.topAnchor, constant: CassetteTheme.Spacing.md),
      art.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
      art.widthAnchor.constraint(equalToConstant: Self.artSide),
      art.heightAnchor.constraint(equalToConstant: Self.artSide),
      nameLabel.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 24),
      nameLabel.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: g),
      nameLabel.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -g),
      kickerLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
      kickerLabel.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: g),
      kickerLabel.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -g),
      pills.topAnchor.constraint(equalTo: kickerLabel.bottomAnchor, constant: 18),
      pills.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: g),
      pills.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -g),
      pills.heightAnchor.constraint(equalToConstant: 48),
      pills.bottomAnchor.constraint(equalTo: hero.bottomAnchor, constant: -8),
    ])
    stack.addArrangedSubview(hero)
  }

  private func loadArt() {
    let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
    let color = UIColor(cassetteHexString: station.accent) ?? CassetteTheme.UIColors.bg3
    let wordArt = CarPlayStyle.phoneWordArt(word: station.name, color: color, side: Self.artSide, scale: scale)
    art.image = wordArt
    guard let src = station.image, !src.isEmpty else {
      lighter.lightUp(image: wordArt, key: "radio-word:\(station.slug)")
      return
    }
    if let cached = RadioArtLoader.shared.cachedImage(for: src), RadioArtLoader.isSharp(cached) {
      art.image = cached
      lighter.lightUp(image: cached, key: "radio:\(src)")
      return
    }
    Task { @MainActor [weak self] in
      let loaded = await RadioArtLoader.shared.image(for: src)
      guard let self else { return }
      if let loaded, RadioArtLoader.isSharp(loaded) {
        art.image = loaded
        lighter.lightUp(image: loaded, key: "radio:\(src)")
      } else {
        lighter.lightUp(image: wordArt, key: "radio-word:\(station.slug)")
      }
    }
  }

  @objc
  private func savedDidChange() {
    applySaveState()
  }

  private var isThisStationPlaying: Bool {
    let player = appDelegate.player
    guard let radio, player.isPlaying, let current = player.currentlyPlaying?.asRadio else { return false }
    return current.id == radio.id
  }

  @objc
  private func playerStateChanged() {
    guard radio != nil else { return }
    let playing = isThisStationPlaying
    LibraryElementDetailTableHeaderView.setPlayPill(playPill, state: playing ? .stop : .play)
    if wasPlaying, !playing {
      // Stopped: what it heard is the latest word until the cloud has caught up, then read again.
      if let heard = lastHeard { lastHeard = (heard.track, Date()) }
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.cloudLag + 1) { [weak self] in self?.refreshLive() }
    }
    wasPlaying = playing
    drawLive()
  }

  // MusicPlayable: the radio heard the song change on this station, so read the page again
  // now rather than at the next half minute.
  func didNowPlayingInfoChange() {
    let key = heardSong()?.key
    guard key != heardKey else { return }
    heardKey = key
    drawLive()
    if key != nil { refreshLive() }
  }

  func didStartPlayingFromBeginning() {}
  func didStartPlaying() {}
  func didPause() {}
  func didStopPlaying() {}
  func didElapsedTimeChange() {}
  func didPlaylistChange() {}
  func didArtworkChange() {}
  func didShuffleChange() {}
  func didRepeatChange() {}
  func didPlaybackRateChange() {}

  /// `+ SAVE` / `✓ SAVED`, the one save mark.
  private func applySaveState() {
    let saved = RadioSaved.shared.isSaved(station.slug)
    savePill.configuration?.image = (saved ? CassetteIcon.check : CassetteIcon.plus).symbolImage
    savePill.configuration?.attributedTitle = AttributedString(NSAttributedString.cassette(
      saved ? "Saved" : "Save",
      .pill,
      color: .cassette(.textPrimary)
    ))
    savePill.accessibilityLabel = saved ? "Saved. Remove \(station.name) from your stations" : "Save \(station.name)"
  }

  // MARK: Playing

  /// This station, then the similar stations, so Next moves to one like it.
  private func play() {
    guard let radio else { return }
    let neighbours = similar.compactMap { dialRadio(for: $0) }
    appDelegate.player.play(context: PlayContext(
      name: station.name,
      index: 0,
      playables: [radio] + neighbours.filter { $0.id != radio.id }
    ))
    Haptics.light.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
  }

  fileprivate func play(similar s: RadioCatalogStation) {
    guard let radio = dialRadio(for: s) else { return }
    appDelegate.player.play(context: PlayContext(name: s.name, index: 0, playables: [radio]))
  }

  // MARK: Headings

  private func heading(_ shout: String, answer: String? = nil) -> UIView {
    let label = CassetteHeading.makeLabel()
    label.attributedText = CassetteHeading.attributed(shout: shout, answer: answer, answerColor: tint.text)
    label.accessibilityLabel = CassetteHeading.accessibilityLabel(shout: shout, answer: answer)
    headings.append((label, shout, answer))
    let head = UIView()
    head.addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: head.topAnchor, constant: CassetteHeading.topSpacing),
      label.bottomAnchor.constraint(equalTo: head.bottomAnchor, constant: -CassetteHeading.bottomSpacing),
      label.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: Self.gutter),
      label.trailingAnchor.constraint(lessThanOrEqualTo: head.trailingAnchor, constant: -Self.gutter),
    ])
    return head
  }

  private func recolourHeadings() {
    for h in headings {
      h.label.attributedText = CassetteHeading.attributed(shout: h.shout, answer: h.answer, answerColor: tint.text)
    }
  }

  /// A view inset by the page gutter.
  private func inset(_ content: UIView) -> UIView {
    let wrap = UIView()
    content.translatesAutoresizingMaskIntoConstraints = false
    wrap.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: wrap.topAnchor),
      content.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
      content.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: Self.gutter),
      content.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -Self.gutter),
    ])
    return wrap
  }

  private static func label(_ text: String, font: UIFont, color: UIColor, lines: Int = 1) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = font
    label.textColor = color
    label.numberOfLines = lines
    return label
  }

  // MARK: Similar

  private func showSimilar(_ list: [RadioCatalogStation]) {
    let list = list.filter { $0.slug != station.slug }
    guard list.map(\.slug) != similar.map(\.slug) || similarBlock.arrangedSubviews.isEmpty else { return }
    similar = list
    similarBlock.arrangedSubviews.forEach { $0.removeFromSuperview() }
    guard !list.isEmpty else { return }
    similarBlock.addArrangedSubview(heading("More like", answer: station.name))
    similarCollection.heightAnchor.constraint(equalToConstant: AlbumCarousel.mockItemWidth + 52).isActive = true
    similarBlock.addArrangedSubview(similarCollection)
    similarCollection.reloadData()
  }

  // MARK: Live

  private func refreshLive() {
    guard station.hasNowPlaying || station.hasRecentPlays == true || !loadedOnce else { return }
    guard let url = URL(string: Self.base + "/api/radio/station/" + station.slug) else { return }
    let asked = Date()
    Task { @MainActor [weak self] in
      var request = URLRequest(url: url)
      request.timeoutInterval = 10
      request.cachePolicy = .reloadIgnoringLocalCacheData
      if let (data, response) = try? await URLSession.shared.data(for: request),
         (response as? HTTPURLResponse)?.statusCode == 200,
         let payload = try? JSONDecoder().decode(RadioStationPagePayload.self, from: data) {
        guard let self else { return }
        loadedOnce = true
        live = payload.live
        liveAskedAt = asked
        recent = payload.recent ?? []
        drawLive()
        if let server = payload.similar, !server.isEmpty { showSimilar(server) }
        return
      }
      // The station route is newer than the now-playing route; until it ships, what's
      // on still comes from the route the player already reads.
      await self?.refreshFromNowPlaying(asked: asked)
    }
  }

  private func refreshFromNowPlaying(asked: Date) async {
    guard station.hasNowPlaying,
          let url = URL(string: Self.base + "/api/radio/now-playing?station=" + station.slug)
    else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.cachePolicy = .reloadIgnoringLocalCacheData
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let live = try? JSONDecoder().decode(RadioStationPagePayload.Live.self, from: data)
    else { return }
    self.live = live
    liveAskedAt = asked
    drawLive()
  }

  /// The song the radio itself hears on this station while it plays (the cloud's song, else
  /// the stream's own title), fresher than the page's last read. Nil when it isn't playing
  /// here, or when all it knows is the show.
  private func heardSong() -> RadioStationPagePayload.Track? {
    guard isThisStationPlaying, let info = appDelegate.player.currentRadioNowPlaying, !info.title.isEmpty else { return nil }
    let cloud = appDelegate.player.currentRadioLive
    let isSong = !(cloud?.songTitle ?? "").isEmpty ||
      info.title.caseInsensitiveCompare(cloud?.show ?? "") != .orderedSame
    guard isSong else { return nil }
    let match = cloud?.albumSlug.map {
      RadioLiveMatch(
        albumSlug: $0,
        title: cloud?.albumTitle ?? "",
        artistName: info.artist,
        artistSlug: nil,
        coverUrl: nil,
        coverFullUrl: nil
      )
    }
    return RadioStationPagePayload.Track(
      artist: info.artist,
      title: info.title,
      album: nil,
      coverUrl: cloud?.artworkURL,
      comment: nil,
      playedAt: nil,
      match: match
    )
  }

  /// On air: the show, then the song on now and the songs before it, newest first, then
  /// what comes next. Tuned in, the radio's own song leads (it keeps itself fresh); else,
  /// or until it has one, the page's.
  private func drawLive() {
    let page = live?.track
    let hearing = heardSong()
    if let hearing { lastHeard = (hearing, Date()) }
    // Playing, the heard song; stopped, still the heard song until a read asked for after the
    // cloud could have caught up, so Stop never brings back the page's older answer.
    let heard = hearing ?? lastHeard.flatMap { last in
      guard let asked = liveAskedAt else { return last.track }
      return asked < last.at.addingTimeInterval(Self.cloudLag) ? last.track : nil
    }
    // The page's copy of the same song carries its cover and its record.
    let now = heard.flatMap { h in page?.key == h.key ? page : h } ?? page
    let show = live?.show
    // The radio can hear a new song before the page catches up: never the song on now twice.
    let log = recent.filter { $0.key != now?.key }.prefix(10)
    let next: String? = {
      if let n = live?.next?.first {
        let at = Self.clock(n.starts).map { " at \($0)" } ?? ""
        let name = [n.name, n.host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return "Next\(at): \(name)"
      }
      if let song = live?.nextTracks?.first { return "Next: \(song.title) · \(song.artist)" }
      return nil
    }()

    let signature = [
      [show?.name, show?.host, show?.until, show?.image].map { $0 ?? "" }.joined(separator: "|"),
      [now?.key, now?.match?.albumSlug, now?.coverUrl].map { $0 ?? "" }.joined(separator: "|"),
      // "12 min ago" moves too, so it counts as a change.
      log.map { [$0.key, Self.ago($0.playedAt, now: Date()), $0.match?.albumSlug].map { $0 ?? "" }.joined(separator: "|") }
        .joined(separator: "/"),
      next ?? "",
    ].joined(separator: "\n")
    guard signature != drawn else { return }
    drawn = signature

    onAirBlock.arrangedSubviews.forEach { $0.removeFromSuperview() }
    headings.removeAll { $0.shout == "On air" }
    guard show != nil || now != nil || !log.isEmpty else {
      onAirBlock.isHidden = true
      return
    }
    onAirBlock.isHidden = false
    onAirBlock.addArrangedSubview(heading("On air"))

    let list = UIStackView()
    list.axis = .vertical
    list.spacing = 12
    if let show { list.addArrangedSubview(showRow(show)) }
    if let now {
      let cover = RadioLiveMatch.art(match: now.match, songCover: now.coverUrl, showImage: nil) ?? station.image
      list.addArrangedSubview(songRow(now, cover: cover, isNow: true, at: Date()))
    }
    let clockNow = Date()
    for play in log {
      list.addArrangedSubview(songRow(play, cover: play.coverUrl ?? play.match?.coverUrl, isNow: false, at: clockNow))
    }
    if let next {
      list.addArrangedSubview(Self.label(next, font: .cassette(.metadata), color: .cassette(.textTertiary), lines: 2))
    }
    onAirBlock.addArrangedSubview(inset(list))
  }

  private static func picture(side: CGFloat, radius: CGFloat, src: String?) -> UIImageView {
    let picture = UIImageView()
    picture.contentMode = .scaleAspectFill
    picture.clipsToBounds = true
    picture.layer.cornerRadius = radius
    picture.backgroundColor = .cassette(.surfaceElevated)
    picture.translatesAutoresizingMaskIntoConstraints = false
    picture.widthAnchor.constraint(equalToConstant: side).isActive = true
    picture.heightAnchor.constraint(equalToConstant: side).isActive = true
    if let src, !src.isEmpty {
      if let cached = RadioArtLoader.shared.cachedImage(for: src) {
        picture.image = cached
      } else {
        Task { @MainActor [weak picture] in
          picture?.image = await RadioArtLoader.shared.image(for: src)
        }
      }
    }
    return picture
  }

  /// The show on now, its host and when it ends.
  private func showRow(_ show: RadioStationPagePayload.Show) -> UIView {
    let lines = UIStackView(arrangedSubviews: [
      Self.label(show.name, font: .cassette(.rowTitle), color: .cassette(.textPrimary), lines: 2),
    ])
    lines.axis = .vertical
    lines.spacing = 2
    let detail = [show.host.flatMap { $0.isEmpty ? nil : "with \($0)" }, Self.clock(show.until).map { "until \($0)" }]
      .compactMap { $0 }.joined(separator: " · ")
    if !detail.isEmpty {
      lines.addArrangedSubview(Self.label(detail, font: .cassette(.cardSubtitle), color: .cassette(.textSecondary), lines: 2))
    }
    var parts: [UIView] = []
    if let image = show.image, !image.isEmpty {
      parts.append(Self.picture(side: 44, radius: CassetteRadius.small, src: image))
    }
    parts.append(lines)
    let row = UIStackView(arrangedSubviews: parts)
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 12
    row.isAccessibilityElement = true
    row.accessibilityLabel = ["On air", show.name, detail].filter { !$0.isEmpty }.joined(separator: ", ")
    return row
  }

  /// A song the station played, or the one on now: a way onto Cassette.
  private func songRow(
    _ song: RadioStationPagePayload.Track,
    cover: String?,
    isNow: Bool,
    at now: Date
  ) -> UIView {
    let lines = UIStackView(arrangedSubviews: [
      Self.label(song.title, font: .cassette(.miniTitle), color: .cassette(.textPrimary)),
      Self.label(song.artist, font: .cassette(.cardSubtitle), color: .cassette(.textSecondary)),
    ])
    lines.axis = .vertical
    lines.spacing = 2
    // Orange is live state: the song on now says so where the others say when.
    let when = Self.label(
      isNow ? "Now" : Self.ago(song.playedAt, now: now) ?? "",
      font: .cassette(.caption),
      color: isNow ? CassetteTheme.UIColors.orange : .cassette(.textTertiary)
    )
    when.setContentHuggingPriority(.required, for: .horizontal)
    when.setContentCompressionResistancePriority(.required, for: .horizontal)
    let content = UIStackView(arrangedSubviews: [Self.picture(side: 44, radius: 3, src: cover), lines, when])
    content.axis = .horizontal
    content.alignment = .center
    content.spacing = 12

    let row = RadioSongRow(content: content)
    row.addAction(UIAction { [weak self] _ in self?.open(song) }, for: .primaryActionTriggered)
    row.menu = { [weak self] in self?.menu(for: song) }
    row.isAccessibilityElement = true
    row.accessibilityTraits = .button
    row.accessibilityLabel = [isNow ? "On now" : nil, song.title, song.artist].compactMap { $0 }.joined(separator: ", ")
    row.accessibilityHint = song.match.map { "Opens \($0.title) on Cassette" } ?? "Looks for it on Cassette"
    return row
  }

  // MARK: Onto Cassette

  /// A tap: the record when we have it, else a search for the song.
  private func open(_ song: RadioStationPagePayload.Track) {
    if let match = song.match {
      openRecord(match)
    } else {
      lookFor("\(song.artist) \(song.title)")
    }
  }

  /// A long press: the record and the artist when we have them, then a search and a copy.
  private func menu(for song: RadioStationPagePayload.Track) -> UIMenu {
    var groups: [UIMenuElement] = []
    if let match = song.match {
      groups.append(UIMenu(options: .displayInline, children: [
        UIAction(title: "Go to the Record", image: CassetteIcon.album.symbolImage) { [weak self] _ in
          MainActor.assumeIsolated { self?.openRecord(match) }
        },
        UIAction(title: "Go to the Artist", image: CassetteIcon.artist.symbolImage) { [weak self] _ in
          MainActor.assumeIsolated { self?.openArtist(match) }
        },
      ]))
    }
    groups.append(UIMenu(options: .displayInline, children: [
      UIAction(title: "Look for It on Cassette", image: CassetteIcon.search.symbolImage) { [weak self] _ in
        MainActor.assumeIsolated { self?.lookFor("\(song.artist) \(song.title)") }
      },
      UIAction(title: "Copy Song and Artist", image: UIImage(systemName: "doc.on.doc")) { _ in
        UIPasteboard.general.string = "\(song.title) - \(song.artist)"
      },
    ]))
    return UIMenu(children: groups)
  }

  private func push(_ vc: UIViewController) {
    navigationController?.pushViewController(vc, animated: true)
  }

  /// The person's own copy when their library has it, else the record's page (RecordOpener).
  private func openRecord(_ match: RadioLiveMatch) {
    let cover = [match.coverFullUrl, match.coverUrl].compactMap { $0 }.first { !$0.isEmpty }
    RecordOpener.open(
      albumSlug: match.albumSlug,
      title: match.title,
      placeholder: cover.flatMap { RadioArtLoader.shared.cachedImage(for: $0) },
      account: account
    ) { [weak self] vc in
      self?.push(vc)
    }
  }

  /// The artist in the person's library when they have them, else their page on Cassette,
  /// else a search for the name.
  private func openArtist(_ match: RadioLiveMatch) {
    if let artist = appDelegate.storage.main.library.getArtistByExactName(for: account, name: match.artistName) {
      push(AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist))
    } else if let slug = match.artistSlug, !slug.isEmpty {
      let path = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
      push(CassetteWebPageVC(path: "/artist/\(path)", title: match.artistName, placeholder: nil))
    } else {
      lookFor(match.artistName)
    }
  }

  /// Cassette's search, the site's, inside the app (the phone's own search is the library).
  private func lookFor(_ query: String) {
    var parts = URLComponents()
    parts.path = "/search"
    parts.queryItems = [URLQueryItem(name: "q", value: String(query.prefix(80)))]
    // A "+" in a name must reach the site as a plus, not a space.
    parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    guard let path = parts.string else { return }
    push(CassetteWebPageVC(path: path, title: "Search", placeholder: nil))
  }

  // MARK: Time

  private static func date(_ s: String?) -> Date? {
    guard let s else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
  }

  private static func clock(_ s: String?) -> String? {
    guard let d = date(s), d > Date() else { return nil }
    return d.formatted(date: .omitted, time: .shortened)
  }

  private static func ago(_ s: String?, now: Date) -> String? {
    guard let d = date(s) else { return nil }
    let minutes = Int(now.timeIntervalSince(d) / 60)
    if minutes < 1 { return "now" }
    if minutes < 60 { return "\(minutes) min ago" }
    return d.formatted(date: .omitted, time: .shortened)
  }
}

// MARK: - Similar stations row

extension RadioStationVC: UICollectionViewDataSource, UICollectionViewDelegate {
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    similar.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: RadioShelfCell.typeName,
      for: indexPath
    ) as! RadioShelfCell
    let s = similar[indexPath.item]
    cell.display(station: s)
    cell.showsPlayButton = dialRadio(for: s) != nil
    cell.onPlayTapped = { [weak self] in self?.play(similar: s) }
    return cell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    let s = similar[indexPath.item]
    navigationController?.pushViewController(RadioStationVC(account: account, station: s), animated: true)
  }
}

// MARK: - RadioSongRow

/// A song row that leads somewhere: a tap is its action, a long press Apple's context menu.
@MainActor
final class RadioSongRow: UIControl {
  var menu: (() -> UIMenu?)?
  private let content: UIView

  init(content: UIView) {
    self.content = content
    super.init(frame: .zero)
    content.isUserInteractionEnabled = false
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: topAnchor),
      content.bottomAnchor.constraint(equalTo: bottomAnchor),
      content.leadingAnchor.constraint(equalTo: leadingAnchor),
      content.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
    // UIControl's own context menu: a long press, with Apple's lift and haptic.
    isContextMenuInteractionEnabled = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet { content.alpha = isHighlighted ? 0.5 : 1 }
  }

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  )
    -> UIContextMenuConfiguration? {
    guard let menu else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu() }
  }
}
