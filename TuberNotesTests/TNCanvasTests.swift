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

    @Test("A page fills the slot on the edge that binds and is centred on the other, whichever way round each is")
    func pageFitCentresOnTheFreeEdge() {
        // Both cases fit by the same ratio, 1032 over 842, so both have the
        // same free-edge length.
        let shortEdge: CGFloat = 595 * 1032 / 842

        let landscapeInPortrait = PageFit.rect(PageGeometry(width: 842, height: 595), in: CGSize(width: 1032, height: 1376))
        #expect(abs(landscapeInPortrait.width - 1032) < 1e-6)
        #expect(abs(landscapeInPortrait.height - shortEdge) < 1e-6)
        #expect(landscapeInPortrait.origin.x == 0)
        // The origin is rounded, so the centre is the nearest whole point.
        #expect(abs(landscapeInPortrait.origin.y - ((1376 - shortEdge) / 2).rounded()) < 1e-6)

        let portraitInLandscape = PageFit.rect(PageGeometry(width: 595, height: 842), in: CGSize(width: 1376, height: 1032))
        #expect(abs(portraitInLandscape.height - 1032) < 1e-6)
        #expect(abs(portraitInLandscape.width - shortEdge) < 1e-6)
        #expect(portraitInLandscape.origin.y == 0)
        #expect(abs(portraitInLandscape.origin.x - ((1376 - shortEdge) / 2).rounded()) < 1e-6)
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

    @Test("The paper and the overlays mirror the canvas content: page points, scaled by the zoom, at the content's origin")
    func mirrorsFollowTheContent() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.installContent(
            .editable(id: pages[0].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1))
        )
        let canvas = try #require(runtime.canvases[pages[0].id])
        canvas.view.layoutIfNeeded()
        let zoom = canvas.canvasView.zoomScale
        #expect(canvas.canvasView.backgroundColor == .clear)
        for mirror in [canvas.paperView, canvas.overlayView] {
            #expect(mirror.bounds.size == CGSize(width: 612, height: 792))
            #expect(abs(mirror.frame.width - 612 * zoom) < 1e-6)
            #expect(abs(mirror.frame.height - 792 * zoom) < 1e-6)
            // The content's origin is where the scroll view shows it, which
            // is the negated offset, pixel-aligned; the inset only says where
            // it may rest.
            #expect(abs(mirror.frame.minX + canvas.canvasView.contentOffset.x) < 1e-6, "\(mirror.frame)")
            #expect(abs(mirror.frame.minY + canvas.canvasView.contentOffset.y) < 1e-6, "\(mirror.frame)")
            #expect(mirror.frame.minY > 0, "centred below the top, not at it: \(mirror.frame)")
        }
        #expect(canvas.view.subviews.firstIndex(of: canvas.paperView)! < canvas.view.subviews.firstIndex(of: canvas.canvasView)!)
        #expect(canvas.view.subviews.firstIndex(of: canvas.overlayView)! > canvas.view.subviews.firstIndex(of: canvas.canvasView)!)

        canvas.canvasView.zoomScale = zoom * 2
        canvas.canvasView.contentOffset = CGPoint(x: 40, y: 60)
        #expect(abs(canvas.paperView.frame.width - 612 * zoom * 2) < 1e-6)
        #expect(abs(canvas.paperView.frame.minX + 40) < 1e-6, "\(canvas.paperView.frame)")
        #expect(abs(canvas.paperView.frame.minY + 60) < 1e-6, "\(canvas.paperView.frame)")
        _ = runtime.retireAll()
    }

    @Test("A page deleted mid-stroke reports nothing until the stroke ends, then retires once with the final ink")
    func departedPageMidStrokeReportsOnlyOnRetire() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(2)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.installContent(
            .editable(id: pages[0].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1))
        )
        let canvas = try #require(runtime.canvases[pages[0].id])
        canvas.canvasViewDidBeginUsingTool(canvas.canvasView)

        runtime.setPages([pages[1]], seq: StructureSeq(2), answering: nil)
        #expect(reporter.retired.isEmpty, "the retire waits for the stroke")
        #expect(runtime.canvases[pages[0].id] == nil, "the canvas is out of the list while it waits")

        // PencilKit's mid-stroke drawing change, for a page the notebook has
        // already dropped: forwarding it would trap there.
        canvas.canvasViewDrawingDidChange(canvas.canvasView)
        #expect(reporter.inkChanges.isEmpty)

        canvas.canvasView.drawing = strokeDrawing(strokes: 1)
        canvas.canvasViewDidEndUsingTool(canvas.canvasView)
        canvas.canvasViewDrawingDidChange(canvas.canvasView)

        #expect(reporter.inkChanges.isEmpty, "no ink report ever leaves a retiring canvas")
        #expect(reporter.retired.map(\.page) == [pages[0].id])
        #expect(reporter.retired.first?.finalInk?.strokes.count == 1, "the stroke went with the page it belonged to")
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

    // MARK: - Turning the page

    /// Six pages, page `i` installed holding `i + 1` strokes, on page 0: the
    /// live window is pages 0 and 1, and the decoded window runs to page 2.
    private func sixInstalledPages(_ reporter: RecordingReporter) -> (PagedCanvasController, [PageID]) {
        let runtime = hosted(reporter)
        let pages = descriptors(6)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        for (index, page) in pages.enumerated() {
            runtime.installContent(
                .editable(id: page.id, ink: strokeDrawing(strokes: index + 1), layers: [], composite: nil, inkSeq: InkSeq(UInt64(index + 1)))
            )
        }
        return (runtime, pages.map(\.id))
    }

    private func finalStrokeCounts(_ reporter: RecordingReporter) -> [PageID: Int?] {
        Dictionary(reporter.retired.map { ($0.page, $0.finalInk?.strokes.count) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("A turn retires the canvases that leave the live window, each with its own ink, and builds the ones that enter")
    func aTurnRetiresWhatLeavesAndBuildsWhatEnters() {
        let reporter = RecordingReporter()
        let (runtime, ids) = sixInstalledPages(reporter)
        #expect(Set(runtime.canvases.keys) == [ids[0], ids[1]])
        #expect(reporter.retired.isEmpty)

        settle(runtime, at: 3)

        #expect(runtime.currentPageID == ids[3])
        #expect(finalStrokeCounts(reporter) == [ids[0]: 1, ids[1]: 2])
        #expect(Set(runtime.canvases.keys) == Set(ids[2...4]))
        for index in 2...4 {
            #expect(runtime.canvases[ids[index]]?.canvasView.drawing.strokes.count == index + 1)
        }
        #expect(reporter.windows.last == Array(ids[1...5]))
        _ = runtime.retireAll()
    }

    @Test("Turning back retires the far canvases once each and rebuilds the near ones from their snapshots")
    func aTurnBackRebuildsFromTheSnapshots() {
        let reporter = RecordingReporter()
        let (runtime, ids) = sixInstalledPages(reporter)
        settle(runtime, at: 3)
        reporter.retired.removeAll()

        settle(runtime, at: 0)

        #expect(finalStrokeCounts(reporter) == [ids[2]: 3, ids[3]: 4, ids[4]: 5])
        #expect(reporter.retired.count == 3)
        #expect(Set(runtime.canvases.keys) == [ids[0], ids[1]])
        #expect(runtime.canvases[ids[0]]?.canvasView.drawing.strokes.count == 1)
        #expect(runtime.canvases[ids[1]]?.canvasView.drawing.strokes.count == 2)
        #expect(reporter.windows.last == Array(ids[0...2]))
        _ = runtime.retireAll()
    }

    @Test("A page that leaves the live window and comes back is rebuilt holding the ink it left with")
    func aReturningPageCarriesTheInkItLeftWith() async throws {
        let reporter = RecordingReporter()
        let (runtime, ids) = sixInstalledPages(reporter)
        let canvas = try #require(runtime.canvases[ids[1]])
        // The install's echo latch clears at the end of its turn, so the
        // stroke below is reported as the edit it is.
        await hop()

        commitStroke(strokeDrawing(strokes: 5), on: canvas)
        #expect(reporter.inkChanges.count == 1)
        #expect(reporter.inkChanges.first?.echoOf == nil)

        settle(runtime, at: 3)
        #expect(finalStrokeCounts(reporter)[ids[1]] == 5)

        settle(runtime, at: 0)
        let rebuilt = try #require(runtime.canvases[ids[1]])
        #expect(rebuilt !== canvas)
        #expect(rebuilt.canvasView.drawing.strokes.count == 5, "the ink it left with, not the two strokes its install described")
        _ = runtime.retireAll()
    }

    @Test("Outside the live window and inside the decoded one, a slot is a placeholder, and a refused page's says why")
    func theDecodedWindowHoldsPlaceholders() {
        let reporter = RecordingReporter()
        let (runtime, ids) = sixInstalledPages(reporter)
        runtime.installContent(.placeholder(id: ids[5], faults: [.missingInk]))

        settle(runtime, at: 3)

        #expect(Set(runtime.placeholders.keys) == [ids[1], ids[5]])
        #expect(runtime.placeholders[ids[5]]?.text == PlaceholderCopy.text(for: .missingInk))
        #expect(runtime.canvases[ids[5]] == nil)
        _ = runtime.retireAll()
    }

    @Test("The decoded window is reported once per change, and a settle that changes nothing reports nothing")
    func theWindowIsReportedOncePerChange() {
        let reporter = RecordingReporter()
        let (runtime, ids) = sixInstalledPages(reporter)
        #expect(reporter.windows == [Array(ids[0...2])])

        settle(runtime, at: 3)
        settle(runtime, at: 5)
        settle(runtime, at: 4)
        settle(runtime, at: 4)

        #expect(reporter.windows == [Array(ids[0...2]), Array(ids[1...5]), Array(ids[3...5]), Array(ids[2...5])])
        #expect(reporter.becameCurrent == [ids[3], ids[5], ids[4]])
        _ = runtime.retireAll()
    }

    @Test("An unloaded page waits: no canvas and a waiting placeholder until a new install")
    func unloadForgetsTheSnapshot() throws {
        let reporter = RecordingReporter()
        let (runtime, ids) = sixInstalledPages(reporter)
        settle(runtime, at: 5)

        runtime.unload(ids[0])
        settle(runtime, at: 0)

        #expect(runtime.canvases[ids[0]] == nil)
        #expect(runtime.placeholders[ids[0]]?.text == PlaceholderCopy.waiting)
        #expect(runtime.canvases[ids[1]] != nil, "a page the notebook kept is rebuilt from its snapshot")

        runtime.installContent(.editable(id: ids[0], ink: strokeDrawing(strokes: 2), layers: [], composite: nil, inkSeq: InkSeq(9)))
        let canvas = try #require(runtime.canvases[ids[0]])
        #expect(canvas.inkSeq == InkSeq(9))
        _ = runtime.retireAll()
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

    @Test("A latch whose callback never came clears at the end of its turn, so the next change is an edit")
    func echoLatchClearsAtEndOfTurn() async throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.installContent(
            .editable(id: pages[0].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1))
        )
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
        runtime.installContent(
            .editable(id: pages[0].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1))
        )
        let canvas = try #require(runtime.canvases[pages[0].id])
        let restored = strokeDrawing(strokes: 2)

        canvas.canvasViewDidBeginUsingTool(canvas.canvasView)
        canvas.canvasView.drawing = strokeDrawing(strokes: 3)
        // Content for the second page, held under the stroke: the canvas the
        // deferred window refresh builds is how the stroke's end is observed
        // here, because `pageStrokeDidEnd` is the only path that runs it.
        runtime.installContent(
            .editable(id: pages[1].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1))
        )
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
        runtime.installContent(
            .editable(id: pages[0].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1))
        )
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
        runtime.apply(CanvasEnvironment(tool: .text(.body, .leading)))
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
            runtime.installContent(.editable(id: page.id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1)))
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
        runtime.apply(CanvasEnvironment(tool: .ink(tool)))
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.installContent(.editable(id: pages[0].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1)))
        let canvas = try #require(runtime.canvases[pages[0].id])
        canvas.canvasViewDidBeginUsingTool(canvas.canvasView)
        runtime.installContent(.editable(id: pages[1].id, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(1)))
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

    private func backdrop(of canvas: PageCanvasController) -> UIImage? {
        canvas.paperView.subviews.compactMap { $0 as? UIImageView }.first?.image
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

    @Test("A scroll asked for before the first layout lands when the layout arrives, and reports the turn once")
    func scrollBeforeTheFirstLayoutIsKept() {
        let reporter = RecordingReporter()
        let runtime = PagedCanvasController(reporter: reporter)
        let pages = descriptors(3)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.scroll(to: pages[2].id)
        #expect(reporter.becameCurrent.isEmpty, "there is no viewport yet, so nothing has settled anywhere")

        host(runtime)

        #expect(runtime.currentPageID == pages[2].id)
        #expect(runtime.scrollView.contentOffset.x == runtime.currentLayout.offsetX(at: 2))
        #expect(reporter.becameCurrent == [pages[2].id])

        _ = runtime.retireAll()
    }

    @Test("A scroll waiting for a layout is dropped when its page leaves the list")
    func scrollBeforeTheFirstLayoutFollowsItsPage() {
        let reporter = RecordingReporter()
        let runtime = PagedCanvasController(reporter: reporter)
        let pages = descriptors(3)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.scroll(to: pages[2].id)
        runtime.setPages(Array(pages.prefix(2)), seq: StructureSeq(2), answering: nil)

        host(runtime)

        #expect(runtime.currentPageID == pages[0].id)
        #expect(runtime.scrollView.contentOffset.x == 0)
        #expect(reporter.becameCurrent.isEmpty)

        _ = runtime.retireAll()
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
        let overlays = canvas.overlayView.subviews.compactMap { $0 as? TextEditingView }
        let overlay = try #require(overlays.first)
        return (runtime, pages[0].id, canvas, overlay)
    }

    private enum TestFailure: Error { case notText }

    @Test("A begin adds one overlay over the ink and makes it first responder")
    func beginAddsOneOverlay() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        #expect(canvas.overlayView.subviews.filter { $0 is TextEditingView }.count == 1)
        #expect(overlay.isFirstResponder)
        #expect(overlay.frame == CGRect(x: 100, y: 100, width: 200, height: 60))
        if case .editing = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        _ = runtime.retireAll()
    }

    @Test("An open box takes the Pencil as Scribble inside its bounds only, with spelling and autocorrection on")
    func scribbleAndSpellingInAnOpenBox() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        #expect(overlay.spellCheckingType == .yes)
        #expect(overlay.autocorrectionType == .yes)
        let interaction = try #require(overlay.interactions.first { $0 is UIScribbleInteraction } as? UIScribbleInteraction)
        #expect(interaction === overlay.scribbleInteraction)
        #expect(interaction.delegate === overlay)
        // Inside the box, in the view's own coordinates, is Scribble's.
        #expect(overlay.scribbleInteraction(interaction, shouldBeginAt: CGPoint(x: 10, y: 10)))
        #expect(overlay.scribbleInteraction(interaction, shouldBeginAt: CGPoint(x: 199, y: 59)))
        // Outside, including on the handles and the slop UIKit would allow,
        // is refused: the Pencil there is the canvas's.
        #expect(!overlay.scribbleInteraction(interaction, shouldBeginAt: CGPoint(x: -1, y: 10)))
        #expect(!overlay.scribbleInteraction(interaction, shouldBeginAt: CGPoint(x: 10, y: -8)))
        #expect(!overlay.scribbleInteraction(interaction, shouldBeginAt: CGPoint(x: 201, y: 61)))
        // The ink gesture is off while the session is open, so a Scribble
        // scratch-out can never arrive at the notebook as a stroke.
        #expect(!canvas.canvasView.drawingGestureRecognizer.isEnabled)
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
            HitTarget(id: a, kind: .text, transform: .unitSquare(to: PageRect(x: 0, y: 0, width: 100, height: 100)), locked: false),
            HitTarget(id: b, kind: .text, transform: .unitSquare(to: PageRect(x: 50, y: 50, width: 100, height: 100)), locked: false),
            HitTarget(id: link, kind: .link, transform: .unitSquare(to: PageRect(x: 300, y: 300, width: 50, height: 50)), locked: false),
        ]
        #expect(PageCanvasController.textHit(at: CGPoint(x: 10, y: 10), targets: rects) == .edit(a))
        #expect(PageCanvasController.textHit(at: CGPoint(x: 75, y: 75), targets: rects) == .edit(b))
        #expect(PageCanvasController.textHit(at: CGPoint(x: 310, y: 310), targets: rects) == nil)
        #expect(PageCanvasController.textHit(at: CGPoint(x: 500, y: 500), targets: rects) == .create(PagePoint(x: 500, y: 500)))
        #expect(PageCanvasController.linkHit(at: CGPoint(x: 310, y: 310), targets: rects) == link)
        #expect(PageCanvasController.linkHit(at: CGPoint(x: 10, y: 10), targets: rects) == nil)
    }

    @Test("undoTyping reaches the open text view's own manager, and does nothing while the view is still opening")
    func undoTypingReachesTheTextView() throws {
        let reporter = RecordingReporter()
        let (runtime, _, canvas, overlay) = try openSession(reporter, layers: [textLayer("hi", x: 100, y: 100)])
        overlay.insertText("!")
        #expect(overlay.text == "hi!")
        runtime.undoTyping()
        #expect(overlay.text == "hi")
        runtime.redoTyping()
        #expect(overlay.text == "hi!")
        #expect(reporter.undoRequests == 0 && reporter.redoRequests == 0, "nothing went up")

        canvas.tapped(at: CGPoint(x: 400, y: 500))
        if case .opening = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        runtime.undoTyping()
        canvas.undoTyping()
        canvas.redoTyping()
        if case .opening = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(overlay.text == "hi!", "the inert overlay in closing is not the session")
        _ = runtime.retireAll()
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

    // MARK: - Selection

    private func imageLayer(x: Double, y: Double, width: Double = 120, height: Double = 80) -> Layer {
        Layer(
            id: LayerID(),
            transform: .placing(sourceWidth: width, sourceHeight: height, at: (x, y), scale: 1),
            payload: .image(ImageLayer(
                asset: AssetRef(id: AssetID(), format: .heic),
                naturalSize: PixelSize(width: Int(width), height: Int(height))
            ))
        )
    }

    /// One live page holding `layers`, with `tool` applied. The lasso is the
    /// only tool an object answers.
    private func livePage(_ reporter: RecordingReporter, layers: [Layer], tool: PKTool = PKLassoTool()) throws
        -> (PagedCanvasController, PageID, PageCanvasController)
    {
        let runtime = hosted(reporter)
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.installContent(.editable(id: pages[0].id, ink: PKDrawing(), layers: layers, composite: nil, inkSeq: InkSeq(1)))
        runtime.apply(CanvasEnvironment(tool: .ink(tool)))
        let canvas = try #require(runtime.canvases[pages[0].id])
        return (runtime, pages[0].id, canvas)
    }

    private func frame(on canvas: PageCanvasController) -> LayerSelectionView? {
        canvas.overlayView.subviews.compactMap { $0 as? LayerSelectionView }.first
    }

    /// The middle of a layer's placement, in page points.
    private func centre(of layer: Layer) -> CGPoint {
        let point = layer.transform.apply(x: 0.5, y: 0.5)
        return CGPoint(x: point.x, y: point.y)
    }

    @Test("A tap on an image with the lasso raises one frame at the layer's placement")
    func lassoTapSelectsAnImage() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])

        canvas.tapped(at: centre(of: image))
        guard case .selected(let layer, _) = canvas.phase else {
            Issue.record("phase is \(canvas.phase)")
            return
        }
        #expect(layer == image.id)
        let selection = try #require(frame(on: canvas))
        #expect(canvas.overlayView.subviews.filter { $0 is LayerSelectionView }.count == 1)
        #expect(selection.frame.origin == CGPoint(x: image.transform.tx, y: image.transform.ty))
        #expect(selection.bounds.size == CGSize(width: 120, height: 80))
        _ = runtime.retireAll()
    }

    @Test("The same tap with a pen selects nothing: a Pencil over a photo writes on it")
    func aPenSelectsNothing() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image], tool: PKInkingTool(.pen, color: .black))

        canvas.tapped(at: centre(of: image))
        if case .idle = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(frame(on: canvas) == nil)
        _ = runtime.retireAll()
    }

    @Test("A tap on paper clears the selection; a tap on a second image replaces the frame")
    func tapsClearAndReplace() throws {
        let reporter = RecordingReporter()
        let first = imageLayer(x: 40, y: 40)
        let second = imageLayer(x: 300, y: 400)
        let (runtime, _, canvas) = try livePage(reporter, layers: [first, second])

        canvas.tapped(at: centre(of: first))
        #expect(frame(on: canvas)?.layerID == first.id)

        canvas.tapped(at: centre(of: second))
        #expect(canvas.overlayView.subviews.filter { $0 is LayerSelectionView }.count == 1)
        #expect(frame(on: canvas)?.layerID == second.id)

        canvas.tapped(at: CGPoint(x: 580, y: 760))
        if case .idle = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(frame(on: canvas) == nil)
        _ = runtime.retireAll()
    }

    @Test("A move reports the whole transform once, at the drag's end, and nothing before it")
    func aMoveReportsOnceAtTheEnd() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, page, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))

        selection.beginDrag(at: CGPoint(x: 60, y: 40))
        selection.continueDrag(to: CGPoint(x: 90, y: 80), by: CGPoint(x: 30, y: 40))
        #expect(reporter.transforms.isEmpty, "nothing is reported while the finger is down")
        #expect(selection.working.tx == 130 && selection.working.ty == 240)

        selection.endDrag()
        #expect(reporter.transforms.count == 1)
        let reported = try #require(reporter.transforms.first)
        #expect(reported.page == page && reported.layer == image.id)
        #expect(reported.transform.tx == 130 && reported.transform.ty == 240)
        #expect(reported.transform.a == image.transform.a && reported.transform.d == image.transform.d)
        _ = runtime.retireAll()
    }

    @Test("A refusal puts the frame back where the notebook holds the layer")
    func aRefusalRestoresTheAcceptedPlacement() throws {
        let reporter = RecordingReporter()
        reporter.transformOutcome = .refused(reason: "off the page")
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))

        selection.move(by: CGPoint(x: 5000, y: 5000))
        selection.beginDrag(at: CGPoint(x: 60, y: 40))
        selection.endDrag()
        #expect(selection.working == image.transform)
        #expect(selection.frame.origin == CGPoint(x: 100, y: 200))
        _ = runtime.retireAll()
    }

    @Test("A composite restates the frame, clears it when the layer is gone, and leaves a drag in flight alone")
    func setLayersRestatesTheFrame() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))

        let moved = image.withTransform(.placing(sourceWidth: 120, sourceHeight: 80, at: (300, 500), scale: 1))
        canvas.setLayers([moved])
        #expect(selection.working.tx == 300 && selection.working.ty == 500)
        #expect(selection.frame.origin == CGPoint(x: 300, y: 500))

        selection.beginDrag(at: CGPoint(x: 60, y: 40))
        selection.continueDrag(to: CGPoint(x: 70, y: 40), by: CGPoint(x: 10, y: 0))
        canvas.setLayers([image])
        #expect(selection.accepted == image.transform, "the notebook's value is recorded")
        #expect(selection.working.tx == 310, "the drag is not interrupted")
        selection.endDrag()

        canvas.setLayers([])
        if case .idle = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(frame(on: canvas) == nil)
        _ = runtime.retireAll()
    }

    @Test("A corner scale is uniform and cannot take either extent below eight points")
    func aCornerScaleIsUniformAndFloored() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))

        selection.scale(fromCorner: .bottomRight, to: CGPoint(x: 160, y: 240))
        let half = selection.working.unitExtents
        #expect(abs(half.width - 60) < 1e-9 && abs(half.height - 40) < 1e-9)
        #expect(abs(half.width / half.height - 1.5) < 1e-9, "the ratio is kept")
        #expect(selection.working.tx == 100 && selection.working.ty == 200, "the opposite corner stays")

        selection.scale(fromCorner: .bottomRight, to: CGPoint(x: 100, y: 200))
        let floored = selection.working.unitExtents
        #expect(floored.height >= LayerSelectionView.minimumExtent)
        #expect(abs(floored.width / floored.height - 1.5) < 1e-9)
        _ = runtime.retireAll()
    }

    @Test("Where the touch lands decides what the drag is, once, at its start")
    func theCornerDecidesTheDrag() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))
        canvas.view.layoutIfNeeded()

        // The bottom-right corner of the bounds, which its handle straddles.
        selection.beginDrag(at: CGPoint(x: 120, y: 80))
        selection.continueDrag(to: CGPoint(x: 60, y: 40), by: CGPoint(x: -60, y: -40))
        let extents = selection.working.unitExtents
        #expect(abs(extents.width - 60) < 1e-9 && abs(extents.height - 40) < 1e-9, "a corner scales")
        #expect(selection.working.tx == 100 && selection.working.ty == 200)
        selection.endDrag()
        #expect(reporter.transforms.count == 1)
        _ = runtime.retireAll()
    }

    @Test("A quarter turn rotates about the centre and leaves it where it was")
    func aQuarterTurnKeepsTheCentre() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))
        let before = selection.pageCentre

        selection.rotate(to: .pi / 2)
        #expect(selection.working.b > 0 && selection.working.c < 0)
        #expect(abs(selection.working.a) < 1e-9 && abs(selection.working.d) < 1e-9)
        #expect(abs(selection.pageCentre.x - before.x) < 1e-9)
        #expect(abs(selection.pageCentre.y - before.y) < 1e-9)
        let extents = selection.working.unitExtents
        #expect(abs(extents.width - 120) < 1e-9 && abs(extents.height - 80) < 1e-9)
        _ = runtime.retireAll()
    }

    @Test("A rotated image is hit by its own shape, not by the box around it")
    func aRotatedImageIsHitByItsOwnShape() throws {
        let reporter = RecordingReporter()
        let eighth = Double.pi / 4
        let turn = PageSpaceTransform(a: cos(eighth), b: sin(eighth), c: -sin(eighth), d: cos(eighth), tx: 0, ty: 0)
        let turned = Layer(
            id: LayerID(),
            transform: PageSpaceTransform.placing(sourceWidth: 120, sourceHeight: 80, at: (0, 0), scale: 1)
                .concatenating(turn)
                .concatenating(.translation(x: 300, y: 200)),
            payload: .image(ImageLayer(
                asset: AssetRef(id: AssetID(), format: .heic),
                naturalSize: PixelSize(width: 120, height: 80)
            ))
        )
        let (runtime, _, canvas) = try livePage(reporter, layers: [turned])

        canvas.tapped(at: centre(of: turned))
        #expect(frame(on: canvas)?.layerID == turned.id)

        // The top-left of the axis-aligned box around a diamond is outside
        // the diamond. A `CGRect.contains` would select here.
        let corners = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)].map { turned.transform.apply(x: $0.0, y: $0.1) }
        let boxCorner = CGPoint(
            x: corners.map(\.x).min()! + 0.5,
            y: corners.map(\.y).min()! + 0.5
        )
        canvas.tapped(at: boxCorner)
        #expect(frame(on: canvas) == nil, "a point the box admits and the shape does not clears the selection")
        _ = runtime.retireAll()
    }

    @Test("The text tool takes the frame down, and so does retiring, which reports only its ink")
    func aToolChangeAndARetireDropTheFrame() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])

        canvas.tapped(at: centre(of: image))
        #expect(frame(on: canvas) != nil)
        runtime.apply(CanvasEnvironment(tool: .text(.body, .leading)))
        if case .idle = canvas.phase {} else { Issue.record("phase is \(canvas.phase)") }
        #expect(frame(on: canvas) == nil)

        runtime.apply(CanvasEnvironment(tool: .ink(PKLassoTool())))
        canvas.tapped(at: centre(of: image))
        #expect(frame(on: canvas) != nil)
        _ = runtime.retireAll()
        #expect(reporter.transforms.isEmpty, "a selection is not a value, so a retire reports none of it")
        #expect(reporter.retired.count == 1)
    }

    @Test("Delete from the frame's menu is one report, and the frame waits for the composite")
    func deleteIsOneReport() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, page, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))

        selection.deleteRequested()
        #expect(reporter.deletes.count == 1)
        #expect(reporter.deletes.first?.page == page && reporter.deletes.first?.layer == image.id)
        #expect(frame(on: canvas) != nil, "the frame stays until the composite without the layer lands")

        canvas.setLayers([])
        #expect(frame(on: canvas) == nil)
        _ = runtime.retireAll()
    }

    @Test("Lock from the frame's menu is one report; the composite that answers takes the handles down and the drag with them")
    func lockIsOneReportAndTheCompositeLocksTheFrame() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200)
        let (runtime, page, canvas) = try livePage(reporter, layers: [image])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))
        #expect(!selection.isLocked)
        #expect(selection.menuActions().map(\.title) == ["Lock", "Delete"])

        selection.lockRequested(true)
        #expect(reporter.locks.count == 1)
        #expect(reporter.locks.first?.page == page && reporter.locks.first?.layer == image.id)
        #expect(reporter.locks.first?.locked == true)
        #expect(!selection.isLocked, "the frame waits for the composite, as it does for a delete")

        canvas.setLayers([image.withLock(true)])
        #expect(selection.isLocked)
        #expect(frame(on: canvas) === selection, "the same frame, restated")
        #expect(selection.menuActions().map(\.title) == ["Unlock"])
        #expect(!selection.panRecognizer.isEnabled)
        canvas.view.layoutIfNeeded()
        #expect(!selection.point(inside: CGPoint(x: 60, y: -30), with: nil), "the knob is gone")
        #expect(selection.point(inside: CGPoint(x: 60, y: 40), with: nil), "the border still takes the tap that opens the menu")
        selection.beginDrag(at: CGPoint(x: 60, y: 40))
        selection.continueDrag(to: CGPoint(x: 90, y: 80), by: CGPoint(x: 30, y: 40))
        selection.endDrag()
        #expect(selection.working == image.transform, "a locked frame does not start a drag")
        #expect(reporter.transforms.isEmpty)

        selection.lockRequested(false)
        #expect(reporter.locks.count == 2 && reporter.locks.last?.locked == false)
        canvas.setLayers([image])
        #expect(!selection.isLocked)
        #expect(selection.menuActions().map(\.title) == ["Lock", "Delete"])
        #expect(selection.panRecognizer.isEnabled)
        _ = runtime.retireAll()
    }

    @Test("A tap on a locked image with the lasso raises a frame with the unlock affordance and no handles")
    func aLockedImageSelectsLocked() throws {
        let reporter = RecordingReporter()
        let image = imageLayer(x: 100, y: 200).withLock(true)
        let (runtime, _, canvas) = try livePage(reporter, layers: [image])

        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))
        #expect(selection.layerID == image.id)
        #expect(selection.isLocked)
        #expect(selection.menuActions().map(\.title) == ["Unlock"])
        #expect(!selection.panRecognizer.isEnabled)
        #expect(selection.frame.origin == CGPoint(x: 100, y: 200))
        _ = runtime.retireAll()
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

    /// Answers an ink report, synchronously and from inside it, the way a
    /// notebook that edits the ink it was just told about would.
    var onInkChanged: (@MainActor (PageID, PKDrawing, InkSeq?) -> Void)?

    func inkChanged(on page: PageID, _ ink: PKDrawing, echoOf: InkSeq?) {
        inkChanges.append((page, ink, echoOf))
        onInkChanged?(page, ink, echoOf)
    }

    var transforms: [(page: PageID, layer: LayerID, transform: PageSpaceTransform)] = []
    var deletes: [(page: PageID, layer: LayerID)] = []
    /// What the notebook answers a transform with. `.refused` is what a
    /// drag past the page's tenth edge would get.
    var transformOutcome: TransformOutcome = .accepted

    func layerTransformed(on page: PageID, layer: LayerID, to transform: PageSpaceTransform) -> TransformOutcome {
        transforms.append((page, layer, transform))
        sequence.append("layerTransformed")
        return transformOutcome
    }

    func layerDeleteRequested(on page: PageID, layer: LayerID) {
        deletes.append((page, layer))
        sequence.append("layerDeleteRequested")
    }

    var locks: [(page: PageID, layer: LayerID, locked: Bool)] = []

    func layerLockRequested(on page: PageID, layer: LayerID, locked: Bool) {
        locks.append((page, layer, locked))
        sequence.append("layerLockRequested")
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
