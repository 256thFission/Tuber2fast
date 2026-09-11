import CoreGraphics
import PencilKit
import Testing
@testable import TNCanvas
@testable import TNModel
import UIKit

/// The canvas runtime, hosted.
///
/// What these can prove in a simulator is arithmetic, the diff, and the
/// reports. What they cannot prove is ink: there is no Apple Pencil here, so
/// stroke feel, the backdrop's registration under a pinch, and the undo
/// gesture's route through the responder chain are all a device's verdict and
/// are recorded as such in the code.
@Suite("Canvas runtime")
@MainActor
struct TNCanvasTests {
    // MARK: - Arithmetic

    @Test("A slot is one viewport wide, and every offset is slot width times index")
    func slotArithmetic() {
        let layout = SlotLayout(slot: CGSize(width: 800, height: 1000), pageCount: 6)

        #expect(layout.contentSize == CGSize(width: 4800, height: 1000))
        #expect(layout.frame(at: 2) == CGRect(x: 1600, y: 0, width: 800, height: 1000))
        #expect(layout.offsetX(at: 4) == 3200)

        // A page varies inside its slot; the slot does not. US Letter in this
        // viewport is taller than it is wide, so the height is what fits.
        let fitted = PageFit.rect(.letter, in: layout.slot)
        #expect(abs(fitted.height - 1000) < 1e-6)
        #expect(fitted.width < 800)
        #expect(abs(PageFit.scale(.letter, in: layout.slot) - 1000 / 792) < 1e-9)

        // The append gesture, at the fraction the device measured.
        #expect(!layout.isPastEnd(offsetX: 4000))
        #expect(!layout.isPastEnd(offsetX: 4100))
        #expect(layout.isPastEnd(offsetX: 4121))
    }

    @Test("The window is derived from the offset, rounded and clamped")
    func windowDerivation() {
        let layout = SlotLayout(slot: CGSize(width: 800, height: 1000), pageCount: 6)

        #expect(layout.settledIndex(atOffsetX: 0) == 0)
        #expect(layout.settledIndex(atOffsetX: 2399) == 3)
        #expect(layout.settledIndex(atOffsetX: 2401) == 3)
        // A rubber-banded offset is past the last slot and still describes the
        // last page.
        #expect(layout.settledIndex(atOffsetX: 5200) == 5)
        #expect(layout.settledIndex(atOffsetX: -300) == 0)

        #expect(layout.liveWindow(around: 3) == 2...4)
        #expect(layout.decodedWindow(around: 3) == 1...5)
        // Clamped at both ends rather than wrapped or short.
        #expect(layout.liveWindow(around: 0) == 0...1)
        #expect(layout.decodedWindow(around: 0) == 0...2)
        #expect(layout.liveWindow(around: 5) == 4...5)
        #expect(layout.decodedWindow(around: 5) == 3...5)

        let empty = SlotLayout(slot: .zero, pageCount: 0)
        #expect(empty.settledIndex(atOffsetX: 0) == nil)
        #expect(empty.liveWindow(around: 0) == nil)
    }

    @Test("One slot per page, and the run is as wide as the pages it holds")
    func contentSizeCoversEveryPage() {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        runtime.setPages(descriptors(4), seq: StructureSeq(1), answering: nil)

        #expect(runtime.scrollView.isPagingEnabled)
        #expect(runtime.scrollView.contentSize.width == runtime.scrollView.bounds.width * 4)
        #expect(runtime.scrollView.contentSize.height == runtime.scrollView.bounds.height)

        _ = runtime.retireAll()
    }

    // MARK: - The diff

    @Test("A page that leaves the list hands its ink over first")
    func setPagesRetiresDepartedPages() {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(3)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        for (index, page) in pages.enumerated() {
            runtime.installContent(
                .editable(
                    id: page.id,
                    ink: strokeDrawing(strokes: index + 1),
                    layers: [],
                    composite: nil,
                    inkSeq: InkSeq(UInt64(index + 1))
                )
            )
        }

        // Page 0 is current, so pages 0 and 1 are live and page 2 is a
        // placeholder holding its snapshot.
        #expect(runtime.canvases.count == 2)
        reporter.retired.removeAll()

        runtime.setPages([pages[0]], seq: StructureSeq(2), answering: nil)

        // Both departures report, and only the one that had a working copy of
        // the ink reports ink.
        #expect(reporter.retired.map(\.page) == [pages[1].id, pages[2].id])
        #expect(reporter.retired.first?.finalInk?.strokes.count == 2)
        #expect(reporter.retired.last?.finalInk == nil)
        #expect(runtime.canvases.keys.map { $0 } == [pages[0].id])

        // The survivor keeps the canvas it had.
        #expect(runtime.canvases[pages[0].id] != nil)
        _ = runtime.retireAll()
    }

    @Test("Retiring a live page delivers the drawing it was holding")
    func installThenRetireDeliversTheDrawing() {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.installContent(
            .editable(id: pages[0].id, ink: strokeDrawing(strokes: 3), layers: [], composite: nil, inkSeq: InkSeq(1))
        )
        #expect(runtime.canvases[pages[0].id] != nil)

        #expect(runtime.retire(pages[0].id) == .retired)

        #expect(reporter.retired.count == 1)
        #expect(reporter.retired.first?.page == pages[0].id)
        #expect(reporter.retired.first?.finalInk?.strokes.count == 3)
        // The canvas is gone and the slot is a placeholder again.
        #expect(runtime.canvases.isEmpty)

        // Retiring again reports nothing: custody was handed over once.
        #expect(runtime.retire(pages[0].id) == .retired)
        #expect(reporter.retired.count == 1)
    }

    @Test("A refused page is a placeholder and never an editable canvas")
    func placeholderSnapshotNeverBuildsACanvas() {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(2)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)

        runtime.installContent(.placeholder(id: pages[0].id, faults: [.missingInk]))
        runtime.installContent(.placeholder(id: pages[1].id, faults: [.unknownPaper("moleskine")]))

        // Both are inside the live window, and neither may take ink: an
        // editable canvas over bytes the notebook refused is ink written onto a
        // page that cannot save it.
        #expect(runtime.canvases.isEmpty)
        #expect(reporter.inkChanges.isEmpty)
    }

    // MARK: - The end boundary

    @Test("A pull past the last page asks for one, and the answer lands on it")
    func endBoundaryIsAnsweredBySetPages() {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        var pages = descriptors(2)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)

        // Sitting on the last page, the way a turn leaves you.
        let width = runtime.scrollView.bounds.width
        runtime.scrollView.contentOffset = CGPoint(x: width, y: 0)
        runtime.scrollViewDidEndDecelerating(runtime.scrollView)
        reporter.becameCurrent.removeAll()

        // The notebook appends inside the report's handler, which is the
        // synchronous answer the seam allows: it finishes its own change and
        // pushes the new list back down before returning.
        reporter.onEndBoundary = { seq in
            pages.append(PageDescriptor(id: PageID(), geometry: .letter, paper: .known(.drawn(.blank))))
            runtime.setPages(pages, seq: StructureSeq(2), answering: seq)
        }

        // A drag that ends 20% of a slot past the last page: past the 15% the
        // device measured, and nothing an ordinary turn's overshoot reaches.
        runtime.scrollView.contentOffset = CGPoint(x: width * 1.2, y: 0)
        runtime.scrollViewDidEndDragging(runtime.scrollView, willDecelerate: false)

        #expect(reporter.boundaries.count == 1)
        #expect(runtime.currentPageID == pages[2].id)
        #expect(runtime.scrollView.contentOffset.x == width * 2)
        // The appended page is a turn — the user asked for it by pulling.
        #expect(reporter.becameCurrent == [pages[2].id])

        _ = runtime.retireAll()
    }

    // MARK: - The echo latch

    @Test("A restore is an install, not an edit: its report carries the sequence")
    func restoreInkIsReportedAsAnEcho() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.installContent(
            .editable(id: pages[0].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1))
        )
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

    // MARK: - Fixtures

    // MARK: - The tool

    @Test("The tool reaches every live canvas, and every canvas built after it")
    func applyReachesLiveAndLaterCanvases() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(3)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.installContent(
            .editable(id: pages[0].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1))
        )

        // A width no other tool in this suite uses, so the assertion cannot
        // pass on a default somebody else set.
        let tool = PKInkingTool(.pencil, color: .red, width: 7)
        runtime.apply(CanvasEnvironment(tool: .ink(tool)))

        let live = try #require(runtime.canvases[pages[0].id])
        let applied = try #require(live.canvasView.tool as? PKInkingTool)
        #expect(applied.inkType == .pencil)
        #expect(applied.width == 7)

        // The runtime keeps the tool, so a canvas that did not exist when
        // `apply` ran opens holding it. Without that, a page turn would draw
        // in whatever PencilKit starts with.
        runtime.installContent(
            .editable(id: pages[1].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1))
        )
        #expect(runtime.canvases.count == 2)
        for canvas in runtime.canvases.values {
            let held = try #require(canvas.canvasView.tool as? PKInkingTool)
            #expect(held.inkType == .pencil)
            #expect(held.width == 7)
        }

        _ = runtime.retireAll()
    }

    /// A laid-out runtime in a key window. The first layout is the first
    /// viewport it has ever had, and the window is built there; the window is
    /// what lets a text view become first responder.
    private func hosted(_ reporter: RecordingReporter) -> PagedCanvasController {
        let runtime = PagedCanvasController(reporter: reporter)
        // The host app's scene: these tests run inside it, and a window
        // without a scene is not a key window.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = runtime
        window.makeKeyAndVisible()
        WindowKeeper.shared.windows.append(window)
        runtime.view.layoutIfNeeded()
        return runtime
    }

    // MARK: - Text editing

    private func textLayer(_ string: String, x: Double, y: Double, width: Double = 200, height: Double = 60) -> Layer {
        Layer(id: LayerID(), transform: .identity, payload: .text(TextLayer(
            rect: PageRect(x: x, y: y, width: width, height: height),
            runs: [TextRun(string: string, style: .body)], alignment: .leading
        )))
    }

    private func linkLayer(x: Double, y: Double) -> Layer {
        Layer(id: LayerID(), transform: .identity, payload: .link(LinkLayer(
            rect: PageRect(x: x, y: y, width: 100, height: 40), style: .button, target: .internalPage(PageID())
        )))
    }

    /// One live page holding `layers`, with the text tool applied and a
    /// session open on the first text layer.
    private func openSession(_ reporter: RecordingReporter, layers: [Layer]) throws -> (PagedCanvasController, PageID, PageCanvasController, TextEditingView) {
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.installContent(.editable(id: pages[0].id, ink: PKDrawing(), layers: layers, composite: nil, inkSeq: InkSeq(1)))
        runtime.apply(CanvasEnvironment(tool: .text(.body, .leading)))
        let canvas = try #require(runtime.canvases[pages[0].id])
        let first = try #require(layers.first)
        guard case .text(let text) = first.payload else { throw TestFailure.notText }
        canvas.tapped(at: CGPoint(x: text.rect.x + 5, y: text.rect.y + 5))
        #expect(reporter.textEditRequests.map(\.layer) == [first.id])
        runtime.beginTextEditing(on: pages[0].id, TextEditStart(layer: first.id, text: text))
        let overlays = canvas.canvasView.subviews.compactMap { $0 as? TextEditingView }
        let overlay = try #require(overlays.first)
        return (runtime, pages[0].id, canvas, overlay)
    }

    private enum TestFailure: Error { case notText }

    @Test("A begin adds one overlay over the ink and makes it first responder")
    func beginAddsOneOverlay() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        #expect(canvas.canvasView.subviews.filter { $0 is TextEditingView }.count == 1)
        #expect(overlay.isFirstResponder)
        #expect(overlay.frame == CGRect(x: 100, y: 100, width: 200, height: 60))
        if case .editing = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        _ = runtime.retireAll()
    }

    @Test("The drawing gesture follows the tool: off for text, on for ink, session or no session")
    func drawingGestureFollowsTheTool() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.installContent(.editable(id: pages[0].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1)))
        let canvas = try #require(runtime.canvases[pages[0].id])
        runtime.apply(CanvasEnvironment(tool: .text(.body, .leading)))
        #expect(!canvas.canvasView.drawingGestureRecognizer.isEnabled)
        runtime.apply(CanvasEnvironment(tool: .ink(PKInkingTool(.pen))))
        #expect(canvas.canvasView.drawingGestureRecognizer.isEnabled)
        // A canvas built after the tool was applied starts with the gesture
        // in the tool's state.
        runtime.apply(CanvasEnvironment(tool: .text(.body, .leading)))
        _ = runtime.retire(pages[0].id)
        runtime.installContent(.editable(id: pages[0].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(2)))
        let rebuilt = try #require(runtime.canvases[pages[0].id])
        #expect(!rebuilt.canvasView.drawingGestureRecognizer.isEnabled)
        _ = runtime.retireAll()
    }

    @Test("A tap on paper commits the typed runs, then asks for a box, and the overlay waits in closing until the end lands")
    func tapOutsideCommitsThenCreates() throws {
        let reporter = RecordingReporter()
        let layer = textLayer("hi", x: 100, y: 100)
        let (runtime, page, canvas, overlay) = try openSession(reporter, layers: [layer])
        overlay.insertText("!")
        canvas.tapped(at: CGPoint(x: 400, y: 500))
        #expect(reporter.sequence.suffix(2) == ["textEditingEnded", "textBoxRequested"])
        let committed = try #require(reporter.textEditsEnded.last)
        #expect(committed.layer == layer.id)
        #expect(committed.text.runs.map(\.string).joined() == "hi!")
        #expect(committed.text.runs.allSatisfy { $0.style == .body })
        #expect(committed.text.rect == PageRect(x: 100, y: 100, width: 200, height: 60))
        #expect(reporter.textBoxRequests.last?.point == PagePoint(x: 400, y: 500))
        #expect(reporter.textBoxRequests.last?.style == .body)
        #expect(canvas.closing.keys.map { $0 } == [layer.id])
        #expect(overlay.superview != nil)
        runtime.endTextEditing(on: page, layer: layer.id)
        #expect(canvas.closing.isEmpty)
        #expect(overlay.superview == nil)
        _ = runtime.retireAll()
    }

    @Test("A tap in a second text rect commits the first, then requests the second")
    func tapInAnotherBox() throws {
        let reporter = RecordingReporter()
        let first = textLayer("a", x: 100, y: 100), second = textLayer("b", x: 100, y: 400)
        let (runtime, _, canvas, _) = try openSession(reporter, layers: [first, second])
        canvas.tapped(at: CGPoint(x: 110, y: 410))
        #expect(reporter.sequence.suffix(2) == ["textEditingEnded", "textEditRequested"])
        #expect(reporter.textEditsEnded.last?.layer == first.id)
        #expect(reporter.textEditRequests.last?.layer == second.id)
        #expect(canvas.closing.count == 1)
        if case .opening = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        _ = runtime.retireAll()
    }

    @Test("A tap inside the open box is the text view's, and a link under the text tool is nothing")
    func tapsInsideAndOnLinks() throws {
        let reporter = RecordingReporter()
        let link = linkLayer(x: 100, y: 600)
        let (runtime, _, canvas, _) = try openSession(reporter, layers: [textLayer("a", x: 100, y: 100), link])
        // A recognizer with no touch reports the origin of the view asked,
        // which is inside the overlay's bounds: the delegate must refuse it.
        let tap = try #require(canvas.canvasView.gestureRecognizers?.first { $0 is UITapGestureRecognizer })
        #expect(!canvas.gestureRecognizerShouldBegin(tap))
        let before = reporter.sequence
        canvas.tapped(at: CGPoint(x: 110, y: 610))
        #expect(reporter.sequence == before, "a link under the text tool edits nothing and activates nothing")
        #expect(reporter.links.isEmpty)
        _ = runtime.retireAll()
    }

    @Test("Hit-testing: topmost wins, a link is nothing, paper is a box")
    func textHitTesting() {
        let a = LayerID(), b = LayerID(), link = LayerID()
        let rects = [
            HitRect(id: a, rect: CGRect(x: 0, y: 0, width: 100, height: 100), kind: .text),
            HitRect(id: b, rect: CGRect(x: 50, y: 50, width: 100, height: 100), kind: .text),
            HitRect(id: link, rect: CGRect(x: 300, y: 300, width: 50, height: 50), kind: .link),
        ]
        #expect(PageCanvasController.textHit(at: CGPoint(x: 10, y: 10), rects: rects) == .edit(a))
        #expect(PageCanvasController.textHit(at: CGPoint(x: 75, y: 75), rects: rects) == .edit(b))
        #expect(PageCanvasController.textHit(at: CGPoint(x: 310, y: 310), rects: rects) == nil)
        #expect(PageCanvasController.textHit(at: CGPoint(x: 500, y: 500), rects: rects) == .create(PagePoint(x: 500, y: 500)))
        #expect(PageCanvasController.linkHit(at: CGPoint(x: 310, y: 310), rects: rects) == link)
        #expect(PageCanvasController.linkHit(at: CGPoint(x: 10, y: 10), rects: rects) == nil)
    }

    @Test("Retiring reports the draft before the final ink")
    func retireReportsDraftBeforeInk() throws {
        let reporter = RecordingReporter()
        let layer = textLayer("hi", x: 100, y: 100)
        let (runtime, page, _, overlay) = try openSession(reporter, layers: [layer])
        overlay.insertText("!")
        #expect(runtime.retire(page) == .retired)
        #expect(reporter.sequence.suffix(2) == ["textEditingEnded", "retired"])
        #expect(reporter.textEditsEnded.last?.text.runs.map(\.string).joined() == "hi!")
        #expect(overlay.superview == nil)
    }

    @Test("A page that leaves the list takes its session with it: the draft is a dead letter, the ink is not")
    func departedPageDropsTheDraft() throws {
        let reporter = RecordingReporter()
        let (runtime, page, _, _) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        runtime.setPages([], seq: StructureSeq(2), answering: nil)
        #expect(reporter.textEditsEnded.isEmpty)
        #expect(reporter.retired.map(\.page) == [page])
        #expect(runtime.canvases.isEmpty)
    }

    @Test("Switching to ink mid-session commits before the Pencil can draw")
    func inkToolCommits() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, _) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        runtime.apply(CanvasEnvironment(tool: .ink(PKInkingTool(.pen))))
        #expect(reporter.textEditsEnded.count == 1)
        if case .idle = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(canvas.canvasView.drawingGestureRecognizer.isEnabled)
        _ = runtime.retireAll()
    }

    @Test("Applying a text style mid-session changes what the caret types with")
    func styleMidSession() throws {
        let reporter = RecordingReporter()
        let (runtime, _, _, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        let bold = TextStyle(font: "system", size: 16, bold: true, italic: false, underline: false, color: TextStyle.body.color)
        runtime.apply(CanvasEnvironment(tool: .text(bold, .center)))
        overlay.insertText("!")
        let runs = overlay.committedLayer.runs
        #expect(runs.last == TextRun(string: "!", style: bold))
        #expect(overlay.committedLayer.alignment == .center)
        _ = runtime.retireAll()
    }

    @Test("A resize cannot go below one line, and typing past the bottom grows the box")
    func resizeFloorAndGrowth() throws {
        let reporter = RecordingReporter()
        let (runtime, _, _, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        overlay.resize(by: CGPoint(x: -1000, y: -1000))
        #expect(overlay.frame.width == overlay.lineHeight)
        #expect(overlay.frame.height == overlay.lineHeight)
        overlay.resize(by: CGPoint(x: 100, y: 0))
        overlay.insertText("\n\n\n\n")
        #expect(overlay.frame.height > overlay.lineHeight * 4)
        overlay.move(by: CGPoint(x: 10, y: -5))
        #expect(overlay.frame.origin == CGPoint(x: 110, y: 95))
        _ = runtime.retireAll()
    }

    @Test("A geometry change leaves the overlay where its rect says")
    func geometryLeavesTheOverlay() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        canvas.updateGeometry(PageGeometry(width: 500, height: 700))
        canvas.view.layoutIfNeeded()
        #expect(overlay.frame.origin == CGPoint(x: 100, y: 100))
        _ = runtime.retireAll()
    }

    @Test("The keyboard's overlap becomes a bottom inset, and leaves with it")
    func keyboardInset() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, _) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        let resting = canvas.canvasView.contentInset.bottom
        canvas.keyboardWillChange(showing: true, frame: CGRect(x: 0, y: 880, width: 820, height: 300))
        #expect(canvas.canvasView.contentInset.bottom >= 300)
        canvas.keyboardWillChange(showing: false, frame: nil)
        #expect(canvas.canvasView.contentInset.bottom == resting)
        _ = runtime.retireAll()
    }

    @Test("A begin for a page with no canvas is answered with the value unchanged")
    func beginWithoutACanvasIsAnswered() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(4)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        let far = pages[3].id
        #expect(runtime.canvases[far] == nil)
        let text = TextLayer(rect: PageRect(x: 1, y: 1, width: 10, height: 10), runs: [], alignment: .leading)
        let layer = LayerID()
        runtime.beginTextEditing(on: far, TextEditStart(layer: layer, text: text))
        #expect(reporter.textEditsEnded.last?.layer == layer)
        #expect(reporter.textEditsEnded.last?.text == text)
        _ = runtime.retireAll()
    }

    private func descriptors(_ count: Int) -> [PageDescriptor] {
        (0..<count).map { _ in
            PageDescriptor(id: PageID(), geometry: .letter, paper: .known(.drawn(.blank)))
        }
    }

    private func strokeDrawing(strokes: Int) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        return PKDrawing(
            strokes: (0..<strokes).map { index in
                let y = Double(index) * 20 + 40
                let points = (0..<8).map { step in
                    PKStrokePoint(
                        location: CGPoint(x: Double(step) * 40 + 40, y: y),
                        timeOffset: Double(step) * 0.01,
                        size: CGSize(width: 3, height: 3),
                        opacity: 1,
                        force: 1,
                        azimuth: 0,
                        altitude: .pi / 2
                    )
                }
                return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
            }
        )
    }
}

/// Windows the hosted runtimes live in, kept for the process: a window that
/// goes away mid-test takes first-responder status with it.
@MainActor
final class WindowKeeper {
    static let shared = WindowKeeper()
    var windows: [UIWindow] = []
}

/// A reporter that records what the runtime said, in the order it said it.
@MainActor
final class RecordingReporter: CanvasReporting {
    var inkChanges: [(page: PageID, ink: PKDrawing, echoOf: InkSeq?)] = []
    var retired: [(page: PageID, finalInk: PKDrawing?)] = []
    var windows: [[PageID]] = []
    var becameCurrent: [PageID] = []
    var boundaries: [ReportSeq] = []
    var links: [(page: PageID, layer: LayerID)] = []
    var undoRequests = 0
    var redoRequests = 0
    var textBoxRequests: [(page: PageID, point: PagePoint, style: TextStyle, alignment: TextAlignment)] = []
    var textEditRequests: [(page: PageID, layer: LayerID)] = []
    var textEditsEnded: [(page: PageID, layer: LayerID, text: TextLayer)] = []
    /// Every report by name, in order, so a test can assert what came first.
    var sequence: [String] = []

    /// Answers the end-boundary question, the way the notebook does.
    var onEndBoundary: (@MainActor (ReportSeq) -> Void)?

    func inkChanged(on page: PageID, _ ink: PKDrawing, echoOf: InkSeq?) {
        inkChanges.append((page, ink, echoOf))
    }

    func layerTransformed(on page: PageID, layer: LayerID, to transform: PageSpaceTransform) -> TransformOutcome {
        .accepted
    }

    func pageBecameCurrent(_ page: PageID) { becameCurrent.append(page) }
    func windowChanged(to pages: [PageID]) { windows.append(pages) }
    func endBoundaryReached(seq: ReportSeq) {
        boundaries.append(seq)
        onEndBoundary?(seq)
    }
    func linkActivated(on page: PageID, layer: LayerID) { links.append((page, layer)) }
    func retired(_ page: PageID, finalInk: PKDrawing?) {
        retired.append((page, finalInk))
        sequence.append("retired")
    }
    func undoRequested() { undoRequests += 1 }
    func redoRequested() { redoRequests += 1 }
    func textBoxRequested(on page: PageID, at point: PagePoint, style: TextStyle, alignment: TextAlignment) {
        textBoxRequests.append((page, point, style, alignment))
        sequence.append("textBoxRequested")
    }
    func textEditRequested(on page: PageID, layer: LayerID) {
        textEditRequests.append((page, layer))
        sequence.append("textEditRequested")
    }
    func textEditingEnded(on page: PageID, layer: LayerID, _ text: TextLayer) {
        textEditsEnded.append((page, layer, text))
        sequence.append("textEditingEnded")
    }
}
