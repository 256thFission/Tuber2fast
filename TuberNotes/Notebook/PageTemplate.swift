import CoreGraphics
import Foundation

/// Paper style for a page: plain, lined, grid, or dotted — each ruled/dotted
/// style in three sizes.
enum PageTemplate: String, Codable, CaseIterable, Identifiable {
    case plain
    case linedLarge, linedMedium, linedSmall
    case gridLarge, gridMedium, gridSmall
    case dottedLarge, dottedMedium, dottedSmall

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain:        "Plain"
        case .linedLarge:   "Lined · Large"
        case .linedMedium:  "Lined · Medium"
        case .linedSmall:   "Lined · Small"
        case .gridLarge:    "Grid · Large"
        case .gridMedium:   "Grid · Medium"
        case .gridSmall:    "Grid · Small"
        case .dottedLarge:  "Dotted · Large"
        case .dottedMedium: "Dotted · Medium"
        case .dottedSmall:  "Dotted · Small"
        }
    }

    var isLined: Bool { self == .linedLarge || self == .linedMedium || self == .linedSmall }
    var isGrid: Bool { self == .gridLarge || self == .gridMedium || self == .gridSmall }
    var isDotted: Bool { self == .dottedLarge || self == .dottedMedium || self == .dottedSmall }

    var spacing: CGFloat {
        switch self {
        case .plain:                                    0
        case .linedLarge, .gridLarge, .dottedLarge:     44
        case .linedMedium, .gridMedium, .dottedMedium:  32
        case .linedSmall, .gridSmall, .dottedSmall:     22
        }
    }

    var systemImage: String {
        if isDotted { return "circle.grid.3x3" }
        if isGrid { return "square.grid.3x3" }
        if isLined { return "text.justify" }
        return "rectangle"
    }
}
