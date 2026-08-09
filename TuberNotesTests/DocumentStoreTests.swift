import Foundation
import Testing
@testable import TuberModel
@testable import TuberNotes
@testable import TuberStore

@Suite("Document store")
struct DocumentStoreTests {
    @Test("No document means first launch, not an error")
    func missingDocumentLoadsNil() async throws {
        let scratch = try TestScratch("store")
        #expect(try await scratch.freshStore().load() == nil)
    }

    @Test("A returned save is reproduced exactly by the next load")
    func saveThenLoadReproducesExactly() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let index = scratch.index()
        let ink = Data((0..<4096).map { UInt8($0 % 251) })

        try await store.save(index: index, changedPages: [index.pageIDs[0]: inkLayer(ink)])

        let reopened = scratch.freshStore()
        #expect(try await reopened.load() == index)
        #expect(try await reopened.loadPage(index.pageIDs[0]).inkData == ink)
    }

    @Test("Page order survives the round trip")
    func pageOrderSurvives() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let ids = (0..<5).map { _ in UUID() }
        let index = scratch.index(pageIDs: ids, currentPageIndex: 3)

        try await store.save(
            index: index,
            changedPages: Dictionary(uniqueKeysWithValues: ids.map { ($0, inkLayer(Data([0x01]))) })
        )

        let loaded = try await scratch.freshStore().load()
        #expect(loaded?.pageIDs == ids)
        #expect(loaded?.currentPageIndex == 3)
    }

    // MARK: - Writing only what changed

    @Test("Saving one changed page leaves every other page file untouched")
    func saveTouchesOnlyChangedPages() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let ids = (0..<4).map { _ in UUID() }
        let index = scratch.index(pageIDs: ids)

        try await store.save(
            index: index,
            changedPages: Dictionary(uniqueKeysWithValues: ids.map { ($0, inkLayer(Data([0x01]))) })
        )
        // Backdated rather than waited out: an unwanted rewrite cannot hide
        // inside the filesystem's timestamp resolution when the resolution it
        // would have to hide inside is twenty-five years wide.
        try scratch.freezeTimestamps()
        try await store.save(index: index, changedPages: [ids[2]: inkLayer(Data([0x02]))])

        let after = try ids.map { try scratch.modificationDate(ofPage: $0) }
        #expect(after[0] == TestScratch.frozen)
        #expect(after[1] == TestScratch.frozen)
        #expect(after[2] != TestScratch.frozen)
        #expect(after[3] == TestScratch.frozen)
        #expect(try await scratch.freshStore().loadPage(ids[2]).inkData == Data([0x02]))
    }

    @Test("An unchanged index is not rewritten")
    func unchangedIndexIsNotRewritten() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let index = scratch.index()

        try await store.save(index: index, changedPages: [index.pageIDs[0]: inkLayer(Data([0x01]))])
        try scratch.freezeTimestamps()
        try await store.save(index: index, changedPages: [index.pageIDs[0]: inkLayer(Data([0x02]))])

        #expect(try scratch.modificationDateOfIndex() == TestScratch.frozen)
    }

    @Test("A changed index is rewritten")
    func changedIndexIsRewritten() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let first = scratch.index()

        try await store.save(index: first, changedPages: [first.pageIDs[0]: inkLayer(Data([0x01]))])
        try scratch.freezeTimestamps()
        let appended = UUID()
        let grown = first.withPages(
            first.pages + [PageRecord(id: appended, geometry: .canonical)],
            currentPageIndex: 1
        )
        try await store.save(index: grown, changedPages: [appended: inkLayer(Data([0x03]))])

        #expect(try scratch.modificationDateOfIndex() != TestScratch.frozen)
        #expect(try await scratch.freshStore().load()?.pageIDs.count == 2)
    }

    // MARK: - Refusals

    @Test("A page not named by the index is refused")
    func unreferencedPageIsRefused() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let index = scratch.index()

        await #expect(throws: (any Error).self) {
            try await store.save(index: index, changedPages: [UUID(): inkLayer(Data([0x01]))])
        }
    }

    @Test("An index naming a missing page file fails the load without mutating disk")
    func danglingPageReferenceFailsLoad() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let ids = [UUID(), UUID()]
        let index = scratch.index(pageIDs: ids)

        try await store.save(
            index: index,
            changedPages: Dictionary(uniqueKeysWithValues: ids.map { ($0, inkLayer(Data([0x01]))) })
        )
        try FileManager.default.removeItem(at: scratch.pageURL(ids[1]))
        let indexBytes = try Data(contentsOf: scratch.indexURL)

        await #expect(throws: (any Error).self) { try await scratch.freshStore().load() }
        #expect(try Data(contentsOf: scratch.indexURL) == indexBytes)
    }

    @Test("An orphaned page file is ignored rather than fatal")
    func orphanedPageFileIsIgnored() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let index = scratch.index()

        try await store.save(index: index, changedPages: [index.pageIDs[0]: inkLayer(Data([0x01]))])

        // Exactly what a crash between the page write and the index write leaves
        // behind (`Contract.md` — Durable form).
        let orphan = UUID()
        try scratch.writeRawPage(orphan, drawingData: Data([0x09]))

        #expect(try await scratch.freshStore().load() == index)
    }

    /// Phase 3b deletes the rule this test used to assert — "geometry equals
    /// the application's canonical page, with `pageWidth < pageHeight`". A page
    /// three times as tall as the canonical one is now a page, as is a
    /// landscape one, because an imported page's geometry is its source's. What
    /// is still refused is a geometry that is not a rectangle of finite points.
    @Test("A geometry that is not a page is refused rather than written")
    func invalidGeometryIsRefused() async throws {
        for geometry in [
            PageGeometry(width: PageGeometry.canonical.width, height: 0),
            PageGeometry(width: 0, height: PageGeometry.canonical.height),
            PageGeometry(width: .nan, height: PageGeometry.canonical.height),
            PageGeometry(width: PageGeometry.canonical.width, height: .infinity),
        ] {
            let scratch = try TestScratch("store")
            let store = scratch.freshStore()
            let bad = scratch.index(geometry: geometry)

            await #expect(throws: (any Error).self) {
                try await store.save(
                    index: bad,
                    changedPages: [bad.pageIDs[0]: inkLayer(Data([0x01]))]
                )
            }
            #expect(try await scratch.freshStore().load() == nil)
        }
    }

    @Test("A page taller, wider, or landscape relative to the canonical page is written")
    func unconventionalGeometryIsWritten() async throws {
        for geometry in [
            PageGeometry(width: PageGeometry.canonical.width, height: PageGeometry.canonical.height * 3),
            PageGeometry(width: 842, height: 595),
            PageGeometry(width: 595.276, height: 841.89),
        ] {
            let scratch = try TestScratch("store")
            let store = scratch.freshStore()
            let index = scratch.index(geometry: geometry)

            try await store.save(
                index: index,
                changedPages: [index.pageIDs[0]: inkLayer(Data([0x01]))]
            )

            #expect(try await scratch.freshStore().load()?.pages.first?.geometry == geometry)
        }
    }

    /// One form is written and the same one is read back. There is no second
    /// form and no migration, so the version on disk is a constant — and the
    /// assertion is against the bytes, because a decoded value would report
    /// whatever `encode(to:)` decided regardless of what landed.
    @Test("A document written and reopened round-trips at format version 1")
    func documentRoundTripsAtFormatVersionOne() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let index = scratch.index()

        try await store.save(index: index, changedPages: [index.pageIDs[0]: inkLayer(Data([0x01]))])

        #expect(try scratch.rawIndexFormatVersion() == 1)
        let reopened = try #require(try await scratch.freshStore().load())
        #expect(reopened == index)
        #expect(reopened.formatVersion == 1)
    }

    /// The half that keeps deleting the version-2 read path from reading as
    /// "version checking was deleted". Every version but the current one is
    /// refused, by name and naming the number found — a file from a newer build
    /// must say so rather than decode into whatever this build can make of it.
    @Test("An index at any other format version refuses to open, naming the number")
    func anyOtherFormatVersionRefusesToOpen() async throws {
        for version in [0, 2, 3, 4, 99] {
            let scratch = try TestScratch("store")
            let pageID = UUID()
            try scratch.createDirectories()
            try scratch.writeRawPage(pageID, drawingData: Data([0x07]))
            try scratch.writeIndexFile(scratch.index(pageIDs: [pageID]))
            try scratch.rewriteIndexFormatVersion(to: version)

            let bytesBefore = try Data(contentsOf: scratch.indexURL)
            await #expect(throws: DocumentIndexError.unsupportedFormatVersion(UInt32(version))) {
                try await scratch.freshStore().load()
            }
            #expect(try Data(contentsOf: scratch.indexURL) == bytesBefore)
        }
    }

    @Test("An out-of-range current page index is rejected rather than clamped")
    func outOfRangeCurrentPageIsRejected() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let bad = scratch.index(pageIDs: [UUID()], currentPageIndex: 4)

        await #expect(throws: (any Error).self) {
            try await store.save(index: bad, changedPages: [:])
        }
    }

    @Test("Malformed index bytes throw and leave the file untouched")
    func malformedIndexThrowsWithoutMutating() async throws {
        let scratch = try TestScratch("store")
        try scratch.createDirectories()
        let garbage = Data("not a property list".utf8)
        try garbage.write(to: scratch.indexURL)

        await #expect(throws: (any Error).self) { try await scratch.freshStore().load() }
        #expect(try Data(contentsOf: scratch.indexURL) == garbage)
    }

    @Test("A page file filed under the wrong name is refused")
    func mismatchedPageIDIsRefused() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let index = scratch.index()
        try await store.save(index: index, changedPages: [index.pageIDs[0]: inkLayer(Data([0x01]))])

        // The page file exists, so the load succeeds; reading it must not.
        try scratch.writeRawPage(index.pageIDs[0], pageID: UUID(), drawingData: Data([0x02]))
        await #expect(throws: (any Error).self) {
            try await scratch.freshStore().loadPage(index.pageIDs[0])
        }
    }

    /// One ink layer carrying `data`, as `EditorSession` would build it — the
    /// layer list a phase-1 save always writes.
    private func inkLayer(_ data: Data) -> [LayerEnvelope] {
        [
            LayerEnvelope(
                layerID: UUID(),
                kind: .ink,
                payload: data,
                pageSpaceTransform: .identity
            )
        ]
    }
}

/// The raw writes only this suite needs: a page put on disk without the store,
/// and an index in a superseded form.
private extension TestScratch {
    /// Writes a page and its one ink layer directly, bypassing the store —
    /// the only way to produce an orphan or a mis-filed page. In the current
    /// form: the page file names the layer, the layer file holds the envelope.
    func writeRawPage(_ fileName: UUID, pageID: UUID? = nil, drawingData: Data) throws {
        try createDirectories()
        let ink = LayerEnvelope(
            layerID: UUID(),
            kind: .ink,
            payload: drawingData,
            pageSpaceTransform: .identity
        )
        try writeLayerFile(ink)
        let page = PageFile(pageID: pageID ?? fileName, layerIDs: [ink.layerID])
        try TestScratch.binaryEncoder().encode(page).write(to: pageURL(fileName), options: .atomic)
    }

    /// The version stamped on the index file, read from the bytes rather than
    /// through `DocumentIndex`, whose `encode(to:)` would answer for it.
    func rawIndexFormatVersion() throws -> Int? {
        let raw = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: indexURL),
            options: [],
            format: nil
        ) as? [String: Any]
        return raw?["formatVersion"] as? Int
    }

    /// An otherwise-valid index restamped with a version this build does not
    /// write. `DocumentIndex.encode(to:)` writes the current version whatever
    /// the value says, so the only way to put another one on disk is to edit
    /// the bytes.
    func rewriteIndexFormatVersion(to version: Int) throws {
        guard var raw = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: indexURL),
            options: [.mutableContainers],
            format: nil
        ) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        raw["formatVersion"] = version
        try PropertyListSerialization
            .data(fromPropertyList: raw, format: .binary, options: 0)
            .write(to: indexURL, options: .atomic)
    }
}
