//
//  CassetteIcons.swift
//  AmperfyKit — Cassette Player iOS fork
//
//  The icon registry (design-system audit 2026-10-20, Wave 3).
//
//  One entry per CONCEPT ("shuffle", "more", "playlist"), never per screen. Each entry
//  carries both forms the app needs:
//
//  - `glyph`: what chrome draws. The Lucide asset where Cassette has one (matching the web
//    and CarPlay), otherwise the SF Symbol.
//  - `symbol`: the SF Symbol, always. Used where only a symbol works: player transport
//    (sized through `SymbolConfiguration`, which a Lucide asset ignores), App Intents and
//    system menus.
//
//  The rule a screen follows: transport controls take `symbolImage`; everything else takes
//  `uiImage` / `image`. To draw at a size, use `uiImage(size:)`, which works for both kinds
//  (a `SymbolConfiguration` on a Lucide asset is silently ignored, audit ICO-2).
//
//  `UIImage.<name>` statics and `AmperfyImage.<name>` resolve to these entries, so the two
//  old registries can no longer disagree about a concept. New code names `CassetteIcon`.
//  `scripts/check-tokens.sh` counts raw `systemName:` strings outside this file.
//

import SwiftUI
import UIKit

// MARK: - CassetteIconSize

/// Icon point sizes, by where the icon sits. SF symbols use the value as their point size;
/// Lucide glyphs are drawn in a square of `pointSize * 1.2`, the box an SF symbol of that
/// point size occupies, so the two families line up side by side.
public enum CassetteIconSize: CGFloat, Sendable {
  /// Inline with 13pt text (chevrons beside a section title).
  case small = 13
  /// Row accessories and the mini player's secondary buttons.
  case row = 15
  /// Toolbar and header buttons.
  case control = 17
  /// The large play button on a detail header or the player.
  case prominent = 25
}

// MARK: - CassetteIcon

public enum CassetteIcon: CaseIterable, Sendable {
  // Navigation and library
  case home, library, album, artist, song, playlist, genre, radio, podcast, folder
  // Chrome actions
  case search, plus, plusCircle, minus, check, info, more, filter, sort, list, settings
  case refresh, trash, chevronDown, chevronRight, openExternal, signOut, sortByName
  case adjust, sparkles, download, cancelDownload, lyrics, waveform
  // Transport (always symbols)
  case play, pause, stop, next, previous, shuffle, repeatAll, repeatOne, repeatOff
  // Keep playing: the queue carries on when it runs out (Apple Music's Autoplay glyph)
  case keepPlaying
  // Devices: the Mac and this phone in Settings (SF symbols; no Lucide asset yet)
  case laptop, desktop, iphone, ipad

  /// The Lucide asset in the kit catalog, when Cassette draws this concept itself.
  public var lucideAsset: String? {
    switch self {
    case .home: return "cassette-lucide-house"
    case .library: return "cassette-lucide-library"
    case .album: return "cassette-lucide-albums"
    case .artist: return "cassette-lucide-artists"
    case .song: return "cassette-lucide-songs"
    case .playlist: return "cassette-lucide-playlists"
    case .genre: return "cassette-lucide-genres"
    case .radio: return "cassette-lucide-radio"
    case .search: return "cassette-lucide-search"
    case .plus: return "cassette-lucide-plus"
    case .plusCircle: return "cassette-lucide-circle-plus"
    case .minus: return "cassette-lucide-minus"
    case .check: return "cassette-lucide-check"
    case .info: return "cassette-lucide-info"
    case .more: return "cassette-lucide-ellipsis"
    case .filter: return "cassette-lucide-filter"
    case .sort: return "cassette-lucide-arrow-up-down"
    case .list: return "cassette-lucide-list"
    case .settings: return "cassette-lucide-settings"
    case .refresh: return "cassette-lucide-refresh-cw"
    case .trash: return "cassette-lucide-trash-2"
    case .shuffle: return "cassette-lucide-shuffle"
    default: return nil
    }
  }

  /// The SF Symbol for this concept.
  public var symbolName: String {
    switch self {
    case .home: return "house.fill"
    case .library: return "music.note.square.stack.fill"
    case .album: return "square.stack"
    case .artist: return "music.mic"
    case .song: return "music.note"
    case .playlist: return "music.note.list"
    case .genre: return "guitars.fill"
    case .radio: return "dot.radiowaves.left.and.right"
    case .podcast: return "mic"
    case .folder: return "folder.fill"
    case .search: return "magnifyingglass"
    case .plus: return "plus"
    case .plusCircle: return "plus.circle"
    case .minus: return "minus"
    case .check: return "checkmark"
    case .info: return "info.circle"
    case .more: return "ellipsis"
    case .filter: return "line.3.horizontal.decrease"
    case .sort: return "arrow.up.arrow.down"
    case .list: return "list.bullet"
    case .settings: return "gear"
    case .refresh: return "arrow.triangle.2.circlepath"
    case .trash: return "trash"
    case .chevronDown: return "chevron.down"
    case .chevronRight: return "chevron.right"
    case .openExternal: return "arrow.up.forward.square"
    case .signOut: return "rectangle.portrait.and.arrow.right"
    case .sortByName: return "textformat.abc.dottedunderline"
    // One "adjust" glyph app-wide: the equalizer, the player's sound button and Home's
    // tune button were three different symbols (audit ICO-3).
    case .adjust: return "slider.horizontal.3"
    case .sparkles: return "sparkles"
    case .download: return "arrow.down.circle"
    case .cancelDownload: return "xmark.icloud"
    case .lyrics: return "quote.bubble"
    case .waveform: return "waveform"
    case .play: return "play.fill"
    case .pause: return "pause.fill"
    case .stop: return "stop.fill"
    case .next: return "forward.fill"
    case .previous: return "backward.fill"
    case .shuffle: return "shuffle"
    case .repeatAll: return "repeat"
    case .repeatOne: return "repeat.1"
    case .repeatOff: return "repeat.badge.xmark"
    case .keepPlaying: return "infinity"
    case .laptop: return "laptopcomputer"
    case .desktop: return "desktopcomputer"
    case .iphone: return "iphone"
    case .ipad: return "ipad"
    }
  }

  /// What chrome draws: the Lucide glyph (a template image) where one exists, else the symbol.
  @MainActor
  public var uiImage: UIImage {
    if let lucideAsset, let image = UIImage(named: lucideAsset) {
      return image.withRenderingMode(.alwaysTemplate)
    }
    return symbolImage
  }

  /// The SF Symbol, for transport controls and anything sized by `SymbolConfiguration`.
  @MainActor
  public var symbolImage: UIImage {
    UIImage(systemName: symbolName) ?? UIImage()
  }

  /// `uiImage` drawn at `size` for either family, as a template image.
  @MainActor
  public func uiImage(size: CassetteIconSize, weight: UIImage.SymbolWeight = .regular) -> UIImage {
    guard lucideAsset != nil else { return symbolImage(size: size, weight: weight) }
    let side = size.rawValue * 1.2
    let source = uiImage
    return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
      source.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
    }.withRenderingMode(.alwaysTemplate)
  }

  /// The SF Symbol at `size`.
  @MainActor
  public func symbolImage(
    size: CassetteIconSize,
    weight: UIImage.SymbolWeight = .regular
  )
    -> UIImage {
    let config = UIImage.SymbolConfiguration(pointSize: size.rawValue, weight: weight)
    return UIImage(systemName: symbolName, withConfiguration: config) ?? UIImage()
  }

  /// SwiftUI: the same choice as `uiImage`.
  public var image: Image {
    if let lucideAsset {
      return Image(lucideAsset).renderingMode(.template)
    }
    return Image(systemName: symbolName)
  }
}
