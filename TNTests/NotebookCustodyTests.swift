import Foundation
import PencilKit
import Testing
import UIKit
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook

@Suite("Notebook: ink custody, undo and the window")
@MainActor
struct NotebookCustodyTests {
    @Test("Undo restores the prior value without the echo counting as an edit; redo returns")
    func undoWithoutEcho() async throws {
        let scratch = try Scratch("nb-undo")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        _ = notebook.drainChanges()
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
        let editSeqBefore = notebook.state(of: page)!.content!.editSeq
        #expect(notebook.undo() == page)
        let changes = notebook.drainChanges()
        guard case .inkRestored(let restoredPage, let ink, _) = try #require(changes.last) else { Issue.record("no restore"); return }
        #expect(restoredPage == page && ink.strokes.count == 1)
        // The runtime reports PencilKit's callback for the programmatic set.
        notebook.inkChanged(on: page, ink)
        #expect(notebook.state(of: page)!.content!.editSeq == editSeqBefore + 1, "the echo is not an edit")
        #expect(notebook.state(of: page)!.content!.ink.strokes.count == 1)
        #expect(notebook.canRedo)
        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)!.content!.ink.strokes.count == 2)
        #expect(!notebook.canRedo)
    }

    @Test("A report of the ink already held is no edit: the page stays clean and its ink file is not rewritten")
    func anEqualReportIsNotAnEdit() async throws {
        let scratch = try Scratch("nb-equal-report")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
        await notebook.flush()
        let inkURL = PackageStore(root: scratch.packageURL).layout.inkURL(page)
        let written = try PosixFileSystem().modificationTime(inkURL)
        let held = notebook.state(of: page)!.content!
        _ = notebook.drainChanges()

        notebook.inkChanged(on: page, held.ink)
        let after = notebook.state(of: page)!.content!
        #expect(after.editSeq == held.editSeq)
        #expect(!after.isDirty && !notebook.isDirty)
        #expect(notebook.drainChanges().isEmpty, "no content change reaches the editor")
        await notebook.flush()
        #expect(try PosixFileSystem().modificationTime(inkURL) == written)
    }

    @Test("An echo whose ink differs from the restored value is an edit: PencilKit committed a stroke over the restore")
    func echoCarryingDifferentInkIsAnEdit() async throws {
        let scratch = try Scratch("nb-undo-late-commit")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        _ = notebook.drainChanges()
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
        #expect(notebook.undo() == page)
        guard case .inkRestored(_, let restored, _) = try #require(notebook.drainChanges().last) else { Issue.record("no restore"); return }
        #expect(restored.strokes.count == 1)
        // The canvas installed the restore, then PencilKit finished committing
        // the undone stroke on top of it and reported the result stamped as
        // the install's echo. The drawing on the canvas is two strokes again.
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
        #expect(notebook.state(of: page)!.content!.ink.strokes.count == 2, "custody follows the canvas: the value it holds is the value on screen")
        #expect(notebook.state(of: page)!.content!.isDirty)
        #expect(notebook.canUndo, "the stroke that came back is undoable again")
        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)!.content!.ink.strokes.count == 1)
    }

    @Test("Undo survives a page leaving the window: the stack is the notebook's and the page comes back")
    func undoAcrossPages() async throws {
        let scratch = try Scratch("nb-undo-pages")
        let store = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 2))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let (a, b) = (notebook.pageIDs[0], notebook.pageIDs[1])
        notebook.windowChanged(to: [a, b])
        try await waitUntil { notebook.state(of: a)?.content != nil && notebook.state(of: b)?.content != nil }
        notebook.inkChanged(on: a, Ink.drawing(strokes: 1))
        notebook.inkChanged(on: b, Ink.drawing(strokes: 2))
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
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
        _ = notebook.drainChanges()
        #expect(notebook.undo() == page)
        // Passes without proving anything if a late result has not arrived
        // within the sleep, as on a starved simulator.
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
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
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
        notebook.inkChanged(on: b, Ink.drawing(strokes: 1))
        notebook.inkChanged(on: a, Ink.drawing(strokes: 1))
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

    @Test("An undo into an unloaded page is saved by a close before the page's load lands, in the window or out of it", arguments: [false, true])
    func undoIntoAnUnloadedPageSurvivesClose(leavesTheWindow: Bool) async throws {
        let scratch = try Scratch("nb-undo-close")
        let store = HeldLoadStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
        await notebook.flush()
        notebook.windowChanged(to: [])
        notebook.retired(page, finalInk: nil)
        notebook.prune()
        _ = notebook.drainChanges()

        await store.hold()
        #expect(notebook.undo() == page)
        // A scroll that settles elsewhere cancels the load the undo started,
        // and nothing else would ever adopt the revision.
        if leavesTheWindow { notebook.windowChanged(to: []) }
        let closing = Task { await notebook.close() }
        await store.release()
        #expect(await closing.value == .clean)
        if leavesTheWindow {
            #expect(!notebook.drainChanges().contains { if case .content(let s) = $0 { s.id == page } else { false } }, "a page settled outside the window is not pushed")
            let held = try #require(notebook.state(of: page)?.content)
            #expect(held.retired && held.composite == nil, "held as an import's page is, with no composite")
        }

        let reopened = try await Notebook.open(store: PackageStore(root: scratch.packageURL), schedule: fast)
        reopened.windowChanged(to: [page])
        try await waitUntil { reopened.state(of: page)?.content != nil }
        #expect(reopened.state(of: page)?.content?.ink.strokes.count == 1, "the undone stroke stays undone")
    }

    @Test("A load that a newer load replaced while it rendered is dropped on arrival, and the newer ink installs")
    func staleLoadIsDropped() async throws {
        let scratch = try Scratch("nb-stale")
        let created = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = created.pageIDs[0]
        created.windowChanged(to: [page])
        try await waitUntil { created.state(of: page)?.content != nil }
        try await created.addLayer(Fixture.imageLayer(), assetData: try Fixture.imageData(width: 40, height: 30), on: page)
        created.inkChanged(on: page, Ink.drawing(strokes: 1))
        #expect(await created.close() == .clean)

        let store = GatedAssetStore(PackageStore(root: scratch.packageURL))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        // The first load reads one stroke, then parks in its render's asset
        // read, past every cancellation check: leaving the window cannot stop it.
        notebook.windowChanged(to: [page])
        try await notebook.waitForArrivals(store.gate, 1)
        let first = try #require(notebook.loads[page])
        notebook.windowChanged(to: [])
        try InkContainer.encode(notebookID: notebook.index.notebookID, pageID: page, archive: Ink.drawing(strokes: 3).dataRepresentation())
            .write(to: store.base.layout.inkURL(page))
        // The second load is held before its render, so the first lands
        // while the page is loading again and only the generation tells them apart.
        await store.loadGate.close()
        notebook.windowChanged(to: [page])
        try await notebook.waitForArrivals(store.loadGate, 2)
        await store.gate.release(0)
        await first.value
        if case .loading = notebook.state(of: page)! {} else { Issue.record("the stale load installed: \(String(describing: notebook.state(of: page)))") }

        await store.loadGate.open()
        try await waitUntil { notebook.state(of: page)?.content != nil }
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 3)
    }

    @Test("Prune drops only pages that are retired, outside the window, and clean")
    func pruneIsConservative() async throws {
        let scratch = try Scratch("nb-prune")
        let base = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 3))
        let notebook = try await Notebook.open(store: base, schedule: fast)
        let ids = notebook.pageIDs
        notebook.windowChanged(to: ids)
        try await waitUntil { ids.allSatisfy { notebook.state(of: $0)?.content != nil } }
        notebook.inkChanged(on: ids[1], Ink.drawing(strokes: 1))
        notebook.windowChanged(to: [ids[2]])
        notebook.retired(ids[0], finalInk: nil)
        notebook.retired(ids[1], finalInk: nil)
        notebook.prune()
        if case .unloaded = notebook.state(of: ids[0])! {} else { Issue.record("clean retired page not pruned") }
        #expect(notebook.state(of: ids[1])?.content != nil, "dirty page kept")
        #expect(notebook.state(of: ids[2])?.content != nil, "wanted page kept")
    }

    @Test("A torn-down canvas's final ink lands in custody as an edit and keeps the page from pruning until it is saved")
    func finalInkAtTeardownLandsInCustody() async throws {
        let scratch = try Scratch("nb-final-ink")
        let store = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        #expect(!notebook.canUndo)

        notebook.retired(page, finalInk: Ink.drawing(strokes: 2))
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 2)
        #expect(notebook.state(of: page)?.content?.isDirty == true)
        #expect(notebook.canUndo)
        notebook.windowChanged(to: [])
        notebook.prune()
        #expect(notebook.state(of: page)?.content != nil, "a dirty page is not pruned")

        await notebook.flush()
        notebook.prune()
        if case .unloaded = notebook.state(of: page)! {} else { Issue.record("a saved retired page is pruned") }
        let bytes = try await store.loadPage(page)
        #expect(try PKDrawing(data: try #require(bytes.inkArchive)).strokes.count == 2)
    }

    @Test("A torn-down canvas's final ink equal to custody is no edit")
    func equalFinalInkIsNotAnEdit() async throws {
        let scratch = try Scratch("nb-equal-final-ink")
        let store = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
        // An edit would clear the redo this undo leaves.
        #expect(notebook.undo() == page)
        await notebook.flush()
        let held = notebook.state(of: page)!.content!
        #expect(notebook.canRedo)

        notebook.retired(page, finalInk: held.ink)
        let after = notebook.state(of: page)!.content!
        #expect(after.editSeq == held.editSeq)
        #expect(!after.isDirty)
        #expect(notebook.canRedo, "no entry recorded")
    }

    @Test("A page erased to nothing reopens empty, its ink container written and present")
    func anErasedPageReopensEmpty() async throws {
        let scratch = try Scratch("nb-erased")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
        await notebook.flush()
        notebook.inkChanged(on: page, PKDrawing())
        #expect(await notebook.close() == .clean)

        try await Self.expectReopensEmpty(page, at: scratch.packageURL)
    }

    @Test("A page whose only stroke was undone reopens empty")
    func anUndoneOnlyStrokeReopensEmpty() async throws {
        let scratch = try Scratch("nb-undone")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
        await notebook.flush()
        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.ink.strokes.isEmpty == true)
        #expect(await notebook.close() == .clean)

        try await Self.expectReopensEmpty(page, at: scratch.packageURL)
    }

    private static func expectReopensEmpty(_ page: PageID, at url: URL) async throws {
        let bytes = try await PackageStore(root: url).loadPage(page)
        #expect(bytes.faults.isEmpty)
        #expect(try PKDrawing(data: try #require(bytes.inkArchive, "the container is present")).strokes.isEmpty)
        let reopened = try await Notebook.open(store: PackageStore(root: url), schedule: fast)
        reopened.windowChanged(to: [page])
        try await waitUntil { reopened.state(of: page)?.content != nil }
        #expect(reopened.state(of: page)?.content?.ink.strokes.isEmpty == true)
        #expect(reopened.state(of: page)?.content?.hasInk == true)
    }

    @Test("A page whose load fails after an entry was recorded for it drops that entry")
    func failedLoadForgetsTheEntry() async throws {
        let scratch = try Scratch("nb-failed-load-forgets")
        let store = RefusingLoadStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
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

    // Every layer edit bumps in `commitLayerEdit`, and
    // `contentVersionBumpsOncePerLayerEdit` holds one row per edit. Every
    // other bump site is its own, so this list is the invariant's
    // enforcement: a mutation that changes what a page looks like and is
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
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
        expectBump("ink")
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
        expectBump("ink again")
        notebook.undo()
        expectBump("undo into a loaded page")
        guard case .inkRestored(_, let ink, _) = try #require(notebook.drainChanges().last) else { Issue.record("no restore"); return }
        notebook.inkChanged(on: page, ink)
        expectSame("the echo")
        try await notebook.setPaper(.drawn(.grid), on: page)
        expectBump("paper")

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
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
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
        notebook.inkChanged(on: a, Ink.drawing(strokes: 1))
        notebook.inkChanged(on: b, Ink.drawing(strokes: 1))
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
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
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
        notebook.inkChanged(on: a, Ink.drawing(strokes: 1))
        notebook.inkChanged(on: b, Ink.drawing(strokes: 1))
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
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2))
        let revision = try #require(await notebook.revision(of: page))
        #expect(revision.ink.strokes.count == 2, "custody, before the save engine has written anything")
        withExtendedLifetime(scratch) {}
    }
}
