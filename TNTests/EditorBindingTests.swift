import Foundation
import PencilKit
import Testing
import UIKit
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook

/// What the runtime was told, in order. Identities and sequences only:
/// what a test can assert about is the seam's vocabulary, not pixels.
enum SurfaceCall: Sendable, Equatable {
    case setPages([PageID], seq: StructureSeq, answering: ReportSeq?)
    case installContent(PageID, editable: Bool)
    case restoreInk(PageID, seq: InkSeq)
    case scroll(PageID)
    case retireAll
    case unload(PageID)
    case updateComposite(PageID)
    case beginTextEditing(PageID, LayerID)
    case endTextEditing(PageID, LayerID)
    case undoTyping
    case redoTyping
    case endToolUses
}

/// A surface that records instead of drawing. It stands where
/// `PagedCanvasController` stands, which is what lets the binding be
/// tested in a bundle with no host app and no Pencil.
@MainActor
final class RecordingSurface: CanvasRuntime {
    private(set) var calls: [SurfaceCall] = []
    private(set) var environments: [CanvasEnvironment] = []
    private(set) var layersSeen: [PageID: [Layer]] = [:]
    private(set) var starts: [TextEditStart] = []
    /// Pages whose retire this surface defers, as a stroke in flight does.
    var deferring: Set<PageID> = []
    /// What the runtime answers when the binding asks, as a Pencil held
    /// down would make it answer.
    var isStrokeInFlight = false

    func setPages(_ pages: [PageDescriptor], seq: StructureSeq, answering: ReportSeq?) {
        calls.append(.setPages(pages.map(\.id), seq: seq, answering: answering))
    }

    func installContent(_ snapshot: PageSnapshot) {
        calls.append(.installContent(snapshot.id, editable: snapshot.isEditable))
    }

    func restoreInk(on page: PageID, _ ink: PKDrawing, seq: InkSeq) {
        calls.append(.restoreInk(page, seq: seq))
    }

    func scroll(to page: PageID) { calls.append(.scroll(page)) }

    func unload(_ page: PageID) { calls.append(.unload(page)) }

    func updateComposite(on page: PageID, _ composite: Composite, layers: [Layer]) {
        calls.append(.updateComposite(page))
        layersSeen[page] = layers
    }

    func beginTextEditing(on page: PageID, _ start: TextEditStart) {
        calls.append(.beginTextEditing(page, start.layer))
        starts.append(start)
    }

    func endTextEditing(on page: PageID, layer: LayerID) { calls.append(.endTextEditing(page, layer)) }

    func apply(_ environment: CanvasEnvironment) { environments.append(environment) }

    func undoTyping() { calls.append(.undoTyping) }
    func redoTyping() { calls.append(.redoTyping) }

    func retireAll() -> [PageID] {
        calls.append(.retireAll)
        return Array(deferring)
    }

    func setUndoAvailability(canUndo: Bool, canRedo: Bool) {}

    func endToolUses() { calls.append(.endToolUses) }

    // MARK: What a test asks

    var pagesSet: [[PageID]] {
        calls.compactMap { if case .setPages(let ids, _, _) = $0 { ids } else { nil } }
    }

    var installed: [PageID] {
        calls.compactMap { if case .installContent(let page, _) = $0 { page } else { nil } }
    }

    func answered(_ seq: ReportSeq) -> [PageID]? {
        for call in calls.reversed() {
            if case .setPages(let ids, _, let answering) = call, answering == seq { return ids }
        }
        return nil
    }
}

@Suite("EditorBinding: reports up, pushes down")
@MainActor
struct EditorBindingTests {
    /// A notebook with `pages` pages, saved and reopened, so every page is
    /// unloaded and a window has real work to do. `leftOn` is the index of the
    /// page it was last looking at, which `close()` writes to `view.json`.
    private func reopened(_ name: String, pages: Int, leftOn: Int? = nil) async throws -> (Scratch, Notebook) {
        let scratch = try Scratch(name)
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        for _ in 1..<pages { notebook.appendPage() }
        if let leftOn { notebook.pageBecameCurrent(notebook.pageIDs[leftOn]) }
        await notebook.flush()
        _ = await notebook.close()
        let store = PackageStore(root: scratch.packageURL)
        return (scratch, try await Notebook.open(store: store, schedule: fast))
    }

    @Test("Opening pushes the page order down before anything is asked for")
    func openingPushesSetPages() async throws {
        let scratch = try Scratch("editor-open")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)

        #expect(surface.pagesSet.contains(notebook.pageIDs))
        #expect(surface.installed.isEmpty, "no page is loaded until a window asks for one")
        _ = binding
        _ = await notebook.close()
    }

    @Test("A notebook left on page three opens there: the saved page is pushed after the order")
    func openingScrollsToTheSavedPage() async throws {
        let (scratch, notebook) = try await reopened("editor-reopen-current", pages: 3, leftOn: 2)
        let third = notebook.pageIDs[2]
        #expect(notebook.currentPageID == third, "view.json is read into the notebook")

        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)

        let order = try #require(surface.calls.firstIndex { if case .setPages = $0 { true } else { false } })
        let scroll = try #require(surface.calls.firstIndex(of: .scroll(third)))
        #expect(scroll > order, "the runtime must know the page list before it can be sent to one of them")

        _ = binding
        _ = scratch
        _ = await notebook.close()
    }

    @Test("A window report leads to content for those pages once they load")
    func windowChangedInstallsContent() async throws {
        let (scratch, notebook) = try await reopened("editor-window", pages: 3)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let pages = notebook.pageIDs

        #expect(surface.installed.isEmpty)
        binding.windowChanged(to: pages)
        try await waitUntil { Set(surface.installed) == Set(pages) }
        #expect(surface.calls.allSatisfy {
            if case .installContent(_, let editable) = $0 { editable } else { true }
        })
        _ = await notebook.close()
        _ = scratch
    }

    @Test("Pruning a page tells the runtime to forget its content, and the page comes back by a new install")
    func pruneTellsTheRuntimeWhatItDropped() async throws {
        let (scratch, notebook) = try await reopened("editor-prune", pages: 3)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let (first, second) = (notebook.pageIDs[0], notebook.pageIDs[1])
        binding.windowChanged(to: [first])
        try await waitUntil { surface.installed.contains(first) }
        binding.retired(first, finalInk: nil)

        binding.windowChanged(to: [second])
        #expect(surface.calls.contains(.unload(first)))
        if case .unloaded = notebook.state(of: first) {} else { Issue.record("page is \(String(describing: notebook.state(of: first)))") }

        binding.windowChanged(to: [first])
        try await waitUntil { surface.installed.count { $0 == first } == 2 }
        _ = await notebook.close()
        _ = scratch
    }

    @Test("Undo after an ink report restores that page's ink and scrolls to it")
    func undoRestoresInkAndScrolls() async throws {
        let scratch = try Scratch("editor-undo")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let page = notebook.pageIDs[0]

        binding.windowChanged(to: [page])
        try await waitUntil { surface.installed.contains(page) }
        binding.inkChanged(on: page, Ink.drawing(strokes: 3), echoOf: nil)
        #expect(notebook.canUndo)

        binding.undoRequested()
        let restored = surface.calls.contains { if case .restoreInk(let p, _) = $0 { p == page } else { false } }
        #expect(restored)
        #expect(surface.calls.contains(.scroll(page)))
        #expect(notebook.state(of: page)?.content?.ink.strokes.isEmpty == true)
        _ = await notebook.close()
    }

    @Test("An ink report reaches the notebook with the bindings the closure answers")
    func inkReportsCarryTheBindings() async throws {
        let scratch = try Scratch("editor-gesture")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        notebook.appendPage()
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let (unbound, bound) = (notebook.pageIDs[0], notebook.pageIDs[1])
        binding.windowChanged(to: [unbound, bound])
        try await waitUntil { surface.installed.contains(unbound) && surface.installed.contains(bound) }

        // Three lines down the page and a scratch-out across the top two.
        let lines = (0..<3).map {
            Ink.line(from: CGPoint(x: 0, y: CGFloat($0) * 50), to: CGPoint(x: 200, y: CGFloat($0) * 50))
        }
        let scribbled = PKDrawing(strokes: lines + [Ink.zigzag(over: CGRect(x: 20, y: -10, width: 80, height: 70), turns: 4)])

        // The default answer is no gesture at all, so the scratch-out is ink.
        binding.inkChanged(on: unbound, PKDrawing(strokes: lines), echoOf: nil)
        binding.inkChanged(on: unbound, scribbled, echoOf: nil)
        #expect(notebook.state(of: unbound)?.content?.ink.strokes.count == 4)
        #expect(!surface.calls.contains { if case .restoreInk(let p, _) = $0 { p == unbound } else { false } })

        binding.bindingsForStroke = { [.scribble: .erase] }
        binding.inkChanged(on: bound, PKDrawing(strokes: lines), echoOf: nil)
        binding.inkChanged(on: bound, scribbled, echoOf: nil)
        #expect(notebook.state(of: bound)?.content?.ink.strokes.count == 1, "the two crossed lines and the scribble are gone")
        #expect(surface.calls.contains { if case .restoreInk(let p, _) = $0 { p == bound } else { false } })
        _ = await notebook.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("Undo and redo are ignored while the runtime has a stroke in flight, and the stack is untouched")
    func undoIsIgnoredWhileAStrokeIsInFlight() async throws {
        let scratch = try Scratch("editor-undo-under-stroke")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let page = notebook.pageIDs[0]
        binding.windowChanged(to: [page])
        try await waitUntil { surface.installed.contains(page) }
        binding.inkChanged(on: page, Ink.drawing(strokes: 3), echoOf: nil)
        surface.isStrokeInFlight = true
        let told = surface.calls.count

        binding.undoRequested()
        binding.redoRequested()
        #expect(surface.calls.count == told, "nothing was pushed and nothing scrolled")
        #expect(notebook.canUndo && !notebook.canRedo, "the stack did not move")
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 3)

        surface.isStrokeInFlight = false
        binding.undoRequested()
        #expect(surface.calls.contains { if case .restoreInk(let p, _) = $0 { p == page } else { false } })
        #expect(surface.calls.last == .scroll(page))
        _ = await notebook.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("A commit that lands under the next stroke is kept as ink, and no restore is pushed")
    func aReportUnderAStrokeRunsNoGesture() async throws {
        let scratch = try Scratch("editor-gesture-under-stroke")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        notebook.appendPage()
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let (underAStroke, atRest) = (notebook.pageIDs[0], notebook.pageIDs[1])
        binding.windowChanged(to: [underAStroke, atRest])
        try await waitUntil { surface.installed.contains(underAStroke) && surface.installed.contains(atRest) }
        let lines = (0..<3).map {
            Ink.line(from: CGPoint(x: 0, y: CGFloat($0) * 50), to: CGPoint(x: 200, y: CGFloat($0) * 50))
        }
        let scribbled = PKDrawing(strokes: lines + [Ink.zigzag(over: CGRect(x: 20, y: -10, width: 80, height: 70), turns: 4)])
        binding.bindingsForStroke = { [.scribble: .erase] }

        surface.isStrokeInFlight = true
        binding.inkChanged(on: underAStroke, PKDrawing(strokes: lines), echoOf: nil)
        binding.inkChanged(on: underAStroke, scribbled, echoOf: nil)
        #expect(!surface.calls.contains { if case .restoreInk = $0 { true } else { false } })
        #expect(notebook.state(of: underAStroke)?.content?.ink == scribbled, "every stroke the report carried")

        surface.isStrokeInFlight = false
        binding.inkChanged(on: atRest, PKDrawing(strokes: lines), echoOf: nil)
        binding.inkChanged(on: atRest, scribbled, echoOf: nil)
        #expect(surface.calls.contains { if case .restoreInk(let p, _) = $0 { p == atRest } else { false } }, "the gesture still runs at rest")
        _ = await notebook.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("An undo whose entry is a layer change scrolls to that page, with no ink to restore")
    func undoOfALayerChangeScrolls() async throws {
        let scratch = try Scratch("editor-undo-layer")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let page = notebook.pageIDs[0]

        binding.windowChanged(to: [page])
        try await waitUntil { surface.installed.contains(page) }
        try notebook.insertLayer(textLayer("hi"), on: page)
        binding.drain()
        try await waitUntil { surface.layersSeen[page]?.count == 1 }
        #expect(notebook.canUndo)

        binding.undoRequested()
        #expect(surface.calls.last == .scroll(page), "the scroll answers the undo, after the drain")
        #expect(!surface.calls.contains { if case .restoreInk = $0 { true } else { false } })
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true)
        _ = await notebook.close()
    }

    @Test("A delete request answers with the composite that omits the layer, and the delete is undoable")
    func deleteRequestOmitsTheLayer() async throws {
        let scratch = try Scratch("editor-delete-layer")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let page = notebook.pageIDs[0]

        binding.windowChanged(to: [page])
        try await waitUntil { surface.installed.contains(page) }
        let layer = Fixture.imageLayer()
        try await notebook.addLayer(layer, assetData: Fixture.archive(3, count: 128), on: page)
        binding.drain()
        try await waitUntil { surface.layersSeen[page]?.map(\.id) == [layer.id] }

        binding.layerDeleteRequested(on: page, layer: layer.id)
        try await waitUntil { surface.layersSeen[page]?.isEmpty == true }
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true)
        #expect(notebook.canUndo, "a delete is one entry on the stack")

        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.layers.map(\.id) == [layer.id])
        _ = await notebook.close()
        _ = scratch
    }

    @Test("A lock request answers with a composite whose layer carries the flag; a delete under it is refused; undo unlocks")
    func lockRequestLocksTheLayer() async throws {
        let scratch = try Scratch("editor-lock-layer")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let page = notebook.pageIDs[0]

        binding.windowChanged(to: [page])
        try await waitUntil { surface.installed.contains(page) }
        let layer = Fixture.imageLayer()
        try await notebook.addLayer(layer, assetData: Fixture.archive(4, count: 128), on: page)
        binding.drain()
        try await waitUntil { surface.layersSeen[page]?.map(\.id) == [layer.id] }
        let composites = surface.calls.count { if case .updateComposite = $0 { true } else { false } }

        binding.layerLockRequested(on: page, layer: layer.id, locked: true)
        try await waitUntil { surface.layersSeen[page]?.first?.locked == true }
        #expect(surface.calls.count { if case .updateComposite = $0 { true } else { false } } == composites + 1)
        #expect(notebook.canUndo, "a lock is one entry on the stack")

        binding.layerDeleteRequested(on: page, layer: layer.id)
        binding.drain()
        #expect(notebook.state(of: page)?.content?.layers.map(\.id) == [layer.id], "a locked layer is not deleted")
        #expect(binding.layerTransformed(on: page, layer: layer.id, to: .translation(x: 3, y: 3)) == .refused(reason: "layer \(layer.id) is locked"))

        #expect(notebook.undo() == page)
        try await waitUntil { surface.layersSeen[page]?.first?.locked == false }
        #expect(notebook.state(of: page)?.content?.layers == [layer])
        _ = await notebook.close()
        _ = scratch
    }

    @Test("A move pushes one page order; a self-drop, a next-neighbour drop, and the last page onto the end push nothing")
    func movePageGuards() async throws {
        let (scratch, notebook) = try await reopened("editor-move", pages: 3)
        let surface = RecordingSurface()
        let editor = EditorViewModel(binding: EditorBinding(notebook: notebook, surface: surface), palette: ToolPalette(store: MemoryPaletteStore()))
        let (a, b, c) = (notebook.pageIDs[0], notebook.pageIDs[1], notebook.pageIDs[2])
        let pushed = surface.pagesSet.count

        editor.movePage(a, before: a)
        editor.movePage(a, before: b)
        editor.movePage(c, before: nil)
        #expect(surface.pagesSet.count == pushed)
        #expect(notebook.pageIDs == [a, b, c])
        #expect(!notebook.isDirty, "an unchanged order is not a save")

        editor.movePage(c, before: a)
        #expect(surface.pagesSet.count == pushed + 1)
        #expect(surface.pagesSet.last == [c, a, b])
        _ = await notebook.close()
        _ = scratch
    }

    @Test("Adding after a page pushes the order then scrolls to the new page; deleting the only page pushes nothing")
    func addAfterAndDeleteLast() async throws {
        let scratch = try Scratch("editor-add-delete")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let editor = EditorViewModel(binding: EditorBinding(notebook: notebook, surface: surface), palette: ToolPalette(store: MemoryPaletteStore()))
        let first = notebook.pageIDs[0]
        let pushed = surface.pagesSet.count

        editor.deletePage(first)
        #expect(surface.pagesSet.count == pushed)
        #expect(editor.navigatorPages.map(\.isDeletable) == [false])

        editor.addPage(after: first)
        let created = try #require(notebook.pageIDs.last)
        #expect(surface.pagesSet.last == [first, created])
        #expect(surface.calls.last == .scroll(created), "the scroll follows the push")
        #expect(editor.navigatorPages.map(\.isDeletable) == [true, true])
        #expect(editor.navigatorPages.map(\.version) == [0, 1])
        _ = await notebook.close()
    }

    @Test("A navigator cell's loading flag follows the page's state across a window change")
    func navigatorPagesFollowLoading() async throws {
        let (scratch, notebook) = try await reopened("editor-navigator", pages: 2)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let editor = EditorViewModel(binding: binding, palette: ToolPalette(store: MemoryPaletteStore()))
        let (a, b) = (notebook.pageIDs[0], notebook.pageIDs[1])
        #expect(editor.navigatorPages.map(\.isLoading) == [false, false])
        #expect(editor.navigatorPages.map(\.isCurrent) == [true, false])

        editor.scroll(toPageIndex: 1)
        #expect(surface.calls.last == .scroll(b))
        binding.pageBecameCurrent(b)
        #expect(editor.navigatorPages.map(\.isCurrent) == [false, true])

        binding.windowChanged(to: [a])
        #expect(editor.navigatorPages.map(\.isLoading) == [true, false])
        try await waitUntil { surface.installed.contains(a) }
        #expect(editor.navigatorPages.map(\.isLoading) == [false, false])
        _ = await notebook.close()
        _ = scratch
    }

    @Test("The end boundary is answered by a page order carrying that report's sequence, and the pulled page copies its template")
    func endBoundaryAnswersWithSetPages() async throws {
        let scratch = try Scratch("editor-boundary")
        // A4 landscape, so the copied geometry is not the default one.
        let a4Landscape = try #require(PageSize.a4.geometry(.landscape))
        let notebook = try await Notebook.create(at: scratch.packageURL, geometry: a4Landscape, schedule: fast)
        let first = notebook.pageIDs[0]
        try await notebook.setPaper(.drawn(.lined), on: first)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let before = notebook.pageIDs

        binding.endBoundaryReached(seq: ReportSeq(7))

        let answer = try #require(surface.answered(ReportSeq(7)), "the append answered no report")
        #expect(answer.count == before.count + 1)
        #expect(Array(answer.prefix(before.count)) == before)

        // The pull still takes the template's paper and size with it.
        let pulled = try #require(answer.last)
        #expect(notebook.paper(of: pulled) == .drawn(.lined))
        #expect(notebook.index.record(of: pulled)?.geometry == a4Landscape)
        _ = await notebook.close()
    }

    @Test("A text box request is answered by the omitting composite then the begin, and a commit by the composite then the end")
    func textRequestsAreAnsweredAfterTheComposite() async throws {
        let scratch = try Scratch("editor-text")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let page = notebook.pageIDs[0]
        binding.windowChanged(to: [page])
        try await waitUntil { surface.installed.contains(page) }

        binding.textBoxRequested(on: page, at: PagePoint(x: 30, y: 40), style: .body, alignment: .leading)
        let layer = try #require(notebook.state(of: page)?.content?.layers.first)
        #expect(layer.payload == .text(TextLayer(rect: PageRect(x: 30, y: 40, width: 240, height: 96), runs: [], alignment: .leading)))
        try await waitUntil { surface.calls.contains(.beginTextEditing(page, layer.id)) }
        #expect(Array(surface.calls.suffix(2)) == [.updateComposite(page), .beginTextEditing(page, layer.id)])
        #expect(surface.layersSeen[page]?.map(\.id) == [layer.id])
        let start = try #require(surface.starts.last)

        let typed = TextLayer(rect: start.text.rect, runs: [TextRun(string: "typed", style: .body)], alignment: .leading)
        binding.textEditingEnded(on: page, layer: layer.id, typed)
        try await waitUntil { surface.calls.contains(.endTextEditing(page, layer.id)) }
        #expect(Array(surface.calls.suffix(2)) == [.updateComposite(page), .endTextEditing(page, layer.id)])
        #expect(notebook.state(of: page)?.content?.layers.first?.payload == .text(typed))
        _ = await notebook.close()
    }

    @Test("Undo and redo during a text session go to the typing, and the notebook's stack is not touched")
    func undoDuringASessionGoesToTyping() async throws {
        let scratch = try Scratch("editor-undo-typing")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let page = notebook.pageIDs[0]
        binding.windowChanged(to: [page])
        try await waitUntil { surface.installed.contains(page) }
        binding.inkChanged(on: page, Ink.drawing(strokes: 3), echoOf: nil)
        #expect(notebook.canUndo && !notebook.canRedo)

        binding.textBoxRequested(on: page, at: PagePoint(x: 30, y: 40), style: .body, alignment: .leading)
        #expect(notebook.hasTextSession)
        // Every call from here on is the session's. The opening push is not:
        // a binding sends the runtime to the page the notebook was left on as
        // soon as it has the order, and that happened before any of this.
        let beforeTheUndo = surface.calls.count
        binding.undoRequested()
        binding.redoRequested()
        #expect(Array(surface.calls.suffix(2)) == [.undoTyping, .redoTyping])
        #expect(notebook.canUndo && !notebook.canRedo, "the stack did not move")
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 3)
        #expect(!surface.calls.contains { if case .restoreInk = $0 { true } else { false } })
        #expect(!surface.calls.dropFirst(beforeTheUndo).contains { if case .scroll = $0 { true } else { false } },
                "an undo that restores a loaded page in place takes the reader nowhere")
        _ = await notebook.close()
    }

    @Test("An import or a link while a box is open on the current page is refused through the content error")
    func insertDuringASessionIsRefused() async throws {
        let scratch = try Scratch("editor-insert-during-session")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let editor = EditorViewModel(binding: binding, palette: ToolPalette(store: MemoryPaletteStore()))
        let page = notebook.pageIDs[0]
        binding.windowChanged(to: [page])
        try await waitUntil { surface.installed.contains(page) }
        binding.textBoxRequested(on: page, at: PagePoint(x: 30, y: 40), style: .body, alignment: .leading)
        let layers = try #require(notebook.state(of: page)?.content?.layers.count)

        await editor.importImage(try Fixture.imageData(width: 40, height: 30))
        #expect(editor.lastContentError != nil)
        await editor.addLink(to: .internalPage(page))
        #expect(editor.lastContentError != nil)
        await editor.importPDF(try Fixture.pdfData(pages: 1))
        #expect(editor.lastContentError != nil)
        #expect(notebook.state(of: page)?.content?.layers.count == layers, "nothing was inserted")
        #expect(notebook.pageCount == 1, "no page was added")
        #expect(!notebook.canUndo, "nothing was recorded")
        #expect(editor.canUndo && editor.canRedo, "the buttons drive the typing while the box is open")

        let box = try #require(notebook.state(of: page)?.content?.textEditing?.layer)
        binding.textEditingEnded(on: page, layer: box, TextLayer(rect: PageRect(x: 30, y: 40, width: 240, height: 96), runs: [], alignment: .leading))
        await editor.addLink(to: .internalPage(page))
        #expect(editor.lastContentError == nil, "the refusal ends with the session")
        _ = await notebook.close()
    }
}
