import Foundation
import Testing
@testable import TuberNotes

@Suite("Import reader")
struct ImportReaderTests {
    /// A temporary file has no security scope to end, so this shows the read
    /// is mapped and outlives the function that ends the scope; a picked
    /// document's real scope is a device check.
    @Test("A picked file is read mapped, and its bytes outlive the read")
    func importReadIsMapped() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tn-import-\(UUID().uuidString).pdf")
        let bytes = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try ImportReader.read(url: url)
        #expect(read.withUnsafeBytes { malloc_zone_from_ptr($0.baseAddress) } == nil, "the picked file was copied into the heap")
        #expect(read == bytes)
    }
}
