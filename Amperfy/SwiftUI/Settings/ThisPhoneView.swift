//
//  ThisPhoneView.swift
//  Amperfy
//
//  Cassette fork (phone-taste): This phone, from Settings. What is here and what it
//  weighs, biggest first, because the reason to open it is room. Swipe an album to take
//  it off; KEPT OFF puts one back.
//
//  The page is ONE List (so the album rows can take swipe actions), never a List inside a
//  ScrollView.
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

  // MARK: - ThisPhoneView

  struct ThisPhoneView: View {
    @ObservedObject
    var model: DevicePagesModel

    @State
    private var downloadQuality = ""
    @State
    private var freeSpace = ""
    /// The album whose Remove is waiting for the confirm.
    @State
    private var pendingRemoval: DeviceOwnershipManager.OnPhoneAlbum?
    /// The device payload is a heavy server read: once per page open, not again on the way
    /// back from Download quality.
    @State
    private var didOpen = false

    private var albums: [DeviceOwnershipManager.OnPhoneAlbum] {
      (model.phone?.albums ?? []).sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
      List {
        header
          .plainDeviceRow()

        qualityRow
          .plainDeviceRow()
        if !freeSpace.isEmpty {
          freeRow
            .plainDeviceRow()
        }

        if !model.keptOff.isEmpty {
          KeptOffShelf(model: model)
            .plainDeviceRow()
        }

        if !albums.isEmpty {
          CassetteHeadingText(
            shout: "BIGGEST",
            answer: "first",
            answerColor: Color.cassette(.textSecondary)
          )
          .padding(.horizontal, CassetteHeading.sideInset)
          .padding(.top, CassetteHeading.topSpacing)
          .padding(.bottom, CassetteHeading.bottomSpacing)
          .plainDeviceRow()

          ForEach(albums) { album in
            BiggestRow(album: album, model: model)
              .plainDeviceRow()
              .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // Removal is the on-device mode's (as the album menu offers it).
                // No .destructive role: with one, the List takes the row out before the
                // confirm is answered. The ownership notification removes it for real.
                if CassetteLibraryFilterProvider.shared.isOnDeviceOnly {
                  Button("Remove") {
                    pendingRemoval = album
                  }
                  .tint(Color.cassette(.danger))
                }
              }
          }
        }

        Color.clear
          .frame(height: 48)
          .plainDeviceRow()
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(Color.cassette(.surfaceBase))
      .toolbarBackground(Color.cassette(.surfaceBase), for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .alert(
        removalTitle,
        isPresented: Binding(
          get: { pendingRemoval != nil },
          set: { if !$0 { pendingRemoval = nil } }
        ),
        presenting: pendingRemoval
      ) { album in
        Button("Remove", role: .destructive) {
          model.remove(albumId: album.albumId)
        }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        // The album menu's confirm, word for word (EntityPreviewVC).
        Text("It stays on your computer.")
      }
      .onAppear {
        model.pageAppeared()
        downloadQuality = DevicePagesModel.downloadQualityLabel(storage: appDelegate.storage)
        freeSpace = Self.freeSpace()
        guard !didOpen else { return }
        didOpen = true
        model.phonePageOpened()
      }
      .onDisappear {
        model.pageDisappeared()
      }
    }

    private var removalTitle: String {
      guard let pendingRemoval else { return "" }
      return "Remove \u{201C}\(pendingRemoval.name)\u{201D} from this \(UIDevice.cassetteDeviceWord)?"
    }

    private static func freeSpace() -> String {
      let home = URL(fileURLWithPath: NSHomeDirectory())
      let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
        .volumeAvailableCapacityForImportantUsage ?? 0
      return free > 0 ? DeviceFormat.size(free) : ""
    }

    // MARK: Header

    private var header: some View {
      let count = model.phone?.albums.count ?? 0
      let songs = model.phone?.tracks ?? 0
      let bytes = model.phone?.bytes ?? 0
      return VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 6) {
          Image(uiImage: DeviceFormat.deviceIcon.uiImage(size: .row))
            .renderingMode(.template)
          Text("On this \(DeviceFormat.deviceName)")
            .cassetteText(.kicker)
        }
        .foregroundStyle(Color.cassette(.textSecondary))
        .padding(.bottom, 8)
        Text(count == 1 ? "1 album" : "\(DeviceFormat.count(count)) albums")
          .cassetteText(.pageTitle)
          .foregroundStyle(Color.cassette(.textPrimary))
          .accessibilityAddTraits(.isHeader)
        Text("\(DeviceFormat.count(songs)) \(songs == 1 ? "song" : "songs") · \(DeviceFormat.size(bytes))")
          .cassetteText(.meta)
          .foregroundStyle(Color.cassette(.textSecondary))
          .padding(.top, 10)
      }
      .padding(.horizontal, 22)
      .padding(.top, 8)
      .padding(.bottom, 28)
      .frame(maxWidth: .infinity, alignment: .leading)
      .redacted(reason: model.phone == nil ? .placeholder : [])
    }

    // MARK: Quality card

    /// Download quality, the card's first row: the same menu as Settings' row.
    private var qualityRow: some View {
      DownloadQualityMenu(chosen: { downloadQuality = $0 }) {
        DeviceValueRow(title: "Download quality", value: downloadQuality, trailing: .chooses)
      }
      .background(
        UnevenRoundedRectangle(
          topLeadingRadius: CassetteRadius.card,
          bottomLeadingRadius: freeSpace.isEmpty ? CassetteRadius.card : 0,
          bottomTrailingRadius: freeSpace.isEmpty ? CassetteRadius.card : 0,
          topTrailingRadius: CassetteRadius.card,
          style: .continuous
        )
        .fill(Color.cassette(.surfaceElevated))
      )
      .padding(.horizontal, 16)
    }

    /// Free on this phone: the room left, which the phone knows exactly.
    private var freeRow: some View {
      VStack(spacing: 0) {
        DeviceHairline()
        DeviceValueRow(title: "Free on this \(UIDevice.cassetteDeviceWord)", value: freeSpace)
      }
      .background(
        UnevenRoundedRectangle(
          topLeadingRadius: 0,
          bottomLeadingRadius: CassetteRadius.card,
          bottomTrailingRadius: CassetteRadius.card,
          topTrailingRadius: 0,
          style: .continuous
        )
        .fill(Color.cassette(.surfaceElevated))
      )
      .padding(.horizontal, 16)
    }
  }

  // MARK: - BiggestRow

  /// One album on the phone: its cover, title, "artist · n songs", and its size.
  private struct BiggestRow: View {
    let album: DeviceOwnershipManager.OnPhoneAlbum
    @ObservedObject
    var model: DevicePagesModel

    @State
    private var coverPath: String?

    private var subtitle: String {
      let songs = album.tracks == 1 ? "1 song" : "\(album.tracks) songs"
      return album.artist.isEmpty ? songs : "\(album.artist) · \(songs)"
    }

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          DeviceCoverView(
            path: coverPath,
            title: album.name,
            side: 48,
            radius: CassetteRadius.artworkRow
          )
          .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(album.name)
              .font(.cassetteDisplay(size: 17, weight: .semibold))
              .foregroundStyle(Color.cassette(.textPrimary))
              .lineLimit(1)
            Text(subtitle)
              .font(.cassette(.cardSubtitle))
              .foregroundStyle(Color.cassette(.textSecondary))
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          Text(DeviceFormat.size(album.bytes))
            .font(.cassette(.caption))
            .foregroundStyle(Color.cassette(.textSecondary))
        }
        .padding(.vertical, 8)
        Rectangle()
          .fill(Color.cassette(.textPrimary).opacity(0.08))
          .frame(height: 0.5)
      }
      .padding(.horizontal, 20)
      .background(Color.cassette(.surfaceBase))
      .accessibilityElement(children: .combine)
      .task(id: album.albumId) {
        coverPath = model.coverPath(albumId: album.albumId)
      }
    }
  }

  // MARK: - KeptOffShelf

  /// KEPT OFF / this phone: albums removed from this phone, from a fresh device payload.
  /// Tapping one puts it back. They are not on the phone, so nothing here plays.
  private struct KeptOffShelf: View {
    @ObservedObject
    var model: DevicePagesModel

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        CassetteHeadingText(
          shout: "KEPT OFF",
          answer: "this \(UIDevice.cassetteDeviceWord)",
          answerColor: Color.cassette(.textSecondary)
        )
        .padding(.horizontal, CassetteHeading.sideInset)
        .padding(.bottom, CassetteHeading.bottomSpacing)
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(alignment: .top, spacing: 12) {
            ForEach(model.keptOff) { tile in
              Button {
                Task { await model.putBack(tile) }
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  DeviceCoverView(
                    path: tile.coverPath,
                    title: tile.row.albumName,
                    side: 150,
                    radius: CassetteRadius.artworkTile,
                    remote: tile.remoteCover
                  )
                  .opacity(model.puttingBack.contains(tile.id) ? 0.5 : 1)
                  .padding(.bottom, 6)
                  Text(tile.row.albumName)
                    .font(.cassetteDisplay(size: 16, weight: .semibold))
                    .foregroundStyle(Color.cassette(.textPrimary))
                    .lineLimit(1)
                  Text("Put back")
                    .font(.cassette(.cardSubtitle))
                    .foregroundStyle(Color.cassette(.textSecondary))
                    .lineLimit(1)
                }
                .frame(width: 150, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(model.puttingBack.contains(tile.id))
              .accessibilityLabel("Put back \(tile.row.albumName)")
            }
          }
          .padding(.horizontal, CassetteHeading.sideInset)
        }
        if model.putBackFailed {
          Text("Couldn't put it back.")
            .font(.cassette(.caption))
            .foregroundStyle(Color.cassette(.textSecondary))
            .padding(.horizontal, CassetteHeading.sideInset)
            .padding(.top, 8)
        }
      }
      .padding(.top, CassetteHeading.topSpacing)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Row style

  extension View {
    /// A row of the page's single plain List: no insets, no separator, no background.
    fileprivate func plainDeviceRow() -> some View {
      listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
  }

#endif
