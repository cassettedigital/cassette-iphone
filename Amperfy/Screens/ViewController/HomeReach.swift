//
//  HomeReach.swift
//  Amperfy
//
//  Cassette: the reaching row and All shelves (One Home, founder 2026-10-28). Home carries one
//  reaching shelf at a time, the one the moment picked in the cloud (Loud ones, Quiet ones,
//  Bops, Deep dive, Nostalgia, a corner of your library, More like this month, Albums you
//  haven't played). Deep dive is one record, drawn as one big card; Nostalgia leads with its
//  mix of songs from its years. All shelves holds every shelf made today, and a shelf opens as
//  a page of its records. Names only: no line under a row's name says why (founder).
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
import SwiftUI
import UIKit

// MARK: - DeepDiveCardCell

/// Deep dive's one record as one big card: the cover across the card, then the record's name,
/// its artist and the play disc (the sketch's 358pt cover on a 390pt phone). The cover opens
/// the record; the disc plays it from the top.
final class DeepDiveCardCell: BasicCollectionCell {
  private static let playDiameter: CGFloat = 52
  private static let padding: CGFloat = 14

  var onPlayTapped: (() -> ())?

  private let cardView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = UIColor.cassette(.surfaceElevated)
    view.layer.cornerRadius = CassetteRadius.litCard
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
    return view
  }()

  // Seeded with a real frame: a zero frame lays the nib's inner image out as garbage
  // (ResumeCardCell, Patch 104).
  private let artworkView: EntityImageView = {
    let view = EntityImageView(frame: CGRect(x: 0, y: 0, width: 358, height: 358))
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  private let artistLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  private lazy var playButton: UIButton = {
    let button = LibraryElementDetailTableHeaderView.makeDetailPlayCTA(
      diameter: Self.playDiameter,
      glyphScale: 0.43
    )
    button.translatesAutoresizingMaskIntoConstraints = false
    button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 0)
    button.addAction(UIAction { [weak self] _ in self?.onPlayTapped?() }, for: .touchUpInside)
    return button
  }()

  private var displayedID: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupSubviews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupSubviews()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onPlayTapped = nil
    displayedID = nil
  }

  private func setupSubviews() {
    contentView.backgroundColor = .clear
    contentView.addSubview(cardView)
    cardView.addSubview(artworkView)
    let text = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
    text.translatesAutoresizingMaskIntoConstraints = false
    text.axis = .vertical
    text.spacing = 4
    cardView.addSubview(text)
    cardView.addSubview(playButton)
    let pad = Self.padding
    // The card's height comes from its width (a square cover) and the text under it.
    let bottom = text.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -pad)
    bottom.priority = UILayoutPriority(999)
    NSLayoutConstraint.activate([
      cardView.topAnchor.constraint(equalTo: contentView.topAnchor),
      cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

      artworkView.topAnchor.constraint(equalTo: cardView.topAnchor),
      artworkView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
      artworkView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
      artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),

      text.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: pad),
      text.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: pad),
      text.trailingAnchor.constraint(lessThanOrEqualTo: playButton.leadingAnchor, constant: -12),
      bottom,
      text.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -pad),

      playButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -pad),
      playButton.centerYAnchor.constraint(equalTo: text.centerYAnchor),
      playButton.widthAnchor.constraint(equalToConstant: Self.playDiameter),
      playButton.heightAnchor.constraint(equalToConstant: Self.playDiameter),
      playButton.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -pad),
    ])
  }

  func display(album: Album) {
    titleLabel.attributedText = NSAttributedString.cassette(
      album.name,
      .cardTitle,
      color: UIColor.cassette(.textPrimary),
      uppercase: true
    )
    artistLabel.attributedText = NSAttributedString.cassette(
      album.artist?.name ?? "",
      .answerCompact,
      color: UIColor.cassette(.accentAnswer),
      uppercase: false
    )
    if displayedID != album.id {
      displayedID = album.id
      let setting = appDelegate.storage.settings.accounts.getSetting(album.account?.info).read
      artworkView.display(theme: setting.themePreference, container: album, cornerRadius: .verySmall)
    }
    let pixel = 1.0 / max(traitCollection.displayScale, 1.0)
    cardView.layer.borderWidth = pixel
    cardView.cassetteOnAppearanceChange {
      $0.layer.borderColor = UIColor.cassette(.textPrimary).withAlphaComponent(0.06).cgColor
    }
    accessibilityLabel = [album.name, album.artist?.name].compactMap { $0 }.joined(separator: ", ")
    playButton.accessibilityLabel = "Play \(album.name)"
  }
}

// MARK: - ReachMixCell

/// Nostalgia's mix in the reaching row, as the made-for-you row draws a playlist (its records'
/// covers, the play disc, its name and song count). The picture opens it; the disc plays it.
final class ReachMixCell: UICollectionViewCell {
  func display(
    mix: HomeManager.MadeForYouMix,
    open: @escaping () -> (),
    play: @escaping () -> ()
  ) {
    let paths = MoodDoorRow.coverPaths(of: mix)
    contentConfiguration = UIHostingConfiguration {
      MadeForYouTile(mix: mix, coverPaths: paths, open: open, play: play)
    }
    .margins(.all, 0)
  }
}

// MARK: - AllShelvesVC

/// Every shelf made today that the phone holds a record of, the one on Home first: three of
/// its covers, its name in two voices, how many records, and ON HOME on the one Home shows.
/// A row opens the shelf.
final class AllShelvesVC: UITableViewController {
  private let account: Account
  private let cloudHome: CloudHome
  private var shelves: [CloudHome.Shelf] = []

  init(account: Account, cloudHome: CloudHome) {
    self.account = account
    self.cloudHome = cloudHome
    super.init(style: .plain)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "All Shelves"
    navigationItem.largeTitleDisplayMode = .never
    tableView.backgroundColor = CassetteTheme.UIColors.bg
    tableView.separatorColor = UIColor.cassette(.hairline)
    tableView.register(ShelfRowCell.self, forCellReuseIdentifier: ShelfRowCell.reuseID)
    tableView.rowHeight = ShelfRowCell.height
    let header = UILabel()
    header.attributedText = CassetteHeading.attributed(
      shout: "All shelves",
      answer: "today",
      answerColor: UIColor.cassette(.accentAnswer)
    )
    let headerHost = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 56))
    header.translatesAutoresizingMaskIntoConstraints = false
    headerHost.addSubview(header)
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor, constant: CassetteHeading.sideInset),
      header.trailingAnchor.constraint(lessThanOrEqualTo: headerHost.trailingAnchor, constant: -CassetteHeading.sideInset),
      header.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor, constant: -8),
    ])
    tableView.tableHeaderView = headerHost
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(reload),
      name: CloudHome.didChange,
      object: nil
    )
    reload()
  }

  @objc
  private func reload() {
    shelves = cloudHome.shelves
    tableView.reloadData()
    contentUnavailableConfiguration = shelves.isEmpty
      ? UIContentUnavailableConfiguration.cassetteEmpty(image: nil, title: "No shelves today", body: nil) : nil
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    shelves.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
    cell.display(shelf: shelves[indexPath.row])
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let shelf = shelves[indexPath.row]
    navigationController?.pushViewController(
      ShelfVC(account: account, cloudHome: cloudHome, shelfID: shelf.id),
      animated: true
    )
  }
}

// MARK: - ShelfRowCell

/// One shelf on All shelves.
private final class ShelfRowCell: UITableViewCell {
  static let reuseID = "ShelfRowCell"
  static let height: CGFloat = 88

  private let covers: [UIImageView] = (0 ..< 3).map { _ in
    let view = UIImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.contentMode = .scaleAspectFill
    view.clipsToBounds = true
    view.layer.cornerRadius = CassetteRadius.artworkTile
    view.backgroundColor = UIColor.cassette(.surfaceElevated)
    return view
  }

  private let nameLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  private let lineLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.cassette(.cardSubtitle)
    label.textColor = UIColor.cassette(.textSecondary)
    return label
  }()

  private let onHomeLabel: UILabel = {
    let label = PaddedLabel()
    label.attributedText = NSAttributedString.cassette(
      "On Home",
      .kicker,
      color: CassetteTheme.UIColors.bg,
      uppercase: true
    )
    // ink, not orange: orange marks what's live (I-T4); being on Home is a fact
    label.backgroundColor = UIColor.cassette(.fillSelected)
    label.layer.cornerRadius = 4
    label.clipsToBounds = true
    return label
  }()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    accessoryType = .disclosureIndicator
    let stack = UIView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    // back to front: the third cover furthest back, the first in front
    for view in covers.reversed() { stack.addSubview(view) }
    let text = UIStackView(arrangedSubviews: [nameLabel, lineLabel, onHomeLabel])
    text.translatesAutoresizingMaskIntoConstraints = false
    text.axis = .vertical
    text.alignment = .leading
    text.spacing = 3
    contentView.addSubview(text)
    var constraints = [
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: CassetteHeading.sideInset),
      stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      stack.widthAnchor.constraint(equalToConstant: 84),
      stack.heightAnchor.constraint(equalToConstant: 64),
      text.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 14),
      text.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -8),
      text.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ]
    // the sketch's fan: 64, 60 and 56pt covers, 14pt apart
    for (index, view) in covers.enumerated() {
      let side = CGFloat(64 - 4 * index)
      constraints += [
        view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: CGFloat(14 * index)),
        view.topAnchor.constraint(equalTo: stack.topAnchor, constant: CGFloat(2 * index)),
        view.widthAnchor.constraint(equalToConstant: side),
        view.heightAnchor.constraint(equalToConstant: side),
      ]
      view.alpha = [1, 0.8, 0.55][index]
    }
    NSLayoutConstraint.activate(constraints)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func display(shelf: CloudHome.Shelf) {
    nameLabel.attributedText = CassetteHeading.attributed(
      shout: shelf.shout,
      answer: shelf.answer,
      answerColor: UIColor.cassette(.accentAnswer),
      shoutStyle: .rowTitle,
      answerStyle: .answerCompact
    )
    if shelf.isDeepDive, let album = shelf.albums.first {
      lineLabel.text = [album.name, album.artist?.name].compactMap { $0 }.joined(separator: " · ")
    } else {
      let records = shelf.albums.count == 1 ? "1 album" : "\(shelf.albums.count) albums"
      lineLabel.text = shelf.mix == nil ? records : "A playlist and \(records)"
    }
    onHomeLabel.isHidden = !shelf.onHome
    let settings = appDelegate.storage.settings.accounts
    for (index, view) in covers.enumerated() {
      let album = index < shelf.albums.count ? shelf.albums[index] : nil
      view.isHidden = album == nil
      view.image = album.flatMap { album in
        album.imagePath(setting: settings.getSetting(album.account?.info).read.artworkDisplayPreference)
          .flatMap { UIImage(contentsOfFile: $0) }
      }
    }
    accessibilityLabel = [shelf.shout, shelf.answer, lineLabel.text, shelf.onHome ? "on Home" : nil]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
  }
}

/// A label with room around its text (the ON HOME chip).
private final class PaddedLabel: UILabel {
  private let insets = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: insets))
  }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
  }
}

// MARK: - ShelfVC

/// One shelf, opened: its records in a grid of album tiles, Nostalgia's mix first. A tile
/// opens the record and its disc plays it, as on Home.
final class ShelfVC: UICollectionViewController {
  private enum Item: Hashable {
    case mix(String)
    case album(String)
  }

  private static let gutter = AlbumCarousel.mockGutter
  private static let spacing: CGFloat = 12

  private let account: Account
  private let cloudHome: CloudHome
  private let shelfID: String
  private var shelf: CloudHome.Shelf?

  init(account: Account, cloudHome: CloudHome, shelfID: String) {
    self.account = account
    self.cloudHome = cloudHome
    self.shelfID = shelfID
    let layout = UICollectionViewCompositionalLayout { _, environment in
      let width = environment.container.effectiveContentSize.width
      let columns: CGFloat = width > 600 ? 4 : 2
      let itemWidth = ((width - 2 * Self.gutter - (columns - 1) * Self.spacing) / columns).rounded(.down)
      let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
        widthDimension: .absolute(itemWidth),
        heightDimension: .estimated(itemWidth + 48)
      ))
      let group = NSCollectionLayoutGroup.horizontal(
        layoutSize: NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1),
          heightDimension: .estimated(itemWidth + 48)
        ),
        subitems: Array(repeating: item, count: Int(columns))
      )
      group.interItemSpacing = .fixed(Self.spacing)
      let section = NSCollectionLayoutSection(group: group)
      section.interGroupSpacing = 20
      section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: Self.gutter, bottom: 24, trailing: Self.gutter)
      return section
    }
    super.init(collectionViewLayout: layout)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var items: [Item] = []

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.largeTitleDisplayMode = .never
    collectionView.backgroundColor = CassetteTheme.UIColors.bg
    collectionView.register(
      UINib(nibName: AlbumCollectionCell.typeName, bundle: .main),
      forCellWithReuseIdentifier: AlbumCollectionCell.typeName
    )
    collectionView.register(ReachMixCell.self, forCellWithReuseIdentifier: "ReachMixCell")
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(reload),
      name: CloudHome.didChange,
      object: nil
    )
    reload()
  }

  @objc
  private func reload() {
    shelf = cloudHome.shelves.first { $0.id == shelfID }
    title = shelf.map { [$0.shout, $0.answer].filter { !$0.isEmpty }.joined(separator: " ") } ?? "Shelf"
    items = (shelf?.mix.map { [Item.mix($0.id)] } ?? []) + (shelf?.albums.map { Item.album($0.id) } ?? [])
    collectionView.reloadData()
    contentUnavailableConfiguration = shelf == nil
      ? UIContentUnavailableConfiguration.cassetteEmpty(image: nil, title: "That shelf isn't in today's", body: nil)
      : nil
  }

  private func album(_ id: String) -> Album? {
    shelf?.albums.first { $0.id == id }
  }

  override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    items.count
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  )
    -> UICollectionViewCell {
    switch items[indexPath.item] {
    case .mix:
      let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ReachMixCell", for: indexPath) as! ReachMixCell
      if let mix = shelf?.mix {
        cell.display(
          mix: mix,
          open: { [weak self] in self?.open(mix) },
          play: { MoodDoorRow.play(mix) }
        )
      }
      return cell
    case let .album(id):
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: AlbumCollectionCell.typeName,
        for: indexPath
      ) as! AlbumCollectionCell
      if let album = album(id) {
        cell.showsPlayOverlay = true
        cell.onPlayTapped = { OneTapPlay.play(album) }
        let width = collectionView.bounds.width
        let columns: CGFloat = width > 600 ? 4 : 2
        let itemWidth = ((width - 2 * Self.gutter - (columns - 1) * Self.spacing) / columns).rounded(.down)
        cell.display(container: album, rootView: self, itemWidth: itemWidth, initialIndexPath: indexPath)
      }
      return cell
    }
  }

  override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard case let .album(id) = items[indexPath.item], let album = album(id) else { return }
    navigationController?.pushViewController(
      AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
      animated: true
    )
  }

  private func open(_ mix: HomeManager.MadeForYouMix) {
    navigationController?.pushViewController(MixDetailVC(account: account, mix: mix), animated: true)
  }
}
