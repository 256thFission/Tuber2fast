import Foundation

/// The page of Just a Canvas, in logical page points.
///
/// Page space has its origin at the top-left; positive x points right and
/// positive y points down. These values are display-scale independent.
///
/// Width is fixed for the life of a document. Height grows only, one increment
/// at a time, up to a bounded maximum (`DataContract.md` §4, §5a). The bound
/// exists because every save rewrites the whole file: unbounded height would
/// reintroduce the cost that infinite canvas was rejected for.
enum PageGeometry {
    static let width: Double = 612

    /// The height every document starts at, and the amount each extension adds.
    static let initialHeight: Double = 792

    /// Sixteen initial page heights. A bound, not a measurement — G4's baseline
    /// revises it from save-cost-versus-height evidence.
    static let maximumExtents = 16

    static var maximumHeight: Double { initialHeight * Double(maximumExtents) }

    /// Heights a document may legitimately have: within range and a whole
    /// number of extents, because extension only ever adds one whole increment.
    static func isValidHeight(_ height: Double) -> Bool {
        guard height.isFinite, height >= initialHeight, height <= maximumHeight else {
            return false
        }
        let extents = (height / initialHeight).rounded()
        return abs(extents * initialHeight - height) < 0.000_001
    }

    /// The next height up, or `nil` at the maximum. Returning `nil` rather than
    /// clamping is what lets the caller refuse an extension and change nothing.
    static func extended(from height: Double) -> Double? {
        let next = height + initialHeight
        guard next <= maximumHeight else { return nil }
        return next
    }
}
