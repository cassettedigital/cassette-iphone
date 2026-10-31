//
//  MoodDoorTile.swift
//  Amperfy
//
//  Cassette: one Home "Mood" tile. Same glow-wash + procedural-pattern
//  treatment as the web app's tiles (color wash behind, MoodDoorArt motif,
//  name overlaid at the bottom) - NOT flattened to a plain color block; the
//  CONTENT stays colorful/textured like web.
//  No "Playlist" kicker or sub-copy line on the card itself - just the name.
//
//  phone-taste (approved phone mock, 2026-10-20): the tile sits in the shelf geometry,
//  a 150pt square at the control radius (the mock's `.door`), on bg3 with the colour
//  wash running from the top-leading corner to clear at about 70%, and the name in
//  Barlow Bold 20 12pt in from the bottom-left with a soft shadow (`.door > b`).
//

import AmperfyKit
import SwiftUI

// MARK: - MoodDoorTile

struct MoodDoorTile: View {
  /// The mock's `.door`: a 150pt square, the same side as a cover tile.
  static let side: CGFloat = 150
  /// The name's inset from the bottom-left corner (`.door > b`).
  static let labelInset: CGFloat = 12

  let door: MoodDoor
  let isBusy: Bool
  let onTap: () -> ()

  private var color: Color {
    Color(hexString: door.hexColor) ?? CoverTint.neutral.textColor // not orange: nothing is live here (I-T4)
  }

  var body: some View {
    Button(action: onTap) {
      ZStack(alignment: .bottomLeading) {
        Color.cassette(.surfaceElevated)

        LinearGradient(
          stops: [
            .init(color: color.opacity(0.4), location: 0),
            .init(color: .clear, location: 0.7),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )

        MoodDoorArt(shape: door.shape, color: color)

        MoodTileLabel(text: door.label)

        if isBusy {
          Color.cassette(.surfaceSunken).opacity(0.35)
          ProgressView()
            .tint(Color.cassette(.textPrimary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(width: Self.side, height: Self.side)
      .clipShape(RoundedRectangle(cornerRadius: CassetteRadius.control))
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
  }
}

// MARK: - MoodTileLabel

/// The name on a Mood tile (a door, or Lately): Barlow Bold 20 in ink, one line, 12pt in
/// from the bottom-left, with a soft dark shadow so it reads over a cover or a motif.
struct MoodTileLabel: View {
  let text: String

  var body: some View {
    Text(text)
      .font(Font.cassette(.tileLabel))
      .foregroundStyle(Color.cassette(.textPrimary))
      .lineLimit(1)
      .shadow(color: Color.cassette(.surfaceSunken).opacity(0.6), radius: 4, x: 0, y: 1)
      .padding(MoodDoorTile.labelInset)
  }
}
