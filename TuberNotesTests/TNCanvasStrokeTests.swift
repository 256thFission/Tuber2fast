import CoreGraphics
import PencilKit
import Testing
@testable import TNCanvas
@testable import TNModel
import UIKit

/// A use in flight on a hosted canvas: what waits for it to end, and the
/// ink it reports, an edit or an echo.
@Suite("Canvas strokes: a use in flight and the ink it reports")
@MainActor
final class TNCanvasStrokeTests: HostingSuite {
    // MARK: - The echo latch

    @Test("A restore is an install, not an edit: its report carries the sequence")
    func restoreInkIsReportedAsAnEcho() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime)
        let canvas = try #require(runtime.canvases[pages[0].id])
        // The content install itself is not an edit and is not reported: the
        // drawing is set before the delegate is attached.
        #expect(reporter.inkChanges.isEmpty)

        runtime.restoreInk(on: pages[0].id, strokeDrawing(strokes: 2), seq: InkSeq(7))

        // Measured here, not simulated: PencilKit fires the drawing-change
        // callback for a programmatic `drawing` assignment synchronously, and
        // once. That is the question stage 4 owed an answer to, and it is the
        // whole basis of the latch — the set and its callback are serialized by
        // the main actor, so the notebook can drop exactly this one report.
        #expect(reporter.inkChanges.count == 1)
        #expect(reporter.inkChanges.first?.echoOf == InkSeq(7))
        #expect(reporter.inkChanges.first?.ink.strokes.count == 2)

        // The latch is a single shot: the next change is the user's.
        canvas.canvasViewDrawingDidChange(canvas.canvasView)
        #expect(reporter.inkChanges.count == 2)
        #expect(reporter.inkChanges.last?.echoOf == nil)

        _ = runtime.retireAll()
    }

    @Test("A latch whose callback never came clears at the end of its turn, so the next change is an edit")
    func echoLatchClearsAtEndOfTurn() async throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime)
        let canvas = try #require(runtime.canvases[pages[0].id])

        // A set that fires no callback: the latch is armed and nothing
        // consumes it.
        let delegate = canvas.canvasView.delegate
        canvas.canvasView.delegate = nil
        runtime.restoreInk(on: pages[0].id, strokeDrawing(strokes: 2), seq: InkSeq(7))
        canvas.canvasView.delegate = delegate
        await hop()

        canvas.canvasViewDrawingDidChange(canvas.canvasView)
        #expect(reporter.inkChanges.count == 1)
        #expect(reporter.inkChanges.first?.echoOf == nil, "a stamp left armed would drop the next stroke as an echo")
        _ = runtime.retireAll()
    }

    @Test("A restore that answers the drawing-changed report lands inside it, and the stroke still ends once")
    func restoreFromInsideTheInkReportLands() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(2)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime)
        let canvas = try #require(runtime.canvases[pages[0].id])
        let restored = strokeDrawing(strokes: 2)

        canvas.canvasViewDidBeginUsingTool(canvas.canvasView)
        canvas.canvasView.drawing = strokeDrawing(strokes: 3)
        // Content for the second page, held under the stroke: the canvas the
        // deferred window refresh builds is how the stroke's end is observed
        // here, because `pageStrokeDidEnd` is the only path that runs it.
        installBlank(pages[1].id, on: runtime)
        #expect(runtime.canvases[pages[1].id] == nil)
        #expect(reporter.inkChanges.count == 1, "the in-tool assignment's own callback")
        reporter.inkChanges.removeAll()

        reporter.onInkChanged = { [weak runtime, weak reporter] page, _, _ in
            reporter?.onInkChanged = nil
            runtime?.restoreInk(on: page, restored, seq: InkSeq(7))
        }
        canvas.canvasViewDidEndUsingTool(canvas.canvasView)
        canvas.canvasViewDrawingDidChange(canvas.canvasView)

        #expect(reporter.inkChanges.count == 2)
        #expect(reporter.inkChanges.first?.echoOf == nil)
        #expect(reporter.inkChanges.first?.ink.strokes.count == 3)
        #expect(reporter.inkChanges.last?.echoOf == InkSeq(7))
        // The value, not the count: `PKDrawing` equality is stroke identity,
        // and what `Notebook.retired` compares rests on the assignment keeping
        // it.
        #expect(canvas.canvasView.drawing == restored)
        // The stroke ended, and the refresh it ran restored nothing further: a
        // snapshot whose sequence had not followed the canvas's would have made
        // `applyContent` install the ink again, for a third report.
        #expect(runtime.canvases[pages[1].id] != nil)
        #expect(!canvas.isStrokeInFlight)
        #expect(runtime.retire(pages[0].id) == .retired, "nothing is left waiting on a second stroke end")
        #expect(reporter.retired.count == 1)
        #expect(reporter.retired.first?.finalInk == restored)

        _ = runtime.retireAll()
    }

    // A restore during a stroke is not here: it traps. Undo is ignored and
    // no gesture runs while a stroke is in flight, which CanvasLifecycleTests
    // and EditorBindingTests prove.
    @Test("A composite that arrives during a stroke lands when it ends, with its hit rects, and the stroke is reported once")
    func compositeWaitsForTheStroke() async throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime)
        let canvas = try #require(runtime.canvases[pages[0].id])
        await hop()
        canvas.canvasViewDidBeginUsingTool(canvas.canvasView)

        let box = textLayer("hi", x: 100, y: 100)
        let composite = Composite(image: try solidImage())
        runtime.updateComposite(on: pages[0].id, composite, layers: [box])
        #expect(backdrop(of: canvas)?.cgImage !== composite.image, "the canvas is not touched under the stroke")

        draw(strokeDrawing(strokes: 1), on: canvas)
        canvas.canvasViewDidEndUsingTool(canvas.canvasView)
        canvas.canvasViewDrawingDidChange(canvas.canvasView)

        #expect(backdrop(of: canvas)?.cgImage === composite.image)
        #expect(reporter.inkChanges.count == 1)
        #expect(reporter.inkChanges.first?.echoOf == nil, "the stroke is an edit")
        #expect(reporter.inkChanges.first?.ink.strokes.count == 1)
        runtime.apply(CanvasEnvironment(tool: .text(.body, .leading), theme: .macaron))
        canvas.tapped(at: CGPoint(x: 110, y: 110))
        #expect(reporter.textEditRequests.map(\.layer) == [box.id], "the hit rects landed with the picture")

        _ = runtime.retireAll()
    }

    @Test("A composite and a restore for page B land under a stroke on page A; page A's composite still waits")
    func neighbourStrokeHoldsNothing() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(2)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        for page in pages {
            installBlank(page.id, on: runtime)
        }
        let a = try #require(runtime.canvases[pages[0].id])
        let b = try #require(runtime.canvases[pages[1].id])
        a.canvasViewDidBeginUsingTool(a.canvasView)

        let box = textLayer("hi", x: 100, y: 100)
        let compositeB = Composite(image: try solidImage())
        let compositeA = Composite(image: try solidImage())
        runtime.updateComposite(on: pages[1].id, compositeB, layers: [box])
        runtime.restoreInk(on: pages[1].id, strokeDrawing(strokes: 3), seq: InkSeq(7))
        runtime.updateComposite(on: pages[0].id, compositeA, layers: [])
        #expect(backdrop(of: b)?.cgImage === compositeB.image, "b's picture is not held by a's stroke")
        #expect(b.canvasView.drawing.strokes.count == 3, "b's restore is not held by a's stroke")
        #expect(backdrop(of: a)?.cgImage !== compositeA.image, "a's picture waits for a's stroke")

        a.canvasView.drawing = strokeDrawing(strokes: 1)
        a.canvasViewDidEndUsingTool(a.canvasView)
        a.canvasViewDrawingDidChange(a.canvasView)
        #expect(backdrop(of: a)?.cgImage === compositeA.image, "a's picture landed when a's stroke ended")
        #expect(a.canvasView.drawing.strokes.count == 1, "nothing was restored over a's stroke")

        _ = runtime.retireAll()
    }

    // MARK: - The tool use

    /// Two pages on page 0, a use begun on page 0 with `tool` in hand, and
    /// page 1's content installed under it, where it waits: the canvas the
    /// install builds is how a test sees the use end.
    private func aUseWithAnInstallWaiting(on runtime: PagedCanvasController, tool: PKTool) throws -> (PageCanvasController, PageID) {
        let pages = descriptors(2)
        runtime.apply(CanvasEnvironment(tool: .ink(tool), theme: .macaron))
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime)
        let canvas = try #require(runtime.canvases[pages[0].id])
        canvas.canvasViewDidBeginUsingTool(canvas.canvasView)
        installBlank(pages[1].id, on: runtime)
        #expect(runtime.canvases[pages[1].id] == nil, "the install waits for the use")
        return (canvas, pages[1].id)
    }

    @Test("A lasso pass that selects nothing commits nothing, ends a turn later, and the install it held builds")
    func endOfToolUseFallbackBuildsTheWaitingCanvas() async throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let (canvas, waiting) = try aUseWithAnInstallWaiting(on: runtime, tool: PKLassoTool())

        canvas.canvasViewDidEndUsingTool(canvas.canvasView)
        #expect(canvas.isStrokeInFlight, "no change has come, and it may yet")
        #expect(runtime.canvases[waiting] == nil)

        await hop()
        // Without the fallback the use stays open until the next use on this
        // canvas commits, and every install, turn and undo waits for it.
        #expect(!canvas.isStrokeInFlight)
        #expect(runtime.canvases[waiting] != nil)
        _ = runtime.retireAll()
    }

    @Test("A use still drawing when the runtime leaves the window ends there, and what waited for it runs")
    func aToolUseEndsWhenTheRuntimeLeavesTheWindow() async throws {
        let reporter = RecordingReporter()
        let runtime = PagedCanvasController(reporter: reporter, environment: testEnvironment)
        let window = host(runtime)
        let (canvas, waiting) = try aUseWithAnInstallWaiting(on: runtime, tool: PKInkingTool(.pen))

        window.rootViewController = UIViewController()
        try await waitUntil { !canvas.isStrokeInFlight }
        #expect(runtime.canvases[waiting] != nil)
        _ = runtime.retireAll()
    }

    @Test("A use still drawing when the app leaves the foreground ends a turn later, and what waited for it runs")
    func aToolUseEndsWhenTheAppLeavesTheForeground() async throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let (canvas, waiting) = try aUseWithAnInstallWaiting(on: runtime, tool: PKInkingTool(.pen))

        runtime.endToolUses()
        #expect(canvas.isStrokeInFlight, "PencilKit's own cancel has the turn first")
        try await waitUntil { !canvas.isStrokeInFlight }
        #expect(runtime.canvases[waiting] != nil)
        _ = runtime.retireAll()
    }

    @Test("A forced exit never pre-empts PencilKit's own commit")
    func anUntouchableExitLeavesACommittingUseToItsCommit() async throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        runtime.apply(testEnvironment)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime)
        let canvas = try #require(runtime.canvases[pages[0].id])

        canvas.canvasViewDidBeginUsingTool(canvas.canvasView)
        canvas.canvasViewDidEndUsingTool(canvas.canvasView)
        runtime.endToolUses()
        await hop()
        #expect(canvas.isStrokeInFlight, "the use is committing, and only its change or its bound ends it")

        draw(strokeDrawing(strokes: 1), on: canvas)
        canvas.canvasViewDrawingDidChange(canvas.canvasView)
        #expect(!canvas.isStrokeInFlight)
        #expect(reporter.inkChanges.map { $0.ink.strokes.count } == [1])
        _ = runtime.retireAll()
    }

    @Test("A pen use waits for its commit past one turn, and the commit is the stroke")
    func aPenUseWaitsForItsCommitPastOneTurn() async throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        runtime.apply(testEnvironment)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime)
        let canvas = try #require(runtime.canvases[pages[0].id])
        await hop()

        canvas.canvasViewDidBeginUsingTool(canvas.canvasView)
        draw(strokeDrawing(strokes: 1), on: canvas)
        canvas.canvasViewDidEndUsingTool(canvas.canvasView)
        await hop()
        #expect(canvas.isStrokeInFlight, "PencilKit commits a pen stroke after the use ends, and it has not yet")

        canvas.canvasViewDrawingDidChange(canvas.canvasView)
        #expect(!canvas.isStrokeInFlight)
        #expect(reporter.inkChanges.map { $0.ink.strokes.count } == [1])
        _ = runtime.retireAll()
    }

    @Test("A pen use that commits nothing ends at the bound, and what waited for it runs")
    func aPenUseThatCommitsNothingEndsAtTheBound() async throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let (canvas, waiting) = try aUseWithAnInstallWaiting(on: runtime, tool: PKInkingTool(.pen))

        canvas.canvasViewDidEndUsingTool(canvas.canvasView)
        try await waitUntil(.seconds(5)) { !canvas.isStrokeInFlight }
        #expect(runtime.canvases[waiting] != nil)
        _ = runtime.retireAll()
    }

    @Test("An eraser use that commits nothing ends after one turn, as every tool but a pen does")
    func anEraserUseThatCommitsNothingEndsAfterOneTurn() async throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        runtime.apply(CanvasEnvironment(tool: .ink(PKEraserTool(.vector)), theme: .macaron))
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime)
        let canvas = try #require(runtime.canvases[pages[0].id])

        canvas.canvasViewDidBeginUsingTool(canvas.canvasView)
        canvas.canvasViewDidEndUsingTool(canvas.canvasView)
        await hop()
        #expect(!canvas.isStrokeInFlight)
        _ = runtime.retireAll()
    }

    @Test("A tool told during a stroke reaches the other canvases at once, and that canvas when the stroke ends")
    func aToolToldMidStrokeWaitsForTheStroke() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        runtime.apply(testEnvironment)
        let pages = descriptors(2)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        for page in pages {
            installBlank(page.id, on: runtime)
        }
        let a = try #require(runtime.canvases[pages[0].id])
        let b = try #require(runtime.canvases[pages[1].id])
        a.canvasViewDidBeginUsingTool(a.canvasView)

        // The text tool turns the drawing gesture off, and turning it off
        // under the Pencil cancels the stroke.
        runtime.apply(CanvasEnvironment(tool: .text(.body, .leading), theme: .macaron))
        #expect(!b.canvasView.drawingGestureRecognizer.isEnabled)
        #expect(a.canvasView.drawingGestureRecognizer.isEnabled, "the stroke keeps the tool it began with")

        draw(strokeDrawing(strokes: 1), on: a)
        a.canvasViewDidEndUsingTool(a.canvasView)
        a.canvasViewDrawingDidChange(a.canvasView)
        #expect(!a.canvasView.drawingGestureRecognizer.isEnabled)
        #expect(reporter.inkChanges.last?.ink.strokes.count == 1, "the stroke was reported before the tool changed")
        _ = runtime.retireAll()
    }

    private func backdrop(of canvas: PageCanvasController) -> UIImage? {
        paper(of: canvas)?.image
    }

    private func solidImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(UIColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try #require(context.makeImage())
    }
}
