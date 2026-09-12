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

    /// The active tool. Setting it applies to the runtime at once and tells
    /// the palette what to remember; the tool is the runtime's own state,
    /// held here only so the strip has something to render from.
    ///
    /// `private(set)`, so the intentions below are the only way to change
    /// it and the `didSet` is a boundary rather than a courtesy.
    package private(set) var tool: EditorTool {
        didSet {
            guard tool != oldValue else { return }
            binding.apply(CanvasEnvironment(tool: tool.canvasTool))
            palette.remember(tool)
        }
    }

    /// The presets, the recents, and the last kind, shared by every tab.
    @ObservationIgnored package let palette: ToolPalette

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

    package convenience init(
        notebook: Notebook,
        palette: ToolPalette,
        onLinkActivated: @escaping @MainActor (LinkTarget) -> Void
    ) {
        self.init(
            binding: EditorBinding(notebook: notebook, onLinkActivated: onLinkActivated),
            palette: palette
        )
    }

    /// The designated initializer. Production passes the binding that made
    /// the runtime; a test passes one over a recording surface.
    package init(binding: EditorBinding, palette: ToolPalette) {
        self.notebook = binding.notebook
        self.palette = palette
        self.tool = palette.currentTool
        self.binding = binding
        self.canvasHost = binding.host
        binding.onDrained = { [weak self] in self?.refreshMirrors() }
        // The ink report, not the drain: a drain also runs for a page turn
        // and an undo, and neither is a colour anybody drew with.
        binding.onInkReported = { [weak self] in self?.inkReported() }
        refreshMirrors()
        // `didSet` does not run for the initial value, and the runtime
        // starts with no tool at all.
        binding.apply(CanvasEnvironment(tool: tool.canvasTool))
    }

    private func refreshMirrors() {
        // While a box is open the buttons drive the text view's own manager,
        // whose depth is not reported up: a report per keystroke is what the
        // Structure rule forbids. So they stay enabled for the session.
        canUndo = notebook.canUndo || notebook.hasTextSession
        canRedo = notebook.canRedo || notebook.hasTextSession
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

    // MARK: The tool

    // One call per tap, so the strip computes nothing. Each restores what
    // the palette holds rather than asking the view to carry it.

    package func select(kind: InkKind) { tool = palette.tool(for: kind) }

    package func selectEraser() { tool = palette.eraserTool }

    package func setEraserMode(_ mode: EraserMode) {
        switch mode {
        case .object: tool = .eraseObject
        case .pixel: tool = .erasePixel(palette.pixelEraserWidth)
        }
    }

    package func selectLasso() { tool = .lasso }

    /// The text tool, typing with what the palette last typed with.
    package func selectText() { tool = palette.textTool }

    package func setTextStyle(_ style: TextStyle) {
        guard case .text(_, let alignment) = tool else {
            TNPrecondition.fail("a text style was set on \(tool), which has none")
        }
        tool = .text(style, alignment)
    }

    package func setTextAlignment(_ alignment: TextAlignment) {
        guard case .text(let style, _) = tool else {
            TNPrecondition.fail("a text alignment was set on \(tool), which has none")
        }
        tool = .text(style, alignment)
    }

    package func setWidth(_ width: ToolWidth) {
        switch tool {
        case .ink(let kind, let preset):
            tool = .ink(kind, InkPreset(color: preset.color, width: width))
        case .erasePixel:
            tool = .erasePixel(width)
        case .eraseObject, .lasso, .text:
            // The strip offers no width for any of these, so reaching here
            // is a view that drew a control the tool does not have.
            TNPrecondition.fail("a width was set on \(tool), which has none")
        }
    }

    package func setColor(_ color: ToolColor) {
        guard case .ink(let kind, let preset) = tool else {
            TNPrecondition.fail("a colour was set on \(tool), which has none")
        }
        tool = .ink(kind, InkPreset(color: color, width: preset.width))
    }

    /// A stroke landed, so the colour it landed in is one the person drew
    /// with. An eraser or a lasso report carries no colour.
    private func inkReported() {
        guard case .ink(_, let preset) = tool else { return }
        palette.used(preset.color)
    }

    // MARK: History

    package func undo() { binding.undoRequested() }
    package func redo() { binding.redoRequested() }

    // MARK: Pages

    // A new page at a chosen size. The four say which paper; `append` below
    // is the one that talks to the notebook.

    /// The paper the boundary pull would have given it: the current page's
    /// drawn paper, which the notebook decides and nothing here restates.
    package func addPage(size: PageSize, orientation: PageOrientation) async {
        await append(size, orientation, .inheritTemplate)
    }

    package func addPage(size: PageSize, orientation: PageOrientation, paper: DrawnPaper) async {
        await append(size, orientation, .drawn(paper))
    }

    /// The new page takes another page's asset paper: the chosen width, the
    /// asset's aspect.
    package func addPage(size: PageSize, orientation: PageOrientation, paperFrom page: PageID) async {
        guard let paper = notebook.paper(of: page), paper.isAsset else {
            lastContentError = .invalidWrite("page \(page) has no asset paper to take")
            return
        }
        await append(size, orientation, .asset(paper))
    }

    /// A photo becomes the new page's paper. The asset is published first,
    /// so the append that follows only has to measure it.
    package func addPage(size: PageSize, orientation: PageOrientation, photo data: Data) async {
        lastContentError = nil
        let stored: AssetRef
        do { stored = try await notebook.storeImageAsset(data) } catch {
            lastContentError = error
            return
        }
        await append(size, orientation, .asset(.image(stored)))
    }

    /// This page, flattened, becomes the new page's paper: the composite and
    /// the ink rendered to one asset at asset resolution. The source is
    /// untouched — flattening in place would lose it, and the contract says
    /// flatten does not change the source — and it records nothing, so the
    /// undo stack is as it was and the append is navigation like any other.
    ///
    /// Its own name rather than a fifth `addPage` overload: the others take
    /// the thing the paper comes from, and this one takes nothing, since the
    /// source is always the page the reader is on.
    package func addPageFlatteningCurrentPage(size: PageSize, orientation: PageOrientation) async {
        let page = notebook.currentPageID
        lastContentError = nil
        guard !notebook.hasTextSession(on: page) else { lastContentError = Self.textBoxOpen(page); return }
        let flattened: AssetRef
        do { flattened = try await notebook.flatten(page) } catch {
            lastContentError = error
            return
        }
        await append(size, orientation, .asset(.image(flattened)))
    }

    /// The `do`/`catch` sits at method scope, for the reason the comment
    /// above `importImage` gives, and a refusal is reported through
    /// `lastContentError` like any other content change. A refused append
    /// creates nothing, so there is nothing to take the reader to.
    private func append(_ size: PageSize, _ orientation: PageOrientation, _ paper: NewPagePaper) async {
        lastContentError = nil
        guard let geometry = size.geometry(orientation) else {
            lastContentError = Self.sizeOutOfBounds
            return
        }
        var created: PageID?
        do {
            created = try await notebook.appendPage(after: notebook.currentPageID, geometry: geometry, paper: paper)
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


    /// A new page after `page`, and the reader is taken to it. It inherits
    /// the current page's paper and geometry, not `page`'s: that is what
    /// `appendPage` copies today, and the navigator's label says so.
    package func addPage(after page: PageID) {
        var created: PageID?
        binding.intention { created = notebook.appendPage(after: page) }
        if let created { binding.surface.scroll(to: created) }
    }

    /// A copy of `page`, straight after it, and the reader is taken to it.
    /// The notebook reads an unloaded source from its files, so a cell in the
    /// navigator can be duplicated without being visited first.
    package func duplicatePage(_ page: PageID) async {
        lastContentError = nil
        var created: PageID?
        do { created = try await notebook.duplicatePage(page) } catch { lastContentError = error }
        binding.drain()
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

    /// The pages a new page could take its asset paper from, each with its
    /// place in the notebook, which is what a row is labelled by. A page
    /// whose state is `.unreadable` is omitted: `paper(of:)` reads the index,
    /// so such a row would offer an asset that can only fail.
    package var pagesWithAssetPaper: [(page: PageID, number: Int)] {
        notebook.pageIDs.enumerated().compactMap { position, page -> (page: PageID, number: Int)? in
            guard notebook.paper(of: page)?.isAsset == true else { return nil }
            if let state = notebook.state(of: page), case .unreadable = state { return nil }
            return (page, position + 1)
        }
    }

    /// The current page's size as the catalogue names it, which is what a
    /// creation sheet opens on: a page added without asking is the size of
    /// the one it follows.
    package var currentPageSize: (size: PageSize, orientation: PageOrientation) {
        guard let geometry = notebook.index.record(of: notebook.currentPageID)?.geometry else {
            TNPrecondition.fail("the current page \(notebook.currentPageID) has no record")
        }
        return PageSize.matching(geometry)
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
    // catch binds `any Error`. So these three call `drain()` themselves
    // rather than run inside `binding.intention`, which is the same two
    // steps in the same order.

    package func importImage(_ data: Data) async {
        let page = notebook.currentPageID
        lastContentError = nil
        guard !notebook.hasTextSession(on: page) else { lastContentError = Self.textBoxOpen(page); return }
        do { try await notebook.importImage(data, on: page) } catch { lastContentError = error }
        binding.drain()
    }

    /// A photo as the current page's paper. The notebook refuses a page that
    /// has ink or layers on it before it stores anything, because asset paper
    /// covers the whole page; the refusal reaches the bar through
    /// `lastContentError` like any other.
    package func setPaper(photo data: Data) async {
        let page = notebook.currentPageID
        lastContentError = nil
        guard !notebook.hasTextSession(on: page) else { lastContentError = Self.textBoxOpen(page); return }
        do { try await notebook.importImageAsPaper(data, on: page) } catch { lastContentError = error }
        binding.drain()
    }

    /// One new page per PDF page, after the current one.
    package func importPDF(_ data: Data) async {
        let page = notebook.currentPageID
        lastContentError = nil
        guard !notebook.hasTextSession(on: page) else { lastContentError = Self.textBoxOpen(page); return }
        do { try await notebook.importPDF(data) } catch { lastContentError = error }
        binding.drain()
    }

    package func addLink(to target: LinkTarget) async {
        let page = notebook.currentPageID
        let rect = Self.defaultRect(width: 160, height: 44, on: notebook.index.record(of: page)?.geometry)
        lastContentError = nil
        guard !notebook.hasTextSession(on: page) else { lastContentError = Self.textBoxOpen(page); return }
        do { try notebook.addLinkLayer(on: page, rect: rect, target: target) } catch { lastContentError = error }
        binding.drain()
    }

    /// An insert while a box is open would record an entry out of order
    /// with the session's. Nothing here closes the box; the person editing
    /// it does.
    private static func textBoxOpen(_ page: PageID) -> FormatFault {
        .invalidWrite("page \(page) has a text box open")
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
