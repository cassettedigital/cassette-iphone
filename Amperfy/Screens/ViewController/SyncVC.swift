//
//  SyncVC.swift
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

// MARK: - SyncVC

class SyncVC: UIViewController {
  var state: ParsedObjectType = .genre
  var parsedObjectCount: Int = 0
  var parsedObjectPercent: Float = 0.0
  var libObjectsToParseCount: Int = 1
  var syncFinished = false
  var account: Account!

  /// One plain line for every stage of the first read. Amperfy listed its own categories
  /// ("Syncing genres ...", "Syncing podcasts ..."), most of which a Cassette phone never has.
  static let readingLibraryText = "Reading your library from your computer"

  @IBOutlet
  weak var progressBar: UIProgressView!
  @IBOutlet
  weak var progressLabel: UILabel!
  @IBOutlet
  weak var progressInfo: UILabel!
  @IBOutlet
  weak var activitySpinner: UIActivityIndicatorView!
  @IBOutlet
  weak var skipButton: BasicButton!

  override func viewDidLoad() {
    super.viewDidLoad()
    applyCassetteStyle()
    progressBar.setProgress(0.0, animated: true)
    progressInfo.text = ""
    progressLabel.text = String(format: "%.1f", 0.0) + "%"
    appDelegate.isKeepScreenAlive = true
  }

  /// Wave 4: the storyboard holds layout only. This screen was stock iOS: system type in
  /// white, a pure black root and a system-blue button.
  private func applyCassetteStyle() {
    CassetteIBStyle.screen(view)
    CassetteIBStyle.label(progressLabel, .metadata, .textSecondary)
    CassetteIBStyle.label(progressInfo, .body, .textSecondary)
    CassetteIBStyle.progress(progressBar)
    CassetteIBStyle.spinner(activitySpinner)
    CassetteIBStyle.filledButton(skipButton)
    // The heading ("Syncing" / "Updating") has no outlet.
    for label in view.cassetteStandaloneLabels
      where label !== progressLabel && label !== progressInfo {
      CassetteIBStyle.label(label, .heroTitle, .textPrimary)
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    Task { @MainActor in
      self.appDelegate.eventLogger.supressAlerts = true
      if self.appDelegate.storage.settings.accounts.allAccounts.count <= 1 {
        self.appDelegate.storage.settings.app.isLibrarySynced = false
      }
      self.appDelegate.storage.main.library.cleanStorageOfObsoleteAccountEntries(account: account)

      do {
        try await self.appDelegate.getMeta(account.info).librarySyncer
          .syncInitial(statusNotifyier: self)
        self.appDelegate.storage.settings.accounts.updateSetting(account.info) { accountSettings in
          accountSettings.initialSyncCompletionStatus = .completed
        }
      } catch {
        guard !self.syncFinished else { return }
        self.appDelegate.eventLogger.report(
          topic: "Initial Sync",
          error: error,
          displayPopup: false
        )
        self.appDelegate.storage.settings.accounts.updateSetting(account.info) { accountSettings in
          accountSettings.initialSyncCompletionStatus = .aborted
        }
      }
      self.finishSync()
    }
  }

  private func finishSync() {
    guard !syncFinished else { return }

    syncFinished = true
    progressInfo.text = "Done"
    activitySpinner.stopAnimating()
    activitySpinner.isHidden = true
    progressLabel.isHidden = true

    appDelegate.storage.settings.app.librarySyncVersion = .newestVersion
    appDelegate.storage.settings.app.isLibrarySynced = true
    appDelegate.startManagerAfterSync()
    appDelegate.getMeta(account.info).startManagerAfterSync(player: appDelegate.player)
    appDelegate.isKeepScreenAlive = false
    appDelegate.eventLogger.supressAlerts = false

    // cassette Patch 052 (Phase G): post-sync theme re-apply pins to ink
    // explicitly. ThemePreference.asColor resolves to ink after Patch 046
    // but pinning removes the per-account lookup on a one-shot launch path.
    appDelegate.setAppTheme(color: UIColor.cassette(.textPrimary))
    appDelegate.applyAppThemeToAlreadyLoadedViews()
    guard let mainScene = AppDelegate.mainSceneDelegate else { return }
    mainScene
      .replaceMainRootViewController(vc: AppStoryboard.Main.segueToMainWindow(account: account))
  }

  private func updateSyncInfo(infoText: String? = nil, percentParsed: Float = 0.0) {
    if let infoText = infoText {
      progressInfo.text = infoText
    }
    progressBar.setProgress(percentParsed, animated: percentParsed != 0.0)
    progressLabel.text = String(format: "%.1f", percentParsed * 100) + "%"
  }

  @IBAction
  func skipPressed(_ sender: Any) {
    let alert = UIAlertController(
      title: "Skip Sync",
      message: "Skipping now leaves part of your library off this \(UIDevice.cassetteDeviceWord) until the next sync.",
      preferredStyle: .alert
    )
    let skip = UIAlertAction(title: "Skip", style: .destructive, handler: { action in
      self.appDelegate.storage.settings.accounts
        .updateSetting(self.account.info) { accountSettings in
          accountSettings.initialSyncCompletionStatus = .skipped
        }
      self.finishSync()
    })
    let cancel = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
    alert.addAction(skip)
    alert.addAction(cancel)
    present(alert, animated: true, completion: nil)
  }
}

// MARK: SyncCallbacks

extension SyncVC: SyncCallbacks {
  nonisolated func notifyParsedObject(ofType parsedObjectType: ParsedObjectType) {
    Task { @MainActor in
      guard parsedObjectType == state else {
        return
      }
      self.parsedObjectCount += 1

      var parsePercent: Float = 0.0
      if self.libObjectsToParseCount > 0 {
        parsePercent = min(Float(self.parsedObjectCount) / Float(self.libObjectsToParseCount), 1.0)
      }
      let percentDiff = Int(parsePercent * 1000) - Int(self.parsedObjectPercent * 1000)
      if percentDiff > 0 {
        self.updateSyncInfo(percentParsed: parsePercent)
      }
      self.parsedObjectPercent = parsePercent
    }
  }

  nonisolated func notifySyncStarted(ofType parsedObjectType: ParsedObjectType, totalCount: Int) {
    Task { @MainActor in
      self.parsedObjectCount = 0
      self.parsedObjectPercent = 0.0
      self.state = parsedObjectType
      self.libObjectsToParseCount = totalCount > 0 ? totalCount : 1

      if totalCount > 0 {
        activitySpinner.stopAnimating()
        activitySpinner.isHidden = true
      } else {
        activitySpinner.startAnimating()
        activitySpinner.isHidden = false
      }
      progressLabel.isHidden = totalCount <= 0

      self.updateSyncInfo(infoText: Self.readingLibraryText, percentParsed: 0.0)
    }
  }
}
