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

/// A real store whose `loadPage` refuses every call once told to, so a page
/// that loaded clean once can fail its next load.
final class RefusingLoadStore: ForwardingStore, @unchecked Sendable {
    private let refusing = Gate()
    func refuse() async { await refusing.close() }
    override func loadPage(_ page: PageID) async throws(FormatFault) -> PageBytes {
        if !(await refusing.isOpen) { throw .corruptJSON("refused by the test") }
        return try await base.loadPage(page)
    }
}

actor Gate {
    private(set) var isOpen = true
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

    @Test("A restore whose layers equal the page's pushes one ink restore and no composite")
    func inkOnlyRestoreLeavesTheComposite() async throws {
        let scratch = try Scratch("nb-undo-ink-only")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        try notebook.insertLayer(textLayer("hi"), on: page)
        try await waitUntil { notebook.drainChanges().contains { if case .compositeUpdated = $0 { true } else { false } } }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil)
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2), echoOf: nil)
        _ = notebook.drainChanges()
        #expect(notebook.undo() == page)
        try await Task.sleep(for: .milliseconds(100))
        let changes = notebook.drainChanges()
        let restores = changes.filter { if case .inkRestored = $0 { true } else { false } }
        let composites = changes.filter { if case .compositeUpdated = $0 { true } else { false } }
        #expect(restores.count == 1 && composites.isEmpty, "\(changes)")
        #expect(notebook.state(of: page)?.content?.layers.count == 1)
    }

    @Test("Two undos into an unloaded page before its load lands, then two redos, walk back through both states")
    func twoUndosIntoOneUnloadedPage() async throws {
        let scratch = try Scratch("nb-undo-twice-unloaded")
        let store = HeldLoadStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil)
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2), echoOf: nil)
        await notebook.flush()
        notebook.windowChanged(to: [])
        notebook.retired(page, finalInk: nil)
        notebook.prune()
        if case .unloaded = notebook.state(of: page)! {} else { Issue.record("page should be pruned") }

        await store.hold()
        #expect(notebook.undo() == page)
        #expect(notebook.undo() == page)
        if case .loading = notebook.state(of: page)! {} else { Issue.record("the undo starts the load") }
        #expect(notebook.canRedo && !notebook.canUndo, "both entries moved to redo before the page arrived")
        await store.release()
        try await waitUntil { notebook.state(of: page)?.content != nil }
        #expect(notebook.state(of: page)?.content?.ink.strokes.isEmpty == true, "both undone on arrival")
        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 1, "the middle state, not the disk's")
        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 2)
        #expect(!notebook.canRedo)
    }

    @Test("An undo on an unloaded page then one on a loaded page redo in the reverse order")
    func redoReversesAcrossLoadedAndUnloaded() async throws {
        let scratch = try Scratch("nb-undo-order")
        let store = HeldLoadStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 2)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let (a, b) = (notebook.pageIDs[0], notebook.pageIDs[1])
        notebook.windowChanged(to: [a, b])
        try await waitUntil { notebook.state(of: a)?.content != nil && notebook.state(of: b)?.content != nil }
        notebook.inkChanged(on: b, Ink.drawing(strokes: 1), echoOf: nil)
        notebook.inkChanged(on: a, Ink.drawing(strokes: 1), echoOf: nil)
        await notebook.flush()
        notebook.windowChanged(to: [b])
        notebook.retired(a, finalInk: nil)
        notebook.prune()

        await store.hold()
        #expect(notebook.undo() == a, "the newest edit is on a, which is not loaded")
        #expect(notebook.undo() == b)
        #expect(notebook.state(of: b)?.content?.ink.strokes.isEmpty == true)
        #expect(notebook.redo() == b, "the reverse order, whether or not a has arrived")
        #expect(notebook.state(of: b)?.content?.ink.strokes.count == 1)
        #expect(notebook.redo() == a)
        #expect(!notebook.canRedo)
        await store.release()
        try await waitUntil { notebook.state(of: a)?.content != nil }
        #expect(notebook.state(of: a)?.content?.ink.strokes.count == 1)
        #expect(notebook.state(of: a)?.content?.isDirty == false, "the redo's revision is what the disk holds")
    }

    @Test("A layer restored during a held save stays pending after the save completes")
    func restoreDuringHeldSaveKeepsTheLayerPending() async throws {
        let scratch = try Scratch("nb-undo-held-layer")
        let store = HeldStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let layer = Fixture.imageLayer()
        try await notebook.addLayer(layer, assetData: Fixture.archive(1, count: 128), on: page)
        // The ink report is the entry; it holds the layer at its first placement.
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil)
        #expect(notebook.transformLayer(on: page, layer: layer.id, to: .translation(x: 5, y: 5)) == .accepted)

        await store.hold()
        let flushing = Task { await notebook.flush() }
        try await Task.sleep(for: .milliseconds(60))   // the pass captured the moved layer and is inside the held save
        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.layers == [layer], "the restore returns the layer to its first placement")
        await store.release()
        await flushing.value
        #expect(notebook.state(of: page)?.content?.pendingLayerFiles.contains(layer.id) == true, "the pass wrote the moved layer, not the one in custody")
        await notebook.flush()
        #expect(notebook.state(of: page)?.content?.isDirty == false)
        let bytes = try await store.base.loadPage(page)
        #expect(bytes.layers == [layer], "the restored placement is on disk, not the moved one")
    }

    @Test("Insert then undo removes the layer and restores the ink index; redo brings it back with its file pending")
    func undoRemovesAnInsertedLayer() async throws {
        let scratch = try Scratch("nb-undo-insert")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let layer = textLayer("hi")
        try notebook.insertLayer(layer, on: page)
        try await waitUntil { notebook.drainChanges().contains { if case .compositeUpdated = $0 { true } else { false } } }
        #expect(notebook.state(of: page)?.content?.inkIndex == 1)

        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true)
        #expect(notebook.state(of: page)?.content?.inkIndex == 0)
        try await waitUntil {
            notebook.drainChanges().contains { if case .compositeUpdated(let p, _, let layers) = $0 { p == page && layers.isEmpty } else { false } }
        }

        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.layers == [layer])
        #expect(notebook.state(of: page)?.content?.inkIndex == 1)
        #expect(notebook.state(of: page)?.content?.pendingLayerFiles.contains(layer.id) == true)
    }

    @Test("Transform then undo restores the old transform and marks the file pending")
    func undoRestoresATransform() async throws {
        let scratch = try Scratch("nb-undo-transform")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let layer = Fixture.imageLayer()
        try await notebook.addLayer(layer, assetData: Fixture.archive(1, count: 128), on: page)
        #expect(notebook.transformLayer(on: page, layer: layer.id, to: .translation(x: 5, y: 5)) == .accepted)
        await notebook.flush()
        #expect(notebook.state(of: page)?.content?.pendingLayerFiles.isEmpty == true)

        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.layers == [layer])
        #expect(notebook.state(of: page)?.content?.pendingLayerFiles == [layer.id])
    }

    @Test("Delete then undo re-lists the layer at its original position")
    func undoRelistsADeletedLayer() async throws {
        let scratch = try Scratch("nb-undo-delete")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let first = textLayer("first"), second = textLayer("second")
        try notebook.insertLayer(first, on: page)
        try notebook.insertLayer(second, on: page)
        #expect(notebook.state(of: page)?.content?.layers == [first, second])

        notebook.deleteLayer(first.id, on: page)
        #expect(notebook.state(of: page)?.content?.layers == [second])
        #expect(notebook.state(of: page)?.content?.inkIndex == 1)

        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.layers == [first, second])
        #expect(notebook.state(of: page)?.content?.inkIndex == 2)
    }

    @Test("A refused transform and a transform to the one the layer has record nothing")
    func noOpTransformsRecordNothing() async throws {
        let scratch = try Scratch("nb-undo-noop-transform")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let layer = Fixture.imageLayer()
        try await notebook.addLayer(layer, assetData: Fixture.archive(1, count: 128), on: page)
        #expect(notebook.transformLayer(on: page, layer: layer.id, to: .translation(x: 5, y: 5)) == .accepted)
        #expect(notebook.undo() == page)
        #expect(notebook.canRedo)

        let invalid = PageSpaceTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0)
        #expect(notebook.transformLayer(on: page, layer: layer.id, to: invalid) == .refused(reason: "invalidTransform(\(layer.id))"))
        #expect(notebook.canRedo, "a refusal is not an edit")
        #expect(notebook.transformLayer(on: page, layer: layer.id, to: layer.transform) == .accepted)
        #expect(notebook.canRedo, "a transform to the one the layer has is not an edit")
        notebook.deleteLayer(LayerID(), on: page)
        #expect(notebook.canRedo, "a delete of a layer the page does not hold is not an edit")

        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.layers.first?.transform == .translation(x: 5, y: 5))
    }

    @Test("A locked layer refuses a transform and a delete by name; lock and unlock are each one entry, and undo walks them back")
    func aLockRefusesEditsAndIsUndoable() async throws {
        let scratch = try Scratch("nb-lock-layer")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let layer = Fixture.imageLayer()
        try await notebook.addLayer(layer, assetData: Fixture.archive(1, count: 128), on: page)
        await notebook.flush()
        let entriesBefore = notebook.canUndo

        #expect(notebook.setLayerLock(layer.id, on: page, locked: true) == .accepted)
        #expect(notebook.state(of: page)?.content?.layers.first?.locked == true)
        #expect(notebook.state(of: page)?.content?.pendingLayerFiles == [layer.id], "the lock is durable, so the file is rewritten")
        #expect(notebook.canUndo)

        let moved = PageSpaceTransform.translation(x: 5, y: 5)
        #expect(notebook.transformLayer(on: page, layer: layer.id, to: moved) == .refused(reason: "layer \(layer.id) is locked"))
        #expect(notebook.deleteLayer(layer.id, on: page) == .refused(reason: "layer \(layer.id) is locked"))
        #expect(notebook.state(of: page)?.content?.layers == [layer.withLock(true)], "a refusal changes nothing")
        #expect(notebook.setLayerLock(layer.id, on: page, locked: true) == .accepted)
        #expect(notebook.canRedo == false, "locking a locked layer moves no revision and records nothing")

        #expect(notebook.undo() == page, "undo of the lock")
        #expect(notebook.state(of: page)?.content?.layers == [layer])
        #expect(notebook.canUndo == entriesBefore)
        #expect(notebook.transformLayer(on: page, layer: layer.id, to: moved) == .accepted, "unlocked by the undo, it moves")
        #expect(notebook.undo() == page, "undo of the move")
        #expect(notebook.canRedo)

        #expect(notebook.redo() == page, "redo of the move")
        #expect(notebook.setLayerLock(layer.id, on: page, locked: true) == .accepted)
        #expect(notebook.setLayerLock(layer.id, on: page, locked: false) == .accepted)
        #expect(notebook.state(of: page)?.content?.layers.first?.locked == false)
        #expect(notebook.undo() == page, "undo of the unlock relocks")
        #expect(notebook.state(of: page)?.content?.layers.first?.locked == true)
        #expect(notebook.deleteLayer(layer.id, on: page) == .refused(reason: "layer \(layer.id) is locked"))
        #expect(notebook.setLayerLock(LayerID(), on: page, locked: true) == .refused(reason: "no such layer"))

        // The lock survives the store: a reopen reads it back.
        await notebook.flush()
        let bytes = try await PackageStore(root: scratch.packageURL).loadPage(page)
        #expect(bytes.layers.map(\.locked) == [true])
        _ = await notebook.close()
    }

    @Test("An undo into an unloaded page whose entry is a layer change applies on arrival and queues a composite without the layer")
    func layerUndoIntoAnUnloadedPage() async throws {
        let scratch = try Scratch("nb-undo-layer-unloaded")
        let store = HeldLoadStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let layer = textLayer("hi")
        try notebook.insertLayer(layer, on: page)
        await notebook.flush()
        notebook.windowChanged(to: [])
        notebook.retired(page, finalInk: nil)
        notebook.prune()
        if case .unloaded = notebook.state(of: page)! {} else { Issue.record("page should be pruned") }
        _ = notebook.drainChanges()

        await store.hold()
        #expect(notebook.undo() == page)
        if case .loading = notebook.state(of: page)! {} else { Issue.record("the undo starts the load") }
        await store.release()
        try await waitUntil { notebook.state(of: page)?.content != nil }
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true, "undone on arrival")
        #expect(notebook.state(of: page)?.content?.inkIndex == 0)
        try await waitUntil {
            notebook.drainChanges().contains { if case .compositeUpdated(let p, _, let layers) = $0 { p == page && layers.isEmpty } else { false } }
        }
    }

    @Test("A begin for a layer the page does not hold ends the session it never opened instead of trapping")
    func beginForAMissingLayerEndsTheSession() async throws {
        let scratch = try Scratch("nb-text-begin-missing")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        _ = notebook.drainChanges()
        let missing = LayerID()

        notebook.beginTextEditing(on: page, layer: missing)
        #expect(notebook.state(of: page)?.content?.textEditing == nil)
        let changes = notebook.drainChanges()
        #expect(changes.contains { if case .textEditingEnded(let p, let l) = $0 { p == page && l == missing } else { false } }, "\(changes)")
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

    @Test("A bookmark dirties the index, survives a flush and a reopen, and records no undo entry")
    func bookmarking() async throws {
        let scratch = try Scratch("nb-bookmark")
        let store = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 2))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let (a, b) = (notebook.pageIDs[0], notebook.pageIDs[1])
        _ = notebook.drainChanges()
        #expect(!notebook.canUndo)

        notebook.bookmark(b, titled: "Chapter two")
        #expect(notebook.isDirty)
        #expect(notebook.drainChanges().isEmpty, "a mark queues nothing for the runtime")
        #expect(!notebook.canUndo, "a mark is not an edit")
        await notebook.flush()
        #expect(!notebook.isDirty)
        var reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.index.bookmarks == [PageBookmark(page: b, title: "Chapter two")])

        // Renaming replaces rather than appends; an unchanged title writes
        // nothing at all.
        notebook.bookmark(b, titled: "Chapter two")
        #expect(!notebook.isDirty, "an unchanged mark is not a change")
        notebook.bookmark(b, titled: "Two")
        notebook.bookmark(a, titled: "")
        await notebook.flush()
        reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.index.bookmarks.count == 2)
        #expect(reopened.index.bookmarks.first { $0.page == b }?.title == "Two")
        #expect(reopened.index.bookmarks.first { $0.page == a }?.title == "", "a mark nobody named is still a mark")

        notebook.removeBookmark(a)
        #expect(notebook.isDirty)
        await notebook.flush()
        #expect(try await PackageStore(root: scratch.packageURL).load().index.bookmarks.map(\.page) == [b])
        notebook.removeBookmark(a)
        #expect(!notebook.isDirty, "unmarking a page that carries no mark writes nothing")
        #expect(!notebook.canUndo)
    }

    @Test("Deleting a bookmarked page takes its bookmark with it")
    func deletingABookmarkedPage() async throws {
        let scratch = try Scratch("nb-bookmark-delete")
        let store = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 2))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let (a, b) = (notebook.pageIDs[0], notebook.pageIDs[1])
        notebook.bookmark(a, titled: "first")
        notebook.bookmark(b, titled: "second")
        await notebook.flush()

        notebook.deletePage(a)
        #expect(notebook.index.bookmarks.map(\.page) == [b])
        await notebook.flush()
        let reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.index.bookmarks.map(\.page) == [b])
        // The index it wrote is one this build will open again.
        #expect(throws: Never.self) { try reopened.index.validated() }
    }

    @Test("Moving pages reorders the outline without touching the list")
    func movingReordersTheOutline() async throws {
        let scratch = try Scratch("nb-bookmark-order")
        let store = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 3))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let (a, b, c) = (notebook.pageIDs[0], notebook.pageIDs[1], notebook.pageIDs[2])
        notebook.bookmark(a, titled: "first")
        notebook.bookmark(c, titled: "third")
        // Insertion order, which is not page order and is not meant to be.
        #expect(notebook.index.bookmarks.map(\.page) == [a, c])

        notebook.movePage(c, before: a)
        #expect(notebook.index.pageIDs == [c, a, b])
        #expect(notebook.index.bookmarks.map(\.page) == [a, c], "the list is untouched by a reorder")
        // The outline is the marked pages read out of `pages`, so it follows
        // the new order without the list being kept in it.
        let marked = notebook.index.pages.filter { record in notebook.index.bookmarks.contains { $0.page == record.id } }
        #expect(marked.map(\.id) == [c, a])
    }

    @Test("Deleting a page drops its entries from both stacks; undo walks only the surviving page")
    func deletingAPageForgetsItsHistory() async throws {
        let scratch = try Scratch("nb-delete-forgets")
        let store = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 2))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let (a, b) = (notebook.pageIDs[0], notebook.pageIDs[1])
        notebook.windowChanged(to: [a, b])
        try await waitUntil { notebook.state(of: a)?.content != nil && notebook.state(of: b)?.content != nil }
        notebook.inkChanged(on: a, Ink.drawing(strokes: 1), echoOf: nil)
        notebook.inkChanged(on: b, Ink.drawing(strokes: 1), echoOf: nil)
        notebook.inkChanged(on: a, Ink.drawing(strokes: 2), echoOf: nil)
        #expect(notebook.undo() == a, "a's newest entry is on the redo stack")
        #expect(notebook.canRedo)

        notebook.deletePage(a)
        #expect(notebook.canUndo, "b's entry survives")
        #expect(!notebook.canRedo, "a's redo entry went with the page")
        #expect(notebook.undo() == b)
        #expect(notebook.state(of: b)?.content?.ink.strokes.isEmpty == true)
        #expect(!notebook.canUndo, "a's older entry went with the page")
        #expect(notebook.undo() == nil)
        #expect(notebook.redo() == b)
        #expect(!notebook.canRedo)
    }

    @Test("An undo whose page was pending load when the page was deleted does not trap and restores nothing")
    func undoIntoADeletedPageRestoresNothing() async throws {
        let scratch = try Scratch("nb-delete-pending")
        let store = HeldLoadStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 2)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let (a, b) = (notebook.pageIDs[0], notebook.pageIDs[1])
        notebook.windowChanged(to: [a])
        try await waitUntil { notebook.state(of: a)?.content != nil }
        notebook.inkChanged(on: a, Ink.drawing(strokes: 1), echoOf: nil)
        await notebook.flush()
        notebook.windowChanged(to: [])
        notebook.retired(a, finalInk: nil)
        notebook.prune()
        if case .unloaded = notebook.state(of: a)! {} else { Issue.record("a should be pruned") }
        _ = notebook.drainChanges()

        await store.hold()
        #expect(notebook.undo() == a)
        if case .loading = notebook.state(of: a)! {} else { Issue.record("the undo starts the load") }
        notebook.deletePage(a)
        #expect(!notebook.canUndo && !notebook.canRedo)
        #expect(notebook.undo() == nil)
        #expect(notebook.redo() == nil)
        await store.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(notebook.state(of: a) == nil)
        #expect(notebook.pageIDs == [b])
        #expect(!notebook.drainChanges().contains { if case .content = $0 { true } else { false } }, "the cancelled load installs nothing")
    }

    @Test("A page whose load fails after an entry was recorded for it drops that entry")
    func failedLoadForgetsTheEntry() async throws {
        let scratch = try Scratch("nb-failed-load-forgets")
        let store = RefusingLoadStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil)
        await notebook.flush()
        notebook.windowChanged(to: [])
        notebook.retired(page, finalInk: nil)
        notebook.prune()
        if case .unloaded = notebook.state(of: page)! {} else { Issue.record("page should be pruned") }
        #expect(notebook.canUndo)

        await store.refuse()
        notebook.windowChanged(to: [page])
        try await waitUntil { if case .unreadable = notebook.state(of: page)! { true } else { false } }
        #expect(!notebook.canUndo, "the entry went with the page's readability")
        #expect(notebook.undo() == nil)
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
        try notebook.insertLayer(textLayer("t", rect: PageRect(x: 10, y: 10, width: 100, height: 40)), on: page)
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

    // MARK: Revisions for a render

    @Test("A revision of an unloaded page comes from its files and installs nothing")
    func revisionOfUnloadedPage() async throws {
        let scratch = try Scratch("nb-revision-unloaded")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil)
        await notebook.flush()
        _ = await notebook.close()

        let reopened = try await Notebook.open(store: PackageStore(root: scratch.packageURL), schedule: fast)
        let canUndo = reopened.canUndo
        let revision = try #require(await reopened.revision(of: page))
        #expect(revision.ink.strokes.count == 1, "the stroke on disk")
        if case .unloaded = reopened.state(of: page)! {} else { Issue.record("a revision must not load the page") }
        #expect(reopened.dirtyPageCount == 0)
        #expect(!reopened.isDirty)
        #expect(reopened.canUndo == canUndo, "reading a page is not an edit")
    }

    @Test("A revision of a loading page reads the disk rather than waiting on custody")
    func revisionOfLoadingPage() async throws {
        let scratch = try Scratch("nb-revision-loading")
        let store = HeldLoadStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        await store.hold()
        notebook.windowChanged(to: [page])
        if case .loading = notebook.state(of: page)! {} else { Issue.record("should be loading") }
        // The revision waits on the same held load, so release it from another
        // task rather than before the ask.
        let reading = Task { await notebook.revision(of: page) }
        await store.release()
        #expect(try #require(await reading.value).ink.strokes.isEmpty, "the page on disk has no ink")
        #expect(notebook.dirtyPageCount == 0)
    }

    @Test("A revision of an unloaded page with a stashed undo is the restored ink")
    func revisionPrefersPendingRestore() async throws {
        let scratch = try Scratch("nb-revision-restore")
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

        #expect(notebook.undo() == b)
        #expect(notebook.undo() == a, "the older edit is on a, which is not loaded")
        notebook.windowChanged(to: [b])
        if case .unloaded = notebook.state(of: a)! {} else { Issue.record("a should have dropped back to unloaded") }

        let revision = try #require(await notebook.revision(of: a))
        #expect(revision.ink.strokes.isEmpty, "the pending restore, not the stroke on disk")
        if case .unloaded = notebook.state(of: a)! {} else { Issue.record("still unloaded") }
    }

    @Test("A revision of a page with a bad ink container is nil and moves nothing")
    func revisionOfCorruptPageRefuses() async throws {
        let scratch = try Scratch("nb-revision-corrupt")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = index.pageIDs[0]
        #expect(await notebook.revision(of: page) == nil)
        if case .unloaded = notebook.state(of: page)! {} else { Issue.record("a refused revision must not change the state") }
    }

    @Test("A revision of a ready page is what custody holds, unsaved ink included")
    func revisionOfReadyPage() async throws {
        let scratch = try Scratch("nb-revision-ready")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2), echoOf: nil)
        let revision = try #require(await notebook.revision(of: page))
        #expect(revision.ink.strokes.count == 2, "custody, before the save engine has written anything")
        withExtendedLifetime(scratch) {}
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

    @Test("A duplicate follows its source, equals it, shares its assets, and records nothing")
    func duplicatingAReadyPage() async throws {
        let scratch = try Scratch("nb-duplicate")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let first = notebook.pageIDs[0]
        let source = try await notebook.appendPage(
            after: first, geometry: PageGeometry(width: 842, height: 595), paper: .drawn(.grid))
        try await notebook.addLayer(Fixture.imageLayer(), assetData: try Fixture.imageData(width: 40, height: 30), on: source)
        try notebook.insertLayer(Fixture.textLayer(), on: source)
        notebook.inkChanged(on: source, Ink.drawing(strokes: 2), echoOf: nil)
        let before = try #require(notebook.state(of: source)?.content)
        let couldUndo = notebook.canUndo

        let copy = try await notebook.duplicatePage(source)

        #expect(notebook.pageIDs == [first, source, copy], "the copy follows the source")
        let copied = try #require(notebook.state(of: copy)?.content)
        #expect(copied.ink == before.ink)
        #expect(copied.inkIndex == before.inkIndex)
        #expect(copied.hasInk == before.hasInk)
        #expect(notebook.index.record(of: copy)?.geometry == PageGeometry(width: 842, height: 595))
        #expect(notebook.paper(of: copy) == .drawn(.grid))

        // The same layers under new identities: a layer file is one file per
        // id, so sharing them would make a transform on either page rewrite
        // the file for both.
        #expect(copied.layers.map(\.payload) == before.layers.map(\.payload))
        #expect(copied.layers.map(\.transform) == before.layers.map(\.transform))
        #expect(Set(copied.layers.map(\.id)).isDisjoint(with: Set(before.layers.map(\.id))))

        // Duplicating is navigation: nothing joins the stack.
        #expect(notebook.canUndo == couldUndo)

        await notebook.flush()
        let reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.pageFaults.isEmpty)
        #expect(reopened.index.pageIDs == [first, source, copy])
        // One asset, named by both pages: assets are immutable and shared.
        let assets = try FileManager.default.contentsOfDirectory(
            atPath: scratch.packageURL.appendingPathComponent("assets").path)
        #expect(assets.count == 1)
    }

    @Test("A page that is not loaded is duplicated from its files, and stays unloaded")
    func duplicatingAnUnloadedPage() async throws {
        let scratch = try Scratch("nb-duplicate-unloaded")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let source = notebook.pageIDs[0]
        notebook.windowChanged(to: [source])
        try await waitUntil { notebook.state(of: source)?.content != nil }
        let ink = Ink.drawing(strokes: 3)
        notebook.inkChanged(on: source, ink, echoOf: nil)
        await notebook.flush()
        _ = await notebook.close()

        let reopened = try await Notebook.open(store: PackageStore(root: scratch.packageURL), schedule: fast)
        guard case .unloaded = try #require(reopened.state(of: source)) else {
            Issue.record("the source should be unloaded"); return
        }

        let copy = try await reopened.duplicatePage(source)

        #expect(reopened.state(of: copy)?.content?.ink == ink)
        #expect(reopened.state(of: copy)?.content?.hasInk == true)
        guard case .unloaded = try #require(reopened.state(of: source)) else {
            Issue.record("reading a page for a copy must not install it"); return
        }

        await reopened.flush()
        let onDisk = try await PackageStore(root: scratch.packageURL).load()
        #expect(onDisk.pageFaults.isEmpty)
        #expect(onDisk.index.pageIDs == [source, copy])
    }

    @Test("A page with a text box open cannot be duplicated")
    func duplicatingRefusesAnOpenTextBox() async throws {
        let scratch = try Scratch("nb-duplicate-text")
        defer { withExtendedLifetime(scratch) {} }
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.createTextBox(on: page, at: PagePoint(x: 40, y: 40), style: .body, alignment: .leading)
        #expect(notebook.hasTextSession(on: page))

        await #expect(throws: FormatFault.self) { try await notebook.duplicatePage(page) }
        #expect(notebook.pageCount == 1, "a refused duplicate inserts nothing")
    }

    @Test("A link moves by its rect, undoes, redoes; a bad rect and a text layer are refused")
    func movingALink() async throws {
        let scratch = try Scratch("nb-move-link")
        defer { withExtendedLifetime(scratch) {} }
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let link = Fixture.linkLayer(to: page)
        try notebook.insertLayer(link, on: page)
        let text = Fixture.textLayer()
        try notebook.insertLayer(text, on: page)
        await notebook.flush()

        let moved = PageRect(x: 300, y: 500, width: 120, height: 40)
        #expect(notebook.moveLinkLayer(on: page, layer: link.id, to: moved) == .accepted)
        guard case .link(let after) = try #require(notebook.state(of: page)?.content?.layers.first { $0.id == link.id }).payload else {
            Issue.record("the layer stopped being a link"); return
        }
        #expect(after.rect == moved)
        #expect(after.target == .internalPage(page), "only the rect moves")
        #expect(notebook.state(of: page)?.content?.pendingLayerFiles.contains(link.id) == true)

        // A move is an edit, on the stack like every other layer edit.
        #expect(notebook.undo() == page)
        guard case .link(let undone) = try #require(notebook.state(of: page)?.content?.layers.first { $0.id == link.id }).payload else {
            Issue.record("the layer stopped being a link"); return
        }
        #expect(undone.rect == PageRect(x: 40, y: 40, width: 160, height: 44))
        #expect(notebook.redo() == page)
        guard case .link(let redone) = try #require(notebook.state(of: page)?.content?.layers.first { $0.id == link.id }).payload else {
            Issue.record("the layer stopped being a link"); return
        }
        #expect(redone.rect == moved)

        // A rect that is not a rect, and a layer that is not a link.
        let couldUndo = notebook.canUndo
        #expect(notebook.moveLinkLayer(on: page, layer: link.id, to: PageRect(x: 10, y: 10, width: 0, height: 40)) != .accepted)
        #expect(notebook.moveLinkLayer(on: page, layer: text.id, to: moved) != .accepted)
        #expect(notebook.canUndo == couldUndo, "a refusal records nothing")
        guard case .link(let unchanged) = try #require(notebook.state(of: page)?.content?.layers.first { $0.id == link.id }).payload else {
            Issue.record("the layer stopped being a link"); return
        }
        #expect(unchanged.rect == moved)
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
        #expect(notebook.state(of: page)?.content?.textEditing?.layer == layer.id)
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
    func textContentVersionBumpSites() async throws {
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

    // MARK: Text sessions on the stack

    private func readyPage(_ name: String) async throws -> (Scratch, Notebook, PageID) {
        let scratch = try Scratch(name)
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        return (scratch, notebook, page)
    }

    @Test("A created box and what was typed in it undo as one step; redo brings the box back with its text")
    func createdBoxUndoesAsOneStep() async throws {
        let (scratch, notebook, page) = try await readyPage("nb-text-undo-create")
        notebook.createTextBox(on: page, at: PagePoint(x: 30, y: 40), style: .body, alignment: .leading)
        #expect(!notebook.canUndo, "the insert is the session's, not an entry of its own")
        let layer = try #require(notebook.state(of: page)?.content?.layers.first)
        guard case .text(let empty) = layer.payload else { Issue.record("not text"); return }
        let typed = TextLayer(rect: empty.rect, runs: [TextRun(string: "typed", style: .body)], alignment: .leading)
        notebook.endTextEditing(on: page, layer: layer.id, typed)
        #expect(notebook.canUndo)

        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true)
        #expect(notebook.state(of: page)?.content?.inkIndex == 0)
        #expect(!notebook.canUndo, "one step took the box and its text")

        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.layers.first?.payload == .text(typed))
        #expect(notebook.state(of: page)?.content?.inkIndex == 1)
        #expect(notebook.state(of: page)?.content?.pendingLayerFiles.contains(layer.id) == true)
        _ = await notebook.close()
        _ = scratch
    }

    @Test("Editing an existing box, then undo, puts the old runs back")
    func undoRestoresTheOldRuns() async throws {
        let (scratch, notebook, page) = try await readyPage("nb-text-undo-edit")
        let layer = textLayer("old")
        try notebook.insertLayer(layer, on: page)
        guard case .text(let old) = layer.payload else { Issue.record("not text"); return }
        notebook.beginTextEditing(on: page, layer: layer.id)
        notebook.endTextEditing(on: page, layer: layer.id, TextLayer(rect: old.rect, runs: [TextRun(string: "new", style: .body)], alignment: .leading))
        #expect(notebook.state(of: page)?.content?.layers.first?.payload != .text(old))

        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.layers == [layer])
        #expect(notebook.canUndo, "the insert's own entry is beneath the session's")
        #expect(notebook.canRedo)
        _ = await notebook.close()
        _ = scratch
    }

    @Test("A session committed unchanged records nothing: undo and redo are as they were")
    func unchangedCommitRecordsNothing() async throws {
        let (scratch, notebook, page) = try await readyPage("nb-text-undo-unchanged")
        let kept = textLayer("kept"), undone = textLayer("undone", rect: PageRect(x: 10, y: 100, width: 200, height: 60))
        try notebook.insertLayer(kept, on: page)
        try notebook.insertLayer(undone, on: page)
        #expect(notebook.undo() == page)
        #expect(notebook.canUndo && notebook.canRedo)
        guard case .text(let text) = kept.payload else { Issue.record("not text"); return }

        notebook.beginTextEditing(on: page, layer: kept.id)
        notebook.endTextEditing(on: page, layer: kept.id, text)
        #expect(notebook.canUndo && notebook.canRedo, "a record would have cleared redo")
        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.layers == [kept, undone])
        _ = await notebook.close()
        _ = scratch
    }

    @Test("A created box abandoned empty records nothing, and the page it moved twice is still dirty")
    func abandonedBoxRecordsNothing() async throws {
        let (scratch, notebook, page) = try await readyPage("nb-text-undo-abandoned")
        let layer = textLayer("hi")
        try notebook.insertLayer(layer, on: page)
        #expect(notebook.undo() == page)
        #expect(!notebook.canUndo && notebook.canRedo)

        notebook.createTextBox(on: page, at: PagePoint(x: 30, y: 40), style: .body, alignment: .leading)
        // The save that lands between the insert and the abandon writes the
        // empty box; the removal has to reach the disk too.
        await notebook.flush()
        #expect(!notebook.isDirty)
        let version = notebook.contentVersion(of: page)
        let box = try #require(notebook.state(of: page)?.content?.textEditing?.layer)
        notebook.endTextEditing(on: page, layer: box, TextLayer(rect: PageRect(x: 30, y: 40, width: 240, height: 96), runs: [], alignment: .leading))
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true)
        #expect(notebook.state(of: page)?.content?.inkIndex == 0)
        #expect(notebook.isDirty, "the removal is a change to the page even though the stack saw none")
        #expect(notebook.contentVersion(of: page) == version + 1)
        #expect(!notebook.canUndo && notebook.canRedo, "a record would have cleared redo")
        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.layers == [layer])
        _ = await notebook.close()
        _ = scratch
    }

    @Test("The notebook says a session is open, and on which page, while one is open and not after")
    func hasTextSessionFollowsTheSession() async throws {
        // `apply` under an open session is a trap, which Swift Testing cannot
        // observe; what it reads is asserted here, and the binding's routing
        // test is what keeps the trap out of reach.
        let (scratch, notebook, page) = try await readyPage("nb-text-session-page")
        let other = notebook.appendPage()
        #expect(!notebook.hasTextSession)
        notebook.createTextBox(on: page, at: PagePoint(x: 30, y: 40), style: .body, alignment: .leading)
        #expect(notebook.hasTextSession)
        #expect(notebook.hasTextSession(on: page) && !notebook.hasTextSession(on: other))
        #expect(notebook.state(of: page)?.content?.textEditing?.before.layers.isEmpty == true, "captured ahead of the insert")
        let box = try #require(notebook.state(of: page)?.content?.textEditing?.layer)
        notebook.endTextEditing(on: page, layer: box, TextLayer(rect: PageRect(x: 30, y: 40, width: 240, height: 96), runs: [], alignment: .leading))
        #expect(!notebook.hasTextSession && !notebook.hasTextSession(on: page))
        _ = await notebook.close()
        _ = scratch
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
