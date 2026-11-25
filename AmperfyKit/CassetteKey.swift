//
//  CassetteKey.swift
//  AmperfyKit
//
//  The website's key and button row (the kit's Button and ActionRow, design wave 4) at the
//  phone's density: the founder, 2026-11-22, "the web button rows look way better than iOS"
//  (C-rows-model). One key part and one row part for every key row on the iPhone; every number
//  is the shared kit's (tokens.json `control`, generated into CassetteKitTokens.swift), never
//  typed here (design wave 6).
//
//  A key: 48 tall, round ends, 20 of side room, its glyph (20, a quarter bigger than its words)
//  12 before its words in the display face's capitals at 700, 16pt tracked 0.08125em. A row:
//  keys at their own width, 12 apart, on one line; short of room, the keys give up their words
//  for their glyph in the order the caller names, and a key that holds never does.
//

import UIKit

// MARK: - CassetteKeyLook

/// How a key is drawn, the kit Button's `look`.
public enum CassetteKeyLook: Sendable {
  /// The one primary dark: an ink fill with the paper's colour for its words.
  case fill
  /// An ink outline at the kit's strength, clear inside.
  case line
  /// Its words alone.
  case word
}

// MARK: - CassetteKeyButton

/// One key. Make it with `CassetteKey.make`; change what it says with `setWords(_:icon:)`.
@MainActor
public final class CassetteKeyButton: UIButton {
  public private(set) var look: CassetteKeyLook = .fill
  public private(set) var words: String?
  public private(set) var icon: CassetteIcon?
  /// Whether its row has asked it to show its glyph alone (it gives way first).
  public private(set) var isGlyphOnly = false
  /// The key's height: the action step, or the record head's step.
  public private(set) var keyHeight: CGFloat = CassetteKitTokens.Control.action
  /// The words' colour, when a lit page asks for its record's ink.
  public var ink: UIColor? {
    didSet { apply() }
  }

  private var heightConstraint: NSLayoutConstraint?
  private var squareConstraint: NSLayoutConstraint?

  fileprivate func configure(look: CassetteKeyLook, height: CGFloat) {
    self.look = look
    keyHeight = height
    translatesAutoresizingMaskIntoConstraints = false
    let h = heightAnchor.constraint(equalToConstant: height)
    h.isActive = true
    heightConstraint = h
    let square = widthAnchor.constraint(equalToConstant: height)
    square.isActive = false
    squareConstraint = square
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  /// What the key says and shows. A nil glyph is a key of words alone.
  public func setWords(_ words: String?, icon: CassetteIcon?) {
    self.words = words
    self.icon = icon
    accessibilityLabel = words
    apply()
    superview?.superview?.setNeedsLayout()
  }

  /// The row's ask: the glyph alone, a circle at the key's height (only a key with a glyph).
  fileprivate func setGlyphOnly(_ glyphOnly: Bool) {
    let wanted = glyphOnly && icon != nil
    guard wanted != isGlyphOnly else { return }
    isGlyphOnly = wanted
    apply()
  }

  private func apply() {
    typealias C = CassetteKitTokens.Control
    var config: UIButton.Configuration
    let fg: UIColor
    switch look {
    case .fill:
      config = .filled()
      config.baseBackgroundColor = .cassette(.fillSelected)
      fg = ink ?? .cassette(.textOnFill)
    case .line:
      config = .plain()
      config.background.backgroundColor = .clear
      config.background.strokeColor = (ink ?? .cassette(.textPrimary))
        .withAlphaComponent(CassetteKitTokens.Component.Pill.strokeAlpha)
      config.background.strokeWidth = CassetteKitTokens.Component.Pill.stroke
      fg = ink ?? .cassette(.textPrimary)
    case .word:
      config = .plain()
      config.background.backgroundColor = .clear
      fg = ink ?? .cassette(.textPrimary)
    }
    config.baseForegroundColor = fg
    config.cornerStyle = .capsule
    config.imagePlacement = .leading
    config.imagePadding = C.keyGap
    if let icon {
      // The glyph in a box a quarter bigger than the words (the kit's 1.25em), or 44% of a
      // circle's side when it stands alone.
      let box = isGlyphOnly ? (keyHeight * 0.44).rounded() : (C.keyLetters * 1.25).rounded()
      config.image = CassetteKey.glyph(icon, box: box)
    } else {
      config.image = nil
    }
    if isGlyphOnly {
      config.attributedTitle = nil
      config.contentInsets = .zero
    } else {
      if let words {
        config.attributedTitle = AttributedString(NSAttributedString.cassette(
          words,
          .pill,
          color: fg
        ))
      } else {
        config.attributedTitle = nil
      }
      config.contentInsets = NSDirectionalEdgeInsets(
        top: 0,
        leading: C.keyPad,
        bottom: 0,
        trailing: C.keyPad
      )
    }
    configuration = config
    squareConstraint?.isActive = isGlyphOnly
  }
}

// MARK: - CassetteKey

@MainActor
public enum CassetteKey {
  /// A new key. `height` is the action step unless the row is a record head's (`Control.head`).
  public static func make(
    _ look: CassetteKeyLook,
    words: String?,
    icon: CassetteIcon?,
    height: CGFloat = CassetteKitTokens.Control.action
  )
    -> CassetteKeyButton {
    let key = CassetteKeyButton(frame: .zero)
    key.configure(look: look, height: height)
    key.setWords(words, icon: icon)
    return key
  }

  /// A glyph drawn in a square box of `box` points, as a template image: the kit's own drawing
  /// when Cassette draws the concept, else its SF Symbol (the transport).
  public static func glyph(_ icon: CassetteIcon, box: CGFloat) -> UIImage {
    if icon.lucideAsset != nil {
      let source = icon.uiImage
      return UIGraphicsImageRenderer(size: CGSize(width: box, height: box)).image { _ in
        source.draw(in: CGRect(x: 0, y: 0, width: box, height: box))
      }.withRenderingMode(.alwaysTemplate)
    }
    let config = UIImage.SymbolConfiguration(pointSize: (box * 0.8).rounded(), weight: .semibold)
    return icon.symbolImage.applyingSymbolConfiguration(config) ?? icon.symbolImage
  }
}

// MARK: - CassetteKeyRow

/// Two or more keys side by side on one line, the kit's ActionRow: each at its own width,
/// 12 apart. Short of room, the keys named in `givesWay` (first gives first) trade their words
/// for their glyph until the row fits; any other key holds its words.
@MainActor
public final class CassetteKeyRow: UIView {
  public enum Alignment: Sendable {
    case leading
    case center
  }

  public var alignment: Alignment = .leading {
    didSet { applyAlignment() }
  }

  public private(set) var keys = [CassetteKeyButton]()
  private var givesWay = [CassetteKeyButton]()
  private let stack = UIStackView()
  private var leadingConstraint: NSLayoutConstraint!
  private var centerConstraint: NSLayoutConstraint!

  public init(alignment: Alignment = .leading) {
    self.alignment = alignment
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .center
    stack.distribution = .fill
    stack.spacing = CassetteKitTokens.Space.md
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    self.leadingConstraint = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
    self.centerConstraint = stack.centerXAnchor.constraint(equalTo: centerXAnchor)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])
    applyAlignment()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// The row's keys, left to right, and which of them give way when short (first gives first).
  public func setKeys(_ keys: [CassetteKeyButton], givesWay: [CassetteKeyButton] = []) {
    for key in self.keys { key.removeFromSuperview() }
    self.keys = keys
    self.givesWay = givesWay
    for key in keys { stack.addArrangedSubview(key) }
    setNeedsLayout()
  }

  private func applyAlignment() {
    leadingConstraint.isActive = alignment == .leading
    centerConstraint.isActive = alignment == .center
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    let room = bounds.width
    guard room > 0 else { return }
    for key in keys { key.setGlyphOnly(false) }
    var step = 0
    while naturalWidth() > room, step < givesWay.count {
      givesWay[step].setGlyphOnly(true)
      step += 1
    }
    super.layoutSubviews()
  }

  private func naturalWidth() -> CGFloat {
    let visible = keys.filter { !$0.isHidden }
    let widths = visible.map { $0.isGlyphOnly ? $0.keyHeight : $0.intrinsicContentSize.width }
    return widths.reduce(0, +) + CGFloat(max(0, visible.count - 1)) * stack.spacing
  }
}
