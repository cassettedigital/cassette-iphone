//
//  CassetteTokens.swift
//  AmperfyKit — Cassette Player iOS fork
//
//  The semantic tier of the design system (design-system audit 2026-10-20, Wave 2).
//
//  Screens ask for a ROLE ("secondary text", "raised surface"), never a palette step
//  ("ink2", "bg2"). The palette in `CassetteTheme.UIColors` / `.Colors` is what the roles
//  resolve to; it stays public only until every call site has moved, then it goes private
//  so the compiler is the gate. One table below feeds UIKit and SwiftUI alike, the same way
//  `CassetteTextStyle` feeds `UIFont.cassette` and `Font.cassette`.
//
//  Usage: `label.textColor = .cassette(.textSecondary)`,
//         `.foregroundStyle(Color.cassette(.textSecondary))`,
//         `layer.cornerRadius = CassetteRadius.card`.
//
//  CarPlay draws none of these: its template content follows the car (`CarPlayStyle`).
//

import SwiftUI
import UIKit

// MARK: - CassetteColorRole

public enum CassetteColorRole: CaseIterable, Sendable {
  // MARK: Surfaces (darkest first)

  /// Behind the now-playing artwork and the player sheets. Darker than `surfaceBase`.
  case surfaceSunken
  /// The page: every list, grid and screen background.
  case surfaceBase
  /// A card, a banner, the tab bar, a grouped settings row.
  case surfaceRaised
  /// Something on a raised surface: a placeholder tile, a chip, a pressed row.
  case surfaceElevated
  /// Borders, hairlines, the nav bar shadow, tracks of an unfilled slider.
  case hairline

  // MARK: Text and icons

  /// Titles and body text; primary icons and the global tint.
  case textPrimary
  /// Subtitles, metadata, secondary icons, back-button titles.
  case textSecondary
  /// The quietest readable text: track numbers, footers, unselected tab labels.
  /// #9C8D70 since 2026-10-29 (the founder: "make too faint text go away"): 4.6:1 or better on
  /// every dark surface, where #6E6050 read 2.5 to 3.0:1 (audit A11Y-3, Q19).
  case textTertiary
  /// Text and icons sitting on `fillSelected` or on `accentProgress`.
  case textOnFill

  // MARK: Fills

  /// A selected or ON control: the selected segment, a switch that is on, a filled toggle.
  case fillSelected

  // MARK: Accent and state

  /// The one brand accent, for live state only: playback progress, the now-playing
  /// waveform, Shuffle on (and sync progress). Reserved; see `theme/cassette-tokens.md`.
  case accentProgress
  /// The answer voice of a Home row heading ("ON REPEAT  lately"), in brand orange. Home
  /// row answers ONLY. Unlit pages pass `.textSecondary`; pages lit by a record pass
  /// `CoverTint.text`.
  case accentAnswer
  /// Destructive actions and errors (web `.cs-btn-danger`).
  case danger
  /// Something worked.
  case success
  /// Needs attention, not an error.
  case warning

  public var uiColor: UIColor {
    let p = CassetteTheme.UIColors.self
    switch self {
    case .surfaceSunken: return p.bg4
    case .surfaceBase: return p.bg
    case .surfaceRaised: return p.bg2
    case .surfaceElevated: return p.bg3
    case .hairline: return p.ink4
    case .textPrimary: return p.ink
    case .textSecondary: return p.ink2
    case .textTertiary: return p.ink3
    case .textOnFill: return p.bg
    case .fillSelected: return p.ink
    case .accentProgress: return p.orange
    case .accentAnswer: return p.orange
    case .danger: return p.rust
    case .success: return p.sage
    case .warning: return p.amber
    }
  }
}

extension UIColor {
  /// The color for a design-system role. See `CassetteColorRole`.
  public static func cassette(_ role: CassetteColorRole) -> UIColor {
    role.uiColor
  }
}

extension Color {
  /// The color for a design-system role. See `CassetteColorRole`.
  public static func cassette(_ role: CassetteColorRole) -> Color {
    Color(uiColor: role.uiColor)
  }
}

// MARK: - CassetteRadius

/// Every corner radius in the app, by what it rounds. The values are today's, unchanged:
/// consolidating them (for example artwork 3 and 5 into one) is a visual decision, made here
/// once when it is made. `CassetteTheme.Radius` and Amperfy's `CornerRadius` both resolve to
/// these.
public enum CassetteRadius {
  /// Album art in carousels, grids and the detail header.
  public static let artworkTile: CGFloat = 3
  /// Album art in list rows and the players.
  public static let artworkRow: CGFloat = 5
  /// Small controls and chips.
  public static let small: CGFloat = 4
  /// Buttons, fields, the radio dial tiles.
  public static let control: CGFloat = 8
  /// Grouped panels.
  public static let panel: CGFloat = 12
  /// Cards and banners (the sync banner, settings cards).
  public static let card: CGFloat = 14
  /// Amperfy's large rounding (popups).
  public static let large: CGFloat = 15
  /// Sheets presented over the app.
  public static let sheet: CGFloat = 28
  /// Fully round ends (capsules); use with a height under 200pt.
  public static let pill: CGFloat = 100
  /// A card lit by its record: the Resume card, the search top result.
  public static let litCard: CGFloat = 18
  /// A genre tile on Search.
  public static let genreTile: CGFloat = 10
  /// A device icon tile in Settings.
  public static let iconTile: CGFloat = 9
  /// The Now Playing cover.
  public static let playerArtwork: CGFloat = 8

  /// A station's own mark (its logo or its word art), wherever it stands for the station: rounded at
  /// a share of its side, the app icon's shape, so a station never reads as an album (the founder,
  /// 2026-10-29, after the Mac's 10-22 call). The share is the shared kit's (tokens.json
  /// `shape.station`, generated into CassetteKitTokens.swift), the first thing this app reads from
  /// it. What a station is playing (a show's picture, a record) keeps a cover's corners. Use with
  /// `cornerCurve = .continuous`.
  public static func station(side: CGFloat) -> CGFloat {
    side * CassetteKitTokens.Shape.station
  }
}

// MARK: - CassetteOpacity

/// The alpha steps the app uses, so "pressed" and "disabled" mean one thing everywhere.
public enum CassetteOpacity {
  /// A barely-there wash, such as a ghost initial or a pressed highlight on dark.
  public static let faint: CGFloat = 0.08
  /// A scrim over content behind a sheet or banner.
  public static let scrim: CGFloat = 0.5
  /// A control that cannot be used right now.
  public static let disabled: CGFloat = 0.4
}

// MARK: - CoverTint

/// The colour of a record, read from its own cover on the phone (founder, 2026-10-20:
/// pages are lit by the record, not by brand orange). A straight port of the approved
/// mock's math, kept bit-for-bit: `coverColor()` in proto/home-taste/color.ts reads the
/// base, and proto/phone-taste/Tinted.tsx lifts it (`--tint`, `--tint-text`).
///
///   base   the cover's strongest hue family, pushed toward a poster colour
///   glow   `brighten(base, 0.42)`, the mock's `--tint`: shadows and small washes
///   text   `readable(base)`, the mock's `--tint-text`: lifted until it reads at 4.5:1 or
///          better on the page (#1C1914), for artist names, track numbers and answers
///
/// Stored as 0xRRGGBB integers so the value is Sendable and Hashable; colours are built
/// on read. `neutral` is the only fallback (never orange): a cover that cannot be read,
/// or a page whose cover has not been read yet.
extension Notification.Name {
  /// Posted on the main actor when `CoverTint.nowPlaying` changes.
  public static let cassetteNowPlayingTintChanged = Notification.Name("cassette.nowPlayingTintChanged")
}

public struct CoverTint: Sendable, Hashable {
  /// 0xRRGGBB, the mock's `coverColor()`.
  public let baseRGB: UInt32
  /// 0xRRGGBB, `brighten(base, 0.42)`, the mock's `--tint`.
  public let glowRGB: UInt32
  /// 0xRRGGBB, `readable(base)`: at least 4.5:1 on #1C1914, the mock's `--tint-text`.
  public let textRGB: UInt32

  public init(baseRGB: UInt32) {
    let base = baseRGB & 0xFFFFFF
    self.baseRGB = base
    self.glowRGB = CoverTintMath.brighten(base, 0.42)
    self.textRGB = CoverTintMath.readable(base)
  }

  public var base: UIColor { CoverTintMath.color(baseRGB) }
  public var glow: UIColor { CoverTintMath.color(glowRGB) }
  public var text: UIColor { CoverTintMath.color(textRGB) }
  public var textColor: Color { Color(uiColor: text) }

  /// The glow mixed toward black in sRGB (`color-mix(in srgb, tint X%, black)`): a cover's
  /// drop shadow. `strength` 0.4 is the detail hero, 0.45 the Resume card.
  public func shadow(_ strength: CGFloat) -> UIColor {
    let k = max(0, min(1, strength))
    return CoverTintMath.mix(glowRGB, 0x000000, share: k)
  }

  /// Ink mixed with the glow in sRGB (`color-mix(in srgb, ink X%, tint)`): a kicker over a
  /// lit card. 0.75 on the Resume card, 0.70 on Now Playing.
  public func kickerInk(inkShare: CGFloat = 0.75) -> UIColor {
    let k = max(0, min(1, inkShare))
    return CoverTintMath.mix(CoverTintMath.ink, glowRGB, share: k)
  }

  /// The only fallback: a warm neutral (glow #A17236, text #D4AE7D). Never orange.
  public static let neutral = CoverTint(baseRGB: 0x6B5A44)

  /// A destructive word (Sign Out, Delete) in the danger colour lifted to read 4.5:1 on every
  /// surface (I-T3: rust #B84830 is 3.34:1). The rust itself stays for fills and swipes.
  public static var dangerText: UIColor { CoverTintMath.color(CoverTintMath.readable(0xB84830)) }

  /// The colour of the record playing now (founder, 2026-10-21: the playing row's bars and
  /// the scrubbers speak in the record's colour, like its artist name, instead of brand
  /// orange). Set by whoever reads the playing cover: the mini player on every track change
  /// and Now Playing. `neutral` when nothing plays or the cover cannot be read. Readers use
  /// `text`, which reads at 4.5:1 or better on the page; they listen for
  /// `.cassetteNowPlayingTintChanged`.
  @MainActor public static var nowPlaying: CoverTint = .neutral {
    didSet {
      guard nowPlaying != oldValue else { return }
      NotificationCenter.default.post(name: .cassetteNowPlayingTintChanged, object: nil)
    }
  }

  // MARK: Reading a cover

  /// The mock's `coverColor()`: draw the cover at 24x24, weight each saturated mid-tone
  /// pixel into one of 12 hue bins, take the strongest bin (or the plain average when no
  /// bin is strong), then push it toward a poster colour. Pure; safe off the main thread.
  public static func extract(from image: CGImage) -> CoverTint {
    guard let base = CoverTintMath.coverColor(image) else { return .neutral }
    return CoverTint(baseRGB: base)
  }

  /// `extract(from:)` for a UIImage; `neutral` when it has no bitmap.
  public static func extract(from image: UIImage) -> CoverTint {
    guard let cgImage = image.cgImage else { return .neutral }
    return extract(from: cgImage)
  }

  // MARK: Cache

  private final class CoverTintBox: Sendable {
    let value: CoverTint
    init(_ value: CoverTint) { self.value = value }
  }

  // NSCache is internally thread-safe; the unchecked annotation satisfies strict
  // concurrency for the shared static (the AmbientBackdropCache pattern).
  nonisolated(unsafe) private static let cache = NSCache<NSString, CoverTintBox>()

  /// The tint already read for `key` (a `cacheKey(forCoverPath:)`, or a playlist's cover
  /// key), if any. For a cover file, `cached(coverPath:)` builds the key.
  public static func cached(key: String) -> CoverTint? {
    cache.object(forKey: key as NSString)?.value
  }

  /// The tint for an image already in hand (a playlist's pick or preset, Now Playing's
  /// decoded cover): from the cache, else read off the main thread and cached under `key`.
  public static func resolve(image: UIImage, key: String) async -> CoverTint {
    if let hit = cached(key: key) { return hit }
    let tint = await Task.detached(priority: .utility) {
      extract(from: image)
    }.value
    cache.setObject(CoverTintBox(tint), forKey: key as NSString)
    return tint
  }

  /// The one cache key for a cover on disk: its path plus the modification date of the file
  /// the colour is read from (the small-surface thumb when there is one, else the full
  /// cover). A cover re-downloaded or re-picked at the SAME path gets a new key, so every lit
  /// surface (Now Playing, the record pages, the Resume and Search cards, the Mac page, the
  /// glows) moves to its new colour together instead of keeping the old one until restart.
  public static func cacheKey(forCoverPath coverPath: String) -> String {
    let source = CoverImageStore.preferredSourcePath(forFullPath: coverPath, smallSurface: true)
    guard let modified = (try? FileManager.default.attributesOfItem(atPath: source))?[
      .modificationDate
    ] as? Date else { return coverPath }
    return "\(coverPath)#\(modified.timeIntervalSince1970)"
  }

  /// The tint already read for the cover at `coverPath`, under `cacheKey(forCoverPath:)`.
  public static func cached(coverPath: String) -> CoverTint? {
    guard !coverPath.isEmpty else { return nil }
    return cached(key: cacheKey(forCoverPath: coverPath))
  }

  /// The tint for a cover on disk, under `cacheKey(forCoverPath:)`: always read from the
  /// same small decode (the thumb when there is one), off the main thread, so one record
  /// has one colour on every surface. nil when the file is missing or cannot be decoded, so
  /// the caller keeps `neutral`.
  public static func resolve(coverPath: String) async -> CoverTint? {
    guard !coverPath.isEmpty else { return nil }
    let key = cacheKey(forCoverPath: coverPath)
    if let hit = cached(key: key) { return hit }
    let tint = await Task.detached(priority: .utility) { () -> CoverTint? in
      let source = CoverImageStore.preferredSourcePath(forFullPath: coverPath, smallSurface: true)
      guard let image = CoverImageStore.downsampledImage(atPath: source, maxPixel: 64)
      else { return nil }
      return extract(from: image)
    }.value
    if let tint {
      cache.setObject(CoverTintBox(tint), forKey: key as NSString)
    }
    return tint
  }

  /// Convenience for a page that only needs the readable text colour of a cover on disk.
  public static func readableText(forCoverAt coverPath: String) async -> UIColor? {
    await resolve(coverPath: coverPath)?.text
  }
}

// MARK: - CoverTintMath

/// The mock's colour functions, in Double, verbatim (home-taste/color.ts rgbToHsl,
/// hslToHex, brighten, coverColor; phone-taste/Tinted.tsx luminance, contrast, readable).
/// Channels are 0...255; colours are 0xRRGGBB. hslToRGB rounds each channel to 8 bits
/// exactly as hslToHex does, and readable() runs the same accumulating float loop as the
/// JS, so a cover reads the same colour here as on the web mock.
enum CoverTintMath {
  /// The page (#1C1914, `surfaceBase`).
  static let page: UInt32 = 0x1C1914
  /// What a lifted colour must read on: the lightest surface it sits on, the elevated card
  /// (#2A261E, `surfaceElevated`), so it holds 4.5:1 on cards as well as the page (I-T5; it
  /// was lifted against the page only, 3.87:1 on an elevated card). Lighter than the web mock
  /// by a step on some covers.
  static let readOn: UInt32 = 0x2A261E
  /// Ink (#EDE4D0, `textPrimary`), for kicker mixes.
  static let ink: UInt32 = 0xEDE4D0

  static func rgbToHsl(_ r0: Double, _ g0: Double, _ b0: Double) -> (h: Double, s: Double, l: Double) {
    let r = r0 / 255
    let g = g0 / 255
    let b = b0 / 255
    let mx = max(r, g, b)
    let mn = min(r, g, b)
    let l = (mx + mn) / 2
    if mx == mn { return (0, 0, l) }
    let d = mx - mn
    let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
    var h: Double
    if mx == r {
      h = (g - b) / d + (g < b ? 6 : 0)
    } else if mx == g {
      h = (b - r) / d + 2
    } else {
      h = (r - g) / d + 4
    }
    return (h / 6, s, l)
  }

  static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> UInt32 {
    func channel(_ n: Double) -> UInt32 {
      let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
      let a = s * min(l, 1 - l)
      let c = l - a * max(-1, min(k - 3, 9 - k, 1))
      return UInt32(max(0, min(255, (c * 255).rounded())))
    }
    return (channel(0) << 16) | (channel(8) << 8) | channel(4)
  }

  static func components(_ rgb: UInt32) -> (r: Double, g: Double, b: Double) {
    (Double((rgb >> 16) & 0xFF), Double((rgb >> 8) & 0xFF), Double(rgb & 0xFF))
  }

  static func hsl(_ rgb: UInt32) -> (h: Double, s: Double, l: Double) {
    let c = components(rgb)
    return rgbToHsl(c.r, c.g, c.b)
  }

  /// The same hue, lifted to read as an accent on a near-black page.
  static func brighten(_ rgb: UInt32, _ l: Double) -> UInt32 {
    let (h, s, l0) = hsl(rgb)
    return hslToRGB(h, s < 0.1 ? s : max(s, 0.5), max(l0, l))
  }

  static func luminance(_ rgb: UInt32) -> Double {
    let c = components(rgb)
    func lin(_ v: Double) -> Double {
      let x = v / 255
      return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
  }

  static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let la = luminance(a)
    let lb = luminance(b)
    let x = max(la, lb)
    let y = min(la, lb)
    return (x + 0.05) / (y + 0.05)
  }

  /// The cover's colour, as light as it needs to be to read as text on the page.
  static func readable(_ base: UInt32) -> UInt32 {
    var l = 0.66
    while l <= 0.92 {
      let c = brighten(base, l)
      if contrast(c, readOn) >= 4.5 { return c }
      l += 0.02
    }
    return brighten(base, 0.92)
  }

  /// `coverColor()` over a 24x24 sRGB redraw of `image`. nil only when the bitmap cannot
  /// be made.
  static func coverColor(_ image: CGImage) -> UInt32? {
    let size = 24
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let data = context.data else { return nil }
    let pixels = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

    var bins = [(w: Double, r: Double, g: Double, b: Double)](repeating: (0, 0, 0, 0), count: 12)
    var all = (w: 0.0, r: 0.0, g: 0.0, b: 0.0)
    for i in 0 ..< size * size {
      var r = Double(pixels[i * 4])
      var g = Double(pixels[i * 4 + 1])
      var b = Double(pixels[i * 4 + 2])
      let alpha = Double(pixels[i * 4 + 3])
      // A canvas reads straight (un-premultiplied) RGBA; covers are opaque, so this only
      // matters at a transparent edge.
      if alpha > 0, alpha < 255 {
        r = min(255, (r * 255 / alpha).rounded())
        g = min(255, (g * 255 / alpha).rounded())
        b = min(255, (b * 255 / alpha).rounded())
      }
      all.w += 1
      all.r += r
      all.g += g
      all.b += b
      let (h, s, l) = rgbToHsl(r, g, b)
      if s < 0.2 || l < 0.1 || l > 0.9 { continue }
      let w = s * (1 - abs(l - 0.5))
      let bin = Int((h * 12).rounded(.down)) % 12
      bins[bin].w += w
      bins[bin].r += r * w
      bins[bin].g += g * w
      bins[bin].b += b * w
    }
    // The FIRST bin with the strictly greatest weight (the JS reduce keeps ties).
    var best = bins[0]
    for bin in bins.dropFirst() where bin.w > best.w {
      best = bin
    }
    let src = best.w > 8 ? best : all
    guard src.w > 0 else { return nil }
    let (h, s0, l0) = rgbToHsl(src.r / src.w, src.g / src.w, src.b / src.w)
    let s = s0 > 0.12 ? max(s0, 0.55) : s0 * 0.5
    let l = min(0.55, max(0.28, l0))
    return hslToRGB(h, s, l)
  }

  static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> UIColor {
    let c = components(rgb)
    return UIColor(red: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: alpha)
  }

  /// `color-mix(in srgb, a share, b)`.
  static func mix(_ a: UInt32, _ b: UInt32, share: CGFloat) -> UIColor {
    let x = components(a)
    let y = components(b)
    let k = Double(share)
    return UIColor(
      red: (x.r * k + y.r * (1 - k)) / 255,
      green: (x.g * k + y.g * (1 - k)) / 255,
      blue: (x.b * k + y.b * (1 - k)) / 255,
      alpha: 1
    )
  }
}
