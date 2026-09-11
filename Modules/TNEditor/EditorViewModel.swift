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

    // A new page at a chosen size. Each of these does its `do`/`catch` at
    // method scope, for the reason the comment above `importImage` gives,
    // and reports a refusal through `lastContentError` like any other
    // content change. A refused append creates nothing.

    package func addPage(size: PageSize, orientation: PageOrientation, paper: DrawnPaper) async {
        lastContentError = nil
        guard let geometry = size.geometry(orientation) else {
            lastContentError = Self.sizeOutOfBounds
            return
        }
        var created: PageID?
        do {
            created = try await notebook.appendPage(after: notebook.currentPageID, geometry: geometry, paper: .drawn(paper))
        } catch {
            lastContentError = Self.fault(error)
        }
        binding.drain()
        if let created { binding.surface.scroll(to: created) }
    }

    /// The new page takes another page's asset paper: the chosen width, the
    /// asset's aspect.
    package func addPage(size: PageSize, orientation: PageOrientation, paperFrom page: PageID) async {
        lastContentError = nil
        guard let geometry = size.geometry(orientation) else {
            lastContentError = Self.sizeOutOfBounds
            return
        }
        guard let paper = notebook.paper(of: page), paper.isAsset else {
            lastContentError = .invalidWrite("page \(page) has no asset paper to take")
            return
        }
        var created: PageID?
        do {
            created = try await notebook.appendPage(after: notebook.currentPageID, geometry: geometry, paper: .asset(paper))
        } catch {
            lastContentError = Self.fault(error)
        }
        binding.drain()
        if let created { binding.surface.scroll(to: created) }
    }

    /// A photo becomes the new page's paper. The asset is published first,
    /// so the append that follows only has to measure it.
    package func addPage(size: PageSize, orientation: PageOrientation, photo data: Data) async {
        lastContentError = nil
        guard let geometry = size.geometry(orientation) else {
            lastContentError = Self.sizeOutOfBounds
            return
        }
        var stored: AssetRef?
        do { stored = try await notebook.storeImageAsset(data) } catch { lastContentError = error }
        guard let stored else { return }
        var created: PageID?
        do {
            created = try await notebook.appendPage(after: notebook.currentPageID, geometry: geometry, paper: .asset(.image(stored)))
        } catch {
            lastContentError = Self.fault(error)
        }
        binding.drain()
        if let created { binding.surface.scroll(to: created) }
    }

    /// The sheet refuses a size `geometry(_:)` returns nil for before it
    /// offers to create anything; this is the same refusal, stated for a
    /// caller that got here anyway.
    private static let sizeOutOfBounds = FormatFault.invalidWrite(
        "page size is outside \(EditorViewModel.bounds) points")

    /// `%g` rather than interpolation: `minEdge` is derived and prints its
    /// binary tail as `137.60000000000002`.
    private static let bounds = String(format: "%g to %g", PageBounds.minEdge, PageBounds.maxEdge)

    /// `lastContentError` is a `FormatFault`, the one channel a refused
    /// content change speaks through, so an append's refusal joins it.
    private static func fault(_ refusal: NewPageRefusal) -> FormatFault {
        switch refusal {
        case .geometryOutOfBounds(let width, let height):
            .invalidWrite("page \(width) x \(height) is outside \(Self.bounds) points")
        case .assetUnreadable(let asset):
            .invalidWrite("paper asset \(asset.fileName) could not be read")
        }
    }

    /// The last page cannot be deleted; the notebook refuses it, silently,
    /// because a notebook with no pages has no state to return to.
    package func deleteCurrentPage() {
        binding.intention { notebook.deletePage(notebook.currentPageID) }
    }

    package var currentPaper: Paper? { notebook.paper(of: notebook.currentPageID) }

    /// The pages a new page could take its asset paper from. A page whose
    /// state is `.unreadable` is omitted: `paper(of:)` reads the index, so
    /// such a row would offer an asset that can only fail.
    package var pagesWithAssetPaper: [(page: PageID, paper: Paper)] {
        notebook.pageIDs.compactMap { page -> (page: PageID, paper: Paper)? in
            guard let paper = notebook.paper(of: page), paper.isAsset else { return nil }
            if let state = notebook.state(of: page), case .unreadable = state { return nil }
            return (page, paper)
        }
    }

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
