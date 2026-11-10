//
//  LibrarySettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 15.09.22.
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
import SwiftUI

// MARK: - StorageSettingsView

// cassette §G: the "Storage" screen (file name kept as LibrarySettingsView.swift
// to avoid .pbxproj churn — rename deferred). Cache/cached wording is replaced
// with download/storage language to match the on-device ethos; podcast rows are
// dropped (not a Cassette feature).
struct StorageSettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
  let fileManager = CacheFileManager.shared

  @State
  var playlistCount = 0
  @State
  var artistCount = 0
  @State
  var albumCount = 0
  @State
  var songCount = 0
  @State
  var podcastCount = 0
  @State
  var podcastEpisodeCount = 0
  @State
  var albumWithSyncedSongsCount = 0
  @State
  var cachedSongCount = 0
  @State
  var cachedPodcastEpisodesCount = 0
  @State
  var completeCacheSize = ""
  /// On this phone: the music synced from the hub (ownership records), not Amperfy's cache.
  @State
  var onPhoneMusic = ""
  @State
  var onPhoneAlbums: [DeviceOwnershipManager.OnPhoneAlbum] = []
  @State
  var freeSpace = ""
  @State
  var cacheSizeLimit = ""
  @State
  var cacheSelection = ["0", " MB"]
  @State
  var autoSyncProgressText = ""

  @State
  var isShowDeleteCacheAlert = false
  @State
  var isShowDownloadSongsAlert = false

  let byteValues = (
    stride(from: 0, through: 20, by: 1).map { $0.description } +
      stride(from: 25, through: 50, by: 5).map { $0.description } +
      stride(from: 60, through: 100, by: 10).map { $0.description } +
      stride(from: 110, through: 975, by: 25).map { $0.description }
  )

  private func updateValues() {
    Task { @MainActor in do {
      guard let activeAccountInfo = settings.activeAccountInfo else { return }
      let accountObjectId = appDelegate.storage.main.library
        .getAccount(info: activeAccountInfo).managedObject.objectID
      playlistCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getPlaylistCount(for: accountAsync)
      }
      artistCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getArtistCount(for: accountAsync)
      }
      albumCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getAlbumCount(for: accountAsync)
      }
      podcastCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getPodcastCount(for: accountAsync)
      }
      podcastEpisodeCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getPodcastEpisodeCount(for: accountAsync)
      }
      songCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getSongCount(for: accountAsync)
      }
      albumWithSyncedSongsCount = try await appDelegate.storage.async
        .performAndGet { asyncCompanion in
          let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
          return asyncCompanion.library.getAlbumWithSyncedSongsCount(for: accountAsync)
        }

      if albumCount < 1 {
        autoSyncProgressText = String(format: "%.1f", 0.0) + "%"
      } else {
        let progress = Float(albumWithSyncedSongsCount) * 100.0 / Float(albumCount)
        autoSyncProgressText = String(format: "%.1f", progress) + "%"
      }

      cachedSongCount = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        return asyncCompanion.library.getCachedSongCount(for: accountAsync)
      }
      cachedPodcastEpisodesCount = try await appDelegate.storage.async
        .performAndGet { asyncCompanion in
          let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
          return asyncCompanion.library.getCachedPodcastEpisodeCount(for: accountAsync)
        }
      completeCacheSize = try await appDelegate.storage.async.performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
        let playableByteSize = fileManager.getPlayableCacheSize(for: accountAsync.info)
        return (playableByteSize > 1_000_000) ? playableByteSize.asByteString : Int64(0)
          .asByteString
      }

      let curCacheSizeLimit = Int64(settings.cacheSizeLimit)
      cacheSizeLimit = curCacheSizeLimit > 0 ? curCacheSizeLimit.asByteString : "No Limit"
      cacheSelection = curCacheSizeLimit > 0 ? [
        curCacheSizeLimit.asByteString.components(separatedBy: " ")[0],
        " " + curCacheSizeLimit.asByteString.components(separatedBy: " ")[1]
      ] : ["0", " MB"]
    } catch {
      // do nothing
    }}
  }

  /// Once per visit, not on the 1s timer: it walks every ownership record.
  private func refreshOnPhone() {
    let summary = DeviceOwnershipManager(context: appDelegate.storage.main.context).onPhoneSummary()
    onPhoneMusic = summary.tracks == 0
      ? "Nothing yet"
      : "\(summary.bytes.asByteString) · \(summary.tracks) song\(summary.tracks == 1 ? "" : "s")"
    onPhoneAlbums = summary.albums
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage ?? 0
    freeSpace = free > 0 ? free.asByteString : ""
  }

  var body: some View {
    ZStack {
      SettingsList {
        SettingsSection(content: {
          SettingsRow(title: "Playlists") {
            SecondaryText(playlistCount.description)
          }
          SettingsRow(title: "Artists") {
            SecondaryText(artistCount.description)
          }
          SettingsRow(title: "Albums") {
            SecondaryText(albumCount.description)
          }
          SettingsRow(title: "Songs") {
            SecondaryText(songCount.description)
          }
        })

        // cassette (UX pass 2026-10-20): "On this phone" reads the music the hub synced
        // here (CassetteMusic, via the ownership records). The old "Downloaded songs" /
        // "Storage used" rows read Amperfy's per-account cache, which Cassette music does
        // not live in, so on an on-device phone they said almost nothing.
        SettingsSection(content: {
          SettingsRow(title: "Music") { SecondaryText(onPhoneMusic) }
          SettingsRow(title: "Free on this phone") { SecondaryText(freeSpace) }
          if !CassetteLibraryFilterProvider.shared.isOnDeviceOnly {
            SettingsRow(title: "Kept from streaming") {
              SecondaryText(completeCacheSize.description)
            }
          }
        }, footer: "Choose what syncs to this phone in Cassette on your computer.", header: "On this phone")

        if !onPhoneAlbums.isEmpty {
          SettingsSection(content: {
            ForEach(onPhoneAlbums) { album in
              SettingsRow(title: album.name, orientation: .vertical) {
                SecondaryText(
                  [album.artist, "\(album.tracks) song\(album.tracks == 1 ? "" : "s")",
                   album.bytes.asByteString]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                )
              }
            }
          }, header: "Albums on this \(UIDevice.cassetteDeviceWord)")
        }
      }
    }
    .navigationTitle("Storage")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      updateValues()
      refreshOnPhone()
      appDelegate.userStatistics.visited(.settingsLibrary)
    }
    .onReceive(timer) { _ in
      updateValues()
    }
    .onDisappear {
      timer.upstream.connect().cancel()
    }
  }
}

// MARK: - StorageSettingsView_Previews

struct StorageSettingsView_Previews: PreviewProvider {
  @State
  static var settings = Settings()

  static var previews: some View {
    StorageSettingsView().environmentObject(settings)
  }
}
