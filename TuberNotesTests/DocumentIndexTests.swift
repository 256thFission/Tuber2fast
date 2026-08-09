import Foundation
import Testing
@testable import TuberModel
@testable import TuberNotes
@testable import TuberStore

@Suite("Document index")
struct DocumentIndexTests {
    @Test("An index round trips through the durable encoding unchanged")
    func roundTrip() throws {
        let original = sample(
            pages: [
                PageRecord(id: UUID(), geometry: .canonical),
                PageRecord(id: UUID(), geometry: PageGeometry(width: 842, height: 595)),
                PageRecord(id: UUID(), geometry: PageGeometry(width: 595.276, height: 841.89)),
                PageRecord(id: UUID(), geometry: .canonical),
            ],
            currentPageIndex: 2
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder()
            .decode(DocumentIndex.self, from: encoder.encode(original))

        #expect(decoded == original)
        #expect(decoded.pageIDs == original.pageIDs)
        // Per page, and each page keeps its own — a mixed run survives the
        // encoding in order, which is the property that makes an imported
        // landscape page still landscape after a relaunch.
        #expect(decoded.pages.map(\.geometry) == original.pages.map(\.geometry))
        #expect(decoded.geometry(ofPageAt: 1) == PageGeometry(width: 842, height: 595))
        #expect(decoded.zoomCapPagePointsPerPixel == original.zoomCapPagePointsPerPixel)
    }

    @Test("Encoding writes the one form this build reads")
    func encodingWritesOnlyTheCurrentForm() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(
            sample(pages: [PageRecord(id: UUID(), geometry: .canonical)])
        )

        let raw = try PropertyListSerialization.propertyList(
            from: bytes,
            options: [],
            format: nil
        ) as? [String: Any]
        let keys = Set((raw ?? [:]).keys)

        #expect(keys.contains("pages"))
        #expect(keys.contains("zoomCapPagePointsPerPixel"))
        #expect((raw?["formatVersion"] as? Int) == 1)
    }

    @Test("A page file round trips unchanged")
    func pageRoundTrip() throws {
        // Since phase 3 a page file is its own ID and an ordered list of layer
        // IDs; the envelopes are one file each under `layers/`. Order is part
        // of the value — it is z-order — so the round trip has to keep it.
        let original = PageFile(
            pageID: UUID(),
            layerIDs: (0..<4).map { _ in UUID() }
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder()
            .decode(PageFile.self, from: encoder.encode(original))

        #expect(decoded == original)
        #expect(decoded.layerIDs == original.layerIDs)

        // Both halves of `Codable` are synthesized now that one form is read,
        // so the key set is exactly the two stored properties — asserted rather
        // than assumed, because nothing else here would notice a third.
        let raw = try PropertyListSerialization.propertyList(
            from: try encoder.encode(original),
            options: [],
            format: nil
        ) as? [String: Any]
        #expect(Set((raw ?? [:]).keys) == ["pageID", "layerIDs"])
    }

    /// Only version 1 opens, and every other number is refused by name — the
    /// forward compatibility that survives having no backward paths at all. A
    /// newer build's index must say "written by a newer version" rather than
    /// decode into whatever this build can make of it.
    @Test("Only the current format version validates, and the rest are refused by number")
    func rejectsUnsupportedVersion() {
        #expect(throws: Never.self) { try sample(formatVersion: 1).validated() }
        for version: UInt32 in [0, 2, 3, 4, .max] {
            #expect(throws: DocumentIndexError.unsupportedFormatVersion(version)) {
                try sample(formatVersion: version).validated()
            }
        }
    }

    @Test("A document always has at least one page")
    func rejectsEmptyPageList() {
        #expect(throws: DocumentIndexError.noPages) {
            try sample(pages: []).validated()
        }
    }

    @Test("Duplicate page IDs are rejected")
    func rejectsDuplicatePageIDs() {
        let repeated = UUID()
        #expect(throws: (any Error).self) {
            try sample(
                pages: [repeated, UUID(), repeated].map {
                    PageRecord(id: $0, geometry: .canonical)
                }
            ).validated()
        }
    }

    @Test("An out-of-range current page is rejected rather than clamped")
    func rejectsOutOfRangeCurrentPage() throws {
        let records = [UUID(), UUID()].map { PageRecord(id: $0, geometry: .canonical) }
        #expect(throws: (any Error).self) {
            try sample(pages: records, currentPageIndex: 2).validated()
        }
        #expect(throws: (any Error).self) {
            try sample(pages: records, currentPageIndex: -1).validated()
        }
        #expect(try sample(pages: records, currentPageIndex: 1).validated().currentPageIndex == 1)
    }

    /// What survives of the old geometry rule, and what does not. Finite page
    /// points greater than zero, per page — and nothing about the aspect, and
    /// nothing about equalling the canonical page.
    @Test("A page's geometry must be finite points greater than zero, and nothing more")
    func rejectsInvalidGeometry() {
        #expect(throws: (any Error).self) {
            try sample(geometry: PageGeometry(width: 612, height: 0)).validated()
        }
        #expect(throws: (any Error).self) {
            try sample(geometry: PageGeometry(width: 0, height: 792)).validated()
        }
        #expect(throws: (any Error).self) {
            try sample(geometry: PageGeometry(width: 612, height: .nan)).validated()
        }
        #expect(throws: (any Error).self) {
            try sample(geometry: PageGeometry(width: .infinity, height: 792)).validated()
        }
        #expect(throws: (any Error).self) {
            try sample(geometry: PageGeometry(width: -612, height: 792)).validated()
        }

        // Accepted, where the old rule refused all three: landscape, a size
        // other than the canonical page, and a page far taller than it is wide.
        #expect(throws: Never.self) {
            try sample(geometry: PageGeometry(width: 842, height: 595)).validated()
        }
        #expect(throws: Never.self) {
            try sample(geometry: PageGeometry(width: 595.276, height: 841.89)).validated()
        }
        #expect(throws: Never.self) {
            try sample(geometry: PageGeometry(width: 100, height: 5000)).validated()
        }
    }

    /// Mixed geometry is the normal case, so an index describing one has to
    /// validate — it is what every annotated import looks like.
    @Test("A mixed-geometry index validates")
    func mixedGeometryValidates() throws {
        let mixed = sample(
            pages: [
                PageRecord(id: UUID(), geometry: .canonical),
                PageRecord(id: UUID(), geometry: PageGeometry(width: 842, height: 595)),
                PageRecord(id: UUID(), geometry: .canonical),
            ],
            currentPageIndex: 1
        )
        #expect(throws: Never.self) { try mixed.validated() }
    }

    @Test("A zoom cap that is not a limit is rejected rather than corrected")
    func rejectsInvalidZoomCap() {
        #expect(throws: (any Error).self) { try sample(zoomCap: 0).validated() }
        #expect(throws: (any Error).self) { try sample(zoomCap: -0.025).validated() }
        #expect(throws: (any Error).self) { try sample(zoomCap: .nan).validated() }
        #expect(throws: (any Error).self) { try sample(zoomCap: .infinity).validated() }
        // A cap coarser than one pixel per page point is not a document anyone
        // could write in.
        #expect(throws: (any Error).self) { try sample(zoomCap: 2).validated() }
        #expect(throws: Never.self) { try sample(zoomCap: 1).validated() }

        // And a cap finer than `PKCanvasView` will deliver is refused at load
        // rather than opened and quietly given less. The runtime clamps
        // `maximumZoomScale` to 10, so at the 2× grid every iPad has, a
        // twentieth of a page point per pixel is the finest reachable cap.
        #expect(throws: (any Error).self) { try sample(zoomCap: 1.0 / 40.0).validated() }
        #expect(throws: Never.self) {
            try sample(zoomCap: PageProjection.finestReachablePagePointsPerPixel).validated()
        }
        #expect(PageProjection.finestReachablePagePointsPerPixel
            == DocumentIndex.canonicalZoomCapPagePointsPerPixel)
    }

    @Test("A new document is one canonical page under the pinned cap")
    func newDocumentIsOneCanonicalPage() throws {
        let pageID = UUID()
        let index = try DocumentIndex.newDocument(documentID: UUID(), pageID: pageID).validated()

        #expect(index.pages == [PageRecord(id: pageID, geometry: .canonical)])
        #expect(index.zoomCapPagePointsPerPixel
            == DocumentIndex.canonicalZoomCapPagePointsPerPixel)
        #expect(index.projection(ofPageAt: 0)?.geometry == .canonical)
        #expect(index.projection(ofPageAt: 1) == nil)
    }

    private func sample(
        formatVersion: UInt32 = DocumentIndex.currentFormatVersion,
        geometry: PageGeometry = .canonical,
        pages: [PageRecord]? = nil,
        currentPageIndex: Int = 0,
        zoomCap: Double = DocumentIndex.canonicalZoomCapPagePointsPerPixel
    ) -> DocumentIndex {
        DocumentIndex(
            formatVersion: formatVersion,
            documentID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            pages: pages ?? [
                PageRecord(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    geometry: geometry
                ),
            ],
            currentPageIndex: currentPageIndex,
            zoomCapPagePointsPerPixel: zoomCap
        )
    }
}
