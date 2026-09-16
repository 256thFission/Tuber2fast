import Foundation
import TNCore

/// The six colours a theme sets, and everything the design derives from them.
///
/// Six hexes and two percentages is the whole of a theme: nothing else in the
/// editor's chrome carries a colour of its own. Outlines, keycap walls, the
/// grid line, and the seat's body are all computed here, so a new theme is a
/// row of hexes and never a sweep through the views.
///
/// No UIKit and no SwiftUI: this is a durable value, and the bridges to
/// `UIColor` and `Color` live with the views that need them.
package struct Theme: Equatable, Sendable {
    /// The wallpaper behind the page.
    package let ground: RGBA8
    /// One fill for the band, the writing bar, the chips and the readouts.
    package let chrome: RGBA8
    /// Held tool, active tab, seat title strip, lasso, page margin.
    package let accent: RGBA8
    /// Seat toggle, resize grip, dirty dot, rule lines, highlighter.
    package let secondary: RGBA8
    /// What handwriting is, and what every outline is mixed toward.
    package let ink: RGBA8
    /// How far a saturated fill travels toward `ink` to become its outline.
    package let outlineMixSaturated: Double
    /// The same for a pale fill, which has further to go to be seen.
    package let outlineMixPale: Double
    /// Mix toward white instead of toward `ink`. Dark mode's one difference.
    package let invertsMix: Bool

    package init(
        ground: RGBA8,
        chrome: RGBA8,
        accent: RGBA8,
        secondary: RGBA8,
        ink: RGBA8,
        outlineMixSaturated: Double = 0.42,
        outlineMixPale: Double = 0.55,
        invertsMix: Bool = false
    ) {
        self.ground = ground
        self.chrome = chrome
        self.accent = accent
        self.secondary = secondary
        self.ink = ink
        self.outlineMixSaturated = outlineMixSaturated
        self.outlineMixPale = outlineMixPale
        self.invertsMix = invertsMix
    }

    // MARK: Derived

    /// `chrome` at full lightness. White, since HSL lightness 1 is white
    /// whatever the hue was, which is what the design asserts of every
    /// shipped theme.
    package var paper: RGBA8 { RGBA8(red: 255, green: 255, blue: 255, alpha: 0xFF) }

    /// The grid line, and the second colour of every ground pattern.
    ///
    /// Eight percent is the distance at which the default ground's line
    /// carries the same contrast against its ground as the hex the design's
    /// own table names, which is the only number the document gives for it.
    package var ground2: RGBA8 { Self.mix(ground, toward: mixTarget(of: ground), 0.08) }

    /// The seat's body: the accent most of the way to the paper.
    package var seatBody: RGBA8 { Self.mix(accent, toward: paper, 0.80) }

    /// A fill's outline, and the colour of the keycap wall under it.
    ///
    /// Two questions, both answered by the same contrast threshold. How far:
    /// a pale fill has to travel further than a saturated one to separate
    /// from its own body. Toward what: a fill that is already the ink's
    /// darkness has nowhere darker to go, so it goes the other way.
    package func outline(of fill: RGBA8) -> RGBA8 {
        Self.mix(fill, toward: mixTarget(of: fill), isPale(fill) ? outlineMixPale : outlineMixSaturated)
    }

    /// The paper escape. A fill the ink cannot be told apart from mixes
    /// toward the paper at the same percentage.
    private func mixTarget(of fill: RGBA8) -> RGBA8 {
        if invertsMix { return Self.contrast(fill, paper) < Self.threshold ? ink : paper }
        return Self.contrast(fill, ink) < Self.threshold ? paper : ink
    }

    /// Pale means the paper can barely be told from it. The same threshold
    /// the escape uses, read from the other end.
    package func isPale(_ fill: RGBA8) -> Bool {
        Self.contrast(fill, invertsMix ? ink : paper) < Self.threshold
    }

    /// The one number both questions turn on.
    package static let threshold = 1.6

    // MARK: Colour arithmetic

    /// Straight sRGB interpolation, which is what "moved toward" means
    /// everywhere in this design.
    package static func mix(_ from: RGBA8, toward: RGBA8, _ amount: Double) -> RGBA8 {
        func channel(_ a: UInt8, _ b: UInt8) -> UInt8 {
            let value = Double(a) + amount * (Double(b) - Double(a))
            return UInt8(min(255, max(0, value.rounded())))
        }
        return RGBA8(
            red: channel(from.red, toward.red),
            green: channel(from.green, toward.green),
            blue: channel(from.blue, toward.blue),
            alpha: from.alpha
        )
    }

    /// WCAG relative luminance.
    package static func luminance(_ color: RGBA8) -> Double {
        func linear(_ byte: UInt8) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    package static func contrast(_ a: RGBA8, _ b: RGBA8) -> Double {
        let (first, second) = (luminance(a), luminance(b))
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    // MARK: Themes

    private static func hex(_ value: String) -> RGBA8 {
        guard let parsed = RGBA8(hex: value + "FF") else {
            TNPrecondition.fail("a theme colour that is not a colour: \(value)")
        }
        return parsed
    }

    package static let macaron = Theme(
        ground: hex("#F4EADA"),
        chrome: hex("#FFFFFF"),
        accent: hex("#FF6A8C"),
        secondary: hex("#FFB347"),
        ink: hex("#141414")
    )

    /// Joy-Con neon red and neon blue over the console's own greys. The
    /// hexes are the shell colours the hardware stores for itself, not the
    /// louder pair the box art uses.
    package static let switchConsole = Theme(
        ground: hex("#414548"),
        chrome: hex("#828282"),
        accent: hex("#FF3C28"),
        secondary: hex("#0AB9E6"),
        ink: hex("#0F0F0F")
    )

    /// The DMG's four greens and its shell. The four are a two-band palette
    /// rather than a four-step ramp — the two light greens are 1.2 to 1 on
    /// each other, and so are the two dark ones — so chrome and secondary
    /// take one from each band and the accent carries the dark one.
    package static let gameBoy = Theme(
        ground: hex("#C2C0BC"),
        chrome: hex("#9BBC0F"),
        accent: hex("#306230"),
        secondary: hex("#8BAC0F"),
        ink: hex("#0F380F")
    )

    /// The same theme after dark: the cream and the ink trade places and
    /// the mix target inverts, so an outline now comes up off its fill
    /// instead of going down into it. The paper stays white.
    package static let macaronDark = Theme(
        ground: hex("#26211B"),
        chrome: hex("#332C24"),
        accent: hex("#FF6A8C"),
        secondary: hex("#FFB347"),
        ink: hex("#F4EADA"),
        invertsMix: true
    )

    package static let all: [(name: String, theme: Theme)] = [
        ("Macaron", .macaron), ("Macaron Dark", .macaronDark),
        ("Switch", .switchConsole), ("Game Boy", .gameBoy),
    ]

    /// The second notebook's tab colour in the mocks. A per-notebook preset,
    /// not a theme token, so it lives beside the themes rather than in one.
    package static let pistachio = hex("#DFF3C8")

    /// The theme the whole app draws in. One value, read wherever chrome is
    /// drawn; set once, at the top.
    @MainActor package static var current: Theme = .macaron

    /// Posted when `current` changes, so the UIKit half repaints.
    @MainActor package static let changed = Notification.Name("TNThemeChanged")
}
