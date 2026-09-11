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
    case retire(PageID)
    case updateComposite(PageID)
}

/// A surface that records instead of drawing. It stands where
/// `PagedCanvasController` stands, which is what lets the binding be
/// tested in a bundle with no host app and no Pencil.
@MainActor
final class RecordingSurface: CanvasSurface {
    private(set) var calls: [SurfaceCall] = []
    private(set) var environments: [CanvasEnvironment] = []
    /// Pages whose retire this surface defers, as a stroke in flight does.
    var deferring: Set<PageID> = []

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

    func retire(_ page: PageID) -> RetireOutcome {
        calls.append(.retire(page))
        return deferring.contains(page) ? .deferred : .retired
    }

    func updateComposite(on page: PageID, _ composite: Composite) {
        calls.append(.updateComposite(page))
    }

    func apply(_ environment: CanvasEnvironment) { environments.append(environment) }

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
    /// unloaded and a window has real work to do.
    private func reopened(_ name: String, pages: Int) async throws -> (Scratch, Notebook) {
        let scratch = try Scratch(name)
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        for _ in 1..<pages { notebook.appendPage() }
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
}
