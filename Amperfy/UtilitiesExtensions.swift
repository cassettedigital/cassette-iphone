//
//  UtilitiesExtensions.swift
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
import MarqueeLabel
import os.log
import SwiftUI
import UIKit

extension MarqueeLabel {
  func applyAmperfyStyle() {
    if trailingBuffer != 30.0 {
      trailingBuffer = 30.0
    }
    if leadingBuffer != 0.0 {
      leadingBuffer = 0.0
    }
    if animationDelay != 2.0 {
      animationDelay = 2.0
    }
    if type != .continuous {
      type = .continuous
    }
    speed = .rate(30.0)
    if fadeLength != 10.0 {
      fadeLength = 10.0
    }
    // cassette (I-M3): with Reduce Motion a long title stays put and ends in "…" instead of
    // scrolling.
    let still = UIAccessibility.isReduceMotionEnabled
    if labelize != still {
      labelize = still
    }
  }
}

extension UIColor {
  static let hardLabelColor = UIColor(named: "hardLabelColor")
}

extension Color {
  // cassette (Wave 2): state colors are tokens (were system red and green).
  static let error = Color.cassette(.danger)
  static let success = Color.cassette(.success)

  // MARK: - Text Colors

  static let lightText = Color(UIColor.lightText)
  static let darkText = Color(UIColor.darkText)
  static let placeholderText = Color(UIColor.placeholderText)

  // cassette Patch 016: redirect the SwiftUI bridge constants for system
  // foreground/background colors to the Cassette palette. SwiftUI views
  // throughout the project consume these names directly (Color.label,
  // Color.systemBackground, etc.); rebinding them here lets every Form/List
  // surface inherit the warm ink/bg tokens without per-call edits.

  // MARK: - Label Colors

  static let label = Color.cassette(.textPrimary)
  static let secondaryLabel = Color.cassette(.textSecondary)
  static let tertiaryLabel = Color.cassette(.textTertiary)
  static let quaternaryLabel = Color.cassette(.hairline)

  // MARK: - Background Colors

  static let systemBackground = Color.cassette(.surfaceBase)
  static let secondarySystemBackground = Color.cassette(.surfaceRaised)
  static let tertiarySystemBackground = Color.cassette(.surfaceElevated)

  // MARK: - Fill Colors

  static let systemFill = Color(UIColor.systemFill)
  static let secondarySystemFill = Color(UIColor.secondarySystemFill)
  static let tertiarySystemFill = Color(UIColor.tertiarySystemFill)
  static let quaternarySystemFill = Color(UIColor.quaternarySystemFill)

  // MARK: - Grouped Background Colors

  static let systemGroupedBackground = Color.cassette(.surfaceBase)
  static let secondarySystemGroupedBackground = Color.cassette(.surfaceRaised)
  static let tertiarySystemGroupedBackground = Color.cassette(.surfaceElevated)

  // MARK: - Gray Colors

  static let systemGray = Color(UIColor.systemGray)
  static let systemGray2 = Color(UIColor.systemGray2)
  static let systemGray3 = Color(UIColor.systemGray3)
  static let systemGray4 = Color(UIColor.systemGray4)
  static let systemGray5 = Color(UIColor.systemGray5)
  static let systemGray6 = Color(UIColor.systemGray6)

  // MARK: - Other Colors

  static let separator = Color(UIColor.separator)
  static let opaqueSeparator = Color(UIColor.opaqueSeparator)
  static let link = Color(UIColor.link)

  // MARK: System Colors

  static let systemBlue = Color(UIColor.systemBlue)
  static let systemPurple = Color(UIColor.systemPurple)
  static let systemGreen = Color(UIColor.systemGreen)
  static let systemYellow = Color(UIColor.systemYellow)
  static let systemOrange = Color(UIColor.systemOrange)
  static let systemPink = Color(UIColor.systemPink)
  static let systemRed = Color(UIColor.systemRed)
  static let systemTeal = Color(UIColor.systemTeal)
  static let systemIndigo = Color(UIColor.systemIndigo)
}

public func withPopupAnimation<Result>(_ body: () throws -> Result) rethrows -> Result {
  try withAnimation(.easeInOut(duration: 0.2)) {
    try body()
  }
}

extension View {
  var appDelegate: AppDelegate {
    (UIApplication.shared.delegate as! AppDelegate)
  }
}

extension UIColor {
  // cassette Patch 016: warm overlay tokens for popup-player slide-overs
  // and hover states, replacing the iOS system surface colours.
  static let slideOverBackgroundColor: UIColor = UIColor.cassette(.surfaceBase)
    .withAlphaComponent(0.5)
  static let hoveredBackgroundColor: UIColor = UIColor.cassette(.surfaceRaised)
    .withAlphaComponent(0.4)
}

extension UIButton.Configuration {
  /// cassette Patch 104 (Root 1): the app's quiet-icon recipe was
  /// `UIButton(type: .system)` + `.plain()`, written when plain meant
  /// *bare*. Compiled against the iOS 26 SDK, standard buttons pick up
  /// the system's default Liquid Glass capsule background, so "plain"
  /// buttons started leaking a faint rounded container (player heart,
  /// detail action bar, Library title dropdown). Every bare icon/text
  /// button routes through this factory so the opt-out lives in exactly
  /// one place: an explicitly cleared background configuration.
  static func cassetteBare() -> UIButton.Configuration {
    var config = UIButton.Configuration.plain()
    config.background = .clear()
    return config
  }

  static func player(isSelected: Bool) -> UIButton.Configuration {
    var config = UIButton.Configuration.tinted()
    if isSelected {
      config.background.strokeColor = UIColor.cassette(.fillSelected)
      config.background.strokeWidth = 1.0
      config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .medium)
    }
    config.buttonSize = .small
    config.baseForegroundColor = !isSelected ? UIColor.cassette(.textPrimary) : UIColor.cassette(.textOnFill)
    config.baseBackgroundColor = !isSelected ? .clear : UIColor.cassette(.fillSelected)
    config.cornerStyle = .medium
    return config
  }

  /// phone-taste: a quiet player toggle, a bare 20pt glyph in ink2 that lights in
  /// `onColor` when on (no filled square). `player(isSelected:)` stays as it is, so
  /// repeat and the queue toggle keep their look until a surface opts in.
  static func playerQuietToggle(isOn: Bool, onColor: UIColor) -> UIButton.Configuration {
    var config = UIButton.Configuration.cassetteBare()
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20)
    config.baseForegroundColor = isOn ? onColor : UIColor.cassette(.textSecondary)
    return config
  }

  /// Shuffle on the player: orange when on (live state, `.accentProgress`), quiet when off.
  static func playerShuffle(isOn: Bool) -> UIButton.Configuration {
    playerQuietToggle(isOn: isOn, onColor: UIColor.cassette(.accentProgress))
  }

  static func playerRound() -> UIButton.Configuration {
    var config = UIButton.Configuration.gray()
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .medium)
    config.buttonSize = .small
    return config
  }
}

extension UIView {
  static let forceTouchClickLimit: Float = 1.0

  func normalizedForce(touches: Set<UITouch>) -> Float? {
    guard is3DTouchAvailable, let touch = touches.first else { return nil }
    let maximumForce = touch.maximumPossibleForce
    let force = touch.force
    let normalizedForce = (force / maximumForce)
    return Float(normalizedForce)
  }

  func isForceClicked(_ touches: Set<UITouch>) -> Bool {
    guard let force = normalizedForce(touches: touches) else { return false }
    if force < UIView.forceTouchClickLimit {
      return false
    } else {
      return true
    }
  }

  var is3DTouchAvailable: Bool {
    forceTouchCapability() == .available
  }

  func forceTouchCapability() -> UIForceTouchCapability {
    UIApplication.shared.mainWindow?.rootViewController?.traitCollection
      .forceTouchCapability ?? .unknown
  }

  public func setBackgroundBlur(style: UIBlurEffect.Style, alpha: CGFloat = 1.0) {
    backgroundColor = UIColor.clear
    let blurEffect = UIBlurEffect(style: style)
    let blurEffectView = UIVisualEffectView(effect: blurEffect)
    blurEffectView.alpha = alpha
    blurEffectView.frame = bounds
    blurEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    insertSubview(blurEffectView, at: 0)
  }

  func addLeftSideBorder() {
    let separator = UIView()
    separator.backgroundColor = .separator
    addSubview(separator)
    separator.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      separator.widthAnchor.constraint(equalToConstant: 1),
      separator.leadingAnchor.constraint(equalTo: leadingAnchor),
      separator.topAnchor.constraint(equalTo: topAnchor),
      separator.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  func addTopSideBorder() {
    let separator = UIView()
    separator.backgroundColor = .separator
    addSubview(separator)
    separator.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      separator.heightAnchor.constraint(equalToConstant: 1),
      separator.leadingAnchor.constraint(equalTo: leadingAnchor),
      separator.topAnchor.constraint(equalTo: topAnchor),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }
}

extension UINavigationController {
  func replaceCurrentlyActiveVC(with vc: UIViewController, animated: Bool) {
    var vcs = viewControllers
    vcs = vcs.dropLast()
    vcs.append(vc)
    setViewControllers(vcs, animated: animated)
  }
}

extension UITableView {
  func register(nibName: String) {
    register(UINib(nibName: nibName, bundle: nil), forCellReuseIdentifier: nibName)
  }

  func dequeueCell<CellType: UITableViewCell>(
    for tableView: UITableView,
    at indexPath: IndexPath
  )
    -> CellType {
    guard let cell = dequeueReusableCell(
      withIdentifier: CellType.typeName,
      for: indexPath
    ) as? CellType else {
      os_log(.error, "The dequeued cell is not an instance of %s", CellType.typeName)
      return CellType()
    }
    return cell
  }

  func hasRowAt(indexPath: IndexPath) -> Bool {
    indexPath.section < numberOfSections && indexPath
      .row < numberOfRows(inSection: indexPath.section)
  }
}

extension UICollectionView {
  func hasItemAt(indexPath: IndexPath) -> Bool {
    indexPath.section < numberOfSections && indexPath
      .row < numberOfItems(inSection: indexPath.section)
  }
}

@MainActor
extension UITableViewController {
  func dequeueCell<CellType: UITableViewCell>(
    for tableView: UITableView,
    at indexPath: IndexPath
  )
    -> CellType {
    self.tableView.dequeueCell(for: tableView, at: indexPath)
  }

  func refreshAllVisibleCells() {
    let visibleIndexPaths = tableView.visibleCells.compactMap { tableView.indexPath(for: $0) }
    tableView.reconfigureRows(at: visibleIndexPaths)
  }

  func exectueAfterAnimation(body: @escaping () -> ()) {
    Task { @MainActor in
      body()
    }
  }
}

extension UIViewController {
  var typeName: String {
    Self.typeName
  }
}

extension NSObject {
  @MainActor
  var appDelegate: AppDelegate {
    (UIApplication.shared.delegate as! AppDelegate)
  }
}

extension UIApplication {
  var mainWindow: UIWindow? {
    let scenes = UIApplication.shared.connectedScenes
    for uiScene in scenes {
      if let windowScene = uiScene as? UIWindowScene {
        for window in windowScene.windows {
          if window.isKeyWindow {
            return window
          }
        }
      }
    }
    return nil
  }
}

extension UITraitCollection {
  static let maxDisplayScale = UITraitCollection(displayScale: 3.0)
}

extension UITableViewCell {
  func animateActivation() {
    UIView.animate(withDuration: 0.2, animations: {
      self.markAsFocused()
    }, completion: { _ in
      self.markAsFocused()
      UIView.animate(withDuration: 0.2, animations: {
        self.markAsUnfocused()
      }, completion: { _ in
        self.markAsUnfocused()
      })
    })
  }

  func markAsFocused() {
    backgroundColor = .systemGray4
  }

  func markAsUnfocused() {
    backgroundColor = .clear
  }
}

extension UICollectionViewCell {
  func animateActivation() {
    UIView.animate(withDuration: 0.2, animations: {
      self.markAsFocused()
    }, completion: { _ in
      self.markAsFocused()
      UIView.animate(withDuration: 0.2, animations: {
        self.markAsUnfocused()
      }, completion: { _ in
        self.markAsUnfocused()
      })
    })
  }

  func markAsFocused() {
    let focuseBackground = UIView(frame: bounds)
    focuseBackground.backgroundColor = .systemGray4
    backgroundView = focuseBackground
  }

  func markAsUnfocused() {
    backgroundView = nil
  }
}

extension UIMenu {
  /// rebuilds menu on every access
  static func lazyMenu(
    title: String = "",
    builder: @escaping () -> [UIMenuElement]
  )
    -> UIMenu {
    UIMenu(title: title, children: [
      UIDeferredMenuElement.uncached { completion in
        let actions = builder()
        completion(actions)
      },
    ])
  }
}

extension UICollectionViewLayout {
  static var verticalLayout: UICollectionViewFlowLayout {
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .vertical
    return layout
  }
}

extension UIDevice.BatteryState {
  public var description: String {
    switch self {
    case .unknown:
      return "unknown"
    case .unplugged:
      return "unplugged"
    case .charging:
      return "charging"
    case .full:
      return "full"
    @unknown default:
      return "@unknown default"
    }
  }
}

/// This fixes in swiftui mutliple picker views side by side to overlapp their touch areas
/// This is effective in addition to use .clipped() which only fixes the overlapping area visually
extension UIPickerView {
  open override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 150)
  }
}

extension Notification.Name {
  static let LibraryItemsChanged = Notification.Name("de.familie-zimba.Amperfy.LibraryItemsChanged")
}

extension UIViewController {
  @objc
  var sceneTitle: String? { nil }

  func extendSafeAreaToAccountForMiniPlayer() {
    guard let hostVC = AppDelegate.mainWindowHostVC else { return }
    additionalSafeAreaInsets = UIEdgeInsets(
      top: 0,
      left: 0,
      bottom: hostVC.getSafeAreaExtension(),
      right: 0
    )
  }
}

// MARK: - UIContentUnavailableConfiguration

/// cassette (BUG-419): one factory for every empty state on the phone. The
/// native container stays (it handles layout, scrolling and accessibility); the
/// type and the ink tiers come from here, so a Barlow title is never paired with
/// a system-footnote body again and the copy lives in one place.
extension UIContentUnavailableConfiguration {
  /// Stamps the Cassette type scale and ink tiers onto any configuration.
  mutating func applyCassetteType() {
    textProperties.font = UIFont.cassette(.sectionTitle)
    textProperties.color = UIColor.cassette(.textPrimary)
    secondaryTextProperties.font = UIFont.cassette(.body)
    secondaryTextProperties.color = UIColor.cassette(.textSecondary)
    imageProperties.tintColor = UIColor.cassette(.textTertiary)
  }

  /// An "empty" state: nothing to list yet.
  static func cassetteEmpty(
    image: UIImage?,
    title: String,
    body: String?
  )
    -> UIContentUnavailableConfiguration {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = image
    config.text = title
    config.secondaryText = body
    config.applyCassetteType()
    return config
  }

  /// A "no results" state for a search.
  static func cassetteNoResults(
    title: String = "No results",
    body: String? = "Try a different artist, album, or song."
  )
    -> UIContentUnavailableConfiguration {
    var config = UIContentUnavailableConfiguration.search()
    config.text = title
    config.secondaryText = body
    config.applyCassetteType()
    return config
  }

  /// The on-device library is empty: nothing has synced to this phone yet. The computer is
  /// the source of truth and the phone mirrors what was chosen to sync there; nothing is added
  /// on the web. The title alone (phone-taste: no explainer copy; I-W3, one line for "nothing
  /// synced yet" on Home and in the lists).
  @MainActor
  static var cassetteOnDeviceEmpty: UIContentUnavailableConfiguration {
    cassetteEmpty(image: .musicalNotes, title: "Nothing on this phone yet", body: nil)
  }

  /// A search of the on-device library found nothing. The title alone (phone-taste: no
  /// explainer copy). Shared by Search and the Songs, Artists and Albums list search.
  @MainActor
  static var cassetteOnDeviceNoResults: UIContentUnavailableConfiguration {
    cassetteNoResults(title: "No results on this phone", body: nil)
  }
}

// MARK: - OnPhoneContainable

/// phone-taste: an album, artist or playlist seen through the phone. Its `playables` are
/// only what this phone can play (OneTapPlay's rule, read once when it is made); everything
/// else is the container's own. A row's swipe hands this to `SwipeActionContext`, whose
/// queue and download cases read `containable.playables`, so a swipe on Search or a genre
/// page never queues a song that is not on the phone.
struct OnPhoneContainable: PlayableContainable {
  let base: PlayableContainable
  let playables: [AbstractPlayable]

  @MainActor
  init(_ base: PlayableContainable) {
    self.base = base
    self.playables = OneTapPlay.playables(of: base)
  }

  var id: String { base.id }
  var name: String { base.name }
  var subtitle: String? { base.subtitle }
  var subsubtitle: String? { base.subsubtitle }
  func infoDetails(for api: ServerApiType?, details: DetailInfoType) -> [String] {
    base.infoDetails(for: api, details: details)
  }

  func info(for api: ServerApiType?, details: DetailInfoType) -> String {
    base.info(for: api, details: details)
  }

  var playContextType: PlayerMode { base.playContextType }
  var account: Account? { base.account }
  var isRateable: Bool { base.isRateable }
  var isDownloadAvailable: Bool { base.isDownloadAvailable }
  @MainActor
  func getArtworkCollection(theme: ThemePreference) -> ArtworkCollection {
    base.getArtworkCollection(theme: theme)
  }

  @MainActor
  func fetchFromServer(
    storage: PersistentStorage,
    librarySyncer: LibrarySyncer,
    playableDownloadManager: DownloadManageable
  ) async throws {
    try await base.fetchFromServer(
      storage: storage,
      librarySyncer: librarySyncer,
      playableDownloadManager: playableDownloadManager
    )
  }

  var isFavoritable: Bool { base.isFavoritable }
  var isFavorite: Bool { base.isFavorite }
  @MainActor
  func remoteToggleFavorite(syncer: LibrarySyncer) async throws {
    try await base.remoteToggleFavorite(syncer: syncer)
  }

  func playedViaContext() { base.playedViaContext() }
  var containerIdentifier: PlayableContainerIdentifier { base.containerIdentifier }
}
