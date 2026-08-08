import SwiftUI
import TuberStore

/// SwiftUI's implicit `DeveloperToolsSupport` import ships its own
/// `LibraryItem` (the previews library), which collides with the store's.
/// One module-level alias settles the lookup for every file in this target:
/// in this app, a `LibraryItem` is a row of the notebook library.
typealias LibraryItem = TuberStore.LibraryItem

/// The browser's shared visual vocabulary, eyeballed from `images/01`–`06`
/// (dark mode): the paper cover, the folder tints, the swatch palette, and
/// the one date format every cell uses.
@MainActor
enum LibraryStyle {
    /// The cream 'paper' of a document cover — the canonical page's color.
    static let paper = Color(red: 0.973, green: 0.965, blue: 0.925)
    /// The page-stack edge behind the cover's trailing side.
    static let paperEdge = Color(red: 0.85, green: 0.84, blue: 0.79)
    /// The default folder blue, rendered when `FolderDecoration.color` is nil.
    static let defaultFolderHex = "#5B9BF8"

    /// 26 swatches in the observed 9×3 layout; the 27th slot is the custom
    /// wheel. Row one is the "9 primary dots" the folder popover shows.
    static let paletteRows: [[String]] = [
        [
            "#B33A30", "#B4641E", "#B8860B", "#2E7D32", "#1E5CB3",
            "#6A3AB2", "#A83279", "#6E6E6E", "#3A3A3C",
        ],
        [
            "#E74C3C", "#F5A623", "#F7D51D", "#4CD964", "#5B9BF8",
            "#B57BEE", "#F06EAA", "#AEAEB2", "#FFFFFF",
        ],
        [
            "#F5A8A8", "#F8C99B", "#F7EC9E", "#B5EFA5", "#BFDFFC",
            "#DCC8F5", "#F8C8DE", "#E8E6E1",
        ],
    ]

    /// The primary dots row for the folder chevron popover: the vivid row,
    /// which carries the default blue.
    static var primaryDots: [String] { paletteRows[1] }

    /// The Icon tab's glyph set. GoodNotes' own set is unobserved
    /// (`02-proposal.md` fidelity commitments) — these 21 are our pick,
    /// flagged as such.
    static let folderGlyphs: [String] = [
        "star.fill", "heart.fill", "book.fill", "graduationcap.fill", "pencil",
        "briefcase.fill", "house.fill", "airplane", "car.fill", "leaf.fill",
        "flame.fill", "bolt.fill", "music.note", "camera.fill", "gamecontroller.fill",
        "globe.americas.fill", "lightbulb.fill", "gift.fill", "flag.fill",
        "paintbrush.fill", "wrench.and.screwdriver.fill",
    ]

    /// Absolute always, `MMM d, yyyy 'at' h:mm a` — every first-party cell
    /// uses it, even old ones; relative forms are not built (UX-3).
    static let itemDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter
    }()

    /// The color a folder renders: its decoration's hex, or the default blue.
    static func folderColor(_ decoration: FolderDecoration) -> Color {
        color(fromHex: decoration.color ?? defaultFolderHex)
    }

    /// `#RRGGBB` → Color; an unparseable value renders the default blue
    /// rather than black, because a decoration is never worth a wrong-looking
    /// refusal — the store already surfaced the corrupt sidecar.
    static func color(fromHex hex: String) -> Color {
        var value: UInt64 = 0
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6, Scanner(string: trimmed).scanHexInt64(&value) else {
            return color(fromHex: defaultFolderHex)
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Color → `#RRGGBB`, for the custom wheel writing into `FolderDecoration`.
    static func hex(from color: Color) -> String {
        let resolved = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ component: CGFloat) -> Int { Int((max(0, min(1, component)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
