import Foundation
import PencilKit
import Testing
import UIKit
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook

@Suite("Notebook: pages, bookmarks, paper and imports")
@MainActor
struct NotebookPagesTests {
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
        #expect(reopened.index.pages[1].paper == .drawn(.blank))

        try await notebook.setPaper(.drawn(.grid), on: second)
        notebook.movePage(second, before: first)
        await notebook.flush()
        var again = try await PackageStore(root: scratch.packageURL).load()
        #expect(again.index.pageIDs == [second, first])
        #expect(again.index.pages[0].paper == .drawn(.grid))
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
        notebook.inkChanged(on: a, Ink.drawing(strokes: 1))
        notebook.inkChanged(on: b, Ink.drawing(strokes: 1))
        notebook.inkChanged(on: a, Ink.drawing(strokes: 2))
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
        notebook.inkChanged(on: a, Ink.drawing(strokes: 1))
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
        // Passes without proving anything if a late result has not arrived
        // within the sleep, as on a starved simulator.
        try await Task.sleep(for: .milliseconds(100))
        #expect(notebook.state(of: a) == nil)
        #expect(notebook.pageIDs == [b])
        #expect(!notebook.drainChanges().contains { if case .content = $0 { true } else { false } }, "the cancelled load installs nothing")
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

    @Test("Importing a PDF makes one page per PDF page, each with that page as paper and no layer")
    func pdfPagesArePaper() async throws {
        let scratch = try Scratch("nb-pdf-paper")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        // Not loaded, so not known to be blank: the PDF follows it.
        let first = notebook.pageIDs[0]
        try await notebook.importPDF(try Fixture.pdfData(pages: 2))
        #expect(notebook.pageCount == 3)
        let imported = Array(notebook.pageIDs.dropFirst())
        for (offset, page) in imported.enumerated() {
            let record = try #require(notebook.index.record(of: page))
            guard case .pdf(let asset, let sourcePageIndex) = record.paper else {
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
        #expect(bytes.file.layers.isEmpty)
    }

    @Test("A PDF with a page that has no page box is refused whole, and nothing is made or written")
    func aPDFWithAnEmptyBoxPageIsRefused() async throws {
        let scratch = try Scratch("nb-pdf-empty-box")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let before = notebook.pageIDs
        _ = notebook.drainChanges()
        let pdf = try Fixture.shapedPDF(sizes: [CGSize(width: 400, height: 600), .zero])

        await #expect(throws: FormatFault.invalidWrite("PDF page 2 has no page box")) { try await notebook.importPDF(pdf) }

        #expect(notebook.pageIDs == before)
        #expect(notebook.drainChanges().isEmpty)
        #expect(!notebook.isDirty)
        let assets = scratch.packageURL.appendingPathComponent("assets").path
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: assets)) ?? []).isEmpty)
    }

    @Test("A turned PDF page imports turned, and a cropped one at its crop's size")
    func rotatedAndCroppedPagesKeepTheirShape() async throws {
        let scratch = try Scratch("nb-pdf-shape")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let size = CGSize(width: 400, height: 600)

        let turned = try await notebook.importPDF(try Fixture.shapedPDF(sizes: [size], rotation: 90))
        let cropped = try await notebook.importPDF(try Fixture.shapedPDF(sizes: [size], cropBox: CGRect(x: 50, y: 60, width: 300, height: 200)))

        #expect(notebook.index.record(of: turned[0])?.geometry == PageGeometry(width: 600, height: 400))
        #expect(notebook.index.record(of: cropped[0])?.geometry == PageGeometry(width: 300, height: 200))
        withExtendedLifetime(scratch) {}
    }

    @Test("A PDF takes the place of a lined only page whose one stroke was drawn and undone, and the redo goes with it")
    func aPageWhoseInkWasUndoneIsReplaced() async throws {
        let (scratch, notebook, page) = try await readyPage("nb-pdf-undone")
        try await notebook.setPaper(.drawn(.lined), on: page)
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1))
        #expect(notebook.undo() == page)
        #expect(notebook.canRedo)

        let created = try await notebook.importPDF(try Fixture.pdfData(pages: 2))

        #expect(notebook.pageIDs == created)
        #expect(notebook.currentPageID == created[0])
        #expect(notebook.state(of: page) == nil)
        #expect(!notebook.canRedo, "the entry named a page the notebook no longer holds")
        _ = await notebook.close()
        _ = scratch
    }

    @Test("A PDF page with nothing on it is not blank paper: the next PDF follows it")
    func aPDFPageIsNotABlankPage() async throws {
        let (scratch, notebook, _) = try await readyPage("nb-pdf-not-blank")
        let first = try await notebook.importPDF(try Fixture.pdfData(pages: 1))
        #expect(notebook.pageIDs == first)

        let second = try await notebook.importPDF(try Fixture.pdfData(pages: 1))

        #expect(notebook.pageIDs == first + second)
        _ = await notebook.close()
        _ = scratch
    }

    @Test("A PDF's pages are pushed only when the window names them: after a save and one window change, only the window's pages hold a composite")
    func importHoldsCompositesOnlyForTheWindow() async throws {
        let (scratch, notebook, _) = try await readyPage("nb-pdf-window")
        _ = notebook.drainChanges()

        let created = try await notebook.importPDF(try Fixture.pdfData(pages: 30))

        #expect(notebook.pageIDs == created)
        let changes = notebook.drainChanges()
        #expect(changes.allSatisfy { if case .structure = $0 { true } else { false } }, "\(changes)")
        #expect(created.allSatisfy { notebook.state(of: $0)?.content?.composite == nil })

        await notebook.flush()
        // What the runtime reports once it lands on the first page.
        let window = Array(created.prefix(3))
        notebook.windowChanged(to: window)
        notebook.prune()

        try await waitUntil { window.allSatisfy { notebook.state(of: $0)?.content?.composite != nil } }
        let pushed = notebook.drainChanges().compactMap { if case .content(let snapshot) = $0 { snapshot.id } else { nil } }
        #expect(pushed == window)
        for page in created.dropFirst(window.count) {
            guard case .unloaded = notebook.state(of: page) else {
                Issue.record("page \(page) outside the window is \(String(describing: notebook.state(of: page)))"); continue
            }
        }
        _ = await notebook.close()
        _ = scratch
    }

    @Test("Setting the paper a page already has writes nothing and pushes nothing")
    func settingTheSamePaperWritesNothing() async throws {
        let scratch = try Scratch("nb-same-paper")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        let paper = try #require(notebook.paper(of: page))
        await notebook.flush()
        _ = notebook.drainChanges()
        #expect(!notebook.isDirty)
        let version = notebook.contentVersion(of: page)

        try await notebook.setPaper(paper, on: page)

        #expect(!notebook.isDirty, "the index is not owed a write")
        #expect(notebook.contentVersion(of: page) == version)
        #expect(notebook.drainChanges().isEmpty)
        _ = await notebook.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("Asset paper needs an empty page, takes the asset's aspect, and dirties the index; a PDF page keeps its paper")
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
        let pdf = try #require(notebook.paper(of: source))
        await #expect(throws: PaperRefusal.pageHasAssetPaper) { try await notebook.setPaper(.drawn(.lined), on: source) }
        await #expect(throws: PaperRefusal.pageHasAssetPaper) { try await notebook.setPaper(.image(flattened), on: source) }
        #expect(notebook.paper(of: source) == pdf)

        notebook.inkChanged(on: letter, Ink.drawing(strokes: 1))
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
        #expect(record.paper == .image(flattened))

        await notebook.flush()
        let reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.pageFaults.isEmpty)
        let saved = try #require(reopened.index.record(of: empty))
        #expect(saved.paper == .image(flattened) && abs(saved.height - 918) < 1)
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
        notebook.inkChanged(on: source, Ink.drawing(strokes: 2))
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
        #expect(reopened.index.record(of: photoPage)?.paper == .image(photo))
        #expect(reopened.index.record(of: after)?.paper == .drawn(.blank))
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
        notebook.inkChanged(on: source, Ink.drawing(strokes: 2))
        let before = try #require(notebook.state(of: source)?.content)
        let couldUndo = notebook.canUndo

        let copy = try await notebook.duplicatePage(source)

        #expect(notebook.pageIDs == [first, source, copy], "the copy follows the source")
        let copied = try #require(notebook.state(of: copy)?.content)
        #expect(copied.ink == before.ink)
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
        notebook.inkChanged(on: source, ink)
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

    @Test("A page deleted while its files are read for a duplicate is refused, and nothing is inserted")
    func aPageDeletedDuringDuplicateIsRefused() async throws {
        let scratch = try Scratch("nb-duplicate-deleted")
        let store = GatedLoadStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 2)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let (source, other) = (notebook.pageIDs[0], notebook.pageIDs[1])

        let duplicate = Task { try await notebook.duplicatePage(source) }
        try await notebook.waitForArrivals(store.gate, 1)
        notebook.deletePage(source)
        await store.gate.release(0)

        await #expect(throws: FormatFault.invalidWrite("page \(source) was deleted while it was read")) { try await duplicate.value }
        #expect(notebook.pageIDs == [other])
        withExtendedLifetime(scratch) {}
    }

    @Test("A page deleted while a new page's asset paper is measured is refused as the page to follow")
    func aPageDeletedDuringAnAssetAppendIsRefused() async throws {
        let scratch = try Scratch("nb-append-deleted")
        let store = GatedAssetStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 2)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let (first, second) = (notebook.pageIDs[0], notebook.pageIDs[1])
        let asset = try await notebook.storeImageAsset(try Fixture.imageData(width: 200, height: 100))

        let append = Task { try await notebook.appendPage(after: first, geometry: .letter, paper: .asset(.image(asset))) }
        try await notebook.waitForArrivals(store.gate, 1)
        notebook.deletePage(first)
        await store.gate.release(0)

        await #expect(throws: NewPageRefusal.pageGone(first)) { try await append.value }
        #expect(notebook.pageIDs == [second])
        withExtendedLifetime(scratch) {}
    }

    @Test("A scan whose page to follow is deleted while it is measured inserts nothing")
    func aScanWhosePageIsDeletedInsertsNothing() async throws {
        let scratch = try Scratch("nb-scan-deleted")
        let store = GatedAssetStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 2)))
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let (first, second) = (notebook.pageIDs[0], notebook.pageIDs[1])
        let image = try Fixture.imageData(width: 200, height: 100)
        _ = notebook.drainChanges()

        let scan = Task { try await notebook.importScan([image]) }
        try await notebook.waitForArrivals(store.gate, 1)
        notebook.deletePage(first)
        _ = notebook.drainChanges()
        await store.gate.release(0)

        await #expect(throws: FormatFault.invalidWrite("the page the scan would follow is gone")) { try await scan.value }
        #expect(notebook.pageIDs == [second])
        #expect(notebook.drainChanges().isEmpty)
        withExtendedLifetime(scratch) {}
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
        #expect(notebook.state(of: page)?.content?.textEditing != nil)

        await #expect(throws: FormatFault.self) { try await notebook.duplicatePage(page) }
        #expect(notebook.pageCount == 1, "a refused duplicate inserts nothing")
    }

    @Test("An image, a link or a flatten on a page with a text box open is refused, and leaves no entry and no asset")
    func insertUnderAnOpenTextBoxThrows() async throws {
        let (scratch, notebook, page) = try await readyPage("nb-insert-text")
        // Something to redo, which a record would clear.
        try notebook.insertLayer(textLayer("undone"), on: page)
        #expect(notebook.undo() == page)
        notebook.createTextBox(on: page, at: PagePoint(x: 40, y: 40), style: .body, alignment: .leading)
        let assets = scratch.packageURL.appendingPathComponent("assets").path
        let assetsBefore = try FileManager.default.contentsOfDirectory(atPath: assets)
        let refusal = FormatFault.invalidWrite("page \(page) has a text box open")

        await #expect(throws: refusal) { try await notebook.importImage(try Fixture.imageData(width: 40, height: 30), on: page) }
        #expect(throws: refusal) { try notebook.addLinkLayer(on: page, rect: PageRect(x: 10, y: 10, width: 160, height: 44), target: .internalPage(page)) }
        await #expect(throws: refusal) { try await notebook.flatten(page) }

        #expect(notebook.state(of: page)?.content?.layers.count == 1, "only the box")
        #expect(!notebook.canUndo)
        #expect(notebook.canRedo, "a record would have cleared redo")
        #expect(try FileManager.default.contentsOfDirectory(atPath: assets) == assetsBefore, "a refusal publishes no asset")
        _ = await notebook.close()
        _ = scratch
    }

    @Test("A page appended at a stated size and paper lands that record and survives a reopen")
    func appendAtAStatedSizeAndPaper() async throws {
        let scratch = try Scratch("nb-append-size")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let first = notebook.pageIDs[0]
        let a4Landscape = try #require(PageSize.a4.geometry(.landscape))
        let page = try await notebook.appendPage(after: first, geometry: a4Landscape, paper: .drawn(.grid))
        #expect(notebook.index.record(of: page)?.geometry == PageGeometry(width: 842, height: 595))
        #expect(notebook.index.record(of: page)?.paper == .drawn(.grid))

        await notebook.flush()
        let reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.pageFaults.isEmpty)
        #expect(reopened.index.pageIDs == [first, page])
        let saved = try #require(reopened.index.record(of: page))
        #expect(saved.width == 842 && saved.height == 595)
        #expect(saved.paper == .drawn(.grid))
        // The first page kept the size it was created at.
        #expect(reopened.index.record(of: first)?.geometry == .letter)
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
        #expect(record.paper == .image(asset))
        let structures = notebook.drainChanges().filter { if case .structure = $0 { true } else { false } }
        #expect(structures.count == 1, "the size and the paper are one change, not an append and then a paper change")

        await notebook.flush()
        let reopened = try await PackageStore(root: scratch.packageURL).load()
        #expect(reopened.pageFaults.isEmpty)
        let saved = try #require(reopened.index.record(of: page))
        #expect(saved.geometry == PageGeometry(width: 612, height: 306))
        #expect(saved.paper == .image(asset))
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
