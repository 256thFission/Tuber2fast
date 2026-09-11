import Foundation
import PencilKit
import Testing
import UIKit
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

/// A real store whose `readAsset` parks every call until the test releases
/// it by index, so two renders of one page can be made to land in either
/// order.
final class GatedAssetStore: ForwardingStore, @unchecked Sendable {
    let gate = CallGate()
    override func readAsset(_ ref: AssetRef) async throws(FormatFault) -> Data {
        await gate.park()
        return try await base.readAsset(ref)
    }
}

actor CallGate {
    private var parked: [CheckedContinuation<Void, Never>?] = []
    var arrivals: Int { parked.count }
    func park() async {
        await withCheckedContinuation { parked.append($0) }
    }
    func release(_ index: Int) {
        parked[index]?.resume()
        parked[index] = nil
    }
}

/// One pixel of a composite, as bytes. Premultiplied RGBA, the layout the
/// renderer draws into.
func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
}

func textLayer(_ string: String, rect: PageRect = PageRect(x: 10, y: 10, width: 200, height: 60), size: Double = 40) -> Layer {
    let style = TextStyle(font: "system", size: size, bold: false, italic: false, underline: false, color: TextStyle.body.color)
    return Layer(id: LayerID(), transform: .identity, payload: .text(TextLayer(rect: rect, runs: [TextRun(string: string, style: style)], alignment: .leading)))
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

    // MARK: Text editing

    @Test("Begin leaves the layer out of the composite and queues the picture before the begin; commit puts it back")
    func beginOmitsTheLayer() async throws {
        let scratch = try Scratch("nb-text-begin")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let layer = textLayer("████")
        try notebook.insertLayer(layer, on: page)
        // Page point (15, 30) inside the first block glyph, at the 2x composite scale.
        func isDark() -> Bool {
            guard let image = notebook.state(of: page)?.content?.composite?.image else { return false }
            return pixel(image, x: 30, y: 60).r < 128
        }
        try await waitUntil { isDark() }
        _ = notebook.drainChanges()

        notebook.beginTextEditing(on: page, layer: layer.id)
        #expect(notebook.state(of: page)?.content?.textEditing == layer.id)
        try await waitUntil { !isDark() }
        let changes = notebook.drainChanges()
        #expect(changes.count == 2)
        guard case .compositeUpdated(let p1, _, let layers) = try #require(changes.first) else { Issue.record("no composite first: \(changes)"); return }
        #expect(p1 == page && layers.map(\.id) == [layer.id], "the list carries the edited layer too")
        guard case .textEditingBegan(let p2, let start) = try #require(changes.last) else { Issue.record("no begin last: \(changes)"); return }
        #expect(p2 == page && start.layer == layer.id && start.text.runs.first?.string == "████")

        let typed = TextLayer(rect: start.text.rect, runs: [TextRun(string: "██", style: .body), TextRun(string: "██", style: .body)], alignment: .center)
        notebook.endTextEditing(on: page, layer: layer.id, typed)
        #expect(notebook.state(of: page)?.content?.textEditing == nil)
        #expect(notebook.state(of: page)?.content?.pendingLayerFiles.contains(layer.id) == true)
        guard case .text(let stored) = try #require(notebook.state(of: page)?.content?.layers.first?.payload) else { Issue.record("not text"); return }
        #expect(stored.runs == [TextRun(string: "████", style: .body)], "adjacent equal runs merged at commit")
        #expect(stored.alignment == .center)
        try await waitUntil { notebook.drainChanges().last.map { if case .textEditingEnded = $0 { true } else { false } } ?? false }
        await notebook.flush()
        let bytes = try await PackageStore(root: scratch.packageURL).loadPage(page)
        guard case .text(let saved) = try #require(bytes.layers.first?.payload) else { Issue.record("not saved as text"); return }
        #expect(saved == stored)
    }

    @Test("An unchanged commit writes nothing, and an all-empty commit deletes the layer")
    func unchangedAndEmptyCommits() async throws {
        let scratch = try Scratch("nb-text-commit")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let layer = textLayer("hi")
        try notebook.insertLayer(layer, on: page)
        await notebook.flush()
        #expect(notebook.state(of: page)?.content?.isDirty == false)
        guard case .text(let text) = try #require(notebook.state(of: page)?.content?.layers.first?.payload) else { Issue.record("not text"); return }

        notebook.beginTextEditing(on: page, layer: layer.id)
        notebook.endTextEditing(on: page, layer: layer.id, text)
        #expect(notebook.state(of: page)?.content?.isDirty == false, "a save writes only what changed")
        #expect(notebook.state(of: page)?.content?.pendingLayerFiles.isEmpty == true)
        try await waitUntil { notebook.drainChanges().contains { if case .textEditingEnded = $0 { true } else { false } } }

        notebook.beginTextEditing(on: page, layer: layer.id)
        notebook.endTextEditing(on: page, layer: layer.id, TextLayer(rect: text.rect, runs: [TextRun(string: "", style: .body)], alignment: .leading))
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true)
        #expect(notebook.state(of: page)?.content?.inkIndex == 0)
        #expect(notebook.state(of: page)?.content?.isDirty == true)
        try await waitUntil { notebook.drainChanges().contains { if case .textEditingEnded = $0 { true } else { false } } }
        await notebook.flush()
        let bytes = try await PackageStore(root: scratch.packageURL).loadPage(page)
        #expect(bytes.file.layers.isEmpty && bytes.file.inkIndex == 0)
        // Begin while a session is open, a commit for the wrong layer, and an
        // invalid committed rect are traps, which Swift Testing cannot observe.
    }

    @Test("Two renders landing out of order install the newer one, and the text changes ride behind it")
    func staleRenderIsDropped() async throws {
        let scratch = try Scratch("nb-text-race")
        let created = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = created.pageIDs[0]
        _ = await created.close()
        let store = GatedAssetStore(PackageStore(root: scratch.packageURL))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let image = Fixture.imageLayer()
        try await notebook.addLayer(image, assetData: try Fixture.imageData(width: 40, height: 30), on: page)
        try await notebook.waitForArrivals(store.gate, 1)
        await store.gate.release(0)
        try await waitUntil { notebook.drainChanges().contains { if case .compositeUpdated = $0 { true } else { false } } }
        let text = textLayer("hi")
        try notebook.insertLayer(text, on: page)
        try await waitUntil { notebook.drainChanges().contains { if case .compositeUpdated = $0 { true } else { false } } }
        // The decoded asset is cached; purge so the next two renders both read.
        await notebook.renderer.purge()

        notebook.beginTextEditing(on: page, layer: text.id)
        try await notebook.waitForArrivals(store.gate, 2)
        guard case .text(let value) = try #require(notebook.state(of: page)?.content?.layers.last?.payload) else { Issue.record("not text"); return }
        notebook.endTextEditing(on: page, layer: text.id, value)
        try await notebook.waitForArrivals(store.gate, 3)
        #expect(notebook.drainChanges().isEmpty, "nothing lands while both renders are parked")

        // The commit's render lands first, then the begin's, which is stale.
        await store.gate.release(2)
        try await waitUntil { notebook.state(of: page)?.content?.afterRender.isEmpty == true }
        await store.gate.release(1)
        try await Task.sleep(for: .milliseconds(100))
        let changes = notebook.drainChanges()
        let composites = changes.filter { if case .compositeUpdated = $0 { true } else { false } }
        #expect(composites.count == 1, "the stale render queued nothing: \(changes)")
        let kinds = changes.map { change -> String in
            switch change {
            case .compositeUpdated: "composite"
            case .textEditingBegan: "began"
            case .textEditingEnded: "ended"
            default: "other"
            }
        }
        #expect(kinds == ["composite", "began", "ended"], "\(kinds)")
        #expect(notebook.state(of: page)?.content?.afterRender.isEmpty == true)
    }

    // The content version has no choke point; this list is the invariant's
    // enforcement for the sites this plan adds.
    @Test("The content version rises on an inserted layer and a changed commit, and on nothing else here")
    func contentVersionBumpSites() async throws {
        let scratch = try Scratch("nb-text-version")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
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
        let layer = textLayer("hi")
        try notebook.insertLayer(layer, on: page)
        expectBump("a layer inserted")
        guard case .text(let text) = try #require(notebook.state(of: page)?.content?.layers.first?.payload) else { Issue.record("not text"); return }
        notebook.beginTextEditing(on: page, layer: layer.id)
        expectSame("a session began")
        notebook.endTextEditing(on: page, layer: layer.id, text)
        expectSame("an unchanged commit")
        notebook.beginTextEditing(on: page, layer: layer.id)
        notebook.endTextEditing(on: page, layer: layer.id, TextLayer(rect: text.rect, runs: [TextRun(string: "ho", style: .body)], alignment: .leading))
        expectBump("a changed commit")
        notebook.beginTextEditing(on: page, layer: layer.id)
        notebook.endTextEditing(on: page, layer: layer.id, TextLayer(rect: text.rect, runs: [], alignment: .leading))
        expectBump("an emptied box, deleted")
    }
}

extension Notebook {
    /// Waits until `count` asset reads have parked at the gate.
    func waitForArrivals(_ gate: CallGate, _ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await gate.arrivals < count {
            try #require(ContinuousClock.now < deadline, "timed out waiting for \(count) asset reads")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
