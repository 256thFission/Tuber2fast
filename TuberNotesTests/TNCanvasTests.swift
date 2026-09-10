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
            pages.append(PageDescriptor(id: PageID(), geometry: .letter, paper: .known(.blank)))
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

    /// A laid-out runtime. The first layout is the first viewport it has ever
    /// had, and the window is built there.
    private func hosted(_ reporter: RecordingReporter) -> PagedCanvasController {
        let runtime = PagedCanvasController(reporter: reporter)
        let root = runtime.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()
        return runtime
    }

    private func descriptors(_ count: Int) -> [PageDescriptor] {
        (0..<count).map { _ in
            PageDescriptor(id: PageID(), geometry: .letter, paper: .known(.blank))
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
    func retired(_ page: PageID, finalInk: PKDrawing?) { retired.append((page, finalInk)) }
    func undoRequested() { undoRequests += 1 }
    func redoRequested() { redoRequests += 1 }
}
