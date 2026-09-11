import Foundation
import PencilKit
import TNCore
import TNModel
import TNNotebook
import UIKit

/// The runtime's own controls, which are not part of the value seam.
///
/// `CanvasSurface` in `TNModel` is the value channel: descriptors,
/// snapshots, composites. Retiring every live canvas at once and telling
/// the runtime whether undo is available are commands about the runtime
/// itself, so they live here rather than widening the seam. `TNCanvas`
/// adopts this in `CanvasRuntime.swift`, the one file in this target that
/// names `TNCanvas`.
@MainActor package protocol CanvasRuntime: CanvasSurface {
    /// Retires every live page. Returns the pages whose retire was
    /// deferred by a stroke in flight; each of those reports later.
    func retireAll() -> [PageID]
    func setUndoAvailability(canUndo: Bool, canRedo: Bool)
}

/// Forwards the runtime's reports to the binding without keeping it alive.
///
/// The binding owns the runtime, and the runtime holds its reporter; if
/// the binding were the reporter, the pair would retain each other and the
/// notebook would never close. The forwarder is the one weak link in that
/// ring, and it exists before the runtime does, which is also what lets
/// the runtime be built inside the binding's own initializer.
@MainActor package final class ReportForwarder: CanvasReporting {
    fileprivate weak var binding: EditorBinding?

    package init() {}

    package func inkChanged(on page: PageID, _ ink: PKDrawing, echoOf: InkSeq?) {
        binding?.inkChanged(on: page, ink, echoOf: echoOf)
    }

    package func layerTransformed(on page: PageID, layer: LayerID, to transform: PageSpaceTransform) -> TransformOutcome {
        guard let binding else { return .refused(reason: "the editor is gone") }
        return binding.layerTransformed(on: page, layer: layer, to: transform)
    }

    package func pageBecameCurrent(_ page: PageID) { binding?.pageBecameCurrent(page) }
    package func windowChanged(to pages: [PageID]) { binding?.windowChanged(to: pages) }
    package func endBoundaryReached(seq: ReportSeq) { binding?.endBoundaryReached(seq: seq) }
    package func linkActivated(on page: PageID, layer: LayerID) { binding?.linkActivated(on: page, layer: layer) }
    package func retired(_ page: PageID, finalInk: PKDrawing?) { binding?.retired(page, finalInk: finalInk) }
    package func undoRequested() { binding?.undoRequested() }
    package func redoRequested() { binding?.redoRequested() }
    package func textBoxRequested(on page: PageID, at point: PagePoint, style: TextStyle, alignment: TextAlignment) {
        binding?.textBoxRequested(on: page, at: point, style: style, alignment: alignment)
    }
    package func textEditRequested(on page: PageID, layer: LayerID) { binding?.textEditRequested(on: page, layer: layer) }
    package func textEditingEnded(on page: PageID, layer: LayerID, _ text: TextLayer) {
        binding?.textEditingEnded(on: page, layer: layer, text)
    }
}

/// The one place the notebook and the canvas runtime meet.
///
/// Reports come up, are forwarded to the notebook, and the changes the
/// notebook queued are pushed down before the handler returns. That is
/// what makes an answer synchronous without re-entering a mutation: the
/// runtime reports last, so the notebook's state change is finished
/// before the push arrives, and the push lands in the same turn — an
/// append answers before the next frame.
@MainActor package final class EditorBinding: CanvasReporting {
    /// Strong: the binding is the notebook's owner for as long as a tab
    /// holds the binding, and nothing else holds either.
    package let notebook: Notebook
    /// Strong: the binding owns the runtime it drives.
    package let surface: any CanvasSurface
    /// The canvas as a plain view controller, which is how the app gets it
    /// without ever naming `TNCanvas`.
    package let host: UIViewController
    /// Where an activated link goes. The editor resolves the layer to a
    /// target; where the app takes the reader is the app's business.
    package var onLinkActivated: @MainActor (LinkTarget) -> Void
    /// Called at the end of every drain, so a view model can refresh the
    /// mirrors it stores.
    package var onDrained: (@MainActor () -> Void)?
    /// Called when a stroke somebody drew lands, which is what makes the
    /// colour it landed in a colour they have used.
    package var onInkReported: (@MainActor () -> Void)?

    private var runtime: (any CanvasRuntime)? { surface as? any CanvasRuntime }
    /// The last complete window the runtime reported.
    private var window: [PageID] = []
    /// Pages the runtime has reported retired, which is how a deferred
    /// retire is known to have landed before the notebook closes.
    private var retirementsReported: Set<PageID> = []
    private var isDraining = false

    // The production initializer, which makes the runtime it drives, is
    // in `CanvasRuntime.swift`, beside the import it needs.

    /// The designated initializer. A test passes its own surface; the
    /// production path passes the runtime and the forwarder that reports
    /// back into it.
    private let forwarder: ReportForwarder?

    package init(
        notebook: Notebook,
        surface: any CanvasSurface,
        forwarder: ReportForwarder? = nil,
        onLinkActivated: @escaping @MainActor (LinkTarget) -> Void = { _ in }
    ) {
        self.notebook = notebook
        self.surface = surface
        // A surface that is not a view controller has no host to vend; the
        // app never asks one for it, because only the production path,
        // whose surface is the runtime, reaches `EditorViewModel`.
        self.host = (surface as? UIViewController) ?? UIViewController()
        self.onLinkActivated = onLinkActivated
        // The runtime holds the forwarder unowned, so the binding must own
        // it for as long as it owns the runtime.
        self.forwarder = forwarder
        forwarder?.binding = self

        // The opening push. `StructureSeq(0)` is below every sequence the
        // notebook mints, which starts at 1, so the structure change the
        // notebook queued when it opened supersedes this one in the same
        // turn and the runtime never sees the order go backwards.
        surface.setPages(notebook.descriptors, seq: StructureSeq(0), answering: nil)
        notebook.onAsyncChange = { [weak self] in self?.drain() }
        drain()
    }

    // MARK: The drain

    /// Pushes everything the notebook has queued, then tells the runtime
    /// what undo can do. Called after every report and on every change
    /// that lands outside one.
    package func drain() {
        // A push that reported straight back would re-enter here; the
        // outer drain's next poll picks up whatever the inner one queued,
        // so nothing is lost and nothing recurses.
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        var changes = notebook.drainChanges()
        while !changes.isEmpty {
            for change in changes { push(change) }
            changes = notebook.drainChanges()
        }
        runtime?.setUndoAvailability(canUndo: notebook.canUndo, canRedo: notebook.canRedo)
        onDrained?()
    }

    private func push(_ change: NotebookChange) {
        switch change {
        case .structure(let pages, let seq, let answering):
            surface.setPages(pages, seq: seq, answering: answering)
        case .content(let snapshot):
            surface.installContent(snapshot)
        case .inkRestored(let page, let ink, let seq):
            surface.restoreInk(on: page, ink, seq: seq)
        case .compositeUpdated(let page, let composite, let layers):
            surface.updateComposite(on: page, composite, layers: layers)
        case .textEditingBegan(let page, let start):
            surface.beginTextEditing(on: page, start)
        case .textEditingEnded(let page, let layer):
            surface.endTextEditing(on: page, layer: layer)
        }
    }

    /// Runs a mutation of the notebook and pushes what it queued.
    package func intention(_ body: () -> Void) {
        body()
        drain()
    }

    /// The same, for a mutation that must leave the main actor — an
    /// import writes an asset before the layer exists.
    package func intention(_ body: () async -> Void) async {
        await body()
        drain()
    }

    /// Delivers the tool to the runtime.
    package func apply(_ environment: CanvasEnvironment) {
        surface.apply(environment)
    }

    // MARK: Closing

    /// Retires every live canvas. Returns the pages whose retire the
    /// runtime deferred; each of those reports its final ink later.
    package func retireAll() -> [PageID] {
        if let runtime { return runtime.retireAll() }
        return window.filter { surface.retire($0) == .deferred }
    }

    /// Whether every one of `pages` has since reported its retirement.
    package func hasRetired(_ pages: [PageID]) -> Bool {
        pages.allSatisfy(retirementsReported.contains)
    }

    // MARK: Reports

    package func inkChanged(on page: PageID, _ ink: PKDrawing, echoOf: InkSeq?) {
        notebook.inkChanged(on: page, ink, echoOf: echoOf)
        // An echo is the runtime restating ink it was handed, which is a
        // restore and not a stroke anybody drew.
        if echoOf == nil { onInkReported?() }
        drain()
    }

    package func layerTransformed(on page: PageID, layer: LayerID, to transform: PageSpaceTransform) -> TransformOutcome {
        let outcome = notebook.transformLayer(on: page, layer: layer, to: transform)
        drain()
        return outcome
    }

    package func pageBecameCurrent(_ page: PageID) {
        notebook.pageBecameCurrent(page)
        drain()
    }

    package func windowChanged(to pages: [PageID]) {
        window = pages
        notebook.windowChanged(to: pages)
        // Content for a page that has left the window and is clean is
        // dropped here, which is the only place that decision is taken.
        notebook.prune()
        drain()
    }

    package func endBoundaryReached(seq: ReportSeq) {
        notebook.appendPage(answering: seq)
        drain()
    }

    package func linkActivated(on page: PageID, layer: LayerID) {
        guard let target = linkTarget(on: page, layer: layer) else {
            TNLog.event(.canvas, "a link was activated on page \(page) for layer \(layer), which is not a link")
            return
        }
        onLinkActivated(target)
    }

    private func linkTarget(on page: PageID, layer: LayerID) -> LinkTarget? {
        guard let content = notebook.state(of: page)?.content,
              let found = content.layers.first(where: { $0.id == layer }),
              case .link(let link) = found.payload
        else { return nil }
        return link.target
    }

    package func retired(_ page: PageID, finalInk: PKDrawing?) {
        retirementsReported.insert(page)
        notebook.retired(page, finalInk: finalInk)
        drain()
    }

    package func undoRequested() {
        // While a box is open the text view's own manager answers, and the
        // stack is not touched: `Notebook.apply` requires no open session,
        // and this routing is what keeps that true. The runtime is not
        // asked whether its view exists yet; in that window typing has
        // nothing to undo and the request is dropped there.
        if notebook.hasTextSession {
            surface.undoTyping()
            return
        }
        let page = notebook.undo()
        drain()
        // An undo restores the page it happened on, whichever page is
        // current, so the reader is taken to the change they undid. The
        // scroll answers the undo itself, not the ink restore it may or may
        // not have queued: a layer-only undo queues none.
        if let page { surface.scroll(to: page) }
    }

    package func redoRequested() {
        if notebook.hasTextSession {
            surface.redoTyping()
            return
        }
        let page = notebook.redo()
        drain()
        if let page { surface.scroll(to: page) }
    }

    package func textBoxRequested(on page: PageID, at point: PagePoint, style: TextStyle, alignment: TextAlignment) {
        notebook.createTextBox(on: page, at: point, style: style, alignment: alignment)
        drain()
    }

    package func textEditRequested(on page: PageID, layer: LayerID) {
        notebook.beginTextEditing(on: page, layer: layer)
        drain()
    }

    package func textEditingEnded(on page: PageID, layer: LayerID, _ text: TextLayer) {
        notebook.endTextEditing(on: page, layer: layer, text)
        drain()
    }
}
