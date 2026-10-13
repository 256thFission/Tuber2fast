import Foundation
import PencilKit
import TNCore
import TNModel
import TNNotebook
import UIKit

/// The runtime's own controls, which are not part of the value seam.
///
/// `CanvasSurface` in `TNModel` is the value channel: descriptors,
/// snapshots, composites. Retiring every live canvas at once, telling the
/// runtime whether undo is available, asking whether a stroke is in
/// flight, ending the tool uses nothing can touch, and committing every
/// open text box are about the runtime itself, so they live here rather
/// than widening the seam. The binding holds the runtime as one of these
/// and nothing narrower, so the close a test proves is the one production
/// runs. `TNCanvas` adopts this in `CanvasRuntime.swift`, the one file in
/// this target that names `TNCanvas`.
@MainActor package protocol CanvasRuntime: CanvasSurface {
    /// Tears the runtime down, which is terminal: it builds no canvas
    /// after this. Retires every live page and returns the pages whose
    /// retire was deferred by a stroke in flight; each of those reports
    /// later.
    func retireAll() -> [PageID]
    func setUndoAvailability(canUndo: Bool, canRedo: Bool)
    /// Whether any canvas, a departing one included, has a tool use open.
    /// Asked, never mirrored: the stroke is PencilKit's.
    var isStrokeInFlight: Bool { get }
    /// Nothing can touch the canvases: a tool use PencilKit did not end,
    /// ends.
    func endToolUses()
    /// Every open text box commits, as a tap away commits it, and reports
    /// `textEditingEnded` before this returns.
    func commitTextEditing()
}

/// Forwards the runtime's reports to the binding.
///
/// The runtime takes its reporter when it is built, and the production
/// binding builds its runtime inside its own initializer, before there is
/// a `self` to hand over. So the forwarder is made first, given to the
/// runtime, and pointed at the binding once the binding exists. It breaks
/// no cycle: the runtime and its undo manager hold the reporter unowned.
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

    package func layerDeleteRequested(on page: PageID, layer: LayerID) {
        binding?.layerDeleteRequested(on: page, layer: layer)
    }

    package func layerLockRequested(on page: PageID, layer: LayerID, locked: Bool) {
        binding?.layerLockRequested(on: page, layer: layer, locked: locked)
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
    package let surface: any CanvasRuntime
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
    /// Which Pencil gestures apply to the stroke in hand. Asked on every
    /// report rather than copied: a copy would go stale at the initialiser,
    /// at every tool change, and in every other tab sharing the palette.
    /// The default is no gesture at all, which is what a binding nobody has
    /// told about a tool must mean.
    package var bindingsForStroke: @MainActor () -> GestureBindings = { [:] }

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
        surface: any CanvasRuntime,
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
        // it for as long as it owns the runtime. Pointed here only now,
        // because the runtime was built before `self` existed.
        self.forwarder = forwarder
        forwarder?.binding = self

        // The opening push. `StructureSeq(0)` is below every sequence the
        // notebook mints, which starts at 1, so the structure change the
        // notebook queued when it opened supersedes this one in the same
        // turn and the runtime never sees the order go backwards.
        surface.setPages(notebook.descriptors, seq: StructureSeq(0), answering: nil)
        // And the page it was left on. The runtime learns the order from
        // `setPages`, whose descriptors carry no current flag, so without this
        // every notebook opens on its first page while the toolbar, which reads
        // the notebook, says otherwise.
        surface.scroll(to: notebook.currentPageID)
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
        surface.setUndoAvailability(canUndo: notebook.canUndo, canRedo: notebook.canRedo)
        onDrained?()
    }

    private func push(_ change: NotebookChange) {
        switch change {
        case .structure(let pages, let seq, let answering):
            surface.setPages(pages, seq: seq, answering: answering)
        case .content(let snapshot):
            surface.installContent(snapshot)
        case .unloaded(let page):
            surface.unload(page)
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

    /// Delivers the tool and the theme to the runtime.
    package func apply(_ environment: CanvasEnvironment) {
        surface.apply(environment)
    }

    /// The app left the foreground.
    package func endToolUses() {
        surface.endToolUses()
    }

    /// An open text box commits. Its report runs `textEditingEnded`
    /// below, which drains, so the notebook holds the words when this
    /// returns.
    package func commitTextEditing() {
        surface.commitTextEditing()
    }

    // MARK: Closing

    /// Retires every live canvas. Returns the pages whose retire the
    /// runtime deferred; each of those reports its final ink later.
    package func retireAll() -> [PageID] {
        // `hasRetired` answers for this close only: a page retired earlier
        // in the session and deferred now has not reported this stroke's ink.
        retirementsReported.removeAll()
        return surface.retireAll()
    }

    /// Whether every one of `pages` has since reported its retirement.
    package func hasRetired(_ pages: [PageID]) -> Bool {
        pages.allSatisfy(retirementsReported.contains)
    }

    // MARK: Reports

    package func inkChanged(on page: PageID, _ ink: PKDrawing, echoOf: InkSeq?) {
        // A report that arrives while a stroke is in flight is a commit
        // landing under the next stroke. No gesture applies to it: a
        // gesture's restore would replace the drawing under the Pencil.
        let bindings = surface.isStrokeInFlight ? [:] : bindingsForStroke()
        notebook.inkChanged(on: page, ink, echoOf: echoOf, bindings: bindings)
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

    /// One-way, unlike a transform: the answer is the composite that omits
    /// the layer. A locked layer is refused, and the runtime never offers
    /// Delete on one, so nothing here acts on the answer.
    package func layerDeleteRequested(on page: PageID, layer: LayerID) {
        notebook.deleteLayer(layer, on: page)
        drain()
    }

    /// One-way the same way: the composite that follows carries the flag.
    package func layerLockRequested(on page: PageID, layer: LayerID, locked: Bool) {
        _ = notebook.setLayerLock(layer, on: page, locked: locked)
        drain()
    }

    package func pageBecameCurrent(_ page: PageID) {
        notebook.pageBecameCurrent(page)
        drain()
    }

    package func windowChanged(to pages: [PageID]) {
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
        // I1: ignored while a stroke is in flight. The stroke is PencilKit's
        // until it commits; a restore under it would replace ink the
        // notebook has not seen. Asked of the runtime at the moment; nothing
        // kept here.
        guard !surface.isStrokeInFlight else {
            TNLog.event(.canvas, "undo ignored: a stroke is in flight")
            return
        }
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
        guard !surface.isStrokeInFlight else {
            TNLog.event(.canvas, "redo ignored: a stroke is in flight")
            return
        }
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
