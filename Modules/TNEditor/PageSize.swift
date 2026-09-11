import Foundation
import TNModel

package enum PageOrientation: Sendable, Hashable, CaseIterable { case portrait, landscape }

/// The sizes a creation sheet offers, stated portrait, in points (PDF
/// convention). A creation aid, not durable: a page carries its
/// `PageGeometry`, and the catalogue name is derivable from the two numbers.
/// No display names here; the app owns those.
package enum PageSize: Sendable, Hashable {
    case letter      // 612 x 792
    case a4          // 595 x 842
    case a5          // 420 x 595
    /// Both edges are constants, not a screen read, so the catalogue does
    /// not differ per device: 1376 is `ZoomCap.widestSupportedViewportPoints`
    /// and 1032 is the 13-inch iPad Pro's other edge.
    case iPadPro13   // 1032 x 1376
    case square      // 612 x 612
    case custom(width: Double, height: Double)

    package static let named: [PageSize] = [.letter, .a4, .a5, .iPadPro13, .square]

    /// nil when an edge is outside `PageBounds`. Named sizes never are.
    package func geometry(_ orientation: PageOrientation) -> PageGeometry? {
        let stated: PageGeometry
        switch self {
        // Taken exactly as typed and never transposed: whoever typed 800 by
        // 600 has already stated the orientation.
        case .custom(let width, let height): stated = PageGeometry(width: width, height: height)
        case .letter: stated = Self.turned(.letter, orientation)
        case .a4: stated = Self.turned(PageGeometry(width: 595, height: 842), orientation)
        case .a5: stated = Self.turned(PageGeometry(width: 420, height: 595), orientation)
        case .iPadPro13: stated = Self.turned(PageGeometry(width: 1032, height: 1376), orientation)
        case .square: stated = Self.turned(PageGeometry(width: 612, height: 612), orientation)
        }
        return stated.isWithinBounds ? stated : nil
    }

    /// What a page of this shape would be chosen as, so a sheet can open on
    /// the size the page already is. A shape no named size states is custom,
    /// and a custom size is stated as typed, which is portrait by convention.
    package static func matching(_ geometry: PageGeometry) -> (size: PageSize, orientation: PageOrientation) {
        for named in named {
            for orientation in PageOrientation.allCases where named.geometry(orientation) == geometry {
                return (named, orientation)
            }
        }
        return (.custom(width: geometry.width, height: geometry.height), .portrait)
    }

    /// The named sizes are stated portrait, so landscape is the transpose.
    private static func turned(_ geometry: PageGeometry, _ orientation: PageOrientation) -> PageGeometry {
        switch orientation {
        case .portrait: geometry
        case .landscape: PageGeometry(width: geometry.height, height: geometry.width)
        }
    }
}
