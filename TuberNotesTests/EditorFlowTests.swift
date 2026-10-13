import Foundation
import PencilKit
import Testing
@testable import TNCanvas
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook
import UIKit

/// TNTests' `MemoryPaletteStore`, its load and save only: that target is
/// not linked here.
private final class MemoryPaletteStore: ToolPaletteStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record: ToolPaletteRecord?

    func load() -> ToolPaletteRecord? { lock.withLock { record } }
    func save(_ record: ToolPaletteRecord) { lock.withLock { self.record = record } }
}

/// W1's first flow as the app wires it. `EditorViewModel`'s own initializer
/// builds the binding, its forwarder and the runtime over a notebook on disk,
/// and the runtime is hosted in a window. Taps go in through the view model,
/// strokes through PencilKit's delegate calls, and what is asserted is the
/// live canvas and the notebook's custody. CanvasLifecycleTests proves the
/// binding and the runtime together; this proves the view model reaches them.
@Suite("Editor flow: the view model, the runtime and the notebook as the app wires them")
@MainActor
final class EditorFlowTests: HostingSuite {
    @MainActor
    private struct Tab {
        let editor: EditorViewModel
        let notebook: Notebook
        let runtime: PagedCanvasController
        let canvas: PageCanvasController
        let window: UIWindow

        var strokesOnCanvas: Int { canvas.canvasView.drawing.strokes.count }
        var content: PageContent? { notebook.state(of: canvas.pageID)?.content }
        var strokesInCustody: Int? { content?.ink.strokes.count }
        /// What the system's undo gesture finds on the responder chain.
        var systemUndo: UndoManager? { canvas.canvasView.undoManager }

        /// The close the app runs, then the window lets the runtime go, so
        /// nothing outlives the binding it reports to.
        func leave() async -> CloseOutcome {
            let outcome = await editor.close()
            window.rootViewController = nil
            return outcome
        }
    }

    private let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private var package: URL { directory.appending(path: "Scratch.tubernotes") }
    /// Shared by every tab, as the workspace's is.
    private let palette = ToolPalette(store: MemoryPaletteStore())

    isolated deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A new one-page notebook, closed, so a tab opens it the way the app
    /// does: with no page loaded.
    private func create() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let created = try await Notebook.create(at: package, schedule: fast)
        #expect(await created.close() == .clean)
    }

    /// A tab over the notebook, its canvas in a window and its page live.
    private func open() async throws -> Tab {
        let notebook = try await Notebook.open(store: PackageStore(root: package), schedule: fast)
        let editor = EditorViewModel(notebook: notebook, palette: palette, theme: .macaron) { _ in }
        let runtime = try #require(editor.canvasHost as? PagedCanvasController)
        let window = host(runtime)
        let page = notebook.pageIDs[0]
        try await waitUntil { runtime.canvases[page] != nil }
        // The install's echo latch clears at the end of its turn, so the
        // first stroke is reported as the edit it is.
        await hop()
        return Tab(editor: editor, notebook: notebook, runtime: runtime, canvas: try #require(runtime.canvases[page]), window: window)
    }

    @Test("The tool chosen on the bar reaches the live canvas, and a second eraser tap switches the mode there")
    func theBarsToolReachesTheCanvas() async throws {
        try await create()
        let tab = try await open()
        let view = tab.canvas.canvasView

        tab.editor.select(.ink(.highlighter))
        #expect((view.tool as? PKInkingTool)?.inkType == .marker)
        tab.editor.select(.eraser)
        #expect((view.tool as? PKEraserTool)?.eraserType == .vector, "whole strokes")
        tab.editor.select(.eraser)
        #expect((view.tool as? PKEraserTool)?.eraserType == .fixedWidthBitmap, "pixels")
        tab.editor.select(.text)
        #expect(!view.drawingGestureRecognizer.isEnabled, "the text tool draws nothing")
        tab.editor.select(.ink(.pen))
        #expect((view.tool as? PKInkingTool)?.inkType == .pen)
        #expect(view.drawingGestureRecognizer.isEnabled)
        #expect(await tab.leave() == .clean)
    }

    @Test("A stroke reaches the notebook through the forwarder, and the bar hears it land")
    func aStrokeReachesCustody() async throws {
        try await create()
        let tab = try await open()
        let ink = try #require(tab.editor.tool.color)
        #expect(!tab.editor.canUndo)

        commitStroke(strokeDrawing(strokes: 1), on: tab.canvas)
        #expect(tab.strokesInCustody == 1)
        #expect(tab.editor.canUndo, "the drain refreshed the bar's mirror")
        #expect(palette.recentColors == [ink], "the colour it landed in is a recent")
        #expect(await tab.leave() == .clean)
    }

    @Test("Undo from the bar and from the system restores the canvas and the notebook together, and no echo is taken for an edit")
    func undoRestoresCanvasAndCustody() async throws {
        try await create()
        let tab = try await open()
        let system = try #require(tab.systemUndo)
        commitStroke(strokeDrawing(strokes: 1), on: tab.canvas)
        commitStroke(strokeDrawing(strokes: 2), on: tab.canvas)
        let edits = try #require(tab.content?.editSeq)

        tab.editor.undo()
        #expect(tab.strokesOnCanvas == 1)
        #expect(tab.strokesInCustody == 1)
        system.undo()
        #expect(tab.strokesOnCanvas == 0)
        #expect(tab.strokesInCustody == 0)
        // Each restore reports straight back. Taken for a stroke, that echo
        // would be an edit of its own, owing a save for nothing.
        await hop()
        #expect(tab.content?.editSeq == edits + 2, "two undos, two edits")
        #expect(!tab.editor.canUndo)
        #expect(tab.editor.canRedo)

        system.redo()
        tab.editor.redo()
        #expect(tab.strokesOnCanvas == 2)
        #expect(tab.strokesInCustody == 2)
        #expect(!tab.editor.canRedo)
        #expect(await tab.leave() == .clean)
    }

    @Test("The system's undo manager is told what the notebook's history can do")
    func undoAvailabilityReachesTheFilter() async throws {
        try await create()
        let tab = try await open()
        let system = try #require(tab.systemUndo)
        #expect(!system.canUndo)
        #expect(!system.canRedo)

        commitStroke(strokeDrawing(strokes: 1), on: tab.canvas)
        #expect(system.canUndo)
        #expect(!system.canRedo)
        tab.editor.undo()
        #expect(!system.canUndo)
        #expect(system.canRedo)
        #expect(await tab.leave() == .clean)
    }

    @Test("Undo from the bar and from the system is ignored while a stroke is in flight, and the stroke lands whole")
    func undoMidStrokeIsIgnored() async throws {
        try await create()
        let tab = try await open()
        commitStroke(strokeDrawing(strokes: 1), on: tab.canvas)

        tab.canvas.canvasViewDidBeginUsingTool(tab.canvas.canvasView)
        draw(strokeDrawing(strokes: 2), on: tab.canvas)
        tab.editor.undo()
        tab.systemUndo?.undo()
        #expect(tab.strokesOnCanvas == 2, "the stroke under the Pencil is whole")
        #expect(tab.strokesInCustody == 1)

        tab.canvas.canvasViewDidEndUsingTool(tab.canvas.canvasView)
        tab.canvas.canvasViewDrawingDidChange(tab.canvas.canvasView)
        #expect(tab.strokesInCustody == 2)
        tab.editor.undo()
        #expect(tab.strokesOnCanvas == 1, "the next undo takes exactly that stroke")
        #expect(tab.strokesInCustody == 1)
        #expect(await tab.leave() == .clean)
    }

    @Test("Leaving with a stroke in flight waits for it, and the notebook opens again holding it")
    func leavingMidStrokeKeepsTheStroke() async throws {
        try await create()
        let tab = try await open()
        tab.canvas.canvasViewDidBeginUsingTool(tab.canvas.canvasView)
        draw(strokeDrawing(strokes: 1), on: tab.canvas)

        let leaving = Task { await tab.leave() }
        // The teardown has run, and deferred the page under the Pencil.
        try await waitUntil { !tab.runtime.scrollView.isScrollEnabled }
        #expect(!tab.notebook.isClosed, "the stroke is not in custody yet")

        tab.canvas.canvasViewDidEndUsingTool(tab.canvas.canvasView)
        tab.canvas.canvasViewDrawingDidChange(tab.canvas.canvasView)
        #expect(await leaving.value == .clean)

        let back = try await open()
        #expect(back.strokesOnCanvas == 1)
        #expect(back.strokesInCustody == 1)
        #expect(await back.leave() == .clean)
    }
}
