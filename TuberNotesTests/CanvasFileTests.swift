import Foundation
import Testing

@testable import TuberNotes

@Suite("Canvas file")
struct CanvasFileTests {
    @Test("A file round trips through the durable encoding unchanged")
    func roundTrip() throws {
        let original = sampleFile()

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(original)
        let decoded = try PropertyListDecoder().decode(CanvasFile.self, from: data)

        #expect(decoded == original)
    }

    @Test("A grown height round trips and is valid")
    func grownHeightRoundTrips() throws {
        let grown = sampleFile(height: PageGeometry.initialHeight * 4)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder()
            .decode(CanvasFile.self, from: encoder.encode(grown))

        #expect(try decoded.validated() == grown)
        #expect(decoded.formatVersion == 1)
    }

    @Test("Only format version 1 is supported")
    func rejectsUnsupportedVersion() {
        let file = sampleFile(formatVersion: 2)
        #expect(throws: CanvasFileError.unsupportedFormatVersion(2)) {
            try file.validated()
        }
    }

    @Test(
        "Invalid geometry is rejected",
        arguments: [
            PageGeometry.initialHeight - 1,          // below the initial height
            PageGeometry.maximumHeight + 1,          // above the maximum
            PageGeometry.initialHeight * 1.5,        // not a whole extent
            0,
            -792,
            .infinity,
            .nan,
        ] as [Double]
    )
    func rejectsInvalidHeight(_ height: Double) {
        #expect(throws: (any Error).self) {
            try sampleFile(height: height).validated()
        }
    }

    @Test("Width must equal the canonical page width")
    func rejectsInvalidWidth() {
        #expect(throws: (any Error).self) { try sampleFile(width: 0).validated() }
        #expect(throws: (any Error).self) { try sampleFile(width: -612).validated() }
        #expect(throws: (any Error).self) { try sampleFile(width: .nan).validated() }
        #expect(throws: (any Error).self) { try sampleFile(width: 500).validated() }
        #expect(throws: (any Error).self) { try sampleFile(width: 700).validated() }
    }

    @Test("The initial and maximum heights are themselves valid")
    func boundsAreInclusive() throws {
        #expect(try sampleFile(height: PageGeometry.initialHeight).validated().pageHeight
            == PageGeometry.initialHeight)
        #expect(try sampleFile(height: PageGeometry.maximumHeight).validated().pageHeight
            == PageGeometry.maximumHeight)
    }

    private func sampleFile(
        formatVersion: UInt32 = CanvasFile.currentFormatVersion,
        width: Double = PageGeometry.width,
        height: Double = PageGeometry.initialHeight
    ) -> CanvasFile {
        CanvasFile(
            formatVersion: formatVersion,
            documentID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            pageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            pageWidth: width,
            pageHeight: height,
            drawingData: Data([0x01, 0x02, 0x03])
        )
    }
}
