import Testing

@testable import TuberNotes

@Suite("Page geometry")
struct PageGeometryTests {
    @Test("The page is finite, positive, and portrait")
    func portrait() {
        #expect(PageGeometry.width.isFinite)
        #expect(PageGeometry.height.isFinite)
        #expect(PageGeometry.width > 0)
        #expect(PageGeometry.height > 0)
        #expect(PageGeometry.width < PageGeometry.height)
    }

    @Test("Only the one fixed height is valid")
    func validHeights() {
        #expect(PageGeometry.isValidHeight(PageGeometry.height))

        // The heights reachable back when the page grew downward are now just
        // as invalid as any other number. This is the regression that catches a
        // file written by the extension-era build.
        #expect(!PageGeometry.isValidHeight(PageGeometry.height * 2))
        #expect(!PageGeometry.isValidHeight(PageGeometry.height * 16))

        #expect(!PageGeometry.isValidHeight(PageGeometry.height - 1))
        #expect(!PageGeometry.isValidHeight(PageGeometry.height + 1))
        #expect(!PageGeometry.isValidHeight(0))
        #expect(!PageGeometry.isValidHeight(.nan))
        #expect(!PageGeometry.isValidHeight(.infinity))
    }
}
