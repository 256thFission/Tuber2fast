import Foundation
@testable import TuberCanvas
@testable import TuberModel

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

    func canvasContent(forPageAt index: Int) -> PagedCanvasController.PageContent {
        content(index)
    }

    func staticLayers(forPageAt index: Int) -> [LayerEnvelope] {
        staticLayers(index)
    }

    func projection(forPageAt index: Int) -> PageProjection {
        projection(index)
    }

    func drawingChanged(onPageAt index: Int) {
        onDrawingChanged(index)
    }

    func layerTransformed(
        onPageAt index: Int,
        layerID: UUID,
        to transform: PageSpaceTransform
    ) -> Bool {
        layerTransforms.append((index, layerID, transform))
        return acceptsLayerTransforms
    }

    func pageIsRetiring(at index: Int, handingOver snapshot: DrawingSnapshot) {
        onPageRetiring(index, snapshot)
    }

    func currentPageChanged(to index: Int) {
        onPageChanged(index)
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
