//
//  AmbientCoverBackdrop.swift
//  Amperfy
//
//  cassette Patch 112 — Now Playing ambient backlight. Behind the crisp
//  now-playing cover we render a soft, oversized, blurred copy of that same
//  cover so the record's own colours fill the screen like a lamp in a dim
//  room. View-layer only: no colour sampling, no dominant_color, no data
//  model. We blur the image we already have.
//
//  Performance: never blur a full-res image and never blur per frame. The
//  cover is downsampled to ~32px once (off-main, cached in `NSCache`); a 32px
//  texture blurred + scaled up is visually identical to a 1000px one, which is
//  what makes this effectively free on the GPU.
//
//  Hosted (via UIHostingController) behind the UIKit PopupPlayerVC content.
//

import AmperfyKit
import CoreImage
import ImageIO
import SwiftUI
import UIKit

// Patch 114: shared CIContext for the off-main pre-blur (Sendable + thread-safe).
private let ambientBlurContext = CIContext(options: nil)

// MARK: - AmbientSourceDecoder

/// cassette: decode the ambient/cover source straight from disk as a
/// downsampled thumbnail via ImageIO, OFF the main thread. Previously the
/// popup fed the ambient model with `getImageToDisplayImmediately`, a
/// synchronous full-res `UIImage(contentsOfFile:)` on the main thread — an
/// oversized cover (e.g. a multi-thousand-pixel render) decoded there blocks
/// popup-open and can starve the audio render thread on first open.
/// `CGImageSourceCreateThumbnailAtIndex` caps the work to `maxPixelSize`
/// regardless of the source's real dimensions, so the cost is bounded.
enum AmbientSourceDecoder {
  static func thumbnail(contentsOfFile path: String, maxPixelSize: Int) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(
      URL(fileURLWithPath: path) as CFURL, nil
    ) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
      source, 0, options as CFDictionary
    ) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}

// MARK: - AmbientBackdropCache

enum AmbientBackdropCache {
  // NSCache is internally thread-safe; the unchecked annotation just satisfies
  // strict concurrency for the shared static.
  private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()

  /// Returns a ~32px downsampled **and pre-blurred** copy, cached by key.
  /// Patch 114: the blur now happens HERE, off the main thread, so the SwiftUI
  /// view renders a plain Image. Previously the view applied `.blur(radius:70)`,
  /// whose first-render Gaussian shader compiled on the main thread the first
  /// time the player opened — a one-time spike that starved the audio render
  /// thread (the "first-open glitch"). Doing the decode + downsample + blur on
  /// a detached task and caching the result makes opening the player cheap.
  /// The tiny already made for `key`, if any (no decode, no blur).
  static func cachedTiny(for key: String) -> UIImage? {
    cache.object(forKey: key as NSString)
  }

  static func tiny(for key: String, image: UIImage) async -> UIImage {
    if let hit = cache.object(forKey: key as NSString) { return hit }
    let small = await Task.detached(priority: .utility) {
      image.ambientDownsampledBlurred(maxDimension: 32, blurRadius: 8)
    }.value
    cache.setObject(small, forKey: key as NSString)
    return small
  }
}

extension UIImage {
  fileprivate func ambientDownsampled(maxDimension: CGFloat) -> UIImage {
    let longest = max(size.width, size.height)
    guard longest > maxDimension else { return self }
    let scale = maxDimension / longest
    let target = CGSize(width: size.width * scale, height: size.height * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    return UIGraphicsImageRenderer(size: target, format: format).image { _ in
      draw(in: CGRect(origin: .zero, size: target))
    }
  }

  /// Patch 114: downsample to ~`maxDimension`px, then Gaussian-blur the tiny
  /// image off-main (CIGaussianBlur on a 32px source is trivial). The soft
  /// blur + the later bilinear upscale-to-fill reproduce the old `.blur(70)`
  /// lamp look without an on-main render-time blur.
  fileprivate func ambientDownsampledBlurred(maxDimension: CGFloat, blurRadius: Double) -> UIImage {
    let small = ambientDownsampled(maxDimension: maxDimension)
    guard let input = CIImage(image: small) else { return small }
    let cropExtent = input.extent
    guard let filter = CIFilter(name: "CIGaussianBlur") else { return small }
    // Clamp so the blur doesn't pull in transparent edges (dark halo).
    filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
    filter.setValue(blurRadius, forKey: kCIInputRadiusKey)
    guard let output = filter.outputImage,
          let cg = ambientBlurContext.createCGImage(output, from: cropExtent)
    else { return small }
    return UIImage(cgImage: cg)
  }
}

// MARK: - AmbientBackdropModel

/// Bridges the UIKit player to the SwiftUI backdrop. The player pushes the
/// current cover (or placeholder) image, a stable id, and the play state.
@MainActor
final class AmbientBackdropModel: ObservableObject {
  /// Stable id for the current artwork (artwork image path, or a placeholder
  /// key). Drives the cross-fade and the downsample cache key.
  @Published
  var coverID: String = "ambient-placeholder"
  /// The resolved cover image, OR the on-brand placeholder image. One path.
  @Published
  var image: UIImage?
  @Published
  var isPlaying: Bool = false
  /// The room the cover lights: the record's own colour (CoverTint.room), set with the tint.
  @Published
  var room: Color = Color(uiColor: CoverTint.neutral.room)
  /// Up Next is showing, its rows from the top of the sheet down: the glass is thick
  /// everywhere, not only under the controls.
  @Published
  var isListShown: Bool = false
}

// MARK: - AmbientCoverBackdrop

struct AmbientCoverBackdrop: View {
  @ObservedObject
  var model: AmbientBackdropModel
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  @State
  private var tiny: UIImage?

  /// The room: the record's own colour, the same in both looks (the founder, 2026-11-01).
  private var room: Color { model.room }
  /// The glass: the screen's own paper, light or dark, laid over the room and the cover. It
  /// is what keeps the app's words and buttons in their usual colours on any cover.
  private let glass = Color(uiColor: UIColor.cassette(.surfaceSunken))

  var body: some View {
    ZStack {
      room

      if let tiny {
        GeometryReader { geo in
          Image(uiImage: tiny)
            .resizable()
            .scaledToFill()
            .frame(width: geo.size.width * 1.4, height: geo.size.height * 1.4)
            .position(x: geo.size.width / 2, y: geo.size.height * 0.42)
            // Patch 114: NO `.blur` here — the tiny image is already blurred
            // off-main in AmbientBackdropCache, so first open compiles no
            // render-time blur shader on the main thread (the audio-glitch
            // fix). The bilinear upscale-to-fill keeps it soft.
            // Over the coloured room and under the glass (2026-11-01), so the cover
            // shows strongly: the glass, not a dimmed cover, keeps the rows legible.
            // Slight lift while playing, settling when paused.
            .opacity(model.isPlaying ? 0.75 : 0.62)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: model.isPlaying)
        }
        .transition(.opacity)
        .id(model.coverID)
        .animation(
          reduceMotion ? .easeInOut(duration: 0.3) : .easeInOut(duration: 0.6),
          value: model.coverID
        )
      }

      // The glass: thinnest around the cover, so the record's colour shows most there, and
      // thick under the title and the controls, where the words need the paper's contrast
      // (4.5:1 for the quiet type on light and on dark, measured on pale and dark covers).
      LinearGradient(
        stops: [
          .init(color: glass.opacity(model.isListShown ? 0.8 : 0.5), location: 0),
          .init(color: glass.opacity(model.isListShown ? 0.82 : 0.62), location: 0.42),
          .init(color: glass.opacity(0.86), location: 0.62),
          .init(color: glass.opacity(0.9), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: model.room)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: model.isListShown)
    .ignoresSafeArea()
    .task(id: model.coverID) {
      guard let image = model.image else { tiny = nil; return }
      tiny = await AmbientBackdropCache.tiny(for: model.coverID, image: image)
    }
  }
}

// MARK: - CoverGlowRecipe

/// Where and how strongly a record's glow sits behind a surface (phone-taste mocks: the
/// `.ambient` layer and each surface's `::after` scrim in phone.module.css). The glow is
/// the same tiny pre-blurred cover Now Playing uses (`AmbientBackdropCache`): never
/// blurred at render time (Patch 114), and no saturation boost; the app's recipe is
/// canonical.
struct CoverGlowRecipe {
  /// One scrim stop: a colour role at an alpha, at a location from 0 to 1.
  typealias Stop = (role: CassetteColorRole, alpha: CGFloat, location: CGFloat)

  enum Scrim {
    case none
    /// Top to bottom over the host's bounds.
    case vertical([Stop])
    /// Leading to trailing over the host's bounds.
    case horizontal([Stop])
  }

  /// The glow square's side is the host's width times this, centred horizontally.
  var sizeFactor: CGFloat
  /// The glow's top is the host's height times this, plus `topOffset`.
  var topFactor: CGFloat
  var topOffset: CGFloat
  /// The glow's opacity.
  var alpha: CGFloat
  /// The warm scrim laid over the glow.
  var scrim: Scrim
  /// How much of the glow square, measured up from its bottom edge, fades out to nothing
  /// (0 keeps a hard edge). The mock's glow is a CSS blur, which softens its own edges; the
  /// app's pre-blurred tiny is drawn into a clipped square, so on a tall page its bottom
  /// edge showed as a hard line where the scrim had not yet gone opaque (founder,
  /// 2026-10-21). The fade eases out, so there is no visible start either.
  var bottomFade: CGFloat = 0

  /// Album, artist and playlist pages (`.albumPage::after`): the glow rises above the hero
  /// and the scrim reaches the solid page at the host's bottom edge. Dialled toward Now
  /// Playing's room (founder, 2026-10-21: a red cover lit the album page "REALLY intense",
  /// Now Playing "soft and beautiful"): a dimmer glow (0.55 to 0.42) and a darker top (0.2
  /// to 0.4, as Now Playing darkens toward its edges), so a strong cover tints the page
  /// instead of painting it.
  static let page = CoverGlowRecipe(
    sizeFactor: 1.4,
    topFactor: 0,
    topOffset: -160,
    alpha: 0.42,
    scrim: .vertical([
      (.surfaceSunken, 0.4, 0),
      (.surfaceBase, 0.62, 0.45),
      (.surfaceBase, 1.0, 1.0),
    ]),
    bottomFade: 0.35
  )

  /// The Home Resume card (`.resume .ambient`, `.resume::after`).
  static let resumeCard = CoverGlowRecipe(
    sizeFactor: 1.2,
    topFactor: -1.2,
    topOffset: 0,
    alpha: 0.75,
    scrim: .horizontal([
      (.surfaceBase, 0.25, 0),
      (.surfaceBase, 0.7, 0.7),
    ])
  )

  /// The Search top result (`.topResult .ambient`, `.topResult::after`).
  static let topResult = CoverGlowRecipe(
    sizeFactor: 1.2,
    topFactor: -0.8,
    topOffset: 0,
    alpha: 0.8,
    scrim: .horizontal([
      (.surfaceBase, 0.2, 0),
      (.surfaceBase, 0.7, 0.75),
    ])
  )

  /// A Search genre tile (`.genreGlow`: inset -40% each side, centred).
  static let genreTile = CoverGlowRecipe(
    sizeFactor: 1.8,
    topFactor: -0.4,
    topOffset: 0,
    alpha: 0.55,
    scrim: .none
  )

  /// The glow square inside a host of `size`.
  func glowFrame(in size: CGSize) -> CGRect {
    let side = size.width * sizeFactor
    return CGRect(
      x: (size.width - side) / 2,
      y: size.height * topFactor + topOffset,
      width: side,
      height: side
    )
  }

  /// The glow's own alpha mask, top to bottom: opaque, then easing out over the bottom
  /// `bottomFade` of the square (a smoothstep, so neither end of the fade shows as a line).
  /// nil when there is no fade.
  var bottomFadeStops: [(alpha: CGFloat, location: CGFloat)]? {
    guard bottomFade > 0 else { return nil }
    let start = 1 - min(bottomFade, 1)
    return [0, 0.25, 0.5, 0.75, 1].map { t in
      let eased = t * t * (3 - 2 * t)
      return (alpha: 1 - eased, location: start + (1 - start) * t)
    }
  }

  /// The scrim's gradient, or nil for `.none`.
  var gradient: (stops: [Stop], horizontal: Bool)? {
    switch scrim {
    case .none: return nil
    case let .vertical(stops): return (stops, false)
    case let .horizontal(stops): return (stops, true)
    }
  }
}

// MARK: - CoverGlowView

/// A record's glow behind a UIKit surface (a detail hero, the Resume card, a search
/// result, a genre tile): the AmbientCoverBackdrop recipe without the full-screen player
/// wiring, so it can sit inside a cell. Hosts place it behind their content; it never
/// takes touches and never clips (the glow rises past the host's top).
@MainActor
final class CoverGlowView: UIView {
  let recipe: CoverGlowRecipe

  private let glowImageView: UIImageView = {
    let view = UIImageView()
    view.contentMode = .scaleAspectFill
    view.clipsToBounds = true
    view.alpha = 0
    return view
  }()

  private let scrimLayer = CAGradientLayer()
  /// The glow's soft bottom edge (`recipe.bottomFade`); unused when the recipe has none.
  private let fadeMask = CAGradientLayer()
  /// The key of the cover being shown (or loading). A newer `show` or `clear` replaces
  /// the token, so a late load for a reused cell is dropped.
  private var currentKey: String?
  private var loadToken = UUID()

  init(recipe: CoverGlowRecipe) {
    self.recipe = recipe
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    clipsToBounds = false
    backgroundColor = .clear
    addSubview(glowImageView)
    if let stops = recipe.bottomFadeStops {
      fadeMask.colors = stops.map { UIColor.black.withAlphaComponent($0.alpha).cgColor }
      fadeMask.locations = stops.map { NSNumber(value: Double($0.location)) }
      fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
      fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
      glowImageView.layer.mask = fadeMask
    }
    if recipe.gradient != nil {
      layer.addSublayer(scrimLayer)
      applyScrimColors()
    }
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
      self.applyScrimColors()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    glowImageView.frame = recipe.glowFrame(in: bounds.size)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    scrimLayer.frame = bounds
    fadeMask.frame = glowImageView.bounds
    CATransaction.commit()
  }

  /// Glow from an image already in hand, cached under `key`. nil clears.
  func show(image: UIImage?, key: String) {
    guard let image else { clear(); return }
    guard begin(key: key) else { return }
    let token = loadToken
    if let hit = AmbientBackdropCache.cachedTiny(for: key) {
      apply(hit)
      return
    }
    Task { [weak self] in
      let tiny = await AmbientBackdropCache.tiny(for: key, image: image)
      guard let self, self.loadToken == token else { return }
      self.apply(tiny)
    }
  }

  /// Glow from a cover on disk, keyed by the foundation's cover key (`CoverTint.cacheKey`:
  /// the path plus the file's date), the key Now Playing and the record pages use, so their
  /// cached tiny is reused and a cover replaced at the same path glows anew. A missing or
  /// unreadable file clears.
  func show(coverPath: String?) {
    guard let coverPath, !coverPath.isEmpty else { clear(); return }
    let key = CoverTint.cacheKey(forCoverPath: coverPath)
    guard begin(key: key) else { return }
    let token = loadToken
    if let hit = AmbientBackdropCache.cachedTiny(for: key) {
      apply(hit)
      return
    }
    Task { [weak self] in
      let decoded = await Task.detached(priority: .utility) {
        AmbientSourceDecoder.thumbnail(contentsOfFile: coverPath, maxPixelSize: 64)
      }.value
      guard let self, self.loadToken == token else { return }
      guard let decoded else {
        self.clear()
        return
      }
      let tiny = await AmbientBackdropCache.tiny(for: key, image: decoded)
      guard self.loadToken == token else { return }
      self.apply(tiny)
    }
  }

  /// No glow. Drops any load in flight.
  func clear() {
    currentKey = nil
    loadToken = UUID()
    glowImageView.layer.removeAllAnimations()
    glowImageView.alpha = 0
    glowImageView.image = nil
  }

  /// Starts showing `key`. False when that cover is already up (nothing to do). A
  /// different cover is taken down at once, so a reused cell never shows the last one.
  private func begin(key: String) -> Bool {
    if key == currentKey, glowImageView.image != nil { return false }
    if key != currentKey {
      glowImageView.layer.removeAllAnimations()
      glowImageView.alpha = 0
      glowImageView.image = nil
    }
    currentKey = key
    loadToken = UUID()
    return true
  }

  private func apply(_ tiny: UIImage) {
    glowImageView.image = tiny
    let duration = UIAccessibility.isReduceMotionEnabled ? 0.3 : 0.6
    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      self.glowImageView.alpha = self.recipe.alpha
    }
  }

  private func applyScrimColors() {
    guard let gradient = recipe.gradient else { return }
    // resolved against this view's own light or dark (I-T1), not whatever is current
    scrimLayer.colors = gradient.stops.map {
      UIColor.cassette($0.role).resolvedColor(with: traitCollection).withAlphaComponent($0.alpha).cgColor
    }
    scrimLayer.locations = gradient.stops.map { NSNumber(value: Double($0.location)) }
    scrimLayer.startPoint = gradient.horizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
    scrimLayer.endPoint = gradient.horizontal ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
  }
}

// MARK: - CoverGlowLayer

/// The SwiftUI twin of `CoverGlowView`, for SwiftUI pages (the Mac page): the same tiny
/// cover and scrim with the same geometry. Place it behind the content (a ZStack's first
/// layer, or `.background`).
struct CoverGlowLayer: View {
  let image: UIImage?
  let key: String
  let recipe: CoverGlowRecipe

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State
  private var tiny: UIImage?

  init(image: UIImage?, key: String, recipe: CoverGlowRecipe) {
    self.image = image
    self.key = key
    self.recipe = recipe
  }

  var body: some View {
    GeometryReader { geo in
      let frame = recipe.glowFrame(in: geo.size)
      ZStack(alignment: .topLeading) {
        if let tiny {
          Image(uiImage: tiny)
            .resizable()
            .scaledToFill()
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .mask {
              if let stops = recipe.bottomFadeStops {
                LinearGradient(
                  stops: stops.map {
                    Gradient.Stop(color: .black.opacity($0.alpha), location: $0.location)
                  },
                  startPoint: .top,
                  endPoint: .bottom
                )
              } else {
                Rectangle()
              }
            }
            .opacity(recipe.alpha)
            .position(x: frame.midX, y: frame.midY)
            .transition(.opacity)
        }
        if let gradient = recipe.gradient {
          LinearGradient(
            stops: gradient.stops.map {
              Gradient.Stop(
                color: Color.cassette($0.role).opacity($0.alpha),
                location: $0.location
              )
            },
            startPoint: gradient.horizontal ? .leading : .top,
            endPoint: gradient.horizontal ? .trailing : .bottom
          )
          .frame(width: geo.size.width, height: geo.size.height)
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .task(id: key) {
      guard let image else {
        tiny = nil
        return
      }
      let loaded = await AmbientBackdropCache.tiny(for: key, image: image)
      withAnimation(.easeInOut(duration: reduceMotion ? 0.3 : 0.6)) {
        tiny = loaded
      }
    }
  }
}
