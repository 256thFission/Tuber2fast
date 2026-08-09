import Testing
@testable import TuberModel
@testable import TuberNotes
@testable import TuberStore
import UIKit

/// The page's durable form is an ordered layer list, one envelope per file
/// under `layers/`. These tests pin the envelope round-trip, a page file
/// naming no layers surfacing as unreadable, the layer invariants failing
/// loud, and unknown kinds refusing the layer — not the document — while the
/// page refuses input.
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
            from: TestScratch.binaryEncoder().encode(envelope)
        )
        #expect(decoded == envelope)
        #expect(decoded.recognizedKind == .ink)

        let page = PageFile(pageID: UUID(), layerIDs: [envelope.layerID])
        let decodedPage = try PropertyListDecoder().decode(
            PageFile.self,
            from: TestScratch.binaryEncoder().encode(page)
        )
        #expect(decodedPage == page)
    }

    // MARK: - A page file naming no layers is unreadable

    @Test("A page file with no layer list throws on decode rather than reading as blank")
    func pageFileWithNoLayerListThrows() async throws {
        let scratch = try TestScratch("layer")
        let pageID = UUID()
        // A page file carrying its own ID and nothing else: a truncated or
        // hand-damaged file, not an unknown kind — there is no layer to
        // refuse, so the whole page is unreadable.
        try scratch.writePageFileWithNoLayerList(pageID)
        try scratch.writeIndexFile(scratch.index(pageIDs: [pageID]))

        #expect(throws: (any Error).self) {
            try PropertyListDecoder().decode(
                PageFile.self,
                from: Data(contentsOf: scratch.pageURL(pageID))
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await scratch.freshStore().loadPage(pageID)
        }
    }

    @Test("A page whose file names no layers surfaces as unreadable and refuses ink")
    @MainActor
    func pageFileWithNoLayerListRefusesInk() async throws {
        let scratch = try TestScratch("layer")
        let pageID = UUID()
        try scratch.writePageFileWithNoLayerList(pageID)
        try scratch.writeIndexFile(scratch.index(pageIDs: [pageID]))

        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()

        // The failure is the page's, not the document's.
        #expect(session.phase == .ready)

        // Refused, never rendered as an editable blank: a placeholder is
        // built, not a canvas, so no ink can exist for a save to replace the
        // unreadable bytes with.
        let rootView = session.pages.view!
        rootView.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        rootView.layoutIfNeeded()
        #expect(session.pages.livePage(session.pageIDForTesting(at: 0)) == nil)
        #expect(session.currentCanvas == nil)
    }

    // MARK: - Invariants fail loud

    @Test("A non-identity ink transform fails loud")
    func nonIdentityInkTransformFailsLoud() async throws {
        let scratch = try TestScratch("layer")
        let pageID = UUID()
        let layerID = UUID()
        let skewed = PageSpaceTransform(a: 1, b: 0, c: 0, d: 1, tx: 5, ty: 0)
        try scratch.writePage(
            pageID,
            layers: [inkEnvelope(layerID: layerID, payload: Data([0x01]), transform: skewed)]
        )

        await #expect(throws: LayerError.nonIdentityInkTransform(layerID: layerID)) {
            _ = try await scratch.freshStore().loadPage(pageID)
        }
    }

    @Test("A page without exactly one ink layer fails loud")
    func notExactlyOneInkLayerFailsLoud() async throws {
        let scratch = try TestScratch("layer")

        let zeroInk = UUID()
        try scratch.writePage(zeroInk, layers: [])
        await #expect(throws: LayerError.notExactlyOneInkLayer(pageID: zeroInk, count: 0)) {
            _ = try await scratch.freshStore().loadPage(zeroInk)
        }

        let twoInk = UUID()
        try scratch.writePage(
            twoInk,
            layers: [inkEnvelope(payload: Data([0x01])), inkEnvelope(payload: Data([0x02]))]
        )
        await #expect(throws: LayerError.notExactlyOneInkLayer(pageID: twoInk, count: 2)) {
            _ = try await scratch.freshStore().loadPage(twoInk)
        }
    }

    @Test("An ink layer buried under another layer fails loud")
    func inkLayerNotLastFailsLoud() async throws {
        let scratch = try TestScratch("layer")
        let pageID = UUID()
        try scratch.writePage(
            pageID,
            layers: [inkEnvelope(payload: Data([0x01])), unknownEnvelope()]
        )

        await #expect(throws: LayerError.inkLayerNotLast(pageID: pageID)) {
            _ = try await scratch.freshStore().loadPage(pageID)
        }
    }

    @Test("Two layers sharing a layerID fail loud")
    func duplicateLayerIDFailsLoud() async throws {
        let scratch = try TestScratch("layer")
        let pageID = UUID()
        let shared = UUID()
        try scratch.writePage(
            pageID,
            layers: [
                unknownEnvelope(layerID: shared),
                inkEnvelope(layerID: shared, payload: Data([0x01])),
            ]
        )

        await #expect(throws: LayerError.duplicateLayerID(pageID: pageID, layerID: shared)) {
            _ = try await scratch.freshStore().loadPage(pageID)
        }
    }

    // MARK: - Unknown kinds refuse the layer, not the document

    @Test("An unknown kind refuses the layer as a typed state, and the save with it")
    func unknownKindRefusesTheLayerAndTheSave() async throws {
        let scratch = try TestScratch("layer")
        let pageID = UUID()
        let unknownID = UUID()
        let inkID = UUID()
        let ink = Data([0x01, 0x02])
        try scratch.writePage(
            pageID,
            layers: [
                unknownEnvelope(layerID: unknownID),
                inkEnvelope(layerID: inkID, payload: ink),
            ]
        )
        let documentIndex = scratch.index(pageIDs: [pageID])
        try scratch.writeIndexFile(documentIndex)

        // The layer is refused as a typed state; the page's ink still loads.
        let store = scratch.freshStore()
        let loaded = try await store.loadPage(pageID)
        #expect(
            loaded.refusedLayers == [
                RefusedLayer(layerID: unknownID, kind: "sticker", reason: .unknownKind)
            ]
        )
        #expect(loaded.inkData == ink)
        #expect(loaded.inkLayerID == inkID)

        // A save of this page would silently drop the refused layer, so the
        // store refuses the save — the chosen preservation mechanism.
        let bytesBefore = try Data(contentsOf: scratch.pageURL(pageID))
        let refusal = await #expect(throws: PageSaveRefusal.self) {
            try await store.save(
                index: documentIndex,
                changedPages: [pageID: [inkEnvelope(layerID: inkID, payload: Data([0x09]))]]
            )
        }
        #expect(refusal?.refusedPages.map(\.pageID) == [pageID])
        #expect(refusal?.refusedPages.first?.reason.contains("refusedLayerWouldBeLost") == true)
        #expect(try Data(contentsOf: scratch.pageURL(pageID)) == bytesBefore)
    }

    /// The refusal is sound by construction, not by convention: it must hold
    /// for a store that never read the page, because `save` re-reads the file
    /// it is about to replace rather than consulting a memory of its own
    /// loads. An in-memory record would pass every other test in this suite
    /// and still lose the layer here.
    @Test("A store that never loaded the page still refuses to overwrite a refused layer")
    func aFreshStoreRefusesToOverwriteARefusedLayer() async throws {
        let scratch = try TestScratch("layer")
        let pageID = UUID()
        try scratch.writePage(
            pageID,
            layers: [unknownEnvelope(), inkEnvelope(payload: Data([0x01]))]
        )
        let documentIndex = scratch.index(pageIDs: [pageID])
        try scratch.writeIndexFile(documentIndex)
        let bytesBefore = try Data(contentsOf: scratch.pageURL(pageID))

        // A second store on the same directory, with no loadPage first.
        let freshStore = scratch.freshStore()
        let refusal = await #expect(throws: PageSaveRefusal.self) {
            try await freshStore.save(
                index: documentIndex,
                changedPages: [pageID: inkLayer(Data([0x09]))]
            )
        }
        #expect(refusal?.refusedPages.map(\.pageID) == [pageID])
        #expect(refusal?.refusedPages.first?.reason.contains("refusedLayerWouldBeLost") == true)
        #expect(try Data(contentsOf: scratch.pageURL(pageID)) == bytesBefore)
    }

    @Test("A page carrying a refused layer refuses input")
    @MainActor
    func aPageCarryingARefusedLayerRefusesInput() async throws {
        let scratch = try TestScratch("layer")
        let pageID = UUID()
        try scratch.writePage(
            pageID,
            layers: [unknownEnvelope(), inkEnvelope(payload: Data([0x01]))]
        )
        try scratch.writeIndexFile(scratch.index(pageIDs: [pageID]))
        let bytesBefore = try Data(contentsOf: scratch.pageURL(pageID))

        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()

        // The refusal is the layer's: the document opens.
        #expect(session.phase == .ready)

        // The input refusal is the page's: laying out builds a placeholder,
        // never a canvas, so no ink can exist for a save to misaccount.
        let rootView = session.pages.view!
        rootView.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        rootView.layoutIfNeeded()
        #expect(session.pages.livePage(session.pageIDForTesting(at: 0)) == nil)
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

}

private extension TestScratch {
    /// A page file carrying its own ID and no layer list at all — what a
    /// truncated or hand-damaged file looks like. `PageFile` requires
    /// `layerIDs`, so decoding it must throw.
    func writePageFileWithNoLayerList(_ pageID: UUID) throws {
        let plist: [String: Any] = ["pageID": pageID.uuidString]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try data.write(to: pageURL(pageID), options: .atomic)
    }
}
