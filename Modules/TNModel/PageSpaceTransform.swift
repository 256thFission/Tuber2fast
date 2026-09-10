import Foundation

/// A page-space affine transform as its six coefficients. Maps a layer's
/// source unit square into page space.
package struct PageSpaceTransform: Codable, Sendable, Equatable {
    package let a: Double
    package let b: Double
    package let c: Double
    package let d: Double
    package let tx: Double
    package let ty: Double

    package init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    package static let identity = PageSpaceTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    package var isIdentity: Bool { self == .identity }
    package var determinant: Double { a * d - b * c }

    /// The validity rule the format states: finite, `|det| > 1e-9`, and a
    /// translation no further than ten page widths off the page.
    package static let minimumDeterminant: Double = 1e-9
    package static let maximumTranslation: Double = 10 * PageBounds.maxEdge

    package var isValid: Bool {
        [a, b, c, d, tx, ty].allSatisfy(\.isFinite)
            && abs(determinant) > Self.minimumDeterminant
            && abs(tx) <= Self.maximumTranslation
            && abs(ty) <= Self.maximumTranslation
    }

    package func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }

    package var inverted: PageSpaceTransform? {
        let det = determinant
        guard det.isFinite, abs(det) > Self.minimumDeterminant else { return nil }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return PageSpaceTransform(
            a: ia, b: ib, c: ic, d: id,
            tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty)
        )
    }

    package func concatenating(_ later: PageSpaceTransform) -> PageSpaceTransform {
        PageSpaceTransform(
            a: a * later.a + b * later.c,
            b: a * later.b + b * later.d,
            c: c * later.a + d * later.c,
            d: c * later.b + d * later.d,
            tx: tx * later.a + ty * later.c + later.tx,
            ty: tx * later.b + ty * later.d + later.ty
        )
    }

    /// The transform that places a source of `sourceWidth × sourceHeight`
    /// at `origin` scaled uniformly by `scale`, mapping the unit square.
    package static func placing(
        sourceWidth: Double, sourceHeight: Double,
        at origin: (x: Double, y: Double), scale: Double
    ) -> PageSpaceTransform {
        PageSpaceTransform(
            a: sourceWidth * scale, b: 0, c: 0, d: sourceHeight * scale,
            tx: origin.x, ty: origin.y
        )
    }

    /// The array form the format writes: `[a, b, c, d, tx, ty]`.
    package init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        a = try container.decode(Double.self)
        b = try container.decode(Double.self)
        c = try container.decode(Double.self)
        d = try container.decode(Double.self)
        tx = try container.decode(Double.self)
        ty = try container.decode(Double.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "transform has more than six coefficients"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in [a, b, c, d, tx, ty] { try container.encode(value) }
    }
}
