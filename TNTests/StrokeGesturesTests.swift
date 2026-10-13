import Foundation
import PencilKit
import Testing
import UIKit
@testable import TNNotebook

@Suite("Stroke gestures: the scribble reading")
struct StrokeGesturesTests {
    /// The reading of the last stroke, which is the one that just landed.
    func reading(_ strokes: [PKStroke]) -> ScribbleReading {
        ScribbleReading.measure(stroke: strokes.count - 1, in: strokes)
    }

    @Test("A zigzag over two of three lines has those two as its subject")
    func zigzagOverTwoOfThree() {
        let lines = (0..<3).map { i in
            Ink.line(from: CGPoint(x: 0, y: CGFloat(i) * 50), to: CGPoint(x: 200, y: CGFloat(i) * 50))
        }
        let scribble = Ink.zigzag(over: CGRect(x: 20, y: -10, width: 80, height: 70), turns: 4)
        let read = reading(lines + [scribble])
        #expect(read.turns >= ScribbleReading.minimumTurns)
        #expect(read.folding >= ScribbleReading.minimumFolding)
        #expect(read.subject == IndexSet([0, 1]))
    }

    @Test("A w is ink: two turns, no subject")
    func theLetterW() {
        let line = Ink.line(from: CGPoint(x: 0, y: 30), to: CGPoint(x: 60, y: 30))
        let read = reading([line, Ink.w(in: CGRect(x: 0, y: 0, width: 60, height: 60))])
        #expect(read.turns == 2)
        #expect(read.turns < ScribbleReading.minimumTurns)
        #expect(read.hits == nil)
        #expect(read.subject == nil)
    }

    @Test("Two loops around a line turn gently: no turns, no hit test, no subject")
    func doubleLoop() {
        let line = Ink.line(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 50))
        let read = reading([line, Ink.loops(around: CGRect(x: 0, y: 40, width: 100, height: 20), count: 2)])
        #expect(read.turns == 0)
        #expect(read.hits == nil)
        #expect(read.subject == nil)
    }

    @Test("A zigzag over blank paper reads its turns and hits nothing")
    func zigzagOverBlankPaper() {
        let read = reading([Ink.zigzag(over: CGRect(x: 20, y: -10, width: 80, height: 70), turns: 4)])
        #expect(read.turns >= ScribbleReading.minimumTurns)
        #expect(read.hits == IndexSet())
        #expect(read.subject == nil)
    }

    @Test("A straight line fails the shape thresholds, so the hit test never runs")
    func straightLine() {
        let crossed = Ink.line(from: CGPoint(x: 50, y: -50), to: CGPoint(x: 50, y: 50))
        let read = reading([crossed, Ink.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))])
        #expect(read.turns < ScribbleReading.minimumTurns)
        #expect(read.hits == nil)
    }

    @Test("A zigzag whose bounds meet a stroke it never comes near has no subject")
    func boundsMeetButInkDoesNot() {
        let diagonal = Ink.line(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 0, y: 100))
        let scribble = Ink.zigzag(over: CGRect(x: 0, y: 0, width: 30, height: 30), turns: 4)
        #expect(diagonal.renderBounds.intersects(scribble.renderBounds))
        let read = reading([diagonal, scribble])
        #expect(read.turns >= ScribbleReading.minimumTurns)
        #expect(read.hits == IndexSet())
        #expect(read.subject == nil)
    }

    @Test("A moved line is hit where it now is, not where it was")
    func movedLine() {
        let moved = Ink.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), transform: CGAffineTransform(translationX: 0, y: 200))
        let now = reading([moved, Ink.zigzag(over: CGRect(x: 20, y: 190, width: 60, height: 20), turns: 4)])
        #expect(now.subject == IndexSet([0]))
        let before = reading([moved, Ink.zigzag(over: CGRect(x: 20, y: -10, width: 60, height: 20), turns: 4)])
        #expect(before.turns >= ScribbleReading.minimumTurns)
        #expect(before.subject == nil)
    }

    @Test("A masked line is hit on the half that is still ink, not on the half that was erased")
    func maskedLine() {
        let masked = Ink.line(
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 100, y: 0),
            mask: UIBezierPath(rect: CGRect(x: -10, y: -10, width: 60, height: 20))
        )
        let overErased = reading([masked, Ink.zigzag(over: CGRect(x: 60, y: -10, width: 30, height: 20), turns: 4)])
        #expect(overErased.hits == IndexSet())
        #expect(overErased.subject == nil)
        let overInk = reading([masked, Ink.zigzag(over: CGRect(x: 10, y: -10, width: 30, height: 20), turns: 4)])
        #expect(overInk.subject == IndexSet([0]))
    }

    @Test("A thin zigzag across the edge of a wide highlighter line hits it")
    func highlighterEdge() {
        let highlight = Ink.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 0), width: 40, type: .marker)
        let scribble = Ink.zigzag(over: CGRect(x: 50, y: 10, width: 40, height: 8), turns: 4)
        let read = reading([highlight, scribble])
        #expect(read.turns >= ScribbleReading.minimumTurns)
        #expect(read.subject == IndexSet([0]))
        // The same scribble, the same distance away from a thin line: the
        // target's half width is what carries this hit.
        let thin = Ink.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 0))
        #expect(reading([thin, scribble]).subject == nil)
    }
}

@Suite("Stroke gestures: the double circle reading")
struct DoubleCircleGestureTests {
    /// The reading of the last stroke, which is the one that just landed.
    func reading(_ strokes: [PKStroke]) -> DoubleCircleReading {
        DoubleCircleReading.measure(stroke: strokes.count - 1, in: strokes)
    }

    func scribble(_ strokes: [PKStroke]) -> ScribbleReading {
        ScribbleReading.measure(stroke: strokes.count - 1, in: strokes)
    }

    /// Two lines a ring can sit around, and a third far enough down the page
    /// that the ring's bounds do not reach it.
    static func threeLines() -> [PKStroke] {
        [0, 20, 300].map { y in
            Ink.line(from: CGPoint(x: 0, y: CGFloat(y)), to: CGPoint(x: 200, y: CGFloat(y)))
        }
    }

    static let twoOfThem = CGRect(x: 0, y: 0, width: 200, height: 20)

    @Test("Two loops around two of three lines enclose those two, and turn gently")
    func twoLoopsAroundTwoOfThree() {
        let strokes = Self.threeLines() + [Ink.loops(around: Self.twoOfThem, count: 2)]
        let read = reading(strokes)
        #expect(read.closings >= DoubleCircleReading.minimumClosings)
        #expect(read.overlap >= DoubleCircleReading.minimumOverlap)
        #expect(DoubleCircleReading.aspectRange.contains(read.aspect))
        #expect(DoubleCircleReading.roundnessRange.contains(read.roundness))
        #expect(read.subject == IndexSet([0, 1]))
        // The same stroke read as a scribble: a ring has no cusp, so the
        // shape thresholds fail before the hit test runs.
        #expect(scribble(strokes).turns == 0)
        #expect(scribble(strokes).subject == nil)
    }

    @Test("With the double circle unbound its reading is not taken, and the log line leaves it out")
    func anUnboundReadingIsNotTaken() {
        let strokes = Self.threeLines() + [Ink.loops(around: Self.twoOfThem, count: 2)]
        func line(_ bindings: GestureBindings) -> (GestureMatch?, String) {
            var logged = ""
            let match = GestureTrigger.recognise(stroke: strokes.count - 1, in: strokes, bindings: bindings) { logged = $0 }
            return (match, logged)
        }
        let (unbound, unboundLine) = line([.scribble: .erase])
        #expect(unbound == nil)
        #expect(!unboundLine.contains("circle."))
        #expect(unboundLine.contains("trigger=none effect=none"), "a reading not taken has no subject")
        let (bound, boundLine) = line([.doubleCircle: .erase])
        #expect(bound?.trigger == .doubleCircle)
        #expect(boundLine.contains("circle.closings="))
    }

    @Test("One loop is not a double circle: it closes once, and the containment test never runs")
    func oneLoop() {
        let read = reading(Self.threeLines() + [Ink.loops(around: Self.twoOfThem, count: 1)])
        #expect(read.closings == 1)
        #expect(read.closings < DoubleCircleReading.minimumClosings)
        #expect(read.hits == nil)
        #expect(read.subject == nil)
    }

    @Test("Two loops around blank paper enclose nothing, so they are ink")
    func twoLoopsAroundBlankPaper() {
        let read = reading([Ink.loops(around: Self.twoOfThem, count: 2)])
        #expect(read.closings >= DoubleCircleReading.minimumClosings)
        #expect(read.hits == IndexSet())
        #expect(read.subject == nil)
    }

    @Test("Two loops that cross a line and enclose nothing are neither trigger")
    func loopsThatCrossButEncloseNothing() {
        let line = Ink.line(from: CGPoint(x: -300, y: 10), to: CGPoint(x: 300, y: 10))
        let strokes = [line, Ink.loops(around: CGRect(x: 0, y: 0, width: 100, height: 20), count: 2)]
        // The ring's path runs straight over the line; containment, not
        // crossing, is what a double circle points at.
        #expect(reading(strokes).hits == IndexSet())
        #expect(reading(strokes).subject == nil)
        #expect(scribble(strokes).turns == 0)
        #expect(scribble(strokes).subject == nil)
    }

    @Test("A stroke only half inside the loops is not enclosed")
    func partlyInside() {
        let crossing = Ink.line(from: CGPoint(x: 50, y: 10), to: CGPoint(x: 300, y: 10))
        let inside = Ink.line(from: CGPoint(x: 30, y: 10), to: CGPoint(x: 70, y: 10))
        let read = reading([crossing, inside, Ink.loops(around: CGRect(x: 0, y: 0, width: 100, height: 20), count: 2)])
        #expect(read.subject == IndexSet([1]), "the line that leaves the ring is not its subject")
    }

    @Test("A scratch-out drawn in loops is the scribble's, because the notebook tries scribble first")
    func aScratchOutDrawnInLoops() {
        let crossing = Ink.line(from: CGPoint(x: -200, y: 10), to: CGPoint(x: 200, y: 10))
        let inside = Ink.line(from: CGPoint(x: 30, y: 10), to: CGPoint(x: 70, y: 10))
        let loops = Ink.loops(around: CGRect(x: 0, y: 0, width: 100, height: 20), count: 2, spikes: 4)
        let strokes = [crossing, inside, loops]
        // Both readings have a subject, and they are different strokes: the
        // cusps put the crossed line in the scribble's, the ring's bounds
        // put the enclosed one in the circle's. `Notebook.gesture` takes
        // the scribble, so what the stroke crossed is what goes.
        let scratch = scribble(strokes)
        #expect(scratch.turns >= ScribbleReading.minimumTurns)
        #expect(scratch.folding >= ScribbleReading.minimumFolding)
        #expect(scratch.subject == IndexSet([0]))
        #expect(reading(strokes).subject == IndexSet([1]))
    }

    /// The ring in these two cases, and the box it sits in.
    static let smallRing = CGRect(x: 0, y: 0, width: 100, height: 20)

    @Test("A stroke in the corner of the ring's bounding box, outside the ring, survives")
    func insideTheBoxButOutsideTheRing() {
        let ring = Ink.loops(around: Self.smallRing, count: 2)
        let box = ring.renderBounds
        // A short stroke tucked into the top-left corner of the ring's box:
        // inside the box, well outside the path the ring walked.
        let corner = Ink.line(
            from: CGPoint(x: box.minX + 5, y: box.minY + 5),
            to: CGPoint(x: box.minX + 14, y: box.minY + 9)
        )
        let inside = Ink.line(from: CGPoint(x: 30, y: 10), to: CGPoint(x: 70, y: 10))
        #expect(box.contains(corner.renderBounds), "the fixture's point: the corner is inside the box")
        let read = reading([corner, inside, ring])
        #expect(read.subject == IndexSet([1]), "the corner stroke is outside the loop's own path")
    }

    @Test("A masked line whose remaining ink is inside the ring is enclosed")
    func maskedLineHalfInside() {
        // Only ink on the page counts: the erased half of a pixel-erased
        // stroke is not there to be enclosed, so a line whose surviving half
        // is inside the ring goes with it.
        let masked = Ink.line(
            from: CGPoint(x: 20, y: 10),
            to: CGPoint(x: 300, y: 10),
            mask: UIBezierPath(rect: CGRect(x: 0, y: 0, width: 60, height: 20))
        )
        let read = reading([masked, Ink.loops(around: Self.smallRing, count: 2)])
        #expect(read.subject == IndexSet([0]))
    }
}
