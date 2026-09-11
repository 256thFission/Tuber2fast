import Foundation
import Observation
import TNCore
import TNFormat
import TNModel
import TNNotebook
import UIKit

/// One cell of the page navigator: what the grid draws before it has a
/// thumbnail, and what its fetch is keyed by.
package struct NavigatorPage: Identifiable, Sendable, Equatable {
    package let id: PageID
    package let geometry: PageGeometry
    /// The notebook's content version, the cell's `.task(id:)`.
    package let version: UInt64
    package let isCurrent: Bool
    /// False when it is the only page.
    package let isDeletable: Bool
    /// True while the notebook is loading the page. Part of the cell's task
    /// id, so the cell asks again when the load settles instead of the
    /// notebook polling its own state.
    package let isLoading: Bool
}

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
    /// Rebuilt on every drain like the others: a map over five-field structs
    /// per drain is cheaper than a flag that can be stale.
    package private(set) var navigatorPages: [NavigatorPage] = []

    /// The last refusal from an import or a layer addition. Cleared when
    /// the next one is attempted.
    package private(set) var lastContentError: FormatFault?

    /// Whether the notebook still owes the disk something. The save engine
    /// does not publish a write-in-flight flag, and a spinner keyed to one
    /// would flicker at every pass; this is "work outstanding".
    package var isSaving: Bool { notebook.dirtyPageCount > 0 }
    package var lastSaveError: SaveFailure? { notebook.lastSaveError }

    package convenience init(notebook: Notebook, onLinkActivated: @escaping @MainActor (LinkTarget) -> Void) {
        self.init(binding: EditorBinding(notebook: notebook, onLinkActivated: onLinkActivated))
    }

    /// The designated initializer. Production passes the binding that made
    /// the runtime; a test passes one over a recording surface.
    package init(binding: EditorBinding) {
        self.notebook = binding.notebook
        self.tool = .pen(color: .black, width: .medium)
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
        let records = notebook.index.pages
        navigatorPages = records.map { record in
            let isLoading: Bool
            if case .loading = notebook.state(of: record.id) { isLoading = true } else { isLoading = false }
            return NavigatorPage(
                id: record.id,
                geometry: record.geometry,
                version: notebook.contentVersion(of: record.id),
                isCurrent: record.id == notebook.currentPageID,
                isDeletable: records.count > 1,
                isLoading: isLoading
            )
        }
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

    /// A new page after `page`, and the reader is taken to it. It inherits
    /// the current page's paper and geometry, not `page`'s: that is what
    /// `appendPage` copies today, and the navigator's label says so.
    package func addPage(after page: PageID) {
        var created: PageID?
        binding.intention { created = notebook.appendPage(after: page) }
        if let created { binding.surface.scroll(to: created) }
    }

    /// The only page cannot be deleted; the notebook refuses it, silently,
    /// because a notebook with no pages has no state to return to.
    package func deletePage(_ page: PageID) {
        binding.intention { notebook.deletePage(page) }
    }

    package func deleteCurrentPage() { deletePage(notebook.currentPageID) }

    /// Pixels for a navigator cell, keyed by the page's content version.
    /// Cancelled with the cell's task; nil while the page is loading or when
    /// it is unreadable.
    package func thumbnail(of page: PageID) async -> CGImage? {
        await notebook.thumbnail(of: page)
    }

    /// `page` goes before `target`, or to the end when `target` is nil.
    ///
    /// Three drops leave the order as it is and stop here, because the
    /// notebook would otherwise rewrite and save an unchanged index, and a
    /// self-drop would send the page to the end (`Notebook.movePage` removes
    /// the page first, then fails to find it as the target). A drop on the
    /// page's own next neighbour, and the last page dropped past the end,
    /// are the other two; `next == nil` when the page is last, so the one
    /// comparison covers both.
    package func movePage(_ page: PageID, before target: PageID?) {
        let pages = notebook.pageIDs
        guard let from = pages.firstIndex(of: page) else { return }
        let next = pages.indices.contains(from + 1) ? pages[from + 1] : nil
        if target == page || target == next { return }
        binding.intention { notebook.movePage(page, before: target) }
    }

    package var currentPaper: Paper? { notebook.paper(of: notebook.currentPageID) }

    /// Drawn paper only: the two asset papers are intentions of their own,
    /// and neither is a menu item the user picks from a list.
    package func setPaper(_ paper: DrawnPaper) async {
        await binding.intention { try? await notebook.setPaper(.drawn(paper), on: notebook.currentPageID) }
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
