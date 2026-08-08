import PencilKit
import Testing
import UIKit

@testable import TuberNotes

/// Phase 2 of `Docs/Forks/CanvasFeatureComplete.md`, durable half: the asset
/// store and the `image` layer kind. These pin write-once assets, the
/// leaf-to-root write order and its root-to-leaf mirror, a dangling asset ref
/// refusing its layer while the document opens, delete-inline reclamation, and
/// the ink-last pin holding with an image present.
///
/// Nothing here renders anything. Compositing, decode, and the sibling mirror
/// are the other half of this phase.
@Suite("Image layers and the asset store")
struct ImageLayerTests {

    // MARK: - Assets are write-once and immutable

    @Test("An asset round trips, and writing its ID again is refused")
    func assetsAreWriteOnce() async throws {
        let scratch = try TestScratch("image")
        let store = scratch.freshStore()
        let assetID = UUID()
        let original = Data((0..<2048).map { UInt8($0 % 251) })

        try await store.writeAsset(original, assetID: assetID, format: .heic)
        #expect(try await store.loadAsset(assetID: assetID, format: .heic) == original)

        // There is no update entry point at all; this is the only way to try.
        await #expect(throws: AssetError.assetAlreadyExists(assetID: assetID)) {
            try await store.writeAsset(Data([0xFF]), assetID: assetID, format: .heic)
        }
        #expect(try Data(contentsOf: scratch.assetURL(assetID, "heic")) == original)

        // Write-once is per asset, not per store instance: a store that never
        // wrote this one still refuses.
        await #expect(throws: AssetError.assetAlreadyExists(assetID: assetID)) {
            try await scratch.freshStore().writeAsset(Data([0xFE]), assetID: assetID, format: .heic)
        }
        #expect(try Data(contentsOf: scratch.assetURL(assetID, "heic")) == original)
    }

    @Test("The same bytes under a new ID are a new asset, never a mutation")
    func replacingAnImageIsANewAsset() async throws {
        let scratch = try TestScratch("image")
        let store = scratch.freshStore()
        let first = UUID()
        let second = UUID()

        try await store.writeAsset(Data([0x01]), assetID: first, format: .heic)
        try await store.writeAsset(Data([0x02]), assetID: second, format: .heic)

        #expect(try await store.loadAsset(assetID: first, format: .heic) == Data([0x01]))
        #expect(try await store.loadAsset(assetID: second, format: .heic) == Data([0x02]))
    }

    // MARK: - The envelope round trip

    @Test("An image layer round trips with a non-identity transform")
    func imageLayerRoundTripsWithANonIdentityTransform() async throws {
        let scratch = try TestScratch("image")
        let store = scratch.freshStore()
        let pageID = UUID()
        let assetID = UUID()
        let layerID = UUID()
        // Rotated, scaled, and translated: nothing about it is identity, and
        // every coefficient has to survive.
        let placed = PageSpaceTransform(a: 240.5, b: 12.25, c: -8.5, d: 310.75, tx: 41, ty: 96.5)

        try await store.writeAsset(Data([0x89, 0x50, 0x4E, 0x47]), assetID: assetID, format: .heic)
        let envelope = try LayerEnvelope.image(
            layerID: layerID,
            ref: ImageLayerRef(assetID: assetID, format: .heic),
            pageSpaceTransform: placed
        )
        let documentIndex = scratch.index(pageIDs: [pageID])
        try await store.save(
            index: documentIndex,
            changedPages: [pageID: [envelope, inkEnvelope(payload: Data([0x07]))]]
        )

        let loaded = try await scratch.freshStore().loadPage(pageID)
        #expect(loaded.refusedLayers.isEmpty)
        #expect(loaded.inkData == Data([0x07]))
        #expect(loaded.staticLayers.count == 1)
        #expect(loaded.staticLayers.first?.layerID == layerID)
        #expect(loaded.staticLayers.first?.pageSpaceTransform == placed)

        let ref = try ImageLayerRef(payload: #require(loaded.staticLayers.first).payload)
        #expect(ref.assetID == assetID)
        #expect(ref.recognizedFormat == .heic)
    }

    @Test("An image layer's transform must be invertible")
    func nonInvertibleImageTransformFailsLoud() async throws {
        let scratch = try TestScratch("image")
        let assetID = UUID()
        let layerID = UUID()
        let pageID = UUID()
        try await scratch.freshStore().writeAsset(Data([0x01]), assetID: assetID, format: .heic)

        // Determinant zero: the layer collapses to a line, and no inverse maps
        // a page point back into it.
        let singular = PageSpaceTransform(a: 200, b: 100, c: 400, d: 200, tx: 0, ty: 0)
        try scratch.writePage(
            pageID,
            layers: [
                try LayerEnvelope.image(
                    layerID: layerID,
                    ref: ImageLayerRef(assetID: assetID, format: .heic),
                    pageSpaceTransform: singular
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )

        await #expect(throws: LayerError.nonInvertibleLayerTransform(layerID: layerID)) {
            _ = try await scratch.freshStore().loadPage(pageID)
        }
    }

    // MARK: - The ink-last pin, with an image present

    @Test("Ink stays last with an image layer present, on load and on save")
    func inkStaysLastWithAnImagePresent() async throws {
        let scratch = try TestScratch("image")
        let store = scratch.freshStore()
        let pageID = UUID()
        let assetID = UUID()
        try await store.writeAsset(Data([0x01]), assetID: assetID, format: .heic)
        let image = try LayerEnvelope.image(
            layerID: UUID(),
            ref: ImageLayerRef(assetID: assetID, format: .heic),
            pageSpaceTransform: .fittingSource(
                width: 100, height: 50,
                inPageOfWidth: PageGeometry.canonical.width, height: PageGeometry.canonical.height
            )
        )
        let ink = inkEnvelope(payload: Data([0x01]))

        // Buried ink is refused on the way in...
        try scratch.writePage(pageID, layers: [ink, image])
        await #expect(throws: LayerError.inkLayerNotLast(pageID: pageID)) {
            _ = try await scratch.freshStore().loadPage(pageID)
        }

        // ...and on the way out — page-scoped, so the refusal names the page.
        let documentIndex = scratch.index(pageIDs: [pageID])
        let refusal = await #expect(throws: PageSaveRefusal.self) {
            try await scratch.freshStore().save(
                index: documentIndex,
                changedPages: [pageID: [ink, image]]
            )
        }
        #expect(refusal?.refusedPages.map(\.pageID) == [pageID])
        #expect(refusal?.refusedPages.first?.reason.contains("inkLayerNotLast") == true)

        // Ink last, image beneath it: accepted.
        try await scratch.freshStore().save(
            index: documentIndex,
            changedPages: [pageID: [image, ink]]
        )
        #expect(try await scratch.freshStore().loadPage(pageID).staticLayers.count == 1)
    }

    // MARK: - Write order is leaf to root

    @Test("A page naming an asset that is not there is refused before any write")
    func aSaveNamingAMissingAssetIsRefused() async throws {
        let scratch = try TestScratch("image")
        let store = scratch.freshStore()
        let pageID = UUID()
        let assetID = UUID()
        let layerID = UUID()
        let documentIndex = scratch.index(pageIDs: [pageID])

        let envelope = try LayerEnvelope.image(
            layerID: layerID,
            ref: ImageLayerRef(assetID: assetID, format: .heic),
            pageSpaceTransform: .identity
        )
        let refusal = await #expect(throws: PageSaveRefusal.self) {
            try await store.save(
                index: documentIndex,
                changedPages: [pageID: [envelope, inkEnvelope(payload: Data([0x01]))]]
            )
        }
        #expect(refusal?.refusedPages.map(\.pageID) == [pageID])
        #expect(refusal?.refusedPages.first?.reason.contains("danglingAssetRef") == true)

        // Validation happens before any write, so nothing at all landed.
        #expect(!FileManager.default.fileExists(atPath: scratch.pageURL(pageID).path))
        #expect(try await scratch.freshStore().load() == nil)
    }

    /// The observable consequence of leaf-to-root: interrupt an import anywhere
    /// and what survives is an asset nothing references — inert — never a page
    /// file naming an asset that is not there.
    @Test("An interrupted import leaves an orphan asset, never a dangling ref")
    func anInterruptedImportLeavesAnOrphanAsset() async throws {
        let scratch = try TestScratch("image")
        let store = scratch.freshStore()
        let pageID = UUID()
        let documentIndex = scratch.index(pageIDs: [pageID])
        try await store.save(
            index: documentIndex,
            changedPages: [pageID: [inkEnvelope(payload: Data([0x01]))]]
        )

        // The leaf lands; the process dies before the page write.
        let orphan = UUID()
        try await store.writeAsset(Data([0x0A, 0x0B]), assetID: orphan, format: .heic)

        // The document opens and the page reads normally: an orphan is inert.
        let reopened = scratch.freshStore()
        #expect(try await reopened.load() == documentIndex)
        let loaded = try await reopened.loadPage(pageID)
        #expect(loaded.refusedLayers.isEmpty)
        #expect(loaded.staticLayers.isEmpty)
        #expect(FileManager.default.fileExists(atPath: scratch.assetURL(orphan, "heic").path))
    }

    @Test("A save with an image layer still touches only changed pages")
    func aSaveWithAnImageTouchesOnlyChangedPages() async throws {
        let scratch = try TestScratch("image")
        let store = scratch.freshStore()
        let withImage = UUID()
        let plain = UUID()
        let assetID = UUID()
        let documentIndex = scratch.index(pageIDs: [withImage, plain])

        try await store.writeAsset(Data([0x01]), assetID: assetID, format: .heic)
        let image = try LayerEnvelope.image(
            layerID: UUID(),
            ref: ImageLayerRef(assetID: assetID, format: .heic),
            pageSpaceTransform: .fittingSource(
                width: 640, height: 480,
                inPageOfWidth: PageGeometry.canonical.width, height: PageGeometry.canonical.height
            )
        )
        try await store.save(
            index: documentIndex,
            changedPages: [
                withImage: [image, inkEnvelope(payload: Data([0x01]))],
                plain: [inkEnvelope(payload: Data([0x02]))],
            ]
        )
        // Backdated rather than waited out: an unwanted rewrite cannot hide
        // inside a timestamp resolution it is twenty-five years away from.
        try scratch.freezeTimestamps()
        try await store.save(
            index: documentIndex,
            changedPages: [plain: [inkEnvelope(payload: Data([0x03]))]]
        )

        #expect(try scratch.modificationDate(ofPage: withImage) == TestScratch.frozen)
        #expect(try await scratch.freshStore().loadPage(withImage).staticLayers.count == 1)
    }

    // MARK: - A dangling asset ref refuses the layer, not the document

    @Test("A missing asset refuses its layer as a typed state; the document opens")
    func aMissingAssetRefusesItsLayer() async throws {
        let scratch = try TestScratch("image")
        let pageID = UUID()
        let assetID = UUID()
        let layerID = UUID()
        try scratch.writePage(
            pageID,
            layers: [
                try LayerEnvelope.image(
                    layerID: layerID,
                    ref: ImageLayerRef(assetID: assetID, format: .heic),
                    pageSpaceTransform: .identity
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )
        try scratch.writeIndexFile(scratch.index(pageIDs: [pageID]))

        let loaded = try await scratch.freshStore().loadPage(pageID)
        #expect(
            loaded.refusedLayers == [
                RefusedLayer(layerID: layerID, kind: "image", reason: .missingAsset(assetID))
            ]
        )
        // Refused, and still preservable: dropping it is the one repair, and a
        // repair the session cannot perform on a layer it was never handed.
        #expect(loaded.staticLayers.map(\.layerID) == [layerID])
        #expect(loaded.inkData == Data([0x01]))
    }

    @Test("A page with a dangling asset ref refuses input")
    @MainActor
    func aPageWithADanglingAssetRefRefusesInput() async throws {
        let scratch = try TestScratch("image")
        let pageID = UUID()
        try scratch.writePage(
            pageID,
            layers: [
                try LayerEnvelope.image(
                    layerID: UUID(),
                    ref: ImageLayerRef(assetID: UUID(), format: .heic),
                    pageSpaceTransform: .identity
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )
        try scratch.writeIndexFile(scratch.index(pageIDs: [pageID]))
        let bytesBefore = try Data(contentsOf: scratch.pageURL(pageID))

        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()

        // The refusal is the layer's: the document opens.
        #expect(session.phase == .ready)

        // The input refusal is the page's: a placeholder is built, not a canvas.
        let rootView = try #require(session.pages.view)
        rootView.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        rootView.layoutIfNeeded()
        #expect(session.pages.livePage(at: 0) == nil)
        #expect(session.currentCanvas == nil)

        // An import onto such a page is refused too, and nothing is rewritten.
        await #expect(throws: LayerEditError.pageRefusesInput(pageID)) {
            try await session.importImage(
                Data([0x01]), format: .heic, sourceWidth: 10, sourceHeight: 10
            )
        }
        await session.saveIfNeeded()
        #expect(try Data(contentsOf: scratch.pageURL(pageID)) == bytesBefore)
    }

    @Test("Deleting the broken layer repairs the page")
    @MainActor
    func deletingTheBrokenLayerRepairsThePage() async throws {
        let scratch = try TestScratch("image")
        let pageID = UUID()
        let layerID = UUID()
        try scratch.writePage(
            pageID,
            layers: [
                try LayerEnvelope.image(
                    layerID: layerID,
                    ref: ImageLayerRef(assetID: UUID(), format: .heic),
                    pageSpaceTransform: .identity
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )
        try scratch.writeIndexFile(scratch.index(pageIDs: [pageID]))

        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        try await session.deleteLayer(layerID, fromPage: pageID)

        // The page file dropped the ref, so the page opens clean now.
        let loaded = try await scratch.freshStore().loadPage(pageID)
        #expect(loaded.refusedLayers.isEmpty)
        #expect(loaded.staticLayers.isEmpty)
        #expect(loaded.inkData == Data([0x01]))
        #expect(session.lastSaveError == nil)
    }

    // MARK: - Import, end to end

    @Test("An import writes the asset, inserts the layer under the ink, and saves")
    @MainActor
    func importWritesTheAssetAndInsertsTheLayerUnderTheInk() async throws {
        let scratch = try TestScratch("image")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        let pageID = session.currentPageID

        let bytes = Data((0..<1024).map { UInt8($0 % 251) })
        let layerID = try await session.importImage(
            bytes, format: .heic, sourceWidth: 1000, sourceHeight: 500
        )
        #expect(session.lastSaveError == nil)

        let layers = try scratch.layersOnDisk(ofPage: pageID)
        #expect(layers.count == 2)
        #expect(layers[0].layerID == layerID)
        #expect(layers[0].recognizedKind == .image)
        #expect(layers[1].recognizedKind == .ink, "the ink layer is still last")

        // The transform is the placement, and it is not identity: a 2:1 source
        // fits the page's width and is centred vertically.
        let placed = layers[0].pageSpaceTransform
        #expect(!placed.isIdentity)
        #expect(placed.isInvertible)
        #expect(placed.a == PageGeometry.canonical.width)
        #expect(placed.d == PageGeometry.canonical.width / 2)
        #expect(placed.tx == 0)
        #expect(placed.ty == (PageGeometry.canonical.height - PageGeometry.canonical.width / 2) / 2)

        // The asset is where the ref says, byte for byte.
        let ref = try ImageLayerRef(payload: layers[0].payload)
        #expect(try Data(contentsOf: scratch.assetURL(ref.assetID, "heic")) == bytes)
    }

    @Test("An ordinary ink save preserves the page's image layer")
    @MainActor
    func anInkSavePreservesTheImageLayer() async throws {
        let scratch = try TestScratch("image")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        let pageID = session.currentPageID
        let layerID = try await session.importImage(
            Data([0x01, 0x02]), format: .heic, sourceWidth: 400, sourceHeight: 400
        )

        // Ink arrives afterwards and the page is written again. Without the
        // session keeping custody of the layer list, this save would write a
        // list containing only ink and silently delete the image.
        let rootView = try #require(session.pages.view)
        rootView.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        rootView.layoutIfNeeded()
        try #require(session.currentCanvas).canvasView.drawing = strokeAcrossPage()
        await session.saveIfNeeded()
        #expect(session.lastSaveError == nil)

        let loaded = try await scratch.freshStore().loadPage(pageID)
        #expect(loaded.staticLayers.map(\.layerID) == [layerID])
        #expect(!loaded.inkData.isEmpty, "the stroke was saved")
    }

    // MARK: - Delete-inline reclamation

    @Test("Deleting the last layer referencing an asset deletes the asset")
    @MainActor
    func deletingTheLastReferenceReclaimsTheAsset() async throws {
        let scratch = try TestScratch("image")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        let pageID = session.currentPageID
        let layerID = try await session.importImage(
            Data([0x01]), format: .heic, sourceWidth: 200, sourceHeight: 100
        )

        let ref = try ImageLayerRef(
            payload: try #require(scratch.layersOnDisk(ofPage: pageID).first).payload
        )
        #expect(FileManager.default.fileExists(atPath: scratch.assetURL(ref.assetID, "heic").path))

        try await session.deleteLayer(layerID, fromPage: pageID)

        // Root to leaf, now at three levels: the page file dropped the ref
        // first...
        #expect(try await scratch.freshStore().loadPage(pageID).staticLayers.isEmpty)
        // ...the layer file died second...
        #expect(!FileManager.default.fileExists(atPath: scratch.layerURL(layerID).path))
        // ...and the asset died third.
        #expect(!FileManager.default.fileExists(atPath: scratch.assetURL(ref.assetID, "heic").path))
    }

    @Test("An asset another page still references is not reclaimed")
    func aStillReferencedAssetIsNotReclaimed() async throws {
        let scratch = try TestScratch("image")
        let store = scratch.freshStore()
        let keeper = UUID()
        let assetID = UUID()
        try await store.writeAsset(Data([0x01]), assetID: assetID, format: .heic)
        try scratch.writePage(
            keeper,
            layers: [
                try LayerEnvelope.image(
                    layerID: UUID(),
                    ref: ImageLayerRef(assetID: assetID, format: .heic),
                    pageSpaceTransform: .identity
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )

        #expect(try await store.deleteAssetIfUnreferenced(assetID: assetID, format: .heic) == false)
        #expect(FileManager.default.fileExists(atPath: scratch.assetURL(assetID, "heic").path))
    }

    /// The conservative half of reclamation: a layer this build cannot open
    /// might reference anything, so nothing is reclaimed while one exists.
    /// Deleting the wrong file is a durability failure; an orphan is heavy.
    @Test("A layer this build cannot read suspends reclamation entirely")
    func anUnreadableLayerSuspendsReclamation() async throws {
        let scratch = try TestScratch("image")
        let store = scratch.freshStore()
        let assetID = UUID()
        try await store.writeAsset(Data([0x01]), assetID: assetID, format: .heic)
        try scratch.writePage(
            UUID(),
            layers: [
                LayerEnvelope(
                    layerID: UUID(),
                    rawKind: "sticker",
                    payload: Data([0xFF]),
                    pageSpaceTransform: .identity
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )

        #expect(try await store.deleteAssetIfUnreferenced(assetID: assetID, format: .heic) == false)
        #expect(FileManager.default.fileExists(atPath: scratch.assetURL(assetID, "heic").path))
    }

    // MARK: - An unknown asset format refuses the layer

    @Test("A format this build cannot decode refuses the layer, not the document")
    func anUnknownAssetFormatRefusesTheLayer() async throws {
        let scratch = try TestScratch("image")
        let pageID = UUID()
        let layerID = UUID()
        let assetID = UUID()
        // A PNG asset, which is what a build older than the narrowing to HEIC
        // wrote and this one cannot open (`Docs/Queue.md` —
        // `image-format-is-heic`). The fixture is deliberately a format that
        // once *was* legal rather than an invented future one: it is the exact
        // shape the narrowing leaves behind, and the decision that nothing in
        // production needs migrating rests on this refusing cleanly rather than
        // on the case never arising.
        let payload = try ImageLayerRef(assetID: assetID, rawFormat: "png").encodedPayload()
        try scratch.writePage(
            pageID,
            layers: [
                LayerEnvelope(
                    layerID: layerID,
                    kind: .image,
                    payload: payload,
                    pageSpaceTransform: .identity
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )
        let documentIndex = scratch.index(pageIDs: [pageID])
        try scratch.writeIndexFile(documentIndex)
        let bytesBefore = try Data(contentsOf: scratch.pageURL(pageID))

        let loaded = try await scratch.freshStore().loadPage(pageID)
        #expect(
            loaded.refusedLayers == [
                RefusedLayer(
                    layerID: layerID,
                    kind: "image",
                    reason: .unsupportedAssetFormat(assetID: assetID, format: "png")
                )
            ]
        )
        #expect(loaded.inkData == Data([0x01]))

        // This build cannot write the layer back, so it may not overwrite the
        // page at all — the same rule an unknown kind gets.
        let refusal = await #expect(throws: PageSaveRefusal.self) {
            try await scratch.freshStore().save(
                index: documentIndex,
                changedPages: [pageID: [inkEnvelope(payload: Data([0x09]))]]
            )
        }
        #expect(refusal?.refusedPages.map(\.pageID) == [pageID])
        #expect(refusal?.refusedPages.first?.reason.contains("refusedLayerWouldBeLost") == true)
        #expect(try Data(contentsOf: scratch.pageURL(pageID)) == bytesBefore)
    }

    // MARK: - A refusal is the page's, never the batch's

    /// The store's per-page refusal scope, exercised through the session: a
    /// page that cannot save — its write would drop an unknown-kind layer this
    /// build cannot rewrite — refuses loudly, and a clean page's ink in the
    /// same batch still becomes durable. Before the per-page scope, one such
    /// page made every save of the whole document throw, so no page's ink was
    /// ever durable again.
    @Test("A page that cannot drop an unknown-kind layer refuses only its own save")
    @MainActor
    func aPoisonedPageDoesNotHaltDurabilityDocumentWide() async throws {
        let scratch = try TestScratch("image")
        let inkPageID = UUID()
        let poisonedPageID = UUID()
        let unknownLayerID = UUID()
        let imageLayerID = UUID()

        try scratch.writePage(inkPageID, layers: [inkEnvelope(payload: Data())])
        try scratch.writePage(
            poisonedPageID,
            layers: [
                LayerEnvelope(
                    layerID: unknownLayerID,
                    rawKind: "hologram",
                    payload: Data([0xFF]),
                    pageSpaceTransform: .identity
                ),
                try LayerEnvelope.image(
                    layerID: imageLayerID,
                    ref: ImageLayerRef(assetID: UUID(), format: .heic),
                    pageSpaceTransform: .identity
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )
        try scratch.writeIndexFile(scratch.index(pageIDs: [inkPageID, poisonedPageID]))

        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        #expect(session.phase == .ready)

        // Deleting the missing-asset layer dirties the poisoned page's list,
        // but its save would still drop the unknown-kind layer, so the store
        // refuses that page.
        try await session.deleteLayer(imageLayerID, fromPage: poisonedPageID)
        #expect(session.lastSaveError != nil)

        // Ink on the clean page, captured in the same batch as the poisoned
        // page's unsaved list.
        let rootView = try #require(session.pages.view)
        rootView.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        rootView.layoutIfNeeded()
        try #require(session.currentCanvas).canvasView.drawing = strokeAcrossPage()
        await session.saveIfNeeded()

        // The refusal is loud and names its page...
        let surfaced = try #require(session.lastSaveError)
        #expect(surfaced.contains(poisonedPageID.uuidString))
        // ...the unknown layer was never dropped from disk...
        #expect(FileManager.default.fileExists(atPath: scratch.layerURL(unknownLayerID).path))
        // ...and the clean page's ink is durable despite its neighbour.
        let saved = try await scratch.freshStore().loadPage(inkPageID)
        #expect(try PKDrawing(data: saved.inkData).strokes.count == 1)
    }

    /// The other reachable poisoned state: two layers whose assets are
    /// missing. Deleting one still writes the other — a dangling asset ref the
    /// store refuses — so that page's save refuses while a clean page's ink
    /// still lands, and deleting the second layer is the repair.
    @Test("Two missing-asset layers refuse per page, and deleting both repairs the page")
    @MainActor
    func twoMissingAssetLayersRefusePerPageAndAreRepairable() async throws {
        let scratch = try TestScratch("image")
        let inkPageID = UUID()
        let poisonedPageID = UUID()
        let firstImageID = UUID()
        let secondImageID = UUID()

        try scratch.writePage(inkPageID, layers: [inkEnvelope(payload: Data())])
        try scratch.writePage(
            poisonedPageID,
            layers: [
                try LayerEnvelope.image(
                    layerID: firstImageID,
                    ref: ImageLayerRef(assetID: UUID(), format: .heic),
                    pageSpaceTransform: .identity
                ),
                try LayerEnvelope.image(
                    layerID: secondImageID,
                    ref: ImageLayerRef(assetID: UUID(), format: .heic),
                    pageSpaceTransform: .identity
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )
        try scratch.writeIndexFile(scratch.index(pageIDs: [inkPageID, poisonedPageID]))

        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()

        // Deleting one layer still writes the other, whose asset is missing:
        // that page refuses its save, and says so.
        try await session.deleteLayer(firstImageID, fromPage: poisonedPageID)
        let surfaced = try #require(session.lastSaveError)
        #expect(surfaced.contains(poisonedPageID.uuidString))

        // A clean page's ink still becomes durable in the same batch.
        let rootView = try #require(session.pages.view)
        rootView.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        rootView.layoutIfNeeded()
        try #require(session.currentCanvas).canvasView.drawing = strokeAcrossPage()
        await session.saveIfNeeded()
        #expect(session.lastSaveError != nil)
        let saved = try await scratch.freshStore().loadPage(inkPageID)
        #expect(try PKDrawing(data: saved.inkData).strokes.count == 1)

        // Deleting the second layer is the repair: dropping a missing-asset
        // layer is reconstructable, so the page saves cleanly again.
        try await session.deleteLayer(secondImageID, fromPage: poisonedPageID)
        await session.saveIfNeeded()
        #expect(session.lastSaveError == nil)
        let repaired = try await scratch.freshStore().loadPage(poisonedPageID)
        #expect(repaired.staticLayers.isEmpty)
        #expect(repaired.refusedLayers.isEmpty)
    }

    // MARK: - Fixtures

    private func inkEnvelope(
        layerID: UUID = UUID(),
        payload: Data
    ) -> LayerEnvelope {
        LayerEnvelope(
            layerID: layerID, kind: .ink, payload: payload, pageSpaceTransform: .identity
        )
    }

    /// One stroke, so that a page written after an import has ink that differs
    /// from the empty bytes the page was created with.
    private func strokeAcrossPage() -> PKDrawing {
        let points = [
            CGPoint(x: 100, y: 150),
            CGPoint(x: 300, y: 400),
            CGPoint(x: 500, y: 650),
        ].enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: Double(index) * 0.01,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
    }

    /// A unique directory per test, removed afterwards. A class, not a
    /// noncopyable struct, because the assertion closures above capture it.
}

/// The one fixture only this suite needs: a solid HEIC of a given size.
private extension TestScratch {
    static func solidHEIC(size: Int) -> Data {
        solidHEIC(width: size, height: size, color: UIColor.red)
    }
}
