// DesignTokens.swift
// Aski IQ — Centralised spacing / radius / semantic colour tokens.
//
// WHY THIS FILE EXISTS
// The 2026-04-28 audit (§29) flagged the design system as fragmented:
//   - .padding(.horizontal, 16) used 123 times as a raw literal
//   - cornerRadius(10/12/14) coexisted across the app
//   - Brand teal hardcoded as Color(red:0,green:0.702,blue:0.651) in LoginView
// This file establishes a single source of truth. New code should reach for
// AskiSpacing/AskiRadius/AskiColor instead of literal values, and existing
// screens can be retrofitted incrementally during their next touch.
//
// USAGE
//   .padding(.horizontal, AskiSpacing.lg)
//   .cornerRadius(AskiRadius.card)
//   .foregroundColor(AskiColor.brandAccent)
//
// Adding a new value? Add it here first. If it's only used once, prefer
// the inline literal — tokens are for repeated values.

import SwiftUI

// MARK: - Spacing
//
// 4-pt baseline grid — covers everything the app currently uses without
// proliferating sizes. Most screens should compose .xs through .xl; .xxl/.xxxl
// are reserved for hero banners and sectional padding.

enum AskiSpacing {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16    // most common .padding value in the app
    static let xl:  CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

// MARK: - Corner Radius
//
// Three sizes cover everything: chip (small pill), card (most surfaces),
// hero (large modal sheet header). Buttons follow Apple's adaptive metric
// so they aren't included here.

enum AskiRadius {
    static let chip:  CGFloat = 6
    static let card:  CGFloat = 12   // matches SharedComponents.swift cards
    static let hero:  CGFloat = 16   // login card / settings hero
}

// MARK: - Semantic Colors
//
// All colours used by the app should resolve through this enum. Each token
// adapts to dark mode automatically — either by referencing a system color
// or by composing one with `Color(light:dark:)` below. Avoid raw `Color(red:..)`
// literals in new code.

enum AskiColor {

    // MARK: Brand
    /// Aski IQ teal — the only fixed brand colour. Light/dark tone slightly
    /// shifted in dark mode for sufficient contrast against #1c1c1e.
    static let brandAccent = Color(
        light: Color(red: 0,   green: 0.702, blue: 0.651),  // #00B3A6
        dark:  Color(red: 0.2, green: 0.85,  blue: 0.79)    // brighter in dark
    )

    // MARK: Surfaces
    static let surface          = Color(.systemBackground)
    static let surfaceElevated  = Color(.secondarySystemBackground)
    static let surfaceTertiary  = Color(.tertiarySystemBackground)
    static let groupedBackground = Color(.systemGroupedBackground)
    static let separator        = Color(.separator)

    // MARK: Text
    static let textPrimary   = Color.primary
    static let textSecondary = Color.secondary
    static let textInverse   = Color.white

    // MARK: Status — sourced from SharedComponents.StatusBadge to keep parity
    static let statusActive   = Color.green
    static let statusPending  = Color.blue
    static let statusWarning  = Color.orange
    static let statusError    = Color.red
    static let statusInactive = Color.secondary

    // MARK: Money
    /// Used by financial widgets / dashboards. Same as statusActive but named
    /// for the use-case so a future redesign can shift one without the other.
    static let moneyPositive = Color.green
    static let moneyNegative = Color.red
    static let moneyNeutral  = Color.secondary
}

// MARK: - Light/Dark adaptive Color helper
//
// SwiftUI on iOS 14+ ships an asset catalog–based mechanism for adaptive
// colours, but defining one inline is sometimes useful when iterating. Use
// sparingly — prefer Asset Catalog colours for anything that needs the design
// team's attention.

extension Color {
    init(light: Color, dark: Color) {
        self = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }
}
