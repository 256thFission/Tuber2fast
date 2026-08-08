import Foundation
import PencilKit

/// Which idealized shape a Pencil drag commits.
///
/// There is no `shape` layer kind and no vector payload behind this: a shape is
/// ink, snapped. `Docs/Forks/CanvasFeatureComplete.md` — "Shapes are snapped
/// ink" — decided it that way so the eraser, the lasso, stroke undo, the save
/// path, and the renderer all apply to a shape without a single new seam.
package enum ShapeKind: String, CaseIterable, Sendable, Identifiable {
    case line
    case rectangle
    case ellipse

    package var id: String { rawValue }
}

/// Turns a drag and the pen in hand into finished strokes.
///
/// Pure, static, and free of any canvas: geometry in page points and a
/// `PKInkingTool` go in, `PKStroke`s come out. That is deliberate and it is the
/// only reason any of this is testable — the simulator has no Apple Pencil, so
/// the gesture cannot be exercised by CI, but the synthesis it feeds can be
/// exercised exactly.
///
/// Everything here is in **page space** (`Contract.md` — Geometry and
/// coordinates). The caller converts; this file never sees a view, a zoom
/// scale, or a content offset.
enum ShapeSynthesis {
    // MARK: - Sampling constants
    //
    // These are the "sane constants that yield uniform, clean lines" the shape
    // tool needs. Each is stated with what it buys, because a shape drawn with
    // the pen has to read as the pen and not as clip art.

    /// Page points between adjacent control points.
    ///
    /// A `PKStrokePath` fits a spline *near* its control points rather than
    /// through them — see below — so a curve is only as round as it is sampled,
    /// and density is what buys back the difference. Two points is roughly a real
    /// Pencil's sample spacing at writing speed, cheap enough that a full-page
    /// ellipse is a few hundred points — the size of an ordinary handwritten
    /// stroke, not of a vector import.
    static let sampleSpacing: CGFloat = 2

    /// The nominal drawing speed, page points per second, used to fill in each
    /// point's `timeOffset`.
    ///
    /// Constant by construction: the timestamps describe a pen moving at one
    /// unvarying speed, because a snapped shape has no hesitation in it. Inks
    /// that read velocity therefore see a uniform line rather than the taper
    /// they would give a real hand.
    static let nominalSpeed: CGFloat = 500

    /// The smallest time between two control points, seconds.
    ///
    /// A closed shape repeats its first location as its last, and two points
    /// sharing one `timeOffset` is a degenerate path. Strictly increasing time
    /// costs nothing and removes the question.
    static let minimumTimeStep: TimeInterval = 1e-4

    // MARK: - Stroke point parameters
    //
    // A Pencil reports force, azimuth, and altitude per sample; a synthesized
    // shape has to state them. These are the values that mean "held upright,
    // pressed evenly, moving steadily" — the hand nobody has.

    /// Full, unvarying pressure. Pressure variation is exactly the character a
    /// snapped shape must not have.
    static let force: CGFloat = 1

    /// Fully opaque. The tool's colour already carries its own alpha.
    static let opacity: CGFloat = 1

    /// Straight up from the page. Directional inks (the pencil, the reed) shade
    /// by altitude, and a shape shaded as though drawn at a slant would change
    /// weight around a rectangle's four sides.
    static let altitude: CGFloat = .pi / 2

    /// A meaningless bearing for a perpendicular stylus, and stated rather than
    /// left to a default so it is one value on every edge of a rectangle.
    static let azimuth: CGFloat = 0

    // MARK: - Synthesis

    /// The strokes a drag from `start` to `end` commits.
    ///
    /// A rectangle is **four strokes**, not one closed path, per the fork doc.
    /// The reason is the eraser: a stroke is the unit PencilKit's vector eraser
    /// removes, so four strokes let a user rub out one side of a box and keep
    /// the other three, exactly as they could had they drawn it by hand. One
    /// closed path would be all-or-nothing. The ellipse is one stroke because
    /// it has no sides to lose — its unit and its shape are the same thing.
    ///
    /// `creationDate` is a parameter so tests are deterministic; the runtime
    /// passes the moment of the lift.
    static func strokes(
        _ kind: ShapeKind,
        from start: CGPoint,
        to end: CGPoint,
        tool: PKInkingTool,
        creationDate: Date = Date()
    ) -> [PKStroke] {
        switch kind {
        case .line:
            return [
                stroke(
                    through: segment(from: start, to: end),
                    tool: tool,
                    creationDate: creationDate
                )
            ]

        case .rectangle:
            let rect = normalized(from: start, to: end)
            let topLeft = CGPoint(x: rect.minX, y: rect.minY)
            let topRight = CGPoint(x: rect.maxX, y: rect.minY)
            let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
            let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
            return [
                (topLeft, topRight),
                (topRight, bottomRight),
                (bottomRight, bottomLeft),
                (bottomLeft, topLeft),
            ].map { edge in
                stroke(
                    through: segment(from: edge.0, to: edge.1),
                    tool: tool,
                    creationDate: creationDate
                )
            }

        case .ellipse:
            return [
                stroke(
                    through: closed(ellipse(in: normalized(from: start, to: end))),
                    tool: tool,
                    creationDate: creationDate
                )
            ]
        }
    }

    // MARK: - What the spline does with these points
    //
    // `PKStrokePath` is a B-spline — the SDK header says so outright — so its
    // control points are **approximated, not interpolated**. Measured: a path
    // through (0,0), (100,0), (100,100) evaluates at parametric 1 to
    // (83.33, 16.67), which is (P0 + 4·P1 + P2) / 6 exactly. A corner given to
    // one path is a corner the ink cuts.
    //
    // Two consequences, both load-bearing above:
    //
    // - **A rectangle cannot be one path.** Four strokes are not only the
    //   eraser-granularity choice `strokes(_:from:to:tool:)` argues for; a
    //   single closed path would round all four corners by a third of their
    //   depth. Four separately clamped paths meet at sharp corners.
    // - **Dense sampling is what keeps a curve honest.** At
    //   `sampleSpacing` the deviation is the sagitta of a two-point chord —
    //   thousandths of a page point on any ellipse a user can drag.
    //
    // The ends need no help: measured, an unclamped path's rendered endpoints
    // are its first and last control points exactly, and repeating them
    // changes neither `renderBounds` nor `PKDrawing.bounds`. PencilKit clamps
    // the ends itself. Repeating them anyway would only make the ink dwell
    // where the pen never paused.

    /// A loop with its first control point repeated at the end, so the ink
    /// closes on itself instead of stopping one sample short of the seam.
    ///
    /// One point, not three: the ends being clamped already, a longer wrap
    /// would run the curve back over ink it has drawn, and a marker or a
    /// highlighter shows doubled ink as a darker patch.
    static func closed(_ loop: [CGPoint]) -> [CGPoint] {
        guard let first = loop.first else { return loop }
        return loop + [first]
    }

    /// The drag rectangle, whichever corner the drag started from.
    static func normalized(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    // MARK: - Point sampling

    /// Locations along a straight segment, both endpoints exact.
    ///
    /// The last point is `b` itself rather than `a + (b - a)`: those differ in
    /// the last bit or two of floating point, and a rectangle whose corners do
    /// not coincide is a rectangle with four visible nicks in it.
    static func segment(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let length = hypot(b.x - a.x, b.y - a.y)
        let steps = max(1, Int((length / sampleSpacing).rounded(.up)))
        return (0...steps).map { step in
            guard step != steps else { return b }
            let t = CGFloat(step) / CGFloat(steps)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// Locations around the ellipse inscribed in `rect`, one full revolution
    /// and no repeated point — `closed` closes it.
    ///
    /// The sample count is rounded up to a multiple of four so that the four
    /// extreme points are sampled exactly. Without that the control points land
    /// just inside the drag rectangle on one axis or the other, and the shape
    /// the user gets is measurably smaller than the one they dragged.
    static func ellipse(in rect: CGRect) -> [CGPoint] {
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        let centerX = rect.midX
        let centerY = rect.midY

        // Ramanujan's approximation. Any circumference estimate would do — this
        // one is accurate enough that the spacing is honest for a flat ellipse
        // as well as a round one.
        let circumference = CGFloat.pi
            * (3 * (radiusX + radiusY)
                - ((3 * radiusX + radiusY) * (radiusX + 3 * radiusY)).squareRoot())
        let wanted = max(8, Int((circumference / sampleSpacing).rounded(.up)))
        let count = wanted + (4 - wanted % 4) % 4

        return (0..<count).map { step -> CGPoint in
            let angle = 2 * CGFloat.pi * CGFloat(step) / CGFloat(count)
            return CGPoint(x: centerX + radiusX * cos(angle), y: centerY + radiusY * sin(angle))
        }
    }

    // MARK: - Stroke construction

    /// One stroke through the given locations, inked with the tool in hand.
    ///
    /// The ink comes from the tool rather than from anything of ours, which is
    /// the whole fidelity requirement: a shape drawn with the marker is marker
    /// ink at marker width, and it erases, lassoes, and renders as marker ink
    /// because that is what it is.
    static func stroke(
        through locations: [CGPoint],
        tool: PKInkingTool,
        creationDate: Date
    ) -> PKStroke {
        precondition(
            locations.count >= 2,
            "a synthesized stroke needs at least two control points"
        )

        let size = CGSize(width: tool.width, height: tool.width)
        var elapsed: TimeInterval = 0
        var previous = locations[0]
        var points: [PKStrokePoint] = []
        points.reserveCapacity(locations.count)

        for (offset, location) in locations.enumerated() {
            if offset > 0 {
                let distance = hypot(location.x - previous.x, location.y - previous.y)
                elapsed += max(TimeInterval(distance / nominalSpeed), minimumTimeStep)
            }
            previous = location
            points.append(
                PKStrokePoint(
                    location: location,
                    timeOffset: elapsed,
                    size: size,
                    opacity: opacity,
                    force: force,
                    azimuth: azimuth,
                    altitude: altitude
                )
            )
        }

        return PKStroke(ink: tool.ink, path: PKStrokePath(controlPoints: points, creationDate: creationDate))
    }
}
