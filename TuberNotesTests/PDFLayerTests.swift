import PencilKit
import Testing
import UIKit

@testable import TuberNotes

/// Phase 3 of `Docs/Forks/CanvasFeatureComplete.md`, durable half: the `pdf`
/// layer kind, and `layers/` splitting out of the page file.
///
/// The last test in this file is the phase's **exit test** and the reason the
/// split lands at phase 3 rather than phase 1: with a heavy asset on the page,
/// "annotating page 4 of a large import writes one small file, never the pdf
/// envelope, never the asset" stops being a slogan and becomes an assertion
/// about mtimes and bytes.
///
/// Nothing here renders a PDF. Base-and-lens rendering, prefetch decode, and
/// per-page geometry are other lanes.
@Suite("PDF layers and the layer split")
struct PDFLayerTests {

    // MARK: - The pdf kind

    @Test("A pdf layer round trips: asset, source page, and placement")
    func pdfLayerRoundTrips() async throws {
        let scratch = try TestScratch("pdf")
        let store = scratch.freshStore()
        let pageID = UUID()
        let assetID = UUID()
        let layerID = UUID()
        let placed = PageSpaceTransform(a: 612, b: 0, c: 0, d: 792, tx: 12, ty: 30)

        try await store.writeAsset(onePageFixture(), assetID: assetID, format: .pdf)
        let envelope = try LayerEnvelope.pdf(
            layerID: layerID,
            ref: PDFLayerRef(assetID: assetID, sourcePageIndex: 7),
            pageSpaceTransform: placed
        )
        try await store.save(
            index: scratch.index(pageIDs: [pageID]),
            changedPages: [pageID: [envelope, inkEnvelope(payload: Data([0x07]))]]
        )

        let loaded = try await scratch.freshStore().loadPage(pageID)
        #expect(loaded.refusedLayers.isEmpty)
        #expect(loaded.staticLayers.count == 1)
        let static0 = try #require(loaded.staticLayers.first)
        #expect(static0.recognizedKind == .pdf)
        #expect(static0.pageSpaceTransform == placed)

        let ref = try PDFLayerRef(payload: static0.payload)
        #expect(ref.assetID == assetID)
        #expect(ref.sourcePageIndex == 7)
    }

    /// The decision this phase turned on, pinned as behaviour rather than left
    /// in a comment: a `pdf` layer's payload carries **no source size**, and its
    /// transform is the source page's unit square mapped into page space —
    /// exactly the convention an `image` layer uses.
    @Test("A pdf payload carries no source size, only the ref and the page index")
    func pdfPayloadCarriesNoSourceSize() throws {
        let ref = PDFLayerRef(assetID: UUID(), sourcePageIndex: 3)
        let fields = try PropertyListSerialization.propertyList(
            from: try ref.encodedPayload(),
            format: nil
        ) as? [String: Any]

        #expect(Set(try #require(fields).keys) == ["assetID", "sourcePageIndex"])
    }

    @Test("A pdf layer's transform must be invertible")
    func nonInvertiblePDFTransformFailsLoud() async throws {
        let scratch = try TestScratch("pdf")
        let assetID = UUID()
        let layerID = UUID()
        let pageID = UUID()
        try await scratch.freshStore().writeAsset(onePageFixture(), assetID: assetID, format: .pdf)

        let singular = PageSpaceTransform(a: 200, b: 100, c: 400, d: 200, tx: 0, ty: 0)
        try scratch.writePage(
            pageID,
            layers: [
                try LayerEnvelope.pdf(
                    layerID: layerID,
                    ref: PDFLayerRef(assetID: assetID, sourcePageIndex: 0),
                    pageSpaceTransform: singular
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )

        await #expect(throws: LayerError.nonInvertibleLayerTransform(layerID: layerID)) {
            _ = try await scratch.freshStore().loadPage(pageID)
        }
    }

    @Test("A negative source page index is an invalid state, not a clamp")
    func negativeSourcePageIndexFailsLoud() async throws {
        let scratch = try TestScratch("pdf")
        let assetID = UUID()
        let layerID = UUID()
        let pageID = UUID()
        try await scratch.freshStore().writeAsset(onePageFixture(), assetID: assetID, format: .pdf)

        try scratch.writePage(
            pageID,
            layers: [
                try LayerEnvelope.pdf(
                    layerID: layerID,
                    ref: PDFLayerRef(assetID: assetID, sourcePageIndex: -1),
                    pageSpaceTransform: .identity
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )

        await #expect(
            throws: LayerError.negativeSourcePageIndex(layerID: layerID, index: -1)
        ) {
            _ = try await scratch.freshStore().loadPage(pageID)
        }
    }

    @Test("A pdf layer whose asset is missing refuses the layer, and the document opens")
    func aMissingPDFAssetRefusesTheLayerOnly() async throws {
        let scratch = try TestScratch("pdf")
        let missing = UUID()
        let layerID = UUID()
        let pageID = UUID()

        try scratch.writePage(
            pageID,
            layers: [
                try LayerEnvelope.pdf(
                    layerID: layerID,
                    ref: PDFLayerRef(assetID: missing, sourcePageIndex: 0),
                    pageSpaceTransform: .identity
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )
        try scratch.writeIndexFile(scratch.index(pageIDs: [pageID]))

        // The document opens, and the page loads: the refusal is the layer's.
        let loaded = try await scratch.freshStore().loadPage(pageID)
        #expect(loaded.refusedLayers.map(\.reason) == [.missingAsset(missing)])
        #expect(loaded.inkData == Data([0x01]))
        // Preserved as well as refused: dropping it is the one repair, and a
        // repair is a save, so the envelope has to survive to be written back.
        #expect(loaded.staticLayers.map(\.layerID) == [layerID])
    }

    @Test("A pdf layer whose payload will not decode refuses the layer")
    func anUnreadablePDFPayloadRefusesTheLayer() async throws {
        let scratch = try TestScratch("pdf")
        let layerID = UUID()
        let pageID = UUID()

        try scratch.writePage(
            pageID,
            layers: [
                LayerEnvelope(
                    layerID: layerID,
                    kind: .pdf,
                    payload: Data("not a property list".utf8),
                    pageSpaceTransform: .identity
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )

        let loaded = try await scratch.freshStore().loadPage(pageID)
        #expect(loaded.refusedLayers.map(\.reason) == [.unreadablePayload])
    }

    /// A `pdf` asset is not a bitmap. An `image` layer naming one is the same
    /// invalid state as one naming an encoding this build has no decoder for,
    /// and takes the same refusal rather than being handed to an image decoder.
    @Test("An image layer may not name a pdf asset")
    func anImageLayerMayNotNameAPDFAsset() async throws {
        let scratch = try TestScratch("pdf")
        let assetID = UUID()
        let layerID = UUID()
        let pageID = UUID()
        try await scratch.freshStore().writeAsset(onePageFixture(), assetID: assetID, format: .pdf)

        try scratch.writePage(
            pageID,
            layers: [
                LayerEnvelope(
                    layerID: layerID,
                    kind: .image,
                    payload: try ImageLayerRef(assetID: assetID, rawFormat: "pdf")
                        .encodedPayload(),
                    pageSpaceTransform: .identity
                ),
                inkEnvelope(payload: Data([0x01])),
            ]
        )

        let loaded = try await scratch.freshStore().loadPage(pageID)
        #expect(
            loaded.refusedLayers.map(\.reason)
                == [.unsupportedAssetFormat(assetID: assetID, format: "pdf")]
        )
    }

    @Test("A pdf asset is never rewritten: writing its ID again is refused")
    func pdfAssetsAreWriteOnce() async throws {
        let scratch = try TestScratch("pdf")
        let store = scratch.freshStore()
        let assetID = UUID()
        let original = onePageFixture()

        try await store.writeAsset(original, assetID: assetID, format: .pdf)
        await #expect(throws: AssetError.assetAlreadyExists(assetID: assetID)) {
            try await store.writeAsset(twoPageFixture(), assetID: assetID, format: .pdf)
        }
        #expect(try Data(contentsOf: scratch.assetURL(assetID, "pdf")) == original)
    }

    // MARK: - Reading a source PDF

    @Test("A source PDF's pages are counted and measured, in order")
    func sourcePagesAreCountedAndMeasured() async throws {
        let pages = try await PDFSource.pages(in: twoPageFixture())

        #expect(pages.map(\.index) == [0, 1])
        #expect(pages[0].width == 612)
        #expect(pages[0].height == 792)
        // The second page is landscape, so mixed geometry is visible from the
        // very first thing that reads a source.
        #expect(pages[1].width == 842)
        #expect(pages[1].height == 595)
    }

    @Test("Bytes that are not a PDF import nothing at all")
    func bytesThatAreNotAPDFAreRefused() async throws {
        await #expect(throws: PDFSourceError.notAPDF) {
            _ = try await PDFSource.pages(in: Data("this is not a pdf".utf8))
        }
    }

    // MARK: - Import: one source page becomes one document page

    @Test("Importing a PDF appends one page per source page, each with a pdf layer under ink")
    @MainActor
    func importAppendsOnePagePerSourcePage() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        let pagesBefore = session.pageCount

        let bytes = twoPageFixture()
        let appended = try await session.importPDF(bytes)

        #expect(session.lastSaveError == nil)
        #expect(appended.count == 2)
        #expect(session.pageCount == pagesBefore + 2)

        for (offset, pageID) in appended.enumerated() {
            let layers = try scratch.layersOnDisk(ofPage: pageID)
            #expect(layers.count == 2)
            #expect(layers[0].recognizedKind == .pdf)
            #expect(layers[1].recognizedKind == .ink, "the ink layer is still last")

            let ref = try PDFLayerRef(payload: layers[0].payload)
            #expect(ref.sourcePageIndex == offset)
            // One import is one asset, however many pages it has.
            #expect(ref.assetID == (try PDFLayerRef(
                payload: try scratch.layersOnDisk(ofPage: appended[0])[0].payload
            ).assetID))
        }

        // The asset is the imported file, byte for byte — never normalized,
        // never rewritten.
        let assetID = try PDFLayerRef(
            payload: try scratch.layersOnDisk(ofPage: appended[0])[0].payload
        ).assetID
        #expect(try Data(contentsOf: scratch.assetURL(assetID, "pdf")) == bytes)
        #expect(try scratch.assetFileCount() == 1)
    }

    // MARK: - Per-page geometry: the imported page is its source

    /// The payoff of phase 3b, and the defect it repairs. Phase 3a had one
    /// document-wide geometry, so an 842 × 595 landscape worksheet was fitted
    /// into a 612 × 792 portrait page: the layer's transform scaled it to
    /// 612 × 432 and centred it, leaving 180 points of white band the source
    /// never had. Now the page *is* the source page, and the transform maps the
    /// unit square edge to edge.
    @Test("An imported page carries its source's size rather than being letterboxed")
    @MainActor
    func importedPagesCarryTheirSourceSize() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()

        let sizes = [
            CGSize(width: 612, height: 792),
            CGSize(width: 842, height: 595),
            CGSize(width: 595.276, height: 841.89),
        ]
        let appended = try await session.importPDF(pdf(pageSizes: sizes) { _, _ in })
        #expect(session.lastSaveError == nil)
        #expect(appended.count == sizes.count)

        let index = try #require(await scratch.freshStore().load())
        for (offset, pageID) in appended.enumerated() {
            let position = try #require(index.pageIDs.firstIndex(of: pageID))
            let geometry = try #require(index.geometry(ofPageAt: position))
            let source = sizes[offset]

            #expect(abs(geometry.width - Double(source.width)) < 0.01)
            #expect(abs(geometry.height - Double(source.height)) < 0.01)

            // And no letterboxing: the pdf layer's transform maps the source's
            // unit square onto the whole page, with no offset and no bands.
            let placed = try scratch.layersOnDisk(ofPage: pageID)[0].pageSpaceTransform
            #expect(abs(placed.a - geometry.width) < 0.01)
            #expect(abs(placed.d - geometry.height) < 0.01)
            #expect(abs(placed.tx) < 0.01)
            #expect(abs(placed.ty) < 0.01)
        }

        // The landscape page really is landscape — the sentence the old
        // `pageWidth < pageHeight` rule made unwriteable.
        let landscapePosition = try #require(index.pageIDs.firstIndex(of: appended[1]))
        let landscape = try #require(index.geometry(ofPageAt: landscapePosition))
        #expect(landscape.width > landscape.height)
    }

    /// Mixed geometry has to survive the round trip, per page and in order, or
    /// an annotated import is a different document after a relaunch.
    @Test("Per-page geometry round trips through a save and a relaunch")
    @MainActor
    func perPageGeometryRoundTrips() async throws {
        let scratch = try TestScratch("pdf")
        let first = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await first.start()
        let appended = try await first.importPDF(twoPageFixture())
        await first.saveIfNeeded()

        let second = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await second.start()
        #expect(second.phase == .ready)

        let index = try #require(await scratch.freshStore().load())
        #expect(index.pageIDs.suffix(2) == ArraySlice(appended))
        #expect(
            index.pages.map(\.geometry) == [
                .canonical,
                PageGeometry(width: 612, height: 792),
                PageGeometry(width: 842, height: 595),
            ]
        )
        #expect(index.zoomCapPagePointsPerPixel
            == DocumentIndex.canonicalZoomCapPagePointsPerPixel)
    }

    /// "Mixed geometry is the normal case, not an edge case": swiping past the
    /// last page of a landscape import appends a blank *canonical portrait*
    /// page, so a portrait page after a landscape worksheet is the ordinary
    /// state of any annotated import.
    @Test("A page appended past a landscape import is canonical portrait")
    @MainActor
    func appendingPastALandscapeImportGivesACanonicalPage() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        try await session.importPDF(pdf(pageSizes: [CGSize(width: 842, height: 595)]) { _, _ in })

        // The append gesture, as the runtime reports it: a deliberate pull past
        // the last page's trailing edge.
        let root = session.pages.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()
        let scroll = session.pages.scrollView
        let last = session.pageCount - 1
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * (CGFloat(last) + 0.5), y: 0)
        session.pages.scrollViewDidEndDragging(scroll, willDecelerate: false)
        await session.saveIfNeeded()

        let index = try #require(await scratch.freshStore().load())
        #expect(index.pages.count == 3)
        #expect(index.pages[1].geometry == PageGeometry(width: 842, height: 595))
        #expect(index.pages[2].geometry == .canonical)
    }

    /// An image dropped on a page fits **that** page. Under one document-wide
    /// geometry it fitted a page that might not be the one it landed on.
    @Test("An image import fits the page it lands on, not a document-wide page")
    @MainActor
    func imageImportFitsItsOwnPage() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        let landscapePage = try await session.importPDF(
            pdf(pageSizes: [CGSize(width: 842, height: 595)]) { _, _ in }
        )[0]

        // A square source, so the fit is decided entirely by the page.
        try await session.importImage(
            Data([0x89, 0x50, 0x4E, 0x47]),
            format: .heic,
            sourceWidth: 100,
            sourceHeight: 100,
            onPage: landscapePage
        )

        let layers = try scratch.layersOnDisk(ofPage: landscapePage)
        let image = try #require(layers.first { $0.recognizedKind == .image })
        // Fitted to the landscape page's *height* — 595 — and centred across
        // its 842-point width. Against the canonical portrait page it would
        // have been 612 wide and centred vertically instead.
        #expect(abs(image.pageSpaceTransform.a - 595) < 0.01)
        #expect(abs(image.pageSpaceTransform.d - 595) < 0.01)
        #expect(abs(image.pageSpaceTransform.tx - (842 - 595) / 2) < 0.01)
        #expect(abs(image.pageSpaceTransform.ty) < 0.01)
    }

    @Test("A PDF this build cannot open imports nothing")
    @MainActor
    func anUnreadablePDFImportsNothing() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        let pagesBefore = session.pageCount

        await #expect(throws: PDFSourceError.notAPDF) {
            _ = try await session.importPDF(Data("nope".utf8))
        }
        #expect(session.pageCount == pagesBefore)
        // Refused before the leaf was written, so not even an orphan asset.
        #expect(try scratch.assetFileCount() == 0)
    }

    // MARK: - A page too small to display is refused before anything is written

    /// The one defect that destroyed a document with no recovery. An imported
    /// page *is* its source box, geometry is durable from the moment the import
    /// saves, and `PageCanvasController.establishZoomIfNeeded` traps on a page
    /// whose fit-width scale is past the document's zoom ceiling — so a receipt
    /// used to import cleanly and then crash the app on every subsequent open.
    ///
    /// The refusal has to land before `writeAsset`, not merely before the page
    /// is appended: an orphan asset would be inert, but the point of the test is
    /// that the disk is untouched.
    @Test("A source page narrower than the zoom cap allows is refused, and nothing is written")
    @MainActor
    func aPageTooSmallToDisplayIsRefusedAtImport() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        let pagesBefore = session.pageCount
        let onDiskBefore = try #require(await scratch.freshStore().load()).pageIDs

        let minimum = PageProjection.smallestDisplayablePagePoints(
            zoomCapPagePointsPerPixel: DocumentIndex.canonicalZoomCapPagePointsPerPixel
        )
        // A till receipt, and one ordinary page ahead of it: one bad box refuses
        // the whole import, so a half-imported worksheet is not a state.
        let receipt = pdf(
            pageSizes: [
                CGSize(width: 612, height: 792),
                CGSize(width: 103, height: 800),
            ]
        ) { _, _ in }

        await #expect(throws: LayerEditError.pageTooSmallToDisplay(
            width: 103,
            height: 800,
            minimum: minimum
        )) {
            _ = try await session.importPDF(receipt)
        }

        #expect(session.pageCount == pagesBefore)
        #expect(session.lastSaveError == nil)
        // Nothing durable moved: no asset, and the index still names exactly the
        // pages it named before.
        #expect(try scratch.assetFileCount() == 0)
        #expect(try #require(await scratch.freshStore().load()).pageIDs == onDiskBefore)
    }

    /// The other side of the bound, so the guard is a bound rather than a
    /// blanket refusal of small pages: a hair above it imports like any other
    /// source, at its own size.
    @Test("A source page at the minimum imports at its own size")
    @MainActor
    func aPageAtTheMinimumImportsNormally() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()

        let minimum = PageProjection.smallestDisplayablePagePoints(
            zoomCapPagePointsPerPixel: DocumentIndex.canonicalZoomCapPagePointsPerPixel
        )
        // 104 × 300: past the 103.2-point bound by eight tenths of a point, and
        // narrower than anything else this suite imports.
        #expect(minimum > 103 && minimum < 104)
        let appended = try await session.importPDF(
            pdf(pageSizes: [CGSize(width: 104, height: 300)]) { _, _ in }
        )

        #expect(session.lastSaveError == nil)
        #expect(appended.count == 1)

        let index = try #require(await scratch.freshStore().load())
        let position = try #require(index.pageIDs.firstIndex(of: appended[0]))
        #expect(try #require(index.geometry(ofPageAt: position))
            == PageGeometry(width: 104, height: 300))
    }

    @Test("Deleting one page's pdf layer leaves the asset the other pages still show")
    @MainActor
    func deletingOnePDFLayerKeepsTheSharedAsset() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        let appended = try await session.importPDF(twoPageFixture())

        let firstLayer = try #require(scratch.layersOnDisk(ofPage: appended[0]).first)
        let assetID = try PDFLayerRef(payload: firstLayer.payload).assetID

        try await session.deleteLayer(firstLayer.layerID, fromPage: appended[0])

        // The page dropped its ref and the layer file died with it...
        #expect(try await scratch.freshStore().loadPage(appended[0]).staticLayers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: scratch.layerURL(firstLayer.layerID).path))
        // ...but page two is still showing the same file, so it lives.
        #expect(FileManager.default.fileExists(atPath: scratch.assetURL(assetID, "pdf").path))

        // Delete the last reference and the asset goes with it.
        let secondLayer = try #require(scratch.layersOnDisk(ofPage: appended[1]).first)
        try await session.deleteLayer(secondLayer.layerID, fromPage: appended[1])
        #expect(!FileManager.default.fileExists(atPath: scratch.assetURL(assetID, "pdf").path))
    }

    /// The reference scan reclamation relies on reads disk, and disk knows
    /// nothing about layers whose save has not landed. Before the session
    /// guarded this, a transiently failed import save plus one delete
    /// destroyed the write-once asset all the surviving in-memory layers
    /// referenced — and with it the only copy of the PDF bytes.
    @Test("A failed save plus a delete never destroys a write-once asset")
    @MainActor
    func aFailedSavePlusADeleteDoesNotDestroyTheAsset() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()

        // Layer writes fail while asset writes still succeed: the import's
        // asset lands, but its layers and pages exist only in memory.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: scratch.layersURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scratch.layersURL.path
            )
        }
        let appended = try await session.importPDF(twoPageFixture())
        #expect(session.lastSaveError != nil)

        // The layer to delete exists only in the session; no file names it.
        let firstLayer = try #require(
            session.pages.staticLayersForPage?(session.pageCount - 2).first
        )
        let assetID = try PDFLayerRef(payload: firstLayer.payload).assetID
        try await session.deleteLayer(firstLayer.layerID, fromPage: appended[0])

        // The one copy of the PDF bytes survives the delete: the other page's
        // layer references it from memory, where the disk scan is blind.
        #expect(FileManager.default.fileExists(atPath: scratch.assetURL(assetID, "pdf").path))

        // Once the store works again, one ordinary save recovers everything.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scratch.layersURL.path
        )
        await session.saveIfNeeded()
        #expect(session.lastSaveError == nil)
        let survivor = try await scratch.freshStore().loadPage(appended[1])
        #expect(survivor.refusedLayers.isEmpty)
        #expect(survivor.staticLayers.count == 1)
        #expect(try await scratch.freshStore().loadPage(appended[0]).staticLayers.isEmpty)
        #expect(FileManager.default.fileExists(atPath: scratch.assetURL(assetID, "pdf").path))
    }

    /// `evicted()` keeps a far page's layer list but drops its ink to
    /// `.loading`, and a `.loading` page has no list to edit. That is a typed
    /// refusal for the caller, never a trap: an evicted page is a state any
    /// caller can reach by turning away.
    @Test("Deleting a layer on an evicted page refuses with a typed error, never traps")
    @MainActor
    func deleteLayerOnAnEvictedPageRefusesLoudly() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()

        // Six imported pages, so the last sits one page outside the prune
        // radius of an early one. One page and not five: the boundary is what
        // this asserts. `EditorSession.prefetchRadius` is that boundary — if it
        // moves again, this count moves with it.
        let appended = try await session.importPDF(
            pdf(
                pageSizes: Array(repeating: CGSize(width: 612, height: 792), count: 6)
            ) { _, _ in }
        )
        #expect(session.lastSaveError == nil)
        let farPageID = appended[5]
        let farLayerID = try #require(scratch.layersOnDisk(ofPage: farPageID).first).layerID

        // Turning prunes: the last page is outside the new page ± 3 window, so
        // its durable bytes drop and its ink becomes `.loading`.
        turn(session, to: 1)

        await #expect(throws: LayerEditError.pageNotReady(farPageID)) {
            try await session.deleteLayer(farLayerID, fromPage: farPageID)
        }
        // And nothing was deleted: the page's layers survive untouched.
        #expect(try scratch.layersOnDisk(ofPage: farPageID).count == 2)
    }

    // MARK: - Throwing the worksheet away

    /// A `pdf` layer is not selectable, and selection is the only other
    /// producer of a `layerID` — so without `deletePDFLayers` a mis-imported
    /// PDF is permanent. This is that hole closed: the page the user is
    /// looking at, named without any spatial hit test.
    @Test("Deleting the current page's PDF removes it durably")
    @MainActor
    func deletingTheCurrentPagesPDFIsDurable() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        let appended = try await session.importPDF(onePageFixture())
        let pageID = try #require(appended.first)
        let layer = try #require(scratch.layersOnDisk(ofPage: pageID).first)
        let assetID = try PDFLayerRef(payload: layer.payload).assetID

        // No page argument: the button has none either, so the default path is
        // the one under test. The import appended without navigating — page 0
        // is the document's own blank first page — so the user turns to it.
        turn(session, to: 1)
        #expect(session.currentPageID == pageID)
        #expect(try await session.deletePDFLayers() == 1)
        #expect(session.lastSaveError == nil)

        // Durable: a store that has read nothing sees a page with only ink.
        let reloaded = try await scratch.freshStore().loadPage(pageID)
        #expect(reloaded.staticLayers.isEmpty)
        #expect(reloaded.refusedLayers.isEmpty)
        // And the same two-level reclamation an image delete gets, because it
        // *is* an image delete — same site, same save, same `reclaim`.
        #expect(!FileManager.default.fileExists(atPath: scratch.layerURL(layer.layerID).path))
        #expect(!FileManager.default.fileExists(atPath: scratch.assetURL(assetID, "pdf").path))
    }

    /// The whole point of deleting by *kind*: it must not become a page-clearing
    /// button. An image on the same page is untouched, asset and all.
    @Test("Deleting the page's PDF leaves the page's image layers alone")
    @MainActor
    func deletingThePDFLeavesImagesAlone() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        let appended = try await session.importPDF(onePageFixture())
        let pageID = try #require(appended.first)
        try await session.importImage(
            Data([0x89, 0x50, 0x4E, 0x47]),
            format: .heic,
            sourceWidth: 100,
            sourceHeight: 100,
            onPage: pageID
        )

        #expect(try await session.deletePDFLayers(onPage: pageID) == 1)
        #expect(session.lastSaveError == nil)

        let reloaded = try await scratch.freshStore().loadPage(pageID)
        #expect(reloaded.staticLayers.count == 1)
        let survivor = try #require(reloaded.staticLayers.first)
        #expect(survivor.recognizedKind == .image)
        let imageRef = try ImageLayerRef(payload: survivor.payload)
        #expect(FileManager.default.fileExists(atPath: scratch.assetURL(imageRef.assetID, "heic").path))
    }

    /// The refusal is typed rather than silent because the caller is a button:
    /// the chrome cannot know whether the visible page carries a PDF without
    /// observing which page is visible, so it asks and is told no.
    @Test("A page with no pdf layer refuses gracefully and changes nothing")
    @MainActor
    func aPageWithNoPDFRefuses() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()
        let blankPageID = session.currentPageID

        await #expect(throws: LayerEditError.noPDFLayerOnPage(blankPageID)) {
            _ = try await session.deletePDFLayers()
        }
        // Refused, not half-done: the blank page still has its ink layer and
        // nothing else, and no save was provoked.
        #expect(session.lastSaveError == nil)
        #expect(try await scratch.freshStore().loadPage(blankPageID).staticLayers.isEmpty)
    }

    // MARK: - The layer split

    @Test("A page file is layer IDs, and each layer is its own file")
    func aPageFileNamesLayerFiles() async throws {
        let scratch = try TestScratch("pdf")
        let store = scratch.freshStore()
        let pageID = UUID()
        let assetID = UUID()
        let pdfLayerID = UUID()
        let inkLayerID = UUID()
        try await store.writeAsset(onePageFixture(), assetID: assetID, format: .pdf)

        try await store.save(
            index: scratch.index(pageIDs: [pageID]),
            changedPages: [
                pageID: [
                    try LayerEnvelope.pdf(
                        layerID: pdfLayerID,
                        ref: PDFLayerRef(assetID: assetID, sourcePageIndex: 0),
                        pageSpaceTransform: .identity
                    ),
                    inkEnvelope(layerID: inkLayerID, payload: Data([0x01])),
                ]
            ]
        )

        let raw = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: scratch.pageURL(pageID)),
            format: nil
        ) as? [String: Any]
        #expect(raw?["layers"] == nil, "the page file still carries inline envelopes")
        #expect(
            raw?["layerIDs"] as? [String]
                == [pdfLayerID.uuidString, inkLayerID.uuidString],
            "the page file is an ordered list of layer IDs, and order is z-order"
        )
        #expect(FileManager.default.fileExists(atPath: scratch.layerURL(pdfLayerID).path))
        #expect(FileManager.default.fileExists(atPath: scratch.layerURL(inkLayerID).path))
    }

    @Test("A page naming a layer file that is not there is fatal to the page")
    func aDanglingLayerRefIsFatal() async throws {
        let scratch = try TestScratch("pdf")
        let pageID = UUID()
        let ink = inkEnvelope(payload: Data([0x01]))
        try scratch.writePage(pageID, layers: [ink])
        try FileManager.default.removeItem(at: scratch.layerURL(ink.layerID))

        await #expect(
            throws: LayerError.missingLayerFile(pageID: pageID, layerID: ink.layerID)
        ) {
            _ = try await scratch.freshStore().loadPage(pageID)
        }
    }

    @Test("An orphan layer file is inert")
    func anOrphanLayerFileIsInert() async throws {
        let scratch = try TestScratch("pdf")
        let store = scratch.freshStore()
        let pageID = UUID()
        let index = scratch.index(pageIDs: [pageID])
        try await store.save(
            index: index,
            changedPages: [pageID: [inkEnvelope(payload: Data([0x01]))]]
        )

        // Exactly what a crash between the layer write and the page write
        // leaves behind.
        try scratch.writeLayerFile(inkEnvelope(payload: Data([0x09])))

        #expect(try await scratch.freshStore().load() == index)
        #expect(try await scratch.freshStore().loadPage(pageID).inkData == Data([0x01]))
    }

    @Test("A layer file filed under the wrong name is refused")
    func aMisfiledLayerFileIsRefused() async throws {
        let scratch = try TestScratch("pdf")
        let pageID = UUID()
        let named = UUID()
        let envelope = inkEnvelope(payload: Data([0x01]))

        try scratch.writeLayerFile(envelope, under: named)
        try scratch.writePageFileOnly(pageID, layerIDs: [named])

        await #expect(
            throws: LayerError.layerFileIDMismatch(expected: named, found: envelope.layerID)
        ) {
            _ = try await scratch.freshStore().loadPage(pageID)
        }
    }

    /// Write order is leaf to root, **enforced rather than described**. The
    /// caller states which layers changed, and the store refuses a claim that
    /// would leave the page file naming a layer that never landed.
    ///
    /// It has to be a page that already exists in the split form: a page with
    /// no file yet, and one still in a pre-split form, both write every layer
    /// forward whatever the caller claims, because none of their layers has a
    /// file to be unchanged. Those two cases cannot dangle, so they are not
    /// refused — which is itself worth pinning, in the second half here.
    @Test("A write naming a layer with no file and none being written is refused")
    func aWriteThatWouldDangleIsRefused() async throws {
        let scratch = try TestScratch("pdf")
        let pageID = UUID()
        let documentIndex = scratch.index(pageIDs: [pageID])
        let ink = inkEnvelope(payload: Data([0x01]))

        // A page with no file yet writes everything, so an understated claim
        // is harmless and accepted.
        try await scratch.freshStore().save(
            index: documentIndex,
            pages: [PageWrite(pageID: pageID, layers: [ink], changedLayerIDs: [])]
        )
        #expect(FileManager.default.fileExists(atPath: scratch.layerURL(ink.layerID).path))
        let pageBytesBefore = try Data(contentsOf: scratch.pageURL(pageID))

        // Now the page is split, and a claim that omits a layer with no file
        // on disk is refused before anything is written. Its asset is durable,
        // so the only thing wrong with it is the missing layer file.
        let assetID = UUID()
        try await scratch.freshStore().writeAsset(Data([0x89]), assetID: assetID, format: .heic)
        let unwritten = try LayerEnvelope.image(
            layerID: UUID(),
            ref: ImageLayerRef(assetID: assetID, format: .heic),
            pageSpaceTransform: .identity
        )
        let refusal = await #expect(throws: DocumentStore.PageSaveRefusal.self) {
            try await scratch.freshStore().save(
                index: documentIndex,
                pages: [
                    PageWrite(
                        pageID: pageID,
                        layers: [unwritten, ink],
                        changedLayerIDs: [ink.layerID]
                    )
                ]
            )
        }
        #expect(refusal?.refusedPages.map(\.pageID) == [pageID])
        #expect(refusal?.refusedPages.first?.reason.contains("danglingLayerRef") == true)
        #expect(try Data(contentsOf: scratch.pageURL(pageID)) == pageBytesBefore)
        #expect(!FileManager.default.fileExists(atPath: scratch.layerURL(unwritten.layerID).path))
    }

    // MARK: - Migration: read three forms, write one

    @Test("A phase 2 page file with an image layer loads, then splits on its next save")
    func aPhase2PageSplitsOnItsNextSave() async throws {
        let scratch = try TestScratch("pdf")
        let store = scratch.freshStore()
        let pageID = UUID()
        let assetID = UUID()
        try await store.writeAsset(Data([0x89, 0x50]), assetID: assetID, format: .heic)

        let image = try LayerEnvelope.image(
            layerID: UUID(),
            ref: ImageLayerRef(assetID: assetID, format: .heic),
            pageSpaceTransform: .fittingSource(
                width: 100, height: 50,
                inPageOfWidth: PageGeometry.canonical.width, height: PageGeometry.canonical.height
            )
        )
        let ink = inkEnvelope(payload: Data([0x01]))
        try scratch.writeInlinePageFile(pageID, layers: [image, ink])
        let documentIndex = scratch.index(pageIDs: [pageID])
        try scratch.writeIndexFile(documentIndex)

        // It loads in the old form, with no layers/ files at all.
        let loaded = try await scratch.freshStore().loadPage(pageID)
        #expect(loaded.staticLayers.map(\.layerID) == [image.layerID])
        #expect(!FileManager.default.fileExists(atPath: scratch.layerURL(ink.layerID).path))

        // The next save writes it forward. Only the ink changed, but a page
        // that has never been split writes *all* of its layers forward — none
        // of them has a file yet, so a minimal write would dangle.
        let newInk = inkEnvelope(layerID: ink.layerID, payload: Data([0x02]))
        try await scratch.freshStore().save(
            index: documentIndex,
            pages: [
                PageWrite(
                    pageID: pageID,
                    layers: [image, newInk],
                    changedLayerIDs: [newInk.layerID]
                )
            ]
        )

        #expect(FileManager.default.fileExists(atPath: scratch.layerURL(image.layerID).path))
        #expect(FileManager.default.fileExists(atPath: scratch.layerURL(ink.layerID).path))
        let reloaded = try await scratch.freshStore().loadPage(pageID)
        #expect(reloaded.inkData == Data([0x02]))
        #expect(reloaded.staticLayers.map(\.layerID) == [image.layerID])
    }

    // MARK: - The exit test

    /// **The exit test for phase 3, and the reason the split lands here.**
    ///
    /// A document with a genuinely heavy asset and several pages. One page's
    /// ink is dirtied, once, and saved. What may be written is exactly one
    /// file — that page's ink layer — and the assertion is made against every
    /// other durable file in the package by modification date *and* by bytes.
    ///
    /// What it proves, stated precisely so it is not read as proving more:
    ///
    /// - the imported PDF asset is not rewritten, so annotation cost is
    ///   independent of import size;
    /// - the inked page's own `pdf` layer envelope is not rewritten, which is
    ///   the property inline envelopes made impossible;
    /// - the inked page's *page file* is not rewritten, because its layer list
    ///   did not change;
    /// - no other page's files are touched at any level;
    /// - the index is not rewritten, because page order and the current page
    ///   did not change.
    ///
    /// What it does not prove: anything about rendering, and anything about
    /// what the write costs in time. It is a statement about which bytes moved.
    ///
    /// The comparison is whole-package and by identity, not a list of files the
    /// test remembered to check — `TestScratch.snapshot()` walks everything under
    /// the document directory, so a file this change did not anticipate cannot
    /// slip through by not being named.
    @Test("Ink on one page of a large import writes exactly that page's ink layer")
    @MainActor
    func inkOnOnePageWritesOnlyThatPagesInkLayer() async throws {
        let scratch = try TestScratch("pdf")
        let session = EditorSession(store: scratch.freshStore(), debounce: .milliseconds(20))
        await session.start()

        let source = heavyFixture(pages: 5)
        #expect(
            source.count > 200_000,
            "the asset has to be big enough that rewriting it would be the whole cost"
        )
        let appended = try await session.importPDF(source)
        #expect(session.lastSaveError == nil)

        // Page 4 of the import — one that is neither first nor last, so an
        // off-by-one in the write path cannot pass by accident.
        let inkedPageIndex = try #require(appended.indices.last.map { $0 - 1 })
        let inkedPageID = appended[inkedPageIndex]
        let inkLayerID = try #require(scratch.layersOnDisk(ofPage: inkedPageID).last).layerID

        // Turn to it and let its ink settle before the measurement starts, so
        // that what follows is one ink edit and nothing else.
        turn(session, to: session.pageCount - 2)
        try await waitUntil("the inked page has a live canvas") {
            session.currentPageID == inkedPageID && session.currentCanvas != nil
        }
        await session.saveIfNeeded()
        #expect(session.lastSaveError == nil)

        // Backdated rather than waited out: with every file stamped
        // twenty-five years back, a rewrite cannot hide inside the
        // filesystem's timestamp resolution.
        try scratch.freezeTimestamps()
        let before = try scratch.snapshot()

        try #require(session.currentCanvas).canvasView.drawing = strokeAcrossPage()
        await session.saveIfNeeded()
        #expect(session.lastSaveError == nil)

        let after = try scratch.snapshot()

        // The set of files did not change: nothing was created and nothing was
        // removed by an ordinary ink save.
        #expect(Set(after.keys) == Set(before.keys))

        let inkLayerPath = "layers/\(inkLayerID.uuidString).plist"
        let rewritten = after.filter { name, entry in before[name] != entry }.keys.sorted()
        #expect(
            rewritten == [inkLayerPath],
            """
            an ink edit on one page rewrote \(rewritten.joined(separator: ", ")); \
            it may rewrite only \(inkLayerPath). Anything else here is the \
            whole-document rewrite the format exists to prevent.
            """
        )

        // And the ink genuinely landed, so this is not a save that did nothing.
        #expect(
            try PKDrawing(data: await scratch.freshStore().loadPage(inkedPageID).inkData)
                .strokes.count == 1
        )
    }

    // MARK: - Fixtures

    private func inkEnvelope(layerID: UUID = UUID(), payload: Data) -> LayerEnvelope {
        LayerEnvelope(
            layerID: layerID, kind: .ink, payload: payload, pageSpaceTransform: .identity
        )
    }

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

    /// The paging runtime settles on a page the way a finished scroll does.
    @MainActor
    private func turn(_ session: EditorSession, to page: Int) {
        let root = session.pages.view!
        if root.frame.isEmpty {
            root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        }
        root.layoutIfNeeded()
        let scroll = session.pages.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * CGFloat(page), y: 0)
        session.pages.scrollViewDidEndDecelerating(scroll)
        session.pages.view.layoutIfNeeded()
    }

    @MainActor
    private func waitUntil(
        _ what: String,
        within: Duration = .seconds(5),
        _ condition: () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: within)
        while clock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record(Comment(rawValue: "timed out waiting for: \(what)"))
    }

    /// A one-page US-Letter PDF.
    private func onePageFixture() -> Data {
        pdf(pageSizes: [CGSize(width: 612, height: 792)]) { _, _ in }
    }

    /// Portrait then landscape, so that "mixed geometry is the normal case" is
    /// visible to the very first thing that reads a source.
    private func twoPageFixture() -> Data {
        pdf(
            pageSizes: [
                CGSize(width: 612, height: 792),
                CGSize(width: 842, height: 595),
            ]
        ) { _, _ in }
    }

    /// A multi-page PDF heavy enough that rewriting it would dominate any save
    /// — several hundred kilobytes of vector content, which is what a scanned
    /// or graphics-rich worksheet is.
    private func heavyFixture(pages: Int) -> Data {
        pdf(pageSizes: Array(repeating: CGSize(width: 612, height: 792), count: pages)) {
            context, pageIndex in
            var generator = SeededGenerator(seed: UInt64(pageIndex) &+ 1)
            for _ in 0..<4000 {
                let color = UIColor(
                    red: CGFloat.random(in: 0...1, using: &generator),
                    green: CGFloat.random(in: 0...1, using: &generator),
                    blue: CGFloat.random(in: 0...1, using: &generator),
                    alpha: 1
                )
                color.setStroke()
                let path = UIBezierPath()
                path.move(
                    to: CGPoint(
                        x: CGFloat.random(in: 0...612, using: &generator),
                        y: CGFloat.random(in: 0...792, using: &generator)
                    )
                )
                path.addLine(
                    to: CGPoint(
                        x: CGFloat.random(in: 0...612, using: &generator),
                        y: CGFloat.random(in: 0...792, using: &generator)
                    )
                )
                path.lineWidth = 0.5
                path.stroke()
                _ = context
            }
        }
    }

    private func pdf(
        pageSizes: [CGSize],
        draw: (UIGraphicsPDFRendererContext, Int) -> Void
    ) -> Data {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSizes[0])
        )
        return renderer.pdfData { context in
            for (pageIndex, size) in pageSizes.enumerated() {
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                draw(context, pageIndex)
            }
        }
    }

    /// Deterministic randomness: a fixture that differed run to run would make
    /// a size assertion flaky for no benefit.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }
}

/// The fixtures only this suite needs: the superseded inline page form, an
/// index written without the store, and a count of the assets on disk.
private extension TestScratch {
    /// The phase 1–2 form: envelopes inline in the page file. Production code
    /// can read it and can never write it, so the fixture lives here.
    func writeInlinePageFile(_ pageID: UUID, layers: [LayerEnvelope]) throws {
        struct InlinePageFile: Encodable {
            let pageID: UUID
            let layers: [LayerEnvelope]
        }
        try TestScratch.binaryEncoder()
            .encode(InlinePageFile(pageID: pageID, layers: layers))
            .write(to: pageURL(pageID), options: .atomic)
    }

    func assetFileCount() throws -> Int {
        guard FileManager.default.fileExists(atPath: assetsURL.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(
            at: assetsURL,
            includingPropertiesForKeys: nil
        ).count
    }
}
