//
//  EntityImageView.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 20.02.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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

import Foundation
import UIKit

open class EntityImageView: UIView {
  /// cassette Patch 104 (Root 3): the corner radius used to be owned by two
  /// parties — `display()` stomped `layer.cornerRadius` back to 5pt on every
  /// artwork refresh while hosts applied circle masks one-shot in their own
  /// `layoutSubviews`. Whoever ran last won, so artist circles flashed round
  /// then went square (or never rounded at all on reused cells). The shape is
  /// now owned here and re-applied on both layout and display.
  public enum Shape {
    case rounded(CornerRadius)
    case circle
  }

  public var shape: Shape = .rounded(.small) {
    didSet { applyShape() }
  }

  @IBOutlet
  weak var singleImage: LibraryEntityImage!
  @IBOutlet
  weak var quadImage1: LibraryEntityImage!
  @IBOutlet
  weak var quadImage2: LibraryEntityImage!
  @IBOutlet
  weak var quadImage3: LibraryEntityImage!
  @IBOutlet
  weak var quadImage4: LibraryEntityImage!

  private var view: UIView!
  /// Cancels stale cloud-cover loads when a cell is reused.
  private var remoteCoverLoadID = UUID()
  /// phone-taste: a playlist's own cover (the person's pick or its preset) draws here,
  /// never through `singleImage`. A reused cell's LibraryEntityImage can still have a
  /// cover decode running for the album it showed last; when that decode lands it
  /// repaints the generated placeholder, because handing it a bitmap cleared its
  /// entity. On `singleImage` that greyed the playlist's cover (the D03 clobber, on a
  /// recycled cell). Here `singleImage` is hidden while the cover shows, so a late
  /// repaint lands on a view nobody sees. Pinned to `singleImage`'s edges, with its
  /// corner radius, so it sits exactly where the single cover always sat.
  private let playlistCoverView: UIImageView = {
    let imageView = UIImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFill
    imageView.isUserInteractionEnabled = false
    imageView.layer.cornerRadius = RoundedImage.cornerRadius
    imageView.layer.masksToBounds = true
    imageView.isHidden = true
    return imageView
  }()

  private var quadImages: [LibraryEntityImage] {
    [
      quadImage1,
      quadImage2,
      quadImage3,
      quadImage4,
    ]
  }

  required public init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    loadViewFromNib()
  }

  override public init(frame: CGRect) {
    super.init(frame: frame)
    loadViewFromNib()
  }

  public func loadViewFromNib() {
    let bundle = Bundle(for: type(of: self))
    let nib = UINib(nibName: String(describing: type(of: self)), bundle: bundle)
    let view = nib.instantiate(withOwner: self, options: nil).first as! UIView
    view.frame = bounds
    view.autoresizingMask = [
      UIView.AutoresizingMask.flexibleWidth,
      UIView.AutoresizingMask.flexibleHeight,
    ]
    addSubview(view)
    self.view = view

    backgroundColor = .clear

    layer.masksToBounds = true
    self.view.backgroundColor = .clear
    self.view.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    // cassette Patch 107: the inner nib view's xib pins the artwork with a
    // required `top >= topMargin`. With the default
    // insetsLayoutMarginsFromSafeArea the topMargin inflates to
    // safeAreaInsets.top whenever this view sits under a bar (the
    // extendsUnderNavigationBar detail header), collapsing the artwork to
    // ~2×(radius − safeAreaTop) at rest and defeating the @999 edge-fill.
    // Zeroing it mirrors the header fix; it is a no-op for row/list thumbnails
    // (no safe-area overlap), so only the under-bar header case changes.
    self.view.insetsLayoutMarginsFromSafeArea = false
    quadImages[0].layer.maskedCorners = [
      .layerMinXMinYCorner,
      .layerMaxXMinYCorner,
      .layerMinXMaxYCorner,
      .layerMaxXMaxYCorner,
    ]
    quadImages[0].layer.maskedCorners = [.layerMinXMinYCorner]
    quadImages[1].layer.maskedCorners = [.layerMaxXMinYCorner]
    quadImages[2].layer.maskedCorners = [.layerMinXMaxYCorner]
    quadImages[3].layer.maskedCorners = [.layerMaxXMaxYCorner]
    // Last subview, so it sits above the single cover and the quad stack.
    self.view.addSubview(playlistCoverView)
    NSLayoutConstraint.activate([
      playlistCoverView.leadingAnchor.constraint(equalTo: singleImage.leadingAnchor),
      playlistCoverView.trailingAnchor.constraint(equalTo: singleImage.trailingAnchor),
      playlistCoverView.topAnchor.constraint(equalTo: singleImage.topAnchor),
      playlistCoverView.bottomAnchor.constraint(equalTo: singleImage.bottomAnchor),
    ])
  }

  public func display(
    theme: ThemePreference,
    container: PlayableContainable,
    cornerRadius: CornerRadius = .small
  ) {
    // cassette: cloud playlist cover (web-chosen) wins over the song mosaic.
    if let playlist = container as? Playlist,
       let urlString = CassetteCloudPlaylistBridge.storedCoverUrl(for: playlist.id),
       let url = URL(string: urlString) {
      // cassette (D03): do NOT run the song-mosaic path (display(collection:)) first.
      // It calls singleImage.displayAndUpdate(entity:), which spawns an async decode
      // that fires AFTER applyRemoteCover nils the entity and repaints the grey
      // placeholder OVER the cover (the clobber that greyed a playlist whose cover was
      // set on the web). Set up a clean single-image placeholder, then load the cover.
      if case .circle = shape { applyShape() } else { shape = .rounded(cornerRadius) }
      hidePlaylistCover()
      quadImages.forEach { $0.isHidden = true }
      singleImage.isHidden = false
      singleImage.display(artworkType: .playlist)
      loadRemoteCover(url, playlistId: playlist.id, urlKey: urlString, theme: theme, container: container)
      return
    }
    // phone-taste: a playlist with no cover of its own gets its derived preset, the same
    // one the web picks. A playlist never draws an album-art mosaic (founder rule). Only
    // the player queue (an empty id) keeps the song art.
    if let playlist = container as? Playlist,
       let preset = CassetteCloudPlaylistBridge.derivedPresetCoverImage(forPlaylistId: playlist.id) {
      if case .circle = shape { applyShape() } else { shape = .rounded(cornerRadius) }
      let loadID = UUID()
      remoteCoverLoadID = loadID
      applyRemoteCover(preset, loadID: loadID)
      return
    }
    remoteCoverLoadID = UUID()
    display(
      theme: theme,
      collection: container.getArtworkCollection(theme: theme),
      cornerRadius: cornerRadius
    )
  }

  /// A picture the caller made (a station's mark): one image, nothing behind it.
  public func display(image: UIImage, cornerRadius: CornerRadius = .small) {
    if case .circle = shape { applyShape() } else { shape = .rounded(cornerRadius) }
    hidePlaylistCover()
    quadImages.forEach { $0.isHidden = true }
    singleImage.isHidden = false
    singleImage.display(image: image)
  }

  private func loadRemoteCover(
    _ url: URL,
    playlistId: String,
    urlKey: String,
    theme: ThemePreference,
    container: PlayableContainable
  ) {
    let loadID = UUID()
    remoteCoverLoadID = loadID
    // Curated presets: prefer the bundled PNG (live site only has SVG today) — local.
    if let bundled = CassetteCloudPlaylistBridge.bundledPresetCoverImage(forCoverUrl: url.absoluteString)
    {
      applyRemoteCover(bundled, loadID: loadID)
      return
    }
    // A picked cover already materialized on disk for THIS url — local, offline, no flash.
    // Decoded at this view's size (a 70pt row, not the 1400px upload), once (BUG-819).
    let maxPixel = CoverImageStore.decodePixels(forPoints: max(bounds.width, bounds.height))
    if let local = CassetteCloudPlaylistBridge.materializedCoverImage(
      for: playlistId,
      url: urlKey,
      maxPixel: maxPixel
    ) {
      applyRemoteCover(local, loadID: loadID)
      return
    }
    Task { [weak self] in
      do {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
          await self?.fallBackToPreset(theme: theme, container: container, loadID: loadID)
          return
        }
        // Persist so the next cold/offline launch reads local (best-effort), then read it
        // back at this view's size.
        CassetteCloudPlaylistBridge.storeMaterializedCover(data, for: playlistId, url: urlKey)
        // (A failed write, rare, still shows the download as it came.)
        guard let image = CassetteCloudPlaylistBridge.materializedCoverImage(
          for: playlistId,
          url: urlKey,
          maxPixel: maxPixel
        ) ?? UIImage(data: data) else {
          await self?.fallBackToPreset(theme: theme, container: container, loadID: loadID)
          return
        }
        await MainActor.run {
          self?.applyRemoteCover(image, loadID: loadID)
        }
      } catch {
        // Offline / unreachable: fall through to the playlist's preset instead of
        // leaving the generic playlist glyph (a picked cover that hasn't materialized
        // yet otherwise reads as art-less until the network returns).
        await self?.fallBackToPreset(theme: theme, container: container, loadID: loadID)
      }
    }
  }

  @MainActor
  private func fallBackToPreset(theme: ThemePreference, container: PlayableContainable, loadID: UUID) {
    // Only if no newer display started (a real cover landing must win). The preset
    // draws in playlistCoverView, so a cover decode still running on singleImage
    // cannot repaint over it.
    guard remoteCoverLoadID == loadID else { return }
    // phone-taste: a playlist whose picked cover cannot load shows its derived preset,
    // never an album-art mosaic. Only an id-less playlist (the queue) keeps the song art.
    if let playlist = container as? Playlist,
       let preset = CassetteCloudPlaylistBridge.derivedPresetCoverImage(forPlaylistId: playlist.id) {
      applyRemoteCover(preset, loadID: loadID)
      return
    }
    display(theme: theme, collection: container.getArtworkCollection(theme: theme))
  }

  private func applyRemoteCover(_ image: UIImage, loadID: UUID) {
    guard remoteCoverLoadID == loadID else { return }
    quadImages.forEach { $0.isHidden = true }
    // Hidden, not repainted: a decode still in flight on singleImage lands unseen.
    singleImage.isHidden = true
    playlistCoverView.image = image
    playlistCoverView.isHidden = false
  }

  private func hidePlaylistCover() {
    playlistCoverView.isHidden = true
    playlistCoverView.image = nil
  }

  public func configureStyling(
    image: UIImage,
    imageSizeType: ArtworkIconSizeType,
    imageTintColor: UIColor,
    backgroundColor: UIColor
  ) {
    // The icon draws in singleImage, which a playlist cover leaves hidden.
    hidePlaylistCover()
    singleImage.isHidden = false
    singleImage.tintColor = imageTintColor
    view.backgroundColor = backgroundColor
    view.layoutMargins = UIEdgeInsets(
      top: imageSizeType.rawValue,
      left: imageSizeType.rawValue,
      bottom: imageSizeType.rawValue,
      right: imageSizeType.rawValue
    )
    let modImage = image.withRenderingMode(.alwaysTemplate)
    singleImage.display(image: modImage)
  }

  override open func layoutSubviews() {
    super.layoutSubviews()
    applyShape()
  }

  private func applyShape() {
    layer.masksToBounds = true
    switch shape {
    case let .rounded(radius):
      layer.cornerRadius = radius.asCGFloat
    case .circle:
      layer.cornerRadius = min(bounds.width, bounds.height) / 2.0
    }
  }

  private func display(
    theme: ThemePreference,
    collection: ArtworkCollection,
    cornerRadius: CornerRadius = .small
  ) {
    // Patch 104 (Root 3): an explicit `.circle` shape set by the host wins;
    // otherwise the call-site radius parameter keeps working as before.
    if case .circle = shape {
      applyShape()
    } else {
      shape = .rounded(cornerRadius)
    }
    hidePlaylistCover()
    quadImages.forEach { $0.isHidden = true }
    singleImage.isHidden = false

    if let quadEntities = collection.quadImageEntity {
      if quadEntities.count > 1 {
        // check if all images are the same
        if Set(quadEntities.compactMap { $0.artwork?.id }).count == 1 {
          singleImage.displayAndUpdate(entity: quadEntities.first!)
        } else {
          singleImage.isHidden = true
          quadImages.forEach {
            // cassette Patch 017: transient placeholder while each tile waits
            // to be assigned its real entity below. `name: nil` falls through
            // to the SF Symbol ghost rather than rendering a blank initial.
            // A mosaic tile is half the view's side: a row's size, not the 300pt default (BUG-817).
            let side = CoverImageStore.rowSurfaceMaxPt
            $0.display(image: UIImage.getGeneratedArtwork(
              theme: theme,
              artworkType: .song,
              name: nil,
              size: CGSize(width: side, height: side)
            ))
            $0.isHidden = false
          }
          for (index, entity) in quadEntities.enumerated() {
            guard index < quadImages.count else { break }
            quadImages[index].display(entity: entity)
          }
        }
      } else if let firstEntity = quadEntities.first {
        singleImage.displayAndUpdate(entity: firstEntity)
      } else {
        singleImage.display(artworkType: collection.defaultArtworkType)
      }
    } else if let singleEntity = collection.singleImageEntity {
      singleImage.displayAndUpdate(entity: singleEntity)
    } else {
      singleImage.display(artworkType: collection.defaultArtworkType)
    }
  }
}
