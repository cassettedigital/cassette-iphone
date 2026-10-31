//
//  CommonScreenOperations.swift
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
import Foundation
import UIKit

extension UIView {
  static let defaultMarginX: CGFloat = 25
  static let defaultMarginY: CGFloat = 11
  static let defaultMarginTopElement = UIEdgeInsets(
    top: 0.0,
    left: UIView.defaultMarginX,
    bottom: 0.0,
    right: UIView.defaultMarginX
  )
  static let defaultMarginMiddleElement = UIEdgeInsets(
    top: UIView.defaultMarginY,
    left: UIView.defaultMarginX,
    bottom: UIView.defaultMarginY,
    right: UIView.defaultMarginX
  )
  static let defaultMarginCellX: CGFloat = 16
  static let defaultMarginCellY: CGFloat = 9
  static let defaultMarginCell = UIEdgeInsets(
    top: UIView.defaultMarginCellY,
    left: UIView.defaultMarginCellX,
    bottom: UIView.defaultMarginCellY,
    right: UIView.defaultMarginCellX
  )
}

// MARK: - CommonScreenOperations

class CommonScreenOperations {
  static let tableSectionHeightLarge: CGFloat = 40
  static let tableSectionHeightFooter: CGFloat = 8
}

// MARK: - CassetteMenuAvatar

/// The avatar menu's photo (phone-taste): a 30pt circle, fetched once per photo URL with one
/// fetch at a time (the menu is built for Home, Search and Library at launch, so each would
/// otherwise start its own). Until the photo is in, the menu shows the chosen disc or the
/// silhouette. Fold into the chip's fittedAvatarPhoto once the BUG-178 avatar work merges.
@MainActor
private enum CassetteMenuAvatar {
  static let side: CGFloat = 30
  private static var url: String?
  private static var photo: UIImage?
  private static var inFlight = false

  /// Start the photo fetch when the account's photo URL is new and nothing is in flight.
  static func prefetch() {
    let current = CassetteSyncAPI.accountImage
    if current != url {
      url = current
      photo = nil
    }
    guard let current, photo == nil, !inFlight, let remote = URL(string: current) else { return }
    inFlight = true
    Task {
      let data = try? await URLSession.shared.data(from: remote).0
      inFlight = false
      guard url == current, let data, let image = UIImage(data: data) else { return }
      photo = circle(image)
    }
  }

  /// The photo when it is in, else the disc or silhouette. Always `.alwaysOriginal`: a menu
  /// tints template images, which would turn an initials or emoji disc into a blob.
  static func image() -> UIImage {
    prefetch()
    if let photo { return photo }
    return UIViewController.cassetteAccountAvatarImage(size: side)
      .withRenderingMode(.alwaysOriginal)
  }

  /// The photo filled into a circle, rasterised at the point size.
  private static func circle(_ image: UIImage) -> UIImage {
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    let scale = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
    let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    return UIGraphicsImageRenderer(size: rect.size).image { _ in
      UIBezierPath(ovalIn: rect).addClip()
      image.draw(in: CGRect(
        x: (side - drawn.width) / 2,
        y: (side - drawn.height) / 2,
        width: drawn.width,
        height: drawn.height
      ))
    }.withRenderingMode(.alwaysOriginal)
  }
}

// MARK: - UIViewController

extension UIViewController {
  /// The avatar's menu, still Apple's UIMenu (phone-taste, 2026-10-21). Three inline groups:
  /// you on top (your name, the Mac's state under it, your avatar; a tap opens Settings),
  /// then the host's extras beside Settings (cassette Patch 035: today HomeVC's
  /// "Edit Home", so the other tabs sharing this menu stay clean), then Log Out on its own.
  private func createUserButtonMenu(
    extraLeadingMenuElements: [UIMenuElement] = []
  )
    -> UIMenu {
    var groups = [UIMenuElement]()

    // cassette: pairing binds ONE phone to ONE Cassette account, so there is no account
    // switcher and no "Add Account" (the multi-account plumbing stays for upstream parity).
    if appDelegate.storage.settings.accounts.active != nil {
      CassetteMenuAvatar.prefetch()
      // The Mac's heartbeat, so the first open has its state word. The tab roots build this
      // menu once at launch; the three share one request.
      Task { _ = await CassetteSyncStatus.refreshMacSummary(maxAge: 300) }
      // Deferred and uncached, so the Mac's state is read each time the menu opens; it
      // completes at once, so the menu never shows a loading row.
      let whoRow = UIDeferredMenuElement.uncached { [weak self] completion in
        guard let self else { completion([]); return }
        completion([cassetteWhoAction()])
      }
      groups.append(UIMenu(options: [.displayInline], children: [whoRow]))
    }

    let openSettings = UIAction(
      title: "Settings",
      image: .settings,
      handler: { [weak self] _ in
        self?.presentCassetteSettings()
      }
    )
    groups.append(UIMenu(
      options: [.displayInline],
      children: extraLeadingMenuElements + [openSettings]
    ))

    // Patch 111 (5): "Log Out" for the active account, reusing the shared teardown
    // (AppDelegate.logoutAccount) with a confirmation. Last, and apart.
    if let activeAccountInfo = appDelegate.storage.settings.accounts.active {
      let logoutAction = UIAction(
        title: "Sign Out",
        image: CassetteIcon.signOut.uiImage,
        attributes: .destructive,
        handler: { [weak self] _ in
          self?.confirmLogout(accountInfo: activeAccountInfo)
        }
      )
      groups.append(UIMenu(options: [.displayInline], children: [logoutAction]))
    }

    return UIMenu(
      title: "",
      image: nil,
      options: [.displayInline],
      children: groups
    )
  }

  /// The Settings sheet (a window on Mac Catalyst). The avatar menu's top row and its
  /// Settings row both open it.
  private func presentCassetteSettings() {
    #if targetEnvironment(macCatalyst)
      appDelegate.showSettings(sender: "")
    #else
      SupportSettingsView.rememberScreenBeforeSettings()
      let nav = AppStoryboard.Main.segueToSettings()
      nav.modalPresentationStyle = .formSheet
      nav.sheetPresentationController?.prefersGrabberVisible = true
      present(nav, animated: true)
    #endif
  }

  /// The avatar menu's top row: your name, "<Mac> · in sync / syncing / out of reach"
  /// under it (just the Mac's name until its heartbeat has been read), your own avatar, at
  /// full strength. Offline or signed out reads "out of reach": with no token the sync pass
  /// never runs, and without a network the Mac cannot be reached. A tap opens Settings.
  private func cassetteWhoAction() -> UIAction {
    let name = CassetteSyncAPI.accountName ?? CassetteSyncAPI.accountEmail ?? "You"
    let serverUrl = appDelegate.storage.settings.accounts.activeSetting.read
      .loginCredentials?.serverUrl
    let canSync = CassetteSyncAPI.bearerToken != nil
      && appDelegate.networkMonitor.isConnectedToNetwork
    let state = CassetteSyncStatus.macState(isPaired: serverUrl != nil, canSync: canSync)
    let line = CassetteSyncStatus.menuLine(
      hubName: CassetteSyncStatus.displayHubName(serverUrl: serverUrl),
      state: state
    )
    // The hub's heartbeat, fresh for the next open (one request at a time, at most one a
    // minute; never from the sync poll).
    Task { _ = await CassetteSyncStatus.refreshMacSummary(maxAge: 300) }
    let action = UIAction(
      title: name,
      image: CassetteMenuAvatar.image(),
      handler: { [weak self] _ in
        self?.presentCassetteSettings()
      }
    )
    action.subtitle = line
    return action
  }

  /// Patch 111 (5): confirm before logging out. The prompt is shared with Settings >
  /// Account and asks whether the music on this phone stays or goes; it used to name the
  /// hub's `cassette-*` machine login and claim every download would be deleted.
  private func confirmLogout(accountInfo: AccountInfo) {
    appDelegate.presentLogoutChoice(for: accountInfo)
  }

  public func setupUserNavButton(
    currentAccount: Account,
    userButton: inout UIButton?,
    userBarButtonItem: inout UIBarButtonItem?,
    extraLeadingMenuElements: [UIMenuElement] = []
  ) {
    // cassette: account avatar from /api/sync/account — photo when set, else
    // the chosen default (silhouette / initials / emoji). Silhouette is the
    // cream person.circle.fill glyph; web + Android match this mark.
    let size: CGFloat = {
      #if targetEnvironment(macCatalyst)
        return 50
      #else
        return 40
      #endif
    }()

    let button = UIButton(type: .custom)
    button.translatesAutoresizingMaskIntoConstraints = false
    // Pinned explicitly: iOS 26's glass toolbar lays out custom bar-button
    // views by intrinsic content size, and setImage() below can otherwise
    // re-inflate this chip to whatever the loaded image's raw size is.
    button.widthAnchor.constraint(equalToConstant: size).isActive = true
    button.heightAnchor.constraint(equalToConstant: size).isActive = true
    button.layer.cornerRadius = size / 2
    button.clipsToBounds = true
    button.setImage(Self.cassetteAccountAvatarImage(size: size), for: .normal)
    button.imageView?.contentMode = .scaleAspectFill
    button.contentHorizontalAlignment = .fill
    button.contentVerticalAlignment = .fill
    button.menu = createUserButtonMenu(extraLeadingMenuElements: extraLeadingMenuElements)
    button.showsMenuAsPrimaryAction = true
    userButton = button

    userBarButtonItem = UIBarButtonItem(customView: button)
    navigationItem.leftBarButtonItem = userBarButtonItem!

    // Photo loads async; swap in when ready so the chip updates without a relaunch.
    if let urlString = CassetteSyncAPI.accountImage, let url = URL(string: urlString) {
      Task { [weak button] in
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let photo = UIImage(data: data) else { return }
        await MainActor.run {
          button?.setImage(Self.fittedAvatarPhoto(photo, size: size), for: .normal)
        }
      }
    }

    // Repaint the chip in place when the account avatar changes on another device
    // (persistAccount posts this on a fresh /api/sync/account pull) — so a new
    // profile emoji picked on desktop shows here without a relaunch or navigation.
    // Only the persistent tab roots (Home / Library / Search) set this button up,
    // so the observer lives with a long-lived button rather than accumulating;
    // [weak button] simply no-ops if the button is ever gone.
    _ = NotificationCenter.default.addObserver(
      forName: .cassetteAccountAvatarChanged,
      object: nil,
      queue: .main
    ) { [weak button] _ in
      // Delivered on .main (queue: .main), so we are on the main actor at runtime.
      MainActor.assumeIsolated {
        guard let button else { return }
        button.setImage(Self.cassetteAccountAvatarImage(size: size), for: .normal)
        if let urlString = CassetteSyncAPI.accountImage, let url = URL(string: urlString) {
          Task { [weak button] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let photo = UIImage(data: data) else { return }
            await MainActor.run {
              button?.setImage(Self.fittedAvatarPhoto(photo, size: size), for: .normal)
            }
          }
        }
      }
    }
  }

  /// Render the cached account avatar (preset or silhouette). Photo is loaded
  /// separately once the URL resolves.
  static func cassetteAccountAvatarImage(size: CGFloat) -> UIImage {
    if CassetteSyncAPI.accountImage != nil {
      // Placeholder while the photo fetch lands — same silhouette as before.
      return silhouetteAvatar(size: size)
    }
    let preset = CassetteSyncAPI.accountAvatarPreset
    if preset == "initials" {
      let label = CassetteSyncAPI.accountName ?? CassetteSyncAPI.accountEmail ?? "?"
      let initials = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2))
        .uppercased()
      // Neutral grey disc — same family as the web IconButton key (--cs-bg3).
      return discAvatar(
        size: size,
        colors: [UIColor(red: 0.176, green: 0.157, blue: 0.125, alpha: 1)],
        text: initials.isEmpty ? "?" : initials,
        textColor: CassetteTheme.UIColors.ink
      )
    }
    if preset.hasPrefix("emoji:") {
      let emoji = String(preset.dropFirst("emoji:".count))
      if !emoji.isEmpty {
        return discAvatar(
          size: size,
          colors: [UIColor(red: 0.176, green: 0.157, blue: 0.125, alpha: 1)],
          text: emoji,
          textScale: 0.55,
          textColor: CassetteTheme.UIColors.ink
        )
      }
    }
    return silhouetteAvatar(size: size)
  }

  /// Crop-to-fill and rasterize a downloaded photo at the chip's exact point
  /// size. Avatar stickers are baked at a fixed 256x256px with no scale hint,
  /// so a raw `UIImage(data:)` reads as a 256-*point* image and inflates the
  /// button's intrinsic content size well past the intended 40/50pt chip —
  /// this is what balloons the nav chip under iOS 26's glass toolbar (BUG-178).
  private static func fittedAvatarPhoto(_ source: UIImage, size: CGFloat) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    return renderer.image { _ in
      let sourceSize = source.size
      guard sourceSize.width > 0, sourceSize.height > 0 else {
        source.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        return
      }
      let scale = max(size / sourceSize.width, size / sourceSize.height)
      let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
      let origin = CGPoint(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2)
      source.draw(in: CGRect(origin: origin, size: drawSize))
    }
  }

  private static func silhouetteAvatar(size: CGFloat) -> UIImage {
    UIImage.userCircle(withConfiguration: UIImage.SymbolConfiguration(
      pointSize: size * 0.6,
      weight: .regular
    )).withTintColor(
      CassetteTheme.UIColors.ink,
      renderingMode: .alwaysOriginal
    )
  }

  private static func discAvatar(
    size: CGFloat,
    colors: [UIColor],
    text: String? = nil,
    textScale: CGFloat = 0.38,
    textColor: UIColor = .white
  )
    -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    return renderer.image { ctx in
      let rect = CGRect(x: 0, y: 0, width: size, height: size)
      let path = UIBezierPath(ovalIn: rect)
      path.addClip()
      if colors.count >= 2 {
        let gradient = CGGradient(
          colorsSpace: CGColorSpaceCreateDeviceRGB(),
          colors: colors.map(\.cgColor) as CFArray,
          locations: [0, 1]
        )!
        ctx.cgContext.drawLinearGradient(
          gradient,
          start: .zero,
          end: CGPoint(x: size, y: size),
          options: []
        )
      } else {
        colors.first?.setFill()
        path.fill()
      }
      if let text {
        let attrs: [NSAttributedString.Key: Any] = [
          .font: UIFont.systemFont(ofSize: size * textScale, weight: .semibold),
          .foregroundColor: textColor,
        ]
        let drawn = text as NSString
        let textSize = drawn.size(withAttributes: attrs)
        drawn.draw(
          at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
          withAttributes: attrs
        )
      }
    }
  }
}

// MARK: - OneTapPlay

/// One tap on a cover plays it at once (phone-taste: "every cover plays in one tap").
/// The one shared way to start a record from a tile, a shelf, the Resume card's fallback
/// or a search result, so no surface queues music that is not on the phone.
///
/// "On this phone" means the DeviceOwnership set (what the hub synced here), NOT Amperfy's
/// `isCached` download cache: owned songs play from CassetteMusic and need not be cached.
@MainActor
enum OneTapPlay {
  /// `appDelegate` is an instance property on NSObject/View, so a static context asks the
  /// application for it.
  private static var delegate: AppDelegate {
    UIApplication.shared.delegate as! AppDelegate
  }

  /// What this phone can play now from `containable`, in container order. On-device mode
  /// keeps only the songs on this phone (other playables pass); Server Mode keeps
  /// everything, or only cached items while offline.
  static func playables(of containable: PlayableContainable) -> [AbstractPlayable] {
    playables(containable.playables)
  }

  /// The same rule for a list that is not a container (a mix, the Lately songs, the whole
  /// library), in list order. The one copy of it: CarPlay, the mood doors and Search's
  /// Shuffle all call this.
  static func playables(_ list: [AbstractPlayable]) -> [AbstractPlayable] {
    if CassetteLibraryFilterProvider.shared.isOnDeviceOnly {
      let owned = DeviceOwnershipManager(context: delegate.storage.main.context)
        .fetchAllSubsonicTrackIds()
      return list.filter { playable in
        guard let song = playable.asSong else { return true }
        return owned.contains(song.id)
      }
    }
    return list.filterCached(dependigOn: delegate.storage.settings.user.isOfflineMode)
  }

  /// Plays `containable` now: an album from the top, an artist shuffled, a playlist (and
  /// anything else) in order. Does nothing and returns false when nothing of it is on the
  /// phone. A light haptic marks the start.
  @discardableResult
  static func play(_ containable: PlayableContainable) -> Bool {
    let list = playables(of: containable)
    guard !list.isEmpty else { return false }
    let context = PlayContext(containable: containable, index: 0, playables: list)
    if containable is Artist {
      delegate.player.playShuffled(context: context)
    } else {
      delegate.player.play(context: context)
    }
    Haptics.light.vibrate(isHapticsEnabled: delegate.storage.settings.user.isHapticsEnabled)
    return true
  }

  /// Plays `containable` from `song` when the phone can play it there, else as `play` does.
  /// One Home: Resume picks a record up at the song it was on, on whichever device.
  @discardableResult
  static func play(_ containable: PlayableContainable, startingAt song: AbstractPlayable?) -> Bool {
    let list = playables(of: containable)
    guard let song, !(containable is Artist),
          let index = list.firstIndex(where: { $0.id == song.id }), index > 0
    else { return play(containable) }
    delegate.player.play(context: PlayContext(containable: containable, index: index, playables: list))
    Haptics.light.vibrate(isHapticsEnabled: delegate.storage.settings.user.isHapticsEnabled)
    return true
  }
}
