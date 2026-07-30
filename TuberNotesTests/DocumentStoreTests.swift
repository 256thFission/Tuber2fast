import Foundation
import Testing

@testable import TuberNotes

@Suite("Document store")
struct DocumentStoreTests {
    @Test("No file means first launch, not an error")
    func missingFileLoadsNil() async throws {
        let scratch = try Scratch()
        let store = DocumentStore(fileURL: scratch.fileURL)

        #expect(try await store.load() == nil)
    }

    @Test("A returned save is reproduced exactly by the next load")
    func saveThenLoadReproducesExactly() async throws {
        let scratch = try Scratch()
        let store = DocumentStore(fileURL: scratch.fileURL)
        let file = scratch.file(drawingData: Data((0..<4096).map { UInt8($0 % 251) }))

        try await store.save(file)
        let loaded = try await store.load()

        #expect(loaded == file)
    }

    @Test("A grown page height is refused rather than written")
    func grownHeightIsRefused() async throws {
        let scratch = try Scratch()
        let store = DocumentStore(fileURL: scratch.fileURL)

        await #expect(throws: (any Error).self) {
            try await store.save(scratch.file(height: PageGeometry.height * 3))
        }
        #expect(try await store.load() == nil)
    }

    @Test("Each save replaces the prior file completely")
    func saveReplacesPriorFile() async throws {
        let scratch = try Scratch()
        let store = DocumentStore(fileURL: scratch.fileURL)

        try await store.save(scratch.file(drawingData: Data(repeating: 0xAA, count: 8192)))
        let second = scratch.file(drawingData: Data(repeating: 0xBB, count: 16))
        try await store.save(second)

        // A leftover tail from the larger first write would mean the replacement
        // was not atomic.
        #expect(try await store.load() == second)
        let onDisk = try Data(contentsOf: scratch.fileURL)
        #expect(!onDisk.contains(0xAA))
    }

    @Test("Malformed bytes throw and leave the source file untouched")
    func malformedFileThrowsWithoutMutating() async throws {
        let scratch = try Scratch()
        let store = DocumentStore(fileURL: scratch.fileURL)
        let garbage = Data("not a property list".utf8)
        try garbage.write(to: scratch.fileURL)

        await #expect(throws: (any Error).self) { try await store.load() }
        #expect(try Data(contentsOf: scratch.fileURL) == garbage)
    }

    @Test("An unsupported version throws and leaves the source file untouched")
    func unsupportedVersionThrowsWithoutMutating() async throws {
        let scratch = try Scratch()
        let store = DocumentStore(fileURL: scratch.fileURL)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let future = try encoder.encode(scratch.file(formatVersion: 99))
        try future.write(to: scratch.fileURL)

        await #expect(throws: (any Error).self) { try await store.load() }
        #expect(try Data(contentsOf: scratch.fileURL) == future)
    }

    @Test("An out-of-range height on disk is rejected rather than clamped")
    func invalidGeometryOnDiskIsRejected() async throws {
        let scratch = try Scratch()
        let store = DocumentStore(fileURL: scratch.fileURL)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        // Encoded directly: `save` would have refused to write this.
        let tooTall = try encoder.encode(scratch.file(height: PageGeometry.height * 2))
        try tooTall.write(to: scratch.fileURL)

        await #expect(throws: (any Error).self) { try await store.load() }
    }

    @Test("A save that would violate the contract is refused before it is written")
    func invalidSaveDoesNotTouchDisk() async throws {
        let scratch = try Scratch()
        let store = DocumentStore(fileURL: scratch.fileURL)
        let good = scratch.file()
        try await store.save(good)

        await #expect(throws: (any Error).self) {
            try await store.save(scratch.file(height: PageGeometry.height * 2))
        }
        #expect(try await store.load() == good)
    }

    /// A unique directory per test, removed afterwards. A class, not a
    /// noncopyable struct, because the assertion closures below capture it.
    private final class Scratch {
        let directory: URL
        var fileURL: URL { directory.appendingPathComponent("JustACanvas.canvas") }

        private let documentID = UUID()
        private let pageID = UUID()

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tubernotes-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        func file(
            formatVersion: UInt32 = CanvasFile.currentFormatVersion,
            height: Double = PageGeometry.height,
            drawingData: Data = Data([0x00])
        ) -> CanvasFile {
            CanvasFile(
                formatVersion: formatVersion,
                documentID: documentID,
                pageID: pageID,
                pageWidth: PageGeometry.width,
                pageHeight: height,
                drawingData: drawingData
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
