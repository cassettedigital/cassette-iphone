//
//  WaveformAnimatedView.swift
//  Amperfy
//
//  cassette Patch 071: three-bar pulsing waveform (dynamic-island style).

import AmperfyKit
import UIKit

@MainActor
final class WaveformAnimatedView: UIView {
  private static let barWidth: CGFloat = 3
  private static let barSpacing: CGFloat = 3
  private static let maxBarHeight: CGFloat = 18
  private static let minBarHeight: CGFloat = 4

  private var bars: [UIView] = []
  private var barHeightConstraints: [NSLayoutConstraint] = []
  private var displayLink: CADisplayLink?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    setupBars()
    observeNowPlayingTint()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    isUserInteractionEnabled = false
    setupBars()
    observeNowPlayingTint()
  }

  private func setupBars() {
    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .bottom
    stack.spacing = Self.barSpacing
    stack.distribution = .equalSpacing
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.heightAnchor.constraint(equalToConstant: Self.maxBarHeight),
    ])

    for _ in 0 ..< 3 {
      let bar = UIView()
      bar.translatesAutoresizingMaskIntoConstraints = false
      bar.backgroundColor = CoverTint.nowPlaying.text
      bar.layer.cornerRadius = 1
      let height = bar.heightAnchor.constraint(equalToConstant: Self.midBarHeight)
      NSLayoutConstraint.activate([
        bar.widthAnchor.constraint(equalToConstant: Self.barWidth),
        height,
      ])
      bars.append(bar)
      barHeightConstraints.append(height)
      stack.addArrangedSubview(bar)
    }
    setBarHeights(to: Self.midBarHeight)
  }

  /// The bars only ever mark the playing song, so they speak in the playing record's colour
  /// (`CoverTint.nowPlaying`), as its artist name does, and follow it to the next record.
  private func observeNowPlayingTint() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(nowPlayingTintChanged),
      name: .cassetteNowPlayingTintChanged,
      object: nil
    )
  }

  @objc
  private func nowPlayingTintChanged() {
    for bar in bars { bar.backgroundColor = CoverTint.nowPlaying.text }
  }

  private static var midBarHeight: CGFloat {
    (maxBarHeight + minBarHeight) / 2
  }

  private func setBarHeights(to height: CGFloat) {
    for constraint in barHeightConstraints {
      constraint.constant = height
    }
  }

  func startAnimating() {
    // cassette (I-M3): with Reduce Motion the bars hold still at mid height; the mark still
    // says this one is playing.
    guard !UIAccessibility.isReduceMotionEnabled else {
      setBarHeights(to: Self.midBarHeight)
      return
    }
    guard displayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stopAnimating() {
    displayLink?.invalidate()
    displayLink = nil
    setBarHeights(to: Self.midBarHeight)
  }

  @objc
  private func tick() {
    let time = CACurrentMediaTime()
    for index in 0 ..< bars.count {
      let phase = Double(index) * .pi / 2
      let wave = (sin(time * 6 + phase) + 1) / 2
      let height = Self.minBarHeight + CGFloat(wave) * (Self.maxBarHeight - Self.minBarHeight)
      barHeightConstraints[index].constant = height
    }
  }

  override func removeFromSuperview() {
    stopAnimating()
    super.removeFromSuperview()
  }
}
