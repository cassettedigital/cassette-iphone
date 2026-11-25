//
//  CassetteFont.swift
//  AmperfyKit — Cassette Player iOS fork
//
//  Typography tokens for Cassette. Display face is Barlow Condensed,
//  monospace face is DM Mono. Both are Google Fonts (OFL). The TTFs are
//  expected to live in Amperfy/Resources/Fonts/ and be listed under the
//  `UIAppFonts` key in Info.plist. If a custom font fails to load at
//  runtime (e.g. missing from the bundle), every API here falls back to
//  the system font so the app never crashes.
//
//  Weights wired up:
//    Barlow Condensed — Regular (400), SemiBold (600), Bold (700), ExtraBold (800)
//    DM Mono          — Regular (400), Medium (500)
//
//  Run `apps/cassette-player-ios/scripts/fetch-fonts.sh` from the wrapper
//  to download the TTFs from Google Fonts into Amperfy/Resources/Fonts/.
//

import SwiftUI
import UIKit

// MARK: - CassetteDisplayWeight

public enum CassetteDisplayWeight {
  case regular
  case semibold
  case bold
  case extraBold

  /// The weight as a number, as the kit's type roles name it.
  public var kitWeight: Int {
    switch self {
    case .regular: 400
    case .semibold: 600
    case .bold: 700
    case .extraBold: 800
    }
  }

  fileprivate var postScriptName: String {
    switch self {
    case .regular: return "BarlowCondensed-Regular"
    case .semibold: return "BarlowCondensed-SemiBold"
    case .bold: return "BarlowCondensed-Bold"
    case .extraBold: return "BarlowCondensed-ExtraBold"
    }
  }

  fileprivate var systemWeight: UIFont.Weight {
    switch self {
    case .regular: return .regular
    case .semibold: return .semibold
    case .bold: return .bold
    case .extraBold: return .heavy
    }
  }

  fileprivate var swiftUIWeight: Font.Weight {
    switch self {
    case .regular: return .regular
    case .semibold: return .semibold
    case .bold: return .bold
    case .extraBold: return .heavy
    }
  }
}

// MARK: - CassetteMonoWeight

public enum CassetteMonoWeight {
  case regular
  case medium

  /// The weight as a number, as the kit's type roles name it.
  public var kitWeight: Int {
    switch self {
    case .regular: 400
    case .medium: 500
    }
  }

  fileprivate var postScriptName: String {
    switch self {
    case .regular: return "DMMono-Regular"
    case .medium: return "DMMono-Medium"
    }
  }

  fileprivate var systemWeight: UIFont.Weight {
    switch self {
    case .regular: return .regular
    case .medium: return .medium
    }
  }

  fileprivate var swiftUIWeight: Font.Weight {
    switch self {
    case .regular: return .regular
    case .medium: return .medium
    }
  }
}

// MARK: - UIFont

extension UIFont {
  public static func cassetteDisplay(
    size: CGFloat,
    weight: CassetteDisplayWeight = .semibold
  )
    -> UIFont {
    if let font = UIFont(name: weight.postScriptName, size: size) {
      return font
    }
    return UIFont.systemFont(ofSize: size, weight: weight.systemWeight)
  }

  public static func cassetteMono(
    size: CGFloat,
    weight: CassetteMonoWeight = .regular
  )
    -> UIFont {
    if let font = UIFont(name: weight.postScriptName, size: size) {
      return font
    }
    return UIFont.monospacedSystemFont(ofSize: size, weight: weight.systemWeight)
  }

  /// The answer voice: Apple's New York (the system serif) in italic, medium by default.
  /// Nothing is bundled. Headings and artist lines only, never a list row, never under 20pt.
  ///
  /// The italic is added by merging into the serif descriptor's own traits, so both the
  /// weight and the serif design survive (`withSymbolicTraits` drops the weight).
  public static func cassetteAnswer(
    size: CGFloat,
    weight: UIFont.Weight = .medium
  )
    -> UIFont {
    #if DEBUG
      _ = CassetteAnswerFaceLog.once
    #endif
    return makeCassetteAnswer(size: size, weight: weight)
  }

  fileprivate static func makeCassetteAnswer(size: CGFloat, weight: UIFont.Weight) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    guard let serif = base.fontDescriptor.withDesign(.serif) else {
      return UIFont.italicSystemFont(ofSize: size)
    }
    var traits = (serif.fontAttributes[.traits] as? [UIFontDescriptor.TraitKey: Any]) ?? [:]
    traits[.weight] = weight.rawValue
    let symbolic = (traits[.symbolic] as? NSNumber)?.uint32Value ?? 0
    traits[.symbolic] = symbolic | UIFontDescriptor.SymbolicTraits.traitItalic.rawValue
    let italic = serif.addingAttributes([.traits: traits])
    return UIFont(descriptor: italic, size: size)
  }
}

#if DEBUG
  /// Logs the resolved answer face once per launch (expect a New York medium italic).
  /// A lazily initialised `static let` runs exactly once, so no mutable static is needed.
  private enum CassetteAnswerFaceLog {
    static let once: Void = {
      let font = UIFont.makeCassetteAnswer(size: 25, weight: .medium)
      print("Cassette answer face: \(font.fontName)")
    }()
  }
#endif

// MARK: - SwiftUI Font

extension Font {
  public static func cassetteDisplay(
    size: CGFloat,
    weight: CassetteDisplayWeight = .semibold
  )
    -> Font {
    // SwiftUI's `Font(name:size:)` silently falls back to the system font
    // if the PostScript name can't be resolved, so we always ask for the
    // custom one and layer `.weight()` on top for the system fallback path.
    Font.custom(weight.postScriptName, size: size)
      .weight(weight.swiftUIWeight)
  }

  public static func cassetteMono(
    size: CGFloat,
    weight: CassetteMonoWeight = .regular
  )
    -> Font {
    Font.custom(weight.postScriptName, size: size)
      .weight(weight.swiftUIWeight)
  }

  /// The answer voice in SwiftUI: the system serif (New York), italic. See
  /// `UIFont.cassetteAnswer`.
  public static func cassetteAnswer(size: CGFloat, weight: Font.Weight = .medium) -> Font {
    .system(size: size, weight: weight, design: .serif).italic()
  }
}

// MARK: - CassetteTextStyle

/// Canonical typography scale for the Cassette iOS fork. Roles map onto
/// Display (Barlow Condensed) / Mono (DM Mono), the answer face (New York italic), plus
/// system `.body` where SF Pro Text reads better than a condensed face.
///
/// Album/track titles stay on Barlow. The quieter line under a card (artist
/// name, resume artist) uses `.cardSubtitle`: DM Mono at the 13pt floor, which
/// stays more legible at that size than condensed Barlow.
///
/// Caption and `.metadata` share a size and are differentiated by weight
/// only (medium vs regular mono). The mono floor is 13pt (Patch 104), never 12:
/// a Cassette product decision; iOS HIG would allow 11pt here but we don't.
///
/// cassette Patch 104 (Root 4): the scale read small on track numbers,
/// library rows and the Home greeting, so the roles were lifted app-wide
/// (roles, not per-screen sizes): heroTitle 28 -> 30, rowTitle 16 -> 18,
/// miniTitle 14 -> 15, metadata/caption 12 -> 13. sectionTitle stays 22.
/// `.greeting` is new: the Home greeting used to fall back to tiny 12pt
/// mono (the prototype's Newsreader face isn't bundled) - it now gets a
/// real Barlow treatment at a legible size.
///
/// Phone-taste (2026-10-21) adds the two-voice roles from the approved phone mocks: the
/// SHOUT (Barlow ExtraBold, uppercased, tracked) and the ANSWER (New York italic, the
/// in-app answer voice; Playfair is marketing only and never used here). The answer face
/// is for headings and artist lines only: never a list row, never under 20pt. The mock's
/// 11px kicker and meta sit at the 13pt mono floor here. Every role is a fixed size (no
/// Dynamic Type), like the rest of the scale, so a shout and its answer always pair.
/// UIKit has no text-transform: read `kern` and `isUppercased`, or use
/// `NSAttributedString.cassette(_:_:color:)` / `View.cassetteText(_:)`, which apply both.
public enum CassetteTextStyle: CaseIterable, Sendable {
  case heroTitle // Barlow Condensed Bold, 30pt
  case sectionTitle // Barlow Condensed Bold, 22pt
  case greeting // Barlow Condensed SemiBold, 20pt (Home greeting line)
  case rowTitle // Barlow Condensed Semibold, 18pt
  case miniTitle // Barlow Condensed Semibold, 15pt
  case sectionLabel // Barlow Condensed Bold, 13pt (callers uppercase as needed)
  case cardSubtitle // DM Mono Regular, 13pt (artist under an album/resume card)
  case metadata // DM Mono Medium, 13pt
  case caption // DM Mono Regular, 13pt
  case body // SF Pro Text Regular, 15pt (system font, not Cassette Display)
  // Bar chrome, set once by `CassetteTheme.applyGlobalAppearance()` (Wave 2: these were
  // literal sizes there).
  case navTitle // Barlow Condensed SemiBold, 18pt (inline nav bar title)
  case largeTitle // Barlow Condensed Bold, 34pt (large nav bar title)
  /// Barlow Condensed SemiBold, 10pt. Under the 13pt floor above: the tab bar's own
  /// label size, kept as shipped; raising it is a design call (audit TOK-7).
  case tabLabel
  case tabLabelSelected // Barlow Condensed Bold, 10pt

  // MARK: Two-voice roles (phone-taste)

  /// Barlow Condensed ExtraBold 26, tracked +0.13, uppercased: the first voice of a row
  /// heading ("ON REPEAT").
  case shout
  /// Barlow Condensed ExtraBold 36, -0.18, uppercased: album and playlist titles, the
  /// device page title.
  case pageTitle
  /// Barlow Condensed ExtraBold 46, -0.23, uppercased: the artist name, the Mac name.
  case heroName
  /// Barlow Condensed ExtraBold 34, uppercased: the Now Playing title.
  case playerTitle
  /// Barlow Condensed ExtraBold 22, uppercased: the Resume card title.
  case cardTitle
  /// Barlow Condensed Bold 20: the Lately and mood door labels.
  case tileLabel
  /// Barlow Condensed Bold 16, +1.3, uppercased: PLAY / SHUFFLE pill labels.
  case pill
  /// New York italic medium 25, -0.25: the answer of a heading, the album artist line.
  case answer
  /// New York italic medium 23, -0.23: the Now Playing artist line.
  case answerPlayer
  /// New York italic medium 20, -0.20: the queue now-row. The serif's floor.
  case answerCompact
  /// DM Mono Medium 13, +2.0, uppercased: a kicker over a title ("ALBUM", "NOW PLAYING").
  case kicker
  /// DM Mono Medium 13, +1.7, uppercased: a meta line ("2016 · 11 SONGS").
  case meta

  /// The single definition of the scale. `UIFont.cassette` and `Font.cassette` both read it,
  /// so the two can no longer drift (they were two copy-pasted switches).
  /// The role's numbers in the shared kit (tokens.json `type.roles`, generated into
  /// CassetteKitTokens.swift): its size, tracking and capitals come from there, never from here
  /// (design wave 6). The selected tab label shares the tab label's numbers.
  public var kitRole: CassetteKitTokens.TypeRole {
    typealias R = CassetteKitTokens.Roles
    switch self {
    case .heroTitle: return R.heroTitle
    case .sectionTitle: return R.sectionTitle
    case .greeting: return R.greeting
    case .rowTitle: return R.rowTitle
    case .miniTitle: return R.miniTitle
    case .sectionLabel: return R.sectionLabel
    case .cardSubtitle: return R.cardSubtitle
    case .metadata: return R.metadata
    case .caption: return R.caption
    case .body: return R.body
    case .navTitle: return R.navTitle
    case .largeTitle: return R.largeTitle
    case .tabLabel: return R.tabLabel
    case .tabLabelSelected: return R.tabLabel
    case .shout: return R.shout
    case .pageTitle: return R.pageTitle
    case .heroName: return R.heroName
    case .playerTitle: return R.playerTitle
    case .cardTitle: return R.cardTitle
    case .tileLabel: return R.tileLabel
    case .pill: return R.pill
    case .answer: return R.answer
    case .answerPlayer: return R.answerPlayer
    case .answerCompact: return R.answerCompact
    case .kicker: return R.kicker
    case .meta: return R.meta
    }
  }

  /// The face each role is set in, by hand: the app's font files. CassetteKitTokensTest holds
  /// every one to the kit's face and weight.
  fileprivate var spec: (face: CassetteFace, size: CGFloat) {
    let face: CassetteFace = switch self {
    case .heroTitle: .display(.bold)
    case .sectionTitle: .display(.bold)
    case .greeting: .display(.semibold)
    case .rowTitle: .display(.semibold)
    case .miniTitle: .display(.semibold)
    case .sectionLabel: .display(.bold)
    case .cardSubtitle: .mono(.regular)
    case .metadata: .mono(.medium)
    case .caption: .mono(.regular)
    case .body: .system
    case .navTitle: .display(.semibold)
    case .largeTitle: .display(.bold)
    case .tabLabel: .display(.semibold)
    case .tabLabelSelected: .display(.bold)
    case .shout: .display(.extraBold)
    case .pageTitle: .display(.extraBold)
    case .heroName: .display(.extraBold)
    case .playerTitle: .display(.extraBold)
    case .cardTitle: .display(.extraBold)
    case .tileLabel: .display(.bold)
    case .pill: .display(.bold)
    case .answer: .answer
    case .answerPlayer: .answer
    case .answerCompact: .answer
    case .kicker: .mono(.medium)
    case .meta: .mono(.medium)
    }
    return (face, kitRole.size)
  }

  /// Letter-spacing in points (the mock's em tracking at this size). 0 for every role that
  /// predates phone-taste.
  public var kern: CGFloat {
    kitRole.kern
  }

  /// Whether the role is set in capitals (the mock's text-transform: uppercase). False for
  /// every role that predates phone-taste.
  public var isUppercased: Bool {
    kitRole.upper
  }

  /// The face's family and weight as the kit names them, for the equality test.
  public var kitFace: (face: String, weight: Int) {
    switch spec.face {
    case let .display(w): return ("Barlow Condensed", w.kitWeight)
    case let .mono(w): return ("DM Mono", w.kitWeight)
    case .system: return ("SF Pro", 400)
    case .answer: return ("New York", 500)
    }
  }
}

// MARK: - CassetteFace

fileprivate enum CassetteFace {
  case display(CassetteDisplayWeight)
  case mono(CassetteMonoWeight)
  /// SF Pro Text Regular.
  case system
  /// New York italic, medium (`cassetteAnswer`).
  case answer
}

extension UIFont {
  public static func cassette(_ style: CassetteTextStyle) -> UIFont {
    let spec = style.spec
    switch spec.face {
    case let .display(weight): return .cassetteDisplay(size: spec.size, weight: weight)
    case let .mono(weight): return .cassetteMono(size: spec.size, weight: weight)
    case .system: return .systemFont(ofSize: spec.size, weight: .regular)
    case .answer: return .cassetteAnswer(size: spec.size)
    }
  }
}

extension Font {
  public static func cassette(_ style: CassetteTextStyle) -> Font {
    let spec = style.spec
    switch spec.face {
    case let .display(weight): return .cassetteDisplay(size: spec.size, weight: weight)
    case let .mono(weight): return .cassetteMono(size: spec.size, weight: weight)
    case .system: return .system(size: spec.size, weight: .regular)
    case .answer: return .cassetteAnswer(size: spec.size)
    }
  }
}

// MARK: - Styled text helpers

extension NSAttributedString {
  /// `text` in a role: its font, `color`, and the role's tracking. Capitals when
  /// `uppercase ?? style.isUppercased`. A paragraph style is added only when it changes
  /// something (an alignment other than `.natural`, or a line-height multiple).
  public static func cassette(
    _ text: String,
    _ style: CassetteTextStyle,
    color: UIColor,
    uppercase: Bool? = nil,
    alignment: NSTextAlignment = .natural,
    lineHeightMultiple: CGFloat? = nil
  )
    -> NSAttributedString {
    let shown = (uppercase ?? style.isUppercased) ? text.uppercased() : text
    var attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.cassette(style),
      .foregroundColor: color,
    ]
    // A zero kern attribute switches the font's own pair kerning off, so it is only
    // set when the role actually tracks.
    if style.kern != 0 {
      attributes[.kern] = style.kern
    }
    if alignment != .natural || lineHeightMultiple != nil {
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = alignment
      if let lineHeightMultiple {
        paragraph.lineHeightMultiple = lineHeightMultiple
      }
      attributes[.paragraphStyle] = paragraph
    }
    return NSAttributedString(string: shown, attributes: attributes)
  }
}

extension View {
  /// A role in SwiftUI: its font, tracking and capitals.
  public func cassetteText(_ style: CassetteTextStyle) -> some View {
    font(.cassette(style))
      .tracking(style.kern)
      .textCase(style.isUppercased ? .uppercase : nil)
  }
}

// MARK: - CassetteHeading

/// The two-voice row heading from the phone mocks: a SHOUT in Barlow capitals, then its
/// answer in the New York italic, on one line that truncates at the tail
/// ("ON REPEAT  lately"). One builder for UIKit and one for SwiftUI so the two never drift.
///
/// The answer colour is the caller's: `.accentAnswer` (brand orange) for Home rows only,
/// `.textSecondary` on unlit pages, and `CoverTint.text` on pages lit by a record.
public enum CassetteHeading {
  /// Air above a heading block (the mock's `.block` padding-top).
  public static let topSpacing: CGFloat = CassetteKitTokens.Component.Heading.top
  /// Air between the heading and its row (the mock's `.head` margin-bottom).
  public static let bottomSpacing: CGFloat = CassetteKitTokens.Component.Heading.bottom
  /// The heading's side inset (the mock's 20px page gutter).
  public static let sideInset: CGFloat = CassetteKitTokens.Component.Heading.side
  /// A table header or section header holding one heading: 28 + one 26pt line + 12.
  public static let tableHeaderHeight: CGFloat = 66

  /// One run per voice joined by a single space, on the shared baseline. The shout is
  /// uppercased in `shoutColor` (ink) with its role's tracking; the answer keeps its case.
  public static func attributed(
    shout: String,
    answer: String?,
    answerColor: UIColor,
    shoutStyle: CassetteTextStyle = .shout,
    answerStyle: CassetteTextStyle = .answer,
    shoutColor: UIColor = .cassette(.textPrimary)
  )
    -> NSAttributedString {
    let result = NSMutableAttributedString(
      attributedString: .cassette(shout, shoutStyle, color: shoutColor, uppercase: true)
    )
    if let answer, !answer.isEmpty {
      result.append(NSAttributedString(
        string: " ",
        attributes: [.font: UIFont.cassette(shoutStyle), .foregroundColor: shoutColor]
      ))
      result.append(.cassette(answer, answerStyle, color: answerColor, uppercase: false))
    }
    return result
  }

  /// The SwiftUI twin of `attributed`, for `Text(_:)` (one Text, not Text + Text).
  public static func attributedSwiftUI(
    shout: String,
    answer: String?,
    answerColor: Color,
    shoutStyle: CassetteTextStyle = .shout,
    answerStyle: CassetteTextStyle = .answer
  )
    -> AttributedString {
    var result = AttributedString(shout.uppercased())
    result.font = Font.cassette(shoutStyle)
    result.foregroundColor = Color.cassette(.textPrimary)
    if shoutStyle.kern != 0 {
      result[AttributeScopes.SwiftUIAttributes.TrackingAttribute.self] = shoutStyle.kern
    }
    if let answer, !answer.isEmpty {
      var space = AttributedString(" ")
      space.font = Font.cassette(shoutStyle)
      var second = AttributedString(answer)
      second.font = Font.cassette(answerStyle)
      second.foregroundColor = answerColor
      if answerStyle.kern != 0 {
        second[AttributeScopes.SwiftUIAttributes.TrackingAttribute.self] = answerStyle.kern
      }
      result += space
      result += second
    }
    return result
  }

  /// What VoiceOver reads: "On Repeat, lately".
  public static func accessibilityLabel(shout: String, answer: String?) -> String {
    guard let answer, !answer.isEmpty else { return shout }
    return "\(shout), \(answer)"
  }

  /// A one-line heading label (Auto Layout ready): tail truncation, fixed type, a header
  /// for VoiceOver. Set its `attributedText` from `attributed(...)`.
  @MainActor
  public static func makeLabel() -> UILabel {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    label.adjustsFontForContentSizeCategory = false
    label.accessibilityTraits = .header
    return label
  }

  /// A clear view `tableHeaderHeight` tall holding one heading, for a table header or a
  /// section header. Hosts on grouped tables also set `tableView.sectionHeaderTopPadding = 0`.
  @MainActor
  public static func makeTableHeaderView(
    shout: String,
    answer: String?,
    answerColor: UIColor,
    sideInset: CGFloat = CassetteHeading.sideInset
  )
    -> UIView {
    let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: tableHeaderHeight))
    view.backgroundColor = .clear
    let label = makeLabel()
    label.attributedText = attributed(shout: shout, answer: answer, answerColor: answerColor)
    label.accessibilityLabel = accessibilityLabel(shout: shout, answer: answer)
    view.addSubview(label)
    // The two faces' natural line is a few points taller than the mock's 26pt line box, so
    // the bottom pin gives way before the label is squeezed (no clipped accents).
    let bottom = label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -bottomSpacing)
    bottom.priority = UILayoutPriority(740)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: sideInset),
      label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -sideInset),
      label.topAnchor.constraint(equalTo: view.topAnchor, constant: topSpacing),
      bottom,
    ])
    return view
  }
}

// MARK: - CassetteHeadingText

/// The two-voice heading in SwiftUI. One line, tail truncation, a header for VoiceOver.
public struct CassetteHeadingText: View {
  private let shout: String
  private let answer: String?
  private let answerColor: Color

  public init(
    shout: String,
    answer: String? = nil,
    answerColor: Color = Color.cassette(.accentAnswer)
  ) {
    self.shout = shout
    self.answer = answer
    self.answerColor = answerColor
  }

  public var body: some View {
    Text(CassetteHeading.attributedSwiftUI(
      shout: shout,
      answer: answer,
      answerColor: answerColor
    ))
    .lineLimit(1)
    .truncationMode(.tail)
    .accessibilityLabel(CassetteHeading.accessibilityLabel(shout: shout, answer: answer))
    .accessibilityAddTraits(.isHeader)
  }
}

// MARK: - CassettePlayDisc

/// The one-tap play disc on a cover, in SwiftUI (the twin of
/// `AlbumCollectionCell.makePlayOverlayButton()`): a 34pt cream disc with a filled play
/// glyph, nudged 1pt right for optical centring, a soft drop shadow, and a 44pt circular
/// hit area.
///
/// Hosts layer it with `.overlay(alignment: .bottomTrailing) { CassettePlayDisc { ... }
/// .padding(8) }` or as a ZStack sibling with an 8pt inset, NEVER inside another Button:
/// in SwiftUI the outer button's tap wins.
public struct CassettePlayDisc: View {
  private let diameter: CGFloat
  private let glyphSize: CGFloat
  private let action: () -> ()

  public init(diameter: CGFloat = 34, glyphSize: CGFloat = 15, action: @escaping () -> ()) {
    self.diameter = diameter
    self.glyphSize = glyphSize
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .fill(Color.cassette(.fillSelected))
        CassetteIcon.play.image
          .font(.system(size: glyphSize, weight: .bold))
          .symbolVariant(.fill)
          .foregroundStyle(Color.cassette(.textOnFill))
          .offset(x: 1)
      }
      .frame(width: diameter, height: diameter)
      .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 4)
      // The disc draws at `diameter`; the touch target is a 44pt circle around it.
      .contentShape(Circle().inset(by: min(0, (diameter - 44) / 2)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Play")
  }
}
