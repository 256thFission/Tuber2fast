import Foundation
import PencilKit
import Testing
import UIKit
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook

@Suite("Notebook: layers and text sessions")
@MainActor
struct NotebookLayerTests {
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
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
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

    @Test("Insert then undo removes the layer; redo brings it back with its file pending")
    func undoRemovesAnInsertedLayer() async throws {
        let scratch = try Scratch("nb-undo-insert")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let layer = textLayer("hi")
        try notebook.insertLayer(layer, on: page)
        try await waitUntil { notebook.drainChanges().contains { if case .compositeUpdated = $0 { true } else { false } } }
        #expect(notebook.state(of: page)?.content?.layers == [layer])

        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true)
        try await waitUntil {
            notebook.drainChanges().contains { if case .compositeUpdated(let p, _, let layers) = $0 { p == page && layers.isEmpty } else { false } }
        }

        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.layers == [layer])
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

        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.layers == [first, second])
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

    @Test("A begin on a text box an undo relocked opens no session, leaves the page as it was, and ends the session it never opened")
    func beginOnALockedTextBoxOpensNoSession() async throws {
        let scratch = try Scratch("nb-text-begin-locked")
        defer { withExtendedLifetime(scratch) {} }
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let text = Fixture.textLayer()
        try notebook.insertLayer(text, on: page)
        #expect(notebook.setLayerLock(text.id, on: page, locked: true) == .accepted)
        #expect(notebook.setLayerLock(text.id, on: page, locked: false) == .accepted)
        #expect(notebook.undo() == page)
        let before = try #require(notebook.state(of: page)?.content)
        #expect(before.layers == [text.withLock(true)])
        _ = notebook.drainChanges()

        notebook.beginTextEditing(on: page, layer: text.id)
        let after = try #require(notebook.state(of: page)?.content)
        #expect(after.textEditing == nil)
        #expect(after.layers == before.layers)
        #expect(after.revision == before.revision)
        let changes = notebook.drainChanges()
        #expect(changes.contains { if case .textEditingEnded(let p, let l) = $0 { p == page && l == text.id } else { false } }, "\(changes)")
    }

    @Test("A link moves to an origin at its size, undoes, redoes; an image, a bad origin and a locked link are refused")
    func movingALinkIsUndoable() async throws {
        let scratch = try Scratch("nb-move-link")
        defer { withExtendedLifetime(scratch) {} }
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let link = Fixture.linkLayer(to: page)
        try notebook.insertLayer(link, on: page)
        let image = Fixture.imageLayer()
        try await notebook.addLayer(image, assetData: Fixture.archive(1, count: 128), on: page)
        await notebook.flush()

        let moved = PageRect(x: 300, y: 500, width: 160, height: 44)
        #expect(notebook.moveRectLayer(on: page, layer: link.id, to: PagePoint(x: 300, y: 500)) == .accepted)
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

        // A layer its transform places, an origin that makes no rect, and a
        // locked link.
        let couldUndo = notebook.canUndo
        #expect(notebook.moveRectLayer(on: page, layer: image.id, to: PagePoint(x: 300, y: 500)) == .refused(reason: "layer \(image.id) is placed by its transform"))
        #expect(notebook.moveRectLayer(on: page, layer: link.id, to: PagePoint(x: .nan, y: 10)) != .accepted)
        #expect(notebook.canUndo == couldUndo, "a refusal records nothing")
        #expect(notebook.setLayerLock(link.id, on: page, locked: true) == .accepted)
        #expect(notebook.moveRectLayer(on: page, layer: link.id, to: PagePoint(x: 0, y: 0)) == .refused(reason: "layer \(link.id) is locked"))
        guard case .link(let unchanged) = try #require(notebook.state(of: page)?.content?.layers.first { $0.id == link.id }).payload else {
            Issue.record("the layer stopped being a link"); return
        }
        #expect(unchanged.rect == moved)
    }

    @Test("A text box moves to an origin at its size with its words, undoes and redoes")
    func movingATextBoxIsUndoable() async throws {
        let scratch = try Scratch("nb-move-text")
        defer { withExtendedLifetime(scratch) {} }
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let text = Fixture.textLayer()
        try notebook.insertLayer(text, on: page)
        await notebook.flush()

        #expect(notebook.moveRectLayer(on: page, layer: text.id, to: PagePoint(x: 120, y: 400)) == .accepted)
        let after = try #require(notebook.state(of: page)?.content?.layers.first { $0.id == text.id })
        guard case .text(let typed) = text.payload, case .text(let moved) = after.payload else {
            Issue.record("the layer stopped being text"); return
        }
        #expect(moved.rect == PageRect(x: 120, y: 400, width: 300, height: 80))
        #expect(moved.runs == typed.runs && moved.alignment == typed.alignment, "only the rect moves")
        #expect(after.transform == .identity)
        #expect(notebook.isDirty)

        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.layers == [text])
        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.layers == [after])
    }

    @Test("A link deleted from its frame goes in one entry, and Undo brings it back whole")
    func deletingASelectedLinkIsUndoable() async throws {
        let scratch = try Scratch("nb-delete-link")
        defer { withExtendedLifetime(scratch) {} }
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let link = Fixture.linkLayer(to: page)
        try notebook.insertLayer(link, on: page)
        await notebook.flush()

        #expect(notebook.deleteLayer(link.id, on: page) == .accepted)
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true)
        #expect(notebook.isDirty)

        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.layers == [link])
        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true)
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
        #expect(notebook.state(of: page)?.content?.layers == [layer])
        #expect(notebook.transformLayer(on: page, layer: layer.id, to: .translation(x: 5, y: 5)) == .accepted)
        #expect(notebook.transformLayer(on: page, layer: layer.id, to: PageSpaceTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0)) == .refused(reason: "invalidTransform(\(layer.id))"))
        await notebook.flush()
        let bytes = try await PackageStore(root: scratch.packageURL).loadPage(page)
        #expect(bytes.file.layers == [layer.id])
        #expect(bytes.layers.first?.transform == .translation(x: 5, y: 5))
        notebook.deleteLayer(layer.id, on: page)
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true)
        await notebook.flush()
        let after = try await PackageStore(root: scratch.packageURL).loadPage(page)
        #expect(after.file.layers.isEmpty)
    }

    @Test("Layers stack in the order they were inserted, all beneath the ink: in memory, in the composite, on disk")
    func layersStackInInsertionOrder() async throws {
        let scratch = try Scratch("nb-layer-order")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let ink = Ink.drawing(strokes: 2)
        notebook.inkChanged(on: page, ink)
        let first = textLayer("first"), second = textLayer("second")
        try notebook.insertLayer(first, on: page)
        try notebook.insertLayer(second, on: page)

        #expect(notebook.state(of: page)?.content?.layers == [first, second], "the second lands on top of the first")
        #expect(notebook.state(of: page)?.content?.ink == ink, "the ink is no layer, and an insert does not touch it")
        try await waitUntil {
            notebook.drainChanges().contains { if case .compositeUpdated(let p, _, let layers) = $0 { p == page && layers == [first, second] } else { false } }
        }
        await notebook.flush()
        let bytes = try await PackageStore(root: scratch.packageURL).loadPage(page)
        #expect(bytes.file.layers == [first.id, second.id])
        #expect(bytes.file.hasInk)
    }

    @Test("An undo of a deleted image after a compact brings back its asset too, and the page saves")
    func undoOfADeletedImageAfterCompactSaves() async throws {
        let scratch = try Scratch("nb-compact-undo")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let layer = Fixture.imageLayer()
        let layout = PackageLayout(root: scratch.packageURL)
        try await notebook.addLayer(layer, assetData: Fixture.archive(1, count: 128), on: page)
        await notebook.flush()
        #expect(notebook.deleteLayer(layer.id, on: page) == .accepted)
        await notebook.flush()

        _ = try await notebook.store.compact(now: .now + 2 * 86_400, keeping: notebook.assetsInUse)
        #expect(try !PosixFileSystem().exists(layout.layerURL(layer.id)), "the orphaned layer file went")
        #expect(try PosixFileSystem().exists(layout.assetURL(layer.payload.asset!)), "the undo stack names the asset")

        #expect(notebook.undo() == page)
        await notebook.flush()
        #expect(notebook.lastSaveError == nil)
        #expect(try PosixFileSystem().exists(layout.layerURL(layer.id)), "the restore rewrote the layer file")
        #expect(await notebook.close() == .clean)
    }

    @Test("A redo of an undone image insert after a compact brings back its asset too, and the page saves")
    func redoOfAnUndoneInsertAfterCompactSaves() async throws {
        let scratch = try Scratch("nb-compact-redo")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let layer = Fixture.imageLayer()
        let layout = PackageLayout(root: scratch.packageURL)
        try await notebook.addLayer(layer, assetData: Fixture.archive(1, count: 128), on: page)
        await notebook.flush()
        #expect(notebook.undo() == page)
        await notebook.flush()

        _ = try await notebook.store.compact(now: .now + 2 * 86_400, keeping: notebook.assetsInUse)
        #expect(try !PosixFileSystem().exists(layout.layerURL(layer.id)), "the orphaned layer file went")
        #expect(try PosixFileSystem().exists(layout.assetURL(layer.payload.asset!)), "the redo stack names the asset")

        #expect(notebook.redo() == page)
        await notebook.flush()
        #expect(notebook.lastSaveError == nil)
        #expect(await notebook.close() == .clean)
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
        #expect(notebook.state(of: page)?.content?.isDirty == true)
        try await waitUntil { notebook.drainChanges().contains { if case .textEditingEnded = $0 { true } else { false } } }
        await notebook.flush()
        let bytes = try await PackageStore(root: scratch.packageURL).loadPage(page)
        #expect(bytes.file.layers.isEmpty)
        // Begin while a session is open, a commit for the wrong layer, and an
        // invalid committed rect are traps, which Swift Testing cannot observe.
    }

    @Test("Two renders on one held read install only the newer one, and the text changes ride behind it")
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
        // The decoded asset is cached; purge so the next render reads.
        await notebook.renderer.purge()

        notebook.beginTextEditing(on: page, layer: text.id)
        try await notebook.waitForArrivals(store.gate, 2)
        guard case .text(let value) = try #require(notebook.state(of: page)?.content?.layers.last?.payload) else { Issue.record("not text"); return }
        notebook.endTextEditing(on: page, layer: text.id, value)
        // The commit's render waits on the begin's read instead of opening one.
        // Passes without proving anything if a late result has not arrived
        // within the sleep, as on a starved simulator.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await store.gate.arrivals == 2)
        #expect(notebook.drainChanges().isEmpty, "nothing lands while the read is parked")

        // The read lands both renders, in either order; the begin's is stale.
        await store.gate.release(1)
        try await waitUntil { notebook.state(of: page)?.content?.afterRender.isEmpty == true }
        // Passes without proving anything if a late result has not arrived
        // within the sleep, as on a starved simulator.
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

    // MARK: Layer edits

    /// A page holding an image, a link and a text box, in that order, saved
    /// and clean, for the layer-edit tests to edit.
    private func pageWithLayers(_ name: String) async throws -> (Scratch, Notebook, PageID, image: Layer, link: Layer, text: Layer) {
        let (scratch, notebook, page) = try await readyPage(name)
        let image = Fixture.imageLayer(), link = Fixture.linkLayer(to: page), text = textLayer("hi")
        try await notebook.addLayer(image, assetData: Fixture.archive(1, count: 128), on: page)
        try notebook.insertLayer(link, on: page)
        try notebook.insertLayer(text, on: page)
        await notebook.flush()
        #expect(!notebook.isDirty)
        return (scratch, notebook, page, image, link, text)
    }

    @Test("Each layer edit bumps the content version once and dirties the page", arguments: LayerEdit.allCases)
    func contentVersionBumpsOncePerLayerEdit(_ edit: LayerEdit) async throws {
        let (scratch, notebook, page, image, link, text) = try await pageWithLayers("nb-version-\(edit)")
        guard case .text(let typed) = text.payload else { Issue.record("not text"); return }
        let version = notebook.contentVersion(of: page)

        switch edit {
        case .insert:
            try notebook.insertLayer(textLayer("more"), on: page)
        case .transform:
            #expect(notebook.transformLayer(on: page, layer: image.id, to: .translation(x: 1, y: 1)) == .accepted)
        case .lock:
            #expect(notebook.setLayerLock(image.id, on: page, locked: true) == .accepted)
        case .delete:
            #expect(notebook.deleteLayer(image.id, on: page) == .accepted)
        case .moveLink:
            #expect(notebook.moveRectLayer(on: page, layer: link.id, to: PagePoint(x: 300, y: 500)) == .accepted)
        case .moveText:
            #expect(notebook.moveRectLayer(on: page, layer: text.id, to: PagePoint(x: 300, y: 500)) == .accepted)
        case .commitText:
            notebook.beginTextEditing(on: page, layer: text.id)
            notebook.endTextEditing(on: page, layer: text.id, TextLayer(rect: typed.rect, runs: [TextRun(string: "ho", style: .body)], alignment: .leading))
        case .emptyText:
            notebook.beginTextEditing(on: page, layer: text.id)
            notebook.endTextEditing(on: page, layer: text.id, TextLayer(rect: typed.rect, runs: [], alignment: .leading))
        }

        #expect(notebook.contentVersion(of: page) == version + 1)
        #expect(notebook.isDirty)
        _ = await notebook.close()
        _ = scratch
    }

    @Test("A layer edit to the value the page holds bumps nothing, dirties nothing, owes no file and records nothing")
    func sameValueLayerEditsLeaveThePageClean() async throws {
        let (scratch, notebook, page, image, link, text) = try await pageWithLayers("nb-same-value")
        guard case .text(let typed) = text.payload, case .link(let placed) = link.payload else { Issue.record("payloads"); return }
        // Something to redo, which a record would clear.
        try notebook.insertLayer(textLayer("undone"), on: page)
        #expect(notebook.undo() == page)
        await notebook.flush()
        #expect(!notebook.isDirty)
        let version = notebook.contentVersion(of: page)
        let pending = notebook.state(of: page)?.content?.pendingLayerFiles

        #expect(notebook.setLayerLock(image.id, on: page, locked: false) == .accepted)
        #expect(notebook.transformLayer(on: page, layer: image.id, to: image.transform) == .accepted)
        #expect(notebook.moveRectLayer(on: page, layer: link.id, to: PagePoint(x: placed.rect.x, y: placed.rect.y)) == .accepted)
        #expect(notebook.moveRectLayer(on: page, layer: text.id, to: PagePoint(x: typed.rect.x, y: typed.rect.y)) == .accepted)
        notebook.beginTextEditing(on: page, layer: text.id)
        notebook.endTextEditing(on: page, layer: text.id, typed)

        #expect(notebook.contentVersion(of: page) == version)
        #expect(!notebook.isDirty)
        #expect(notebook.state(of: page)?.content?.pendingLayerFiles == pending)
        #expect(notebook.canRedo, "a record would have cleared redo")
        _ = await notebook.close()
        _ = scratch
    }

    // MARK: Text sessions on the stack

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
        #expect(!notebook.canUndo, "one step took the box and its text")

        #expect(notebook.redo() == page)
        #expect(notebook.state(of: page)?.content?.layers.map(\.payload) == [.text(typed)])
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
        notebook.endTextEditing(on: page, layer: box, TextLayer(rect: TextLayer.newBox.moved(to: PagePoint(x: 30, y: 40)), runs: [], alignment: .leading))
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true)
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
        #expect(notebook.state(of: page)?.content?.textEditing != nil)
        #expect(notebook.state(of: other)?.content?.textEditing == nil)
        #expect(notebook.state(of: page)?.content?.textEditing?.before.layers.isEmpty == true, "captured ahead of the insert")
        let box = try #require(notebook.state(of: page)?.content?.textEditing?.layer)
        notebook.endTextEditing(on: page, layer: box, TextLayer(rect: TextLayer.newBox.moved(to: PagePoint(x: 30, y: 40)), runs: [], alignment: .leading))
        #expect(!notebook.hasTextSession && notebook.state(of: page)?.content?.textEditing == nil)
        _ = await notebook.close()
        _ = scratch
    }
}
