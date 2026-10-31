//
//  PopupPlayer+Visuals.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 11.02.24.
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
import SwiftUI
import UIKit

extension PopupPlayerVC {
  func refresh() {
    // a station starting or ending moves the sheet between its cover and the person's choice
    if let shown = shownDisplayStyle, shown != effectiveDisplayStyle {
      changeDisplayStyleVisually(to: effectiveDisplayStyle, animated: true)
      shownDisplayStyle = effectiveDisplayStyle
    }
    refreshContextQueueSectionHeader()
    refreshUserQueueSectionHeader()
    refreshCellMasks()
    refreshCellsContent()
    refreshCurrentlyPlayingInfoView()
  }

  func refreshCurrentlyPlayingInfoView() {
    refreshBackgroundItemArtwork()
    largeCurrentlyPlayingView?.refresh()
    for visibleCell in tableView.visibleCells {
      if let currentlyPlayingCell = visibleCell as? CurrentlyPlayingTableCell {
        currentlyPlayingCell.refresh()
        break
      }
    }
  }

  /// Patch 113: optimistic now-playing refresh fired from a next/prev tap.
  /// Updates only the hero title/artist/cover from the just-advanced queue
  /// item (cover via LibraryEntityImage — cache hit or placeholder + async
  /// swap, never blocking on a decode). Deliberately NOT the ambient backdrop
  /// or the lockscreen (those reconcile on the trailing didStartPlaying), so
  /// the tap is never blocked by an on-disk artwork decode.
  func optimisticallyRefreshNowPlaying() {
    largeCurrentlyPlayingView?.refresh()
  }

  func refreshCurrentlyPlayingArtworks() {
    refreshBackgroundItemArtwork()
    largeCurrentlyPlayingView?.refreshArtwork()
    for visibleCell in tableView.visibleCells {
      if let currentlyPlayingCell = visibleCell as? CurrentlyPlayingTableCell {
        currentlyPlayingCell.refreshArtwork()
        break
      }
    }
  }

  func refreshOptionButton(button: UIButton, rootView: UIViewController?) {
    // phone-taste: the ••• is the mock's dark glass circle (.glassBtn): 44pt (the nibs size
    // it), a translucent bg4 fill, a faint ink ring and a 20pt ink ellipsis. It is our own
    // fill on cassetteBare(), not iOS 26's system glass, which Patch 104 opted out of. The
    // stand-in button in the style-switch animation comes through here too, so it matches.
    var config = UIButton.Configuration.cassetteBare()
    config.image = CassetteIcon.more.symbolImage
    config.baseForegroundColor = UIColor.cassette(.textPrimary)
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 20,
      weight: .regular
    )
    config.background.backgroundColor = UIColor.cassette(.surfaceSunken).withAlphaComponent(0.55)
    config.background.strokeColor = UIColor.cassette(.textPrimary).withAlphaComponent(0.08)
    config.background.strokeWidth = 1
    config.cornerStyle = .capsule
    config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    button.isEnabled = true
    button.configuration = config

    if let currentlyPlaying = appDelegate.player.currentlyPlaying,
       let rootView = rootView {
      button.showsMenuAsPrimaryAction = true
      button.menu = UIMenu.lazyMenu {
        var actions: [UIMenuElement] = EntityPreviewActionBuilder(
          container: currentlyPlaying,
          on: rootView
        ).createMenuActions()
        // cassette §E: Equalizer entry — present only when EQ is enabled.
        // Opens the now-playing EQ panel as a slide-up sheet over the cover.
        // Routed through `rootView` (the player VC) to avoid implicit self
        // capture in this escaping menu closure.
        if rootView.appDelegate.storage.settings.user.isEqualizerEnabled {
          let eqAction = UIAction(
            title: "Equalizer",
            image: CassetteIcon.adjust.uiImage
          ) { [weak rootView] _ in
            (rootView as? PopupPlayerVC)?.presentEqualizerPanel()
          }
          actions.insert(eqAction, at: 0)
        }
        // cassette 2026-10-21: on the radio, when the song on air matched a record on
        // Cassette, the first item goes to that record, without leaving the app: the
        // person's own copy when they have it, else the record's page (RecordOpener),
        // shown in the Library tab with the player closed and the station still playing.
        if (rootView as? PopupPlayerVC)?.radioAlbumSlug != nil {
          actions.insert(UIAction(title: "Go to Album", image: CassetteIcon.album.uiImage) { [weak rootView] _ in
            MainActor.assumeIsolated { (rootView as? PopupPlayerVC)?.openRadioAlbum() }
          }, at: 0)
        }
        return actions
      }
      button.isEnabled = true
    } else {
      button.isEnabled = false
    }
  }

  // cassette §E: present the now-playing Equalizer panel. Slides up over the
  // player as a sheet, reusing this VC's ambient-backlight model so the panel
  // shares the same dim-room backdrop and the cover glows behind it.
  func presentEqualizerPanel() {
    let panel = EqualizerPanelView(ambientModel: ambientBackdropModel) { [weak self] in
      self?.dismiss(animated: true)
    }
    let host = UIHostingController(rootView: panel)
    host.view.backgroundColor = UIColor.cassette(.surfaceSunken)
    host.overrideUserInterfaceStyle = .dark
    if let sheet = host.sheetPresentationController {
      sheet.detents = [.large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28
    }
    present(host, animated: true)
  }

  /// cassette Patch 029: the popup-player background is now a flat
  /// `bg4` surface set on the host view in `PopupPlayerVC.viewDidLoad`.
  /// The blurred album-art layer + `DominantColors`-driven gradient
  /// (Patches 022/024) produced a persistently blue backdrop that
  /// clashed with the orange controls; the audit calls for stripping
  /// the album-art layer entirely. This method is intentionally a
  /// no-op so the existing `refreshCurrentlyPlayingArtworks` /
  /// `downloadFinishedSuccessful` call sites stay valid without
  /// repopulating the backdrop.
  func refreshBackgroundItemArtwork() {
    backgroundImage.image = nil
    backgroundImage.layer.sublayers?
      .filter { $0 is CAGradientLayer }
      .forEach { $0.removeFromSuperlayer() }

    // Patch 112: feed the ambient backlight. One path for cover + placeholder.
    // The cache key flips to the artwork file path only once that file exists,
    // so a backdrop that started as the placeholder cross-fades to the real
    // cover when the download lands (downloadFinishedSuccessful re-invokes
    // this).
    guard let playable = player.currentlyPlaying else {
      ambientBackdropModel.image = nil
      ambientBackdropModel.coverID = "ambient-placeholder"
      updateCoverTint(.neutral)
      return
    }
    let setting = appDelegate.storage.settings.accounts.getSetting(playable.account?.info).read
    let artworkPath = playable.imagePath(setting: setting.artworkDisplayPreference)
    let hasCover = artworkPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
    ambientBackdropModel.isPlaying = player.isPlaying

    // cassette 2026-10-21: a station glows like a record. What the cloud says is on wears
    // its picture (the record, else the show's), so the glow follows it; with nothing from
    // the cloud and no logo on the hub, the station's own mark (or its word picture) glows
    // instead of the generic placeholder.
    if let radio = playable.asRadio {
      let liveArt = player.currentRadioArtwork
      if liveArt != nil || !hasCover {
        let art: UIImage
        let key: String
        if let liveArt {
          art = liveArt
          key = "radio-live:\(player.currentRadioLive?.artworkURL ?? radio.id)"
        } else {
          let mark = RadioMark.image(for: radio) { [weak self] in self?.refreshBackgroundItemArtwork() }
          art = mark.image
          key = "radio-\(mark.key)"
        }
        guard ambientBackdropModel.coverID != key else { return }
        Task { @MainActor [weak self] in
          let tint = await CoverTint.resolve(image: art, key: key)
          guard let self, player.currentlyPlaying?.id == radio.id else { return }
          ambientBackdropModel.image = art
          ambientBackdropModel.coverID = key
          updateCoverTint(tint)
        }
        return
      }
    }

    if hasCover, let artworkPath {
      // phone-taste: the glow's key is the foundation's cover key (the path plus the file's
      // date), the one the record pages' glows use, so the blurred tiny is shared and a
      // cover replaced at the same path redraws the glow too.
      let coverID = CoverTint.cacheKey(forCoverPath: artworkPath)
      // cassette: decode the cover OFF the main thread as a capped-size
      // thumbnail (an oversized cover can't block popup-open or starve audio),
      // then feed image + coverID TOGETHER. AmbientCoverBackdrop's
      // `.task(id: coverID)` regenerates the blurred backdrop from model.image,
      // and it only re-fires when coverID CHANGES — so coverID must flip in the
      // same step the image lands. (Task 2 set coverID synchronously while the
      // image arrived later, so the task ran with a nil image and the soft blur
      // never came back.) The downsample + blur still run off-main (Patch 114).
      Task { @MainActor [weak self] in
        let thumb = await Task.detached(priority: .utility) {
          AmbientSourceDecoder.thumbnail(contentsOfFile: artworkPath, maxPixelSize: 600)
        }.value
        guard let thumb else { return }
        // phone-taste: the record's colour comes from the foundation, keyed and read the
        // same way on every lit surface (CoverTint.cacheKey: the cover path plus the file's
        // date, so a cover replaced at the same path is read again), so Now Playing and
        // the album page agree on one colour per record.
        let tint = await CoverTint.resolve(coverPath: artworkPath) ?? .neutral
        guard let self else { return }
        // Staleness guard: only apply if the live track's cover is still this
        // one (a newer track may have started while we decoded).
        let currentPath = player.currentlyPlaying.flatMap { current -> String? in
          let s = self.appDelegate.storage.settings.accounts
            .getSetting(current.account?.info).read
          return current.imagePath(setting: s.artworkDisplayPreference)
        }
        guard currentPath == artworkPath else { return }
        ambientBackdropModel.image = thumb
        ambientBackdropModel.coverID = coverID
        updateCoverTint(tint)
      }
    } else {
      // No cover on disk → the on-brand generated placeholder is in-memory and
      // cheap; set image + coverID together synchronously.
      ambientBackdropModel.image = LibraryEntityImage.getImageToDisplayImmediately(
        libraryEntity: playable,
        themePreference: setting.themePreference,
        artworkDisplayPreference: setting.artworkDisplayPreference,
        useCache: true
      )
      ambientBackdropModel.coverID = "ambient-placeholder"
      // phone-taste: the generated tile is not the record, so its colour is never read.
      updateCoverTint(.neutral)
    }
  }

  /// cassette Patch 029: the host view paints a flat `bg4` backdrop in
  /// `PopupPlayerVC.viewDidLoad`. Patch 024's gradient layer is gone, so
  /// this method only needs to clear any stale gradient sublayers that
  /// might have been installed before the migration.
  func applyGradientBackground() {
    view.backgroundColor = UIColor.cassette(.surfaceSunken)
    view.layer.sublayers?
      .filter { $0 is CAGradientLayer }
      .forEach { $0.removeFromSuperlayer() }
  }

  @objc
  internal func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification),
          let curPlayable = player.currentlyPlaying
    else { return }
    // cassette: the backdrop is blurred from the ALBUM-first cover, whose artwork
    // is a distinct Core Data row from the song's own — so an owned-album cover
    // backfill (its notification carries the album artwork id) was missed by both
    // checks and the backdrop stayed on the old/placeholder cover until the next
    // track. Match the album artwork id too, mirroring the C09 lock-screen patch
    // and the in-app LibraryEntityImage handler.
    if curPlayable.uniqueID == downloadNotification.id
      || curPlayable.artwork?.uniqueID == downloadNotification.id
      || curPlayable.asSong?.album?.artwork?.uniqueID == downloadNotification.id {
      Task { @MainActor in
        refreshBackgroundItemArtwork()
      }
    }
  }

  func adjustLayoutMargins() {
    view.layoutMargins = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
  }
}
