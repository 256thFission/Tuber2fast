import Foundation
import PencilKit
import Testing
@testable import TuberCanvas
@testable import TuberModel
@testable import TuberNotes
@testable import TuberStore

/// Behavior of the session's teardown and of open intent — the two halves of
/// `Docs/Contract.proposed.md` L4: `close()` releases a package only when
/// nothing is dirty, and opening an enumerated package never creates.
@Suite("Editor session close", .serialized)
@MainActor
struct EditorSessionCloseTests {
    // MARK: - close()

    @Test("close() awaits a save already in flight rather than racing it")
    func closeAwaitsAnInFlightSave() async throws {
        let scratch = try TestScratch("close")
        let held = HeldSaveStore(scratch.store)
        // A far-future debounce: the explicit save below is the only pass a
        // timer cannot account for.
        let session = scratch.session(debounce: .seconds(30), store: held)
        await session.start()
        try await canvas(of: session).drawing = strokeAcrossPage()

        await held.hold()
        let save = Task { await session.saveIfNeeded() }
        await Task.yield()

        let closed = Flag()
        let closing = Task { () -> CloseOutcome in
            let outcome = await session.close()
            closed.isSet = true
            return outcome
        }
        for _ in 0..<20 { await Task.yield() }
        // The store has not returned, so the teardown cannot have: a close
        // that returned here released a package with a write still in it.
        #expect(!closed.isSet)

        await held.release()
        await save.value
        #expect(await closing.value == .clean)
        try expectSavedStroke(in: await savedDrawing(scratch.store))
    }

    @Test("close() runs a final pass for ink no save has captured yet")
    func closeLandsUncapturedInk() async throws {
        let scratch = try TestScratch("close")
        // No timer can fire before the close, so the ink below is dirty and
        // un-captured — live in its canvas — when the teardown begins.
        let session = scratch.session(debounce: .seconds(30))
        await session.start()
        try await canvas(of: session).drawing = strokeAcrossPage()

        #expect(await session.close() == .clean)

        // A fresh store, so the assertion is about disk and not about any
        // in-memory record the session's own store kept.
        try expectSavedStroke(in: await savedDrawing(scratch.freshStore()))
    }

    @Test("close() during .loading awaits the protected start, never cancels it")
    func closeDuringLoadingAwaitsTheStart() async throws {
        let scratch = try TestScratch("close")
        let first = scratch.session()
        await first.start()
        try await canvas(of: first).drawing = strokeAcrossPage()
        await first.saveIfNeeded()

        let held = HeldLoadStore(scratch.freshStore())
        let session = scratch.session(store: held, intent: .openExisting)
        await held.hold()
        let starting = Task { await session.start() }
        for _ in 0..<5 { await Task.yield() }
        #expect(session.phase == .loading)

        let closed = Flag()
        let closing = Task { () -> CloseOutcome in
            let outcome = await session.close()
            closed.isSet = true
            return outcome
        }
        for _ in 0..<20 { await Task.yield() }
        // The load is still held, so the start has not completed and the
        // close must still be waiting on it (`03-review.md` B1).
        #expect(!closed.isSet)

        await held.release()
        await starting.value
        #expect(await closing.value == .clean)
        // No torn state: the start ran to completion under the close, and the
        // document reads back whole.
        #expect(session.phase == .ready)
        try expectSavedStroke(in: await savedDrawing(scratch.freshStore()))
    }

    @Test("A failing final save closes dirty, and the retained session drains itself")
    func failingFinalSaveClosesDirtyAndDrains() async throws {
        let scratch = try TestScratch("close")
        let session = scratch.session(debounce: .seconds(30))
        await session.start()
        try await canvas(of: session).drawing = strokeAcrossPage()

        // Break the destination the way `failedSaveStaysDirty` does: the
        // containing directory becomes a file, so the final pass throws.
        try FileManager.default.removeItem(at: scratch.root)
        try Data().write(to: scratch.root)

        let outcome = await session.close()
        guard case .dirty = outcome else {
            Issue.record("expected .dirty from a failing final pass, got \(outcome)")
            return
        }
        #expect(session.lastSaveError != nil)

        // Heal the store and touch nothing else: no Retry tap, no drawing, no
        // scene transition. The retry the failed pass armed at its own exit
        // must drain the session by itself — the mechanical half of
        // retain-if-dirty (`03-review.md` B3).
        try FileManager.default.removeItem(at: scratch.root)
        try FileManager.default.createDirectory(
            at: scratch.root,
            withIntermediateDirectories: true
        )
        try await waitUntil("the retained session drains itself clean") {
            guard session.lastSaveError == nil else { return false }
            return try await savedDrawing(scratch.freshStore()) != nil
        }
        try expectSavedStroke(in: await savedDrawing(scratch.freshStore()))

        // A later close finds the drain done and reports it, still without a
        // second teardown.
        #expect(await session.close() == .clean)
    }

    @Test("A session that closed clean refuses edits and writes nothing")
    func editsAfterACleanCloseAreRefused() async throws {
        let scratch = try TestScratch("close")
        let session = scratch.session(debounce: .seconds(30))
        await session.start()
        let canvasView = try await canvas(of: session)
        canvasView.drawing = strokeAcrossPage()

        #expect(await session.close() == .clean)
        try scratch.freezeTimestamps()

        // The change callback fires synchronously on assignment — the same
        // path a live Pencil edit takes — and must dirty nothing.
        canvasView.drawing = twoStrokesAcrossPage()
        session.resumeForForeground()
        await #expect(throws: LayerEditError.sessionNotReady) {
            try await session.importImage(
                TestScratch.solidHEIC(width: 8, height: 8, color: UIColor.red),
                format: .heic,
                sourceWidth: 8,
                sourceHeight: 8
            )
        }
        // Harmless by design — a subset of the teardown — and the last thing
        // that could possibly write.
        await session.flushForBackground()

        #expect(try scratch.filesWrittenSinceFreeze().isEmpty)
    }

    @Test("Two concurrent close() calls share one teardown")
    func closeIsIdempotent() async throws {
        let scratch = try TestScratch("close")
        let counting = CountingStore(scratch.store)
        let session = scratch.session(debounce: .seconds(30), store: counting)
        await session.start()
        try await canvas(of: session).drawing = strokeAcrossPage()

        let first = Task { await session.close() }
        let second = Task { await session.close() }

        #expect(await first.value == .clean)
        #expect(await second.value == .clean)
        // The launch's create and the teardown's one final pass. A second
        // teardown would have asked the store again.
        #expect(await counting.saveCount() == 2)
        try expectSavedStroke(in: await savedDrawing(scratch.store))
    }

    // MARK: - Open intent

    @Test("openExisting refuses a package with no index, byte-identical")
    func openExistingRefusesAMissingIndex() async throws {
        let scratch = try TestScratch("close")
        // The scratch is an enumerable package sans index: the directory and
        // its `pages/` and `layers/` exist, `document.plist` does not — a torn
        // copy or a damaged restore, as the browser would meet it.
        let structureBefore = try FileManager.default
            .subpathsOfDirectory(atPath: scratch.documentURL.path).sorted()
        let filesBefore = try scratch.snapshot()

        let session = scratch.session(intent: .openExisting)
        await session.start()

        #expect(session.phase == .failed("This document has no index."))
        #expect(try FileManager.default
            .subpathsOfDirectory(atPath: scratch.documentURL.path).sorted()
            == structureBefore)
        #expect(try scratch.snapshot() == filesBefore)
        // And closing the refused session is clean: it holds nothing.
        #expect(await session.close() == .clean)
    }

    @Test("openExisting opens a valid document normally")
    func openExistingOpensAValidDocument() async throws {
        let scratch = try TestScratch("close")
        let first = scratch.session()
        await first.start()
        try await canvas(of: first).drawing = strokeAcrossPage()
        await first.saveIfNeeded()

        let second = scratch.session(store: scratch.freshStore(), intent: .openExisting)
        await second.start()

        #expect(second.phase == .ready)
        #expect(try await canvas(of: second).drawing.strokes.count == 1)
    }

    @Test("createIfAbsent still creates on nil — the pre-library behavior")
    func createIfAbsentCreatesOnNil() async throws {
        let scratch = try TestScratch("close")
        let session = scratch.session(intent: .createIfAbsent)
        await session.start()

        #expect(session.phase == .ready)
        let index = try #require(await scratch.store.load())
        #expect(index.pageIDs == [session.currentPageID])
    }

    // MARK: - Fixtures

    /// A completion marker a test can read from the main actor while the task
    /// that sets it is still awaited elsewhere.
    @MainActor
    private final class Flag {
        var isSet = false
    }

    /// Polls until `condition` holds, exactly as `EditorSessionTests` does:
    /// the drain under test is a real timer, so wall time is what is waited on.
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

    /// The live canvas of the session's current page — the same hosting step
    /// `EditorSessionTests` takes, for the same reason: the paged runtime
    /// builds canvases during layout, and a session never laid out has none.
    @MainActor
    private func canvas(of session: EditorSession) async throws -> PKCanvasView {
        let root = session.pages.view!
        if root.frame.isEmpty {
            root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        }
        root.layoutIfNeeded()
        for _ in 0..<200 {
            if let page = session.currentCanvas { return page.canvasView }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("the paged runtime built no canvas for the current page")
    }

    private func savedDrawing(_ store: DocumentStore) async throws -> Data? {
        guard let index = try await store.load() else { return nil }
        return try await store.loadPage(index.pageIDs[index.currentPageIndex]).inkData
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

    private func twoStrokesAcrossPage() -> PKDrawing {
        let stroke = strokeAcrossPage().strokes[0]
        return PKDrawing(strokes: [stroke, stroke])
    }
}

/// What only this suite adds to the scratch: a session whose open intent is
/// the test's choice.
private extension TestScratch {
    @MainActor
    func session(
        debounce: Duration = .milliseconds(20),
        store: (any DocumentStoring)? = nil,
        intent: OpenIntent = .createIfAbsent
    ) -> EditorSession {
        EditorSession(store: store ?? self.store, intent: intent, debounce: debounce)
    }
}

/// `HeldSaveStore`'s idiom pointed at the other end of the session: its `load`
/// can be held open, so a start is genuinely in flight while a test closes the
/// session over it. Everything else forwards untouched.
private final class HeldLoadStore: DocumentStoring {
    private let underlying: DocumentStore
    private let gate = Gate()

    init(_ underlying: DocumentStore) {
        self.underlying = underlying
    }

    func hold() async {
        await gate.close()
    }

    func release() async {
        await gate.open()
    }

    func load() async throws -> DocumentIndex? {
        await gate.wait()
        return try await underlying.load()
    }

    func loadPage(_ pageID: UUID) async throws -> LoadedPage {
        try await underlying.loadPage(pageID)
    }

    func save(index: DocumentIndex, pages: [PageWrite]) async throws {
        try await underlying.save(index: index, pages: pages)
    }

    func writeAsset(_ bytes: Data, assetID: UUID, format: AssetFormat) async throws {
        try await underlying.writeAsset(bytes, assetID: assetID, format: format)
    }

    func loadAsset(assetID: UUID, format: AssetFormat) async throws -> Data {
        try await underlying.loadAsset(assetID: assetID, format: format)
    }

    @discardableResult
    func deletePageFileIfUnreferenced(pageID: UUID) async throws -> Bool {
        try await underlying.deletePageFileIfUnreferenced(pageID: pageID)
    }

    @discardableResult
    func deleteLayerFileIfUnreferenced(layerID: UUID) async throws -> Bool {
        try await underlying.deleteLayerFileIfUnreferenced(layerID: layerID)
    }

    @discardableResult
    func deleteAssetIfUnreferenced(assetID: UUID, format: AssetFormat) async throws -> Bool {
        try await underlying.deleteAssetIfUnreferenced(assetID: assetID, format: format)
    }

    private actor Gate {
        private var isOpen = true
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func close() { isOpen = false }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

/// Counts how many times the store was asked to save, so "one teardown" is a
/// fact about the store rather than an inference about tasks.
private final class CountingStore: DocumentStoring {
    private let underlying: DocumentStore
    private let counter = Counter()

    init(_ underlying: DocumentStore) {
        self.underlying = underlying
    }

    func saveCount() async -> Int {
        await counter.value
    }

    func save(index: DocumentIndex, pages: [PageWrite]) async throws {
        await counter.increment()
        try await underlying.save(index: index, pages: pages)
    }

    func load() async throws -> DocumentIndex? {
        try await underlying.load()
    }

    func loadPage(_ pageID: UUID) async throws -> LoadedPage {
        try await underlying.loadPage(pageID)
    }

    func writeAsset(_ bytes: Data, assetID: UUID, format: AssetFormat) async throws {
        try await underlying.writeAsset(bytes, assetID: assetID, format: format)
    }

    func loadAsset(assetID: UUID, format: AssetFormat) async throws -> Data {
        try await underlying.loadAsset(assetID: assetID, format: format)
    }

    @discardableResult
    func deletePageFileIfUnreferenced(pageID: UUID) async throws -> Bool {
        try await underlying.deletePageFileIfUnreferenced(pageID: pageID)
    }

    @discardableResult
    func deleteLayerFileIfUnreferenced(layerID: UUID) async throws -> Bool {
        try await underlying.deleteLayerFileIfUnreferenced(layerID: layerID)
    }

    @discardableResult
    func deleteAssetIfUnreferenced(assetID: UUID, format: AssetFormat) async throws -> Bool {
        try await underlying.deleteAssetIfUnreferenced(assetID: assetID, format: format)
    }

    private actor Counter {
        private(set) var value = 0

        func increment() { value += 1 }
    }
}
