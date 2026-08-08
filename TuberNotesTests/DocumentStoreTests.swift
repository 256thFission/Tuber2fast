import Foundation
import Testing

@testable import TuberNotes

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
        let before = try ids.map { try scratch.modificationDate(ofPage: $0) }

        // Far enough apart that an unwanted rewrite cannot hide inside the
        // filesystem's timestamp resolution.
        try await Task.sleep(for: .milliseconds(1100))
        try await store.save(index: index, changedPages: [ids[2]: inkLayer(Data([0x02]))])

        let after = try ids.map { try scratch.modificationDate(ofPage: $0) }
        #expect(after[0] == before[0])
        #expect(after[1] == before[1])
        #expect(after[2] != before[2])
        #expect(after[3] == before[3])
        #expect(try await scratch.freshStore().loadPage(ids[2]).inkData == Data([0x02]))
    }

    @Test("An unchanged index is not rewritten")
    func unchangedIndexIsNotRewritten() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let index = scratch.index()

        try await store.save(index: index, changedPages: [index.pageIDs[0]: inkLayer(Data([0x01]))])
        let before = try scratch.modificationDateOfIndex()

        try await Task.sleep(for: .milliseconds(1100))
        try await store.save(index: index, changedPages: [index.pageIDs[0]: inkLayer(Data([0x02]))])

        #expect(try scratch.modificationDateOfIndex() == before)
    }

    @Test("A changed index is rewritten")
    func changedIndexIsRewritten() async throws {
        let scratch = try TestScratch("store")
        let store = scratch.freshStore()
        let first = scratch.index()

        try await store.save(index: first, changedPages: [first.pageIDs[0]: inkLayer(Data([0x01]))])
        let before = try scratch.modificationDateOfIndex()

        try await Task.sleep(for: .milliseconds(1100))
        let appended = UUID()
        let grown = first.withPages(
            first.pages + [PageRecord(id: appended, geometry: .canonical)],
            currentPageIndex: 1
        )
        try await store.save(index: grown, changedPages: [appended: inkLayer(Data([0x03]))])

        #expect(try scratch.modificationDateOfIndex() != before)
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

    /// Read both forms, write forward on the next save, never migrate eagerly —
    /// phase 1's precedent, now at the index. Opening a pre-per-page-geometry
    /// document must not touch it; the first save that follows must write it
    /// forward, whether or not anything about the document changed.
    @Test("A superseded index is read untouched and written forward by the next save")
    func supersededIndexIsWrittenForwardOnNextSave() async throws {
        let scratch = try TestScratch("store")
        let pageID = UUID()
        try scratch.createDirectories()
        try scratch.writeRawPage(pageID, drawingData: Data([0x07]))
        try scratch.writeLegacyIndex(
            pageIDs: [pageID],
            geometry: PageGeometry(width: 595, height: 842)
        )
        let before = try scratch.modificationDateOfIndex()

        let store = scratch.freshStore()
        let loaded = try #require(try await store.load())
        #expect(loaded.pages.map(\.geometry) == [PageGeometry(width: 595, height: 842)])
        // Opening migrates nothing: the file on disk is byte-for-byte what it
        // was.
        #expect(try scratch.modificationDateOfIndex() == before)
        #expect(try scratch.rawIndexKeys().contains("pageIDs"))

        try await Task.sleep(for: .milliseconds(1100))
        try await store.save(index: loaded, changedPages: [pageID: inkLayer(Data([0x08]))])

        #expect(try scratch.modificationDateOfIndex() != before)
        let keys = try scratch.rawIndexKeys()
        #expect(keys.contains("pages"))
        #expect(!keys.contains("pageIDs"))
        // And the geometry survived the migration rather than being replaced
        // with the canonical page.
        let reloaded = try #require(try await scratch.freshStore().load())
        #expect(reloaded.pages.map(\.geometry) == [PageGeometry(width: 595, height: 842)])
        #expect(!reloaded.wasReadInSupersededForm)
    }

    /// The other half of write-forward: once migrated, the index is not
    /// rewritten again by a save that changes nothing about it.
    @Test("A migrated index is not rewritten by the save after it")
    func migratedIndexIsNotRewrittenAgain() async throws {
        let scratch = try TestScratch("store")
        let pageID = UUID()
        try scratch.createDirectories()
        try scratch.writeRawPage(pageID, drawingData: Data([0x07]))
        try scratch.writeLegacyIndex(pageIDs: [pageID], geometry: .canonical)

        let store = scratch.freshStore()
        let loaded = try #require(try await store.load())
        try await store.save(index: loaded, changedPages: [pageID: inkLayer(Data([0x08]))])
        let afterMigration = try scratch.modificationDateOfIndex()

        try await Task.sleep(for: .milliseconds(1100))
        try await store.save(index: loaded, changedPages: [pageID: inkLayer(Data([0x09]))])

        #expect(try scratch.modificationDateOfIndex() == afterMigration)
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

    /// A pre-per-page-geometry index: page order and one document-wide
    /// geometry, under format version 2. The test owns the fixture type for a
    /// superseded form, exactly as `LegacyPageFile` does — `DocumentIndex`
    /// itself can only ever write the current one.
    func writeLegacyIndex(pageIDs: [UUID], geometry: PageGeometry) throws {
        try FileManager.default.createDirectory(at: documentURL, withIntermediateDirectories: true)
        let legacy: [String: Any] = [
            "formatVersion": 2,
            "documentID": documentID.uuidString,
            "pageWidth": geometry.width,
            "pageHeight": geometry.height,
            "pageIDs": pageIDs.map(\.uuidString),
            "currentPageIndex": 0,
        ]
        try PropertyListSerialization
            .data(fromPropertyList: legacy, format: .binary, options: 0)
            .write(to: indexURL, options: .atomic)
    }
}
