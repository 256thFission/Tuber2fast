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
        #expect(!decoded.wasReadInSupersededForm)
    }

    /// Phase 1's precedent at the index: read both forms, write forward on the
    /// next save, never migrate eagerly. A version 2 index has one
    /// document-wide geometry and no cap, and every page takes them.
    @Test("A pre-per-page-geometry index reads forward, one geometry onto every page")
    func legacyIndexReadsForward() throws {
        let pageIDs = [UUID(), UUID(), UUID()]
        let legacy: [String: Any] = [
            "formatVersion": 2,
            "documentID": UUID().uuidString,
            "pageWidth": 612.0,
            "pageHeight": 792.0,
            "pageIDs": pageIDs.map(\.uuidString),
            "currentPageIndex": 1,
        ]
        let bytes = try PropertyListSerialization.data(
            fromPropertyList: legacy,
            format: .binary,
            options: 0
        )

        let decoded = try PropertyListDecoder().decode(DocumentIndex.self, from: bytes)

        #expect(decoded.pageIDs == pageIDs)
        #expect(decoded.pages.allSatisfy { $0.geometry == PageGeometry.canonical })
        #expect(decoded.currentPageIndex == 1)
        // A document written before the cap was pinned gets the application's
        // constant: nothing durable ever depended on the old viewport-derived
        // cap, which is why adopting A9 costs no migration.
        #expect(decoded.zoomCapPagePointsPerPixel
            == DocumentIndex.canonicalZoomCapPagePointsPerPixel)
        // The value is in the current form; only the *file* is superseded.
        #expect(decoded.formatVersion == DocumentIndex.currentFormatVersion)
        #expect(decoded.wasReadInSupersededForm)
        #expect(throws: Never.self) { try decoded.validated() }
    }

    /// A legacy document whose one geometry was not the canonical page keeps
    /// that geometry on every page. It is read forward, never corrected.
    @Test("A legacy index's geometry is carried, not replaced by the canonical page")
    func legacyGeometryIsCarriedNotCorrected() throws {
        let pageID = UUID()
        let legacy: [String: Any] = [
            "formatVersion": 2,
            "documentID": UUID().uuidString,
            "pageWidth": 595.0,
            "pageHeight": 842.0,
            "pageIDs": [pageID.uuidString],
            "currentPageIndex": 0,
        ]
        let bytes = try PropertyListSerialization.data(
            fromPropertyList: legacy,
            format: .binary,
            options: 0
        )

        let decoded = try PropertyListDecoder().decode(DocumentIndex.self, from: bytes)
        #expect(
            decoded.pages
                == [PageRecord(id: pageID, geometry: PageGeometry(width: 595, height: 842))]
        )
    }

    @Test("Encoding writes only the current form")
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
        // The superseded keys are never written back by any code path, which is
        // what makes write-forward a fact rather than a discipline.
        #expect(!keys.contains("pageIDs"))
        #expect(!keys.contains("pageWidth"))
        #expect(!keys.contains("pageHeight"))
        #expect((raw?["formatVersion"] as? Int) == 3)
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
        #expect(decoded.inlineLayers == nil)
    }

    @Test("Only the current format version validates")
    func rejectsUnsupportedVersion() {
        #expect(throws: DocumentIndexError.unsupportedFormatVersion(1)) {
            try sample(formatVersion: 1).validated()
        }
        // Version 2 is *read* forward and never validated as itself: an index
        // value still carrying that version was constructed rather than decoded.
        #expect(throws: DocumentIndexError.unsupportedFormatVersion(2)) {
            try sample(formatVersion: 2).validated()
        }
        #expect(throws: DocumentIndexError.unsupportedFormatVersion(4)) {
            try sample(formatVersion: 4).validated()
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
