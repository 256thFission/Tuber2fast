import Foundation
@testable import TuberCanvas
@testable import TuberModel

/// Page identities for a suite that thinks in page *numbers*.
///
/// The seam is identity-keyed, and a person reading a paging test thinks "page
/// 4", not "the page whose UUID is …". This is the one translation between the
/// two, and it is deterministic so that position 4 is the same identity in
/// every test, every run, and on both sides of a `setPages` call.
///
/// **It belongs to tests that host a runtime with no document behind it.** A
/// test driving a real `EditorSession` must use *that session's* page
/// identities — `pageIDForTesting(at:)` — because its pages are real and were
/// minted by the document. Reaching for this pool there would ask the runtime
/// about a page that does not exist, which is why nothing here is spelled like
/// the production API it feeds.
enum TestPages {
    /// The identity of the page at a position. Derived from the number rather
    /// than allocated, so no pool has to be threaded between a test and its
    /// session.
    static func id(_ position: Int) -> UUID {
        precondition(position >= 0, "a page position is never negative")
        return UUID(
            uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", position))"
        )!
    }

    /// The first `count` page identities, in order — a whole page list.
    static func order(_ count: Int) -> [UUID] {
        (0..<count).map(id)
    }

    /// The position an identity came from, or `nil` for an identity this pool
    /// did not mint.
    static func position(of pageID: UUID) -> Int? {
        let text = pageID.uuidString
        guard text.hasPrefix("00000000-0000-4000-8000-") else { return nil }
        return Int(text.suffix(12))
    }
}

extension PagedCanvasController {
    /// States a page list of `count` pages from `TestPages`, showing `current`.
    ///
    /// Deliberately not spelled `setPages`: a runtime driven by a real
    /// `EditorSession` has real page identities, and a helper that silently
    /// substituted this pool's would hand it a list of pages the document has
    /// never heard of. The awkward name is the point — it cannot be reached for
    /// by accident.
    func setTestPages(count: Int, current: Int = 0) {
        setPages(TestPages.order(count), current: TestPages.id(current))
    }

    /// The live canvas at a position, for a runtime driven by `TestPages`.
    func testLivePage(at position: Int) -> PageCanvasController? {
        livePage(TestPages.id(position))
    }
}

/// A session for a canvas runtime a test hosts directly, with no document
/// behind it.
///
/// It exists because the seam is required: `PagedCanvasController` cannot be
/// constructed without a session, so a test that hosts one says here what it
/// wants the session to answer. That is the point of the type rather than an
/// inconvenience of it — every answer below used to be the *runtime's* nil
/// default, which meant production shipped an editable blank page and a
/// silently dropped handover so that these tests could exist.
///
/// The defaults are this host's own decisions, and each one is stated. A test
/// that needs something else sets it; a test that leans on a default is
/// leaning on a line of test code it can read.
///
/// Its questions and reports are stated in **page numbers**, translated to and
/// from `TestPages` identities at this boundary. That keeps the suites readable
/// without letting the runtime see a position: what crosses the seam is always
/// an identity, which is the property the seam exists to have.
@MainActor
final class TestCanvasSession: PagedCanvasSession {
    /// **A blank, editable page for every slot.** Legitimate for a runtime
    /// with no document behind it — there are no bytes to lose and no page to
    /// overwrite — and never legitimate in an app, which is why it lives here
    /// and not in `PagedCanvasController`.
    var content: (Int) -> PagedCanvasController.PageContent = { _ in .blank }

    /// Nothing beneath the ink.
    var staticLayers: (Int) -> [LayerEnvelope] = { _ in [] }

    /// The canonical page, at the canonical zoom cap.
    var projection: (Int) -> PageProjection = { _ in .canonical }

    /// Every committed layer transform is accepted, as a session with no
    /// document to write to has no reason to refuse one.
    var acceptsLayerTransforms = true

    var onDrawingChanged: (Int) -> Void = { _ in }
    var onPageRetiring: (Int, DrawingSnapshot) -> Void = { _, _ in }
    var onPageChanged: (Int) -> Void = { _ in }
    var onReachedEndBoundary: () -> Void = {}

    private(set) var layerTransforms: [(index: Int, layerID: UUID, transform: PageSpaceTransform)] = []

    /// The position an identity from the seam came from.
    ///
    /// A page this pool did not mint is a defect in the *test*, not a state to
    /// answer for: it means a suite handed the runtime one list and asked it
    /// about another.
    private func position(_ pageID: UUID) -> Int {
        guard let position = TestPages.position(of: pageID) else {
            preconditionFailure(
                "page \(pageID) was not minted by TestPages; this session speaks "
                    + "page numbers and can only answer for pages it named"
            )
        }
        return position
    }

    func canvasContent(forPage pageID: UUID) -> PagedCanvasController.PageContent {
        content(position(pageID))
    }

    func staticLayers(forPage pageID: UUID) -> [LayerEnvelope] {
        staticLayers(position(pageID))
    }

    func projection(forPage pageID: UUID) -> PageProjection {
        projection(position(pageID))
    }

    func drawingChanged(onPage pageID: UUID) {
        onDrawingChanged(position(pageID))
    }

    func layerTransformed(
        onPage pageID: UUID,
        layerID: UUID,
        to transform: PageSpaceTransform
    ) -> Bool {
        layerTransforms.append((position(pageID), layerID, transform))
        return acceptsLayerTransforms
    }

    func pageIsRetiring(_ pageID: UUID, handingOver snapshot: DrawingSnapshot) {
        onPageRetiring(position(pageID), snapshot)
    }

    func currentPageChanged(to pageID: UUID) {
        onPageChanged(position(pageID))
    }

    func reachedEndBoundary() {
        onReachedEndBoundary()
    }
}

/// The host for a `PageCanvasController` a test builds without a paging
/// runtime around it. The same bargain as `TestCanvasSession`, one level down:
/// the reports have somewhere to go, and this file is where a test says what
/// happens to them.
///
/// A page canvas holds its host strongly, exactly as the paged runtime holds
/// its session, so a host passed inline at construction stays alive as long as
/// the canvas that reports to it.
@MainActor
final class TestPageHost: PageCanvasHost {
    /// Accepted, as `TestCanvasSession` accepts: nothing here has a document
    /// to refuse on behalf of.
    var acceptsLayerTransforms = true

    var onDrawingChanged: () -> Void = {}

    private(set) var drawingChanges = 0
    private(set) var layerTransforms: [(layerID: UUID, transform: PageSpaceTransform)] = []

    func drawingChanged() {
        drawingChanges += 1
        onDrawingChanged()
    }

    func layerTransformed(_ layerID: UUID, to transform: PageSpaceTransform) -> Bool {
        layerTransforms.append((layerID, transform))
        return acceptsLayerTransforms
    }
}
