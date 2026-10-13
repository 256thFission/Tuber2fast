import Foundation
import PencilKit
import Testing
import UIKit
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook

@Suite("Notebook: the save engine")
@MainActor
struct NotebookSaveTests {
    @Test("Create, draw, flush, reopen: the ink is on disk and the page is clean")
    func createDrawFlushReopen() async throws {
        let scratch = try Scratch("nb-roundtrip")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        #expect(notebook.pageCount == 1)
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        var changes = notebook.drainChanges()
        #expect(changes.contains { if case .content(let s) = $0 { s.id == page && s.ink?.strokes.isEmpty == true && s.isEditable } else { false } })

        notebook.inkChanged(on: page, Ink.drawing(strokes: 3))
        #expect(notebook.dirtyPageCount == 1)
        await notebook.flush()
        #expect(notebook.dirtyPageCount == 0)
        #expect(notebook.lastSaveError == nil)
        changes = notebook.drainChanges()

        let reopened = try await Notebook.open(store: PackageStore(root: scratch.packageURL), schedule: fast)
        reopened.windowChanged(to: [page])
        try await waitUntil { reopened.state(of: page)?.content != nil }
        #expect(reopened.state(of: page)?.content?.ink.strokes.count == 3)
        #expect(reopened.state(of: page)?.content?.hasInk == true)
    }

    @Test("A stroke during a held save keeps the page dirty; the next pass lands it")
    func drawDuringHeldSave() async throws {
        let scratch = try Scratch("nb-held")
        let store = HeldStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }

        await store.hold()
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
        let flushing = Task { await notebook.flush() }
        try await Task.sleep(for: .milliseconds(60))   // the pass is inside the held save
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
        await store.release()
        await flushing.value
        // The first pass returned; the page edited during it is still dirty.
        #expect(notebook.state(of: page)?.content?.isDirty == true)
        await notebook.flush()
        #expect(notebook.state(of: page)?.content?.isDirty == false)
        let bytes = try await store.base.loadPage(page)
        #expect(try PKDrawing(data: try #require(bytes.inkArchive)).strokes.count == 2)
    }

    @Test("Close returns clean only after a held save completes")
    func closeWaitsForTheWrite() async throws {
        let scratch = try Scratch("nb-close")
        let store = HeldStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        await store.hold()
        notebook.inkChanged(on: page, Ink.drawing(strokes: 5))
        let closing = Task { await notebook.close() }
        // Passes without proving anything if the close has not reached the
        // held save within the sleep, as on a starved simulator.
        try await Task.sleep(for: .milliseconds(60))
        #expect(!notebook.isClosed)
        await store.release()
        #expect(await closing.value == .clean)
        #expect(notebook.isClosed)
        #expect(try await store.base.loadPage(page).inkArchive != nil)
    }

    @Test("A failed save keeps the page dirty and names the fault; the pass it re-arms lands the ink without a flush")
    func aFailingSaveStaysDirtyAndRetries() async throws {
        let scratch = try Scratch("nb-save-fails")
        let store = FailingSaveStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        // Refused before the stroke, so its debounce cannot land a pass first.
        await store.refuse()
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
        await notebook.flush()
        #expect(notebook.lastSaveError == .io(.corruptJSON("refused by the test")))
        #expect(notebook.state(of: page)?.content?.isDirty == true)

        await store.accept()
        try await waitUntil { notebook.state(of: page)?.content?.isDirty == false }
        #expect(notebook.lastSaveError == nil)
        let bytes = try await store.base.loadPage(page)
        #expect(try PKDrawing(data: try #require(bytes.inkArchive)).strokes.count == 2)
    }

    @Test("A close whose pass fails reports the dirty page and leaves the notebook open; the close after recovery is clean")
    func aDirtyCloseReportsItsPages() async throws {
        let scratch = try Scratch("nb-dirty-close")
        let store = FailingSaveStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        await store.refuse()
        notebook.inkChanged(on: page, Ink.drawing(strokes: 3))
        #expect(await notebook.close() == .dirty(pages: [page], indexUnsaved: false))
        #expect(!notebook.isClosed)

        // The close runs its own pass rather than waiting for the re-armed one.
        await store.accept()
        #expect(await notebook.close() == .clean)
        #expect(notebook.isClosed)
        let bytes = try await store.base.loadPage(page)
        #expect(try PKDrawing(data: try #require(bytes.inkArchive)).strokes.count == 3)
    }

    /// Every other test runs the engine at `fast`, and the bound tests read
    /// the constants back; this is where `Docs/Contract.md`'s numbers are
    /// written out.
    @Test("The save schedule and the undo bounds are the Contract's numbers")
    func theContractsNumbers() {
        let schedule = SaveSchedule()
        #expect(schedule.idleFloor == .milliseconds(500))
        #expect(schedule.idleCeiling == .seconds(2))
        #expect(schedule.serializeFactor == 4)
        #expect(schedule.dirtyCeiling == .seconds(5))
        #expect(schedule.backoffCap == .seconds(5))
        #expect(schedule.retryBufferBytes == 64 * 1024 * 1024)
        #expect(EditHistory.maximumEntries == 100)
        #expect(EditHistory.maximumBytes == 64 * 1024 * 1024)
    }

    @Test("A load that lands after a clean close installs nothing and arms no save")
    func aLoadAfterCloseIsDropped() async throws {
        let scratch = try Scratch("nb-load-after-close")
        let base = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1))
        let index = try await base.load().index
        let page = index.pageIDs[0]
        // A container the page file does not record: the load adopts it and
        // marks the page dirty, so a load that installed would save.
        try InkContainer.encode(notebookID: index.notebookID, pageID: page, archive: Ink.drawing(strokes: 1).dataRepresentation())
            .write(to: base.layout.inkURL(page))
        let pageFile = try Data(contentsOf: base.layout.pageURL(page))
        let store = HeldLoadStore(base)
        let notebook = try await Notebook.open(store: store, schedule: fast)
        await store.hold()
        notebook.windowChanged(to: [page])
        #expect(await notebook.close() == .clean)

        await store.release()
        for load in notebook.loads.values { await load.value }
        #expect(notebook.state(of: page)?.content == nil, "the load installed nothing")
        #expect(notebook.debounce == nil && notebook.currentSave == nil, "and armed no save")
        #expect(try Data(contentsOf: base.layout.pageURL(page)) == pageFile)
    }

    @Test("A page change after a clean close arms no view write")
    func aPageChangeAfterCloseWritesNoView() async throws {
        let scratch = try Scratch("nb-view-after-close")
        let notebook = try await Notebook.open(
            store: try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 3)),
            schedule: fast)
        #expect(await notebook.close() == .clean)

        notebook.pageBecameCurrent(notebook.pageIDs[1])
        #expect(notebook.viewWrite == nil, "turning the page wrote view.json")
        notebook.deletePage(notebook.currentPageID)
        #expect(notebook.viewWrite == nil, "deleting the current page wrote view.json")
    }

    @Test("A scan that close cuts off between two asset writes writes no second asset")
    func anAssetWriteAfterCloseIsRefused() async throws {
        let scratch = try Scratch("nb-asset-after-close")
        defer { withExtendedLifetime(scratch) {} }
        let store = HeldAssetStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let image = try Fixture.imageData(width: 200, height: 100)
        await store.hold()
        let scan = Task { try await notebook.importScan([image, image]) }
        try await notebook.waitForArrivals(store.gate, 1)
        #expect(await notebook.close() == .clean)

        await store.release()
        await #expect(throws: FormatFault.self) { try await scan.value }
        #expect(await store.gate.arrivals == 1, "the second write reached the store")
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.base.layout.assetsDirectory.path).count == 1)
    }

    @Test("A discard while a close awaits its pass ends the close: no view.json, and clean")
    func aDiscardDuringCloseEndsIt() async throws {
        let scratch = try Scratch("nb-discard-during-close")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1))
        // The pass fails, so a close that went on would answer dirty. The
        // default debounce is long, so only the close's flush runs a pass.
        let store = HeldStore(PackageStore(root: scratch.packageURL, fileSystem: FaultingFileSystem(faults: [.failStage(nth: 1)])))
        let notebook = try await Notebook.open(store: store)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        await store.hold()
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
        let closing = Task { await notebook.close() }
        try await notebook.waitForArrivals(store.gate, 1)
        let discarding = Task { await notebook.discard() }
        try await waitUntil { notebook.isClosed }

        await store.release()
        #expect(await closing.value == .clean)
        await discarding.value
        #expect(!FileManager.default.fileExists(atPath: store.base.layout.viewURL.path), "the close wrote view.json")
    }

    @Test("A refused new page is absent from the committed index and stays dirty in memory")
    func refusedNewPageStaysDirty() async throws {
        let scratch = try Scratch("nb-refused")
        let base = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1))
        let notebook = try await Notebook.open(store: RefusingNewPagesStore(base), schedule: fast)
        let first = notebook.pageIDs[0]
        notebook.windowChanged(to: [first])
        try await waitUntil { notebook.state(of: first)?.content != nil }
        notebook.inkChanged(on: first, Ink.drawing(strokes: 1))
        let refusedPage = notebook.appendPage()
        await notebook.flush()
        if case .pagesRefused(let refused) = notebook.lastSaveError { #expect(refused.keys.contains(refusedPage)) } else { Issue.record("expected pagesRefused, got \(String(describing: notebook.lastSaveError))") }
        #expect(notebook.state(of: refusedPage)?.content?.isDirty == true, "the refused page stays dirty")
        #expect(notebook.state(of: first)?.content?.isDirty == false, "the other page committed")
        let onDisk = try await PackageStore(root: scratch.packageURL).load()
        #expect(onDisk.index.pageIDs == [first], "the index names only what is present")
        #expect(onDisk.pageFaults.isEmpty)
        #expect(notebook.pageIDs == [first, refusedPage], "the intent survives in memory")
    }

    @Test("A page the store will refuse again is serialized once, and later passes write the same bytes")
    func aPermanentRefusalIsSerializedOnce() async throws {
        let scratch = try Scratch("nb-refused-permanently")
        let base = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1))
        let page = try await base.load().index.pageIDs[0]
        let store = PermanentlyRefusingStore(base, refusing: page)
        // The default debounce is long, so the flushes run the passes.
        let notebook = try await Notebook.open(store: store)
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 3))
        for _ in 0..<3 { await notebook.flush() }
        #expect(notebook.state(of: page)?.content?.isDirty == true, "a refused page stays dirty")
        #expect(store.archives.count >= 3)
        // A fresh encoding is a fresh buffer; reused bytes share the first.
        let buffers = Set(store.archives.map { $0.withUnsafeBytes { Int(bitPattern: $0.baseAddress) } })
        #expect(buffers.count == 1, "every pass after the first reused the first pass's bytes")
    }

    @Test("A page the written index left out is named by the index the pass that lands its file writes")
    func aPageLeftOutOfTheIndexIsWrittenOnTheRetry() async throws {
        let scratch = try Scratch("nb-omitted")
        let index = Fixture.index(pages: 1)
        _ = try await PackageStore.create(root: scratch.packageURL, index: index)
        // The first file this store stages is the new page's ink container.
        let store = PackageStore(root: scratch.packageURL, fileSystem: FaultingFileSystem(faults: [.failStage(nth: 1)]))
        // The default debounce is long, so only the two flushes run passes.
        let notebook = try await Notebook.open(store: store)
        let page = notebook.appendPage()
        notebook.inkChanged(on: page, Ink.drawing(strokes: 3))
        await notebook.flush()
        if case .pagesRefused(let refused) = notebook.lastSaveError { #expect(refused.keys.contains(page)) } else { Issue.record("expected pagesRefused, got \(String(describing: notebook.lastSaveError))") }
        #expect(try await PackageStore(root: scratch.packageURL).load().index.pageIDs == index.pageIDs, "the first index left the page out")
        await notebook.flush()
        let onDisk = PackageStore(root: scratch.packageURL)
        #expect(try await onDisk.load().index.pageIDs == index.pageIDs + [page])
        #expect(try PKDrawing(data: try #require(try await onDisk.loadPage(page).inkArchive)).strokes.count == 3)
        #expect(await notebook.close() == .clean)
    }

    @Test("A page whose file is missing never holds the index owed")
    func aMissingPageFileDoesNotWedgeTheIndex() async throws {
        let scratch = try Scratch("nb-missing-page")
        let index = Fixture.index(pages: 2)
        let store = try await PackageStore.create(root: scratch.packageURL, index: index)
        try FileManager.default.removeItem(at: store.layout.pageURL(index.pageIDs[1]))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        if case .unreadable = notebook.state(of: index.pageIDs[1])! {} else { Issue.record("expected a placeholder, got \(String(describing: notebook.state(of: index.pageIDs[1])))") }
        notebook.bookmark(index.pageIDs[0], titled: "Week one")
        await notebook.flush()
        #expect(try await PackageStore(root: scratch.packageURL).load().index.bookmarks.map(\.page) == [index.pageIDs[0]])
        #expect(await notebook.close() == .clean)
    }
}
