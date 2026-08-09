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
/// **Every question and every report carries a page identity, never a page
/// position.** An index is only the page it names for as long as the list does
/// not change, and the list changes the moment a page can be inserted, deleted,
/// reordered, or duplicated. A stale index does not fail — it addresses the
/// *wrong page*, which on this seam means a page marked dirty that the user
/// never touched, a layer transformed on the wrong page, and, worst, a retiring
/// page's ink handed into a different page's custody. Identity is stable for
/// the page's life; a position is derived from it locally, in the one place
/// scroll arithmetic needs one.
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
    func canvasContent(forPage pageID: UUID) -> PagedCanvasController.PageContent

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
    func staticLayers(forPage pageID: UUID) -> [LayerEnvelope]

    /// The page-space facts a page's canvas is built with: that page's own
    /// geometry, and the document's zoom cap.
    ///
    /// A third question rather than a field on `PageContent`, for the reason
    /// `staticLayers(forPage:)` is a second: it changes on a different
    /// occasion from ink — never, in fact, after the page exists — and it is
    /// needed at canvas construction, which is before any content decision has
    /// been taken.
    ///
    /// A page the session does not know is the session's own question to
    /// answer, and it answers it in one place rather than at this seam.
    func projection(forPage pageID: UUID) -> PageProjection

    /// A live page's drawing changed. The identity is the page's, and nothing
    /// else travels with it (`Contract.md` — Saving).
    func drawingChanged(onPage pageID: UUID)

    /// One committed layer transform, and whether the session accepted it.
    ///
    /// The page identity is added by `PagedCanvasController` and nowhere else,
    /// because a `PageCanvasController` reports to its host rather than to the
    /// session, and is blind to page numbers, page order, and turns
    /// (`Contract.md` — Owners, golden rule 7). Nothing about the gesture that
    /// produced the value travels with it — one immutable transform does,
    /// which is the same shape as a retiring page's drawing snapshot.
    func layerTransformed(
        onPage pageID: UUID,
        layerID: UUID,
        to transform: PageSpaceTransform
    ) -> Bool

    /// A retiring page's ink, handed over before its controller is released.
    /// Without this a page's edits would die with its canvas when it left the
    /// window (`Contract.md` — Navigation: the handover is synchronous).
    func pageIsRetiring(_ pageID: UUID, handingOver snapshot: DrawingSnapshot)

    /// The visible page changed. Fired once per settled turn, not per frame.
    func currentPageChanged(to pageID: UUID)

    /// The user swiped past the last page. The session decides whether a page
    /// is appended; the runtime never grows the document by itself.
    func reachedEndBoundary()
}
