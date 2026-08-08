import TuberCore
import TuberModel
import TuberRender
import UIKit

/// The page's static layers, shown beneath the ink.
///
/// Phase 2 of `Docs/Forks/CanvasFeatureComplete.md`, rendering half. This is
/// the **mirrored sibling**: a `CALayer` stack under a transparent
/// `PKCanvasView`, registered with the ink by one transform assignment per
/// scroll tick from the canvas runtime's existing delegate callbacks.
///
/// This is not a second owner. It is `PageCanvasController`'s own runtime —
/// constructed by that controller, alive only inside it, holding nothing
/// durable and writing nothing — exactly as `ShapeToolRuntime` is. It renders
/// what it is handed and asks nothing.
///
/// **A layer, not a view, and that is load-bearing.** The fork doc's presumed
/// structure says "sibling view"; this project's own code says the safer
/// primitive is a layer. `PKCanvasView` is a `UIScrollView`, and this project
/// already crashed UIKit inside `_delayTouchesForEvent:` by adding a subview to
/// it — the page boundary and the shape tool's preview are both `CALayer`s for
/// exactly that reason. A sibling *view* under the canvas is a subview of the
/// controller's own root rather than of the canvas, so it is not that crash;
/// but it would still be a touch-handling participant sitting under a scroll
/// view, and it buys nothing a layer does not give. Layers never participate in
/// touch handling, so they cannot perturb it.
///
/// Two layers, and the outer one earns its place: slots in the paging scroll
/// view are adjacent, so a page-sized layer transformed by a zoom of 3 would
/// draw across its neighbours. `clip` masks to the viewport and nothing else
/// does — clipping the controller's root view instead would change behaviour
/// for every page, including the blank ones this feature must not touch.
@MainActor
final class PageBackdrop {
    /// Masks the mirrored stack to this page's slot. Bounds-sized, never
    /// transformed.
    private let clip = CALayer()

    /// Carries the texture. **Page-sized bounds in page points**, anchored at
    /// the page origin, positioned once — every mirror tick assigns exactly one
    /// transform to it and nothing else.
    private let page = CALayer()

    /// The layer being manipulated, drawn live above the composite it was
    /// lifted out of.
    ///
    /// Phase 4's minus-one recompositing, and the reason there is no ghosting:
    /// a layer under manipulation is baked into the composite it is being
    /// lifted from, so while it is selected the composite beneath it is
    /// re-rendered *without* it and this carries it instead. Moving it is one
    /// transform assignment per frame — no decode, no re-composite, nothing on
    /// the main thread but a property set.
    ///
    /// A **sublayer of `page`**, which is what makes that true: `page` already
    /// carries the mirror transform for pan and zoom, and a sublayer inherits
    /// it, so this needs only the layer's own page-space transform and the
    /// mirror comes free. Sublayers draw above their superlayer's `contents`,
    /// so it is above the composite and — being inside the backdrop — still
    /// below the ink.
    ///
    /// MEMORY: at most one of these exists per live page, holding one decoded
    /// source bounded by the same level-of-detail cap the composite uses (a
    /// 2,800 px long edge, so about 31 MB worst case with alpha). It is
    /// released the moment the layer is deselected.
    private let lift = CALayer()

    /// The sharp patch over the visible rect at a settled deep zoom — the
    /// "lens" of the fork doc's base-and-lens design.
    ///
    /// A **sublayer of `page`**, for the reason `lift` is: `page` carries the
    /// mirror transform, a sublayer inherits it, so the lens stays registered
    /// with the base for free and needs only its page-space frame. It sits
    /// above the base texture (`page.contents`) and below the lift — a layer
    /// being dragged must draw over everything static — and, being inside the
    /// backdrop, below the ink always.
    ///
    /// MEMORY: at most one of these exists per live page, and it is
    /// viewport-sized at the settled zoom by construction — the lens is asked
    /// for the visible rect, never the page. In memory only; nothing about it
    /// ever touches disk (`Contract.proposed.md` A7 stays unneeded).
    ///
    /// A stale sharp patch at the wrong position is worse than soft, so the
    /// controller hides this the moment the view transforms away from the
    /// settled state; `hideLens` is one property write and a nil `contents`.
    private let lens = CALayer()

    /// Whether `lens` is carrying an image. Read by tests and by nothing else:
    /// the controller does not branch on it, it just hides eagerly.
    private(set) var hasLens = false

    /// Whether `lift` is carrying an image. The controller reads it to decide
    /// whether the composite may exclude that layer: **excluding a layer from
    /// the composite is only safe once something else is drawing it.**
    private(set) var hasLift = false

    /// Whether a composite has ever landed here. A second request keeps the
    /// texture it already has rather than blanking back to the placeholder:
    /// "a late render shows the placeholder or a scaled base, never a blank
    /// page and never a wrong page".
    private var hasTexture = false

    /// The page is loading its static layers. Loud rather than subtle: a page
    /// whose image has not arrived must not be mistakable for a page that has
    /// none. Deliberately not the grey of `PagedCanvasController`'s placeholder
    /// views — that grey means "this is not a page you can write on", and this
    /// one sits *under live ink on an editable page*, so it has to read as
    /// chrome rather than as content or as a refusal.
    ///
    /// Opaque rather than a wash over white, because the canvas above is
    /// transparent and there is nothing behind this to blend with.
    ///
    /// A tint carries no sentence, and that is deliberate too: a label under
    /// live ink would be unreadable the moment anyone wrote on it. The
    /// user-facing sentences belong to `failure-has-a-taxonomy`.
    private static let loadingTint = CGColor(srgbRed: 0.78, green: 0.92, blue: 0.94, alpha: 1)

    /// The stack could not be rendered honestly. A different colour from
    /// loading on purpose — a refusal that looks like a slow load is a refusal
    /// nobody acts on.
    private static let refusedTint = CGColor(srgbRed: 0.97, green: 0.82, blue: 0.79, alpha: 1)

    /// Installs the stack under `canvasView`, in the canvas runtime's own root
    /// view.
    ///
    /// `canvasView` is typed as `UIView` rather than `PKCanvasView` because
    /// nothing here needs PencilKit's vocabulary — only a layer to insert
    /// below.
    ///
    /// `geometry` is this page's own, told at construction and never changed:
    /// the texture layer's bounds *are* the page rectangle in page points, so a
    /// backdrop that read a global would draw a landscape page's worksheet into
    /// a portrait frame. It is the whole of this file's phase 3b change.
    init(under canvasView: UIView, in hostView: UIView, geometry: PageGeometry) {
        clip.masksToBounds = true
        clip.frame = hostView.bounds

        page.anchorPoint = .zero
        page.position = .zero
        page.bounds = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        // Linear at magnification is what a real texture does under zoom;
        // trilinear at minification is what stops an overview zoom from
        // aliasing the composite into noise. Softness under deep zoom is the
        // accepted cost until phase 3's lens; misregistration would not be.
        page.magnificationFilter = .linear
        page.minificationFilter = .trilinear
        page.backgroundColor = Self.loadingTint
        // So a lifted layer dragged past the page edge clips exactly where the
        // committed composite will clip it. Without this the picture changes at
        // the instant of commit, which reads as the drag having moved something
        // it did not.
        page.masksToBounds = true

        lens.anchorPoint = .zero
        lens.magnificationFilter = .linear
        lens.minificationFilter = .trilinear
        lens.isHidden = true
        // Before the lift, so the lift draws above it: a dragged layer must
        // show over every static texture, sharp or soft.
        page.addSublayer(lens)

        lift.anchorPoint = .zero
        lift.position = .zero
        lift.magnificationFilter = .linear
        lift.minificationFilter = .trilinear
        lift.isHidden = true
        page.addSublayer(lift)

        clip.addSublayer(page)
        // Below the canvas's own layer, which is what makes this the *sibling*
        // structure rather than the inside-`PKCanvasView` one the fork doc puts
        // the burden of proof on.
        hostView.layer.insertSublayer(clip, below: canvasView.layer)
    }

    /// Detaches the stack. Called when a page's layer list becomes empty, so a
    /// page with nothing beneath its ink pays nothing.
    func remove() {
        clip.removeFromSuperlayer()
    }

    // MARK: - The frame path

    /// One mirror assignment, from the canvas runtime's scroll callbacks.
    ///
    /// Page point `p` renders at `p * zoom - contentOffset` in the host view's
    /// space. `contentInset` needs no term of its own: a scroll view maps
    /// content to view by subtracting `contentOffset`, and the inset is already
    /// inside that offset.
    ///
    /// Per tick this does one `CATransform3D` construction on the stack and one
    /// layer property assignment. No allocation, no publication, no logging —
    /// the same shape of work `updatePageBoundary` already does per pinch
    /// frame. Implicit animation is off, because an animated transform would
    /// lag the ink it is registered with by the length of the default
    /// animation, which is precisely the drift this structure exists to avoid.
    func mirror(offset: CGPoint, zoom: CGFloat) {
        let transform = CATransform3DScale(
            CATransform3DMakeTranslation(-offset.x, -offset.y, 0), zoom, zoom, 1
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        page.transform = transform
        CATransaction.commit()
    }

    /// The viewport changed size — a rotation, a Split View resize, the first
    /// layout. Not a frame-frequency path: `UIScrollView` moves its own bounds
    /// origin to scroll and this frame does not follow it.
    func viewportChanged(to bounds: CGRect) {
        guard clip.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Contents

    /// A composite has been asked for. Shows the placeholder only if nothing
    /// has ever landed here; a page that already has a texture keeps it and
    /// goes soft rather than blank while a sharper one renders.
    func compositeRequested() {
        guard !hasTexture else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        page.contents = nil
        page.backgroundColor = Self.loadingTint
        CATransaction.commit()
    }

    /// The one main-thread step of the whole pipeline: a `contents` assignment
    /// with the pixels already built.
    func show(_ render: StaticLayerRender) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch render {
        case .empty:
            // Reached only if a page's layers were emptied between the request
            // and its answer. The page is white; the canvas above will be made
            // opaque again by its controller.
            page.contents = nil
            page.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            hasTexture = false

        case .composited(let composite):
            page.contents = composite.image
            page.contentsScale = composite.pixelsPerPagePoint
            page.backgroundColor = nil
            hasTexture = true

        case .refused(let why):
            // Never a partial composite: a page that cannot render its stack
            // honestly says so (`Contract.md` — Invalid states fail loud).
            page.contents = nil
            page.backgroundColor = Self.refusedTint
            hasTexture = false
            CanvasLog.event(.canvas, "static layers refused: \(why)")

        case .cancelled:
            // Correct code cannot reach this: a render is cancelled only when
            // nobody is left to install it, and the controller re-checks its
            // own cancellation before calling here. Showing anything would
            // paint a page the user swiped past.
            preconditionFailure("a cancelled render was handed to the backdrop")
        }
        CATransaction.commit()
    }

    // MARK: - The lens

    /// Puts a settled-zoom render into the lens layer over exactly the
    /// page-space rect it shows. One `contents` assignment with the pixels
    /// already built — the same main-thread share `show(_:)` has.
    ///
    /// The layer's frame is the rect in page points; the image stretches to
    /// fill it, and since the image was rendered at the settled zoom's own
    /// pixels-per-page-point, "stretches" is pixel-exact at that zoom.
    func showLens(_ image: CGImage, over pageRect: CGRect) {
        precondition(!pageRect.isEmpty, "a lens over an empty rect shows nothing")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lens.bounds = CGRect(origin: .zero, size: pageRect.size)
        lens.position = pageRect.origin
        lens.contents = image
        lens.isHidden = false
        CATransaction.commit()
        hasLens = true
    }

    /// Drops the lens. Called the moment the view transforms away from the
    /// settled state it was rendered for — a stale sharp patch at the wrong
    /// position is worse than the soft base. Cheap when there is none, which
    /// is every scroll tick on a page that was never deep-zoomed.
    func hideLens() {
        guard hasLens else { return }
        hasLens = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lens.isHidden = true
        lens.contents = nil
        CATransaction.commit()
    }

    // MARK: - The lifted layer

    /// Puts a decoded source into the lift layer and places it.
    ///
    /// The layer's bounds are the source's **pixel** extent at
    /// `contentsScale` 1, so contents and bounds agree exactly and nothing is
    /// resampled by the layer tree; the pixel-to-unit-square scale is folded
    /// into the transform instead. That composition — pixels, then the unit
    /// square, then page space — is the durable model spelled out in three
    /// steps (`Contract.proposed.md` A6: "the one invertible mapping from the
    /// image's own extent, taken as the unit square with its origin at
    /// top-left, into page space").
    ///
    /// No y-flip appears anywhere here, deliberately: a `CALayer`'s coordinates
    /// are y-down from the top-left, which is page space's own convention, so
    /// the two flips `StaticLayerRenderer` needs against CoreGraphics have no
    /// counterpart on this path.
    func showLift(_ image: CGImage, at transform: PageSpaceTransform) {
        precondition(image.width > 0 && image.height > 0, "a lifted source has no extent")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lift.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        lift.contents = image
        lift.isHidden = false
        CATransaction.commit()
        hasLift = true
        moveLift(to: transform)
    }

    /// One frame of a transform in progress: a single transform assignment,
    /// no allocation, no publication — the same shape of work the mirror does
    /// per scroll tick.
    func moveLift(to transform: PageSpaceTransform) {
        guard hasLift else { return }
        let pixels = lift.bounds.size
        guard pixels.width > 0, pixels.height > 0 else { return }
        let intoUnitSquare = PageSpaceTransform(
            a: 1 / Double(pixels.width), b: 0,
            c: 0, d: 1 / Double(pixels.height),
            tx: 0, ty: 0
        )
        let placed = intoUnitSquare.concatenating(transform)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lift.transform = CATransform3DMakeAffineTransform(
            CGAffineTransform(
                a: placed.a, b: placed.b, c: placed.c, d: placed.d,
                tx: placed.tx, ty: placed.ty
            )
        )
        CATransaction.commit()
    }

    /// Folds the lifted layer back. Called only once the composite that
    /// contains it again has landed, so there is no frame in which the layer is
    /// in neither place.
    func hideLift() {
        guard hasLift else { return }
        hasLift = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lift.isHidden = true
        lift.contents = nil
        CATransaction.commit()
    }

    // MARK: - Read only by tests

    // Debug-only, as every `…ForTesting` member is; the reasoning is at
    // `EditorSession.staticRendererForTesting`.
    #if DEBUG
    /// The layer the mirror transforms, so a test can assert registration
    /// arithmetic that no simulator can show and no eye can measure.
    var pageLayerForTesting: CALayer { page }

    /// The clipping container, so a test can assert it really is beneath the
    /// canvas in the host's sublayer order — the whole structural claim.
    var clipLayerForTesting: CALayer { clip }

    /// The lifted layer, so a test can assert the pixel-to-page composition
    /// lands where the durable transform says it does.
    var liftLayerForTesting: CALayer { lift }

    /// The lens layer, so a test can assert where a settled-zoom render
    /// landed and that invalidation genuinely emptied it.
    var lensLayerForTesting: CALayer { lens }
    #endif
}
