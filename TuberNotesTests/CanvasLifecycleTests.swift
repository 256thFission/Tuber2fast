import Foundation
import PencilKit
import Testing
@testable import TNCanvas
@testable import TNEditor
@testable import TNModel
@testable import TNNotebook
import UIKit

/// The editor's three pieces as production wires them: a notebook on disk,
/// the binding, and the runtime the binding builds, hosted in a window. What
/// the canvas suite proves against a recorder, this proves across the seam.
@Suite("Canvas lifecycle: the notebook, the binding and the runtime together")
@MainActor
struct CanvasLifecycleTests {
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

    /// A new notebook of `pages` pages, saved, with its editor open on the
    /// first page.
    private func open(pages: Int) async throws -> Editor {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notebook = try await Notebook.create(at: directory.appending(path: "Scratch.tubernotes"), schedule: fast)
        for _ in 1..<pages { notebook.appendPage() }
        await notebook.flush()
        let binding = EditorBinding(notebook: notebook, onLinkActivated: { _ in })
        binding.apply(testEnvironment)
        let runtime = binding.host as! PagedCanvasController
        let window = host(runtime)
        return Editor(notebook: notebook, binding: binding, runtime: runtime, window: window, directory: directory)
    }

    private func isUnloaded(_ state: PageState?) -> Bool {
        if case .unloaded = state { true } else { false }
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
}
