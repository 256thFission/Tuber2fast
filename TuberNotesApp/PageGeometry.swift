import Foundation

/// The page of Just a Canvas, in logical page points.
///
/// Page space has its origin at the top-left; positive x points right and
/// positive y points down. These values are display-scale independent.
///
/// Both dimensions are fixed for the life of a document (`DataContract.md` §4).
/// Downward growth was tried and removed: a page that lengthens is not the
/// reading model Phillip wants, and room to keep writing comes from turning to
/// the next page rather than from extending this one.
enum PageGeometry {
    static let width: Double = 612
    static let height: Double = 792

    /// Every document has exactly this geometry, so validation is an equality
    /// check. It stays a function because `CanvasFile` validates loaded bytes,
    /// which can hold anything.
    static func isValidHeight(_ height: Double) -> Bool {
        return height == Self.height
    }
}
