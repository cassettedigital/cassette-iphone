//
//  DetailStickyHeaderSupport.swift
//  Amperfy
//
//  cassette Patch 064: shared scroll threshold for detail sticky headers.
//  cassette Patch 066: guard zero-height header + revised threshold math.
//  cassette redesign (Surface 1): the collapsed state lives entirely in the
//  NATIVE navigation bar — iOS 26 supplies the Liquid Glass treatment for
//  the bar and its buttons. At rest the bar shows back + overflow; as the
//  hero scrolls under, the title fades in and a trailing play bar-button
//  appears alongside the overflow.

import AmperfyKit
import UIKit

@MainActor
enum DetailStickyHeaderSupport {
  private static let stickyHeaderHeight: CGFloat = 56
  private static let minimumHeroHeight: CGFloat = 50

  /// Mounts the fade-in title as the navigation bar's titleView and installs
  /// the trailing bar items. `overflowItem` is always visible; the optional
  /// `collapsedPlayItem` starts hidden and is revealed by `updateAlpha` when
  /// the hero collapses.
  static func install(
    stickyHeader: DetailStickyHeaderView,
    in viewController: UIViewController,
    overflowItem: UIBarButtonItem? = nil,
    collapsedPlayItem: UIBarButtonItem? = nil
  ) {
    viewController.navigationItem.titleView = stickyHeader
    // cassette (header-pop fix, round 7c): the stickyHeader IS the sole visual
    // title. Clear BOTH UIViewController.title AND navigationItem.title. The
    // superclass (KeyCommandTableViewController.viewDidLoad) set self.title to the
    // scene name (album/artist); clearing only navigationItem.title (round 7) was
    // not enough — UIViewController.title keeps its OWN copy, and UIKit re-syncs
    // navigationItem.title FROM it during a nav transition, so the plain string
    // reappeared (gray system font) mid-swipe even though at rest it was clean.
    // Clearing self.title removes that source so nothing re-populates the bar title
    // at rest, during the pop, or on cancel. The styled stickyHeader (alpha-driven)
    // is the only title that shows; the back buttons here are icon-only, so the
    // string title has no visible job.
    viewController.title = nil
    viewController.navigationItem.title = nil
    stickyHeader.alpha = 0
    // round 7f: start genuinely hidden (not just alpha 0) — see updateAlpha. The
    // title is absent from the render tree until scroll brings it on.
    stickyHeader.isHidden = true
    collapsedPlayItem?.isHidden = true
    let trailingItems = [overflowItem, collapsedPlayItem].compactMap { $0 }
    if !trailingItems.isEmpty {
      viewController.navigationItem.rightBarButtonItems = trailingItems
    }
  }

  static func updateAlpha(
    stickyHeader: DetailStickyHeaderView,
    scrollView: UIScrollView,
    tableHeaderView: UIView?,
    in viewController: UIViewController,
    collapsedPlayItem: UIBarButtonItem? = nil
  ) {
    // cassette (header-pop fix, round 3): while the host VC is popping out
    // (interactive edge-swipe back) hold the title/bar exactly as they are.
    // The scrollViewDidScroll / viewIsAppearing paths still fire mid-transition
    // (UIKit nudges contentOffset and the inset as the bar animates toward the
    // destination's large-title layout); recomputing here would re-fade the
    // title and, via the bar-appearance reassignment, force a re-render that
    // contributes to the hero re-expanding. Freeze; the completion handler (or a
    // cancelled-swipe restore) resumes normal updates.
    if (viewController as? BasicTableViewController)?.isHeaderTransitionFrozen == true {
      // While the host VC is popping out (interactive edge-swipe), skip the
      // recompute and hold the title exactly as it is. Its visibility is driven by
      // isHidden (set below from the scroll position), so at the top it is already
      // hidden and stays hidden through the pop — there is nothing for UIKit to
      // cross-fade. Recomputing here would also force the bar-appearance
      // reassignment, a re-render that contributes to the hero re-expanding. A
      // cancelled swipe resumes normal updates via restoreOnCancel.
      collapsedPlayItem?.isHidden = true
      return
    }
    // cassette Patch 104 (Root 2): the header self-sizes now, so the hero
    // height is read from the actual table header frame (no canonical
    // constants), and the threshold is computed by converting the hero's
    // bottom edge into the root view's coordinate space. That keeps the
    // math correct both for the album/artist headers that extend under the
    // bar (contentInsetAdjustmentBehavior == .never) and for the detail
    // screens that still lay out below it.
    guard let tableHeaderView,
          tableHeaderView.frame.height >= minimumHeroHeight else {
      stickyHeader.alpha = 0
      stickyHeader.isHidden = true
      collapsedPlayItem?.isHidden = true
      return
    }

    // Patch 108: the detail VCs are UITableViewController subclasses, so
    // `viewController.view === scrollView` and the old
    // `scrollView.convert(_, to: viewController.view)` was an identity
    // transform — heroBottomY never tracked the scroll and the title never
    // faded in. The hero is the table header (content origin y == 0) and the
    // table view fills the screen from the top, so the hero's bottom edge in
    // screen space is simply maxY minus the current content offset.
    let heroBottomY = tableHeaderView.frame.maxY - scrollView.contentOffset.y
    let barBottomY = viewController.view.safeAreaInsets.top
    // Patch 108: start later + gentler. The title stays absent until the hero
    // is essentially under the bar, then cross-fades in over `fadeDistance` pt
    // of scroll (was a ~20pt near-snap). progress is monotonic in
    // -heroBottomY, so once it reaches 1 it stays 1 for the rest of the scroll.
    let fadeDistance: CGFloat = 100
    let heroProgress = max(0, min(1, (barBottomY + fadeDistance - heroBottomY) / fadeDistance))
    // 2026-10-31 (I-V14): where the page has a big title, the bar and its small title arrive
    // as that title slides under the bar, not after the whole hero (cover, title, facts and
    // the Play and Shuffle pills) has gone: keyed to the hero, the big title passed under a
    // see-through bar, crossing the back key and the half-faded small title.
    let progress: CGFloat
    if let titleBottom = Self.heroTitleBottom(in: tableHeaderView) {
      let titleBottomY = tableHeaderView.frame.minY + titleBottom - scrollView.contentOffset.y
      let titleFade: CGFloat = 44
      progress = max(0, min(1, (barBottomY + titleFade - titleBottomY) / titleFade))
    } else {
      progress = heroProgress
    }
    stickyHeader.alpha = progress
    // round 7f: also drive isHidden from the scroll position, not just alpha.
    // alpha 0 is "transparent but PRESENT" — UIKit composites the titleView during
    // the interactive-pop cross-fade and resets its alpha to 1.0 along the way, so
    // the title surfaced mid- and post-swipe no matter what alpha we wrote (the HUD
    // caught UIKit putting tv back to 1.0 the layout pass after we set it to 0).
    // isHidden removes the view from the render tree entirely whenever it is fully
    // transparent, so at the top there is nothing for UIKit to cross-fade or
    // un-hide: the title is genuinely ABSENT until scroll brings it on. This is the
    // whole header-pop fix — no pop-specific detach / re-attach / alpha juggling.
    stickyHeader.isHidden = progress <= 0
    // Patch 109: fade the bar background in lockstep with the title. Without
    // this UIKit snaps the opaque standardAppearance in the instant the user
    // scrolls (offset > 0), covering the still-visible artwork. The detail VCs
    // keep every appearance slot transparent at rest; here we paint a flat bg
    // whose alpha rides `progress`, so the bar surface and the title arrive
    // together only once the hero has slid under the bar. Reassigning a nav-bar
    // appearance forces a re-render, so skip it outside the fade window where
    // the alpha has already settled at 0 or 1.
    let item = viewController.navigationItem
    let currentBarAlpha = item.standardAppearance?.backgroundColor?.cgColor.alpha ?? 0
    if abs(currentBarAlpha - progress) > 0.01 {
      let barAppearance = UINavigationBarAppearance()
      barAppearance.configureWithTransparentBackground()
      barAppearance.backgroundColor = UIColor.cassette(.surfaceBase).withAlphaComponent(progress)
      barAppearance.shadowColor = UIColor.cassette(.hairline).withAlphaComponent(progress)
      item.standardAppearance = barAppearance
      item.scrollEdgeAppearance = barAppearance
      item.compactAppearance = barAppearance
      item.compactScrollEdgeAppearance = barAppearance
    }
    // Reveal the bar-level play action once the hero's own play CTA has
    // scrolled out from under the bar (midpoint of the hero's fade).
    collapsedPlayItem?.isHidden = heroProgress < 0.5
  }

  /// The record page's big title, in the hero's coordinates, when the hero has one.
  private static func heroTitleBottom(in header: UIView) -> CGFloat? {
    if let generic = header as? GenericDetailTableHeader { return generic.titleBottom }
    for sub in header.subviews {
      if let generic = sub as? GenericDetailTableHeader, let bottom = generic.titleBottom {
        return generic.convert(CGPoint(x: 0, y: bottom), to: header).y
      }
    }
    return nil
  }
}
