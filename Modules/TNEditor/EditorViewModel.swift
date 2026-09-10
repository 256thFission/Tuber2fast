import Foundation
import Observation
import TNCore
import TNFormat
import TNModel
import TNNotebook
import UIKit

/// What one open notebook looks like to the app: a canvas to put on
/// screen, a few observed facts to draw a toolbar from, and intentions.
///
/// Snapshots down, intentions up. Nothing here holds durable authority:
/// every method turns a tap into a notebook mutation and lets the drain
/// push the result to the runtime.
@MainActor @Observable
package final class EditorViewModel {
    @ObservationIgnored package let notebook: Notebook
    @ObservationIgnored private let binding: EditorBinding

    /// The canvas, as a plain view controller. The app never names
    /// `TNCanvas`, which is a compile error and not a review note.
    @ObservationIgnored package let canvasHost: UIViewController

    /// The active tool. Setting it applies to the runtime at once; the
    /// tool is the runtime's own state, held here only so the toolbar has
    /// something to render from.
    package var tool: EditorTool {
        didSet {
            guard tool != oldValue else { return }
            binding.apply(CanvasEnvironment(tool: tool.pkTool))
        }
    }

    // Mirrors, refreshed at the end of every drain. Undo availability is
    // not observable on the notebook — the history is ignored storage, as
    // it must be, or a stroke would invalidate every view.
    package private(set) var canUndo = false
    package private(set) var canRedo = false
    package private(set) var pageCount = 0
    package private(set) var currentPageIndex = 0

    /// The last refusal from an import or a layer addition. Cleared when
    /// the next one is attempted.
    package private(set) var lastContentError: FormatFault?

    /// Whether the notebook still owes the disk something. The save engine
    /// does not publish a write-in-flight flag, and a spinner keyed to one
    /// would flicker at every pass; this is "work outstanding".
    package var isSaving: Bool { notebook.dirtyPageCount > 0 }
    package var lastSaveError: SaveFailure? { notebook.lastSaveError }

    package init(notebook: Notebook, onLinkActivated: @escaping @MainActor (LinkTarget) -> Void) {
        self.notebook = notebook
        self.tool = .pen(color: .black, width: .medium)
        let binding = EditorBinding(notebook: notebook, onLinkActivated: onLinkActivated)
        self.binding = binding
        self.canvasHost = binding.host
        binding.onDrained = { [weak self] in self?.refreshMirrors() }
        refreshMirrors()
        // `didSet` does not run for the initial value, and the runtime
        // starts with no tool at all.
        binding.apply(CanvasEnvironment(tool: tool.pkTool))
    }

    private func refreshMirrors() {
        canUndo = notebook.canUndo
        canRedo = notebook.canRedo
        pageCount = notebook.pageCount
        currentPageIndex = notebook.pageIDs.firstIndex(of: notebook.currentPageID) ?? 0
    }

    // MARK: History

    package func undo() { binding.undoRequested() }
    package func redo() { binding.redoRequested() }

    // MARK: Pages

    /// A new page after the current one, and the reader is taken to it.
    package func addPage() {
        var created: PageID?
        binding.intention { created = notebook.appendPage(after: notebook.currentPageID) }
        if let created { binding.surface.scroll(to: created) }
    }

    /// The last page cannot be deleted; the notebook refuses it, silently,
    /// because a notebook with no pages has no state to return to.
    package func deleteCurrentPage() {
        binding.intention { notebook.deletePage(notebook.currentPageID) }
    }

    package var currentPaper: Paper? { notebook.paper(of: notebook.currentPageID) }

    /// Drawn paper only: the two asset papers are intentions of their own,
    /// and neither is a menu item the user picks from a list.
    package func setPaper(_ paper: DrawnPaper) {
        binding.intention { try? notebook.setPaper(.drawn(paper), on: notebook.currentPageID) }
    }

    package func scroll(toPageIndex index: Int) {
        let pages = notebook.pageIDs
        guard pages.indices.contains(index) else { return }
        binding.surface.scroll(to: pages[index])
    }

    // MARK: Content

    // A content mutation's `do`/`catch` sits at method scope, never inside
    // a closure: a closure literal loses the `throws(FormatFault)` and the
    // catch binds `any Error`. So these four call `drain()` themselves
    // rather than run inside `binding.intention`, which is the same two
    // steps in the same order.

    package func importImage(_ data: Data) async {
        let page = notebook.currentPageID
        lastContentError = nil
        do { try await notebook.importImage(data, on: page) } catch { lastContentError = error }
        binding.drain()
    }

    /// One new page per PDF page, after the current one.
    package func importPDF(_ data: Data) async {
        lastContentError = nil
        do { try await notebook.importPDF(data) } catch { lastContentError = error }
        binding.drain()
    }

    /// A text box near the top-left of the current page, sized to fit
    /// however small the page is. Where the user wants it is a drag away;
    /// this is where it starts.
    package func addTextBox() async {
        let page = notebook.currentPageID
        let rect = Self.defaultRect(width: 240, height: 96, on: notebook.index.record(of: page)?.geometry)
        lastContentError = nil
        do { try await notebook.addTextLayer(on: page, rect: rect, runs: [TextRun(string: "Text")]) } catch { lastContentError = error }
        binding.drain()
    }

    package func addLink(to target: LinkTarget) async {
        let page = notebook.currentPageID
        let rect = Self.defaultRect(width: 160, height: 44, on: notebook.index.record(of: page)?.geometry)
        lastContentError = nil
        do { try await notebook.addLinkLayer(on: page, rect: rect, target: target) } catch { lastContentError = error }
        binding.drain()
    }

    /// The inset is a page point count, not a fraction: a new box sits the
    /// same distance from the corner whatever the page's size.
    private static let defaultInset: Double = 48

    private static func defaultRect(width: Double, height: Double, on geometry: PageGeometry?) -> PageRect {
        let available = geometry ?? .letter
        let inset = min(Self.defaultInset, available.width / 4, available.height / 4)
        return PageRect(
            x: inset, y: inset,
            width: min(width, available.width - 2 * inset),
            height: min(height, available.height - 2 * inset)
        )
    }

    // MARK: Durability

    package func flush() async { await notebook.flush() }

    /// Close: the runtime lets go of every page first, then the notebook
    /// runs its final pass. A retire deferred by a stroke in flight is
    /// waited for, because the ink that stroke carries is not in custody
    /// until its report arrives.
    package func close() async -> CloseOutcome {
        let deferred = binding.retireAll()
        if !deferred.isEmpty {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !binding.hasRetired(deferred), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if !binding.hasRetired(deferred) {
                TNLog.violation("close: \(deferred.count) deferred retire(s) never reported; their last strokes may be lost")
            }
        }
        binding.drain()
        return await notebook.close()
    }
}
