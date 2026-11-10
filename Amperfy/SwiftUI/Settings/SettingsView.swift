//
//  SettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 14.09.22.
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
import UIKit

// MARK: - SettingsView

// cassette §G: the settings root. Removed from this screen earlier:
//   • Offline Mode — gone; cleared at launch (see AmperfyKit init). Owned-file
//     playback still works without a network.
//   • Prevent Screen Lock — gone; normal system lock (audio keeps playing).
//   • Server Mode toggle — gone; it becomes account-sourced (web owns the
//     write path; the phone reads it from the account payload — §C).
//   • Version / Build rows — moved to About.
//
// Phone-taste (2026-10-21): on iOS the root carries the answers. The account card; YOUR MAC
// (a paired Cassette hub only) with its state and Resync Library; THIS PHONE (what is here,
// how it sounds); then Report a problem, About and Advanced. App Icon, Playback and Storage
// left the root; their NavigationTarget cases stay because the Mac Catalyst sidebar lists
// every case. Mac Catalyst keeps its two-section list unchanged.
struct SettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  /// Closes the sheet. SettingsHostVC sets it on iOS; nil on Mac Catalyst, where Settings is
  /// its own window.
  var onDone: (() -> ())? = nil

  #if !targetEnvironment(macCatalyst)
    @StateObject
    private var devices = DevicePagesModel()
    @State
    private var downloadQuality = ""
  #endif

  private static var rootSectionSpacing: CGFloat? {
    #if targetEnvironment(macCatalyst)
      return nil
    #else
      return 12
    #endif
  }

  func navigationLink(_ item: NavigationTarget) -> some View {
    NavigationLink(destination: AnyView(item.view())) {
      Text(item.displayName)
    }
  }

  var body: some View {
    // Phone-taste: on iOS the root's groups sit 12pt apart (the mock's .group gap); the
    // heads add their own air above.
    let list =
      SettingsList(sectionSpacing: Self.rootSectionSpacing) {
        #if targetEnvironment(macCatalyst) // ok
          SettingsSection {
            navigationLink(.account)
            navigationLink(.playback)
            navigationLink(.appIcon)
            navigationLink(.storage)
          }

          SettingsSection {
            navigationLink(.support)
            navigationLink(.about)
            navigationLink(.advanced)

            #if DEBUG
              navigationLink(.developer)
            #endif
          }
        #else
          rootSections
        #endif
      }

    #if targetEnvironment(macCatalyst) // ok
      ZStack {
        list
      }
      .navigationTitle("General")
      .navigationBarTitleDisplayMode(.inline)
    #else
      // cassette: NavigationStack (iOS 16+) replaces the deprecated NavigationView.
      // On iOS 26 the deprecated NavigationView renders a mis-styled opaque bar that
      // briefly covers the large "Settings" title and glitches/animates over the UI
      // on push into a sub-menu; NavigationStack adopts the Liquid Glass bar cleanly.
      NavigationStack {
        list
          .navigationTitle("Settings")
          // cassette: use the INLINE title on the Settings root. The large-title
          // (scroll-edge) state renders the global opaque nav-bar appearance
          // (CassetteTheme.applyGlobalAppearance → configureWithOpaqueBackground)
          // as a gray bar that covers the top and whose own large title never
          // resolves in this SwiftUI-in-modal context — the "gray artifact" that
          // clips the UI. Inline matches every sub-screen and shows "Settings"
          // cleanly with no large-title bar.
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            if let onDone {
              // Not .confirmationAction: on iOS 26 that draws a prominent glass pill in the
              // tint colour. The label carries its own font and ink, past the global
              // bar-button appearance (ink2 Barlow 18).
              ToolbarItem(placement: .topBarTrailing) {
                Button(action: onDone) {
                  Text("Done")
                    .font(.cassetteDisplay(size: 17, weight: .bold))
                    .foregroundStyle(Color.cassette(.textPrimary))
                }
              }
            }
          }
          .onAppear {
            downloadQuality = DevicePagesModel.downloadQualityLabel(storage: appDelegate.storage)
            devices.settingsAppeared()
          }
          .onDisappear {
            devices.pageDisappeared()
          }
      }
    #endif
  }

  #if !targetEnvironment(macCatalyst)

    // MARK: iOS root

    /// A paired Cassette hub: a hub address, and the `cassette-*` login pairing mints (the
    /// AccountSettingsView test), so a generic Subsonic server is never called "your computer".
    private var isCassetteHub: Bool {
      let credentials = appDelegate.storage.settings.accounts.activeSetting.read.loginCredentials
      guard credentials?.serverUrl != nil else { return false }
      return (credentials?.username ?? "").hasPrefix("cassette-")
    }

    private var phoneShout: String {
      UIDevice.current.userInterfaceIdiom == .pad ? "THIS IPAD" : "THIS PHONE"
    }

    /// "12 albums", "1 album" or "nothing yet"; nil until the phone has been read.
    private var phoneAnswer: String? {
      guard let phone = devices.phone else { return nil }
      return phone.albums.isEmpty ? "nothing yet" : DeviceFormat.albums(phone.albums.count)
    }

    private var appearanceValue: String {
      switch settings.appearanceMode {
      case .light: return "Light"
      case .dark: return "Dark"
      default: return "Auto"
      }
    }

    private var equalizerValue: String {
      settings.isEqualizerEnabled ? settings.activeEqualizerSetting.name : "Off"
    }

    @ViewBuilder
    private var rootSections: some View {
      Section {
        AccountCardRow()
      }

      if isCassetteHub {
        Section {
          HubRow(model: devices)
          // Nothing to rescan before the account has a computer (BUG-899).
          if devices.macState != .notPaired {
            ResyncRow(model: devices)
          }
        } header: {
          SettingsHead(shout: "YOUR COMPUTER", answer: devices.macState.answer)
        }
      }

      Section {
        if let phone = devices.phone, !phone.albums.isEmpty {
          if !devices.stripAlbums.isEmpty {
            StripRow(albums: devices.stripAlbums)
          }
          RootRowLabel(title: "Music", value: DeviceFormat.size(phone.bytes), chevron: false)
        }
        RootLink("Albums on this \(UIDevice.cassetteDeviceWord)") {
          ThisPhoneView(model: devices)
        }
      } header: {
        SettingsHead(shout: phoneShout, answer: phoneAnswer)
      }

      Section {
        RootLink("Download quality", value: downloadQuality) {
          PlaybackSettingsView()
        }
        RootLink("Equalizer", value: equalizerValue) {
          EqualizerSettingsView()
        }
        // Light or dark, this phone only (the founder, 2026-10-29: Auto by default, with Light
        // and Dark; I-T1). A menu in the row, as Apple's own Appearance choices are.
        Menu {
          Picker("Appearance", selection: $settings.appearanceMode) {
            Text("Auto").tag(UIUserInterfaceStyle.unspecified)
            Text("Light").tag(UIUserInterfaceStyle.light)
            Text("Dark").tag(UIUserInterfaceStyle.dark)
          }
        } label: {
          RootRowLabel(title: "Appearance", value: appearanceValue)
        }
        .buttonStyle(.plain)
      }

      Section {
        // The iPhone's help article, drawn by the site inside the app (I-S6).
        RootLink("Help") {
          CassetteWebPage(path: "/help/your-iphone", title: "Help")
            .ignoresSafeArea(edges: .bottom)
        }
        RootLink(NavigationTarget.support.displayName) {
          SupportSettingsView()
        }
        RootLink(NavigationTarget.about.displayName, value: AppDelegate.version) {
          AboutSettingsView()
        }
        RootLink(NavigationTarget.advanced.displayName) {
          AdvancedSettingsView()
        }
        #if DEBUG
          RootLink(NavigationTarget.developer.displayName) {
            DeveloperView()
          }
        #endif
      } header: {
        // The mock's 28pt above a group that has no head.
        Color.clear
          .frame(height: 16)
          .listRowInsets(EdgeInsets())
          .accessibilityHidden(true)
      }
    }

  #endif
}

#if !targetEnvironment(macCatalyst)

  // MARK: - SettingsHead

  /// A two-voice section head on the root: the shout in ink, the answer in ink2 (orange is
  /// for Home row answers and live state only). One line, 20pt from the screen edge.
  private struct SettingsHead: View {
    let shout: String
    let answer: String?

    var body: some View {
      CassetteHeadingText(
        shout: shout,
        answer: answer,
        answerColor: Color.cassette(.textSecondary)
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 16)
      .padding(.bottom, 10)
      .padding(.leading, 4)
      .listRowInsets(EdgeInsets())
      .textCase(nil)
    }
  }

  // MARK: - Root rows

  /// The root's chevron: the registry glyph in ink3.
  private struct RootChevron: View {
    var body: some View {
      Image(uiImage: CassetteIcon.chevronRight.uiImage(size: .row, weight: .semibold))
        .renderingMode(.template)
        .foregroundStyle(Color.cassette(.textTertiary))
        .accessibilityHidden(true)
    }
  }

  /// A root row: the label in Barlow, the value in DM Mono ink2, then the chevron.
  private struct RootRowLabel: View {
    let title: String
    var value: String? = nil
    var chevron = true

    var body: some View {
      HStack(spacing: 12) {
        Text(title)
          .font(.cassette(.rowTitle))
          .foregroundStyle(Color.cassette(.textPrimary))
          .lineLimit(1)
        Spacer(minLength: 8)
        if let value, !value.isEmpty {
          Text(value)
            .font(.cassette(.caption))
            .foregroundStyle(Color.cassette(.textSecondary))
            .lineLimit(1)
        }
        if chevron {
          RootChevron()
        }
      }
      .frame(maxWidth: .infinity, minHeight: 50)
      .contentShape(Rectangle())
    }
  }

  /// A root row that pushes `destination`, with the root's own chevron (the system one is
  /// hidden with the link).
  private struct RootLink<Destination: View>: View {
    let title: String
    let value: String?
    let destination: () -> Destination

    init(_ title: String, value: String? = nil, @ViewBuilder destination: @escaping () -> Destination) {
      self.title = title
      self.value = value
      self.destination = destination
    }

    var body: some View {
      ZStack {
        NavigationLink(destination: destination) { EmptyView() }
          .opacity(0)
        RootRowLabel(title: title, value: value)
      }
    }
  }

  // MARK: - AccountCardRow

  /// The account card: photo (else the chosen disc or silhouette), name, "Email, sign out".
  private struct AccountCardRow: View {
    @State
    private var name = "Your account"
    @State
    private var avatar: UIImage?
    @State
    private var photo: UIImage?
    @State
    private var photoURL: String?

    var body: some View {
      ZStack {
        NavigationLink(destination: AccountSettingsView()) { EmptyView() }
          .opacity(0)
        HStack(spacing: 12) {
          Group {
            if let image = photo ?? avatar {
              Image(uiImage: image)
                .resizable()
                .scaledToFill()
            } else {
              Color.cassette(.surfaceSunken)
            }
          }
          .frame(width: 56, height: 56)
          .clipShape(Circle())
          .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(name)
              .font(.cassette(.sectionTitle))
              .foregroundStyle(Color.cassette(.textPrimary))
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          RootChevron()
        }
        .contentShape(Rectangle())
      }
      .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
      .onAppear { reload() }
      .onReceive(NotificationCenter.default.publisher(for: .cassetteAccountAvatarChanged)) { _ in
        reload()
      }
    }

    private func reload() {
      name = CassetteSyncAPI.accountName ?? CassetteSyncAPI.accountEmail ?? "Your account"
      avatar = UIViewController.cassetteAccountAvatarImage(size: 56)
      let urlString = CassetteSyncAPI.accountImage
      if urlString != photoURL {
        photo = nil
        photoURL = urlString
      }
      // The photo loads as the nav chip's does (URLSession's cache makes a reopen cheap).
      guard let urlString, let url = URL(string: urlString) else { return }
      Task {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data),
              CassetteSyncAPI.accountImage == urlString
        else { return }
        photo = image
      }
    }
  }

  // MARK: - HubRow

  /// The paired hub: its glyph on a bg4 tile, its name, and one true line under it.
  private struct HubRow: View {
    @ObservedObject
    var model: DevicePagesModel

    private var name: String {
      model.hubName ?? CassetteSyncStatus.fallbackHubName
    }

    /// "3 of 12 albums" while albums arrive, "12 albums waiting" while the Mac is out of
    /// reach with albums to send, else "Synced 5 min ago" from the hub's own last sync.
    private var subtitle: String? {
      let pending = CassetteSyncStatus.pendingAlbums
      if pending > 0, !CassetteSyncStatus.isHubReachable {
        return pending == 1 ? "1 album waiting" : "\(pending) albums waiting"
      }
      if CassetteSyncStatus.isActive || pending > 0 {
        let total = CassetteSyncStatus.waveTotal
        guard total > 1 else { return nil }
        let done = max(0, min(total, total - pending + 1))
        return "\(done) of \(total) albums"
      }
      return model.lastSyncedAgo.map { "Synced \($0)" }
    }

    var body: some View {
      ZStack {
        NavigationLink(destination: MacDeviceView(model: model)) { EmptyView() }
          .opacity(0)
        HStack(spacing: 12) {
          ZStack {
            RoundedRectangle(cornerRadius: CassetteRadius.iconTile, style: .continuous)
              .fill(Color.cassette(.surfaceSunken))
            Image(
              uiImage: (CassetteSyncStatus.isLaptop(hubName: name) ? CassetteIcon.laptop : .desktop)
                .uiImage(size: .control)
            )
            .renderingMode(.template)
            .foregroundStyle(Color.cassette(.textPrimary))
          }
          .frame(width: 36, height: 36)
          .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(name)
              .font(.cassette(.rowTitle))
              .foregroundStyle(Color.cassette(.textPrimary))
              .lineLimit(1)
            if let subtitle {
              Text(subtitle)
                .font(.cassette(.caption))
                .foregroundStyle(Color.cassette(.textSecondary))
                .lineLimit(1)
            }
          }
          .padding(.vertical, 10)
          Spacer(minLength: 8)
          RootChevron()
        }
        .contentShape(Rectangle())
      }
    }
  }

  // MARK: - ResyncRow

  /// Resync Library: the Mac rescans and the music keeps playing. No confirm, no chevron.
  private struct ResyncRow: View {
    @ObservedObject
    var model: DevicePagesModel

    var body: some View {
      Button {
        Task { await model.resync() }
      } label: {
        HStack(spacing: 12) {
          Text("Resync Library")
            .font(.cassette(.rowTitle))
            .foregroundStyle(Color.cassette(.textPrimary))
          Spacer(minLength: 8)
          if model.isResyncing {
            ProgressView()
              .tint(Color.cassette(.textSecondary))
          }
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .contentShape(Rectangle())
      }
      .accessibilityValue(model.isResyncing ? "Resyncing" : "")
    }
  }

  // MARK: - StripRow

  /// The covers that arrived last: 46pt, 6pt apart, fading out from 78% of the width.
  /// Decorative and not interactive, as in the mock.
  private struct StripRow: View {
    let albums: [DeviceAlbum]

    var body: some View {
      HStack(spacing: 6) {
        ForEach(albums) { album in
          DeviceCoverView(
            path: album.coverPath,
            title: album.name,
            side: 46,
            radius: CassetteRadius.small
          )
        }
      }
      .fixedSize()
      .padding(.vertical, 14)
      .padding(.horizontal, 16)
      // Both bounds, so the row takes the cell's width and the overflow is clipped (with
      // only a maximum, the frame would grow to the strip's full width).
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .clipped()
      .mask(
        LinearGradient(
          stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.78),
            .init(color: .clear, location: 1),
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      .listRowInsets(EdgeInsets())
      .accessibilityHidden(true)
    }
  }

#endif

// MARK: - SettingsView_Previews

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView()
  }
}

// MARK: - CassetteWebPage

/// A page of the site inside Settings, through the app's own web screen (CassetteWebPageVC).
struct CassetteWebPage: UIViewControllerRepresentable {
  let path: String
  let title: String

  func makeUIViewController(context: Context) -> CassetteWebPageVC {
    CassetteWebPageVC(path: path, title: title, placeholder: nil)
  }

  func updateUIViewController(_ uiViewController: CassetteWebPageVC, context: Context) {}
}
