import PencilKit
import Testing
@testable import TuberCanvas
@testable import TuberModel
@testable import TuberNotes
import UIKit

/// The shape tool's testable half.
///
/// The gesture is not testable here and never will be — the simulator has no
/// Apple Pencil — so everything below tests the seam the gesture feeds: given
/// two page points and the pen in hand, what strokes come out, what PencilKit
/// keeps of them, what it renders, and what happens when they are committed.
/// What remains device-only is listed in the pull request rather than
/// approximated with a weaker assertion.
///
/// Two tolerances recur, and neither is slack. `PKStrokePath` stores its
/// control points in reduced precision — a location comes back within about
/// 1.5e-5 page points of the one it was given, an opacity of 1 comes back as
/// 0.99998, an azimuth of 0 as -4.8e-5. Asserting bit equality on those would
/// be asserting an implementation detail of PencilKit's encoder.
@Suite("Shape synthesis")
struct ShapeSynthesisTests {
    /// A deliberately unusual pen: nothing below may pass by defaulting.
    ///
    /// Note the width. `PKInkingTool` clamps to the ink's `validWidthRange`,
    /// and the marker's floor is 7.5 — so `tool.width` is 7.5 here, not the 7
    /// that was asked for, and the strokes must follow the tool rather than
    /// the request.
    private let tool = PKInkingTool(.marker, color: .systemPurple, width: 7)
    private let created = Date(timeIntervalSince1970: 0)

    /// What `PKStrokePath` costs a control point, in page points.
    private let quantization: CGFloat = 1e-4

    // MARK: - Geometry

    @Test("A line is one stroke, from the drag's start to its end")
    func lineIsOneStroke() {
        let start = CGPoint(x: 100.5, y: 120.25)
        let end = CGPoint(x: 400.75, y: 330.5)
        let strokes = ShapeSynthesis.strokes(.line, from: start, to: end, tool: tool, creationDate: created)

        #expect(strokes.count == 1)
        let path = strokes[0].path
        #expect(distance(path.first?.location, start) < quantization)
        #expect(distance(path.last?.location, end) < quantization)
        for point in path {
            #expect(distance(from: point.location, toSegment: start, end) < quantization)
        }
    }

    @Test("A rectangle is four strokes whose endpoints are its corners")
    func rectangleIsFourEdges() {
        // Dragged bottom-right to top-left: the shape is the rectangle either
        // way, so this also pins the normalization.
        let strokes = ShapeSynthesis.strokes(
            .rectangle,
            from: CGPoint(x: 500, y: 400),
            to: CGPoint(x: 120, y: 90),
            tool: tool,
            creationDate: created
        )

        #expect(strokes.count == 4)

        let topLeft = CGPoint(x: 120, y: 90)
        let topRight = CGPoint(x: 500, y: 90)
        let bottomRight = CGPoint(x: 500, y: 400)
        let bottomLeft = CGPoint(x: 120, y: 400)
        let edges = [
            (topLeft, topRight),
            (topRight, bottomRight),
            (bottomRight, bottomLeft),
            (bottomLeft, topLeft),
        ]

        for (edge, stroke) in zip(edges, strokes) {
            // Each edge starts where the previous one ended: corners that miss
            // each other are four visible nicks in the box.
            #expect(distance(stroke.path.first?.location, edge.0) < quantization)
            #expect(distance(stroke.path.last?.location, edge.1) < quantization)
            for point in stroke.path {
                #expect(distance(from: point.location, toSegment: edge.0, edge.1) < quantization)
            }
        }
    }

    @Test("An ellipse is one closed stroke that fills the drag's bounding box")
    func ellipseFillsTheDrag() {
        let rect = CGRect(x: 80, y: 200, width: 400, height: 300)
        let strokes = ShapeSynthesis.strokes(
            .ellipse,
            from: CGPoint(x: rect.minX, y: rect.minY),
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            tool: tool,
            creationDate: created
        )

        #expect(strokes.count == 1)
        let locations = strokes[0].path.map(\.location)

        let box = boundingBox(of: locations)
        #expect(abs(box.minX - rect.minX) < quantization)
        #expect(abs(box.minY - rect.minY) < quantization)
        #expect(abs(box.maxX - rect.maxX) < quantization)
        #expect(abs(box.maxY - rect.maxY) < quantization)

        // Every control point is on the ellipse inscribed in that box.
        for location in locations {
            let normalizedX = (location.x - rect.midX) / (rect.width / 2)
            let normalizedY = (location.y - rect.midY) / (rect.height / 2)
            #expect(abs(normalizedX * normalizedX + normalizedY * normalizedY - 1) < 1e-5)
        }

        // It closes: the loop's first point is repeated as its last.
        #expect(locations.count == ShapeSynthesis.ellipse(in: rect).count + 1)
        #expect(locations.last == locations.first)
    }

    // MARK: - The pen

    @Test("A synthesized stroke is the current tool's ink, colour, and width")
    func strokesCarryTheActiveTool() {
        let strokes = ShapeSynthesis.strokes(
            .rectangle,
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 210, y: 160),
            tool: tool,
            creationDate: created
        )

        for stroke in strokes {
            #expect(stroke.ink.inkType == .marker)
            #expect(components(of: stroke.ink.color) == components(of: UIColor.systemPurple))
            #expect(stroke.transform == .identity)

            for point in stroke.path {
                #expect(point.size == CGSize(width: tool.width, height: tool.width))
                #expect(point.force == ShapeSynthesis.force)
                #expect(point.altitude == ShapeSynthesis.altitude)
                #expect(abs(point.opacity - ShapeSynthesis.opacity) < 1e-3)
                #expect(abs(point.azimuth - ShapeSynthesis.azimuth) < 1e-3)
            }

            // Time runs forwards and starts at zero: a path whose points share
            // a timestamp is degenerate, and a closed shape's repeated point is
            // the case that would produce one.
            #expect(stroke.path.first?.timeOffset == 0)
            for (earlier, later) in zip(stroke.path, stroke.path.dropFirst()) {
                #expect(later.timeOffset > earlier.timeOffset)
            }
        }
    }

    @Test("A shape drawn with a different pen is that pen")
    func strokesFollowTheToolThatDrewThem() {
        let pencil = PKInkingTool(.pencil, color: .systemGreen, width: 3)
        let strokes = ShapeSynthesis.strokes(
            .line,
            from: .zero,
            to: CGPoint(x: 100, y: 0),
            tool: pencil,
            creationDate: created
        )

        #expect(strokes[0].ink.inkType == .pencil)
        #expect(components(of: strokes[0].ink.color) == components(of: UIColor.systemGreen))
        #expect(strokes[0].path.first?.size == CGSize(width: 3, height: 3))
    }

    @Test("A closed shape repeats a point without repeating a timestamp")
    func closedShapesKeepTimeStrictlyIncreasing() {
        let path = ShapeSynthesis.strokes(
            .ellipse,
            from: .zero,
            to: CGPoint(x: 300, y: 300),
            tool: tool,
            creationDate: created
        )[0].path
        let final = path[path.index(before: path.endIndex)]
        let penultimate = path[path.index(path.endIndex, offsetBy: -2)]
        #expect(final.location == path.first?.location)
        #expect(final.timeOffset > penultimate.timeOffset)
    }

    // MARK: - What PencilKit renders

    @Test("The rendered spline reaches the drag's endpoints and stays on the line")
    func theSplineFollowsTheIdealGeometry() {
        // `PKStrokePath` is a B-spline: its control points are approximated,
        // not interpolated. This reads the curve PencilKit will actually draw
        // rather than the points it was handed.
        let start = CGPoint(x: 60, y: 700)
        let end = CGPoint(x: 540, y: 240)
        let path = ShapeSynthesis.strokes(.line, from: start, to: end, tool: tool, creationDate: created)[0].path

        let last = CGFloat(path.count - 1)
        #expect(distance(path.interpolatedPoint(at: 0).location, start) < 0.01)
        #expect(distance(path.interpolatedPoint(at: last).location, end) < 0.01)

        for step in 0...200 {
            let location = path.interpolatedPoint(at: last * CGFloat(step) / 200).location
            #expect(distance(from: location, toSegment: start, end) < 0.01)
        }
    }

    @Test("The rendered ellipse stays on the ellipse, seam included")
    func theSplineFollowsTheIdealEllipse() {
        let rect = CGRect(x: 100, y: 100, width: 300, height: 200)
        let path = ShapeSynthesis.strokes(
            .ellipse,
            from: CGPoint(x: rect.minX, y: rect.minY),
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            tool: tool,
            creationDate: created
        )[0].path

        let last = CGFloat(path.count - 1)
        for step in 0...400 {
            let location = path.interpolatedPoint(at: last * CGFloat(step) / 400).location
            let normalizedX = (location.x - rect.midX) / (rect.width / 2)
            let normalizedY = (location.y - rect.midY) / (rect.height / 2)
            // Loose by design: this is the B-spline's sag between control
            // points, which is what the sampling density is chosen to bound.
            #expect(abs(normalizedX * normalizedX + normalizedY * normalizedY - 1) < 0.01)
        }
    }

    @Test("The ink lands where the drag was, and nowhere else")
    func renderedInkCoversTheShape() {
        // The strongest evidence available without a Pencil: rasterize the
        // committed strokes and look at the page. It catches everything the
        // control-point assertions cannot — a spline that cuts a corner, a
        // shape rendered at the wrong scale, an ellipse left open at its seam.
        let pen = PKInkingTool(.pen, color: .black, width: 4)
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
        let start = CGPoint(x: rect.minX, y: rect.minY)
        let end = CGPoint(x: rect.maxX, y: rect.maxY)

        let box = PKDrawing(
            strokes: ShapeSynthesis.strokes(.rectangle, from: start, to: end, tool: pen, creationDate: created)
        )
        #expect(inked(box, in: rect, at: CGPoint(x: rect.minX, y: rect.minY)) > 0.5)
        #expect(inked(box, in: rect, at: CGPoint(x: rect.maxX, y: rect.minY)) > 0.5)
        #expect(inked(box, in: rect, at: CGPoint(x: rect.maxX, y: rect.maxY)) > 0.5)
        #expect(inked(box, in: rect, at: CGPoint(x: rect.minX, y: rect.maxY)) > 0.5)
        #expect(inked(box, in: rect, at: CGPoint(x: rect.midX, y: rect.midY)) < 0.1)

        let oval = PKDrawing(
            strokes: ShapeSynthesis.strokes(.ellipse, from: start, to: end, tool: pen, creationDate: created)
        )
        // The right-middle point is the seam, where the loop closes.
        #expect(inked(oval, in: rect, at: CGPoint(x: rect.maxX, y: rect.midY)) > 0.5)
        #expect(inked(oval, in: rect, at: CGPoint(x: rect.minX, y: rect.midY)) > 0.5)
        #expect(inked(oval, in: rect, at: CGPoint(x: rect.midX, y: rect.minY)) > 0.5)
        #expect(inked(oval, in: rect, at: CGPoint(x: rect.midX, y: rect.maxY)) > 0.5)
        #expect(inked(oval, in: rect, at: CGPoint(x: rect.minX, y: rect.minY)) < 0.1)
        #expect(inked(oval, in: rect, at: CGPoint(x: rect.midX, y: rect.midY)) < 0.1)

        let diagonal = PKDrawing(
            strokes: ShapeSynthesis.strokes(.line, from: start, to: end, tool: pen, creationDate: created)
        )
        #expect(inked(diagonal, in: rect, at: start) > 0.5)
        #expect(inked(diagonal, in: rect, at: end) > 0.5)
        #expect(inked(diagonal, in: rect, at: CGPoint(x: rect.midX, y: rect.midY)) > 0.5)
        // The other diagonal is bare — which is also what proves this sampler
        // is not reading the page upside down.
        #expect(inked(diagonal, in: rect, at: CGPoint(x: rect.maxX, y: rect.minY)) < 0.1)
    }

    // MARK: - Helpers

    /// Alpha of the rendered drawing at a page point, 0...1.
    ///
    /// `region` is padded so a stroke centred on the region's own edge is not
    /// half outside the raster.
    private func inked(_ drawing: PKDrawing, in region: CGRect, at page: CGPoint) -> CGFloat {
        let padded = region.insetBy(dx: -10, dy: -10)
        guard let cgImage = drawing.image(from: padded, scale: 1).cgImage else { return -1 }

        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        // The sampled pixel, in the raster's own top-down rows, is the page
        // point offset from the padded region's origin.
        let column = page.x - padded.minX
        let row = page.y - padded.minY
        context?.translateBy(x: -column, y: -(CGFloat(cgImage.height) - row))
        context?.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        )
        return CGFloat(pixel[3]) / 255
    }

    private func distance(_ a: CGPoint?, _ b: CGPoint) -> CGFloat {
        guard let a else { return .infinity }
        return hypot(a.x - b.x, a.y - b.y)
    }

    private func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + dx * t), point.y - (a.y + dy * t))
    }

    private func boundingBox(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(
            x: xs.min() ?? 0,
            y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
    }

    private func components(of color: UIColor) -> [CGFloat] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha].map { ($0 * 1000).rounded() / 1000 }
    }
}

/// The commit, and the mode switch that arms it.
@Suite("Shape tool runtime", .serialized)
@MainActor
struct ShapeToolRuntimeTests {
    private let tool = PKInkingTool(.pen, color: .black, width: 4)

    @Test("Committing appends the shape and leaves earlier ink untouched")
    func commitAppendsWithoutDisturbingExistingInk() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        _ = controller.view

        let existing = ShapeSynthesis.strokes(
            .line,
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 90, y: 90),
            tool: PKInkingTool(.pen, color: .systemBlue, width: 2),
            creationDate: Date(timeIntervalSince1970: 0)
        )
        controller.installDrawing(from: DrawingSnapshot(drawing: PKDrawing(strokes: existing)))
        controller.markEditable()

        let shape = ShapeSynthesis.strokes(
            .rectangle,
            from: CGPoint(x: 200, y: 200),
            to: CGPoint(x: 400, y: 300),
            tool: tool,
            creationDate: Date(timeIntervalSince1970: 0)
        )
        controller.commit(shape)

        let strokes = controller.canvasView.drawing.strokes
        #expect(strokes.count == existing.count + shape.count)
        #expect(shape.count == 4)

        // The page's own ink is first and unchanged — same ink, same geometry.
        #expect(strokes[0].ink.inkType == .pen)
        #expect(strokes[0].path.first?.size == CGSize(width: 2, height: 2))
        #expect(hypot((strokes[0].path.first?.location.x ?? 0) - 10, (strokes[0].path.first?.location.y ?? 0) - 10) < 1e-4)

        // ...and the shape is appended after it, in order, closing on itself:
        // the first edge starts where the last one ends.
        #expect(strokes[1].path.first?.location == CGPoint(x: 200, y: 200))
        #expect(strokes[4].path.last?.location == CGPoint(x: 200, y: 200))
    }

    @Test("Committing nothing changes nothing")
    func committingNoStrokesIsANoOp() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        _ = controller.view
        controller.markEditable()

        controller.commit([])
        #expect(controller.canvasView.drawing.strokes.isEmpty)
    }

    @Test("The shape tool switches PencilKit's own inking off, and finger behaviour is untouched")
    func theToolModeArbitratesOnlyThePencil() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        _ = controller.view
        let canvas = controller.canvasView

        // Freehand by default: nothing about the canvas changes until asked.
        #expect(canvas.isDrawingEnabled)
        #expect(pencilDragRecognizers(on: canvas).count == 1)
        #expect(pencilDragRecognizers(on: canvas)[0].isEnabled == false)

        controller.setShapeTool(.rectangle)
        #expect(canvas.isDrawingEnabled == false)
        #expect(pencilDragRecognizers(on: canvas)[0].isEnabled)

        controller.setShapeTool(nil)
        #expect(canvas.isDrawingEnabled)
        #expect(pencilDragRecognizers(on: canvas)[0].isEnabled == false)

        // Finger still navigates and Pencil still writes: the shape tool is a
        // mode switch on the Pencil, not a new claimant on every drag.
        #expect(canvas.drawingPolicy == .pencilOnly)
    }

    @Test("The shape recognizer accepts the Pencil and nothing else")
    func theRecognizerIsPencilOnly() {
        let controller = PageCanvasController(toolPicker: PKToolPicker(), projection: .canonical)
        _ = controller.view

        let recognizer = pencilDragRecognizers(on: controller.canvasView)[0]
        #expect(recognizer.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.pencil.rawValue)])
    }

    @Test("The tool survives a page turn and reaches pages built later")
    func theToolIsTheRuntimesNotThePages() {
        let controller = PagedCanvasController()
        let root = controller.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()
        controller.setPages(count: 5, currentPageIndex: 0)
        controller.markEditable()

        controller.setShapeTool(.ellipse)
        #expect(controller.shapeTool == .ellipse)
        #expect(controller.livePage(at: 0)?.canvasView.isDrawingEnabled == false)

        // Page 2 is outside the opening window, so its canvas is built after
        // the tool was chosen. It must still draw ellipses.
        let scroll = controller.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * 2, y: 0)
        controller.scrollViewDidEndDecelerating(scroll)
        #expect(controller.livePage(at: 2)?.canvasView.isDrawingEnabled == false)

        controller.setShapeTool(nil)
        #expect(controller.livePage(at: 2)?.canvasView.isDrawingEnabled == true)
    }

    private func pencilDragRecognizers(on canvas: PKCanvasView) -> [PencilDragRecognizer] {
        (canvas.gestureRecognizers ?? []).compactMap { $0 as? PencilDragRecognizer }
    }
}
