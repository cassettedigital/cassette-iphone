//
//  MacDeviceView.swift
//  Amperfy
//
//  Cassette fork (phone-taste): Your Mac, from Settings. Lit by the newest records that
//  arrived from it (the ones on this phone), then whether this phone has it all, then
//  what is new there, which plays from here because it is already on the phone.
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

#if !targetEnvironment(macCatalyst)

  // MARK: - MacDeviceView

  struct MacDeviceView: View {
    @ObservedObject
    var model: DevicePagesModel

    /// The lead cover's own colour, once read.
    @State
    private var leadTint: CoverTint?
    /// The lead cover, small, for the glow.
    @State
    private var leadImage: UIImage?
    /// The glow's key: the lead cover's path plus its file's date (`CoverTint.cacheKey`), so a
    /// cover replaced at the same path glows anew instead of keeping the old picture (BUG-458).
    @State
    private var leadKey = ""
    /// The payloads are heavy server reads: once per page open.
    @State
    private var didOpen = false

    private var lead: DeviceAlbum? { model.newOnMac.first }
    private var fan: [DeviceAlbum] { Array(model.newOnMac.prefix(3)) }
    /// The record's colour: the neutral (never orange) until the lead cover is read, as on
    /// every other lit page.
    private var tint: CoverTint { leadTint ?? .neutral }

    private var hubName: String { model.hubName ?? CassetteSyncStatus.fallbackHubName }

    var body: some View {
      ScrollView {
        ZStack(alignment: .top) {
          // Keyed on the decoded image being in hand: the layer reads its image when its
          // key changes, so a key set before the decode would leave the page unlit.
          CoverGlowLayer(
            image: leadImage,
            key: leadImage == nil ? "" : leadKey,
            recipe: .page
          )
          .frame(height: 700)
          VStack(alignment: .leading, spacing: 0) {
            hero
            card
            shelf
            Color.clear.frame(height: 48)
          }
        }
      }
      .background(Color.cassette(.surfaceBase))
      .toolbarBackground(.hidden, for: .navigationBar)
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .onAppear {
        model.pageAppeared()
        guard !didOpen else { return }
        didOpen = true
        model.macPageOpened()
      }
      .onDisappear {
        model.pageDisappeared()
      }
      .task(id: lead?.coverPath) { await loadLead() }
    }

    private func loadLead() async {
      leadImage = nil
      guard let path = lead?.coverPath else {
        leadTint = nil
        return
      }
      leadKey = CoverTint.cacheKey(forCoverPath: path)
      leadImage = await DeviceCoverCache.image(path: path, maxPixel: 128)
      leadTint = await CoverTint.resolve(coverPath: path)
    }

    // MARK: Hero

    private var hero: some View {
      VStack(alignment: .leading, spacing: 0) {
        if !fan.isEmpty {
          HStack(spacing: -46) {
            ForEach(Array(fan.enumerated()), id: \.element.id) { index, album in
              DeviceCoverView(
                path: album.coverPath,
                title: album.name,
                side: 150,
                radius: CassetteRadius.artworkTile
              )
              .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 18)
              .offset(y: index == 1 ? -14 : 0)
              .zIndex(index == 1 ? 1 : 0)
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.top, 30)
          .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 6) {
            Image(
              uiImage: (CassetteSyncStatus.isLaptop(hubName: hubName) ? CassetteIcon.laptop : .desktop)
                .uiImage(size: .row)
            )
            .renderingMode(.template)
            Text("Your computer")
              .cassetteText(.kicker)
          }
          .foregroundStyle(Color.cassette(.textSecondary))
          .padding(.bottom, 8)
          Text(hubName)
            .cassetteText(.heroName)
            .foregroundStyle(Color.cassette(.textPrimary))
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .shadow(color: Color.black.opacity(0.5), radius: 9, x: 0, y: 2)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
          // No word until the Mac's heartbeat has been read: never a guessed "in sync".
          if let answer = model.macState.answer {
            Text(answer)
              .cassetteText(.answer)
              .foregroundStyle(tint.textColor)
              .padding(.top, 6)
              .padding(.bottom, 10)
          }
          if let meta {
            Text(meta)
              .cassetteText(.meta)
              .foregroundStyle(Color.cassette(.textSecondary))
          }
        }
        .padding(.horizontal, 22)
        .padding(.top, fan.isEmpty ? 24 : 22)
      }
    }

    /// "1,204 albums · 13,880 songs", hidden until the cloud has said.
    private var meta: String? {
      guard let mac = model.mac, mac.mac != nil else { return nil }
      return "\(DeviceFormat.count(mac.albums)) albums · \(DeviceFormat.count(mac.tracks)) songs"
    }

    // MARK: Card

    private var scopeLabel: String? {
      guard let scope = model.device?.scope else { return nil }
      return scope == "selective" ? "Selective" : "Everything"
    }

    /// The card's rows, in order; a hairline sits between each pair.
    private var cardRows: [AnyView] {
      var rows: [AnyView] = []
      // Counted by the cloud on both sides (the phone groups albums its own way), so it
      // shows once this phone's payload is in.
      if let coverage = model.coverage {
        rows.append(AnyView(CoverageMeter(have: coverage.have, of: coverage.of)))
      }
      // Read-only: the sync scope is account-wide; the phone has no control for it yet.
      if let scopeLabel {
        rows.append(AnyView(DeviceValueRow(title: "Syncs", value: scopeLabel)))
      }
      if let ago = model.lastSyncedAgo {
        rows.append(AnyView(DeviceValueRow(title: "Last synced", value: ago)))
      }
      rows.append(AnyView(DeviceResyncRow(model: model)))
      return rows
    }

    private var card: some View {
      VStack(spacing: 0) {
        ForEach(Array(cardRows.enumerated()), id: \.offset) { index, row in
          if index > 0 { DeviceHairline() }
          row
        }
      }
      .background(
        RoundedRectangle(cornerRadius: CassetteRadius.card, style: .continuous)
          .fill(Color.cassette(.surfaceElevated))
      )
      .padding(.horizontal, 16)
      .padding(.top, 28)
    }

    // MARK: Shelf

    @ViewBuilder
    private var shelf: some View {
      if !model.newOnMac.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          CassetteHeadingText(shout: "NEW IN YOUR LIBRARY", answer: "lately", answerColor: tint.textColor)
            .padding(.horizontal, CassetteHeading.sideInset)
            .padding(.bottom, CassetteHeading.bottomSpacing)
          ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
              ForEach(model.newOnMac) { album in
                MacPlayTile(album: album)
              }
            }
            .padding(.horizontal, CassetteHeading.sideInset)
          }
        }
        .padding(.top, CassetteHeading.topSpacing)
      }
    }
  }

  // MARK: - MacPlayTile

  /// A 150pt cover that plays in one tap (the tile or its disc). Only on-phone albums get
  /// here, and OneTapPlay queues only what is on the phone.
  private struct MacPlayTile: View {
    let album: DeviceAlbum

    var body: some View {
      Button(action: play) {
        VStack(alignment: .leading, spacing: 2) {
          DeviceCoverView(
            path: album.coverPath,
            title: album.name,
            side: 150,
            radius: CassetteRadius.artworkTile
          )
          .padding(.bottom, 6)
          Text(album.name)
            .font(.cassetteDisplay(size: 16, weight: .semibold))
            .foregroundStyle(Color.cassette(.textPrimary))
            .lineLimit(1)
          Text(album.artist)
            .font(.cassette(.cardSubtitle))
            .foregroundStyle(Color.cassette(.textSecondary))
            .lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(album.artist.isEmpty ? album.name : "\(album.name), \(album.artist)")
      .accessibilityHint("Plays the album")
      .overlay(alignment: .topLeading) {
        // A sibling of the tile's button, never inside it (CassettePlayDisc).
        CassettePlayDisc(action: play)
          .padding(8)
          .frame(width: 150, height: 150, alignment: .bottomTrailing)
      }
    }

    private func play() {
      OneTapPlay.play(album.album)
    }
  }

  // MARK: - Card rows (shared with This Phone)

  /// How much of the Mac's library is on this phone: a 6pt bar (orange fill, live state)
  /// and one line.
  struct CoverageMeter: View {
    let have: Int
    let of: Int

    private var fraction: CGFloat {
      guard of > 0 else { return 0 }
      return min(1, CGFloat(have) / CGFloat(of))
    }

    private var line: String {
      have >= of
        ? "All \(DeviceFormat.count(of)) albums on this phone"
        : "\(DeviceFormat.count(have)) of \(DeviceFormat.count(of)) albums on this phone"
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Rectangle().fill(Color.cassette(.hairline))
            Rectangle()
              .fill(Color.cassette(.accentProgress))
              .frame(width: geo.size.width * fraction)
          }
          .clipShape(Capsule())
        }
        .frame(height: 6)
        Text(line)
          .font(.cassette(.caption))
          .foregroundStyle(Color.cassette(.textSecondary))
      }
      .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(line)
    }
  }

  /// A read-only row in a device card: label in Barlow, value in DM Mono ink2.
  struct DeviceValueRow: View {
    let title: String
    let value: String
    var chevron = false

    var body: some View {
      HStack(spacing: 12) {
        Text(title)
          .font(.cassette(.rowTitle))
          .foregroundStyle(Color.cassette(.textPrimary))
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(value)
          .font(.cassette(.caption))
          .foregroundStyle(Color.cassette(.textSecondary))
          .lineLimit(1)
        if chevron {
          Image(uiImage: CassetteIcon.chevronRight.uiImage(size: .row, weight: .semibold))
            .renderingMode(.template)
            .foregroundStyle(Color.cassette(.textTertiary))
            .accessibilityHidden(true)
        }
      }
      .padding(.leading, 16)
      .padding(.trailing, 14)
      .frame(maxWidth: .infinity, minHeight: 50)
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
    }
  }

  /// Resync Library inside a device card.
  struct DeviceResyncRow: View {
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
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, minHeight: 50)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(model.isResyncing ? "Resyncing" : "")
    }
  }

  /// The card's hairline between rows.
  struct DeviceHairline: View {
    var body: some View {
      Rectangle()
        .fill(Color.cassette(.textPrimary).opacity(0.07))
        .frame(height: 0.5)
    }
  }

#endif
