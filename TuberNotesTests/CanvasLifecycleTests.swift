import Foundation
import PencilKit
import Testing
@testable import TNCanvas
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook
import UIKit

/// The editor's three pieces as production wires them: a notebook on disk,
/// the binding, and the runtime the binding builds, hosted in a window. What
/// the canvas suites prove against a recorder, this proves across the seam.
@Suite("Canvas lifecycle: the notebook, the binding and the runtime together")
@MainActor
final class CanvasLifecycleTests: HostingSuite {
    @MainActor
    private struct Editor {
        let notebook: Notebook
        let binding: EditorBinding
        let runtime: PagedCanvasController
        let window: UIWindow
        let directory: URL

        /// The close `EditorViewModel` runs, then the window lets the runtime
        /// go, so nothing outlives the binding it reports to.
        func close() async {
            _ = binding.retireAll()
            binding.drain()
            _ = await notebook.close()
            window.rootViewController = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A new notebook of `pages` pages, saved and opened again the way the
    /// app opens one, so no page is loaded, with its editor open on the
    /// first page. The pages at `missing` have lost their file.
    private func open(pages: Int, missing: [Int] = []) async throws -> Editor {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let package = directory.appending(path: "Scratch.tubernotes")
        let created = try await Notebook.create(at: package, schedule: fast)
        for _ in 1..<pages { created.appendPage() }
        #expect(await created.close() == .clean)
        let store = PackageStore(root: package)
        for index in missing {
            try FileManager.default.removeItem(at: store.layout.pageURL(created.pageIDs[index]))
        }
        let notebook = try await Notebook.open(store: store, schedule: fast)
        let binding = EditorBinding(notebook: notebook, environment: testEnvironment, onLinkActivated: { _ in })
        let runtime = binding.host as! PagedCanvasController
        let window = host(runtime)
        return Editor(notebook: notebook, binding: binding, runtime: runtime, window: window, directory: directory)
    }

    private func isUnloaded(_ state: PageState?) -> Bool {
        if case .unloaded = state { true } else { false }
    }

    @Test("An undo during a stroke is ignored on both paths and while the stroke commits, and the stroke lands in the notebook")
    func undoDuringAStrokeIsIgnored() async throws {
        let editor = try await open(pages: 1)
        let (notebook, binding, runtime) = (editor.notebook, editor.binding, editor.runtime)
        let page = notebook.pageIDs[0]
        try await waitUntil { runtime.canvases[page] != nil }
        let canvas = try #require(runtime.canvases[page])
        // The install's echo latch clears at the end of its turn, so the
        // first stroke is reported as the edit it is.
        await hop()
        commitStroke(strokeDrawing(strokes: 1), on: canvas)
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 1)

        canvas.canvasViewDidBeginUsingTool(canvas.canvasView)
        binding.undoRequested()
        canvas.undoManager?.undo()
        #expect(canvas.canvasView.drawing.strokes.count == 1)
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 1)
        #expect(notebook.canUndo)

        draw(strokeDrawing(strokes: 2), on: canvas)
        canvas.canvasViewDidEndUsingTool(canvas.canvasView)
        binding.undoRequested()
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 1, "the use has ended and its commit has not landed")

        canvas.canvasViewDrawingDidChange(canvas.canvasView)
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 2, "the stroke is in custody")

        binding.undoRequested()
        #expect(notebook.state(of: page)?.content?.ink.strokes.count == 1, "the next undo removes exactly that stroke")
        #expect(canvas.canvasView.drawing.strokes.count == 1)
        await editor.close()
    }

    @Test("A commit ends the open box, and the notebook holds what was typed before the call returns")
    func commitTextEditingReportsTheDraft() async throws {
        let editor = try await open(pages: 1)
        let (notebook, binding, runtime) = (editor.notebook, editor.binding, editor.runtime)
        let page = notebook.pageIDs[0]
        try await waitUntil { runtime.canvases[page] != nil }
        let canvas = try #require(runtime.canvases[page])
        binding.apply(CanvasEnvironment(tool: .text(.body, .leading), theme: testEnvironment.theme))
        canvas.tapped(at: CGPoint(x: 100, y: 100))
        try await waitUntil { if case .editing = canvas.phase { true } else { false } }
        guard case .editing(let layer, let overlay) = canvas.phase else { return }
        overlay.insertText("answer")

        runtime.commitTextEditing()
        #expect(!notebook.hasTextSession)
        let committed = notebook.state(of: page)?.content?.layers.first { $0.id == layer }?.payload
        let words: String? = if case .text(let text) = committed { text.runs.map(\.string).joined() } else { nil }
        #expect(words == "answer")
        // The end is pushed after the composite that has the words, and the
        // inert overlay comes down with it.
        try await waitUntil { canvas.closing.isEmpty }
        #expect(overlay.superview == nil)
        await editor.close()
    }

    @Test("A page the notebook pruned gets no canvas until its content is pushed again")
    func anEvictedPageWaitsForItsReload() async throws {
        let editor = try await open(pages: 6)
        let (notebook, runtime) = (editor.notebook, editor.runtime)
        let ids = notebook.pageIDs
        try await waitUntil { runtime.canvases[ids[0]] != nil }

        settle(runtime, at: 5)
        try await waitUntil { runtime.canvases[ids[5]] != nil }
        #expect(isUnloaded(notebook.state(of: ids[0])), "page 1 left the window clean, so the notebook let it go")

        settle(runtime, at: 0)
        #expect(runtime.canvases[ids[0]] == nil, "no canvas over a page the notebook does not hold")

        try await waitUntil { runtime.canvases[ids[0]] != nil }
        #expect(notebook.state(of: ids[0])?.content != nil)
        await editor.close()
    }

    @Test("Paging through a notebook holds a snapshot only inside the decoded window, a page only ever in its outer ring included")
    func pagingHoldsAtMostFiveSnapshots() async throws {
        let editor = try await open(pages: 20)
        let (notebook, runtime) = (editor.notebook, editor.runtime)
        let ids = notebook.pageIDs
        // A fling settles once, so the page two past each stop is only ever
        // a placeholder in the outer ring, and never has a canvas to retire.
        for index in [0, 4, 8, 12, 16, 19] {
            settle(runtime, at: index)
            let decoded = try #require(runtime.currentLayout.decodedWindow(around: index))
            try await waitUntil { decoded.allSatisfy { runtime.snapshots[ids[$0]] != nil } }
            #expect(runtime.snapshots.count <= 5, "on page \(index + 1) the runtime holds \(runtime.snapshots.count) snapshots")
        }
        for (index, page) in ids.enumerated() where index < 17 {
            #expect(isUnloaded(notebook.state(of: page)), "page \(index + 1) is outside the window")
        }
        await editor.close()
    }

    @Test("A refused page that leaves the window and comes back says why, not that it is loading")
    func anUnreadablePageReturnsWithItsFault() async throws {
        let editor = try await open(pages: 6, missing: [1])
        let (notebook, runtime) = (editor.notebook, editor.runtime)
        let ids = notebook.pageIDs
        let fault = PlaceholderCopy.text(for: .missingPageFile)
        try await waitUntil { runtime.canvases[ids[0]] != nil }
        #expect(runtime.placeholders[ids[1]]?.text == fault)

        settle(runtime, at: 5)
        #expect(runtime.placeholders[ids[1]] == nil)

        settle(runtime, at: 0)
        #expect(runtime.placeholders[ids[1]]?.text == fault)
        #expect(runtime.canvases[ids[1]] == nil)
        await editor.close()
    }
}
