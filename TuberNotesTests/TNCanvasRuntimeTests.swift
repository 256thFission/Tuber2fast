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
final class TNCanvasRuntimeTests: HostingSuite {
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

    @Test("The page turn is a finger's: the Pencil never reaches the paging pan")
    func pencilCannotTurnThePage() {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let allowed = runtime.scrollView.panGestureRecognizer.allowedTouchTypes.map { UITouch.TouchType(rawValue: $0.intValue)! }

        #expect(!allowed.contains(.pencil))
        #expect(allowed.contains(.direct))
        #expect(allowed.contains(.indirectPointer))

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
        installBlank(pages[0].id, on: runtime)
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
        installBlank(pages[0].id, on: runtime)
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

    @Test("Turning back retires each page that leaves once, a canvas with its ink and an outer-ring placeholder with none, and rebuilds the near ones from their snapshots")
    func aTurnBackRebuildsFromTheSnapshots() {
        let reporter = RecordingReporter()
        let (runtime, ids) = sixInstalledPages(reporter)
        settle(runtime, at: 3)
        reporter.retired.removeAll()

        settle(runtime, at: 0)

        // Page 6 was only ever in the outer ring: it had no canvas to retire.
        #expect(finalStrokeCounts(reporter) == [ids[2]: 3, ids[3]: 4, ids[4]: 5, ids[5]: nil])
        #expect(reporter.retired.count == 4)
        #expect(reporter.retired.last?.page == ids[5])
        #expect(reporter.sequence.suffix(2) == ["retired", "windowChanged"], "reported before the window, whose handler prunes")
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

    // MARK: - Teardown

    @Test("After retireAll nothing scrolls, and no canvas is built: not for an install, a turn, or a stroke's end")
    func aTornDownRuntimeBuildsNothing() async throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(2)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        for page in pages {
            installBlank(page.id, on: runtime)
        }
        let (a, b) = (pages[0].id, pages[1].id)
        let canvas = try #require(runtime.canvases[a])
        canvas.canvasViewDidBeginUsingTool(canvas.canvasView)

        #expect(runtime.retireAll() == [a], "a stroke on screen is waited for")
        #expect(Set(runtime.canvases.keys) == [a])

        runtime.installContent(.editable(id: b, ink: PKDrawing(), layers: [], composite: nil, inkSeq: InkSeq(2)))
        draw(strokeDrawing(strokes: 1), on: canvas)
        canvas.canvasViewDidEndUsingTool(canvas.canvasView)
        canvas.canvasViewDrawingDidChange(canvas.canvasView)

        #expect(runtime.canvases.isEmpty, "the stroke's end rebuilt nothing")
        #expect(reporter.retired.filter { $0.page == a }.map { $0.finalInk?.strokes.count } == [1])
        #expect(!runtime.scrollView.isScrollEnabled)

        let offset = runtime.scrollView.contentOffset
        runtime.scroll(to: b)
        // Longer than the animated turn a live runtime would run and settle.
        try await Task.sleep(for: .seconds(1))
        #expect(runtime.scrollView.contentOffset == offset, "a turn asked for does not scroll it")
        #expect(reporter.becameCurrent.isEmpty)

        settle(runtime, at: 1)
        #expect(runtime.canvases.isEmpty, "a turn builds nothing either")
    }

    @Test("A torn-down runtime does not scroll to a page asked for before its first layout, whether asked before the teardown or after")
    func aTornDownRuntimeKeepsNoScrollForItsFirstLayout() {
        let reporter = RecordingReporter()
        let runtime = PagedCanvasController(reporter: reporter, environment: testEnvironment)
        let pages = descriptors(3)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        runtime.scroll(to: pages[2].id)
        _ = runtime.retireAll()
        runtime.scroll(to: pages[1].id)

        host(runtime)

        #expect(runtime.scrollView.contentOffset.x == 0)
        #expect(reporter.becameCurrent.isEmpty)
    }

    @Test("Close does not wait on a use nothing can touch: one still drawing outside the window ends in the teardown")
    func retireAllEndsAToolUseOutsideTheWindow() throws {
        let reporter = RecordingReporter()
        let runtime = PagedCanvasController(reporter: reporter, environment: testEnvironment)
        let window = host(runtime)
        let pages = descriptors(2)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        for page in pages {
            installBlank(page.id, on: runtime)
        }
        let canvas = try #require(runtime.canvases[pages[0].id])
        canvas.canvasViewDidBeginUsingTool(canvas.canvasView)

        // In one turn: the window door's hop has not run yet.
        window.rootViewController = UIViewController()
        #expect(runtime.retireAll().isEmpty)
        #expect(runtime.canvases.isEmpty)
        #expect(reporter.retired.filter { $0.page == pages[0].id }.count == 1)
    }

    // MARK: - The tool

    @Test("The tool reaches every live canvas, and every canvas built after it")
    func applyReachesLiveAndLaterCanvases() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(3)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime)

        // A width no other tool in this suite uses, so the assertion cannot
        // pass on a default somebody else set.
        let tool = PKInkingTool(.pencil, color: .red, width: 7)
        runtime.apply(CanvasEnvironment(tool: .ink(tool), theme: .macaron))

        let live = try #require(runtime.canvases[pages[0].id])
        let applied = try #require(live.canvasView.tool as? PKInkingTool)
        #expect(applied.inkType == .pencil)
        #expect(applied.width == 7)

        // The runtime keeps the tool, so a canvas that did not exist when
        // `apply` ran opens holding it. Without that, a page turn would draw
        // in whatever PencilKit starts with.
        installBlank(pages[1].id, on: runtime)
        #expect(runtime.canvases.count == 2)
        for canvas in runtime.canvases.values {
            let held = try #require(canvas.canvasView.tool as? PKInkingTool)
            #expect(held.inkType == .pencil)
            #expect(held.width == 7)
        }

        _ = runtime.retireAll()
    }

    // MARK: - The undo filter

    @Test("Every view under every live canvas finds the runtime's one undo filter on the responder chain")
    func everyPencilKitViewAnswersWithTheFilter() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(3)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        for page in pages.prefix(2) {
            installBlank(page.id, on: runtime)
        }
        runtime.view.layoutIfNeeded()
        #expect(runtime.canvases.count == 2)

        let filter = try #require(runtime.undoManager as? FilteringUndoManager)
        #expect(filter.levelsOfUndo == 1)
        func subtree(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(subtree) }
        for canvas in runtime.canvases.values {
            let views = subtree(canvas.canvasView)
            #expect(views.count > 1, "PencilKit's own views are walked, not only the canvas")
            for view in views {
                #expect(view.undoManager === filter, "\(type(of: view)) answers with another manager")
            }
        }
        _ = runtime.retireAll()
    }

    @Test("The filter runs nothing it is handed, answers what it was told, and every way in to undo only reports")
    func theUndoFilterOnlyReports() {
        let reporter = RecordingReporter()
        let filter = FilteringUndoManager(reporter: reporter)
        filter.setAvailability(canUndo: true, canRedo: false)
        let restorer = Restorer()

        filter.beginUndoGrouping()
        filter.registerUndo(withTarget: restorer, selector: #selector(Restorer.restore(_:)), object: NSObject())
        filter.registerUndo(withTarget: restorer) { _ in Issue.record("a closure registration ran") }
        filter.endUndoGrouping()
        #expect(filter.canUndo && !filter.canRedo, "the told answer, not the stack's")

        // An invocation slips past the overrides; one level means the next
        // group lets go of it.
        weak var slipped: NSObject?
        autoreleasepool {
            let argument = NSObject()
            slipped = argument
            filter.beginUndoGrouping()
            (filter.prepare(withInvocationTarget: restorer) as AnyObject).restore(argument)
            filter.endUndoGrouping()
        }
        #expect(slipped != nil, "the stack holds the invocation it was handed")
        autoreleasepool {
            filter.beginUndoGrouping()
            (filter.prepare(withInvocationTarget: restorer) as AnyObject).restore(NSObject())
            filter.endUndoGrouping()
        }
        #expect(slipped == nil, "one level: the second group pushed the first out")

        filter.undo()
        filter.undoNestedGroup()
        filter.redo()
        #expect(reporter.undoRequests == 2 && reporter.redoRequests == 1)
        #expect(restorer.restored == 0)
    }

    @Test("A scroll asked for before the first layout lands when the layout arrives, and reports the turn once")
    func scrollBeforeTheFirstLayoutIsKept() {
        let reporter = RecordingReporter()
        let runtime = PagedCanvasController(reporter: reporter, environment: testEnvironment)
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
        let runtime = PagedCanvasController(reporter: reporter, environment: testEnvironment)
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

    // MARK: - The theme

    @Test("The theme reaches the ground, every canvas, every placeholder, a selection frame, and canvases built later")
    func theThemeReachesEverySurface() throws {
        let reporter = RecordingReporter()
        let runtime = hosted(reporter)
        let pages = descriptors(3)
        let image = imageLayer(x: 100, y: 200)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        for (index, page) in pages.enumerated() {
            installBlank(page.id, on: runtime, layers: index == 0 ? [image] : [])
        }
        runtime.apply(CanvasEnvironment(tool: .ink(PKLassoTool()), theme: .macaron))
        let canvas = try #require(runtime.canvases[pages[0].id])
        canvas.tapped(at: centre(of: image))
        let selection = try #require(frame(on: canvas))
        let placeholder = try #require(runtime.placeholders[pages[2].id])
        let ground = try #require(runtime.scrollView.backgroundColor)
        let dark = Theme.macaronDark
        let edge = MacaronPage.outline(dark).cgColor
        #expect(paper(of: canvas)?.layer.borderColor != edge, "the two themes draw the page edge differently")

        runtime.apply(CanvasEnvironment(tool: .ink(PKLassoTool()), theme: dark))

        #expect(runtime.scrollView.backgroundColor !== ground)
        #expect(paper(of: canvas)?.layer.borderColor == edge)
        #expect(placeholder.layer.borderColor == edge)
        #expect(frame(on: canvas) === selection)
        #expect(selection.theme == dark)

        settle(runtime, at: 2)
        let built = try #require(runtime.canvases[pages[2].id])
        #expect(paper(of: built)?.layer.borderColor == edge)
        _ = runtime.retireAll()
    }

    @Test("The canvas is light under a dark window, because the paper is white in every theme")
    func canvasIsLightUnderADarkWindow() throws {
        let reporter = RecordingReporter()
        let runtime = PagedCanvasController(reporter: reporter, environment: testEnvironment)
        let window = host(runtime)
        window.overrideUserInterfaceStyle = .dark
        window.layoutIfNeeded()
        let pages = descriptors(1)
        runtime.setPages(pages, seq: StructureSeq(1), answering: nil)
        installBlank(pages[0].id, on: runtime)
        let canvas = try #require(runtime.canvases[pages[0].id])
        runtime.view.layoutIfNeeded()

        #expect(window.traitCollection.userInterfaceStyle == .dark)
        // PencilKit reads the trait to decide what colour black ink is drawn in.
        #expect(canvas.canvasView.traitCollection.userInterfaceStyle == .light)
        _ = runtime.retireAll()
    }
}

/// An undo target that counts what ran.
final class Restorer: NSObject {
    var restored = 0
    @objc func restore(_ value: AnyObject) { restored += 1 }
}
