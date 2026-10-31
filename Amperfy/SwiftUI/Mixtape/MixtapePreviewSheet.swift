//
//  MixtapePreviewSheet.swift
//  Amperfy
//
//  Cassette: the "auto-open, never auto-play" mixtape review screen. Shown
//  right after generate/radio/door returns, before anything plays or saves —
//  mirrors the web app's rail (name + art up top, Play/Save/Rebuild, track
//  list below), and the same lesson learned there: generating a mixtape must
//  never yank audio out from under whatever's already playing. The listener
//  presses Play here, or Save if they want to keep it.
//
//  Presented the same way as the Equalizer panel (UIHostingController +
//  .large() sheet detent — see PopupPlayer+Visuals.swift
//  presentEqualizerPanel()); MixtapePresenter below is that same call
//  wrapped for reuse from more than one screen.

import AmperfyKit
import SwiftUI

// MARK: - MixtapePlayback

@MainActor
enum MixtapePlayback {
  /// Every track a generate/radio/door call returned, resolved to whatever's
  /// actually synced on this phone. Tracks that don't resolve (not synced
  /// yet) are silently dropped — same behavior cloud-playlist sync already
  /// has, not a new failure mode.
  static func resolveSongs(
    tracks: [CassetteMixtapeTrack],
    storage: PersistentStorage,
    account: Account
  )
    -> [Song] {
    tracks.compactMap {
      CassetteCloudPlaylistBridge.resolveSong(
        cassetteLocalId: $0.cassetteLocalId,
        mbid: $0.mbid,
        storage: storage,
        account: account
      )
    }
  }

  /// What a door's mix came to for a surface that plays it at once (CarPlay).
  enum DoorMixOutcome {
    /// The mix's name and the songs of it that this phone can play.
    case ok(name: String, songs: [AbstractPlayable])
    /// The server made a mix, but none of it is on this phone.
    case nothingOnPhone
    /// The server says the library has too little that fits this door (422).
    case notEnough
    /// No mix right now: no signal, no account, left the beta (404), anything else.
    case unavailable
  }

  /// A door's mix, cut to the songs on this phone, for a surface with no preview sheet: the
  /// car, where a tile tap is the play gesture. The phone's sheet keeps its own flow.
  /// "On this phone" is the foundation's rule (OneTapPlay): resolveSong matches only songs
  /// this phone owns; in Server Mode the offline setting also keeps only cached ones.
  static func makeDoorMix(doorKey: String) async -> DoorMixOutcome {
    let mixtape: CassetteMixtapeResponse
    do {
      mixtape = try await CassetteSyncAPI.shared.generateDoorMixtape(doorKey: doorKey)
    } catch let CassetteSyncError.http(status) where status == 422 {
      return .notEnough
    } catch {
      return .unavailable
    }
    // A static context has no `appDelegate` property; ask the application for it.
    let delegate = UIApplication.shared.delegate as! AppDelegate
    let storage = delegate.storage
    guard let accountInfo = storage.settings.accounts.active else { return .unavailable }
    let account = storage.main.library.getAccount(info: accountInfo)
    let resolved: [AbstractPlayable] = resolveSongs(
      tracks: mixtape.tracks,
      storage: storage,
      account: account
    )
    let songs = CassetteLibraryFilterProvider.shared.isOnDeviceOnly
      ? resolved
      : resolved.filterCached(dependigOn: storage.settings.user.isOfflineMode)
    guard !songs.isEmpty else { return .nothingOnPhone }
    return .ok(name: mixtape.name, songs: songs)
  }
}

// MARK: - MixtapePreviewSheet

struct MixtapePreviewSheet: View {
  @State
  private var mixtape: CassetteMixtapeResponse
  @State
  private var saving = false
  @State
  private var saved = false
  @State
  private var rebuilding = false
  @State
  private var errorMessage: String?

  let onDone: () -> ()

  init(mixtape: CassetteMixtapeResponse, onDone: @escaping () -> ()) {
    self._mixtape = State(initialValue: mixtape)
    self.onDone = onDone
  }

  private var totalMinutes: Int {
    Int(mixtape.tracks.reduce(0) { $0 + ($1.durationSeconds ?? 0) } / 60)
  }

  /// One line, matching an album hero's single metadata line (just the
  /// year) rather than several stacked labels.
  private var metaLine: String {
    var parts = ["\(mixtape.tracks.count) tracks", "\(totalMinutes) min"]
    if saved { parts.append("Saved") }
    return parts.joined(separator: " · ")
  }

  private var artColor: Color {
    mixtape.art.flatMap { Color(hexString: $0.color) } ?? CoverTint.neutral.textColor // not orange: nothing is live here (I-T4)
  }

  var body: some View {
    // Same information shape as an album's hero (GenericDetailTableHeader):
    // square art, title (.heroTitle), one metadata line (.caption) — not a
    // separate header bar + kicker + name + meta the way a bespoke screen
    // would invent. The sheet's own grabber (see presentMixtapePreview)
    // handles dismiss, so there's no "Done" row competing with it.
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 14) {
          RoundedRectangle(cornerRadius: 3)
            .fill(artColor.opacity(0.32))
            .frame(width: 240, height: 240)
            .padding(.top, 28)

          VStack(spacing: 4) {
            Text(mixtape.name)
              .font(Font.cassette(.heroTitle))
              .foregroundStyle(Color.cassette(.textPrimary))
              .multilineTextAlignment(.center)
              .lineLimit(2)
            Text(metaLine)
              .font(Font.cassette(.caption))
              .foregroundStyle(Color.cassette(.textSecondary))
            if let errorMessage {
              Text(errorMessage)
                .font(Font.cassette(.caption))
                .foregroundStyle(.red)
            }
          }
          .padding(.horizontal, 20)

          actionRow
            .padding(.top, 4)
            .padding(.bottom, 4)

          VStack(spacing: 0) {
            ForEach(mixtape.tracks, id: \.cassetteLocalId) { track in
              VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                  .font(Font.cassette(.rowTitle))
                  .foregroundStyle(Color.cassette(.textPrimary))
                  .lineLimit(1)
                Text(track.artist)
                  .font(Font.cassette(.cardSubtitle))
                  .foregroundStyle(Color.cassette(.textSecondary))
                  .lineLimit(1)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 20)
              .padding(.vertical, 8)
            }
          }
          .padding(.bottom, 24)
        }
      }
    }
    .background(Color.cassette(.surfaceBase))
  }

  private var actionRow: some View {
    HStack(spacing: 28) {
      Button {
        Task { await save() }
      } label: {
        Image(systemName: saved ? "bookmark.fill" : "bookmark")
          .font(.title3)
      }
      .disabled(saving || saved)

      Button {
        play()
      } label: {
        Image(systemName: CassetteIcon.play.symbolName)
          .font(.title2)
          .foregroundStyle(Color.cassette(.textOnFill))
          .frame(width: 52, height: 52)
          .background(Circle().fill(Color.cassette(.fillSelected)))
      }

      if let doorKey = mixtape.doorKey {
        Button {
          Task { await rebuild(doorKey: doorKey) }
        } label: {
          Image(systemName: CassetteIcon.refresh.symbolName)
            .font(.title3)
        }
        .disabled(rebuilding)
      } else {
        Color.clear.frame(width: 22, height: 22)
      }
    }
    .foregroundStyle(Color.cassette(.textSecondary))
  }

  @MainActor
  private func play() {
    guard let accountInfo = appDelegate.storage.settings.accounts.active else { return }
    let account = appDelegate.storage.main.library.getAccount(info: accountInfo)
    let songs = MixtapePlayback.resolveSongs(
      tracks: mixtape.tracks,
      storage: appDelegate.storage,
      account: account
    )
    guard !songs.isEmpty else {
      errorMessage = "None of these tracks are on this phone yet"
      return
    }
    appDelegate.player.play(context: PlayContext(name: mixtape.name, playables: songs))
    onDone()
  }

  private func save() async {
    guard !saving, !saved else { return }
    saving = true
    defer { saving = false }
    do {
      _ = try await CassetteSyncAPI.shared.saveMixtape(
        name: mixtape.name,
        description: mixtape.description ?? "",
        tracks: mixtape.tracks
      )
      saved = true
    } catch {
      errorMessage = "Couldn't save this mixtape"
    }
  }

  private func rebuild(doorKey: String) async {
    guard !rebuilding else { return }
    rebuilding = true
    defer { rebuilding = false }
    do {
      mixtape = try await CassetteSyncAPI.shared.generateDoorMixtape(
        doorKey: doorKey,
        rebuild: true
      )
      saved = false
      errorMessage = nil
    } catch {
      errorMessage = "Couldn't rebuild this mixtape"
    }
  }
}

// MARK: - Presentation helper

/// Fetches (or is handed) a mixtape and presents MixtapePreviewSheet the same
/// way presentEqualizerPanel() presents the EQ panel — UIHostingController +
/// a .large() sheet. Call from any UIViewController.
extension UIViewController {
  func presentMixtapePreview(_ mixtape: CassetteMixtapeResponse) {
    let sheet = MixtapePreviewSheet(mixtape: mixtape) { [weak self] in
      self?.dismiss(animated: true)
    }
    let host = UIHostingController(rootView: sheet)
    host.view.backgroundColor = UIColor(Color.cassette(.surfaceBase))
    if let sheetController = host.sheetPresentationController {
      sheetController.detents = [.large()]
      sheetController.prefersGrabberVisible = true
      sheetController.preferredCornerRadius = 28
    }
    present(host, animated: true)
  }
}
