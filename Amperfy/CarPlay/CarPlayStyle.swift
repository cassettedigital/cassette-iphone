//
//  CarPlayStyle.swift
//  Amperfy
//
//  Cassette: the one place CarPlay images are made (design-system audit 2026-10-20, Wave 1).
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
@preconcurrency import CarPlay
import UIKit

/// Every image CarPlay shows comes from here, built against the CAR's trait collection,
/// never the phone's. The rules:
///
/// - **Glyphs and track numbers** are real bitmaps (CarPlay re-tints templates per background,
///   BUG-054), one per car appearance, registered in a `UIImageAsset`: white on the dark
///   appearance, near-black ink on the light one. The car picks the variant itself, so a
///   headlight flip mid-drive needs no rebuild (BUG-424). The appearance-less fallback is the
///   white variant, which is what every build before this one drew.
/// - **Covers** are the entity's real art, sized to the slot at the car's scale, artists
///   cropped to a circle. No cover means the **placeholder**: the same brand tile as the phone,
///   but with a legible initial (the phone's 8% ghost is invisible at car size, BUG-425).
/// - **Tab images** are the plain template assets on purpose: CarPlay tints its own tab bar and
///   offers no app tint, so they do not come through here.
/// - **No brand orange.** CarPlay chrome (now-playing buttons, accessories, tab selection) stays
///   the system's; the brand is carried by the glyph shapes and the placeholder tile.
/// - **Made artwork** (phone-taste): a mix or a mood is a picture we draw, so its picture can
///   carry our type (`wordArt`, `mosaicArt`). It is the only place our type reaches the car.
@MainActor
struct CarPlayStyle {
  /// The car's traits (`CPInterfaceController.carTraitCollection`).
  let traits: UITraitCollection

  enum Slot {
    /// A `CPListItem` row image.
    case row
    /// A `CPListImageRowItemRowElement` (Home shelf tile).
    case shelf

    var maximumSize: CGSize {
      switch self {
      case .row: return CPListItem.maximumImageSize
      case .shelf: return CPListImageRowItemRowElement.maximumImageSize
      }
    }
  }

  /// Glyph color on a dark car surface.
  static let inkOnDark = UIColor.white
  /// Glyph color on a light car surface: the brand's darkest ink, next to the car's black text.
  static let inkOnLight = UIColor.cassette(.textOnFill)
  /// The placeholder initial: legible on the brand tile at car size.
  static let placeholderMark = UIColor.cassette(.textSecondary).withAlphaComponent(0.65)

  private var scale: CGFloat {
    traits.displayScale > 0 ? traits.displayScale : UITraitCollection.current.displayScale
  }

  // MARK: Glyphs and numbers

  /// A row glyph (Shuffle, All Songs, browse buckets): Lucide or SF Symbol source.
  func glyph(_ source: UIImage, size: ArtworkIconSizeType = .small) -> UIImage {
    perAppearance { color in
      UIImage.carPlayGlyph(with: source, iconSizeType: size, color: color, scale: scale)
    }
  }

  /// The track number an album row shows in place of a cover (BUG-421).
  func trackNumber(_ number: Int) -> UIImage {
    perAppearance { color in
      UIImage.numberToImage(number: number, color: color, scale: scale)
    }
  }

  // MARK: Covers and placeholders

  /// A library entity's cover, or its placeholder when it has none.
  func artwork(
    for entity: AbstractLibraryEntity,
    artworkDisplayPreference: ArtworkDisplayPreference,
    slot: Slot = .row
  )
    -> UIImage {
    artwork(
      LibraryEntityImage.coverImage(
        libraryEntity: entity,
        artworkDisplayPreference: artworkDisplayPreference,
        useCache: false
      ),
      kind: entity.getDefaultArtworkType(),
      name: (entity as? PlayableContainable)?.name,
      circle: entity is Artist,
      slot: slot
    )
  }

  /// A row image for a playable: its track number when the list shows numbers, else its cover.
  func artwork(
    for playable: AbstractPlayable,
    isTrackDisplayed: Bool,
    artworkDisplayPreference: ArtworkDisplayPreference
  )
    -> UIImage {
    isTrackDisplayed
      ? trackNumber(playable.track)
      : artwork(for: playable, artworkDisplayPreference: artworkDisplayPreference)
  }

  /// Any cover, or the placeholder for `kind`/`name` when `image` is nil. Sized to the slot at
  /// the car's scale, circle-cropped for artists.
  func artwork(
    _ image: UIImage?,
    kind: ArtworkType,
    name: String?,
    circle: Bool = false,
    slot: Slot = .row
  )
    -> UIImage {
    let target = slotSize(slot)
    let source = image ?? UIImage.getGeneratedArtwork(
      theme: .defaultValue, // ignored by the renderer; the parameter goes with ThemePreference
      artworkType: kind,
      name: name,
      size: target,
      markColor: Self.placeholderMark,
      scale: scale
    )
    return wrap(fitted(source, into: target, circle: circle))
  }

  /// The placeholder kind for a Home shelf item (a `PlayableContainable` that may not be a
  /// library entity, e.g. a playlist).
  func artworkKind(of containable: PlayableContainable) -> ArtworkType {
    containable.getArtworkCollection(theme: .defaultValue).defaultArtworkType
  }

  // MARK: Our own artwork (phone-taste)

  /// The car mock's made artwork (car.module.css `.made`), as fractions of the tile's side: on a
  /// 104px tile the word is 19px Barlow ExtraBold, 8px from the sides and 7px from the bottom,
  /// with a 0.92 line height.
  private enum Made {
    static let textSize: CGFloat = 0.183
    static let sideInset: CGFloat = 0.077
    static let bottomInset: CGFloat = 0.067
    static let lineHeight: CGFloat = 0.92
    static let maxLines = 3
    /// The smallest the word steps down to, as a fraction of `textSize`.
    static let smallestText: CGFloat = 0.6
    /// The word art's gradient: the colour at 0, the sunken surface from 78% on, 140 degrees.
    static let gradientAngle: CGFloat = 140
    static let gradientStop: CGFloat = 0.78
    /// The mosaic's scrim: clear down to 30%, the sunken surface at 0.85 at the bottom.
    static let scrimStart: CGFloat = 0.3
    static let scrimAlpha: CGFloat = 0.85
  }

  /// A mood door, or a station with no logo: its colour running into the sunken surface, its
  /// name in our type along the bottom. Drawn square at the slot's size and the car's scale;
  /// the car may round the corners itself.
  func wordArt(word: String, color: UIColor, slot: Slot = .shelf) -> UIImage {
    let side = slotSize(slot).width
    return wrap(madeImage(side: side) { context, rect in
      Self.fillAngledGradient(
        context,
        rect: rect,
        from: color,
        to: UIColor.cassette(.surfaceSunken)
      )
      Self.drawMadeWord(word, side: side)
    })
  }

  /// The same word picture for the phone (founder, 2026-10-21: Home's radio tiles for a
  /// station with no logo were two initials on a flat colour, "gross"): the station's colour
  /// running into the sunken surface, its name in our type along the bottom, drawn square at
  /// `side` points and `scale`.
  /// `trailingReserve` (points) keeps the word clear of a play disc in the tile's corner.
  static func phoneWordArt(
    word: String,
    color: UIColor,
    side: CGFloat,
    scale: CGFloat,
    trailingReserve: CGFloat = 0
  ) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = true
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    return UIGraphicsImageRenderer(size: rect.size, format: format).image { renderer in
      fillAngledGradient(renderer.cgContext, rect: rect, from: color, to: UIColor.cassette(.surfaceSunken))
      drawMadeWord(word, side: side, trailingReserve: trailingReserve)
    }
  }

  /// A mood mix's drawn cover (cassette.digital draws it, its name already on it), sized to
  /// the slot at the car's scale.
  func drawnCover(_ image: UIImage, slot: Slot = .shelf) -> UIImage {
    wrap(fitted(image, into: slotSize(slot), circle: false))
  }

  /// A mix: four of its records aspect-filled into quadrants on the elevated surface, a scrim
  /// that darkens the bottom, then its name. Fewer than four covers leave the rest empty.
  func mosaicArt(covers: [UIImage], word: String, slot: Slot = .shelf) -> UIImage {
    let side = slotSize(slot).width
    return wrap(madeImage(side: side) { context, rect in
      UIColor.cassette(.surfaceElevated).setFill()
      context.fill(rect)
      let half = side / 2
      for (index, cover) in covers.prefix(4).enumerated() {
        let cell = CGRect(
          x: CGFloat(index % 2) * half,
          y: CGFloat(index / 2) * half,
          width: half,
          height: half
        )
        Self.drawAspectFill(cover, in: cell, context: context)
      }
      Self.fillScrim(context, rect: rect)
      Self.drawMadeWord(word, side: side)
    })
  }

  // MARK: Plumbing

  /// An opaque square canvas at the car's scale.
  private func madeImage(side: CGFloat, draw: (CGContext, CGRect) -> ()) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = true
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    return UIGraphicsImageRenderer(size: rect.size, format: format).image { renderer in
      draw(renderer.cgContext, rect)
    }
  }

  /// A CSS `linear-gradient(140deg, from, to 78%)`: 0 degrees points up and angles turn
  /// clockwise, and the line is long enough that its ends meet the far corners.
  private static func fillAngledGradient(
    _ context: CGContext,
    rect: CGRect,
    from: UIColor,
    to: UIColor
  ) {
    let radians = Made.gradientAngle * .pi / 180
    let dx = sin(radians)
    let dy = -cos(radians) // screen y grows downward
    let length = abs(rect.width * dx) + abs(rect.height * dy)
    let start = CGPoint(x: rect.midX - dx * length / 2, y: rect.midY - dy * length / 2)
    let end = CGPoint(
      x: start.x + dx * length * Made.gradientStop,
      y: start.y + dy * length * Made.gradientStop
    )
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let gradient = CGGradient(
            colorsSpace: space,
            colors: [from.cgColor, to.cgColor] as CFArray,
            locations: [0, 1]
          )
    else {
      to.setFill()
      context.fill(rect)
      return
    }
    context.drawLinearGradient(
      gradient,
      start: start,
      end: end,
      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
  }

  /// The mosaic's scrim, top to bottom: clear until 30%, then the sunken surface at 0.85.
  private static func fillScrim(_ context: CGContext, rect: CGRect) {
    let sunken = UIColor.cassette(.surfaceSunken)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let gradient = CGGradient(
            colorsSpace: space,
            colors: [
              sunken.withAlphaComponent(0).cgColor,
              sunken.withAlphaComponent(Made.scrimAlpha).cgColor,
            ] as CFArray,
            locations: [0, 1]
          )
    else { return }
    context.drawLinearGradient(
      gradient,
      start: CGPoint(x: rect.midX, y: rect.minY + rect.height * Made.scrimStart),
      end: CGPoint(x: rect.midX, y: rect.maxY),
      options: [.drawsAfterEndLocation]
    )
  }

  /// `image` aspect-filled into `cell`, centered and clipped to it.
  private static func drawAspectFill(_ image: UIImage, in cell: CGRect, context: CGContext) {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return }
    let fill = max(cell.width / size.width, cell.height / size.height)
    let drawn = CGSize(width: size.width * fill, height: size.height * fill)
    context.saveGState()
    context.clip(to: cell)
    image.draw(in: CGRect(
      x: cell.midX - drawn.width / 2,
      y: cell.midY - drawn.height / 2,
      width: drawn.width,
      height: drawn.height
    ))
    context.restoreGState()
  }

  /// The word in our type: upper-cased, bottom-anchored, wrapped to at most three lines, and
  /// stepped down in size while a line still overflows. At the smallest size a name that still
  /// does not fit keeps its first three lines; the title under the tile carries it in full.
  private static func drawMadeWord(_ word: String, side: CGFloat, trailingReserve: CGFloat = 0) {
    let text = word.uppercased()
    let inset = side * Made.sideInset
    let width = side - inset * 2 - max(0, trailingReserve - inset)
    let largest = side * Made.textSize
    let smallest = largest * Made.smallestText
    var size = largest
    var font = UIFont.cassetteDisplay(size: size, weight: .extraBold)
    var lines = wrapLines(text, font: font, width: width)
    while size > smallest,
          lines.count > Made.maxLines || lines.contains(where: { lineWidth($0, font) > width }) {
      size = max(smallest, size * 0.94)
      font = UIFont.cassetteDisplay(size: size, weight: .extraBold)
      lines = wrapLines(text, font: font, width: width)
    }
    lines = Array(lines.prefix(Made.maxLines))
    guard !lines.isEmpty else { return }

    // CSS line boxes: each line is `lineHeight` tall with the glyphs centred in it (a
    // negative half-leading when the line is tighter than the font), the last box ending at
    // the bottom inset.
    let lineHeight = size * Made.lineHeight
    let halfLeading = (lineHeight - (font.ascender - font.descender)) / 2
    let blockTop = side - side * Made.bottomInset - CGFloat(lines.count) * lineHeight
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: UIColor.cassette(.textPrimary),
    ]
    for (index, line) in lines.enumerated() {
      let lineTop = blockTop + CGFloat(index) * lineHeight + halfLeading
      (line as NSString).draw(at: CGPoint(x: inset, y: lineTop), withAttributes: attributes)
    }
  }

  /// Greedy word wrap. A single word wider than `width` gets a line of its own (and makes the
  /// caller step the size down).
  private static func wrapLines(_ text: String, font: UIFont, width: CGFloat) -> [String] {
    var lines = [String]()
    var current = ""
    for word in text.split(separator: " ").map(String.init) {
      let candidate = current.isEmpty ? word : current + " " + word
      if current.isEmpty || lineWidth(candidate, font) <= width {
        current = candidate
      } else {
        lines.append(current)
        current = word
      }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
  }

  private static func lineWidth(_ line: String, _ font: UIFont) -> CGFloat {
    (line as NSString).size(withAttributes: [.font: font]).width
  }

  private func slotSize(_ slot: Slot) -> CGSize {
    let max = slot.maximumSize
    let side = Swift.max(max.width, max.height)
    // `maximumImageSize` is zero before a head unit has connected on some runtimes.
    return side > 0 ? CGSize(width: side, height: side) : CGSize(width: 90, height: 90)
  }

  /// Scale `image` down (never up) to fit `target` at the car's scale; crop to a circle when asked.
  private func fitted(_ image: UIImage, into target: CGSize, circle: Bool) -> UIImage {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return image }
    let ratio = min(1, target.width / size.width, target.height / size.height)
    var drawSize = CGSize(width: size.width * ratio, height: size.height * ratio)
    if circle {
      let side = min(drawSize.width, drawSize.height)
      drawSize = CGSize(width: side, height: side)
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    return UIGraphicsImageRenderer(size: drawSize, format: format).image { _ in
      if circle {
        UIBezierPath(ovalIn: CGRect(origin: .zero, size: drawSize)).addClip()
      }
      // Aspect-fill the (possibly square-cropped) canvas, centered.
      let fill = max(drawSize.width / size.width, drawSize.height / size.height)
      let filled = CGSize(width: size.width * fill, height: size.height * fill)
      image.draw(in: CGRect(
        x: (drawSize.width - filled.width) / 2,
        y: (drawSize.height - filled.height) / 2,
        width: filled.width,
        height: filled.height
      ))
    }
  }

  /// One appearance-independent image, attached to the car's scale.
  private func wrap(_ image: UIImage) -> UIImage {
    let asset = UIImageAsset()
    let base = UITraitCollection(displayScale: scale)
    asset.register(image, with: base)
    return asset.image(with: traits)
  }

  /// One bitmap per car appearance in a single asset, so the car resolves the variant itself.
  private func perAppearance(_ draw: (UIColor) -> UIImage) -> UIImage {
    let onDark = draw(Self.inkOnDark)
    let onLight = draw(Self.inkOnLight)
    let base = UITraitCollection(displayScale: scale)
    let asset = UIImageAsset()
    // Registered first and appearance-less: what a car that reports no appearance gets.
    asset.register(onDark, with: base)
    asset.register(onDark, with: base.modifyingTraits { $0.userInterfaceStyle = .dark })
    asset.register(onLight, with: base.modifyingTraits { $0.userInterfaceStyle = .light })
    return asset.image(with: traits)
  }
}
