import Foundation
import Testing

@testable import TuberNotes

@Suite("Page geometry")
struct PageGeometryTests {
    @Test("The canonical page is a page")
    func canonicalIsAPage() {
        #expect(PageGeometry.canonical.isValid)
        #expect(PageGeometry.canonical.width == 612)
        #expect(PageGeometry.canonical.height == 792)
    }

    @Test("A geometry is valid on finite positive points in both axes")
    func validityIsFinitePositivePoints() {
        #expect(PageGeometry(width: 842, height: 595).isValid)
        #expect(PageGeometry(width: 1, height: 100_000).isValid)

        #expect(!PageGeometry(width: 0, height: 792).isValid)
        #expect(!PageGeometry(width: 612, height: 0).isValid)
        #expect(!PageGeometry(width: -612, height: 792).isValid)
        #expect(!PageGeometry(width: .nan, height: 792).isValid)
        #expect(!PageGeometry(width: 612, height: .infinity).isValid)
    }

    /// The rule phase 3b deletes. It was `pageWidth < pageHeight`, and it is
    /// gone because landscape sources exist: an 842 × 595 worksheet is a page,
    /// and the old rule is exactly why phase 3a letterboxed one into a portrait
    /// page instead of showing it.
    @Test("A landscape page is a page")
    func landscapeIsValid() {
        let landscape = PageGeometry(width: 842, height: 595)
        #expect(landscape.isValid)
        #expect(landscape.width > landscape.height)
    }

    @Test("Geometry round trips through the durable encoding unchanged")
    func roundTrip() throws {
        let original = PageGeometry(width: 842.5, height: 595.25)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder()
            .decode(PageGeometry.self, from: encoder.encode(original))
        #expect(decoded == original)
    }

    // MARK: - The absolute zoom cap

    /// The cap is stated in page points per pixel and the maximum zoom scale is
    /// derived from it, so one device pixel represents exactly that many page
    /// points at the deepest zoom.
    @Test("The zoom cap converts to a scale at which one pixel is one cap's worth of page")
    func capConvertsToAScale() {
        let projection = PageProjection(
            geometry: .canonical,
            zoomCapPagePointsPerPixel: 1.0 / 20.0
        )

        // Twenty pixels per page point at a display scale of 2 is ten view
        // points per page point.
        #expect(abs(projection.maximumZoomScale(displayScale: 2) - 10) < 1e-9)
        #expect(abs(projection.maximumZoomScale(displayScale: 3) - 20.0 / 3.0) < 1e-9)

        // The round trip the cap exists to make true: page points per pixel at
        // the ceiling is the cap, whatever the display scale.
        for displayScale in [1.0, 2.0, 3.0] {
            let scale = projection.maximumZoomScale(displayScale: displayScale)
            #expect(abs(1 / (scale * displayScale) - 1.0 / 20.0) < 1e-12)
        }
    }

    /// The measurement that bounds the cap, kept as a test so it cannot rot
    /// silently: `PKCanvasView` refuses a `maximumZoomScale` above 10, where a
    /// plain `UIScrollView` keeps whatever it is given. If a future iOS lifts
    /// it, this fails and the cap can be deepened deliberately.
    @Test("The canonical cap is reachable at every display scale a shipping iPad has")
    func canonicalCapIsReachable() {
        let projection = PageProjection.canonical
        for displayScale in [2.0, 3.0] {
            #expect(
                projection.maximumZoomScale(displayScale: displayScale)
                    <= PageProjection.runtimeMaximumZoomScale + 1e-9,
                Comment(
                    rawValue: "a cap of \(projection.zoomCapPagePointsPerPixel) needs a "
                        + "scale PKCanvasView will not accept at display scale \(displayScale)"
                )
            )
        }
    }

    /// The whole of A9: nothing about the ceiling may depend on how big the
    /// window is. Two pages of different sizes in different viewports reach the
    /// same maximum scale, where `fitWidth × 8` gave each of them a different
    /// one.
    @Test("The zoom ceiling is independent of page size and viewport")
    func ceilingIsViewportIndependent() {
        let cap = DocumentIndex.canonicalZoomCapPagePointsPerPixel
        let portrait = PageProjection(geometry: .canonical, zoomCapPagePointsPerPixel: cap)
        let landscape = PageProjection(
            geometry: PageGeometry(width: 842, height: 595),
            zoomCapPagePointsPerPixel: cap
        )

        #expect(portrait.maximumZoomScale(displayScale: 2)
            == landscape.maximumZoomScale(displayScale: 2))
    }

    /// The number, asserted so that changing it is a deliberate act rather than
    /// a silent one — and asserted against what the old cap actually delivered,
    /// which is not what its arithmetic said. `fitWidth × 8` was clamped by
    /// `PKCanvasView` to 10 on every viewport where fit-width exceeded 1.25, so
    /// the effective old ceiling was 20 pixels per page point on every iPad in
    /// portrait, and slightly less on the smallest one. Nobody loses zoom.
    @Test("The canonical cap is a twentieth of a page point per pixel")
    func canonicalCapIsPinned() {
        #expect(DocumentIndex.canonicalZoomCapPagePointsPerPixel == 1.0 / 20.0)

        let displayScale = 2.0
        for viewportWidth in [744.0, 820.0, 1024.0, 1180.0, 1366.0] {
            let oldRequested = (viewportWidth / PageGeometry.canonical.width) * 8
            let oldEffective = min(oldRequested, PageProjection.runtimeMaximumZoomScale)
            let now = PageProjection.canonical.maximumZoomScale(displayScale: displayScale)
            #expect(
                now >= oldEffective - 1e-9,
                "a \(viewportWidth)-point viewport used to reach \(oldEffective) and now reaches \(now)"
            )
        }
    }
}
