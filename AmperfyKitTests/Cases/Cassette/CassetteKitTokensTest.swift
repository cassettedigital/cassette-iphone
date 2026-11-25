//
//  CassetteKitTokensTest.swift
//  AmperfyKitTests
//
//  The iPhone's names for sizes are the shared kit's numbers, never its own (design wave 6):
//  CassetteKitTokens.swift is generated from packages/cassette-kit/tokens.json and copied in;
//  everything the app reads goes through it. These fail if a hand-kept table or the hand
//  mapping of a type role to its font drifts from the generated file.
//

@testable import AmperfyKit
import UIKit
import XCTest

@MainActor
final class CassetteKitTokensTest: XCTestCase {
  typealias K = CassetteKitTokens

  func testCornersOpacityAndSpacingAreTheKits() {
    XCTAssertEqual(CassetteRadius.artworkTile, K.Radius.artworkTile)
    XCTAssertEqual(CassetteRadius.artworkRow, K.Radius.artworkRow)
    XCTAssertEqual(CassetteRadius.small, K.Radius.small)
    XCTAssertEqual(CassetteRadius.control, K.Radius.control)
    XCTAssertEqual(CassetteRadius.panel, K.Radius.panel)
    XCTAssertEqual(CassetteRadius.card, K.Radius.card)
    XCTAssertEqual(CassetteRadius.large, K.Radius.large)
    XCTAssertEqual(CassetteRadius.sheet, K.Radius.sheet)
    XCTAssertEqual(CassetteRadius.pill, K.Radius.pill)
    XCTAssertEqual(CassetteRadius.litCard, K.Radius.litCard)
    XCTAssertEqual(CassetteRadius.genreTile, K.Radius.genreTile)
    XCTAssertEqual(CassetteRadius.iconTile, K.Radius.iconTile)
    XCTAssertEqual(CassetteRadius.playerArtwork, K.Radius.playerArtwork)
    XCTAssertEqual(CassetteRadius.station(side: 100), 100 * K.Shape.station)
    // D8: a card's corner on the phones is the kit's card corner
    XCTAssertEqual(CassetteRadius.card, K.Corner.card)

    XCTAssertEqual(CassetteOpacity.faint, K.Opacity.faint)
    XCTAssertEqual(CassetteOpacity.scrim, K.Opacity.scrim)
    XCTAssertEqual(CassetteOpacity.disabled, K.Opacity.disabled)

    let spacing = [
      CassetteTheme.Spacing.xs, CassetteTheme.Spacing.sm, CassetteTheme.Spacing.md,
      CassetteTheme.Spacing.lg, CassetteTheme.Spacing.xl, CassetteTheme.Spacing.xxl,
    ]
    XCTAssertEqual(
      spacing,
      [K.Space.xs, K.Space.sm, K.Space.md, K.Space.lg, K.Space.xl, K.Space.xxl]
    )
    for step in spacing {
      XCTAssertTrue(K.Space.list.contains(step), "\(step) is on the one spacing list")
    }

    XCTAssertEqual(CassetteHeading.topSpacing, K.Component.Heading.top)
    XCTAssertEqual(CassetteHeading.bottomSpacing, K.Component.Heading.bottom)
    XCTAssertEqual(CassetteHeading.sideInset, K.Component.Heading.side)
  }

  /// Every type role is the kit's size, tracking and capitals, set in the kit's face and weight.
  func testEveryTypeRoleIsTheKits() {
    for style in CassetteTextStyle.allCases {
      let role = style.kitRole
      XCTAssertEqual(UIFont.cassette(style).pointSize, role.size, "\(style) size")
      XCTAssertEqual(style.kern, role.kern, "\(style) tracking")
      XCTAssertEqual(style.isUppercased, role.upper, "\(style) capitals")
      XCTAssertEqual(style.kitFace.face, role.face, "\(style) face")
      // the selected tab label is the tab label made bold: the one weight the kit doesn't name
      if style != .tabLabelSelected {
        XCTAssertEqual(style.kitFace.weight, role.weight, "\(style) weight")
      }
    }
  }

  /// A key's words are the kit's key letters (C-rows-model): the pill role is their size and
  /// tracking, and a key is the action step tall.
  func testKeysAreTheKits() {
    XCTAssertEqual(CassetteTextStyle.pill.kitRole.size, K.Control.keyLetters)
    XCTAssertEqual(
      CassetteTextStyle.pill.kern,
      K.Control.keyLetters * K.Control.keyTrackEm,
      accuracy: 0.01
    )
    let key = CassetteKey.make(.fill, words: "Play", icon: .play)
    key.layoutIfNeeded()
    XCTAssertEqual(key.keyHeight, K.Control.action)
    XCTAssertEqual(key.configuration?.contentInsets.leading, K.Control.keyPad)
    XCTAssertEqual(key.configuration?.imagePadding, K.Control.keyGap)
  }

  /// The colour roles are the kit's paper, both papers.
  func testColoursAreTheKits() {
    func hex(_ color: UIColor, _ style: UIUserInterfaceStyle) -> UInt32 {
      let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
      return (UInt32((r * 255).rounded()) << 16) | (UInt32((g * 255).rounded()) << 8) |
        UInt32((b * 255).rounded())
    }
    XCTAssertEqual(hex(.cassette(.surfaceBase), .dark), K.Color.surfaceBase)
    XCTAssertEqual(hex(.cassette(.surfaceBase), .light), K.ColorLight.surfaceBase)
    XCTAssertEqual(hex(.cassette(.textPrimary), .dark), K.Color.textPrimary)
    XCTAssertEqual(hex(.cassette(.textPrimary), .light), K.ColorLight.textPrimary)
    XCTAssertEqual(hex(.cassette(.accentAnswer), .dark), K.Color.accentAnswer)
    XCTAssertEqual(hex(.cassette(.fillSelected), .light), K.ColorLight.fillSelected)
  }
}
