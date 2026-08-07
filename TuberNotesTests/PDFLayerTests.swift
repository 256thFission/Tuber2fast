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
        let scratch = try Scratch()
        let store = scratch.store()
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

        let loaded = try await scratch.store().loadPage(pageID)
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
        let scratch = try Scratch()
        let assetID = UUID()
        let layerID = UUID()
        let pageID = UUID()
        try await scratch.store().writeAsset(onePageFixture(), assetID: assetID, format: .pdf)

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
            _ = try await scratch.store().loadPage(pageID)
        }
    }

    @Test("A negative source page index is an invalid state, not a clamp")
    func negativeSourcePageIndexFailsLoud() async throws {
        let scratch = try Scratch()
        let assetID = UUID()
        let layerID = UUID()
        let pageID = UUID()
        try await scratch.store().writeAsset(onePageFixture(), assetID: assetID, format: .pdf)

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
            _ = try await scratch.store().loadPage(pageID)
        }
    }

    @Test("A pdf layer whose asset is missing refuses the layer, and the document opens")
    func aMissingPDFAssetRefusesTheLayerOnly() async throws {
        let scratch = try Scratch()
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
        let loaded = try await scratch.store().loadPage(pageID)
        #expect(loaded.refusedLayers.map(\.reason) == [.missingAsset(missing)])
        #expect(loaded.inkData == Data([0x01]))
        // Preserved as well as refused: dropping it is the one repair, and a
        // repair is a save, so the envelope has to survive to be written back.
        #expect(loaded.staticLayers.map(\.layerID) == [layerID])
    }

    @Test("A pdf layer whose payload will not decode refuses the layer")
    func anUnreadablePDFPayloadRefusesTheLayer() async throws {
        let scratch = try Scratch()
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

        let loaded = try await scratch.store().loadPage(pageID)
        #expect(loaded.refusedLayers.map(\.reason) == [.unreadablePayload])
    }

    /// A `pdf` asset is not a bitmap. An `image` layer naming one is the same
    /// invalid state as one naming an encoding this build has no decoder for,
    /// and takes the same refusal rather than being handed to an image decoder.
    @Test("An image layer may not name a pdf asset")
    func anImageLayerMayNotNameAPDFAsset() async throws {
        let scratch = try Scratch()
        let assetID = UUID()
        let layerID = UUID()
        let pageID = UUID()
        try await scratch.store().writeAsset(onePageFixture(), assetID: assetID, format: .pdf)

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

        let loaded = try await scratch.store().loadPage(pageID)
        #expect(
            loaded.refusedLayers.map(\.reason)
                == [.unsupportedAssetFormat(assetID: assetID, format: "pdf")]
        )
    }

    @Test("A pdf asset is never rewritten: writing its ID again is refused")
    func pdfAssetsAreWriteOnce() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
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
        let scratch = try Scratch()
        let session = EditorSession(store: scratch.store(), debounce: .milliseconds(20))
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

    @Test("A PDF this build cannot open imports nothing")
    @MainActor
    func anUnreadablePDFImportsNothing() async throws {
        let scratch = try Scratch()
        let session = EditorSession(store: scratch.store(), debounce: .milliseconds(20))
        await session.start()
        let pagesBefore = session.pageCount

        await #expect(throws: PDFSourceError.notAPDF) {
            _ = try await session.importPDF(Data("nope".utf8))
        }
        #expect(session.pageCount == pagesBefore)
        // Refused before the leaf was written, so not even an orphan asset.
        #expect(try scratch.assetFileCount() == 0)
    }

    @Test("Deleting one page's pdf layer leaves the asset the other pages still show")
    @MainActor
    func deletingOnePDFLayerKeepsTheSharedAsset() async throws {
        let scratch = try Scratch()
        let session = EditorSession(store: scratch.store(), debounce: .milliseconds(20))
        await session.start()
        let appended = try await session.importPDF(twoPageFixture())

        let firstLayer = try #require(scratch.layersOnDisk(ofPage: appended[0]).first)
        let assetID = try PDFLayerRef(payload: firstLayer.payload).assetID

        try await session.deleteLayer(firstLayer.layerID, fromPage: appended[0])

        // The page dropped its ref and the layer file died with it...
        #expect(try await scratch.store().loadPage(appended[0]).staticLayers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: scratch.layerURL(firstLayer.layerID).path))
        // ...but page two is still showing the same file, so it lives.
        #expect(FileManager.default.fileExists(atPath: scratch.assetURL(assetID, "pdf").path))

        // Delete the last reference and the asset goes with it.
        let secondLayer = try #require(scratch.layersOnDisk(ofPage: appended[1]).first)
        try await session.deleteLayer(secondLayer.layerID, fromPage: appended[1])
        #expect(!FileManager.default.fileExists(atPath: scratch.assetURL(assetID, "pdf").path))
    }

    // MARK: - The layer split

    @Test("A page file is layer IDs, and each layer is its own file")
    func aPageFileNamesLayerFiles() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
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
        let scratch = try Scratch()
        let pageID = UUID()
        let ink = inkEnvelope(payload: Data([0x01]))
        try scratch.writePage(pageID, layers: [ink])
        try FileManager.default.removeItem(at: scratch.layerURL(ink.layerID))

        await #expect(
            throws: LayerError.missingLayerFile(pageID: pageID, layerID: ink.layerID)
        ) {
            _ = try await scratch.store().loadPage(pageID)
        }
    }

    @Test("An orphan layer file is inert")
    func anOrphanLayerFileIsInert() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let pageID = UUID()
        let index = scratch.index(pageIDs: [pageID])
        try await store.save(
            index: index,
            changedPages: [pageID: [inkEnvelope(payload: Data([0x01]))]]
        )

        // Exactly what a crash between the layer write and the page write
        // leaves behind.
        try scratch.writeLayerFile(inkEnvelope(payload: Data([0x09])))

        #expect(try await scratch.store().load() == index)
        #expect(try await scratch.store().loadPage(pageID).inkData == Data([0x01]))
    }

    @Test("A layer file filed under the wrong name is refused")
    func aMisfiledLayerFileIsRefused() async throws {
        let scratch = try Scratch()
        let pageID = UUID()
        let named = UUID()
        let envelope = inkEnvelope(payload: Data([0x01]))

        try scratch.writeLayerFile(envelope, under: named)
        try scratch.writePageFileOnly(pageID, layerIDs: [named])

        await #expect(
            throws: LayerError.layerFileIDMismatch(expected: named, found: envelope.layerID)
        ) {
            _ = try await scratch.store().loadPage(pageID)
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
        let scratch = try Scratch()
        let pageID = UUID()
        let documentIndex = scratch.index(pageIDs: [pageID])
        let ink = inkEnvelope(payload: Data([0x01]))

        // A page with no file yet writes everything, so an understated claim
        // is harmless and accepted.
        try await scratch.store().save(
            index: documentIndex,
            pages: [PageWrite(pageID: pageID, layers: [ink], changedLayerIDs: [])]
        )
        #expect(FileManager.default.fileExists(atPath: scratch.layerURL(ink.layerID).path))
        let pageBytesBefore = try Data(contentsOf: scratch.pageURL(pageID))

        // Now the page is split, and a claim that omits a layer with no file
        // on disk is refused before anything is written. Its asset is durable,
        // so the only thing wrong with it is the missing layer file.
        let assetID = UUID()
        try await scratch.store().writeAsset(Data([0x89]), assetID: assetID, format: .png)
        let unwritten = try LayerEnvelope.image(
            layerID: UUID(),
            ref: ImageLayerRef(assetID: assetID, format: .png),
            pageSpaceTransform: .identity
        )
        await #expect(
            throws: LayerError.danglingLayerRef(pageID: pageID, layerID: unwritten.layerID)
        ) {
            try await scratch.store().save(
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
        #expect(try Data(contentsOf: scratch.pageURL(pageID)) == pageBytesBefore)
        #expect(!FileManager.default.fileExists(atPath: scratch.layerURL(unwritten.layerID).path))
    }

    // MARK: - Migration: read three forms, write one

    @Test("A phase 2 page file with an image layer loads, then splits on its next save")
    func aPhase2PageSplitsOnItsNextSave() async throws {
        let scratch = try Scratch()
        let store = scratch.store()
        let pageID = UUID()
        let assetID = UUID()
        try await store.writeAsset(Data([0x89, 0x50]), assetID: assetID, format: .png)

        let image = try LayerEnvelope.image(
            layerID: UUID(),
            ref: ImageLayerRef(assetID: assetID, format: .png),
            pageSpaceTransform: .fittingSource(
                width: 100, height: 50,
                inPageOfWidth: PageGeometry.width, height: PageGeometry.height
            )
        )
        let ink = inkEnvelope(payload: Data([0x01]))
        try scratch.writeInlinePageFile(pageID, layers: [image, ink])
        let documentIndex = scratch.index(pageIDs: [pageID])
        try scratch.writeIndexFile(documentIndex)

        // It loads in the old form, with no layers/ files at all.
        let loaded = try await scratch.store().loadPage(pageID)
        #expect(loaded.staticLayers.map(\.layerID) == [image.layerID])
        #expect(!FileManager.default.fileExists(atPath: scratch.layerURL(ink.layerID).path))

        // The next save writes it forward. Only the ink changed, but a page
        // that has never been split writes *all* of its layers forward — none
        // of them has a file yet, so a minimal write would dangle.
        let newInk = inkEnvelope(layerID: ink.layerID, payload: Data([0x02]))
        try await scratch.store().save(
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
        let reloaded = try await scratch.store().loadPage(pageID)
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
    /// test remembered to check — `Scratch.snapshot()` walks everything under
    /// the document directory, so a file this change did not anticipate cannot
    /// slip through by not being named.
    @Test("Ink on one page of a large import writes exactly that page's ink layer")
    @MainActor
    func inkOnOnePageWritesOnlyThatPagesInkLayer() async throws {
        let scratch = try Scratch()
        let session = EditorSession(store: scratch.store(), debounce: .milliseconds(20))
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

        let before = try scratch.snapshot()
        // Far enough apart that an unwanted rewrite cannot hide inside the
        // filesystem's timestamp resolution.
        try await Task.sleep(for: .milliseconds(1100))

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
            try PKDrawing(data: await scratch.store().loadPage(inkedPageID).inkData)
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

    /// A unique directory per test, removed afterwards.
    private final class Scratch {
        let root: URL

        var documentURL: URL { root.appendingPathComponent("JustACanvas.tubernotes") }
        var pagesURL: URL { documentURL.appendingPathComponent("pages") }
        var layersURL: URL { documentURL.appendingPathComponent("layers") }
        var assetsURL: URL { documentURL.appendingPathComponent("assets") }

        func pageURL(_ pageID: UUID) -> URL {
            pagesURL.appendingPathComponent("\(pageID.uuidString).plist")
        }

        func layerURL(_ layerID: UUID) -> URL {
            layersURL.appendingPathComponent("\(layerID.uuidString).plist")
        }

        func assetURL(_ assetID: UUID, _ ext: String) -> URL {
            assetsURL.appendingPathComponent("\(assetID.uuidString).\(ext)")
        }

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tubernotes-pdf-tests-\(UUID().uuidString)")
            for directory in [pagesURL, layersURL] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
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

        /// Writes a page and its layers directly, bypassing the store — the
        /// only way to put on disk what the store refuses to write.
        func writePage(_ pageID: UUID, layers: [LayerEnvelope]) throws {
            for layer in layers { try writeLayerFile(layer) }
            try writePageFileOnly(pageID, layerIDs: layers.map(\.layerID))
        }

        func writePageFileOnly(_ pageID: UUID, layerIDs: [UUID]) throws {
            let page = PageFile(pageID: pageID, layerIDs: layerIDs)
            try Self.binaryEncoder().encode(page).write(to: pageURL(pageID), options: .atomic)
        }

        func writeLayerFile(_ layer: LayerEnvelope, under name: UUID? = nil) throws {
            try Self.binaryEncoder().encode(layer).write(
                to: layerURL(name ?? layer.layerID),
                options: .atomic
            )
        }

        /// The phase 1–2 form: envelopes inline in the page file. Production
        /// code can read it and can never write it, so the fixture lives here.
        func writeInlinePageFile(_ pageID: UUID, layers: [LayerEnvelope]) throws {
            struct InlinePageFile: Encodable {
                let pageID: UUID
                let layers: [LayerEnvelope]
            }
            try Self.binaryEncoder()
                .encode(InlinePageFile(pageID: pageID, layers: layers))
                .write(to: pageURL(pageID), options: .atomic)
        }

        func writeIndexFile(_ index: DocumentIndex) throws {
            try Self.binaryEncoder().encode(index).write(
                to: documentURL.appendingPathComponent("document.plist"),
                options: .atomic
            )
        }

        /// One page's layer envelopes as they are on disk, read the way the
        /// store reads them.
        func layersOnDisk(ofPage pageID: UUID) throws -> [LayerEnvelope] {
            let page = try PropertyListDecoder().decode(
                PageFile.self,
                from: Data(contentsOf: pageURL(pageID))
            )
            if let inline = page.inlineLayers { return inline }
            return try page.layerIDs.map { layerID in
                try PropertyListDecoder().decode(
                    LayerEnvelope.self,
                    from: Data(contentsOf: layerURL(layerID))
                )
            }
        }

        func assetFileCount() throws -> Int {
            guard FileManager.default.fileExists(atPath: assetsURL.path) else { return 0 }
            return try FileManager.default.contentsOfDirectory(
                at: assetsURL,
                includingPropertiesForKeys: nil
            ).count
        }

        /// Every file in the document package, by path relative to it, with
        /// enough to notice any rewrite: when it was last written and what it
        /// contains.
        ///
        /// Content as well as mtime deliberately. An mtime comparison alone
        /// would miss a rewrite that landed inside the filesystem's timestamp
        /// resolution, and a content comparison alone would miss a rewrite of
        /// identical bytes — which is still the whole-file write this format
        /// exists to avoid. Together, neither kind of rewrite can hide.
        func snapshot() throws -> [String: FileState] {
            var out: [String: FileState] = [:]
            let base = documentURL.standardizedFileURL.path
            guard let walk = FileManager.default.enumerator(
                at: documentURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
            ) else { return out }

            for case let url as URL in walk {
                let values = try url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                )
                guard values.isRegularFile == true else { continue }
                let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
                out[path] = FileState(
                    modified: values.contentModificationDate,
                    bytes: try Data(contentsOf: url)
                )
            }
            return out
        }

        struct FileState: Equatable {
            let modified: Date?
            let bytes: Data
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
