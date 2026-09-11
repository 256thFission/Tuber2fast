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
    case beginTextEditing(PageID, LayerID)
    case endTextEditing(PageID, LayerID)
}

/// A surface that records instead of drawing. It stands where
/// `PagedCanvasController` stands, which is what lets the binding be
/// tested in a bundle with no host app and no Pencil.
@MainActor
final class RecordingSurface: CanvasSurface {
    private(set) var calls: [SurfaceCall] = []
    private(set) var environments: [CanvasEnvironment] = []
    private(set) var layersSeen: [PageID: [Layer]] = [:]
    private(set) var starts: [TextEditStart] = []
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

    @Test("The end boundary is answered by a page order carrying that report's sequence")
    func endBoundaryAnswersWithSetPages() async throws {
        let scratch = try Scratch("editor-boundary")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let before = notebook.pageIDs

        binding.endBoundaryReached(seq: ReportSeq(7))

        let answer = try #require(surface.answered(ReportSeq(7)), "the append answered no report")
        #expect(answer.count == before.count + 1)
        #expect(Array(answer.prefix(before.count)) == before)
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
}
