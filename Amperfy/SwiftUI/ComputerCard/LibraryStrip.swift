//
//  LibraryStrip.swift
//  Amperfy
//
//  Cassette fork (BUG-899): the card's library strip, four places and the progress bar,
//  the same strip in every state that has one (the board's TileRow, one for one):
//
//  - skeleton: nothing has arrived yet (the computer is getting ready). One slow 3.6 s wave
//    runs through it: each empty tile dims toward the card's colour in turn, then a band of
//    the card's colour washes through the empty bar; a pause, and again. A negative-space
//    fade, no sheen (founder 2026-11-07).
//  - covers: the person's albums arriving. They fade in under the empty tiles place by
//    place and breathe between 80% and 50% in one slow left-to-right wave (3 s a breath)
//    that keeps running as the row slides; every 5.5 s the row slides one place left and
//    the newest arrival not shown yet lands in the last place out of a soft blur. The bar
//    fills in orange.
//  - still: the albums that are in, held at a steady fade, the bar paused in grey (the
//    computer is out of reach).
//
//  Reduce Motion stills all of it. Nothing in it slides vertically.
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

import SwiftUI
import UIKit

struct LibraryStrip: View {
  enum Mode: Equatable {
    case skeleton
    case covers
    case still
  }

  /// One album's cover, already decoded small.
  struct Cover: Identifiable, Equatable {
    let id: String
    let image: UIImage

    static func == (lhs: Cover, rhs: Cover) -> Bool { lhs.id == rhs.id }
  }

  let mode: Mode
  /// The albums in, newest first.
  let covers: [Cover]
  /// 0 to 1.
  let progress: Double

  // MARK: Timings (the board's numbers)

  static let places = 4
  static let gap: CGFloat = 10
  static let radius: CGFloat = 5
  static let barHeight: CGFloat = 4
  static let barGap: CGFloat = 16

  /// Every 5.5 s the row moves one place left.
  static let slideEvery: Duration = .milliseconds(5500)
  static let slide = Animation.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.7)
  /// The newest cover comes in out of a soft blur, a beat after the row moves.
  static let landing = Animation.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.7).delay(0.28)
  static let landingScale: CGFloat = 0.84
  static let landingBlur: CGFloat = 6

  /// Covers breathing: one breath is six half-second beats; place j runs j beats behind.
  static let beat: Duration = .milliseconds(500)
  static let breathHigh = 0.8
  static let breathLow = 0.5
  static let held = 0.65
  static let breathing = Animation.easeInOut(duration: 1.5)

  /// The skeleton's wave: a 3.6 s round; tile k dims for 0.7 s starting k x 0.3 s in, then
  /// the band crosses the bar from 0.9 s to 2.5 s.
  static let round = 3600
  static let dimmedTo = 0.42
  static let tileGap = 300
  static let tileDim = 700
  static let bandFrom = 900
  static let bandFor = 1600
  static let bandWidth: CGFloat = 120

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  /// What each place along the row shows: the cover at absolute position `base + i` is
  /// `order[i]`. The row shows positions `step ..< step + 4`; `step - 1` is the one sliding
  /// away. Positions never change once given, so a tile keeps its identity (and its breath)
  /// as the row moves, and old history can be let go without redrawing anything.
  @State
  private var order: [String] = []
  @State
  private var base = 0
  @State
  private var step = 0
  /// The position each cover was last placed at; a cover never placed is a new arrival.
  @State
  private var lastPlacedAt: [String: Int] = [:]
  /// The pictures of every cover in the row or in the pool, so one that has dropped out of
  /// the newest few still draws while it is in view.
  @State
  private var images: [String: UIImage] = [:]
  @State
  private var beatCount = 0
  @State
  private var dimmed: Set<Int> = []
  @State
  private var bandProgress: CGFloat = 0
  @State
  private var bandShown = false
  /// True for a moment after a mode change, so covers and tiles hand over place by place.
  @State
  private var revealing = false

  var body: some View {
    VStack(alignment: .leading, spacing: Self.barGap) {
      row
      bar
    }
    .onAppear { arrange(covers, initial: true) }
    .onChange(of: covers) { _, new in arrange(new, initial: false) }
    .onChange(of: mode) { _, _ in
      revealing = true
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(1600))
        revealing = false
      }
    }
    .task(id: motionKey) { await runMotion() }
    .accessibilityHidden(true)
  }

  // MARK: The row

  private var row: some View {
    StripRowLayout(gap: Self.gap) {
      ForEach(Array(placedIndices), id: \.self) { abs in
        if let image = cover(at: abs) {
          coverTile(image, abs: abs)
            .layoutValue(key: StripPlace.self, value: CGFloat(abs - step))
            .transition(entering)
        }
      }
      ForEach(0 ..< Self.places, id: \.self) { place in
        emptyTile(place)
          .layoutValue(key: StripPlace.self, value: CGFloat(place))
          .zIndex(1)
      }
    }
    .clipped()
  }

  /// The positions drawn: the one sliding away and the four in place.
  private var placedIndices: [Int] {
    guard !order.isEmpty else { return [] }
    return Array(max(base, step - 1) ..< min(end, step + Self.places))
  }

  /// One past the last position given.
  private var end: Int { base + order.count }

  /// How many places of the row hold a cover.
  private var filled: Int { max(0, min(Self.places, end - step)) }

  private func cover(at abs: Int) -> UIImage? {
    guard abs >= base, abs < end else { return nil }
    return images[order[abs - base]]
  }

  private func coverTile(_ image: UIImage, abs: Int) -> some View {
    let place = abs - step
    let inPlace = place >= 0 && place < Self.places
    let shows = inPlace && mode != .skeleton
    return Color.clear
      .overlay {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      }
      .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
      .opacity(breath(abs))
      .animation(reduceMotion ? nil : Self.breathing, value: beatCount)
      .animation(reduceMotion ? nil : .easeInOut(duration: 1.5), value: mode)
      .opacity(shows ? 1 : 0)
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.6)
          .delay(revealing ? 0.1 + Double(max(place, 0)) * 0.13 : 0),
        value: shows
      )
  }

  /// A cover's own breath: the covers' wave while they arrive, held still otherwise.
  private func breath(_ abs: Int) -> Double {
    guard mode == .covers, !reduceMotion else { return Self.held }
    let j = ((abs % 6) + 6) % 6
    let phase = (((beatCount - j) % 6) + 6) % 6
    return phase < 3 ? Self.breathHigh : Self.breathLow
  }

  private var entering: AnyTransition {
    guard !reduceMotion else { return .identity }
    return .asymmetric(
      insertion: .modifier(
        active: Landing(scale: Self.landingScale, blur: Self.landingBlur, opacity: 0),
        identity: Landing(scale: 1, blur: 0, opacity: 1)
      ).animation(Self.landing),
      removal: .opacity.animation(.easeOut(duration: 0.3))
    )
  }

  /// An empty place: shown while nothing has arrived, or where no cover is yet.
  private func emptyTile(_ place: Int) -> some View {
    let hasCover = mode != .skeleton && cover(at: step + place) != nil
    let isDimmed = mode == .skeleton && dimmed.contains(place)
    return RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
      .fill(CardColors.emptyTile)
      .opacity(isDimmed ? Self.dimmedTo : 1)
      .animation(reduceMotion ? nil : .easeInOut(duration: Double(Self.tileDim) / 1000), value: isDimmed)
      .opacity(hasCover ? 0 : 1)
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.6).delay(revealing ? Double(place) * 0.13 : 0),
        value: hasCover
      )
      .allowsHitTesting(false)
  }

  // MARK: The bar

  private var bar: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule()
          .fill(mode == .skeleton ? CardColors.emptyTile : CardColors.track)
        Capsule()
          .fill(mode == .still ? CardColors.paused : CardColors.filling)
          .frame(width: mode == .skeleton ? 0 : width * min(max(progress, 0), 1))
          .animation(reduceMotion ? nil : CardMotion.sizing.speed(0.6 / 0.9), value: progress)
        LinearGradient(
          colors: [CardColors.card.opacity(0), CardColors.card.opacity(0.95), CardColors.card.opacity(0)],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: Self.bandWidth)
        .offset(x: -Self.bandWidth + bandProgress * (width + Self.bandWidth))
        .opacity(bandShown && mode == .skeleton ? 1 : 0)
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: mode)
      .clipShape(Capsule())
    }
    .frame(height: Self.barHeight)
  }

  // MARK: Placing covers

  /// Keeps the places in step with the covers in: while the row is not full, every arrival
  /// takes the next empty place (oldest on the left); once it is, the motion loop brings
  /// each new arrival in at the right.
  private func arrange(_ covers: [Cover], initial: Bool) {
    guard !covers.isEmpty else {
      order = []
      base = 0
      step = 0
      lastPlacedAt = [:]
      images = [:]
      return
    }
    for cover in covers where images[cover.id] == nil {
      images[cover.id] = cover.image
    }
    if order.isEmpty {
      let first = Array(covers.prefix(Self.places).map(\.id).reversed())
      order = first
      base = 0
      step = 0
      for (index, id) in first.enumerated() { lastPlacedAt[id] = index }
    } else if filled < Self.places {
      let fresh = covers.filter { lastPlacedAt[$0.id] == nil }.map(\.id).reversed()
      for id in fresh.prefix(Self.places - filled) {
        lastPlacedAt[id] = end
        order.append(id)
      }
    }
    // Let go of pictures that are neither in view nor in the pool.
    let keep = Set(covers.map(\.id)).union(placedIndices.map { order[$0 - base] })
    images = images.filter { keep.contains($0.key) }
  }

  /// The next cover to land: the newest arrival not shown yet, else the one shown longest
  /// ago that is not in view.
  private func nextCover() -> String? {
    if let fresh = covers.first(where: { lastPlacedAt[$0.id] == nil }) { return fresh.id }
    let inView = Set(placedIndices.map { order[$0 - base] })
    let candidates = covers.filter { !inView.contains($0.id) }
    return candidates.min { (lastPlacedAt[$0.id] ?? 0) < (lastPlacedAt[$1.id] ?? 0) }?.id
  }

  // MARK: Motion

  private var motionKey: String { "\(mode)-\(reduceMotion)" }

  private func runMotion() async {
    guard !reduceMotion else {
      dimmed = []
      bandShown = false
      return
    }
    switch mode {
    case .skeleton:
      await runSkeletonWave()
    case .covers:
      await runArrivals()
    case .still:
      dimmed = []
      bandShown = false
    }
  }

  /// One wave per round, forever, until the mode changes (the task is cancelled).
  private func runSkeletonWave() async {
    var events: [(at: Int, act: @MainActor () -> ())] = []
    for k in 0 ..< Self.places {
      events.append((k * Self.tileGap, { dimmed.insert(k) }))
      events.append((k * Self.tileGap + Self.tileDim, { dimmed.remove(k) }))
    }
    events.append((Self.bandFrom, {
      var quiet = Transaction()
      quiet.disablesAnimations = true
      withTransaction(quiet) {
        bandProgress = 0
        bandShown = true
      }
      withAnimation(.linear(duration: Double(Self.bandFor) / 1000)) { bandProgress = 1 }
    }))
    events.append((Self.bandFrom + Self.bandFor, {
      var quiet = Transaction()
      quiet.disablesAnimations = true
      withTransaction(quiet) {
        bandShown = false
        bandProgress = 0
      }
    }))
    events.sort { $0.at < $1.at }
    let clock = ContinuousClock()
    while !Task.isCancelled {
      let start = clock.now
      for event in events {
        try? await Task.sleep(until: start + .milliseconds(event.at), clock: clock)
        if Task.isCancelled { return }
        event.act()
      }
      try? await Task.sleep(until: start + .milliseconds(Self.round), clock: clock)
    }
  }

  /// The breath on every beat, and every 5.5 s the row moves one place when there is more
  /// than a row's worth to show.
  private func runArrivals() async {
    let clock = ContinuousClock()
    var nextSlide = clock.now + Self.slideEvery
    while !Task.isCancelled {
      try? await Task.sleep(for: Self.beat, clock: clock)
      if Task.isCancelled { return }
      beatCount += 1
      guard clock.now >= nextSlide else { continue }
      nextSlide = clock.now + Self.slideEvery
      guard covers.count > Self.places, filled == Self.places,
            let next = nextCover() else { continue }
      if let cover = covers.first(where: { $0.id == next }), images[next] == nil {
        images[next] = cover.image
      }
      withAnimation(Self.slide) {
        lastPlacedAt[next] = end
        order.append(next)
        step += 1
      }
      // Let go of what slid out of sight long ago, so the row's memory stays small.
      // Positions stay as given, so nothing on screen changes.
      if step - base > 64 {
        let drop = step - 1 - base
        order.removeFirst(drop)
        base += drop
      }
    }
  }
}

/// A cover landing: from a little smaller, blurred and clear, to itself.
private struct Landing: ViewModifier {
  let scale: CGFloat
  let blur: CGFloat
  let opacity: Double

  func body(content: Content) -> some View {
    content
      .scaleEffect(scale)
      .blur(radius: blur)
      .opacity(opacity)
  }
}

/// Where a tile sits along the row, in places (0 to 3 in view; -1 just left of it).
private struct StripPlace: LayoutValueKey {
  static let defaultValue: CGFloat = 0
}

/// Four square places across the width with a 10 pt gap; each tile is placed by its
/// place, so moving a tile one place is a layout change the slide animates.
private struct StripRowLayout: Layout {
  let gap: CGFloat
  /// `LibraryStrip.places`, held here so layout never reaches into the view.
  private let places: CGFloat = 4

  private func side(_ width: CGFloat) -> CGFloat {
    max(0, (width - gap * (places - 1)) / places)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 310
    return CGSize(width: width, height: side(width))
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let tile = side(bounds.width)
    for subview in subviews {
      let place = subview[StripPlace.self]
      subview.place(
        at: CGPoint(x: bounds.minX + place * (tile + gap), y: bounds.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: tile, height: tile)
      )
    }
  }
}
