import Foundation
import Testing

@testable import TuberNotes

@Suite("Document index")
struct DocumentIndexTests {
    @Test("An index round trips through the durable encoding unchanged")
    func roundTrip() throws {
        let original = sample(pageIDs: (0..<4).map { _ in UUID() }, currentPageIndex: 2)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder()
            .decode(DocumentIndex.self, from: encoder.encode(original))

        #expect(decoded == original)
        #expect(decoded.pageIDs == original.pageIDs)
    }

    @Test("A page file round trips unchanged")
    func pageRoundTrip() throws {
        let original = PageFile(
            pageID: UUID(),
            drawingData: Data((0..<1024).map { UInt8($0 % 251) })
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder()
            .decode(PageFile.self, from: encoder.encode(original))

        #expect(decoded == original)
    }

    @Test("Only format version 2 is supported")
    func rejectsUnsupportedVersion() {
        #expect(throws: DocumentIndexError.unsupportedFormatVersion(1)) {
            try sample(formatVersion: 1).validated()
        }
        #expect(throws: DocumentIndexError.unsupportedFormatVersion(3)) {
            try sample(formatVersion: 3).validated()
        }
    }

    @Test("A document always has at least one page")
    func rejectsEmptyPageList() {
        #expect(throws: DocumentIndexError.noPages) {
            try sample(pageIDs: []).validated()
        }
    }

    @Test("Duplicate page IDs are rejected")
    func rejectsDuplicatePageIDs() {
        let repeated = UUID()
        #expect(throws: (any Error).self) {
            try sample(pageIDs: [repeated, UUID(), repeated]).validated()
        }
    }

    @Test("An out-of-range current page is rejected rather than clamped")
    func rejectsOutOfRangeCurrentPage() throws {
        let ids = [UUID(), UUID()]
        #expect(throws: (any Error).self) {
            try sample(pageIDs: ids, currentPageIndex: 2).validated()
        }
        #expect(throws: (any Error).self) {
            try sample(pageIDs: ids, currentPageIndex: -1).validated()
        }
        #expect(try sample(pageIDs: ids, currentPageIndex: 1).validated().currentPageIndex == 1)
    }

    @Test("Geometry other than the canonical page is rejected")
    func rejectsInvalidGeometry() {
        #expect(throws: (any Error).self) { try sample(pageHeight: PageGeometry.height * 2).validated() }
        #expect(throws: (any Error).self) { try sample(pageHeight: 0).validated() }
        #expect(throws: (any Error).self) { try sample(pageHeight: .nan).validated() }
        #expect(throws: (any Error).self) { try sample(pageWidth: 500).validated() }
        #expect(throws: (any Error).self) { try sample(pageWidth: .nan).validated() }
    }

    @Test("A version 1 file migrates to a one-page document preserving identity")
    func migratesFromVersionOne() throws {
        let legacy = CanvasFile(
            formatVersion: CanvasFile.currentFormatVersion,
            documentID: UUID(),
            pageID: UUID(),
            pageWidth: PageGeometry.width,
            pageHeight: PageGeometry.height,
            drawingData: Data([0x01, 0x02])
        )

        let migrated = try DocumentIndex.migrated(from: legacy).validated()

        #expect(migrated.formatVersion == 2)
        #expect(migrated.documentID == legacy.documentID)
        #expect(migrated.pageIDs == [legacy.pageID])
        #expect(migrated.currentPageIndex == 0)
    }

    private func sample(
        formatVersion: UInt32 = DocumentIndex.currentFormatVersion,
        pageWidth: Double = PageGeometry.width,
        pageHeight: Double = PageGeometry.height,
        pageIDs: [UUID]? = nil,
        currentPageIndex: Int = 0
    ) -> DocumentIndex {
        DocumentIndex(
            formatVersion: formatVersion,
            documentID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            pageIDs: pageIDs ?? [UUID(uuidString: "22222222-2222-2222-2222-222222222222")!],
            currentPageIndex: currentPageIndex
        )
    }
}
