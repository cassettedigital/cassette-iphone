//
//  CassetteTheme.swift
//  AmperfyKit — Cassette Player iOS fork
//
//  Centralised design system for the Cassette reskin. Colors mirror the
//  tokens in `apps/cassette-player-ios/theme/cassette-tokens.md` and the
//  shared web/native palette. Every UI surface that needs a Cassette
//  background, text colour, separator, or accent should pull from here
//  rather than hardcoding hex values.
//
//  Backgrounds are layered (bg < bg2 < bg3, with bg4 as the deepest
//  surface used behind the now-playing artwork). Ink runs from primary
//  text down to the separator/border tint. Orange is the only accent
//  used for primary action; rust is its pressed/active variant.
//
//  `applyGlobalAppearance()` should be called once during app launch.
//  It sets `UIAppearance` proxies for the navigation bar, tab bar, table
//  views, segmented controls, and switches so every UIKit screen inherits
//  the Cassette palette without per-view boilerplate.
//

import SwiftUI
import UIKit

// MARK: - CassetteTheme

public enum CassetteTheme {
  // MARK: Spacing

  public enum Spacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
  }

  // MARK: Radius

  public enum Radius {
    // Resolved from `CassetteRadius`, the one radius vocabulary (Wave 2).
    public static let sm: CGFloat = CassetteRadius.small
    public static let md: CGFloat = CassetteRadius.control
    public static let lg: CGFloat = CassetteRadius.panel
    public static let pill: CGFloat = CassetteRadius.pill
  }

  // MARK: UIKit colours

  /// Each colour follows the screen's appearance (2026-10-31, I-T1): the dark value, else the
  /// shared kit's light paper (`CassetteKitTokens.ColorLight`, the role each name stands for).
  public enum UIColors {
    private typealias D = CassetteKitTokens.Color
    private typealias L = CassetteKitTokens.ColorLight

    public static let bg = UIColor.cassetteFollowing(dark: D.surfaceBase, light: L.surfaceBase)
    public static let bg2 = UIColor.cassetteFollowing(dark: D.surfaceRaised, light: L.surfaceRaised)
    public static let bg3 = UIColor.cassetteFollowing(dark: D.surfaceElevated, light: L.surfaceElevated)
    public static let bg4 = UIColor.cassetteFollowing(dark: D.surfaceSunken, light: L.surfaceSunken)

    public static let ink = UIColor.cassetteFollowing(dark: D.textPrimary, light: L.textPrimary)
    public static let ink2 = UIColor.cassetteFollowing(dark: D.textSecondary, light: L.textSecondary)
    // dark #9C8D70, lifted 2026-10-29 to read 4.6:1 on every dark surface (Q19)
    public static let ink3 = UIColor.cassetteFollowing(dark: D.textTertiary, light: L.textTertiary)
    public static let ink4 = UIColor.cassetteFollowing(dark: D.hairline, light: L.hairline)

    public static let orange = UIColor.cassetteFollowing(dark: D.accentProgress, light: L.accentProgress)
    public static let rust = UIColor.cassetteFollowing(dark: D.danger, light: L.danger)
    public static let sage = UIColor.cassetteFollowing(dark: D.success, light: L.success)
    public static let amber = UIColor.cassetteFollowing(dark: D.warning, light: L.warning)
  }

  // MARK: SwiftUI colours

  public enum Colors {
    public static let bg = Color(UIColors.bg)
    public static let bg2 = Color(UIColors.bg2)
    public static let bg3 = Color(UIColors.bg3)
    public static let bg4 = Color(UIColors.bg4)

    public static let ink = Color(UIColors.ink)
    public static let ink2 = Color(UIColors.ink2)
    public static let ink3 = Color(UIColors.ink3)
    public static let ink4 = Color(UIColors.ink4)

    public static let orange = Color(UIColors.orange)
    public static let rust = Color(UIColors.rust)
    public static let sage = Color(UIColors.sage)
    public static let amber = Color(UIColors.amber)
  }

  // MARK: Global UIAppearance

  /// One-time configuration of UIAppearance proxies. Call from
  /// `application(_:didFinishLaunchingWithOptions:)` before any view
  /// hierarchy is constructed.
  public static func applyGlobalAppearance() {
    let nav = UINavigationBarAppearance()
    nav.configureWithOpaqueBackground()
    nav.backgroundColor = .cassette(.surfaceBase)
    nav.shadowColor = .cassette(.hairline)
    nav.titleTextAttributes = [
      .font: UIFont.cassette(.navTitle),
      .foregroundColor: UIColor.cassette(.textPrimary),
    ]
    nav.largeTitleTextAttributes = [
      .font: UIFont.cassette(.largeTitle),
      .foregroundColor: UIColor.cassette(.textPrimary),
    ]
    // cassette Patch 046 (Phase A): back button title drops to ink2 (was orange).
    // The chevron itself follows the global nav tintColor, also moved to ink.
    let backItem = UIBarButtonItemAppearance()
    backItem.normal.titleTextAttributes = [
      .foregroundColor: UIColor.cassette(.textSecondary),
      .font: UIFont.cassette(.rowTitle),
    ]
    nav.buttonAppearance = backItem
    nav.backButtonAppearance = backItem

    UINavigationBar.appearance().standardAppearance = nav
    UINavigationBar.appearance().scrollEdgeAppearance = nav
    UINavigationBar.appearance().compactAppearance = nav
    UINavigationBar.appearance().tintColor = .cassette(.textPrimary)

    // cassette Patch 046 (Phase A): tab bar selected icon + label drop to ink
    // (was orange). Differentiation between selected/unselected is now ink
    // (selected) vs ink3 (unselected) plus the existing bold/semibold label
    // weight contrast at lines below. Phase H will layer filled-vs-outline
    // icon swapping on top for the final structural cue.
    let tab = UITabBarAppearance()
    tab.configureWithOpaqueBackground()
    tab.backgroundColor = .cassette(.surfaceRaised)
    tab.shadowColor = .cassette(.hairline)
    let tabItem = UITabBarItemAppearance()
    tabItem.normal.iconColor = .cassette(.textTertiary)
    tabItem.normal.titleTextAttributes = [
      .foregroundColor: UIColor.cassette(.textTertiary),
      .font: UIFont.cassette(.tabLabel),
    ]
    tabItem.selected.iconColor = .cassette(.textPrimary)
    tabItem.selected.titleTextAttributes = [
      .foregroundColor: UIColor.cassette(.textPrimary),
      .font: UIFont.cassette(.tabLabelSelected),
    ]
    tab.stackedLayoutAppearance = tabItem
    tab.inlineLayoutAppearance = tabItem
    tab.compactInlineLayoutAppearance = tabItem
    UITabBar.appearance().standardAppearance = tab
    UITabBar.appearance().scrollEdgeAppearance = tab
    UITabBar.appearance().tintColor = .cassette(.textPrimary)
    UITabBar.appearance().unselectedItemTintColor = .cassette(.textTertiary)

    UITableView.appearance().backgroundColor = .cassette(.surfaceBase)
    UITableView.appearance().separatorColor = .cassette(.hairline)
    // cassette 2026-10-13 (founder): no row separators anywhere on the phone.
    // The library lists, track lists and the dial all draw rows against bg
    // with their own spacing; the hairlines read as clutter on the device.
    UITableView.appearance().separatorStyle = .none
    UITableView.appearance().sectionIndexColor = .cassette(.textSecondary)

    UICollectionView.appearance().backgroundColor = .cassette(.surfaceBase)

    // cassette Patch 050 (Phase E): switches + segmented controls move from
    // orange to ink. UISwitch ON state reads as the warm off-white pill;
    // segmented control selected segment is ink-filled with bg-tinted text
    // (the existing typography attrs already use bg for selected labels,
    // which now reads correctly on the ink fill).
    UISwitch.appearance().onTintColor = .cassette(.fillSelected)

    let segmentNormal: [NSAttributedString.Key: Any] = [
      .foregroundColor: UIColor.cassette(.textSecondary),
      .font: UIFont.cassette(.metadata),
    ]
    let segmentSelected: [NSAttributedString.Key: Any] = [
      .foregroundColor: UIColor.cassette(.textOnFill),
      .font: UIFont.cassette(.metadata),
    ]
    UISegmentedControl.appearance().setTitleTextAttributes(segmentNormal, for: .normal)
    UISegmentedControl.appearance().setTitleTextAttributes(segmentSelected, for: .selected)
    UISegmentedControl.appearance().selectedSegmentTintColor = .cassette(.fillSelected)
    UISegmentedControl.appearance().backgroundColor = .cassette(.surfaceRaised)

    // cassette Patch 046 (Phase A): toolbar + search bar tint drop to ink/ink2.
    // The orange cursor + ring on search bars was loud and competed with the
    // mini-player scrubber visible at the bottom of the same screen.
    UIToolbar.appearance().barTintColor = .cassette(.surfaceRaised)
    UIToolbar.appearance().tintColor = .cassette(.textPrimary)

    UISearchBar.appearance().tintColor = .cassette(.textSecondary)
    UISearchBar.appearance().barTintColor = .cassette(.surfaceRaised)

    // cassette Patch 048 (Phase C): pull-to-refresh spinner inherits the
    // global tintColor in iOS 26, which is now ink. Pin to ink2 explicitly
    // so it reads as a quiet secondary affordance rather than competing
    // with primary content.
    UIRefreshControl.appearance().tintColor = .cassette(.textSecondary)
  }
}

// MARK: - UIColor hex helper

@MainActor
extension UIView {
  /// Runs `update` now and whenever light or dark changes, with this view's traits as the
  /// current ones, so a layer colour (a CGColor, which doesn't follow by itself) taken from a
  /// colour that follows the appearance stays right (I-T1).
  public func cassetteOnAppearanceChange(_ update: @escaping @MainActor (UIView) -> ()) {
    traitCollection.performAsCurrent { update(self) }
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: UIView, _: UITraitCollection) in
      view.traitCollection.performAsCurrent { update(view) }
    }
  }
}

extension UIColor {
  /// Convenience initializer for the Cassette palette. Hex literal in
  /// the form `0xRRGGBB`. Always opaque.
  public static func cassetteHex(_ value: UInt32) -> UIColor {
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: 1.0)
  }
}
