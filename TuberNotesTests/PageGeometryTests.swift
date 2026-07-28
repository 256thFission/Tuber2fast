import Testing

@testable import TuberNotes

@Suite("Page geometry")
struct PageGeometryTests {
    @Test("The page starts finite, positive, and portrait")
    func portraitStart() {
        #expect(PageGeometry.width.isFinite)
        #expect(PageGeometry.initialHeight.isFinite)
        #expect(PageGeometry.width > 0)
        #expect(PageGeometry.initialHeight > 0)
        #expect(PageGeometry.width < PageGeometry.initialHeight)
    }

    @Test("Growing only ever makes the page taller, so it stays portrait")
    func staysPortraitWhileGrowing() {
        var height = PageGeometry.initialHeight
        while let next = PageGeometry.extended(from: height) {
            #expect(next > height)
            #expect(PageGeometry.width < next)
            height = next
        }
        #expect(height == PageGeometry.maximumHeight)
    }

    @Test("Extension stops at the maximum rather than clamping")
    func extensionStopsAtMaximum() {
        #expect(PageGeometry.extended(from: PageGeometry.maximumHeight) == nil)
        #expect(PageGeometry.extended(from: PageGeometry.maximumHeight - PageGeometry.initialHeight)
            == PageGeometry.maximumHeight)
    }

    @Test("Exactly the reachable heights are valid")
    func validHeights() {
        #expect(PageGeometry.isValidHeight(PageGeometry.initialHeight))
        #expect(PageGeometry.isValidHeight(PageGeometry.maximumHeight))
        #expect(PageGeometry.isValidHeight(PageGeometry.initialHeight * 7))

        #expect(!PageGeometry.isValidHeight(PageGeometry.initialHeight - 1))
        #expect(!PageGeometry.isValidHeight(PageGeometry.maximumHeight + 1))
        #expect(!PageGeometry.isValidHeight(PageGeometry.initialHeight * 1.5))
        #expect(!PageGeometry.isValidHeight(0))
        #expect(!PageGeometry.isValidHeight(.nan))
        #expect(!PageGeometry.isValidHeight(.infinity))
    }

    @Test("The maximum is a whole number of extents from the initial height")
    func maximumIsWholeExtents() {
        #expect(PageGeometry.maximumHeight
            == PageGeometry.initialHeight * Double(PageGeometry.maximumExtents))
    }
}
