import Foundation

/// One page's extent, in logical page points.
///
/// Page space has its origin at the top-left; positive x points right and
/// positive y points down. These values are display-scale independent.
///
/// **Geometry is per page**, set at page creation and immutable afterward
/// (`Contract.md` — Geometry and coordinates, as amended by phase 3b): a blank
/// page gets `canonical`, an imported page gets its source's size in page
/// points. It was a global static until phase 3b, which is why so much of the
/// canvas runtime used to read it without being told anything.
///
/// The page still does not grow. Downward growth was tried and removed: a page
/// that lengthens is not the reading model Phillip wants, and room to keep
/// writing comes from turning to the next page rather than from extending this
/// one. Per-page geometry does not reopen that — it fixes a *different* size per
/// page at creation, and no owner mutates it afterwards.
///
/// `pageWidth < pageHeight` is **not** a rule any more. Landscape sources exist,
/// and after phase 3b an imported landscape worksheet is a landscape page rather
/// than a landscape picture letterboxed into a portrait page.
struct PageGeometry: Codable, Sendable, Equatable {
    let width: Double
    let height: Double

    /// What a blank page is: US Letter, in points. Every page this application
    /// creates without a source has exactly this geometry — including the blank
    /// page appended by swiping past the last page of a landscape import, which
    /// is why mixed geometry is the normal state of an annotated import rather
    /// than an edge case.
    static let canonical = PageGeometry(width: 612, height: 792)

    /// Finite page points greater than zero, in both axes. There is no third
    /// condition: the aspect is free, and equality with `canonical` is not
    /// required of anything but a page this application created itself.
    var isValid: Bool {
        width.isFinite && width > 0 && height.isFinite && height > 0
    }
}

/// The page-space facts a `PageCanvasController` is told at construction: how
/// big its page is, and how far into it the document allows zooming.
///
/// One value rather than two parameters because they are asked for together and
/// at exactly one moment — a canvas is built with them and never asks again
/// (`Contract.md` — Owners, golden rule 7: a page canvas "renders the geometry
/// it is given ... it is told, and never asks"). Threading them through the same
/// callback is also what keeps a canvas built during the first layout pass, before
/// `EditorSession.start()` has returned, from being built with a default it would
/// then keep forever.
struct PageProjection: Sendable, Equatable {
    let geometry: PageGeometry

    /// The document's absolute zoom cap, in **page points per pixel**: the
    /// fewest page points one device pixel may represent. Smaller is deeper.
    ///
    /// Durable and viewport-independent, which is the whole of A9: the cap used
    /// to be `fitWidth × 8`, a function of the viewport, so it moved with the
    /// device, the rotation, and Split View. Nothing durable may be derived
    /// from a limit that moves.
    let zoomCapPagePointsPerPixel: Double

    /// What a canvas built with no document behind it uses — a test, or a
    /// runtime hosted before a session exists.
    static let canonical = PageProjection(
        geometry: .canonical,
        zoomCapPagePointsPerPixel: DocumentIndex.canonicalZoomCapPagePointsPerPixel
    )

    /// The zoom scale — view points per page point — at which one device pixel
    /// represents exactly `zoomCapPagePointsPerPixel` page points.
    ///
    /// `displayScale` is the only viewport-ish term, and it is not a viewport
    /// term: it is the pixel grid, which is what the cap is stated against. Two
    /// devices of different sizes and the same display scale reach the same
    /// maximum scale, which is exactly what the old cap could not do.
    func maximumZoomScale(displayScale: Double) -> Double {
        precondition(
            displayScale.isFinite && displayScale > 0,
            "a display scale of \(displayScale) cannot carry a zoom cap"
        )
        return 1 / (zoomCapPagePointsPerPixel * displayScale)
    }

    /// **`PKCanvasView` refuses a `maximumZoomScale` above 10, silently.**
    /// Measured, not documented by Apple: assigning 11, 20, or 100 to a
    /// `PKCanvasView` reads back 10, while a plain `UIScrollView` keeps whatever
    /// it was given. `ZoomProbe` in this project's history is the measurement;
    /// `PageCanvasControllerTests` keeps it honest.
    ///
    /// It bounds the durable cap, which is why it is stated here rather than
    /// buried in the canvas: a document may not pin a ceiling the runtime cannot
    /// deliver, and `PageCanvasController` fails loud rather than accepting the
    /// clamp — a silently shallower zoom than the document promises is exactly
    /// the quiet correction the contract forbids.
    ///
    /// It is also why the old cap was less viewport-dependent than it looked:
    /// `fitWidth × 8` exceeds 10 whenever fit-width exceeds 1.25, which is every
    /// iPad in portrait, so most devices were already sitting on this clamp
    /// rather than on the arithmetic.
    static let runtimeMaximumZoomScale: Double = 10

    /// The coarsest pixel grid this application ships to. Every iPad is 2×; the
    /// constant exists so the durable cap can be validated against the *worst*
    /// case rather than against whichever device happens to be opening the
    /// document, which is what makes the cap a document constant rather than a
    /// device one.
    static let minimumSupportedDisplayScale: Double = 2

    /// The finest cap any document may pin: the deepest detail `PKCanvasView`
    /// will deliver on the coarsest display this application supports.
    ///
    /// A document asking for finer is refused at load rather than opened and
    /// quietly given less — a durable promise the runtime cannot keep is an
    /// invalid state, and `DocumentIndex.validated()` is where invalid durable
    /// states are named.
    static let finestReachablePagePointsPerPixel: Double =
        1 / (runtimeMaximumZoomScale * minimumSupportedDisplayScale)

    /// The widest viewport a single page is ever fitted into: the long edge of
    /// the largest iPad this application supports — the 13-inch iPad Pro, at
    /// 1032 × 1376 points.
    ///
    /// The long edge rather than the portrait width, even though
    /// `UISupportedInterfaceOrientations_iPad` is pinned to portrait
    /// (`project.yml`). The pin is one line, and a bound that silently becomes
    /// wrong when someone deletes it is a bound that fails open. Split View and
    /// Slide Over only ever make the window narrower, so nothing else raises
    /// this number.
    static let widestSupportedViewportPoints: Double = 1376

    /// The smallest a page may be, in page points, under a given zoom cap:
    /// below this the page's fit-width scale is *above* the document's own
    /// ceiling, and the page cannot be opened at all.
    ///
    /// The derivation, which is why it lives here beside the two constants it
    /// is made of. `PageCanvasController` opens a page at fit-width,
    /// `viewport / pageWidth`, and refuses to exceed `maximumZoomScale`,
    /// `1 / (cap × displayScale)`. Fit-width must not pass the ceiling:
    ///
    /// ```text
    /// viewport / pageWidth  <=  1 / (cap × displayScale)
    /// pageWidth             >=  viewport × cap × displayScale
    /// ```
    ///
    /// Taken at the worst viewport this build can present. `displayScale` is
    /// `minimumSupportedDisplayScale` — on iPad that is not merely the minimum,
    /// it is the only value, so the bound is exact rather than conservative on
    /// that axis; a coarser display already clamps the ceiling *up* to
    /// `runtimeMaximumZoomScale`, which only makes the page easier to fit.
    ///
    /// At the canonical cap of 1/20 this is `1376 × 0.05 × 2` = **137.6 points**
    /// — about 48 mm. A till receipt at 58 mm (164 pt) and a business card at
    /// 89 mm (252 pt) both clear it; a page that does not is a fragment of a
    /// source, not a page.
    ///
    /// A document with a coarser cap has a smaller ceiling and therefore needs a
    /// *wider* page, which is why this takes the cap rather than assuming the
    /// finest one. Only `EditorSession` knows a document's cap.
    static func smallestDisplayablePagePoints(zoomCapPagePointsPerPixel: Double) -> Double {
        widestSupportedViewportPoints * zoomCapPagePointsPerPixel * minimumSupportedDisplayScale
    }
}
