//
//  CassetteTransferSession.swift
//  AmperfyKit
//
//  Cassette fork — Layer 3 Phase 3.1 (Transfer Mechanism).
//
//  Owns the single background URLSession ("digital.cassette.transfers") that
//  pulls owned files from the user's Cassette Player over the LAN. Wi-Fi only,
//  resumes across app relaunches. On completion it moves the file into
//  CassetteMusic/, records a DeviceOwnershipMO row, and reports the addition
//  to cassette.digital's device inventory.
//
//  Per-download metadata is stored in the task's `taskDescription` (a JSON
//  blob). The system restores background tasks — including their
//  taskDescription — when it relaunches the app to deliver completions, so no
//  separate sidecar file is needed to survive a cold launch.
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

import CoreData
import Foundation
import os.log
import UIKit

// MARK: - CassetteTransferMetadata

/// Stored in the download task's taskDescription so it survives a cold launch.
struct CassetteTransferMetadata: Codable {
  let cassetteLocalId: String
  let mbid: String?
  let subsonicTrackId: String?
  let ext: String
  let intentId: String
  /// A refresh's new fingerprint, stamped only once the new copy has landed (BUG-882).
  /// Absent on adds and on tasks restored from before it existed.
  var contentFingerprint: String?
}

// MARK: - CassetteTransferSession

public final class CassetteTransferSession: NSObject, @unchecked Sendable {
  public static let shared = CassetteTransferSession()

  public static let backgroundIdentifier = "digital.cassette.transfers"

  private let log = OSLog(subsystem: "Amperfy", category: "CassetteTransferSession")
  private let fileStorage = CassetteFileStorage.shared
  private let syncAPI = CassetteSyncAPI.shared

  // Stored background-events completion handler (set by the AppDelegate).
  private var backgroundCompletionHandler: (() -> ())?

  // In-memory guard against double-enqueueing the same track within a run.
  private let inFlightLock = NSLock()
  private var inFlightLocalIds = Set<String>()

  // cassette: batch the post-download ownership write + inventory report. Each
  // finished file appends here; a debounced flush records all ownership rows in
  // ONE off-main save and sends ONE (chunked) inventory POST — instead of N
  // main-thread Core Data saves + N POSTs during the burst (which starved the
  // Home carousels' main-thread work and flooded the log). `pendingAdditions`
  // is guarded by `pendingLock`; `flushWorkItem` is only touched on the main queue.
  private let pendingLock = NSLock()
  private var pendingAdditions: [(meta: CassetteTransferMetadata, downloadedAt: Date)] = []
  private var flushWorkItem: DispatchWorkItem?
  private let flushDebounceInterval: TimeInterval = 0.4
  private static let maxInventoryPerRequest = 5000 // matches server MAX_INVENTORY_PER_REQUEST

  private lazy var session: URLSession = {
    let config = URLSessionConfiguration
      .background(withIdentifier: Self.backgroundIdentifier)
    config.allowsCellularAccess = false // Wi-Fi only (acceptance criterion)
    config.isDiscretionary = false // start as soon as possible
    config.sessionSendsLaunchEvents = true // wake the app on completion
    config.waitsForConnectivity = true // auto-resume when network returns

    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return URLSession(configuration: config, delegate: self, delegateQueue: queue)
  }()

  override private init() {
    super.init()
    // Touch the session so iOS reconnects to any restored background tasks.
    _ = session
  }

  // MARK: - Enqueue

  /// Enqueue a background download. No-op if the same track is already
  /// in-flight (including tasks restored after a relaunch).
  public func enqueueDownload(
    url: URL,
    cassetteLocalId: String,
    mbid: String?,
    subsonicTrackId: String?,
    fileExtension ext: String,
    intentId: String,
    contentFingerprint: String? = nil
  ) async {
    // Skip if a task for this track already exists.
    if await isAlreadyInFlight(cassetteLocalId: cassetteLocalId) { return }
    guard markInFlight(cassetteLocalId) else { return }

    let metadata = CassetteTransferMetadata(
      cassetteLocalId: cassetteLocalId,
      mbid: mbid,
      subsonicTrackId: subsonicTrackId,
      ext: ext,
      intentId: intentId,
      contentFingerprint: contentFingerprint
    )
    let task = session.downloadTask(with: url)
    if let data = try? JSONEncoder().encode(metadata),
       let json = String(data: data, encoding: .utf8) {
      task.taskDescription = json
    }
    task.resume()
    print("Cassette transfer: enqueued background download for \(cassetteLocalId) (.\(ext))")
    os_log("enqueued download for %{public}@", log: self.log, type: .info, cassetteLocalId)
  }

  private func markInFlight(_ cassetteLocalId: String) -> Bool {
    inFlightLock.lock()
    defer { inFlightLock.unlock() }
    return inFlightLocalIds.insert(cassetteLocalId).inserted
  }

  private func containsInFlight(_ cassetteLocalId: String) -> Bool {
    inFlightLock.lock()
    defer { inFlightLock.unlock() }
    return inFlightLocalIds.contains(cassetteLocalId)
  }

  private func isAlreadyInFlight(cassetteLocalId: String) async -> Bool {
    if containsInFlight(cassetteLocalId) { return true }

    let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
      session.getAllTasks { continuation.resume(returning: $0) }
    }
    for task in tasks {
      guard task.state == .running || task.state == .suspended,
            let desc = task.taskDescription,
            let data = desc.data(using: .utf8),
            let meta = try? JSONDecoder().decode(CassetteTransferMetadata.self, from: data)
      else { continue }
      if meta.cassetteLocalId == cassetteLocalId { return true }
    }
    return false
  }

  // MARK: - Background events (called from AppDelegate)

  public func handleBackgroundEvents(completionHandler: @escaping () -> ()) {
    backgroundCompletionHandler = completionHandler
  }
}

// MARK: URLSessionDownloadDelegate

extension CassetteTransferSession: URLSessionDownloadDelegate {
  /// The computer's own certificate, checked against its key (CassetteHubTrust, BUG-879).
  public func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    CassetteHubTrust.answer(challenge)
  }

  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let desc = downloadTask.taskDescription,
          let data = desc.data(using: .utf8),
          let meta = try? JSONDecoder().decode(CassetteTransferMetadata.self, from: data)
    else {
      #if DEBUG
        print("Cassette transfer: download finished with no/invalid metadata")
      #endif
      os_log("download finished with no/invalid metadata", log: self.log, type: .error)
      return
    }
    #if DEBUG
      print("Cassette transfer: download finished for \(meta.cassetteLocalId), moving into place")
    #endif

    // The temp file at `location` is only valid synchronously here — move it
    // into place immediately.
    do {
      try fileStorage.moveTempFile(
        location,
        to: meta.cassetteLocalId,
        extension: meta.ext
      )
    } catch {
      os_log(
        "failed to move temp file for %{public}@: %{public}@",
        log: self.log,
        type: .error,
        meta.cassetteLocalId,
        error.localizedDescription
      )
      clearInFlight(meta.cassetteLocalId)
      return
    }

    // cassette: buffer for a batched, off-main ownership write + inventory report
    // (see `pendingAdditions` / `flushPendingReports`). Replaces the per-track
    // `@MainActor recordAndReport` that saved Core Data on the main thread once
    // per completed track during the burst.
    enqueueForReporting(meta)
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let desc = task.taskDescription,
          let data = desc.data(using: .utf8),
          let meta = try? JSONDecoder().decode(CassetteTransferMetadata.self, from: data)
    else { return }
    if let error {
      os_log(
        "download failed for %{public}@: %{public}@",
        log: self.log,
        type: .error,
        meta.cassetteLocalId,
        error.localizedDescription
      )
      clearInFlight(meta.cassetteLocalId)
    }
  }

  public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    // BUG-039 regression fix: persist any buffered ownership rows BEFORE telling
    // the OS we're done (which lets it suspend the app). A background download
    // burst that drains the queue before the 0.4s debounce fires would otherwise
    // discard its buffered ownership rows on suspension, and those albums (files on
    // disk, no DeviceOwnership row) would never appear in the on-device library.
    Task { [weak self] in
      await self?.flushPending()
      await MainActor.run {
        let handler = self?.backgroundCompletionHandler
        self?.backgroundCompletionHandler = nil
        handler?()
      }
    }
  }

  /// cassette: buffer a completed download and (re)arm the debounced flush.
  /// Called from the URLSession delegate queue. Cheap — no Core Data, no network.
  private func enqueueForReporting(_ meta: CassetteTransferMetadata) {
    pendingLock.lock()
    pendingAdditions.append((meta, Date()))
    pendingLock.unlock()
    // Manage the debounce timer on the main queue so `flushWorkItem` is only ever
    // touched from one place.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      flushWorkItem?.cancel()
      let work = DispatchWorkItem { [weak self] in Task { await self?.flushPending() } }
      flushWorkItem = work
      DispatchQueue.main.asyncAfter(
        deadline: .now() + flushDebounceInterval,
        execute: work
      )
    }
  }

  /// cassette: drain the buffered burst and persist it DURABLY. The ownership
  /// write is the on-device library's source of truth, so it is committed off-main
  /// and AWAITED — a caller can therefore guarantee it landed before the app
  /// suspends (`urlSessionDidFinishEvents` does exactly that). This closes the
  /// BUG-039 regression where a background download burst that drained the queue
  /// before the 0.4s debounce fired lost its ownership rows entirely, so those
  /// albums (files on disk but no DeviceOwnership row) never appeared. On a save
  /// failure the batch is RE-QUEUED, never silently dropped. The inventory POST is
  /// best-effort. Atomic drain — safe to call concurrently (debounce / completion /
  /// lifecycle); whoever wins the drain owns the batch.
  public func flushPending() async {
    let batch: [(meta: CassetteTransferMetadata, downloadedAt: Date)] = pendingLock.withLock {
      let drained = pendingAdditions
      pendingAdditions.removeAll()
      return drained
    }
    guard !batch.isEmpty else { return }

    let deviceId = await MainActor
      .run { UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device" }
    let deviceLabel = await MainActor.run { UIDevice.current.name }

    // 1) Ownership — off-main, DURABLE (awaited). Must persist; if the save
    // throws, re-buffer so a later flush retries rather than losing owned tracks.
    do {
      let asyncStorage = await MainActor.run { AmperKit.shared.storage.async }
      try await asyncStorage.perform { asyncCompanion in
        let manager = DeviceOwnershipManager(context: asyncCompanion.context)
        try manager.recordBatch(batch.map { entry in
          DeviceOwnershipManager.BatchEntry(
            cassetteLocalId: entry.meta.cassetteLocalId,
            mbid: entry.meta.mbid,
            subsonicTrackId: entry.meta.subsonicTrackId,
            fileExtension: entry.meta.ext,
            downloadedAt: entry.downloadedAt,
            contentFingerprint: entry.meta.contentFingerprint
          )
        })
      }
      for entry in batch { clearInFlight(entry.meta.cassetteLocalId) }
      // Refresh the on-device-only library views once (the notifier is debounced).
      await MainActor.run { CassetteOwnershipNotifier.shared.ownershipDidChange() }
    } catch {
      pendingLock.withLock { pendingAdditions.append(contentsOf: batch) }
      os_log(
        "failed to persist ownership batch (re-queued for retry): %{public}@",
        log: self.log,
        type: .error,
        error.localizedDescription
      )
      return
    }

    // 2) Inventory — best-effort batched POST (chunked to the server cap).
    // Recoverable via the full-inventory sync; does NOT gate local visibility,
    // which the persisted ownership rows above own.
    let added = batch.map {
      (cassetteLocalId: $0.meta.cassetteLocalId, mbid: $0.meta.mbid, downloadedAt: $0.downloadedAt)
    }
    for chunk in Self.chunk(added, size: Self.maxInventoryPerRequest) {
      do {
        try await syncAPI.reportDeviceInventory(
          deviceId: deviceId,
          deviceLabel: deviceLabel,
          added: chunk,
          removed: []
        )
      } catch {
        os_log(
          "failed to report inventory batch: %{public}@",
          log: self.log,
          type: .error,
          error.localizedDescription
        )
      }
    }
    #if DEBUG
      print(
        "Cassette transfer: durably persisted \(batch.count) ownership additions + reported inventory"
      )
    #endif
  }

  private static func chunk<T>(_ array: [T], size: Int) -> [[T]] {
    guard size > 0, array.count > size else { return array.isEmpty ? [] : [array] }
    return stride(from: 0, to: array.count, by: size).map {
      Array(array[$0 ..< Swift.min($0 + size, array.count)])
    }
  }

  private func clearInFlight(_ cassetteLocalId: String) {
    inFlightLock.lock()
    inFlightLocalIds.remove(cassetteLocalId)
    inFlightLock.unlock()
  }
}
