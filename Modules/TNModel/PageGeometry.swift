import Foundation

/// One page's extent in page points. Origin top-left, x right, y down.
/// Chosen when the page is created, and changed only by asset paper on an
/// empty page.
package struct PageGeometry: Codable, Sendable, Equatable {
    package let width: Double
    package let height: Double

    package init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// US Letter. What a page created without a source gets when there is no
    /// current page to copy.
    package static let letter = PageGeometry(width: 612, height: 792)

    /// A page `width` wide in an asset's shape, `aspect` being its height
    /// over its width: asset paper fills the page rectangle, so the
    /// rectangle is the asset's shape.
    package static func fitting(width: Double, aspect: Double) -> PageGeometry {
        PageGeometry(width: width, height: width * aspect)
    }

    package var isWithinBounds: Bool {
        PageBounds.contains(width) && PageBounds.contains(height)
    }
}

/// The bounds every page edge must satisfy. Both carry their derivation.
package enum PageBounds {
    /// The smallest page fit-width can open under the zoom cap on the widest
    /// supported viewport: `1376 × 0.05 × 2 = 137.6`. Below it the page's
    /// fit-width scale exceeds the ceiling the runtime can deliver.
    package static let minEdge: Double = ZoomCap.widestSupportedViewportPoints
        * ZoomCap.pagePointsPerPixel * ZoomCap.minimumDisplayScale

    /// Chosen so a pixel-capped composite is still legible at fit-width.
    /// Needs device evidence; the one constant here expected to move.
    package static let maxEdge: Double = 4096

    /// The bounds as a person reads them. `%g` rather than interpolation:
    /// `minEdge` is derived and prints its binary tail as
    /// `137.60000000000002`.
    package static let description = String(format: "%g to %g", minEdge, maxEdge)

    package static func contains(_ edge: Double) -> Bool {
        edge.isFinite && edge >= minEdge && edge <= maxEdge
    }
}

/// The zoom cap is a code constant (D12), pinned to PencilKit's silent
/// clamp of `maximumZoomScale` at 10 on a 2x display: 1/(10 × 2) = 0.05
/// page points per pixel, twenty pixels per page point at the deepest zoom.
package enum ZoomCap {
    package static let pagePointsPerPixel: Double = 0.05
    /// `PKCanvasView` refuses a `maximumZoomScale` above 10, silently.
    /// Measured; the runtime traps on the read-back rather than accept less.
    package static let runtimeMaximumZoomScale: Double = 10
    package static let minimumDisplayScale: Double = 2
    /// The long edge of the 13-inch iPad Pro, the widest viewport a page is
    /// fitted into.
    package static let widestSupportedViewportPoints: Double = 1376

    package static func maximumZoomScale(displayScale: Double) -> Double {
        1 / (pagePointsPerPixel * displayScale)
    }
}
