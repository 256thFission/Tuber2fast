import CoreGraphics
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import TuberNotes

/// Phase 4 of `Docs/Forks/CanvasFeatureComplete.md`: transformable `image`
/// layers — select, move, scale, rotate.
///
/// What is proven here is what is mechanically provable off a device: the hit
/// test against a transformed unit square including a rotated one, that each
/// gesture produces the transform it claims to, that a locked layer selects but
/// refuses a transform, that a commit reaches disk and the value it replaced
/// comes back, that the composite drops the selected layer through the cache
/// key it already had, and that no selection state exists anywhere SwiftUI can
/// observe.
///
/// **What is not provable here, and is expected not to be:**
///
/// - The whole arbitration story. Whether a finger drag on a selected image
///   moves the image, whether a drag beginning elsewhere still pans and turns,
///   and whether `LayerDragRecognizer` claiming a touch on touch-down actually
///   prevents two `UIScrollView` pans are all UIKit gesture arbitration on a
///   real touch stream. The simulator has no Apple Pencil either, so the
///   interaction between `.pencilOnly` inking and a finger-only selection
///   recognizer cannot be seen here at all.
/// - **Undo, entirely.** `undoManager` walks the responder chain, so an
///   unhosted controller always reports `nil` (`Docs/Unproven.md` — Environment
///   traps). There is no assertion in this file about undo and there cannot be
///   one; `PageCanvasController.commitLayerTransform` documents what a person
///   must check by hand.
/// - Feel: whether a handle is the right size, whether the chrome reads as
///   chrome, and whether a rotation tracks the finger comfortably are a
///   maintainer's verdict.
@Suite("Layer selection and transforms")
@MainActor
struct LayerSelectionTests {

    // MARK: - The transform algebra

    @Test("A transform and its inverse round trip")
    func inverseRoundTrips() throws {
        let transform = PageSpaceTransform(a: 140, b: 0, c: 0, d: 90, tx: 60, ty: 210)
            .concatenating(.rotation(0.7))
            .concatenating(.translation(x: 11, y: -4))
        let inverse = try #require(transform.inverted)

        for point in [(0.0, 0.0), (1.0, 0.0), (0.25, 0.75), (1.0, 1.0)] {
            let there = transform.apply(x: point.0, y: point.1)
            let back = inverse.apply(x: there.x, y: there.y)
            #expect(abs(back.x - point.0) < 1e-9)
            #expect(abs(back.y - point.1) < 1e-9)
        }
    }

    @Test("Concatenation applies the receiver first")
    func concatenationOrder() {
        // Translate by (5, 0), then scale by 2: the origin lands at (10, 0).
        let translateThenScale = PageSpaceTransform.translation(x: 5, y: 0)
            .concatenating(.scale(2))
        let a = translateThenScale.apply(x: 0, y: 0)
        #expect(a.x == 10)
        #expect(a.y == 0)

        // The other order is a different transform: scale first, then
        // translate, and the origin lands at (5, 0).
        let scaleThenTranslate = PageSpaceTransform.scale(2)
            .concatenating(.translation(x: 5, y: 0))
        let b = scaleThenTranslate.apply(x: 0, y: 0)
        #expect(b.x == 5)
        #expect(b.y == 0)
    }

    @Test("A singular transform has no inverse")
    func singularTransformsHaveNoInverse() {
        #expect(PageSpaceTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0).inverted == nil)
        // Two collinear columns: the unit square collapses to a line.
        #expect(PageSpaceTransform(a: 2, b: 4, c: 1, d: 2, tx: 0, ty: 0).inverted == nil)
    }

    // MARK: - The hit test

    @Test("Hit-testing an axis-aligned layer, inside and just outside")
    func hitTestAxisAligned() {
        // A 200x100 patch at (100, 200) — the same placement
        // `StaticLayerRenderTests` composites.
        let transform = PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 100, ty: 200)

        #expect(transform.containsUnitSquarePoint(x: 150, y: 250), "the middle")
        #expect(transform.containsUnitSquarePoint(x: 100, y: 200), "the top-left corner")
        #expect(transform.containsUnitSquarePoint(x: 300, y: 300), "the bottom-right corner")

        #expect(!transform.containsUnitSquarePoint(x: 99.5, y: 250), "just left")
        #expect(!transform.containsUnitSquarePoint(x: 300.5, y: 250), "just right")
        #expect(!transform.containsUnitSquarePoint(x: 150, y: 199.5), "just above")
        #expect(!transform.containsUnitSquarePoint(x: 150, y: 300.5), "just below")
    }

    @Test("Hit-testing follows a rotation, in both directions")
    func hitTestRotated() {
        // A 100x100 square at (200, 300), turned 45 degrees about its own
        // centre (250, 350). Its corners now point along the axes at a
        // distance of 50 * sqrt(2) ~= 70.7, and its edge midpoints are at 50.
        let square = PageSpaceTransform(a: 100, b: 0, c: 0, d: 100, tx: 200, ty: 300)
        let rotated = square.concatenating(
            PageSpaceTransform.translation(x: -250, y: -350)
                .concatenating(.rotation(.pi / 4))
                .concatenating(.translation(x: 250, y: 350))
        )

        #expect(rotated.containsUnitSquarePoint(x: 250, y: 350), "the centre is always inside")

        // Straight right of the centre by 60: outside the unrotated square
        // (which ends at x = 300) and inside the rotated one (which reaches
        // 70.7 along the axes). One point, and it proves the rotation is
        // actually applied rather than merely stored.
        #expect(!square.containsUnitSquarePoint(x: 310, y: 350))
        #expect(rotated.containsUnitSquarePoint(x: 310, y: 350))

        // The unrotated square's own top-left corner: on the boundary before
        // the rotation, and 70.7 out along a direction where the rotated square
        // only reaches 50, so outside after it.
        #expect(square.containsUnitSquarePoint(x: 200, y: 300))
        #expect(!rotated.containsUnitSquarePoint(x: 200, y: 300))
    }

    // MARK: - Selection

    @Test("A tap selects the topmost layer under it, and empty space deselects")
    func tapSelectsTopmostAndEmptySpaceDeselects() throws {
        let canvas = UIScrollView()
        let runtime = Self.runtime(on: canvas)
        let lower = Self.imageLayer(PageSpaceTransform(a: 300, b: 0, c: 0, d: 300, tx: 0, ty: 0))
        let upper = Self.imageLayer(PageSpaceTransform(a: 300, b: 0, c: 0, d: 300, tx: 100, ty: 100))
        runtime.setLayers([lower, upper])

        // In the overlap. Later in the list is higher on the page.
        runtime.tapped(atPagePoint: CGPoint(x: 200, y: 200))
        #expect(runtime.selectedLayerID == upper.layerID)

        // Only the lower one is here.
        runtime.tapped(atPagePoint: CGPoint(x: 50, y: 50))
        #expect(runtime.selectedLayerID == lower.layerID)

        runtime.tapped(atPagePoint: CGPoint(x: 500, y: 600))
        #expect(runtime.selectedLayerID == nil)
    }

    /// The arbitration rule as a fact about the recognizer rather than a
    /// promise about a delegate: with nothing selected there is nothing on the
    /// canvas that could claim a drag.
    @Test("The drag recognizer exists only while a selection does")
    func theDragRecognizerFollowsTheSelection() {
        let canvas = UIScrollView()
        let runtime = Self.runtime(on: canvas)
        let layer = Self.imageLayer(PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 100, ty: 200))
        runtime.setLayers([layer])

        #expect(!runtime.dragRecognizerIsEnabledForTesting, "no selection, no claimant")
        runtime.select(layer)
        #expect(runtime.dragRecognizerIsEnabledForTesting)
        runtime.select(nil)
        #expect(!runtime.dragRecognizerIsEnabledForTesting)
    }

    @Test("A drag beginning off the selection is not ours")
    func aDragOffTheSelectionFallsThrough() {
        let canvas = UIScrollView()
        let runtime = Self.runtime(on: canvas)
        let layer = Self.imageLayer(PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 100, ty: 200))
        runtime.setLayers([layer])
        runtime.select(layer)

        #expect(runtime.grab(atPagePoint: CGPoint(x: 200, y: 250)) == .move, "on the layer")
        #expect(runtime.grab(atPagePoint: CGPoint(x: 500, y: 600)) == nil, "bare page")
        #expect(!runtime.beginTransform(atPagePoint: CGPoint(x: 500, y: 600)))
    }

    @Test("Selection draws chrome, and deselection draws none")
    func selectionDrawsChrome() {
        let canvas = UIScrollView()
        let runtime = Self.runtime(on: canvas)
        let layer = Self.imageLayer(PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 100, ty: 200))
        runtime.setLayers([layer])

        #expect(runtime.chromeLayerForTesting.isHidden)
        runtime.select(layer)
        #expect(!runtime.chromeLayerForTesting.isHidden)
        #expect(runtime.chromeLayerForTesting.path != nil)
        runtime.select(nil)
        #expect(runtime.chromeLayerForTesting.isHidden)
    }

    // MARK: - Move, scale, rotate

    @Test("A body drag translates the layer and commits one value")
    func aBodyDragMoves() throws {
        let canvas = UIScrollView()
        let runtime = Self.runtime(on: canvas)
        let start = PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 100, ty: 200)
        let layer = Self.imageLayer(start)
        runtime.setLayers([layer])
        runtime.select(layer)

        var committed: (id: UUID, from: PageSpaceTransform, to: PageSpaceTransform)?
        runtime.onTransformCommitted = { id, from, to in
            committed = (id, from, to)
            return true
        }

        #expect(runtime.beginTransform(atPagePoint: CGPoint(x: 200, y: 250)))
        runtime.updateTransform(toPagePoint: CGPoint(x: 250, y: 280))
        runtime.endTransform()

        let landed = try #require(committed)
        #expect(landed.id == layer.layerID)
        #expect(landed.from == start)
        // Size and orientation untouched; only the placement moved.
        #expect(landed.to == PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 150, ty: 230))
    }

    @Test("A corner drag scales about the opposite corner")
    func aCornerDragScales() throws {
        let canvas = UIScrollView()
        let runtime = Self.runtime(on: canvas)
        let start = PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 100, ty: 200)
        let layer = Self.imageLayer(start)
        runtime.setLayers([layer])
        runtime.select(layer)

        var committed: PageSpaceTransform?
        runtime.onTransformCommitted = { _, _, to in
            committed = to
            return true
        }

        // The bottom-right corner is placed at (300, 300); its opposite is
        // (100, 200).
        #expect(runtime.grab(atPagePoint: CGPoint(x: 300, y: 300)) == .scale(corner: 2))
        #expect(runtime.beginTransform(atPagePoint: CGPoint(x: 300, y: 300)))
        runtime.updateTransform(toPagePoint: CGPoint(x: 500, y: 400))
        runtime.endTransform()

        let scaled = try #require(committed)
        let anchor = scaled.apply(x: 0, y: 0)
        #expect(abs(anchor.x - 100) < 1e-9, "the opposite corner does not move")
        #expect(abs(anchor.y - 200) < 1e-9)

        let dragged = scaled.apply(x: 1, y: 1)
        #expect(abs(dragged.x - 500) < 1e-9, "the dragged corner follows the finger")
        #expect(abs(dragged.y - 400) < 1e-9)

        // Uniform in the layer's own frame, so the placed aspect ratio is
        // exactly what it was.
        #expect(abs(scaled.a / scaled.d - start.a / start.d) < 1e-9)
    }

    /// The scale factor is a page-space distance ratio, never a unit-space
    /// one. In unit space a non-square placement compresses each axis by its
    /// own placed extent, so distances there are not proportional to page
    /// distances — measured that way, this exact drag lands the corner at
    /// (643.4, 564.7), about 31 points from the finger and *below* it though
    /// the finger moved only right.
    @Test("Scaling a non-square placement measures distance in page space")
    func scalingANonSquarePlacementUsesPageSpaceDistance() throws {
        let canvas = UIScrollView()
        let runtime = Self.runtime(on: canvas)
        // A 1000x500 source fitted to the 612x792 page: 612 wide, 306 tall,
        // vertically centred. Placed width is twice placed height, the
        // anisotropy the unit-space metric mismeasures by exactly 2x.
        let start = PageSpaceTransform(a: 612, b: 0, c: 0, d: 306, tx: 0, ty: 243)
        let layer = Self.imageLayer(start)
        runtime.setLayers([layer])
        runtime.select(layer)

        var committed: PageSpaceTransform?
        runtime.onTransformCommitted = { _, _, to in
            committed = to
            return true
        }

        // Grab the bottom-right corner at (612, 549); its anchor is (0, 243).
        // Drag 61.2 points straight right.
        #expect(runtime.grab(atPagePoint: CGPoint(x: 612, y: 549)) == .scale(corner: 2))
        #expect(runtime.beginTransform(atPagePoint: CGPoint(x: 612, y: 549)))
        runtime.updateTransform(toPagePoint: CGPoint(x: 673.2, y: 549))
        runtime.endTransform()

        let scaled = try #require(committed)
        let anchor = scaled.apply(x: 0, y: 0)
        #expect(abs(anchor.x - 0) < 1e-9, "the opposite corner does not move")
        #expect(abs(anchor.y - 243) < 1e-9)

        // Uniform in the layer's own frame, factor the page-space ratio
        // |finger - anchor| / |corner - anchor|: the corner stays on the
        // anchor-to-corner ray at exactly the finger's distance from the
        // anchor.
        let factor = hypot(673.2 - 0, 549.0 - 243) / hypot(612.0 - 0, 549.0 - 243)
        let corner = scaled.apply(x: 1, y: 1)
        #expect(abs(corner.x - 612 * factor) < 1e-9)
        #expect(abs(corner.y - (243 + 306 * factor)) < 1e-9)
        #expect(
            abs(hypot(corner.x - 0, corner.y - 243) - hypot(673.2, 549.0 - 243)) < 1e-9,
            "the corner is at the finger's distance from the anchor"
        )

        // And specifically not where the unit-space metric put it.
        #expect(hypot(corner.x - 643.4, corner.y - 564.7) > 10)

        // The placed aspect ratio is exactly what it was.
        #expect(abs(scaled.a / scaled.d - start.a / start.d) < 1e-9)
    }

    /// On a square placement unit-space and page-space distances are
    /// proportional, so the page-space ratio reproduces the old arithmetic
    /// exactly — including for a finger off the anchor-to-corner ray.
    @Test("Scaling a square placement is unchanged")
    func scalingASquarePlacementIsUnchanged() throws {
        let canvas = UIScrollView()
        let runtime = Self.runtime(on: canvas)
        let start = PageSpaceTransform(a: 200, b: 0, c: 0, d: 200, tx: 100, ty: 100)
        let layer = Self.imageLayer(start)
        runtime.setLayers([layer])
        runtime.select(layer)

        var committed: PageSpaceTransform?
        runtime.onTransformCommitted = { _, _, to in
            committed = to
            return true
        }

        // Corner (1, 1) is at (300, 300), anchor at (100, 100). The finger
        // lands off the diagonal on purpose.
        #expect(runtime.beginTransform(atPagePoint: CGPoint(x: 300, y: 300)))
        runtime.updateTransform(toPagePoint: CGPoint(x: 400, y: 340))
        runtime.endTransform()

        let scaled = try #require(committed)
        // The unit-space arithmetic this placement makes equivalent:
        // local = ((400-100)/200, (340-100)/200) = (1.5, 1.2),
        // factor = hypot(1.5, 1.2) / sqrt(2).
        let factor = hypot(1.5, 1.2) / 2.0.squareRoot()
        let corner = scaled.apply(x: 1, y: 1)
        #expect(abs(corner.x - (100 + 200 * factor)) < 1e-9)
        #expect(abs(corner.y - (100 + 200 * factor)) < 1e-9)
        let anchor = scaled.apply(x: 0, y: 0)
        #expect(abs(anchor.x - 100) < 1e-9)
        #expect(abs(anchor.y - 100) < 1e-9)
    }

    @Test("A handle drag rotates about the layer's centre")
    func aHandleDragRotates() throws {
        let canvas = UIScrollView()
        let runtime = Self.runtime(on: canvas)
        let start = PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 100, ty: 200)
        let layer = Self.imageLayer(start)
        runtime.setLayers([layer])
        runtime.select(layer)

        var committed: PageSpaceTransform?
        runtime.onTransformCommitted = { _, _, to in
            committed = to
            return true
        }

        // The rotation handle sits 34 points above the middle of the top edge,
        // which is (200, 200) — so (200, 166) at a zoom scale of 1.
        #expect(runtime.grab(atPagePoint: CGPoint(x: 200, y: 166)) == .rotate)
        #expect(runtime.beginTransform(atPagePoint: CGPoint(x: 200, y: 166)))
        // A quarter turn: from straight above the centre (200, 250) to straight
        // to its right.
        runtime.updateTransform(toPagePoint: CGPoint(x: 284, y: 250))
        runtime.endTransform()

        let rotated = try #require(committed)
        let centre = rotated.apply(x: 0.5, y: 0.5)
        #expect(abs(centre.x - 200) < 1e-9, "the centre is the pivot")
        #expect(abs(centre.y - 250) < 1e-9)

        // The top-left corner was at (100, 200): 100 left and 50 up from the
        // centre. A quarter turn clockwise in y-down page space puts it 50
        // right and 100 up.
        let corner = rotated.apply(x: 0, y: 0)
        #expect(abs(corner.x - 250) < 1e-9)
        #expect(abs(corner.y - 150) < 1e-9)
    }

    @Test("A drag that moves nothing commits nothing")
    func aDragThatMovesNothingCommitsNothing() {
        let canvas = UIScrollView()
        let runtime = Self.runtime(on: canvas)
        let layer = Self.imageLayer(PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 100, ty: 200))
        runtime.setLayers([layer])
        runtime.select(layer)

        var commits = 0
        runtime.onTransformCommitted = { _, _, _ in
            commits += 1
            return true
        }

        #expect(runtime.beginTransform(atPagePoint: CGPoint(x: 200, y: 250)))
        runtime.endTransform()
        #expect(commits == 0, "a tap the drag recognizer claimed is not an edit")
    }

    @Test("A refused commit puts the layer back where it was")
    func aRefusedCommitIsPutBack() {
        let canvas = UIScrollView()
        let runtime = Self.runtime(on: canvas)
        let start = PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 100, ty: 200)
        let layer = Self.imageLayer(start)
        runtime.setLayers([layer])
        runtime.select(layer)
        runtime.onTransformCommitted = { _, _, _ in false }

        #expect(runtime.beginTransform(atPagePoint: CGPoint(x: 200, y: 250)))
        runtime.updateTransform(toPagePoint: CGPoint(x: 250, y: 280))
        #expect(runtime.liveTransform != start, "the drag moved it")
        runtime.endTransform()
        #expect(runtime.liveTransform == start, "the refusal put it back")
    }

    // MARK: - Locked

    @Test("A locked layer selects, and refuses every drag")
    func aLockedLayerSelectsButRefusesADrag() {
        let canvas = UIScrollView()
        let runtime = Self.runtime(on: canvas)
        let transform = PageSpaceTransform(a: 200, b: 0, c: 0, d: 100, tx: 100, ty: 200)
        let locked = Self.imageLayer(transform, locked: true)
        runtime.setLayers([locked])

        // Selectable: locked refuses transforms, not addressability.
        runtime.tapped(atPagePoint: CGPoint(x: 200, y: 250))
        #expect(runtime.selectedLayerID == locked.layerID)
        #expect(!runtime.chromeLayerForTesting.isHidden, "it still shows what is selected")

        // And not transformable anywhere on it — body, corner, or handle — so
        // the touch reaches the scroll views and a locked image pans the page.
        #expect(runtime.grab(atPagePoint: CGPoint(x: 200, y: 250)) == nil)
        #expect(runtime.grab(atPagePoint: CGPoint(x: 300, y: 300)) == nil)
        #expect(runtime.grab(atPagePoint: CGPoint(x: 200, y: 166)) == nil)
        #expect(!runtime.beginTransform(atPagePoint: CGPoint(x: 200, y: 250)))
    }

    // MARK: - The value that crosses the boundary

    @Test("An envelope written before `locked` existed decodes as unlocked")
    func anEnvelopeWithoutLockedDecodesAsUnlocked() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let old = try encoder.encode(
            PreLockEnvelope(
                layerID: UUID(),
                kind: "image",
                payload: Data([0x01]),
                pageSpaceTransform: .identity
            )
        )
        let decoded = try PropertyListDecoder().decode(LayerEnvelope.self, from: old)
        #expect(!decoded.locked)
        #expect(decoded.kind == "image")
    }

    @Test("`locked` survives an envelope round trip")
    func lockedRoundTripsThroughTheEnvelope() throws {
        let envelope = try LayerEnvelope.image(
            layerID: UUID(),
            ref: ImageLayerRef(assetID: UUID(), format: .png),
            pageSpaceTransform: PageSpaceTransform(a: 2, b: 0, c: 0, d: 3, tx: 4, ty: 5),
            locked: true
        )
        #expect(envelope.isSelectable)
        #expect(!envelope.isTransformable, "locked is exactly the difference between the two")

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder().decode(
            LayerEnvelope.self, from: try encoder.encode(envelope)
        )
        #expect(decoded == envelope)
        #expect(decoded.locked)
    }

    @Test("Moving a layer produces a new value and leaves the old one whole")
    func withPageSpaceTransformIsAValue() throws {
        let original = try LayerEnvelope.image(
            layerID: UUID(),
            ref: ImageLayerRef(assetID: UUID(), format: .jpeg),
            pageSpaceTransform: .identity,
            locked: true
        )
        let moved = original.withPageSpaceTransform(
            PageSpaceTransform(a: 10, b: 0, c: 0, d: 10, tx: 1, ty: 2)
        )
        #expect(original.pageSpaceTransform == .identity, "the prior value is untouched")
        #expect(moved.layerID == original.layerID)
        #expect(moved.kind == original.kind)
        #expect(moved.payload == original.payload)
        #expect(moved.locked, "everything but the placement is carried")
    }

    // MARK: - Fixtures

    /// A selection runtime over a bare scroll view at zoom 1. Nothing here is
    /// hosted, which is why nothing here can see an undo manager.
    ///
    /// The caller holds the scroll view. `LayerSelectionRuntime` refers to it
    /// `unowned` — correct in the app, where `PageCanvasController` owns both
    /// and they die together — so a fixture that let it go would read a
    /// destroyed object rather than test anything.
    private static func runtime(on canvasView: UIScrollView) -> LayerSelectionRuntime {
        LayerSelectionRuntime(canvasView: canvasView)
    }

    private static func imageLayer(
        _ transform: PageSpaceTransform,
        locked: Bool = false
    ) -> LayerEnvelope {
        // The payload is never opened by selection or hit-testing — that is the
        // whole point of the unit-square placement — so a ref to an asset that
        // does not exist is enough.
        guard let envelope = try? LayerEnvelope.image(
            layerID: UUID(),
            ref: ImageLayerRef(assetID: UUID(), format: .png),
            pageSpaceTransform: transform,
            locked: locked
        ) else {
            preconditionFailure("an image ref failed to encode")
        }
        return envelope
    }

    /// A `LayerEnvelope` as it was written before `locked` existed. Encoding
    /// through this is the only way to produce such a file now.
    private struct PreLockEnvelope: Encodable {
        let layerID: UUID
        let kind: String
        let payload: Data
        let pageSpaceTransform: PageSpaceTransform
    }
}

// MARK: - The commit, through the session

/// The handover: one committed value leaves the canvas runtime and follows the
/// ordinary save path.
@Suite("Layer transforms through the session", .serialized)
@MainActor
struct LayerTransformCommitTests {

    @Test("A committed transform reaches disk, and the prior value comes back")
    func aCommitIsDurableAndReturnsThePriorValue() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()
        let pageID = session.currentPageID

        let layerID = try await session.importImage(
            Scratch.solidPNG(width: 64, height: 64),
            format: .png,
            sourceWidth: 400,
            sourceHeight: 300
        )
        let placed = try #require(
            await scratch.store.loadPage(pageID).staticLayers.first
        ).pageSpaceTransform

        let moved = placed.concatenating(.translation(x: 37, y: -12))
        let prior = try session.transformLayer(layerID, onPage: pageID, to: moved)

        // The value the canvas runtime would register as its undo.
        #expect(prior.layerID == layerID)
        #expect(prior.pageSpaceTransform == placed)

        await session.saveIfNeeded()
        let onDisk = try #require(await scratch.store.loadPage(pageID).staticLayers.first)
        #expect(onDisk.layerID == layerID)
        #expect(onDisk.pageSpaceTransform == moved)
        #expect(!onDisk.locked)
    }

    @Test("Undoing a transform is re-committing the prior value")
    func theInverseIsAnOrdinaryCommit() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()
        let pageID = session.currentPageID

        let layerID = try await session.importImage(
            Scratch.solidPNG(width: 64, height: 64),
            format: .png,
            sourceWidth: 400,
            sourceHeight: 300
        )
        await session.saveIfNeeded()
        let original = try #require(
            await scratch.store.loadPage(pageID).staticLayers.first
        ).pageSpaceTransform

        let moved = original.concatenating(.translation(x: 90, y: 40))
        let prior = try session.transformLayer(layerID, onPage: pageID, to: moved)
        await session.saveIfNeeded()

        // What `PageCanvasController` registers with the responder chain's undo
        // manager is exactly this call with the prior value. The registration
        // itself is untestable here — `undoManager` is nil for an unhosted
        // controller — but that the inverse is an ordinary commit, and lands
        // through the ordinary save path, is not.
        try session.transformLayer(layerID, onPage: pageID, to: prior.pageSpaceTransform)
        await session.saveIfNeeded()

        let restored = try #require(await scratch.store.loadPage(pageID).staticLayers.first)
        #expect(restored.pageSpaceTransform == original)
    }

    @Test("A locked layer refuses a transform, and disk does not move")
    func aLockedLayerRefusesATransform() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()
        let pageID = session.currentPageID

        let layerID = try await session.importImage(
            Scratch.solidPNG(width: 64, height: 64),
            format: .png,
            sourceWidth: 400,
            sourceHeight: 300
        )
        try session.setLayerLocked(layerID, onPage: pageID, locked: true)
        await session.saveIfNeeded()

        let before = try #require(await scratch.store.loadPage(pageID).staticLayers.first)
        #expect(before.locked, "locked round trips through the page file")

        #expect(throws: LayerEditError.layerIsLocked(layerID: layerID, pageID: pageID)) {
            try session.transformLayer(
                layerID,
                onPage: pageID,
                to: PageSpaceTransform(a: 10, b: 0, c: 0, d: 10, tx: 0, ty: 0)
            )
        }

        await session.saveIfNeeded()
        let after = try #require(await scratch.store.loadPage(pageID).staticLayers.first)
        #expect(after.pageSpaceTransform == before.pageSpaceTransform)

        // And unlocking is the repair, not a special case.
        try session.setLayerLocked(layerID, onPage: pageID, locked: false)
        try session.transformLayer(
            layerID,
            onPage: pageID,
            to: PageSpaceTransform(a: 10, b: 0, c: 0, d: 10, tx: 0, ty: 0)
        )
        await session.saveIfNeeded()
        let moved = try #require(await scratch.store.loadPage(pageID).staticLayers.first)
        #expect(!moved.locked)
        #expect(moved.pageSpaceTransform == PageSpaceTransform(a: 10, b: 0, c: 0, d: 10, tx: 0, ty: 0))
    }

    @Test("Transforming a layer that is not there is refused, not guessed at")
    func anAbsentLayerIsRefused() async throws {
        let scratch = Scratch()
        let session = scratch.session()
        await session.start()
        let pageID = session.currentPageID
        let absent = UUID()

        #expect(throws: LayerEditError.layerNotFound(layerID: absent, pageID: pageID)) {
            try session.transformLayer(absent, onPage: pageID, to: .identity)
        }
        let stranger = UUID()
        #expect(throws: LayerEditError.pageNotFound(stranger)) {
            try session.transformLayer(absent, onPage: stranger, to: .identity)
        }
    }

    private final class Scratch {
        let directory: URL
        let store: DocumentStore

        init() {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tubernotes-transform-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            store = DocumentStore(
                directoryURL: directory.appendingPathComponent("JustACanvas.tubernotes")
            )
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        @MainActor
        func session() -> EditorSession {
            EditorSession(store: store, debounce: .milliseconds(20))
        }

        static func solidPNG(width: Int, height: Int) -> Data {
            guard let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                preconditionFailure("could not build a \(width)x\(height) context")
            }
            context.setFillColor(CGColor(srgbRed: 0, green: 0.6, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else {
                preconditionFailure("the context yielded no image")
            }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                out, UTType.png.identifier as CFString, 1, nil
            ) else {
                preconditionFailure("no PNG destination")
            }
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination), "PNG encoding failed")
            return out as Data
        }
    }
}

// MARK: - Minus-one recompositing

/// The composite a selected layer is lifted out of.
@Suite("Minus-one recompositing")
struct MinusOneCompositeTests {

    @Test("The composite drops the selected layer, as a second cache entry")
    func theCompositeExcludesTheSelectedLayer() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)

        // Red under the whole page, green over its top half. Excluding the
        // green one must show red where the green was.
        let background = try await scratch.imageLayer(
            colour: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            transform: PageSpaceTransform(
                a: PageGeometry.canonical.width, b: 0, c: 0, d: PageGeometry.canonical.height, tx: 0, ty: 0
            )
        )
        let overlay = try await scratch.imageLayer(
            colour: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
            transform: PageSpaceTransform(
                a: PageGeometry.canonical.width, b: 0, c: 0, d: PageGeometry.canonical.height / 2, tx: 0, ty: 0
            )
        )

        let whole = try await Self.composited(renderer, layers: [background, overlay])

        // Exactly what `PageCanvasController.layersToComposite` produces while
        // `overlay` is selected: the same list, one layer shorter. No new
        // mechanism — `CompositeKey` is the list of layer IDs, so this is
        // simply a different key.
        let minusOne = try await Self.composited(renderer, layers: [background])

        // Stated as a comparison between pixels of these two composites rather
        // than as "this pixel is red". A bitmap context's channel order is a
        // property of the context, not of the claim being made, and asserting a
        // colour by name here would be asserting the byte layout by accident.
        #expect(
            Self.pixel(minusOne, x: 306, y: 100) == Self.pixel(whole, x: 306, y: 700),
            "where the lifted layer was, the layer beneath it shows through"
        )
        #expect(
            Self.pixel(minusOne, x: 306, y: 100) != Self.pixel(whole, x: 306, y: 100),
            "and it is not what the full composite showed there"
        )

        #expect(
            await renderer.cachedCompositeCount == 2,
            "the two composites are two cache entries, not one invalidating the other"
        )

        // And the minus-one composite is stable under the drag: moving the
        // selected layer does not change the request that excludes it, so a
        // whole gesture causes no re-composite at all.
        _ = try await Self.composited(renderer, layers: [background])
        #expect(await renderer.cachedCompositeCount == 2)
    }

    @Test("A lifted source decodes for where the layer lands, not for the source")
    func aLiftedSourceIsBoundedByItsPlacement() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)

        // A 512-pixel source placed 100 x 50 page points across, at one
        // composite pixel per page point.
        let layer = try await scratch.imageLayer(
            colour: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
            size: 512,
            transform: PageSpaceTransform(a: 100, b: 0, c: 0, d: 50, tx: 40, ty: 60)
        )

        let lifted = try #require(await renderer.sourceImage(for: layer, at: 1))
        #expect(max(lifted.width, lifted.height) <= 100, "decode for the viewport, never for the source")
        #expect(max(lifted.width, lifted.height) > 0)

        // Nothing about a lifted source enters the composite cache: its bound
        // is stated in page-sized composites and this is not one.
        #expect(await renderer.cachedCompositeCount == 0)
    }

    @Test("A layer whose asset is gone cannot be lifted, and says nil")
    func anUnreadableLayerCannotBeLifted() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)
        let orphan = try LayerEnvelope.image(
            layerID: UUID(),
            ref: ImageLayerRef(assetID: UUID(), format: .png),
            pageSpaceTransform: PageSpaceTransform(a: 100, b: 0, c: 0, d: 50, tx: 0, ty: 0)
        )
        #expect(await renderer.sourceImage(for: orphan, at: 1) == nil)
    }

    // MARK: Fixtures

    private static func composited(
        _ renderer: StaticLayerRenderer,
        layers: [LayerEnvelope]
    ) async throws -> CGImage {
        let render = await renderer.composite(
            for: StaticLayerRequest(layers: layers, geometry: .canonical, pixelsPerPagePoint: 1)
        )
        guard case .composited(let composite) = render else {
            Issue.record("the stack rendered as \(render)")
            throw CocoaError(.fileNoSuchFile)
        }
        return composite.image
    }

    /// One pixel of a composite, as its three colour bytes in the sampling
    /// context's own order. The order is deliberately not named: every
    /// assertion above compares two of these, so the layout cancels.
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = bytes.withUnsafeMutableBytes({ buffer in
            CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        }) else {
            preconditionFailure("no 1x1 sampling context")
        }
        context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return [Int(bytes[0]), Int(bytes[1]), Int(bytes[2])]
    }

    private final class Scratch {
        let root: URL
        let store: DocumentStore

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tubernotes-minusone-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("JustACanvas.tubernotes/pages"),
                withIntermediateDirectories: true
            )
            store = DocumentStore(directoryURL: root.appendingPathComponent("JustACanvas.tubernotes"))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func imageLayer(
            colour: CGColor,
            size: Int = 64,
            transform: PageSpaceTransform
        ) async throws -> LayerEnvelope {
            let assetID = UUID()
            try await store.writeAsset(Self.png(size: size, colour: colour), assetID: assetID, format: .png)
            return try LayerEnvelope.image(
                layerID: UUID(),
                ref: ImageLayerRef(assetID: assetID, format: .png),
                pageSpaceTransform: transform
            )
        }

        static func png(size: Int, colour: CGColor) -> Data {
            guard let context = CGContext(
                data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                preconditionFailure("could not build a \(size)x\(size) context")
            }
            context.setFillColor(colour)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            guard let image = context.makeImage() else {
                preconditionFailure("the context yielded no image")
            }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                out, UTType.png.identifier as CFString, 1, nil
            ) else {
                preconditionFailure("no PNG destination")
            }
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination), "PNG encoding failed")
            return out as Data
        }
    }
}

// MARK: - Selection never reaches SwiftUI

/// `Contract.md` — Owners: SwiftUI never mirrors `PKDrawing`, pan, zoom, or
/// Pencil samples, and `Contract.proposed.md` A3 puts "a layer's
/// transform-in-progress, selection" in `PageCanvasController` at frame/input
/// frequency.
///
/// `EditorSession` is the only `@Observable` object in the app, so "selection
/// never reaches SwiftUI" is exactly "`EditorSession` has no selection state".
/// That is a structural claim, so it is checked structurally, with the same
/// comment-and-string stripping `ContractStructureTests` uses — otherwise the
/// prose explaining the rule would trip the rule.
@Suite("Selection stays inside the canvas runtime")
struct SelectionOwnershipTests {

    /// Tokens that would mean selection state had leaked into the observable
    /// object. An allowlist would be wrong here: the point is that *no*
    /// spelling of this state belongs in that file.
    static let selectionTokens = [
        "selectedLayer",
        "selection",
        "Selection",
        "liveTransform",
        "chrome",
    ]

    @Test("EditorSession holds no selection state")
    func theSessionHoldsNoSelectionState() throws {
        let code = try Self.appCode(named: "EditorSession.swift")
        let found = Self.selectionTokens.filter { code.contains($0) }
        #expect(
            found.isEmpty,
            """
            EditorSession names \(found.joined(separator: ", ")). Selection and a transform in \
            progress are frame-frequency canvas-runtime state; putting any of it on the one \
            @Observable object is what would publish it to SwiftUI.
            """
        )
    }

    /// The positive control. Without it this suite would still pass if
    /// selection were deleted outright, which is the "a check that has never
    /// failed is decoration" failure in its quietest form.
    @Test("PageCanvasController is where selection lives")
    func theCanvasRuntimeIsWhereSelectionLives() throws {
        let code = try Self.appCode(named: "PageCanvasController.swift")
        #expect(code.contains("LayerSelectionRuntime"))
        #expect(code.contains("selection"))
    }

    /// The planted violation. `CONTRIBUTING.md`: "A check that has never failed
    /// is decoration. Before trusting a new one, deliberately break the thing it
    /// guards, confirm it fails, then revert." Doing that by hand proves it once;
    /// this proves it on every run, and proves the other half too — that prose
    /// naming the rule does not trip the rule, which is the false positive that
    /// got the old shell gate disabled.
    @Test("The selection check catches a leak, and is not tripped by prose")
    func theSelectionCheckBites() {
        let leaked = ContractChecker.codeOnly(
            "private var selectedLayerID: UUID?\nvar liveTransform: PageSpaceTransform?\n"
        )
        #expect(
            Self.selectionTokens.contains { leaked.contains($0) },
            "selection state added to the observable object would go unnoticed"
        )

        let prose = ContractChecker.codeOnly(
            "// The canvas runtime owns selection and the chrome it draws.\nlet x = 1\n"
        )
        #expect(
            !Self.selectionTokens.contains { prose.contains($0) },
            "a comment explaining the rule must not be read as breaking it"
        )
    }

    private static func appCode(named name: String) throws -> String {
        let url = ContractStructureTests.appDirectory.appendingPathComponent(name)
        return ContractChecker.codeOnly(try String(contentsOf: url, encoding: .utf8))
    }
}
