import Foundation
import Testing
@testable import TuberCanvas
@testable import TuberModel
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

    // MARK: - The smallest page that can be opened at all

    /// The bound is not a taste judgement about small pages: it is exactly the
    /// width at which fit-width in the widest viewport meets the document's own
    /// zoom ceiling. One point narrower and the page opens *above* its ceiling,
    /// which is the state `PageCanvasController.establishZoomIfNeeded` traps on.
    @Test("The smallest displayable page is where fit-width meets the zoom ceiling")
    func smallestPageIsWhereFitWidthMeetsTheCeiling() {
        let cap = DocumentIndex.canonicalZoomCapPagePointsPerPixel
        let minimum = PageProjection.smallestDisplayablePagePoints(
            zoomCapPagePointsPerPixel: cap
        )
        let ceiling = PageProjection(geometry: .canonical, zoomCapPagePointsPerPixel: cap)
            .maximumZoomScale(displayScale: PageProjection.minimumSupportedDisplayScale)

        let atTheBound = PageProjection.widestSupportedViewportPoints / minimum
        #expect(abs(atTheBound - ceiling) < 1e-9)

        // A point narrower is past it; a point wider is inside it.
        #expect(PageProjection.widestSupportedViewportPoints / (minimum - 1) > ceiling)
        #expect(PageProjection.widestSupportedViewportPoints / (minimum + 1) < ceiling)
    }

    /// The number itself, pinned so that moving it is deliberate. 103.2 points
    /// is about 36 mm — narrower than any paper anyone writes on, and wider than
    /// the receipt and ticket boxes that made this a document-destroying defect.
    @Test("The smallest displayable page at the canonical cap is 103.2 points")
    func smallestPageAtTheCanonicalCapIsPinned() {
        let minimum = PageProjection.smallestDisplayablePagePoints(
            zoomCapPagePointsPerPixel: DocumentIndex.canonicalZoomCapPagePointsPerPixel
        )
        #expect(abs(minimum - 103.2) < 1e-9)
        #expect(PageGeometry.canonical.width > minimum)
    }

    /// `widestSupportedViewportPoints` is the largest iPad's **portrait** width,
    /// which is only the widest viewport while the target is pinned to portrait.
    /// The constant cannot see `project.yml`, so this test does — unpin the
    /// orientation and the bound silently becomes a third too small, which is
    /// the trap coming back for pages between 103.2 and 137.6 points.
    ///
    /// It reads the file rather than `Bundle.main`, because the pin has to be
    /// legible in the one project source (`AGENTS.md` — Build) rather than in a
    /// generated artifact.
    @Test("The widest-viewport constant is only correct while project.yml pins portrait")
    func widestViewportAssumesThePortraitPin() throws {
        let project = try String(
            contentsOf: ContractStructureTests.repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let key = "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad:"
        let setting = project.split(separator: "\n").first { $0.contains(key) }
        let line = try #require(
            setting,
            """
            project.yml no longer sets the iPad orientations key. \
            PageProjection.widestSupportedViewportPoints assumes portrait and cannot see \
            this file, so the assumption has to be checked here or nowhere.
            """
        )
        let value = line.split(separator: ":").dropFirst().joined(separator: ":")
            .trimmingCharacters(in: CharacterSet.whitespaces)
        #expect(
            value == "UIInterfaceOrientationPortrait",
            """
            project.yml now allows \(value). A landscape iPad presents a page across the \
            long edge, so PageProjection.widestSupportedViewportPoints must become 1376 — \
            and until it does, a page between 103.2 and 137.6 points imports and then traps \
            in PageCanvasController.establishZoomIfNeeded.
            """
        )
    }

    /// A coarser cap has a shallower ceiling, so it needs a *wider* page — which
    /// is why the bound takes the cap rather than assuming the finest one.
    @Test("A coarser zoom cap demands a wider page")
    func aCoarserCapDemandsAWiderPage() {
        let finest = PageProjection.smallestDisplayablePagePoints(
            zoomCapPagePointsPerPixel: PageProjection.finestReachablePagePointsPerPixel
        )
        let coarser = PageProjection.smallestDisplayablePagePoints(
            zoomCapPagePointsPerPixel: PageProjection.finestReachablePagePointsPerPixel * 2
        )
        #expect(coarser == finest * 2)
    }
}
