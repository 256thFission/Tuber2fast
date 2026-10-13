import Foundation
import TNCore

/// A preset's identity in the theme table.
///
/// Branded rather than a `String`, because the one place a theme is written
/// down is a preference and a display name must not be able to land there.
package struct ThemeID: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String
    package init(rawValue: String) { self.rawValue = rawValue }
}

/// One row of the theme table: an identity that is saved, a name that is
/// shown, and the colours.
package struct ThemePreset: Equatable, Sendable {
    package let id: ThemeID
    package let name: String
    package let theme: Theme

    package init(id: ThemeID, name: String, theme: Theme) {
        self.id = id
        self.name = name
        self.theme = theme
    }
}

/// The tile the ground repeats: a square of `ground` ruled on its top and
/// left edges in `ground2`.
///
/// Every preset shares one. A second kind of tile is a field here when it
/// exists, not before.
package struct GroundTile: Equatable, Sendable {
    /// The side of the square, in points.
    package let size: Double
    /// The rule's width, in points.
    package let lineWidth: Double

    package init(size: Double, lineWidth: Double) {
        self.size = size
        self.lineWidth = lineWidth
    }

    /// The design's grid 34.
    package static let grid = GroundTile(size: 34, lineWidth: 1.5)
}

/// The colours a theme sets, and everything the design derives from them.
///
/// Five hexes, a palette, two percentages, a dark flag and a ground tile
/// are the whole of a theme: nothing else in the editor's chrome carries a
/// colour of its own, bar the red of a save that did not land. Outlines,
/// keycap walls, the grid line, and the seat's body and current row are all
/// computed here, so a new theme is a row of the preset table and never a
/// sweep through the views.
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
    /// Seat toggle, resize grip, dirty dot, and the second kind of button.
    package let secondary: RGBA8
    /// What every outline is mixed toward, and what the chrome's own
    /// lettering is. Not what handwriting is: a stroke keeps the colour
    /// it was drawn in, and no module the ink passes through can name a
    /// theme at all.
    package let ink: RGBA8
    /// The seven colours the brush offers, in the order they are drawn.
    ///
    /// Written down per theme rather than derived from the five above. A
    /// drawing colour has two jobs the chrome's hexes cannot do at once: it
    /// has to be legible on the paper, which is white in every theme, and it
    /// has to be recognisably of this theme's world. The first is always the
    /// theme's darkest, because that is the colour people actually write in.
    package let palette: [RGBA8]
    /// How far a saturated fill travels toward `ink` to become its outline.
    package let outlineMixSaturated: Double
    /// The same for a pale fill, which has further to go to be seen.
    package let outlineMixPale: Double
    /// Mix toward white instead of toward `ink`. Dark mode's one difference.
    package let invertsMix: Bool
    /// What the ground repeats.
    package let groundTile: GroundTile

    package init(
        ground: RGBA8,
        chrome: RGBA8,
        accent: RGBA8,
        secondary: RGBA8,
        ink: RGBA8,
        palette: [RGBA8],
        outlineMixSaturated: Double = 0.42,
        outlineMixPale: Double = 0.55,
        invertsMix: Bool = false,
        groundTile: GroundTile = .grid
    ) {
        self.ground = ground
        self.chrome = chrome
        self.accent = accent
        self.secondary = secondary
        self.ink = ink
        self.palette = palette
        self.outlineMixSaturated = outlineMixSaturated
        self.outlineMixPale = outlineMixPale
        self.invertsMix = invertsMix
        self.groundTile = groundTile
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

    /// The seat's body: the accent most of the way to the paper. After dark
    /// the paper is still white, and a seat mixed toward it would be the
    /// one near-white panel on a dark chrome, so it goes to the ground.
    package var seatBody: RGBA8 { Self.mix(accent, toward: invertsMix ? ground : paper, 0.80) }

    /// The current page's row in the seat: the paper by day. After dark the
    /// seat's lettering has come up toward white and would vanish on the
    /// paper, so the row is the chrome.
    package var seatRow: RGBA8 { invertsMix ? chrome : paper }

    /// A fill's outline, and the colour of the keycap wall under it.
    ///
    /// Two questions, both answered by the same contrast threshold. How far:
    /// a pale fill has to travel further than a saturated one to separate
    /// from its own body. Toward what: a fill that is already the ink's
    /// darkness has nowhere darker to go, so it goes the other way.
    package func outline(of fill: RGBA8) -> RGBA8 {
        Self.mix(fill, toward: mixTarget(of: fill), isPale(fill) ? outlineMixPale : outlineMixSaturated)
    }

    /// A fill's outline where it is drawn over the paper rather than over
    /// the chrome: the lasso's frame, a bookmark on a page.
    ///
    /// By day that is `outline(of:)`. After dark the ordinary outline comes
    /// up toward white, and the paper is still white, so it would vanish on
    /// the very page it marks. Over the paper the dark end is the ground, at
    /// the same percentage. Where the paper escape fires the two agree.
    package func outlineOnPaper(of fill: RGBA8) -> RGBA8 {
        guard invertsMix else { return outline(of: fill) }
        return Self.mix(fill, toward: ground, isPale(fill) ? outlineMixPale : outlineMixSaturated)
    }

    /// The paper escape. A fill the ink cannot be told apart from mixes
    /// toward the paper at the same percentage.
    ///
    /// After dark the escape runs to the ground rather than to the ink,
    /// because a dark theme's ink is a cream: a near-white fill sent toward
    /// it would land on itself and the line would not be there at all. The
    /// ground is the dark end of an inverted theme, which is what the ink is
    /// the rest of the time.
    private func mixTarget(of fill: RGBA8) -> RGBA8 {
        if invertsMix { return Self.contrast(fill, paper) < Self.threshold ? ground : paper }
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
        ink: hex("#141414"),
        // The strawberry and the vanilla are the chrome's own, taken down to
        // where a line of handwriting in them can be read; the rest are the
        // other flavours in the box.
        palette: [
            hex("#141414"), hex("#FF6A8C"), hex("#E9932B"), hex("#3E9B6B"),
            hex("#3B7FD4"), hex("#8A4FBF"), hex("#8C5A2B"),
        ]
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
        // The paper stays white after dark, so the colours that read on it
        // do not change. The day theme's palette is the whole of the answer.
        palette: Theme.macaron.palette,
        invertsMix: true
    )

    /// Every theme this build ships, in the order the design board lays
    /// them out. A theme is a row of this table and nothing more: no view
    /// names one, and adding one is a row.
    package static let presets: [ThemePreset] = [
        ThemePreset(id: ThemeID(rawValue: "macaron"), name: "Macaron", theme: .macaron),
        ThemePreset(id: ThemeID(rawValue: "macaronDark"), name: "Macaron Dark", theme: .macaronDark),
        // A white-grey shell with a neon red and a neon blue on it.
        ThemePreset(id: ThemeID(rawValue: "neon"), name: "Neon", theme: Theme(
            ground: hex("#E7E9EC"),
            chrome: hex("#F2F3F5"),
            accent: hex("#FF3C28"),
            secondary: hex("#0AB9E6"),
            ink: hex("#1B1D21"),
            // The ink, then the red and the blue, then three more neons, and
            // the shell's own grey last.
            palette: [
                hex("#1B1D21"), hex("#FF3C28"), hex("#0AB9E6"), hex("#E0A400"),
                hex("#17A34A"), hex("#8C33C2"), hex("#5A6270"),
            ]
        )),
        // An old handheld's screen: its lightest green is the chrome, a
        // pale wash of it the ground, and its darkest green the ink. The
        // magenta and the purple are the lettering printed around the
        // screen, the only part of the handheld that is not a green or a grey.
        ThemePreset(id: ThemeID(rawValue: "lime"), name: "Lime", theme: Theme(
            ground: hex("#E3EBC4"),
            chrome: hex("#9BBC0F"),
            accent: hex("#B0176B"),
            secondary: hex("#5C2B8A"),
            ink: hex("#0F380F"),
            // The screen's four greens are only three here: the lightest is
            // the chrome's, and the one below it stands for both on the page.
            // The red is the power lamp, and the grey is the lettering on the
            // shell.
            palette: [
                hex("#0F380F"), hex("#306230"), hex("#8BAC0F"), hex("#B0176B"),
                hex("#5C2B8A"), hex("#C1272D"), hex("#4B5A67"),
            ]
        )),
        // Paper and grass: a cream ground, a leaf green, the sky, and an ink
        // that is brown rather than black.
        ThemePreset(id: ThemeID(rawValue: "meadow"), name: "Meadow", theme: Theme(
            ground: hex("#F3EAD6"),
            chrome: hex("#FFFBF0"),
            accent: hex("#8CC63F"),
            secondary: hex("#7EC8E3"),
            ink: hex("#7A6244"),
            // The brown ink leads, since here that is the near-black. The leaf
            // and the sky are the chrome's, deepened: both are pale enough on
            // the chrome to sit behind a page, and neither can be read on one.
            palette: [
                hex("#7A6244"), hex("#5EA226"), hex("#3E9ECF"), hex("#D9A521"),
                hex("#D2527C"), hex("#2E6DA4"), hex("#E1701E"),
            ]
        )),
        // Pink on pink, with the sky for the second colour and a plum for the
        // ink.
        ThemePreset(id: ThemeID(rawValue: "bubblegum"), name: "Bubblegum", theme: Theme(
            ground: hex("#FFE9F1"),
            chrome: hex("#FFFFFF"),
            accent: hex("#FF8AB5"),
            secondary: hex("#7FC8F0"),
            ink: hex("#3A2233"),
            // The plum, then the pink and the sky a shade down from the
            // chrome's, then the reds and the star yellow that pink is always
            // drawn against.
            palette: [
                hex("#3A2233"), hex("#F2669B"), hex("#4FA8DE"), hex("#D6335A"),
                hex("#DBA00A"), hex("#5B4FC2"), hex("#57A65B"),
            ]
        )),
        // Enamel on a grey shell: one orange, a black ink, and a dark grey for
        // the second colour, near enough the black to belong with it and far
        // enough from it to take the plain rule.
        ThemePreset(id: ThemeID(rawValue: "enamel"), name: "Enamel", theme: Theme(
            ground: hex("#D9D9D6"),
            chrome: hex("#EFEFEC"),
            accent: hex("#FF5500"),
            secondary: hex("#6E6E6B"),
            ink: hex("#1A1A1A"),
            // The black, the orange and the grey are the theme's own. The
            // other four are the key colours off the instruments the shell is
            // quoting, which is where its own colour budget goes when it
            // spends any.
            palette: [
                hex("#1A1A1A"), hex("#FF5500"), hex("#6E6E6B"), hex("#0052CC"),
                hex("#1F8A5B"), hex("#E02B20"), hex("#D8A100"),
            ]
        )),
    ]

    /// `nil` for an id this build has no row for, which is how a preference
    /// naming a theme that has been renamed or dropped is refused rather
    /// than guessed at.
    package static func preset(_ id: ThemeID) -> ThemePreset? {
        presets.first { $0.id == id }
    }
}

/// What the app was told to draw in. One value: a theme and a flag saying
/// whether it was chosen are two, and they disagree the moment one is set
/// without the other.
package enum ThemeChoice: Equatable, Codable, Sendable {
    /// Macaron by day and Macaron Dark after dark.
    case system
    /// One preset, whatever the system says the hour is.
    case preset(ThemeID)

    package func resolve(dark: Bool) -> Theme {
        switch self {
        case .system:
            return dark ? .macaronDark : .macaron
        case .preset(let id):
            guard let preset = Theme.preset(id) else {
                // An id that reaches here has already passed the defaults
                // boundary, which is the one place an unknown one is an
                // answer rather than a bug.
                TNPrecondition.fail("a theme choice naming no preset: \(id.rawValue)")
            }
            return preset.theme
        }
    }
}
