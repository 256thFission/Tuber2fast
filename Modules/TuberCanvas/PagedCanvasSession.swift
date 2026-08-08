import Foundation
import TuberModel

/// What the paged canvas runtime asks of the session that hosts it
/// (`Docs/Contract.md` — Owners).
///
/// Every question the runtime cannot answer for itself lives here, and every
/// one of them is required: `PagedCanvasController` cannot be constructed
/// without a session. That is the whole design, and it replaces eight optional
/// closures that failed open in two ways — a page with no content handler was
/// answered `.blank`, which is the editable blank canvas *Lifecycle* forbids,
/// and a retiring page's handover was dropped silently, which is a page's ink
/// lost with no trace. Neither could be caught before it shipped, because "the
/// seam is unwired" was a runtime shrug rather than a compile error. It is now
/// a compile error, so the state no longer exists to be classified
/// (`Contract.md` — Invalid states fail loud).
///
/// **Ownership.** The runtime holds its session **strongly**, which is what
/// lets the reference be non-optional — there is no `weak` that is not also an
/// optional, and an optional here is the defect this type removes. So whoever
/// owns the runtime must not itself be the session: `EditorSession` owns its
/// runtime and conforms through a small forwarding object that refers back
/// `unowned`. Nothing the runtime holds keeps a session alive, which is exactly
/// the ownership the `[weak self]` closures had.
@MainActor
package protocol PagedCanvasSession: AnyObject {
    /// The content for a page about to enter the window.
    ///
    /// `.loading` and `.unreadable` are the cases that matter: a page can enter
    /// the window before the session has its bytes, or with bytes that refuse
    /// to read. Such a page is a placeholder, never an editable blank — ink
    /// drawn on a blank standing in for a real page would be saved over it.
    func canvasContent(forPageAt index: Int) -> PagedCanvasController.PageContent

    /// A page's recognized layers below its ink, in order.
    ///
    /// A second question rather than a case on `PageContent`, deliberately:
    /// ink state and the layer list change on different occasions — an import
    /// changes the list while the ink stays exactly as it was — so a page's
    /// backdrop is refreshed without rebuilding its canvas, which would
    /// destroy live ink.
    ///
    /// An empty list is the answer for a page with nothing beneath its ink and
    /// for a page carrying a refused layer. The latter never reaches here at
    /// all — it is a placeholder, not a canvas — and answering empty is the
    /// belt to that braces: no partial composite exists to be mistaken for a
    /// correct one.
    func staticLayers(forPageAt index: Int) -> [LayerEnvelope]

    /// The page-space facts a page's canvas is built with: that page's own
    /// geometry, and the document's zoom cap.
    ///
    /// A third question rather than a field on `PageContent`, for the reason
    /// `staticLayers(forPageAt:)` is a second: it changes on a different
    /// occasion from ink — never, in fact, after the page exists — and it is
    /// needed at canvas construction, which is before any content decision has
    /// been taken.
    ///
    /// An index the session does not know is the session's own question to
    /// answer, and it answers it in one place rather than at this seam.
    func projection(forPageAt index: Int) -> PageProjection

    /// A live page's drawing changed. The index is the page's, and nothing
    /// else travels with it (`Contract.md` — Saving).
    func drawingChanged(onPageAt index: Int)

    /// One committed layer transform, and whether the session accepted it.
    ///
    /// The page index is added by `PagedCanvasController` and nowhere else,
    /// because a `PageCanvasController` is blind to which page it is
    /// (`Contract.md` — Owners, golden rule 7). Nothing about the gesture that
    /// produced the value travels with it — one immutable transform does,
    /// which is the same shape as a retiring page's drawing snapshot.
    func layerTransformed(
        onPageAt index: Int,
        layerID: UUID,
        to transform: PageSpaceTransform
    ) -> Bool

    /// A retiring page's ink, handed over before its controller is released.
    /// Without this a page's edits would die with its canvas when it left the
    /// window (`Contract.md` — Navigation: the handover is synchronous).
    func pageIsRetiring(at index: Int, handingOver snapshot: DrawingSnapshot)

    /// The visible page changed. Fired once per settled turn, not per frame.
    func currentPageChanged(to index: Int)

    /// The user swiped past the last page. The session decides whether a page
    /// is appended; the runtime never grows the document by itself.
    func reachedEndBoundary()
}
