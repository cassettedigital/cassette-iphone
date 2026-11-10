//
//  PodcastEpisodeTableCell.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 25.06.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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

class PodcastEpisodeTableCell: BasicTableCell {
  @IBOutlet
  weak var podcastEpisodeLabel: UILabel!
  @IBOutlet
  weak var entityImage: EntityImageView!
  @IBOutlet
  weak var infoLabel: UILabel!
  @IBOutlet
  weak var descriptionLabel: UILabel!
  @IBOutlet
  weak var playEpisodeButton: UIButton!
  @IBOutlet
  weak var optionsButton: UIButton!
  @IBOutlet
  weak var showDescriptionButton: UIButton!
  @IBOutlet
  weak var cacheIconImage: UIImageView!
  @IBOutlet
  weak var playProgressBar: UIProgressView!
  @IBOutlet
  weak var playProgressLabel: UILabel!
  @IBOutlet
  weak var playProgressLabelPlayButtonDistance: NSLayoutConstraint!

  static let rowHeight: CGFloat = 143.0 + margin.bottom + margin.top

  private var episode: PodcastEpisode?
  /// Weak: a cell lives in its page, so a strong page here kept it in memory (BUG-447).
  private weak var rootView: UIViewController?
  // cassette Patch 054 (Phase I): PlayIndicator overlay deleted. Currently-
  // playing episode is indicated by `configurePlayEpisodeButton` clearing
  // the play button image and disabling it (see below); no extra overlay.

  override func awakeFromNib() {
    super.awakeFromNib()
    // cassette Patch 032: route through the canonical scale. Title is
    // rowTitle (16pt semibold display); info + description are metadata
    // (12pt medium mono); play progress is caption (12pt regular mono,
    // bumped from 11pt for the 12pt mono floor).
    MainActor.assumeIsolated {
      podcastEpisodeLabel.font = UIFont.cassette(.rowTitle)
      podcastEpisodeLabel.textColor = UIColor.cassette(.textPrimary)
      infoLabel.font = UIFont.cassette(.metadata)
      infoLabel.textColor = UIColor.cassette(.textSecondary)
      descriptionLabel.font = UIFont.cassette(.metadata)
      descriptionLabel.textColor = UIColor.cassette(.textSecondary)
      playProgressLabel.font = UIFont.cassette(.caption)
      playProgressLabel.textColor = UIColor.cassette(.textSecondary)
      // Wave 4: these took system tints and an 18pt system title from the XIB.
      CassetteIBStyle.plainButton(optionsButton, .textSecondary)
      CassetteIBStyle.plainButton(showDescriptionButton, .textSecondary)
      cacheIconImage.tintColor = UIColor.cassette(.textSecondary)
      contentView.backgroundColor = UIColor.cassette(.surfaceBase)
      backgroundColor = UIColor.cassette(.surfaceBase)
    }
  }

  func display(episode: PodcastEpisode, rootView: UIViewController) {
    self.episode = episode
    self.rootView = rootView
    optionsButton.showsMenuAsPrimaryAction = true
    optionsButton.menu = UIMenu.lazyMenu { EntityPreviewActionBuilder(
      container: episode,
      on: rootView,
      playContextCb: { () in PlayContext(containable: episode) }
    ).createMenuActions() }
    refresh()
  }

  func refresh() {
    guard let episode = episode else { return }
    // cassette Patch 054 (Phase I): PlayIndicator overlay deleted.
    // `configurePlayEpisodeButton` handles the playing/available/disabled
    // states directly; no overlay registration is required.
    configurePlayEpisodeButton()
    podcastEpisodeLabel.text = episode.title
    entityImage.display(
      theme: appDelegate.storage.settings.accounts.getSetting(episode.account?.info).read
        .themePreference,
      container: episode
    )

    infoLabel.text = "\(episode.publishDate.asShortDayMonthString)"
    descriptionLabel.text = episode.depiction ?? ""

    var progressText = ""
    if let remainingTime = episode.remainingTimeInSec,
       let playProgressPercent = episode.playProgressPercent {
      progressText = "\(remainingTime.asDurationString) left"
      playProgressBar.isHidden = false
      playProgressLabelPlayButtonDistance.constant = (2 * 8.0) + playProgressBar.frame.width
      playProgressBar.progress = playProgressPercent
    } else {
      progressText = "\(episode.duration.asDurationString)"
      playProgressBar.isHidden = true
      playProgressLabelPlayButtonDistance.constant = 8.0
    }
    if !episode.isAvailableToUser() {
      progressText += " \(CommonString.oneMiddleDot) \(episode.userStatus.description)"
    }
    playProgressLabel.text = progressText
    // cassette: the cache/cloud icon is gated to Server Mode (Navidrome native
    // streaming). In the default on-device-only experience the phone IS the
    // storage device, so "cached" is meaningless — keep the row clean. The icon
    // only surfaces in streaming mode, where it distinguishes cached episodes.
    let showCacheIcon = episode.isCached && !CassetteLibraryFilterProvider.shared.isOnDeviceOnly
    cacheIconImage.isHidden = !showCacheIcon
    playProgressLabel.textColor = UIColor.cassette(.textSecondary)
    backgroundColor = UIColor.cassette(.surfaceBase)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    // cassette Patch 054 (Phase I): PlayIndicator overlay deleted; nothing
    // to reset between reuses beyond what super already handles.
  }

  private func configurePlayEpisodeButton() {
    guard let episode = episode else { return }
    if episode == appDelegate.player.currentlyPlaying {
      playEpisodeButton.setImage(nil, for: .normal)
      playEpisodeButton.isEnabled = false
    } else if episode.isAvailableToUser() {
      playEpisodeButton.setImage(.play, for: .normal)
      playEpisodeButton.isEnabled = true
    } else {
      playEpisodeButton.setImage(.ban, for: .normal)
      playEpisodeButton.isEnabled = false
    }
  }

  @IBAction
  func playEpisodeButtonPressed(_ sender: Any) {
    guard let episode = episode else { return }
    appDelegate.player.play(context: PlayContext(containable: episode))
  }

  @IBAction
  func showDescriptionButtonPressed(_ sender: Any) {
    Haptics.light.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    guard let episode = episode, let rootView = rootView else { return }
    let showDescriptionVC = PlainDetailsVC()
    showDescriptionVC.display(podcastEpisode: episode, on: rootView)
    rootView.present(showDescriptionVC, animated: true)
  }
}
