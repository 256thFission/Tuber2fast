import Foundation
import PencilKit
import Testing
import UIKit
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook

/// Forwards every `PackageStoring` call to a real store. The doubles below
/// override exactly the one method they exist to bend.
class ForwardingStore: PackageStoring, @unchecked Sendable {
    let base: PackageStore
    init(_ base: PackageStore) { self.base = base }
    func load() async throws(FormatFault) -> LoadedNotebook { try await base.load() }
    func loadPage(_ page: PageID) async throws(FormatFault) -> PageBytes { try await base.loadPage(page) }
    func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport { try await base.save(batch) }
    func writeAsset(_ data: Data, _ ref: AssetRef) async throws(FormatFault) { try await base.writeAsset(data, ref) }
    func readAsset(_ ref: AssetRef) async throws(FormatFault) -> Data { try await base.readAsset(ref) }
    func readView() async -> ViewState? { await base.readView() }
    func writeView(_ view: ViewState) async throws(FormatFault) { try await base.writeView(view) }
}

/// A real store whose `save` waits until released.
final class HeldStore: ForwardingStore, @unchecked Sendable {
    private let gate = Gate()
    func hold() async { await gate.close() }
    func release() async { await gate.open() }
    override func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport {
        await gate.wait()
        return try await base.save(batch)
    }
}

/// A real store whose `loadPage` waits until released, so a page can be
/// held in `.loading` for as long as a test needs.
final class HeldLoadStore: ForwardingStore, @unchecked Sendable {
    private let gate = Gate()
    func hold() async { await gate.close() }
    func release() async { await gate.open() }
    override func loadPage(_ page: PageID) async throws(FormatFault) -> PageBytes {
        await gate.wait()
        return try await base.loadPage(page)
    }
}

actor Gate {
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func close() { isOpen = false }
    func open() {
        isOpen = true
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume() }
    }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Drops every write for a page that has no file yet, so the real store
/// commits an index without it, then reports it refused: a refused *new*
/// page, whatever its identity.
final class RefusingNewPagesStore: ForwardingStore, @unchecked Sendable {
    override func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport {
        let fs = PosixFileSystem()
        let isNew: (PageWrite) -> Bool = { !fs.exists(self.base.layout.pageURL($0.pageID)) }
        let refusedIDs = batch.pages.filter(isNew).map(\.pageID)
        let filtered = SaveBatch(index: batch.index, indexChanged: batch.indexChanged, pages: batch.pages.filter { !isNew($0) })
        let report = try await base.save(filtered)
        var refusals = report.refusals
        for id in refusedIDs { refusals[id] = .encodeFailed("refused by the test") }
        return SaveReport(committed: report.committed, refusals: refusals, indexWritten: report.indexWritten, indexWithheld: report.indexWithheld)
    }
}

enum Ink {
    static func drawing(strokes: Int, seed: Double = 0) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let all = (0..<strokes).map { i -> PKStroke in
            let points = (0..<4).map { j in
                PKStrokePoint(location: CGPoint(x: 10 + Double(j) * 20 + seed, y: 10 + Double(i) * 15), timeOffset: Double(j) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        return PKDrawing(strokes: all)
    }
}

var fast: SaveSchedule {
    var schedule = SaveSchedule()
    schedule.idleFloor = .milliseconds(10)
    schedule.idleCeiling = .milliseconds(20)
    schedule.backoffCap = .milliseconds(50)
    return schedule
}

@MainActor
func waitUntil(_ timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        try #require(clock.now < deadline, "timed out")
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("Notebook: custody and the save engine")
@MainActor
struct NotebookTests {
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

        notebook.inkChanged(on: page, Ink.drawing(strokes: 3), echoOf: nil)
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
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil)
        let flushing = Task { await notebook.flush() }
        try await Task.sleep(for: .milliseconds(60))   // the pass is inside the held save
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2), echoOf: nil)
        await store.release()
        await flushing.value
        // The first pass returned; the page edited during it is still dirty.
        #expect(notebook.state(of: page)?.content?.isDirty == true)
        await notebook.flush()
        #expect(notebook.state(of: page)?.content?.isDirty == false)
        let bytes = try await store.base.loadPage(page)
        #expect(try PKDrawing(data: try #require(bytes.inkArchive)).strokes.count == 2)
    }

    @Test("Close returns clean only after a held save completes, and reports dirty pages otherwise")
    func closeWaitsForTheWrite() async throws {
        let scratch = try Scratch("nb-close")
        let store = HeldStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        await store.hold()
        notebook.inkChanged(on: page, Ink.drawing(strokes: 5), echoOf: nil)
        let closing = Task { await notebook.close() }
        try await Task.sleep(for: .milliseconds(60))
        #expect(!notebook.isClosed)
        await store.release()
        #expect(await closing.value == .clean)
        #expect(notebook.isClosed)
        #expect(try await store.base.loadPage(page).inkArchive != nil)
    }

    @Test("Undo restores the prior value without the echo counting as an edit; redo returns")
    func undoWithoutEcho() async throws {
        let scratch = try Scratch("nb-undo")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        _ = notebook.drainChanges()
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil)
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2), echoOf: nil)
        let editSeqBefore = notebook.state(of: page)!.content!.editSeq
        #expect(notebook.undo() == page)
        let changes = notebook.drainChanges()
        guard case .inkRestored(let restoredPage, let ink, let seq) = try #require(changes.last) else { Issue.record("no restore"); return }
        #expect(restoredPage == page && ink.strokes.count == 1)
        // The runtime reports PencilKit's callback for the programmatic set.
        notebook.inkChanged(on: page, ink, echoOf: seq)
        #expect(notebook.state(of: page)!.content!.editSeq == editSeqBefore + 1, "the echo is not an edit")
        #expect(notebook.state(of: page)!.content!.ink.strokes.count == 1)
        #expect(notebook.canRedo)
        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)!.content!.ink.strokes.count == 2)
        #expect(!notebook.canRedo)
    }

    @Test("Undo survives a page leaving the window: the stack is the notebook's and the page comes back")
    func undoAcrossPages() async throws {
        let scratch = try Scratch("nb-undo-pages")
        let store = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 2))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let (a, b) = (notebook.pageIDs[0], notebook.pageIDs[1])
        notebook.windowChanged(to: [a, b])
        try await waitUntil { notebook.state(of: a)?.content != nil && notebook.state(of: b)?.content != nil }
        notebook.inkChanged(on: a, Ink.drawing(strokes: 1), echoOf: nil)
        notebook.inkChanged(on: b, Ink.drawing(strokes: 2), echoOf: nil)
        await notebook.flush()
        // Page a leaves the window and is pruned; its history entry survives.
        notebook.windowChanged(to: [b])
        notebook.retired(a, finalInk: nil)
        notebook.prune()
        if case .unloaded = notebook.state(of: a)! {} else { Issue.record("a should be pruned") }
        #expect(notebook.undo() == b, "the newest edit is on b")
        #expect(notebook.state(of: b)?.content?.ink.strokes.isEmpty == true)
        #expect(notebook.undo() == a, "the older edit is on a, which is not loaded")
        try await waitUntil { notebook.state(of: a)?.content != nil }
        #expect(notebook.state(of: a)?.content?.ink.strokes.isEmpty == true, "restored on arrival")
        #expect(notebook.state(of: a)?.content?.isDirty == true)
        #expect(notebook.redo() == a)
        #expect(notebook.state(of: a)?.content?.ink.strokes.count == 1)
    }

    @Test("A load whose page left the window is dropped on arrival")
    func staleLoadIsDropped() async throws {
        let scratch = try Scratch("nb-stale")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        notebook.windowChanged(to: [])
        try await Task.sleep(for: .milliseconds(100))
        if case .unloaded = notebook.state(of: page)! {} else { Issue.record("expected unloaded, got \(String(describing: notebook.state(of: page)))") }
        #expect(!notebook.drainChanges().contains { if case .content = $0 { true } else { false } })
    }

    @Test("A refused new page is absent from the committed index and stays dirty in memory")
    func refusedNewPageStaysDirty() async throws {
        let scratch = try Scratch("nb-refused")
        let base = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1))
        let notebook = try await Notebook.open(store: RefusingNewPagesStore(base), schedule: fast)
        let first = notebook.pageIDs[0]
        notebook.windowChanged(to: [first])
        try await waitUntil { notebook.state(of: first)?.content != nil }
        notebook.inkChanged(on: first, Ink.drawing(strokes: 1), echoOf: nil)
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

    @Test("Prune drops only pages that are retired, outside the window, and clean")
    func pruneIsConservative() async throws {
        let scratch = try Scratch("nb-prune")
        let base = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 3))
        let notebook = try await Notebook.open(store: base, schedule: fast)
        let ids = notebook.pageIDs
        notebook.windowChanged(to: ids)
        try await waitUntil { ids.allSatisfy { notebook.state(of: $0)?.content != nil } }
        notebook.inkChanged(on: ids[1], Ink.drawing(strokes: 1), echoOf: nil)
        notebook.windowChanged(to: [ids[2]])
        notebook.retired(ids[0], finalInk: nil)
        notebook.retired(ids[1], finalInk: nil)
        notebook.prune()
        if case .unloaded = notebook.state(of: ids[0])! {} else { Issue.record("clean retired page not pruned") }
        #expect(notebook.state(of: ids[1])?.content != nil, "dirty page kept")
        #expect(notebook.state(of: ids[2])?.content != nil, "wanted page kept")
    }

    @Test("Structure intentions dirty the index and emit a structure change; a page turn dirties nothing")
    func structureAndTurns() async throws {
        let scratch = try Scratch("nb-structure")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        _ = notebook.drainChanges()
        let first = notebook.pageIDs[0]
        let second = notebook.appendPage()
        #expect(notebook.pageCount == 2)
        #expect(notebook.isDirty)
        let changes = notebook.drainChanges()
        #expect(changes.contains { if case .structure(let pages, _, _) = $0 { pages.map(\.id) == [first, second] } else { false } })
        await notebook.flush()
        #expect(!notebook.isDirty)
        notebook.pageBecameCurrent(second)
        #expect(!notebook.isDirty)
        #expect(notebook.currentPageID == second)
        let reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.index.pageIDs == [first, second])
        #expect(reopened.index.pages[1].paper == .known(.drawn(.blank)))

        try await notebook.setPaper(.drawn(.grid), on: second)
        notebook.movePage(second, before: first)
        await notebook.flush()
        var again = try await PackageStore(root: scratch.packageURL).load()
        #expect(again.index.pageIDs == [second, first])
        #expect(again.index.pages[0].paper == .known(.drawn(.grid)))
        notebook.deletePage(second)
        #expect(notebook.currentPageID == first)
        await notebook.flush()
        again = try await PackageStore(root: scratch.packageURL).load()
        #expect(again.index.pageIDs == [first])
    }

    @Test("Deleting the current page makes its successor at the same position current, clamped at the end")
    func deleteSuccessorIsClamped() async throws {
        let scratch = try Scratch("nb-delete-successor")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let first = notebook.pageIDs[0]
        let second = notebook.appendPage()
        let third = notebook.appendPage()
        notebook.pageBecameCurrent(second)
        notebook.deletePage(second)
        #expect(notebook.currentPageID == third, "the page that slid into the deleted page's position")
        notebook.deletePage(third)
        #expect(notebook.currentPageID == first, "the last page went; the new last page is current")
        notebook.deletePage(first)
        #expect(notebook.pageIDs == [first], "the only page cannot be deleted")
    }

    // The content version has no choke point; this list is the invariant's
    // enforcement. A mutation that changes what a page looks like and is
    // missing here is a test to add, not a runtime check.
    @Test("The content version rises on every change to a page's picture and on nothing else")
    func contentVersionBumpSites() async throws {
        let scratch = try Scratch("nb-version")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        #expect(notebook.contentVersion(of: page) == 0, "a page never changed in this session")
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        var version = notebook.contentVersion(of: page)
        func expectBump(_ what: String) {
            let now = notebook.contentVersion(of: page)
            #expect(now == version + 1, "\(what) should bump once, went \(version) to \(now)")
            version = now
        }
        func expectSame(_ what: String) {
            #expect(notebook.contentVersion(of: page) == version, "\(what) is not a change to the page")
        }

        _ = notebook.drainChanges()
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil)
        expectBump("ink")
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2), echoOf: nil)
        expectBump("ink again")
        notebook.undo()
        expectBump("undo into a loaded page")
        guard case .inkRestored(_, let ink, let seq) = try #require(notebook.drainChanges().last) else { Issue.record("no restore"); return }
        notebook.inkChanged(on: page, ink, echoOf: seq)
        expectSame("the echo")
        try await notebook.setPaper(.drawn(.grid), on: page)
        expectBump("paper")
        try await notebook.addTextLayer(on: page, rect: PageRect(x: 10, y: 10, width: 100, height: 40), runs: [TextRun(string: "t")])
        expectBump("a text layer added")
        // Text refuses a transform; an image layer takes one.
        let layer = Fixture.imageLayer()
        try await notebook.addLayer(layer, assetData: Fixture.archive(1, count: 128), on: page)
        expectBump("an image layer added")
        #expect(notebook.transformLayer(on: page, layer: layer.id, to: .translation(x: 1, y: 1)) == .accepted)
        expectBump("a layer moved")
        notebook.deleteLayer(layer.id, on: page)
        expectBump("a layer deleted")

        let second = notebook.appendPage()
        expectSame("another page appended")
        #expect(notebook.contentVersion(of: second) == 1, "creation is the new page's first version")
        notebook.pageBecameCurrent(second)
        expectSame("a page turn")
        notebook.movePage(second, before: page)
        expectSame("a reorder")
        notebook.windowChanged(to: [second])
        expectSame("leaving the window")

        await notebook.flush()
        notebook.retired(page, finalInk: nil)
        notebook.prune()
        if case .unloaded = notebook.state(of: page)! {} else { Issue.record("page should be pruned") }
        expectSame("unload")
        notebook.windowChanged(to: [page, second])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        expectSame("reload")
    }

    @Test("A thumbnail of an unloaded page comes from its files and installs nothing")
    func thumbnailOfUnloadedPage() async throws {
        let scratch = try Scratch("nb-thumb-unloaded")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil)
        await notebook.flush()
        _ = await notebook.close()

        let reopened = try await Notebook.open(store: PackageStore(root: scratch.packageURL), schedule: fast)
        let image = try #require(await reopened.thumbnail(of: page))
        let scale = Double(image.height) / PageGeometry.letter.height
        #expect(luminance(of: image, x: Int(40 * scale), y: Int(10 * scale)) < 128, "the stroke on disk is in the thumbnail")
        if case .unloaded = reopened.state(of: page)! {} else { Issue.record("a thumbnail must not load the page") }
        #expect(reopened.dirtyPageCount == 0)
        #expect(!reopened.isDirty)
    }

    @Test("An undo into an unloaded page is thumbnailed with the restored ink, before and after the load")
    func thumbnailPrefersPendingRestore() async throws {
        let scratch = try Scratch("nb-thumb-restore")
        let store = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 2))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let (a, b) = (notebook.pageIDs[0], notebook.pageIDs[1])
        notebook.windowChanged(to: [a, b])
        try await waitUntil { notebook.state(of: a)?.content != nil && notebook.state(of: b)?.content != nil }
        notebook.inkChanged(on: a, Ink.drawing(strokes: 1), echoOf: nil)
        notebook.inkChanged(on: b, Ink.drawing(strokes: 1), echoOf: nil)
        await notebook.flush()
        notebook.windowChanged(to: [b])
        notebook.retired(a, finalInk: nil)
        notebook.prune()
        let before = notebook.contentVersion(of: a)

        #expect(notebook.undo() == b)
        #expect(notebook.undo() == a, "the older edit is on a, which is not loaded")
        #expect(notebook.contentVersion(of: a) == before + 1, "the stash bumps the version")
        // The load the undo started is dropped when a leaves the window; the
        // restore survives it.
        notebook.windowChanged(to: [b])
        if case .unloaded = notebook.state(of: a)! {} else { Issue.record("a should have dropped back to unloaded") }

        let unloaded = try #require(await notebook.thumbnail(of: a))
        let scale = Double(unloaded.height) / PageGeometry.letter.height
        #expect(luminance(of: unloaded, x: Int(40 * scale), y: Int(10 * scale)) == 255, "the pending restore, not the stroke on disk")
        if case .unloaded = notebook.state(of: a)! {} else { Issue.record("still unloaded") }

        notebook.windowChanged(to: [a, b])
        try await waitUntil { notebook.state(of: a)?.content != nil }
        #expect(notebook.state(of: a)?.content?.ink.strokes.isEmpty == true)
        // A new version after the load, so the render comes from custody and
        // not from the cache entry the unloaded path made.
        try await notebook.setPaper(.drawn(.blank), on: a)
        #expect(notebook.contentVersion(of: a) == before + 2)
        let loaded = try #require(await notebook.thumbnail(of: a))
        #expect(loaded !== unloaded, "rendered again, from the ready page")
        #expect(luminance(of: loaded, x: Int(40 * scale), y: Int(10 * scale)) == 255)
    }

    @Test("A page with a bad ink container thumbnails to nil, and its load reaches the same faults")
    func thumbnailOfCorruptPageRefuses() async throws {
        let scratch = try Scratch("nb-thumb-corrupt")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = index.pageIDs[0]
        #expect(await notebook.thumbnail(of: page) == nil)
        if case .unloaded = notebook.state(of: page)! {} else { Issue.record("a refused thumbnail must not change the state") }
        notebook.windowChanged(to: [page])
        try await waitUntil { if case .unreadable = notebook.state(of: page)! { true } else { false } }
        guard case .unreadable(let faults) = notebook.state(of: page)! else { return }
        #expect(faults.contains { if case .inkArchiveUndecodable = $0 { true } else { false } })
    }

    @Test("A page that is loading answers nil at once rather than waiting")
    func thumbnailOfLoadingPageIsNil() async throws {
        let scratch = try Scratch("nb-thumb-loading")
        let store = HeldLoadStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        await store.hold()
        notebook.windowChanged(to: [page])
        if case .loading = notebook.state(of: page)! {} else { Issue.record("should be loading") }
        #expect(await notebook.thumbnail(of: page) == nil)
        if case .loading = notebook.state(of: page)! {} else { Issue.record("still loading") }
        await store.release()
        try await waitUntil { notebook.state(of: page)?.content != nil }
        #expect(await notebook.thumbnail(of: page) != nil)
    }

    @Test("Importing a PDF makes one page per PDF page, each with that page as paper and no layer")
    func pdfPagesArePaper() async throws {
        let scratch = try Scratch("nb-pdf-paper")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let first = notebook.pageIDs[0]
        try await notebook.importPDF(try Fixture.pdfData(pages: 2))
        #expect(notebook.pageCount == 3)
        let imported = Array(notebook.pageIDs.dropFirst())
        for (offset, page) in imported.enumerated() {
            let record = try #require(notebook.index.record(of: page))
            guard case .pdf(let asset, let sourcePageIndex) = try #require(record.paper.paper) else {
                Issue.record("page \(page) is not PDF paper"); continue
            }
            #expect(asset.format == .pdf)
            #expect(sourcePageIndex == offset)
            #expect(record.geometry == PageGeometry(width: 400, height: 600))
            #expect(notebook.state(of: page)?.content?.layers.isEmpty == true)
        }
        #expect(notebook.paper(of: first) == .drawn(.blank))
        await notebook.flush()
        let reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.pageFaults.isEmpty)
        #expect(reopened.index.pages[1].paper == notebook.index.pages[1].paper)
        let bytes = try await PackageStore(root: scratch.packageURL).loadPage(imported[0])
        #expect(bytes.file.layers.isEmpty && bytes.file.inkIndex == 0)
    }

    @Test("Asset paper needs an empty page, takes the asset's aspect, and dirties the index")
    func assetPaperRules() async throws {
        let scratch = try Scratch("nb-asset-paper")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let letter = notebook.pageIDs[0]
        try await notebook.importPDF(try Fixture.pdfData(pages: 1))
        let source = notebook.pageIDs[1]
        notebook.windowChanged(to: notebook.pageIDs)
        try await waitUntil { notebook.state(of: letter)?.content != nil }
        let flattened = try await notebook.flatten(source)
        #expect(flattened.format == .heic)

        notebook.inkChanged(on: letter, Ink.drawing(strokes: 1), echoOf: nil)
        await #expect(throws: PaperRefusal.pageNotEmpty) { try await notebook.setPaper(.image(flattened), on: letter) }
        #expect(notebook.paper(of: letter) == .drawn(.blank))
        // Drawn paper still applies to a page with ink on it.
        try await notebook.setPaper(.drawn(.lined), on: letter)
        #expect(notebook.paper(of: letter) == .drawn(.lined))

        let empty = notebook.appendPage(after: letter)
        await notebook.flush()
        #expect(!notebook.isDirty)
        try await notebook.setPaper(.image(flattened), on: empty)
        #expect(notebook.isDirty, "geometry and paper live in the index")
        let record = try #require(notebook.index.record(of: empty))
        // The aspect is the asset's pixels, which rounded when it was rendered.
        #expect(record.geometry.width == 612 && abs(record.geometry.height - 918) < 1)
        #expect(record.paper == .known(.image(flattened)))

        await notebook.flush()
        let reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.pageFaults.isEmpty)
        let saved = try #require(reopened.index.record(of: empty))
        #expect(saved.paper == .known(.image(flattened)) && abs(saved.height - 918) < 1)
    }

    @Test("Flattening leaves the source page alone; a photo becomes paper and a new page after it is blank")
    func flattenAndPhotoPaper() async throws {
        let scratch = try Scratch("nb-flatten")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let source = notebook.pageIDs[0]
        notebook.windowChanged(to: [source])
        try await waitUntil { notebook.state(of: source)?.content != nil }
        let layer = Fixture.imageLayer()
        try await notebook.addLayer(layer, assetData: try Fixture.imageData(width: 40, height: 30), on: source)
        notebook.inkChanged(on: source, Ink.drawing(strokes: 2), echoOf: nil)
        let ink = try #require(notebook.state(of: source)?.content?.ink)

        let flattened = try await notebook.flatten(source)
        #expect(notebook.state(of: source)?.content?.ink == ink, "flatten does not change the source")
        #expect(notebook.state(of: source)?.content?.layers.map(\.id) == [layer.id])
        #expect(notebook.paper(of: source) == .drawn(.blank))
        #expect(try await notebook.store.readAsset(flattened).count > 0)

        let photoPage = notebook.appendPage(after: source)
        try await notebook.importImageAsPaper(try Fixture.imageData(width: 200, height: 100), on: photoPage)
        guard case .image(let photo) = try #require(notebook.paper(of: photoPage)) else {
            Issue.record("photo paper is not an image"); return
        }
        #expect(try #require(notebook.index.record(of: photoPage)).geometry == PageGeometry(width: 612, height: 306))
        // A new page after asset paper is blank: the asset belongs to the
        // page whose geometry it set.
        let after = notebook.appendPage(after: photoPage)
        #expect(notebook.paper(of: after) == .drawn(.blank))

        await notebook.flush()
        let reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.pageFaults.isEmpty)
        #expect(reopened.index.record(of: photoPage)?.paper == .known(.image(photo)))
        #expect(reopened.index.record(of: after)?.paper == .known(.drawn(.blank)))
    }

    @Test("A layer import publishes the asset first, sits beneath the ink, and round-trips")
    func layerImport() async throws {
        let scratch = try Scratch("nb-layer")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let layer = Fixture.imageLayer()
        try await notebook.addLayer(layer, assetData: Fixture.archive(1, count: 128), on: page)
        #expect(notebook.state(of: page)?.content?.inkIndex == 1)
        #expect(notebook.transformLayer(on: page, layer: layer.id, to: .translation(x: 5, y: 5)) == .accepted)
        #expect(notebook.transformLayer(on: page, layer: layer.id, to: PageSpaceTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0)) == .refused(reason: "invalidTransform(\(layer.id))"))
        await notebook.flush()
        let bytes = try await PackageStore(root: scratch.packageURL).loadPage(page)
        #expect(bytes.file.layers == [layer.id] && bytes.file.inkIndex == 1)
        #expect(bytes.layers.first?.transform == .translation(x: 5, y: 5))
        notebook.deleteLayer(layer.id, on: page)
        #expect(notebook.state(of: page)?.content?.inkIndex == 0)
        await notebook.flush()
        let after = try await PackageStore(root: scratch.packageURL).loadPage(page)
        #expect(after.file.layers.isEmpty && after.file.inkIndex == 0)
    }

    @Test("A page appended at a stated size and paper lands that record and survives a reopen")
    func appendAtAStatedSizeAndPaper() async throws {
        let scratch = try Scratch("nb-append-size")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let first = notebook.pageIDs[0]
        let a4Landscape = try #require(PageSize.a4.geometry(.landscape))
        let page = try await notebook.appendPage(after: first, geometry: a4Landscape, paper: .drawn(.grid))
        #expect(notebook.index.record(of: page)?.geometry == PageGeometry(width: 842, height: 595))
        #expect(notebook.index.record(of: page)?.paper == .known(.drawn(.grid)))

        await notebook.flush()
        let reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.pageFaults.isEmpty)
        #expect(reopened.index.pageIDs == [first, page])
        let saved = try #require(reopened.index.record(of: page))
        #expect(saved.width == 842 && saved.height == 595)
        #expect(saved.paper == .known(.drawn(.grid)))
        // The first page kept the size it was created at.
        #expect(reopened.index.record(of: first)?.geometry == .letter)
    }

    @Test("Inherited paper after a page that draws no paper at all is blank")
    func inheritedPaperAfterNoneIsBlank() async throws {
        let scratch = try Scratch("nb-inherit-none")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let first = notebook.pageIDs[0]
        try await notebook.setPaper(.drawn(DrawnPaper.none), on: first)
        #expect(notebook.paper(of: first) == .drawn(DrawnPaper.none))

        let page = try await notebook.appendPage(after: first, geometry: .letter, paper: .inheritTemplate)
        #expect(notebook.paper(of: page) == .drawn(.blank))
    }

    @Test("Asset paper on a new page keeps the chosen width, takes the asset's aspect, and is one structure change")
    func appendWithAssetPaperIsOneChange() async throws {
        let scratch = try Scratch("nb-append-asset")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let first = notebook.pageIDs[0]
        let asset = try await notebook.storeImageAsset(try Fixture.imageData(width: 200, height: 100))
        _ = notebook.drainChanges()

        let page = try await notebook.appendPage(after: first, geometry: .letter, paper: .asset(.image(asset)))
        let record = try #require(notebook.index.record(of: page))
        // Half as high as it is wide, at the width that was asked for.
        #expect(record.geometry == PageGeometry(width: 612, height: 306))
        #expect(record.paper == .known(.image(asset)))
        let structures = notebook.drainChanges().filter { if case .structure = $0 { true } else { false } }
        #expect(structures.count == 1, "the size and the paper are one change, not an append and then a paper change")

        await notebook.flush()
        let reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.pageFaults.isEmpty)
        let saved = try #require(reopened.index.record(of: page))
        #expect(saved.geometry == PageGeometry(width: 612, height: 306))
        #expect(saved.paper == .known(.image(asset)))
    }

    @Test("An append whose asset paper names nothing in the package is refused and leaves no page behind")
    func appendWithAnUnreadableAssetCreatesNothing() async throws {
        let scratch = try Scratch("nb-append-missing-asset")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let before = notebook.pageIDs
        let indexBefore = notebook.index
        let missing = AssetRef(id: AssetID(), format: .heic)
        _ = notebook.drainChanges()

        await #expect(throws: NewPageRefusal.assetUnreadable(missing)) {
            try await notebook.appendPage(after: before[0], geometry: .letter, paper: .asset(.image(missing)))
        }
        // The refusal is observed by what did not happen: no record, no
        // emission, and an index equal to the one before the call.
        #expect(notebook.pageIDs == before)
        #expect(notebook.pageCount == before.count)
        #expect(notebook.index == indexBefore)
        #expect(!notebook.drainChanges().contains { if case .structure = $0 { true } else { false } })
    }

    @Test("An append outside the page bounds is refused and leaves no page behind")
    func appendOutOfBoundsCreatesNothing() async throws {
        let scratch = try Scratch("nb-append-bounds")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let before = notebook.pageIDs
        let indexBefore = notebook.index
        let tooTall = PageGeometry(width: 612, height: PageBounds.maxEdge + 1)
        _ = notebook.drainChanges()

        await #expect(throws: NewPageRefusal.geometryOutOfBounds(width: 612, height: PageBounds.maxEdge + 1)) {
            try await notebook.appendPage(after: nil, geometry: tooTall, paper: .drawn(.grid))
        }
        #expect(notebook.pageIDs == before)
        #expect(notebook.pageCount == before.count)
        #expect(notebook.index == indexBefore)
        #expect(!notebook.drainChanges().contains { if case .structure = $0 { true } else { false } })
    }
}
