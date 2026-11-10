//
//  ComputerCardModel.swift
//  Amperfy
//
//  Cassette fork (BUG-899): whether Home leads with the computer card, and in which state,
//  from facts the phone already has: whether it is paired, the sync pass's report (albums
//  waiting, whether the hub answered), the computer's heartbeat and totals (the cached
//  GET /api/player/devices/mac), the albums on this phone (the ownership records, read off
//  the main thread) and, only when it decides the state, the account's sync scope.
//
//  The card shows until the music is in: while the phone has no music, and through the
//  phone's first sync. After that first sync it comes back only if the phone is emptied.
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
import Observation
import SwiftUI
import UIKit

// MARK: - The decision

/// Everything the card's state is decided from.
struct ComputerCardFacts: Equatable, Sendable {
  /// The phone has a computer to sync from.
  var isPaired: Bool
  /// The computer can't be reached: the phone can't sync at all, albums are waiting and
  /// the hub did not answer, or its heartbeat went quiet.
  var outOfReach: Bool
  /// Music is on its way (downloads in flight or albums still waiting).
  var arriving: Bool
  /// Albums are waiting and the last download had no room on this phone (BUG-883).
  var phoneFull = false
  /// Albums on this phone; nil until the first read.
  var onPhone: Int?
  /// The phone's first sync has finished.
  var firstSyncDone: Bool
  /// The computer's album count; nil before the cloud has answered.
  var computerAlbums: Int?
  /// The computer has finished reading its library at least once.
  var computerHasRead: Bool
  /// "everything" or "selective"; nil until asked.
  var scope: String?

  /// The card's state, or nil when Home has its music and no card.
  func phase() -> ComputerCard.Phase? {
    guard isPaired else { return .notSetUp }
    // Not read yet: say nothing rather than flash a card that is about to go.
    guard let onPhone else { return nil }
    if onPhone > 0, firstSyncDone || !arriving { return nil }
    if outOfReach { return .outOfReach }
    if arriving, phoneFull { return .phoneFull }
    if arriving { return .syncing }
    guard let computerAlbums, computerHasRead else { return .gettingReady }
    if computerAlbums == 0 { return .noMusic }
    if scope == "selective" { return .nothingChosen }
    return .gettingReady
  }

  /// Whether the scope would change the answer (the one fact fetched only when needed).
  var needsScope: Bool {
    isPaired && onPhone == 0 && !outOfReach && !arriving && computerHasRead
      && (computerAlbums ?? 0) > 0
  }
}

// MARK: - The model

@MainActor
@Observable
final class ComputerCardModel {
  /// What the card draws, or nil when there is no card.
  private(set) var content: ComputerCard.Content?

  /// Called when the card comes or goes, so Home adds or drops its row.
  @ObservationIgnored
  var onShownChange: (() -> ())?

  @ObservationIgnored
  private var phone: (albums: Int, covers: [LibraryStrip.Cover])?
  @ObservationIgnored
  private var scope: String?
  @ObservationIgnored
  private var scopeAskedAt: Date?
  @ObservationIgnored
  private var phoneReadAt: Date?
  @ObservationIgnored
  private var phoneReading = false
  @ObservationIgnored
  private var phoneReadQueued = false
  @ObservationIgnored
  private var isHomeVisible = false
  @ObservationIgnored
  private var observers: [NSObjectProtocol] = []

  /// The newest albums the strip cycles through.
  static let coverLimit = 12
  /// How many of the newest arrivals are looked through for covers on disk.
  private static let coverScanLimit = 60
  /// A cover at the strip's size, at 3x.
  private static let coverPixels = 240
  /// Reads of the phone at most this often while music arrives.
  private static let phoneReadSpacing: TimeInterval = 2
  /// The scope is asked at most this often (a heavy read on the cloud).
  private static let scopeSpacing: TimeInterval = 60

  /// "running" from the moment a phone with no music first opens Home, "done" once music is
  /// in and nothing is arriving (an install that already had music starts at "done").
  private static let firstSyncKey = "cassette.home.firstSync.v1"

  private var delegate: AppDelegate {
    UIApplication.shared.delegate as! AppDelegate
  }

  init() {
    let center = NotificationCenter.default
    for name in [Notification.Name.cassetteSyncActiveChanged, .cassetteMacSummaryChanged] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.readPhone()
          self.recompute()
        }
      })
    }
    readPhone()
    recompute()
  }

  /// Home came on screen: fresh facts, and the computer's heartbeat while the card shows.
  func homeAppeared() {
    isHomeVisible = true
    readPhone()
    recompute()
    if content != nil {
      Task { _ = await CassetteSyncStatus.refreshMacSummary(maxAge: 120) }
    }
  }

  func homeDisappeared() {
    isHomeVisible = false
    watchForComputer(false)
  }

  /// Works the card out again from what is known now.
  func recompute() {
    let facts = currentFacts()
    let next = makeContent(facts)
    let wasShown = content != nil
    if next != content { content = next }
    if facts.needsScope { askScopeIfDue() }
    watchForComputer(isHomeVisible && facts.phase() == .notSetUp)
    if wasShown != (next != nil) { onShownChange?() }
  }

  @ObservationIgnored
  private var computerWatch: Task<(), Never>?

  /// Not set up and on screen: every few seconds the phone asks whether the account's computer
  /// has signed in, so it connects while the person sets the computer up (BUG-899). The asking
  /// itself is spaced and skipped once a computer is there (`AppDelegate.connectComputerIfReady`).
  private func watchForComputer(_ on: Bool) {
    guard on else {
      computerWatch?.cancel()
      computerWatch = nil
      return
    }
    guard computerWatch == nil else { return }
    computerWatch = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        delegate.connectComputerIfReady()
        try? await Task.sleep(for: .seconds(12))
      }
    }
  }

  // MARK: Facts

  private func currentFacts() -> ComputerCardFacts {
    let serverUrl = CassetteSyncStatus.pairedServerUrl(
      delegate.storage.settings.accounts.activeSetting.read.loginCredentials?.serverUrl
    )
    let canSync = CassetteSyncAPI.bearerToken != nil && delegate.networkMonitor.isConnectedToNetwork
    let state = CassetteSyncStatus.macState(isPaired: serverUrl != nil, canSync: canSync)
    let summary = CassetteSyncAPI.cachedMacSummary
    let arriving = CassetteSyncStatus.isActive || CassetteSyncStatus.pendingAlbums > 0
    let onPhone = phone?.albums
    return ComputerCardFacts(
      isPaired: serverUrl != nil,
      outOfReach: state == .outOfReach,
      arriving: arriving,
      phoneFull: CassetteSyncStatus.isPhoneFull && CassetteSyncStatus.pendingAlbums > 0,
      onPhone: onPhone,
      firstSyncDone: firstSyncDone(onPhone: onPhone, arriving: arriving),
      computerAlbums: summary?.albums,
      computerHasRead: summary?.mac?.lastSyncDate != nil,
      scope: scope
    )
  }

  /// Moves the first-sync mark on and reads it.
  private func firstSyncDone(onPhone: Int?, arriving: Bool) -> Bool {
    let defaults = UserDefaults.standard
    let mark = defaults.string(forKey: Self.firstSyncKey)
    if mark == "done" { return true }
    guard let onPhone else { return false }
    if onPhone > 0, !arriving {
      defaults.set("done", forKey: Self.firstSyncKey)
      return true
    }
    if mark == nil, onPhone == 0 { defaults.set("running", forKey: Self.firstSyncKey) }
    return false
  }

  private func makeContent(_ facts: ComputerCardFacts) -> ComputerCard.Content? {
    if let forced = previewContent() { return forced }
    guard let phase = facts.phase() else { return nil }
    let serverUrl = delegate.storage.settings.accounts.activeSetting.read.loginCredentials?.serverUrl
    let name = CassetteSyncStatus.displayHubName(serverUrl: serverUrl) ?? CassetteSyncStatus.fallbackHubName
    let onPhone = phone?.albums ?? 0
    return ComputerCard.Content(
      phase: phase,
      label: phase == .notSetUp ? CassetteSyncStatus.fallbackHubName : name,
      onPhone: onPhone,
      total: onPhone + CassetteSyncStatus.pendingAlbums,
      covers: phone?.covers ?? []
    )
  }

  // MARK: The phone

  /// Re-reads the albums on this phone and its newest covers, off the main thread, at most
  /// every 2 s (a read asked for meanwhile runs once the spacing is up).
  private func readPhone() {
    if phoneReading {
      phoneReadQueued = true
      return
    }
    if let phoneReadAt, Date().timeIntervalSince(phoneReadAt) < Self.phoneReadSpacing {
      guard !phoneReadQueued else { return }
      phoneReadQueued = true
      let wait = Self.phoneReadSpacing - Date().timeIntervalSince(phoneReadAt)
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(max(0.05, wait)))
        guard let self else { return }
        phoneReadQueued = false
        readPhone()
      }
      return
    }
    phoneReading = true
    phoneReadAt = Date()
    let storage = delegate.storage
    let info = storage.settings.accounts.active
    let scanLimit = Self.coverScanLimit
    let coverLimit = Self.coverLimit
    let pixels = Self.coverPixels
    Task { [weak self] in
      let read = try? await storage.async.performAndGet { companion -> PhoneRead in
        let summary = DeviceOwnershipManager(context: companion.context).onPhoneSummary()
        var picks = [PhoneRead.Pick]()
        if let info {
          let account = companion.library.getAccount(info: info)
          let newest = summary.albums.sorted { $0.arrivedAt > $1.arrivedAt }.prefix(scanLimit)
          for entry in newest {
            guard let path = companion.library.getAlbum(
              for: account,
              id: entry.albumId,
              isDetailFaultResolution: false
            )?.artwork?.imagePath else { continue }
            picks.append(PhoneRead.Pick(albumId: entry.albumId, path: path))
            if picks.count == coverLimit { break }
          }
        }
        return PhoneRead(albums: summary.albums.count, picks: picks)
      }
      var covers = [LibraryStrip.Cover]()
      for pick in read?.picks ?? [] {
        let path = pick.path
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
          let source = CoverImageStore.preferredSourcePath(forFullPath: path, smallSurface: true)
          return CoverImageStore.downsampledImage(atPath: source, maxPixel: pixels)
        }.value
        if let image { covers.append(LibraryStrip.Cover(id: pick.albumId, image: image)) }
      }
      guard let self else { return }
      phoneReading = false
      if let read { phone = (read.albums, covers) }
      recompute()
      if phoneReadQueued {
        phoneReadQueued = false
        readPhone()
      }
    }
  }

  // MARK: The scope

  /// Asks the cloud whether this account syncs everything or only chosen music, once a
  /// minute at most and only while Home is on screen.
  private func askScopeIfDue() {
    guard isHomeVisible else { return }
    if let scopeAskedAt, Date().timeIntervalSince(scopeAskedAt) < Self.scopeSpacing { return }
    scopeAskedAt = Date()
    Task { [weak self] in
      let summary = try? await CassetteSyncAPI.shared.getThisDeviceSummary()
      guard let self, let summary else { return }
      scope = summary.scope
      recompute()
    }
  }

  // MARK: Checking the states

  /// Launched with `-cassette.debug.computerCard <phase>` the card draws that state; with
  /// `tour` it walks every state, 6 s each. Covers are the phone's own, else plain swatches.
  /// Read from the launch arguments only, never a stored setting: only a launch from Xcode,
  /// simctl or devicectl shows it, and the next ordinary launch is the real Home.
  static let previewKey = "cassette.debug.computerCard"

  @ObservationIgnored
  private var tourStartedAt = Date()
  @ObservationIgnored
  private var tourTimer: Timer?

  private func previewContent() -> ComputerCard.Content? {
    let launch = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    guard let forced = launch[Self.previewKey] as? String, !forced.isEmpty else { return nil }
    let phase: ComputerCard.Phase
    var tick = 0
    if forced == "tour" {
      if tourTimer == nil {
        tourStartedAt = Date()
        tourTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.recompute() }
        }
      }
      tick = Int(Date().timeIntervalSince(tourStartedAt) / 6)
      let order: [ComputerCard.Phase] = [
        .gettingReady, .syncing, .outOfReach, .phoneFull, .noMusic, .nothingChosen, .notSetUp,
      ]
      phase = order[tick % order.count]
    } else if let named = ComputerCard.Phase(rawValue: forced) {
      phase = named
    } else {
      return nil
    }
    var covers = phone?.covers ?? []
    if covers.count < 8 { covers = Self.swatches }
    let landed = min(covers.count, 5 + tick)
    return ComputerCard.Content(
      phase: phase,
      label: phase == .notSetUp ? CassetteSyncStatus.fallbackHubName : "Michael's MacBook Pro",
      onPhone: 5 + tick * 3,
      total: 120,
      covers: Array(covers.prefix(landed))
    )
  }

  private static let swatches: [LibraryStrip.Cover] = {
    let hues: [CGFloat] = [0.02, 0.08, 0.13, 0.55, 0.62, 0.33, 0.9, 0.75, 0.45, 0.18, 0.68, 0.05]
    return hues.enumerated().map { index, hue in
      let size = CGSize(width: 120, height: 120)
      let image = UIGraphicsImageRenderer(size: size).image { context in
        UIColor(hue: hue, saturation: 0.55, brightness: 0.72, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: size))
        UIColor(hue: hue, saturation: 0.7, brightness: 0.45, alpha: 1).setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 24, y: 24, width: 72, height: 72))
      }
      return LibraryStrip.Cover(id: "swatch-\(index)", image: image)
    }
  }()
}

/// One read of the phone, done off the main thread.
private struct PhoneRead: Sendable {
  struct Pick: Sendable {
    let albumId: String
    let path: String
  }

  let albums: Int
  let picks: [Pick]
}

// MARK: - The card on Home

/// The card as Home hosts it: in the page's gutter, under the bar, telling Home its height
/// so the rows under it move with it.
struct ComputerCardRoot: View {
  let model: ComputerCardModel
  var onAction: (ComputerCard.Action) -> () = { _ in }
  var onHeight: (CGFloat) -> () = { _ in }

  /// Where the Resume card would sit: 18 under the bar, in the 20 pt gutter; Radio's heading
  /// brings its own 28 under it (32 in all, as on the board).
  static let insets = EdgeInsets(top: 18, leading: 20, bottom: 4, trailing: 20)

  var body: some View {
    VStack(spacing: 0) {
      if let content = model.content {
        ComputerCard(content: content, onAction: onAction)
          .padding(Self.insets)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}
