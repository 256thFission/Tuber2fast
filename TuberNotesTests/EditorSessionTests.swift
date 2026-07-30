import Foundation
import PencilKit
import Testing

@testable import TuberNotes

/// Behavior of the editor's save policy and page extension.
///
/// Each test builds its own session, so each builds its own canvas controller.
/// That is not the hazard the contract guards against — a *hosted* second canvas
/// is, and hosting is what registers liveness.
@Suite("Editor session", .serialized)
@MainActor
struct EditorSessionTests {
    // MARK: - Launch

    @Test("First launch creates and saves one valid document")
    func firstLaunchCreatesDocument() async throws {
        let scratch = Scratch()
        let session = scratch.session()

        await session.start()

        #expect(session.phase == .ready)

        #expect(try await savedDrawing(scratch.store) != nil)

        let index = try #require(await scratch.store.load())
        #expect(index.formatVersion == DocumentIndex.currentFormatVersion)
        #expect(index.pageWidth == PageGeometry.width)
        #expect(index.pageHeight == PageGeometry.height)
        #expect(index.pageIDs == [session.currentPageID])
        #expect(index.currentPageIndex == 0)
    }

    @Test("A later launch restores the saved drawing")
    func relaunchRestoresDocument() async throws {
        let scratch = Scratch()

        let first = scratch.session()
        await first.start()
        canvas(of: first).drawing = strokeAcrossPage()
        await first.saveIfNeeded()

        let second = scratch.session()
        await second.start()

        #expect(second.phase == .ready)
        #expect(canvas(of: second).drawing.strokes.count == 1)
        #expect(canvas(of: second).drawing.bounds == strokeAcrossPage().bounds)
    }

    @Test("Invalid stored data fails loudly and leaves the file untouched")
    func invalidDocumentFailsWithoutOverwriting() async throws {
        let scratch = Scratch()
        let garbage = Data("not a canvas".utf8)
        try scratch.writeGarbageIndex(garbage)

        let session = scratch.session()
        await session.start()

        guard case .failed = session.phase else {
            Issue.record("expected a failed phase, got \(session.phase)")
            return
        }
        #expect(try Data(contentsOf: scratch.indexURL) == garbage)
    }

    @Test("Loading a document does not mark it dirty")
    func loadingDoesNotDirtyTheDocument() async throws {
        let scratch = Scratch()
        let first = scratch.session()
        await first.start()
        canvas(of: first).drawing = strokeAcrossPage()
        await first.saveIfNeeded()

        let second = scratch.session()
        await second.start()

        // Installing the loaded drawing fires PencilKit's change callback. If
        // that were treated as an edit, this save would rewrite the file.
        let before = try Data(contentsOf: scratch.currentPageURL(of: second))
        await second.saveIfNeeded()
        #expect(try Data(contentsOf: scratch.currentPageURL(of: second)) == before)
    }

    @Test("Restarting the view task does not reload over live ink")
    func repeatedStartIsIdempotent() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()
        canvas(of: session).drawing = strokeAcrossPage()

        await session.start()

        #expect(session.phase == .ready)
        #expect(canvas(of: session).drawing.strokes.count == 1)
    }

    // MARK: - Pages

    @Test("Pulling past the last page appends one and turns to it")
    func appendPastTheEndAddsAPage() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()
        _ = canvas(of: session)
        #expect(session.pageCount == 1)

        pullPastTheEnd(session)

        #expect(session.pageCount == 2)
        #expect(session.pages.currentPageIndex == 1)

        await session.saveIfNeeded()
        let saved = try #require(await scratch.store.load())
        #expect(saved.pageIDs.count == 2)
        #expect(saved.currentPageIndex == 1)
    }

    @Test("Ink on each page is saved to that page and restored there")
    func inkStaysOnItsOwnPage() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()

        canvas(of: session).drawing = strokeAcrossPage()
        let firstPageID = session.currentPageID

        pullPastTheEnd(session)
        canvas(of: session).drawing = twoStrokesAcrossPage()
        let secondPageID = session.currentPageID
        #expect(firstPageID != secondPageID)

        await session.saveIfNeeded()

        // Read the pages back by identity, not by whatever is on screen.
        #expect(try PKDrawing(data: await scratch.store.loadPage(firstPageID)).strokes.count == 1)
        #expect(try PKDrawing(data: await scratch.store.loadPage(secondPageID)).strokes.count == 2)
    }

    @Test("A relaunch restores the page list and the page the user left on")
    func relaunchRestoresPagesAndPosition() async throws {
        let scratch = Scratch()
        let first = scratch.session()
        await first.start()
        canvas(of: first).drawing = strokeAcrossPage()
        pullPastTheEnd(first)
        canvas(of: first).drawing = twoStrokesAcrossPage()
        await first.saveIfNeeded()

        let second = scratch.session()
        await second.start()
        let restored = canvas(of: second)

        #expect(second.pageCount == 2)
        #expect(second.pages.currentPageIndex == 1)
        #expect(restored.drawing.strokes.count == 2)
    }

    @Test("Editing one page rewrites that page's file alone")
    func savingOnePageDoesNotRewriteTheOther() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()
        canvas(of: session).drawing = strokeAcrossPage()
        let firstPageID = session.currentPageID

        pullPastTheEnd(session)
        canvas(of: session).drawing = twoStrokesAcrossPage()
        await session.saveIfNeeded()

        let firstPageWrittenAt = try #require(scratch.modificationDate(ofPage: firstPageID))

        // Far enough apart that an unwanted rewrite cannot hide inside the
        // filesystem's timestamp resolution.
        try await Task.sleep(for: .milliseconds(1100))
        canvas(of: session).drawing = strokeAcrossPage()
        await session.saveIfNeeded()

        // The whole point of the format: page one was not touched.
        #expect(scratch.modificationDate(ofPage: firstPageID) == firstPageWrittenAt)
    }

    @Test("Ink drawn on a page that then scrolls out of the window is still saved")
    func inkSurvivesItsPageLeavingTheWindow() async throws {
        let scratch = Scratch()
        let session = scratch.session(debounce: .seconds(30))
        await session.start()

        canvas(of: session).drawing = strokeAcrossPage()
        let inkedPageID = session.currentPageID

        // Four appends put the inked page well outside the live window, so its
        // canvas is released before any save has run.
        for _ in 0..<4 { pullPastTheEnd(session) }
        #expect(session.pages.livePage(at: 0) == nil)

        // The retiring page's ink is serialized asynchronously; let that land.
        try await Task.sleep(for: .milliseconds(50))
        await session.saveIfNeeded()

        #expect(try PKDrawing(data: await scratch.store.loadPage(inkedPageID)).strokes.count == 1)
    }

    // MARK: - Autosave

    @Test("A drawing change is debounced and then saved")
    func drawingChangeIsDebouncedAndSaved() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()
        let initial = try await savedDrawing(scratch.store)

        canvas(of: session).drawing = strokeAcrossPage()
        // The change callback comes from PencilKit's delegate on the real
        // device; assigning `drawing` fires the same path here.
        try await Task.sleep(for: .milliseconds(120))

        let saved = try await savedDrawing(scratch.store)
        #expect(saved != initial)
        try expectSavedStroke(in: saved)
    }

    @Test("A failed save leaves the document dirty and retryable")
    func failedSaveStaysDirty() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()

        // Make the destination unwritable by replacing the directory with a file.
        try FileManager.default.removeItem(at: scratch.directory)
        try Data().write(to: scratch.directory)

        canvas(of: session).drawing = strokeAcrossPage()
        await session.saveIfNeeded()
        #expect(session.lastSaveError != nil)

        // Restore the directory; the retry must succeed with the live ink.
        try FileManager.default.removeItem(at: scratch.directory)
        try FileManager.default.createDirectory(
            at: scratch.directory,
            withIntermediateDirectories: true
        )
        await session.saveIfNeeded()

        #expect(session.lastSaveError == nil)
        try expectSavedStroke(in: await savedDrawing(scratch.store))
    }

    @Test("A transient save failure retries itself with no user action")
    func failedSaveRetriesItself() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()

        // Break the destination the way `failedSaveStaysDirty` does: the
        // containing directory becomes a file, so every save throws.
        try FileManager.default.removeItem(at: scratch.directory)
        try Data().write(to: scratch.directory)

        canvas(of: session).drawing = strokeAcrossPage()
        try await waitUntil("the first autosave fails") { session.lastSaveError != nil }

        // Long enough for several backed-off retries at a 20 ms debounce
        // (40 ms, 80 ms, 160 ms, ...), all of them still failing.
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.lastSaveError != nil)

        // Nothing below touches the session: no Retry tap, no further drawing,
        // no scene transition. Only the store starts working again.
        try FileManager.default.removeItem(at: scratch.directory)
        try FileManager.default.createDirectory(
            at: scratch.directory,
            withIntermediateDirectories: true
        )

        try await waitUntil("the retry succeeds by itself") {
            guard session.lastSaveError == nil else { return false }
            return try await savedDrawing(scratch.store) != nil
        }
        try expectSavedStroke(in: await savedDrawing(scratch.store))
    }

    @Test("Backgrounding flushes pending ink")
    func backgroundFlushSaves() async throws {
        let scratch = Scratch()
        let session = scratch.session(debounce: .seconds(30))
        await session.start()

        canvas(of: session).drawing = strokeAcrossPage()
        // The debounce is far in the future; only the flush can save this.
        await session.flushForBackground()

        try expectSavedStroke(in: await savedDrawing(scratch.store))
    }

    @Test("Backgrounding performs one save pass, never a loop")
    func backgroundFlushIsASinglePass() async throws {
        let scratch = Scratch()
        // A far-future debounce, so a timer cannot account for any save observed
        // here and the flush is the only thing that can write.
        let session = scratch.session(debounce: .seconds(30))
        await session.start()

        canvas(of: session).drawing = strokeAcrossPage()

        let flush = Task { await session.flushForBackground() }
        // One yield hands the main actor to the flush, which runs as far as its
        // first suspension — inside serialization, with one generation captured
        // and the save in flight. It cannot proceed past that without the main
        // actor, which this test holds again from here.
        await Task.yield()
        canvas(of: session).drawing = twoStrokesAcrossPage()
        await flush.value

        // Exactly one save reached the store: the generation captured when the
        // flush began. The loop this used to be would have saved the second one
        // as well, on a lease that cannot be relied on to survive it.
        let flushed = try #require(try await savedDrawing(scratch.store))
        #expect(try PKDrawing(data: flushed).strokes.count == 1)

        // The newer ink is still dirty rather than dropped, which is what
        // `resumeForForeground` retries (`DataContract.md` §6).
        await session.saveIfNeeded()
        let resumed = try #require(try await savedDrawing(scratch.store))
        #expect(try PKDrawing(data: resumed).strokes.count == 2)
    }

    @Test("The debounce never drops below the contract's 500 ms floor")
    func debounceFloorHolds() async throws {
        let scratch = Scratch()
        // The interval the app itself uses, not the tests' short one.
        let session = scratch.session(debounce: .milliseconds(500))
        await session.start()
        let initial = try await savedDrawing(scratch.store)

        canvas(of: session).drawing = strokeAcrossPage()

        // A three-stroke document serializes in microseconds, so the adaptive
        // term is ~0 and the floor is the whole interval. Nothing may save yet.
        try await Task.sleep(for: .milliseconds(250))
        #expect(try await savedDrawing(scratch.store) == initial, "a save beat the 500 ms floor")

        try await waitUntil("the floor elapses and the save lands") {
            (try await savedDrawing(scratch.store)) != initial
        }
        try expectSavedStroke(in: await savedDrawing(scratch.store))
    }

    @Test("An expensive document widens the debounce above the floor")
    func debounceWidensWithSerializeCost() async throws {
        let scratch = Scratch()
        // A negligible floor, so what is measured here is the adaptive term and
        // nothing else.
        let session = scratch.session(debounce: .milliseconds(1))
        await session.start()

        let expensive = manyStrokes(count: 20_000)

        // The yardstick, measured warm. A freshly built drawing pays one-time
        // cost on its first traversal that it never pays again — 126 ms against
        // 48 ms when this was written — and the session's own measurement is
        // always a warm one. The cold number would overstate the expected
        // interval by more than the interval itself.
        let snapshot = DrawingSnapshot(drawing: expensive)
        _ = await snapshot.serialized()
        let serializeCost = await snapshot.serialized().duration
        #expect(
            serializeCost > .milliseconds(20),
            "fixture serializes in \(serializeCost), too cheap to exercise back-off"
        )

        // One save of the expensive document, which is what teaches the session
        // how much a serialization of it costs. Called directly so that this
        // step's own timing is not part of the measurement below.
        canvas(of: session).drawing = expensive
        await session.saveIfNeeded()
        let taught = scratch.savedAt

        // Now make a cheap change. Its own save costs almost nothing, so what is
        // being timed is the scheduled interval and not the work: four times the
        // serialization the session just measured, rather than the 1 ms floor.
        //
        // Timing the two *expensive* saves against each other instead does not
        // work — the first assignment of a 20,000-stroke drawing carries one-time
        // PencilKit cost larger than the interval under test, which made an
        // earlier version of this test pass on a fixed debounce.
        let clock = ContinuousClock()
        let started = clock.now
        canvas(of: session).drawing = strokeAcrossPage()
        try await waitUntil("the debounced save lands") { scratch.savedAt != taught }
        let scheduled = started.duration(to: clock.now)

        // Expected is four serializations; asserting two leaves room for machine
        // variance while still being far above the floor a fixed debounce would
        // have used (~1 ms, verified by breaking the adaptive term).
        #expect(
            scheduled > serializeCost * 2,
            "interval \(scheduled) did not back off for a document that serializes in \(serializeCost)"
        )
    }

    // MARK: - Fixtures

    /// Polls until `condition` holds. Autosave, its retries, and the debounce are
    /// timers, so a test that asserts one fires has to wait for wall time; the
    /// alternative is a fixed sleep long enough to be slow and short enough to be
    /// flaky.
    private func waitUntil(
        _ what: String,
        within timeout: Duration = .seconds(10),
        _ condition: () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record(Comment(rawValue: "timed out waiting for: \(what)"))
    }

    /// Asserts the saved bytes reconstruct the fixture stroke.
    ///
    /// Compared by reconstructed geometry rather than by serialized bytes:
    /// `PKDrawing.dataRepresentation()` is not byte-stable across separately
    /// constructed but equal drawings, so a byte comparison would test the
    /// encoder's determinism rather than the durability the contract promises.
    /// Drives the append gesture: a deliberate pull past the last page.
    @MainActor
    private func pullPastTheEnd(_ session: EditorSession) {
        let scroll = session.pages.scrollView
        scroll.contentOffset = CGPoint(
            x: scroll.bounds.width * (CGFloat(session.pageCount) - 0.5),
            y: 0
        )
        session.pages.scrollViewDidEndDragging(scroll, willDecelerate: false)
        session.pages.view.layoutIfNeeded()
    }

    /// The live canvas of the session's current page.
    ///
    /// The paged runtime builds page canvases during layout, so a session that
    /// has never been laid out has none. Tests that touch ink go through here so
    /// that hosting is one decision in one place rather than a setup step each
    /// test can forget.
    @MainActor
    private func canvas(of session: EditorSession) -> PKCanvasView {
        let root = session.pages.view!
        if root.frame.isEmpty {
            root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        }
        root.layoutIfNeeded()
        guard let page = session.currentCanvas else {
            preconditionFailure("the paged runtime built no canvas for the current page")
        }
        return page.canvasView
    }

    /// The saved ink of the current page, or `nil` if nothing is saved yet.
    ///
    /// A free function over the store rather than a method on `Scratch`: the
    /// store is an actor and therefore `Sendable`, while `Scratch` is not, and
    /// awaiting a method on it from a `@MainActor` test would send it across an
    /// isolation boundary.
    private func savedDrawing(_ store: DocumentStore) async throws -> Data? {
        guard let index = try await store.load() else { return nil }
        return try await store.loadPage(index.pageIDs[index.currentPageIndex])
    }

    private func expectSavedStroke(in drawingData: Data?) throws {
        let restored = try PKDrawing(data: try #require(drawingData))
        #expect(restored.strokes.count == 1)
        #expect(restored.bounds == strokeAcrossPage().bounds)
    }

    private func strokeAcrossPage() -> PKDrawing {
        let locations = [
            CGPoint(x: 100, y: 150),
            CGPoint(x: 300, y: 400),
            CGPoint(x: 500, y: 650),
        ]
        let points = locations.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: Double(index) * 0.01,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
    }

    /// A second, distinguishable generation. Stroke count is what the single-pass
    /// test reads back, so the two fixtures differ in exactly that.
    private func twoStrokesAcrossPage() -> PKDrawing {
        let stroke = strokeAcrossPage().strokes[0]
        return PKDrawing(strokes: [stroke, stroke])
    }

    /// A document expensive enough to serialize that the debounce must adapt to
    /// it. Real handwriting reaches these stroke counts on a grown page, which is
    /// the situation a fixed 500 ms interval was measured against and lost.
    private func manyStrokes(count: Int) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let strokes = (0..<count).map { index in
            let y = Double(index % 700) + 40
            let points = (0..<8).map { step in
                PKStrokePoint(
                    location: CGPoint(x: 40 + Double(step) * 8, y: y),
                    timeOffset: Double(step) * 0.01,
                    size: CGSize(width: 3, height: 3),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2
                )
            }
            return PKStroke(
                ink: ink,
                path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
            )
        }
        return PKDrawing(strokes: strokes)
    }

    private final class Scratch {
        let directory: URL
        let store: DocumentStore

        var documentURL: URL { directory.appendingPathComponent("JustACanvas.tubernotes") }
        var indexURL: URL { documentURL.appendingPathComponent("document.plist") }
        var pagesURL: URL { documentURL.appendingPathComponent("pages") }

        func modificationDate(ofPage pageID: UUID) -> Date? {
            let url = pagesURL.appendingPathComponent("\(pageID.uuidString).plist")
            return try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        }

        /// When a page file was last written, or `nil` if none exists yet.
        ///
        /// Timing tests poll this rather than `store.load()`: decoding a megabyte
        /// of property list on every poll would cost more than the intervals
        /// being measured and would show up inside them.
        var savedAt: Date? {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: pagesURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            return urls.compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            }.max()
        }

        func writeGarbageIndex(_ data: Data) throws {
            try FileManager.default.createDirectory(at: pagesURL, withIntermediateDirectories: true)
            try data.write(to: indexURL)
        }

        /// The page file backing whatever page the session currently shows.
        @MainActor
        func currentPageURL(of session: EditorSession) -> URL {
            pagesURL.appendingPathComponent("\(session.currentPageID.uuidString).plist")
        }


        init() {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tubernotes-session-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            store = DocumentStore(
                directoryURL: directory.appendingPathComponent("JustACanvas.tubernotes")
            )
        }

        /// A short debounce by default: these tests assert the debounce fires,
        /// not that it waits 500 ms.
        @MainActor
        func session(debounce: Duration = .milliseconds(20)) -> EditorSession {
            EditorSession(store: store, debounce: debounce)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
