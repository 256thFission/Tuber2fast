import Testing
import UIKit

@testable import TuberNotes

/// Phase 1 of `Docs/Forks/CanvasFeatureComplete.md`: the page's durable form
/// is an ordered layer list, envelopes inlined in the page file, with `ink`
/// the only kind. These tests pin the envelope round-trip, the legacy
/// read-forward path, the layer invariants failing loud, and unknown kinds
/// refusing the layer — not the document — while the page refuses input.
@Suite("Layer envelopes")
struct LayerEnvelopeTests {

    // MARK: - The envelope round-trips through the plist codec

    @Test("An envelope round trips through the plist codec unchanged")
    func envelopeRoundTrips() throws {
        let envelope = LayerEnvelope(
            layerID: UUID(),
            kind: .ink,
            payload: Data((0..<512).map { UInt8($0 % 251) }),
            pageSpaceTransform: .identity
        )
        let decoded = try PropertyListDecoder().decode(
            LayerEnvelope.self,
            from: Scratch.binaryEncoder().encode(envelope)
        )
        #expect(decoded == envelope)
        #expect(decoded.recognizedKind == .ink)

        let page = PageFile(pageID: UUID(), layers: [envelope])
        let decodedPage = try PropertyListDecoder().decode(
            PageFile.self,
            from: Scratch.binaryEncoder().encode(page)
        )
        #expect(decodedPage == page)
    }

    // MARK: - Legacy page files read forward

    @Test("A pre-layer page file decodes as a one-ink-layer page")
    func legacyPageFileDecodesAsAOneInkLayerPage() throws {
        let ink = Data([0x0A, 0x0B, 0x0C])
        let legacy = LegacyPageFile(pageID: UUID(), drawingData: ink)
        let decoded = try PropertyListDecoder().decode(
            PageFile.self,
            from: Scratch.binaryEncoder().encode(legacy)
        )

        #expect(decoded.pageID == legacy.pageID)
        #expect(decoded.layers.count == 1)
        #expect(decoded.layers[0].recognizedKind == .ink)
        #expect(decoded.layers[0].payload == ink)
        #expect(decoded.layers[0].pageSpaceTransform.isIdentity)
    }

    @Test("A pre-layer page file loads through the store")
    func legacyPageFileLoadsThroughTheStore() async throws {
        let scratch = try Scratch()
        let pageID = UUID()
        let ink = Data([0x01, 0x02, 0x03])
        try scratch.writeLegacyPageFile(pageID, drawingData: ink)
        try scratch.writeIndexFile(scratch.index(pageIDs: [pageID]))

        let loaded = try await scratch.store().loadPage(pageID)
        #expect(loaded.inkData == ink)
        #expect(loaded.refusedLayers.isEmpty)
    }

    /// Write-forward, not eager migration: saving one page rewrites that page
    /// in the layered form and leaves the other page's legacy bytes untouched
    /// — which is also the save path still writing only changed pages.
    @Test("A save writes the layered form forward and touches only changed pages")
    func saveWritesForwardAndTouchesOnlyChangedPages() async throws {
        let scratch = try Scratch()
        let changed = UUID()
        let untouched = UUID()
        try scratch.writeLegacyPageFile(changed, drawingData: Data([0x01]))
        try scratch.writeLegacyPageFile(untouched, drawingData: Data([0x02]))
        let documentIndex = scratch.index(pageIDs: [changed, untouched])
        try scratch.writeIndexFile(documentIndex)
        let untouchedBytesBefore = try Data(contentsOf: scratch.pageURL(untouched))

        let store = scratch.store()
        _ = try await store.load()
        try await store.save(
            index: documentIndex,
            changedPages: [changed: inkLayer(Data([0x03]))]
        )

        // The changed page is now in the layered form on disk...
        let raw = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: scratch.pageURL(changed)),
            format: nil
        ) as? [String: Any]
        #expect(raw?["layers"] != nil, "the saved page was not written forward to the layered form")
        #expect(raw?["drawingData"] == nil, "the saved page still carries the pre-layer field")
        #expect(try await store.loadPage(changed).inkData == Data([0x03]))

        // ...and the unchanged page's bytes were not touched at all.
        #expect(try Data(contentsOf: scratch.pageURL(untouched)) == untouchedBytesBefore)
    }

    @Test("A corrupt pre-layer page file throws on decode rather than reading as blank")
    func corruptLegacyPageFileThrows() async throws {
        let scratch = try Scratch()
        let pageID = UUID()
        // The legacy shape with its drawing bytes missing: a truncated or
        // hand-damaged file, not an unknown kind — there is no layer to
        // refuse, so the whole page is unreadable.
        try scratch.writeCorruptLegacyPageFile(pageID)
        try scratch.writeIndexFile(scratch.index(pageIDs: [pageID]))

        #expect(throws: (any Error).self) {
            try PropertyListDecoder().decode(
                PageFile.self,
                from: Data(contentsOf: scratch.pageURL(pageID))
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await scratch.store().loadPage(pageID)
        }
    }

    @Test("A corrupt pre-layer page surfaces as unreadable and refuses ink")
    @MainActor
    func corruptLegacyPageRefusesInk() async throws {
        let scratch = try Scratch()
        let pageID = UUID()
        try scratch.writeCorruptLegacyPageFile(pageID)
        try scratch.writeIndexFile(scratch.index(pageIDs: [pageID]))

        let session = EditorSession(store: scratch.store(), debounce: .milliseconds(20))
        await session.start()

        // The failure is the page's, not the document's.
        #expect(session.phase == .ready)

        // Refused, never rendered as an editable blank: a placeholder is
        // built, not a canvas, so no ink can exist for a save to replace the
        // unreadable bytes with.
        let rootView = session.pages.view!
        rootView.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        rootView.layoutIfNeeded()
        #expect(session.pages.livePage(at: 0) == nil)
        #expect(session.currentCanvas == nil)
    }

    // MARK: - Invariants fail loud

    @Test("A non-identity ink transform fails loud")
    func nonIdentityInkTransformFailsLoud() async throws {
        let scratch = try Scratch()
        let pageID = UUID()
        let layerID = UUID()
        let skewed = PageSpaceTransform(a: 1, b: 0, c: 0, d: 1, tx: 5, ty: 0)
        try scratch.writePageFile(
            pageID,
            layers: [inkEnvelope(layerID: layerID, payload: Data([0x01]), transform: skewed)]
        )

        await #expect(throws: LayerError.nonIdentityInkTransform(layerID: layerID)) {
            _ = try await scratch.store().loadPage(pageID)
        }
    }

    @Test("A page without exactly one ink layer fails loud")
    func notExactlyOneInkLayerFailsLoud() async throws {
        let scratch = try Scratch()

        let zeroInk = UUID()
        try scratch.writePageFile(zeroInk, layers: [])
        await #expect(throws: LayerError.notExactlyOneInkLayer(pageID: zeroInk, count: 0)) {
            _ = try await scratch.store().loadPage(zeroInk)
        }

        let twoInk = UUID()
        try scratch.writePageFile(
            twoInk,
            layers: [inkEnvelope(payload: Data([0x01])), inkEnvelope(payload: Data([0x02]))]
        )
        await #expect(throws: LayerError.notExactlyOneInkLayer(pageID: twoInk, count: 2)) {
            _ = try await scratch.store().loadPage(twoInk)
        }
    }

    @Test("An ink layer buried under another layer fails loud")
    func inkLayerNotLastFailsLoud() async throws {
        let scratch = try Scratch()
        let pageID = UUID()
        try scratch.writePageFile(
            pageID,
            layers: [inkEnvelope(payload: Data([0x01])), unknownEnvelope()]
        )

        await #expect(throws: LayerError.inkLayerNotLast(pageID: pageID)) {
            _ = try await scratch.store().loadPage(pageID)
        }
    }

    @Test("Two layers sharing a layerID fail loud")
    func duplicateLayerIDFailsLoud() async throws {
        let scratch = try Scratch()
        let pageID = UUID()
        let shared = UUID()
        try scratch.writePageFile(
            pageID,
            layers: [
                unknownEnvelope(layerID: shared),
                inkEnvelope(layerID: shared, payload: Data([0x01])),
            ]
        )

        await #expect(throws: LayerError.duplicateLayerID(pageID: pageID, layerID: shared)) {
            _ = try await scratch.store().loadPage(pageID)
        }
    }

    // MARK: - Unknown kinds refuse the layer, not the document

    @Test("An unknown kind refuses the layer as a typed state, and the save with it")
    func unknownKindRefusesTheLayerAndTheSave() async throws {
        let scratch = try Scratch()
        let pageID = UUID()
        let unknownID = UUID()
        let inkID = UUID()
        let ink = Data([0x01, 0x02])
        try scratch.writePageFile(
            pageID,
            layers: [
                unknownEnvelope(layerID: unknownID),
                inkEnvelope(layerID: inkID, payload: ink),
            ]
        )
        let documentIndex = scratch.index(pageIDs: [pageID])
        try scratch.writeIndexFile(documentIndex)

        // The layer is refused as a typed state; the page's ink still loads.
        let store = scratch.store()
        let loaded = try await store.loadPage(pageID)
        #expect(loaded.refusedLayers == [RefusedLayer(layerID: unknownID, kind: "sticker")])
        #expect(loaded.inkData == ink)
        #expect(loaded.inkLayerID == inkID)

        // A save of this page would silently drop the refused layer, so the
        // store refuses the save — the chosen preservation mechanism.
        let bytesBefore = try Data(contentsOf: scratch.pageURL(pageID))
        await #expect(throws: LayerError.refusedLayerWouldBeLost(pageID: pageID)) {
            try await store.save(
                index: documentIndex,
                changedPages: [pageID: [inkEnvelope(layerID: inkID, payload: Data([0x09]))]]
            )
        }
        #expect(try Data(contentsOf: scratch.pageURL(pageID)) == bytesBefore)
    }

    /// The refusal is sound by construction, not by convention: it must hold
    /// for a store that never read the page, because `save` re-reads the file
    /// it is about to replace rather than consulting a memory of its own
    /// loads. An in-memory record would pass every other test in this suite
    /// and still lose the layer here.
    @Test("A store that never loaded the page still refuses to overwrite a refused layer")
    func aFreshStoreRefusesToOverwriteARefusedLayer() async throws {
        let scratch = try Scratch()
        let pageID = UUID()
        try scratch.writePageFile(
            pageID,
            layers: [unknownEnvelope(), inkEnvelope(payload: Data([0x01]))]
        )
        let documentIndex = scratch.index(pageIDs: [pageID])
        try scratch.writeIndexFile(documentIndex)
        let bytesBefore = try Data(contentsOf: scratch.pageURL(pageID))

        // A second store on the same directory, with no loadPage first.
        let freshStore = scratch.store()
        await #expect(throws: LayerError.refusedLayerWouldBeLost(pageID: pageID)) {
            try await freshStore.save(
                index: documentIndex,
                changedPages: [pageID: inkLayer(Data([0x09]))]
            )
        }
        #expect(try Data(contentsOf: scratch.pageURL(pageID)) == bytesBefore)
    }

    @Test("A page carrying a refused layer refuses input")
    @MainActor
    func aPageCarryingARefusedLayerRefusesInput() async throws {
        let scratch = try Scratch()
        let pageID = UUID()
        try scratch.writePageFile(
            pageID,
            layers: [unknownEnvelope(), inkEnvelope(payload: Data([0x01]))]
        )
        try scratch.writeIndexFile(scratch.index(pageIDs: [pageID]))
        let bytesBefore = try Data(contentsOf: scratch.pageURL(pageID))

        let session = EditorSession(store: scratch.store(), debounce: .milliseconds(20))
        await session.start()

        // The refusal is the layer's: the document opens.
        #expect(session.phase == .ready)

        // The input refusal is the page's: laying out builds a placeholder,
        // never a canvas, so no ink can exist for a save to misaccount.
        let rootView = session.pages.view!
        rootView.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        rootView.layoutIfNeeded()
        #expect(session.pages.livePage(at: 0) == nil)
        #expect(session.currentCanvas == nil)

        // Nothing is dirty, so nothing saves, and the refused layer's bytes
        // are never rewritten underneath the refusal.
        await session.saveIfNeeded()
        #expect(session.lastSaveError == nil)
        #expect(try Data(contentsOf: scratch.pageURL(pageID)) == bytesBefore)
    }

    // MARK: - Fixtures

    /// One ink layer carrying `data`, as `EditorSession` would build it — the
    /// layer list a phase-1 save always writes.
    private func inkLayer(_ data: Data) -> [LayerEnvelope] {
        [inkEnvelope(payload: data)]
    }

    private func inkEnvelope(
        layerID: UUID = UUID(),
        payload: Data,
        transform: PageSpaceTransform = .identity
    ) -> LayerEnvelope {
        LayerEnvelope(
            layerID: layerID, kind: .ink, payload: payload, pageSpaceTransform: transform
        )
    }

    /// An envelope of a kind this build does not recognize — what a newer
    /// build's file looks like to this one.
    private func unknownEnvelope(layerID: UUID = UUID()) -> LayerEnvelope {
        LayerEnvelope(
            layerID: layerID,
            rawKind: "sticker",
            payload: Data([0xFF]),
            pageSpaceTransform: .identity
        )
    }

    /// The pre-layer page form, byte for byte what a version-2 document wrote
    /// before phase 1: `{ pageID, drawingData }`.
    private struct LegacyPageFile: Codable {
        let pageID: UUID
        let drawingData: Data
    }

    /// A unique directory per test, removed afterwards. A class, not a
    /// noncopyable struct, because the assertion closures above capture it.
    private final class Scratch {
        let root: URL

        var documentURL: URL { root.appendingPathComponent("JustACanvas.tubernotes") }
        var pagesURL: URL { documentURL.appendingPathComponent("pages") }

        func pageURL(_ pageID: UUID) -> URL {
            pagesURL.appendingPathComponent("\(pageID.uuidString).plist")
        }

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tubernotes-layer-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: pagesURL,
                withIntermediateDirectories: true
            )
        }

        /// A fresh store each time, deliberately: it defeats any in-memory
        /// record the store keeps of its own reads and writes, so assertions
        /// about what is on disk are about disk.
        func store() -> DocumentStore {
            DocumentStore(directoryURL: documentURL)
        }

        func index(pageIDs: [UUID]) -> DocumentIndex {
            DocumentIndex(
                formatVersion: DocumentIndex.currentFormatVersion,
                documentID: UUID(),
                pageWidth: PageGeometry.width,
                pageHeight: PageGeometry.height,
                pageIDs: pageIDs,
                currentPageIndex: 0
            )
        }

        static func binaryEncoder() -> PropertyListEncoder {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return encoder
        }

        /// Writes a page file directly, bypassing the store — the only way to
        /// put on disk what the store refuses to write.
        func writePageFile(_ pageID: UUID, layers: [LayerEnvelope]) throws {
            let page = PageFile(pageID: pageID, layers: layers)
            try Self.binaryEncoder().encode(page).write(to: pageURL(pageID), options: .atomic)
        }

        func writeLegacyPageFile(_ pageID: UUID, drawingData: Data) throws {
            let legacy = LegacyPageFile(pageID: pageID, drawingData: drawingData)
            try Self.binaryEncoder().encode(legacy).write(to: pageURL(pageID), options: .atomic)
        }

        /// The legacy shape with its drawing bytes missing entirely: neither
        /// `layers` nor `drawingData`, so decoding must throw.
        func writeCorruptLegacyPageFile(_ pageID: UUID) throws {
            let plist: [String: Any] = ["pageID": pageID.uuidString]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            )
            try data.write(to: pageURL(pageID), options: .atomic)
        }

        func writeIndexFile(_ index: DocumentIndex) throws {
            try Self.binaryEncoder().encode(index).write(
                to: documentURL.appendingPathComponent("document.plist"),
                options: .atomic
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
