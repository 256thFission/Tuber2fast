import Foundation
import PencilKit
import TNCore

/// A shape the pen can make that means something. One case per shape;
/// the reading for each lives beside it in this file.
package enum GestureTrigger: String, CaseIterable, Codable, Sendable {
    case scribble
    case doubleCircle
}

/// What a trigger can do to the strokes it points at. Only the cases
/// that ship; a case is never added ahead of its arm.
package enum GestureEffect: String, CaseIterable, Codable, Sendable {
    case erase

    /// The drawing after this effect on `subject`. The trigger stroke at
    /// `added` goes with the subject whatever the effect. `strokes` is the
    /// caller's one read of `drawing.strokes`: the getter bridges, so it is
    /// read once and never inside a loop.
    ///
    /// The edit goes through the `strokes` setter on a copy, set once.
    /// Measured, it copies every stroke just as `PKDrawing(strokes:)` does,
    /// so the entry this records is priced as rebuilt and the byte bound on
    /// `EditHistory` (`PageState.swift`) is what keeps history in check.
    package func apply(to drawing: PKDrawing, strokes: [PKStroke], subject: IndexSet, added: Int) -> PKDrawing {
        switch self {
        case .erase:
            var removing = subject
            removing.insert(added)
            var kept = strokes
            // Descending, so an earlier removal cannot move a later index.
            for index in removing.reversed() { kept.remove(at: index) }
            var edited = drawing
            edited.strokes = kept
            return edited
        }
    }
}

/// Which trigger does what. A trigger absent from the map is off. Lives
/// on the palette record beside the other presets; the notebook holds
/// no copy, because a preference is never notebook state.
package typealias GestureBindings = [GestureTrigger: GestureEffect]

/// A trigger that fired, what it points at, and what the bindings say to
/// do about it. Only a bound trigger with a subject makes one.
package struct GestureMatch: Equatable, Sendable {
    package let trigger: GestureTrigger
    package let subject: IndexSet
    package let effect: GestureEffect
}

extension GestureTrigger {
    /// The one recognition entry point: every reading is taken here, the
    /// order between them is decided here, and the line the log prints is
    /// built here. Pure — `log` is handed the line rather than printing it,
    /// so the notebook stays the one that calls `TNLog` and the one that
    /// knows the page.
    ///
    /// `strokes` is the caller's single read of `drawing.strokes`; `index`
    /// is the stroke that just landed, always the last one, because
    /// PencilKit appends.
    ///
    /// The order, plainly: scribble first, because a scratch-out drawn in
    /// loops must erase what it crosses rather than hand over what it
    /// happens to enclose. A trigger with a subject and no binding does not
    /// stop the next one: an unbound scribble leaves a bound double circle
    /// free to fire.
    package static func recognise(
        stroke index: Int,
        in strokes: [PKStroke],
        bindings: GestureBindings,
        log: (String) -> Void
    ) -> GestureMatch? {
        let scribble = ScribbleReading.measure(stroke: index, in: strokes)
        let circle = DoubleCircleReading.measure(stroke: index, in: strokes)
        // Both readings are taken whatever the outcome, because the log is
        // the only way the thresholds get tuned and a second walk of one
        // stroke is not worth a branch.
        let subjects: [(trigger: GestureTrigger, subject: IndexSet)] = [
            (GestureTrigger.scribble, scribble.subject),
            (GestureTrigger.doubleCircle, circle.subject),
        ].compactMap { trigger, subject in subject.map { (trigger, $0) } }
        let match = subjects.lazy.compactMap { found -> GestureMatch? in
            bindings[found.trigger].map {
                GestureMatch(trigger: found.trigger, subject: found.subject, effect: $0)
            }
        }.first
        // `effect=off` is a subject that no binding claimed; `none` is no
        // subject anywhere. `trigger=` names the one that fired, or the
        // first that had a subject when none was bound.
        log("scribble.turns=\(scribble.turns) "
            + "scribble.folding=\(String(format: "%.2f", scribble.folding)) "
            + "scribble.hits=\(scribble.hits.map { String($0.count) } ?? "-") "
            + "circle.closings=\(circle.closings) "
            + "circle.overlap=\(String(format: "%.2f", circle.overlap)) "
            + "circle.hits=\(circle.hits.map { String($0.count) } ?? "-") "
            + "trigger=\(match?.trigger.rawValue ?? subjects.first?.trigger.rawValue ?? "none") "
            + "effect=\(match?.effect.rawValue ?? (subjects.isEmpty ? "none" : "off"))")
        return match
    }
}

/// The walk of a committed path both readings need: its points in drawing
/// space, and the length along them. A reading's own thresholds stay with
/// the reading; this is only the sampling.
private enum Sampled {
    /// The spacing the path is walked at, in points. Small enough that a
    /// cusp lands in one segment, large enough that a hand tremor does not
    /// read as a turn.
    static let distance: CGFloat = 2

    /// The path in drawing space: `renderBounds` is there and the path is
    /// not, and a stroke the lasso moved carries a transform that a fresh
    /// one does not. Only the unmasked part is ink on the page, so a
    /// pixel-erased stroke is sampled within `maskedPathRanges`.
    static func points(of stroke: PKStroke) -> [CGPoint] {
        let transform = stroke.transform
        var points: [CGPoint] = []
        for range in stroke.maskedPathRanges {
            for point in stroke.path.interpolatedPoints(in: range, by: .distance(distance)) {
                points.append(point.location.applying(transform))
            }
        }
        return points
    }

    static func length(along points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// The box the sampled points sit in. Not `renderBounds`: a loop is a
    /// part of a stroke, and only the whole stroke has one.
    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var rect = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() { rect = rect.union(CGRect(origin: point, size: .zero)) }
        return rect
    }
}

/// What was measured about one stroke, whether or not it matched. One
/// place for the numbers, so the device tuning edits constants and not
/// logic.
package struct ScribbleReading: Equatable, Sendable {
    /// Sharp turns along the path: a heading change of more than
    /// `turnAngle` between one sampled segment and the next. A "w" has
    /// two; a scratch-out has four or more; a loop has none, because a
    /// loop turns gently, which is what keeps a double circle out of
    /// this trigger.
    package static let minimumTurns = 4
    package static let turnAngle: CGFloat = 2 * .pi / 3
    /// Path length over bounding-box diagonal. A zigzag folds several
    /// widths of ink into one box; a letter does not.
    package static let minimumFolding: CGFloat = 2.5
    /// Points, in drawing space, on top of the two strokes' half widths.
    package static let hitSlack: CGFloat = 4

    /// A segment shorter than this says nothing about heading.
    private static let shortestSegment: CGFloat = 1

    package let turns: Int
    package let folding: CGFloat
    /// Nil when the shape thresholds failed and the hit test never ran.
    /// The hit test is the one pass that scales with the page, and it
    /// runs only for a stroke that already looks like a scribble.
    package let hits: IndexSet?
    /// `hits` when it is non-empty; nil is ink. Indexes the drawing the
    /// reading was taken from and never includes the stroke itself.
    package var subject: IndexSet? {
        guard let hits, !hits.isEmpty else { return nil }
        return hits
    }

    /// `index` is the stroke that just landed, always the last one,
    /// because PencilKit appends. Pure: no state, no clock, no tool.
    package static func measure(stroke index: Int, in strokes: [PKStroke]) -> ScribbleReading {
        TNPrecondition.require(
            strokes.indices.contains(index),
            "a scribble reading was asked for stroke \(index) of a drawing with \(strokes.count) strokes"
        )
        let scribble = strokes[index]
        let samples = Sampled.points(of: scribble)
        let turns = sharpTurns(along: samples)
        let bounds = scribble.renderBounds
        let diagonal = hypot(bounds.width, bounds.height)
        let folding = diagonal > 0 ? Sampled.length(along: samples) / diagonal : 0
        guard turns >= minimumTurns, folding >= minimumFolding else {
            return ScribbleReading(turns: turns, folding: folding, hits: nil)
        }
        var hits = IndexSet()
        let reach = hitSlack + halfWidth(of: scribble)
        let box = Sampled.bounds(of: samples)
        // `renderBounds` already carries each stroke's own width, so the two
        // half widths the fine test adds are in these boxes; `hitSlack` is
        // not, and the coarse filter must never be tighter than the fine one.
        let reachable = bounds.insetBy(dx: -hitSlack, dy: -hitSlack)
        for (candidate, stroke) in strokes.enumerated() where candidate != index {
            guard stroke.renderBounds.intersects(reachable) else { continue }
            if comesWithin(reach + halfWidth(of: stroke), of: samples, in: box, stroke) {
                hits.insert(candidate)
            }
        }
        return ScribbleReading(turns: turns, folding: folding, hits: hits)
    }

    private static func sharpTurns(along points: [CGPoint]) -> Int {
        var turns = 0
        var previous: CGFloat?
        for (a, b) in zip(points, points.dropFirst()) {
            let delta = CGPoint(x: b.x - a.x, y: b.y - a.y)
            guard hypot(delta.x, delta.y) >= shortestSegment else { continue }
            let heading = atan2(delta.y, delta.x)
            if let previous, abs(shortestAngle(from: previous, to: heading)) > turnAngle { turns += 1 }
            previous = heading
        }
        return turns
    }

    private static func shortestAngle(from: CGFloat, to: CGFloat) -> CGFloat {
        var difference = to - from
        while difference > .pi { difference -= 2 * .pi }
        while difference < -.pi { difference += 2 * .pi }
        return difference
    }

    /// Half the width of the stroke, from three of its points. A pen's
    /// width barely moves along one stroke, and every point read is a
    /// bridged call paid once per candidate on the page.
    private static func halfWidth(of stroke: PKStroke) -> CGFloat {
        let path = stroke.path
        guard !path.isEmpty else { return 0 }
        let picks = [0, path.count / 2, path.count - 1]
        return picks.reduce(CGFloat(0)) { $0 + path[$1].size.width } / CGFloat(picks.count) / 2
    }

    /// Whether any point of `stroke`, walked lazily so a hit ends the walk,
    /// is within `distance` of a sample.
    private static func comesWithin(_ distance: CGFloat, of samples: [CGPoint], in box: CGRect, _ stroke: PKStroke) -> Bool {
        let squared = distance * distance
        // Every sample lies inside the scribble's box, so a point further
        // outside it than `distance` is within reach of none of them. This
        // is most of the hit test's time on a dense page.
        let near = box.insetBy(dx: -distance, dy: -distance)
        let transform = stroke.transform
        for range in stroke.maskedPathRanges {
            for point in stroke.path.interpolatedPoints(in: range, by: .distance(Sampled.distance)) {
                let other = point.location.applying(transform)
                guard near.contains(other) else { continue }
                for sample in samples {
                    let dx = other.x - sample.x
                    let dy = other.y - sample.y
                    if dx * dx + dy * dy <= squared { return true }
                }
            }
        }
        return false
    }
}

/// What was measured about one stroke, whether or not it closed on itself
/// twice. The same shape as `ScribbleReading`: the constants in one place,
/// the figures the log prints, and a hit set that is nil when the shape
/// failed before the page-sized pass ran.
package struct DoubleCircleReading: Equatable, Sendable {
    /// A return counts as a closing when the path comes back this near the
    /// point it started from: a fraction of the stroke's bounds diagonal,
    /// so a big ring is judged as loosely as a small one, plus a few points
    /// for the small ring drawn tightly. A hand never lands on its own
    /// start, and a second turn of a ring sits outside the first.
    package static let closingFraction: CGFloat = 0.12
    package static let closingSlack: CGFloat = 4
    /// Two closings is a double circle. A third turn is one too, and the
    /// first two loops are the ones measured.
    package static let minimumClosings = 2
    /// The two loops' bounds intersected, over the smaller of them. Two
    /// turns of one ring cover each other almost entirely; a figure of
    /// eight, drawn as two loops side by side, does not.
    package static let minimumOverlap: CGFloat = 0.6
    /// Width over height of a loop's bounds. A ring is roughly as wide as
    /// it is tall; a there-and-back flourish is not.
    package static let aspectRange: ClosedRange<CGFloat> = 0.5...2
    /// A loop's path length over the perimeter of the ellipse its bounds
    /// predict, by Ramanujan's approximation. One is a loop that traces its
    /// own bounds the way a ring does. A loop that wanders inside them
    /// reads long; a spike or a cusp costs a little length, which is why
    /// the upper bound is the looser of the two.
    package static let roundnessRange: ClosedRange<CGFloat> = 0.8...1.3

    /// How many times the path left the neighbourhood of its start and came
    /// back to it.
    package let closings: Int
    /// The first two loops' bounds overlap, as a fraction of the smaller.
    /// Zero when there were not two loops to compare.
    package let overlap: CGFloat
    /// The two roundness figures, each the further of the two loops' from
    /// one, so a single number fails the shape when either loop does. Zero
    /// when there were not two loops to measure.
    package let aspect: CGFloat
    package let roundness: CGFloat
    /// Nil when the shape thresholds failed and the containment test never
    /// ran, as in `ScribbleReading`.
    package let hits: IndexSet?
    /// `hits` when it is non-empty; nil is ink. Indexes the drawing the
    /// reading was taken from and never includes the stroke itself.
    package var subject: IndexSet? {
        guard let hits, !hits.isEmpty else { return nil }
        return hits
    }

    /// `index` is the stroke that just landed, always the last one, because
    /// PencilKit appends. Pure: no state, no clock, no tool.
    ///
    /// A double circle points at containment, not at crossing: a ring drawn
    /// around a diagram means the diagram, and a ring that crosses ink and
    /// encloses nothing is ink itself.
    package static func measure(stroke index: Int, in strokes: [PKStroke]) -> DoubleCircleReading {
        TNPrecondition.require(
            strokes.indices.contains(index),
            "a double-circle reading was asked for stroke \(index) of a drawing with \(strokes.count) strokes"
        )
        let circle = strokes[index]
        let samples = Sampled.points(of: circle)
        let bounds = circle.renderBounds
        let reach = closingFraction * hypot(bounds.width, bounds.height) + closingSlack
        let ends = closings(along: samples, within: reach)
        // Two is what the loops below index, whatever a tuning run does to
        // the constant.
        guard ends.count >= max(minimumClosings, 2) else {
            return DoubleCircleReading(closings: ends.count, overlap: 0, aspect: 0, roundness: 0, hits: nil)
        }
        let first = Array(samples[0...ends[0]])
        let second = Array(samples[ends[0]...ends[1]])
        let boxes = (Sampled.bounds(of: first), Sampled.bounds(of: second))
        let overlap = Self.overlap(of: boxes.0, boxes.1)
        let aspect = furtherFromOne(Self.aspect(of: boxes.0), Self.aspect(of: boxes.1))
        let roundness = furtherFromOne(
            Self.roundness(of: first, in: boxes.0),
            Self.roundness(of: second, in: boxes.1)
        )
        let shaped = overlap >= minimumOverlap
            && aspectRange.contains(aspect)
            && roundnessRange.contains(roundness)
        guard shaped else {
            return DoubleCircleReading(
                closings: ends.count, overlap: overlap, aspect: aspect, roundness: roundness, hits: nil
            )
        }
        // Containment is against the outer loop's own path, not against the
        // box it sits in: a stroke in the corner of a ring's bounding box is
        // outside the ring. The outer loop is the one with the larger
        // bounds, because a hand's second turn sits outside the first as
        // often as inside it.
        let outerLoop = boxes.0.area >= boxes.1.area ? first : second
        let outerBounds = boxes.0.union(boxes.1)
        var hits = IndexSet()
        for (candidate, stroke) in strokes.enumerated() where candidate != index {
            // The cheap filter: a stroke whose rendering leaves the pair's
            // boxes cannot be inside the outer loop. Intersection and not
            // containment, because a pixel-erased stroke's `renderBounds`
            // may still span ink the mask removed, and only ink on the page
            // counts: a line whose unmasked half is inside the ring and
            // whose masked half is outside it is enclosed.
            guard stroke.renderBounds.intersects(outerBounds) else { continue }
            let points = Sampled.points(of: stroke)
            guard !points.isEmpty, points.allSatisfy({ encloses($0, outerLoop) }) else { continue }
            hits.insert(candidate)
        }
        return DoubleCircleReading(
            closings: ends.count, overlap: overlap, aspect: aspect, roundness: roundness, hits: hits
        )
    }

    /// Whether `point` is inside the polygon the loop's samples make, by the
    /// even-odd rule, with the loop closed from its last sample to its
    /// first. A point exactly on the path answers either way; a ring is
    /// drawn around ink, not through it.
    private static func encloses(_ point: CGPoint, _ loop: [CGPoint]) -> Bool {
        guard loop.count > 2 else { return false }
        var inside = false
        var previous = loop.count - 1
        for current in loop.indices {
            let a = loop[current]
            let b = loop[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    /// The index of each sample at which the path, having been further away
    /// than `reach`, came back within it of where it started.
    private static func closings(along points: [CGPoint], within reach: CGFloat) -> [Int] {
        guard let start = points.first else { return [] }
        var ends: [Int] = []
        var away = false
        for (index, point) in points.enumerated() {
            let distance = hypot(point.x - start.x, point.y - start.y)
            if distance > reach {
                away = true
            } else if away {
                ends.append(index)
                away = false
            }
        }
        return ends
    }

    private static func overlap(of one: CGRect, _ other: CGRect) -> CGFloat {
        let smaller = min(one.width * one.height, other.width * other.height)
        guard smaller > 0 else { return 0 }
        let shared = one.intersection(other)
        guard !shared.isNull else { return 0 }
        return shared.width * shared.height / smaller
    }

    private static func aspect(of box: CGRect) -> CGFloat {
        box.height > 0 ? box.width / box.height : 0
    }

    /// Ramanujan's approximation to the perimeter of the ellipse `box`
    /// circumscribes, against the length the path actually walked.
    private static func roundness(of points: [CGPoint], in box: CGRect) -> CGFloat {
        let a = box.width / 2
        let b = box.height / 2
        let perimeter = CGFloat.pi * (3 * (a + b) - ((3 * a + b) * (a + 3 * b)).squareRoot())
        guard perimeter > 0 else { return 0 }
        return Sampled.length(along: points) / perimeter
    }

    /// The figure that fails a range around one first, so one number stands
    /// for both loops.
    private static func furtherFromOne(_ one: CGFloat, _ other: CGFloat) -> CGFloat {
        abs(one - 1) >= abs(other - 1) ? one : other
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
