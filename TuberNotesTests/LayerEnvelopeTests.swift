import UIKit
import XCTest

@testable import TuberNotes

/// Phase 1 of `Docs/Forks/CanvasFeatureComplete.md`: the page's durable form
/// is an ordered layer list, envelopes inlined in the page file, with `ink`
/// the only kind. These tests pin the envelope round-trip, the legacy
/// read-forward path, the layer invariants failing loud, and unknown kinds
/// refusing the layer — not the document — while the page refuses input.
final class LayerEnvelopeTests: XCTestCase {

    // MARK: - Fixtures

    private var root: URL!
    private var documentURL: URL { root.appendingPathComponent("JustACanvas.tubernotes") }
    private var pagesURL: URL { documentURL.appendingPathComponent("pages") }
    private func pageURL(_ pageID: UUID) -> URL {
        pagesURL.appendingPathComponent("\(pageID.uuidString).plist")
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tubernotes-layer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pagesURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A fresh store each time, so assertions about disk are about disk.
    private func store() -> DocumentStore {
        DocumentStore(directoryURL: documentURL)
    }

    private func index(pageIDs: [UUID]) -> DocumentIndex {
        DocumentIndex(
            formatVersion: DocumentIndex.currentFormatVersion,
            documentID: UUID(),
            pageWidth: PageGeometry.width,
            pageHeight: PageGeometry.height,
            pageIDs: pageIDs,
            currentPageIndex: 0
        )
    }

    private func inkEnvelope(
        layerID: UUID = UUID(),
        payload: Data,
        transform: PageSpaceTransform = .identity
    ) -> LayerEnvelope {
        LayerEnvelope(
            layerID: layerID, rawKind: "ink", payload: payload, pageSpaceTransform: transform
        )
    }

    private static func binaryEncoder() -> PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }

    /// Writes a page file directly, bypassing the store — the only way to put
    /// on disk what the store refuses to write.
    private func writePageFile(_ pageID: UUID, layers: [LayerEnvelope]) throws {
        let page = PageFile(pageID: pageID, layers: layers)
        try Self.binaryEncoder().encode(page).write(to: pageURL(pageID), options: .atomic)
    }

    /// The pre-layer page form, byte for byte what a version-2 document wrote
    /// before phase 1: `{ pageID, drawingData }`.
    private struct LegacyPageFile: Codable {
        let pageID: UUID
        let drawingData: Data
    }

    private func writeLegacyPageFile(_ pageID: UUID, drawingData: Data) throws {
        let legacy = LegacyPageFile(pageID: pageID, drawingData: drawingData)
        try Self.binaryEncoder().encode(legacy).write(to: pageURL(pageID), options: .atomic)
    }

    private func writeIndexFile(_ index: DocumentIndex) throws {
        try Self.binaryEncoder().encode(index).write(
            to: documentURL.appendingPathComponent("document.plist"),
            options: .atomic
        )
    }

    // MARK: - The envelope round-trips through the plist codec

    func testEnvelopeRoundTripsThroughThePlistCodec() throws {
        let envelope = LayerEnvelope(
            layerID: UUID(),
            kind: .ink,
            payload: Data((0..<512).map { UInt8($0 % 251) }),
            pageSpaceTransform: .identity
        )
        let decoded = try PropertyListDecoder().decode(
            LayerEnvelope.self,
            from: Self.binaryEncoder().encode(envelope)
        )
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.recognizedKind, .ink)

        let page = PageFile(pageID: UUID(), layers: [envelope])
        let decodedPage = try PropertyListDecoder().decode(
            PageFile.self,
            from: Self.binaryEncoder().encode(page)
        )
        XCTAssertEqual(decodedPage, page)
    }

    // MARK: - Legacy page files read forward

    func testLegacyPageFileLoadsAsAOneInkLayerPage() throws {
        let ink = Data([0x0A, 0x0B, 0x0C])
        let legacy = LegacyPageFile(pageID: UUID(), drawingData: ink)
        let decoded = try PropertyListDecoder().decode(
            PageFile.self,
            from: Self.binaryEncoder().encode(legacy)
        )

        XCTAssertEqual(decoded.pageID, legacy.pageID)
        XCTAssertEqual(decoded.layers.count, 1)
        XCTAssertEqual(decoded.layers[0].recognizedKind, .ink)
        XCTAssertEqual(decoded.layers[0].payload, ink)
        XCTAssertTrue(decoded.layers[0].pageSpaceTransform.isIdentity)
    }

    func testLegacyPageFileLoadsThroughTheStore() async throws {
        let pageID = UUID()
        let ink = Data([0x01, 0x02, 0x03])
        try writeLegacyPageFile(pageID, drawingData: ink)
        try writeIndexFile(index(pageIDs: [pageID]))

        let loaded = try await store().loadPage(pageID)
        XCTAssertEqual(loaded.inkData, ink)
        XCTAssertTrue(loaded.refusedLayers.isEmpty)
    }

    /// Write-forward, not eager migration: saving one page rewrites that page
    /// in the layered form and leaves the other page's legacy bytes untouched
    /// — which is also the save path still writing only changed pages.
    func testSaveWritesForwardAndTouchesOnlyChangedPages() async throws {
        let changed = UUID()
        let untouched = UUID()
        try writeLegacyPageFile(changed, drawingData: Data([0x01]))
        try writeLegacyPageFile(untouched, drawingData: Data([0x02]))
        let documentIndex = index(pageIDs: [changed, untouched])
        try writeIndexFile(documentIndex)
        let untouchedBytesBefore = try Data(contentsOf: pageURL(untouched))

        let store = store()
        _ = try await store.load()
        try await store.save(
            index: documentIndex,
            changedPages: [changed: [inkEnvelope(payload: Data([0x03]))]]
        )

        // The changed page is now in the layered form on disk...
        let raw = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: pageURL(changed)),
            format: nil
        ) as? [String: Any]
        XCTAssertNotNil(raw?["layers"], "the saved page was not written forward to the layered form")
        XCTAssertNil(raw?["drawingData"], "the saved page still carries the pre-layer field")
        let reloaded = try await store.loadPage(changed)
        XCTAssertEqual(reloaded.inkData, Data([0x03]))

        // ...and the unchanged page's bytes were not touched at all.
        XCTAssertEqual(try Data(contentsOf: pageURL(untouched)), untouchedBytesBefore)
    }

    // MARK: - Invariants fail loud

    func testNonIdentityInkTransformFailsLoud() async throws {
        let pageID = UUID()
        let skewed = PageSpaceTransform(a: 1, b: 0, c: 0, d: 1, tx: 5, ty: 0)
        let layerID = UUID()
        try writePageFile(
            pageID,
            layers: [inkEnvelope(layerID: layerID, payload: Data([0x01]), transform: skewed)]
        )

        do {
            _ = try await store().loadPage(pageID)
            XCTFail("a non-identity ink transform was accepted")
        } catch let error as LayerError {
            XCTAssertEqual(error, .nonIdentityInkTransform(layerID: layerID))
        }
    }

    func testAPageWithoutExactlyOneInkLayerFailsLoud() async throws {
        let zeroInk = UUID()
        try writePageFile(zeroInk, layers: [])
        do {
            _ = try await store().loadPage(zeroInk)
            XCTFail("a page with no ink layer was accepted")
        } catch let error as LayerError {
            XCTAssertEqual(error, .notExactlyOneInkLayer(pageID: zeroInk, count: 0))
        }

        let twoInk = UUID()
        try writePageFile(
            twoInk,
            layers: [inkEnvelope(payload: Data([0x01])), inkEnvelope(payload: Data([0x02]))]
        )
        do {
            _ = try await store().loadPage(twoInk)
            XCTFail("a page with two ink layers was accepted")
        } catch let error as LayerError {
            XCTAssertEqual(error, .notExactlyOneInkLayer(pageID: twoInk, count: 2))
        }
    }

    func testAnInkLayerNotLastInTheListFailsLoud() async throws {
        let pageID = UUID()
        let unknown = LayerEnvelope(
            layerID: UUID(),
            rawKind: "sticker",
            payload: Data([0xFF]),
            pageSpaceTransform: .identity
        )
        try writePageFile(pageID, layers: [inkEnvelope(payload: Data([0x01])), unknown])

        do {
            _ = try await store().loadPage(pageID)
            XCTFail("an ink layer buried under another layer was accepted")
        } catch let error as LayerError {
            XCTAssertEqual(error, .inkLayerNotLast(pageID: pageID))
        }
    }

    // MARK: - Unknown kinds refuse the layer, not the document

    func testUnknownKindRefusesTheLayerAndTheSave() async throws {
        let pageID = UUID()
        let unknownID = UUID()
        let inkID = UUID()
        let ink = Data([0x01, 0x02])
        let unknown = LayerEnvelope(
            layerID: unknownID,
            rawKind: "sticker",
            payload: Data([0xFF]),
            pageSpaceTransform: .identity
        )
        try writePageFile(
            pageID,
            layers: [unknown, inkEnvelope(layerID: inkID, payload: ink)]
        )
        let documentIndex = index(pageIDs: [pageID])
        try writeIndexFile(documentIndex)

        // The layer is refused as a typed state; the page's ink still loads.
        let store = store()
        let loaded = try await store.loadPage(pageID)
        XCTAssertEqual(loaded.refusedLayers, [RefusedLayer(layerID: unknownID, kind: "sticker")])
        XCTAssertEqual(loaded.inkData, ink)
        XCTAssertEqual(loaded.inkLayerID, inkID)

        // A save of this page would silently drop the refused layer, so the
        // store refuses the save — the chosen preservation mechanism.
        let bytesBefore = try Data(contentsOf: pageURL(pageID))
        do {
            try await store.save(
                index: documentIndex,
                changedPages: [pageID: [inkEnvelope(layerID: inkID, payload: Data([0x09]))]]
            )
            XCTFail("a save over a refused layer was accepted")
        } catch let error as LayerError {
            XCTAssertEqual(error, .refusedLayerWouldBeLost(pageID: pageID))
        }
        XCTAssertEqual(try Data(contentsOf: pageURL(pageID)), bytesBefore)
    }

    @MainActor
    func testAPageCarryingARefusedLayerRefusesInput() async throws {
        let pageID = UUID()
        let unknown = LayerEnvelope(
            layerID: UUID(),
            rawKind: "sticker",
            payload: Data([0xFF]),
            pageSpaceTransform: .identity
        )
        try writePageFile(pageID, layers: [unknown, inkEnvelope(payload: Data([0x01]))])
        try writeIndexFile(index(pageIDs: [pageID]))
        let bytesBefore = try Data(contentsOf: pageURL(pageID))

        let session = EditorSession(store: store(), debounce: .milliseconds(20))
        await session.start()

        // The refusal is the layer's: the document opens.
        XCTAssertEqual(session.phase, .ready)

        // The input refusal is the page's: laying out builds a placeholder,
        // never a canvas, so no ink can exist for a save to misaccount.
        let rootView = session.pages.view!
        rootView.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        rootView.layoutIfNeeded()
        XCTAssertNil(session.pages.livePage(at: 0))
        XCTAssertNil(session.currentCanvas)

        // Nothing is dirty, so nothing saves, and the refused layer's bytes
        // are never rewritten underneath the refusal.
        await session.saveIfNeeded()
        XCTAssertNil(session.lastSaveError)
        XCTAssertEqual(try Data(contentsOf: pageURL(pageID)), bytesBefore)
    }
}
