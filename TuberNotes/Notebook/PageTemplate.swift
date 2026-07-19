import CoreGraphics
import Foundation

/// Paper style for a page: plain, lined, or grid — each ruled style in 3 sizes.
enum PageTemplate: String, Codable, CaseIterable, Identifiable {
    case plain
    case linedLarge, linedMedium, linedSmall
    case gridLarge, gridMedium, gridSmall

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
        }
    }

    var isLined: Bool { self == .linedLarge || self == .linedMedium || self == .linedSmall }
    var isGrid: Bool { self == .gridLarge || self == .gridMedium || self == .gridSmall }

    var spacing: CGFloat {
        switch self {
        case .plain:                     0
        case .linedLarge, .gridLarge:    44
        case .linedMedium, .gridMedium:  32
        case .linedSmall, .gridSmall:    22
        }
    }

    var systemImage: String {
        if isGrid { return "square.grid.3x3" }
        if isLined { return "text.justify" }
        return "rectangle"
    }
}
