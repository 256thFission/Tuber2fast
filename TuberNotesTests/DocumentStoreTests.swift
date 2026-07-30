import Foundation
import Testing

@testable import TuberNotes

@Suite("Document store")
struct DocumentStoreTests {
    @Test("No document means first launch, not an error")
    func missingDocumentLoadsNil() async throws {
        let scratch = try Scratch()
        #expect(try await scratch.store().load() == nil)
    }

    @Test("A returned save is reproduced exactly by the next load")
    func saveThenLoadReproducesExactly() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let index = scratch.index()
        let ink = Data((0..<4096).map { UInt8($0 % 251) })

        try await store.save(index: index, changedPages: [index.pageIDs[0]: ink])

        let reopened = scratch.store()
        #expect(try await reopened.load() == index)
        #expect(try await reopened.loadPage(index.pageIDs[0]) == ink)
    }

    @Test("Page order survives the round trip")
    func pageOrderSurvives() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let ids = (0..<5).map { _ in UUID() }
        let index = scratch.index(pageIDs: ids, currentPageIndex: 3)

        try await store.save(
            index: index,
            changedPages: Dictionary(uniqueKeysWithValues: ids.map { ($0, Data([0x01])) })
        )

        let loaded = try await scratch.store().load()
        #expect(loaded?.pageIDs == ids)
        #expect(loaded?.currentPageIndex == 3)
    }

    // MARK: - Writing only what changed

    @Test("Saving one changed page leaves every other page file untouched")
    func saveTouchesOnlyChangedPages() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let ids = (0..<4).map { _ in UUID() }
        let index = scratch.index(pageIDs: ids)

        try await store.save(
            index: index,
            changedPages: Dictionary(uniqueKeysWithValues: ids.map { ($0, Data([0x01])) })
        )
        let before = try ids.map { try scratch.modificationDate(ofPage: $0) }

        // Far enough apart that an unwanted rewrite cannot hide inside the
        // filesystem's timestamp resolution.
        try await Task.sleep(for: .milliseconds(1100))
        try await store.save(index: index, changedPages: [ids[2]: Data([0x02])])

        let after = try ids.map { try scratch.modificationDate(ofPage: $0) }
        #expect(after[0] == before[0])
        #expect(after[1] == before[1])
        #expect(after[2] != before[2])
        #expect(after[3] == before[3])
        #expect(try await scratch.store().loadPage(ids[2]) == Data([0x02]))
    }

    @Test("An unchanged index is not rewritten")
    func unchangedIndexIsNotRewritten() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let index = scratch.index()

        try await store.save(index: index, changedPages: [index.pageIDs[0]: Data([0x01])])
        let before = try scratch.modificationDateOfIndex()

        try await Task.sleep(for: .milliseconds(1100))
        try await store.save(index: index, changedPages: [index.pageIDs[0]: Data([0x02])])

        #expect(try scratch.modificationDateOfIndex() == before)
    }

    @Test("A changed index is rewritten")
    func changedIndexIsRewritten() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let first = scratch.index()

        try await store.save(index: first, changedPages: [first.pageIDs[0]: Data([0x01])])
        let before = try scratch.modificationDateOfIndex()

        try await Task.sleep(for: .milliseconds(1100))
        let appended = UUID()
        let grown = first.withPages(first.pageIDs + [appended], currentPageIndex: 1)
        try await store.save(index: grown, changedPages: [appended: Data([0x03])])

        #expect(try scratch.modificationDateOfIndex() != before)
        #expect(try await scratch.store().load()?.pageIDs.count == 2)
    }

    // MARK: - Refusals

    @Test("A page not named by the index is refused")
    func unreferencedPageIsRefused() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let index = scratch.index()

        await #expect(throws: (any Error).self) {
            try await store.save(index: index, changedPages: [UUID(): Data([0x01])])
        }
    }

    @Test("An index naming a missing page file fails the load without mutating disk")
    func danglingPageReferenceFailsLoad() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let ids = [UUID(), UUID()]
        let index = scratch.index(pageIDs: ids)

        try await store.save(
            index: index,
            changedPages: Dictionary(uniqueKeysWithValues: ids.map { ($0, Data([0x01])) })
        )
        try FileManager.default.removeItem(at: scratch.pageURL(ids[1]))
        let indexBytes = try Data(contentsOf: scratch.indexURL)

        await #expect(throws: (any Error).self) { try await scratch.store().load() }
        #expect(try Data(contentsOf: scratch.indexURL) == indexBytes)
    }

    @Test("An orphaned page file is ignored rather than fatal")
    func orphanedPageFileIsIgnored() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let index = scratch.index()

        try await store.save(index: index, changedPages: [index.pageIDs[0]: Data([0x01])])

        // Exactly what a crash between the page write and the index write leaves
        // behind (`DataContract.md` §4a).
        let orphan = UUID()
        try scratch.writeRawPage(orphan, drawingData: Data([0x09]))

        #expect(try await scratch.store().load() == index)
    }

    @Test("A grown page height is refused rather than written")
    func grownHeightIsRefused() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let tall = scratch.index(pageHeight: PageGeometry.height * 3)

        await #expect(throws: (any Error).self) {
            try await store.save(index: tall, changedPages: [tall.pageIDs[0]: Data([0x01])])
        }
        #expect(try await scratch.store().load() == nil)
    }

    @Test("An out-of-range current page index is rejected rather than clamped")
    func outOfRangeCurrentPageIsRejected() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let bad = scratch.index(pageIDs: [UUID()], currentPageIndex: 4)

        await #expect(throws: (any Error).self) {
            try await store.save(index: bad, changedPages: [:])
        }
    }

    @Test("Malformed index bytes throw and leave the file untouched")
    func malformedIndexThrowsWithoutMutating() async throws {
        let scratch = try Scratch()
        try scratch.createDirectories()
        let garbage = Data("not a property list".utf8)
        try garbage.write(to: scratch.indexURL)

        await #expect(throws: (any Error).self) { try await scratch.store().load() }
        #expect(try Data(contentsOf: scratch.indexURL) == garbage)
    }

    @Test("A page file filed under the wrong name is refused")
    func mismatchedPageIDIsRefused() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let index = scratch.index()
        try await store.save(index: index, changedPages: [index.pageIDs[0]: Data([0x01])])

        // The page file exists, so the load succeeds; reading it must not.
        try scratch.writeRawPage(index.pageIDs[0], pageID: UUID(), drawingData: Data([0x02]))
        await #expect(throws: (any Error).self) {
            try await scratch.store().loadPage(index.pageIDs[0])
        }
    }

    // MARK: - Migration

    @Test("A format version 1 file migrates preserving IDs and drawing bytes")
    func migratesVersionOneDocument() async throws {
        let scratch = try Scratch()
        let ink = Data((0..<2048).map { UInt8($0 % 253) })
        let legacy = scratch.legacyFile(drawingData: ink)
        try scratch.writeLegacy(legacy)

        let migrated = try await scratch.store().load()

        #expect(migrated?.formatVersion == 2)
        #expect(migrated?.documentID == legacy.documentID)
        #expect(migrated?.pageIDs == [legacy.pageID])
        #expect(migrated?.currentPageIndex == 0)
        #expect(try await scratch.store().loadPage(legacy.pageID) == ink)
    }

    @Test("Migration leaves the version 1 file untouched")
    func migrationDoesNotDeleteTheSource() async throws {
        let scratch = try Scratch()
        let legacy = scratch.legacyFile(drawingData: Data([0x07]))
        try scratch.writeLegacy(legacy)
        let before = try Data(contentsOf: scratch.legacyURL)

        _ = try await scratch.store().load()

        // An interrupted migration has to be a retry, not a loss, and the only
        // thing that makes it a retry is the original still being there.
        #expect(try Data(contentsOf: scratch.legacyURL) == before)
    }

    @Test("A migrated document is not migrated again")
    func migrationRunsOnce() async throws {
        let scratch = try Scratch()
        try scratch.writeLegacy(scratch.legacyFile(drawingData: Data([0x07])))

        let first = try await scratch.store().load()
        let store = scratch.store()
        let pageID = try #require(first?.pageIDs.first)
        try await store.save(index: try #require(first), changedPages: [pageID: Data([0x42])])

        // A second migration would overwrite this with the version 1 bytes.
        #expect(try await scratch.store().loadPage(pageID) == Data([0x42]))
    }

    @Test("A version 1 file with a grown height fails to migrate")
    func grownLegacyHeightFailsMigration() async throws {
        let scratch = try Scratch()
        try scratch.writeLegacy(scratch.legacyFile(height: PageGeometry.height * 2))

        await #expect(throws: (any Error).self) { try await scratch.store().load() }
    }

    /// A unique directory per test, removed afterwards. A class, not a
    /// noncopyable struct, because the assertion closures below capture it.
    private final class Scratch {
        let root: URL
        private let documentID = UUID()
        private let defaultPageID = UUID()

        var documentURL: URL { root.appendingPathComponent("JustACanvas.tubernotes") }
        var legacyURL: URL { root.appendingPathComponent("JustACanvas.canvas") }
        var indexURL: URL { documentURL.appendingPathComponent("document.plist") }
        var pagesURL: URL { documentURL.appendingPathComponent("pages") }

        func pageURL(_ pageID: UUID) -> URL {
            pagesURL.appendingPathComponent("\(pageID.uuidString).plist")
        }

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tubernotes-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        /// A fresh store each time, deliberately: it defeats the store's
        /// in-memory record of the last written index, so assertions about what
        /// is on disk are about disk.
        func store() -> DocumentStore {
            DocumentStore(directoryURL: documentURL, legacyFileURL: legacyURL)
        }

        func index(
            pageIDs: [UUID]? = nil,
            currentPageIndex: Int = 0,
            pageHeight: Double = PageGeometry.height
        ) -> DocumentIndex {
            DocumentIndex(
                formatVersion: DocumentIndex.currentFormatVersion,
                documentID: documentID,
                pageWidth: PageGeometry.width,
                pageHeight: pageHeight,
                pageIDs: pageIDs ?? [defaultPageID],
                currentPageIndex: currentPageIndex
            )
        }

        func legacyFile(
            height: Double = PageGeometry.height,
            drawingData: Data = Data([0x00])
        ) -> CanvasFile {
            CanvasFile(
                formatVersion: CanvasFile.currentFormatVersion,
                documentID: documentID,
                pageID: defaultPageID,
                pageWidth: PageGeometry.width,
                pageHeight: height,
                drawingData: drawingData
            )
        }

        func createDirectories() throws {
            try FileManager.default.createDirectory(at: pagesURL, withIntermediateDirectories: true)
        }

        func writeLegacy(_ file: CanvasFile) throws {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(file).write(to: legacyURL, options: .atomic)
        }

        /// Writes a page file directly, bypassing the store — the only way to
        /// produce an orphan or a mis-filed page.
        func writeRawPage(_ fileName: UUID, pageID: UUID? = nil, drawingData: Data) throws {
            try createDirectories()
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let page = PageFile(pageID: pageID ?? fileName, drawingData: drawingData)
            try encoder.encode(page).write(to: pageURL(fileName), options: .atomic)
        }

        func modificationDate(ofPage pageID: UUID) throws -> Date {
            try modificationDate(of: pageURL(pageID))
        }

        func modificationDateOfIndex() throws -> Date {
            try modificationDate(of: indexURL)
        }

        private func modificationDate(of url: URL) throws -> Date {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values.contentModificationDate else {
                throw CocoaError(.fileReadUnknown)
            }
            return date
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
