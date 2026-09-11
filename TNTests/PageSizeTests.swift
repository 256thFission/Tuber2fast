import Foundation
import Testing
@testable import TNEditor
@testable import TNModel

/// The creation catalogue is arithmetic over two constants per size, so
/// every rule it has is provable without a host, a package, or a notebook.
@Suite("PageSize: the creation catalogue")
struct PageSizeTests {
    @Test("Every named size has a geometry within bounds both ways, and landscape is the portrait transpose")
    func namedSizesTurnAndStayWithinBounds() throws {
        for size in PageSize.named {
            let portrait = try #require(size.geometry(.portrait), "\(size) has no portrait geometry")
            let landscape = try #require(size.geometry(.landscape), "\(size) has no landscape geometry")
            #expect(portrait.isWithinBounds)
            #expect(landscape.isWithinBounds)
            #expect(landscape == PageGeometry(width: portrait.height, height: portrait.width))
        }
        #expect(PageSize.named.count == 5)
    }

    @Test("A square is the same geometry either way")
    func squareIsItsOwnTranspose() throws {
        let portrait = try #require(PageSize.square.geometry(.portrait))
        let landscape = try #require(PageSize.square.geometry(.landscape))
        #expect(portrait == landscape)
        #expect(portrait == PageGeometry(width: 612, height: 612))
    }

    @Test("A custom size is refused edge by edge: the bounds decide, and the smallest edge is allowed")
    func customSizesAreBounded() throws {
        let smallest = try #require(
            PageSize.custom(width: PageBounds.minEdge, height: PageBounds.minEdge).geometry(.portrait))
        #expect(smallest == PageGeometry(width: PageBounds.minEdge, height: PageBounds.minEdge))
        // 137.5 is under `minEdge`, 137.6, and 4097 is over `maxEdge`.
        #expect(PageSize.custom(width: 137.5, height: 612).geometry(.portrait) == nil)
        #expect(PageSize.custom(width: 612, height: 137.5).geometry(.portrait) == nil)
        #expect(PageSize.custom(width: 4097, height: 612).geometry(.portrait) == nil)
        #expect(PageSize.custom(width: 612, height: 4097).geometry(.portrait) == nil)
    }

    @Test("A custom size is taken as typed and never transposed")
    func customSizesDoNotTurn() throws {
        let typed = PageSize.custom(width: 800, height: 600)
        let portrait = try #require(typed.geometry(.portrait))
        let landscape = try #require(typed.geometry(.landscape))
        #expect(portrait == PageGeometry(width: 800, height: 600))
        #expect(portrait == landscape)
    }
}
