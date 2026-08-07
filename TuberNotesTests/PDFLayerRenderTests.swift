import CoreGraphics
import ImageIO
import PencilKit
import Testing
import UIKit

@testable import TuberNotes

/// Phase 3c of `Docs/Forks/CanvasFeatureComplete.md`, first deliverable: a
/// `pdf` layer renders in the static composite, through `PDFPageRasterizer`,
/// exactly as an `image` layer renders through ImageIO.
///
/// This is the resolution of review finding 4: an imported PDF page used to
/// show the pink refusal tint under fully editable ink, and an image layer
/// added onto a pdf-backed page was refused with it by the
/// one-failure-refuses-all rule. Both are pinned here — a pdf page
/// composites, an image over a pdf composites, and the refusals that remain
/// are the genuine ones: unknown kind, unreadable payload, missing or
/// unreadable asset, an out-of-range source page.
@Suite("PDF layers in the static composite")
struct PDFLayerRenderTests {

    /// The quadrant fixture's own extent, as a page: an imported page's
    /// geometry is its source's size in points.
    private static let quadrantGeometry = PageGeometry(width: 120, height: 200)

    @Test("A pdf layer composites: the quadrants land where the display shows them")
    func aPDFLayerComposites() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)
        let layer = try await scratch.pdfLayer(
            bytes: PDFFixture.quadrantPDF(rotate: 0),
            sourcePageIndex: 0,
            transform: PageSpaceTransform(a: 120, b: 0, c: 0, d: 200, tx: 0, ty: 0)
        )

        let composite = try await composited(
            renderer,
            request: StaticLayerRequest(
                layers: [layer], geometry: Self.quadrantGeometry, pixelsPerPagePoint: 1
            )
        )
        #expect(composite.image.width == 120 && composite.image.height == 200)
        // Top-left red and bottom-left blue in one pair is the y-flip test:
        // a doubled or missing flip anywhere between PDF user space and page
        // space swaps exactly these two.
        #expect(isRed(pixel(composite.image, x: 5, y: 5)))
        #expect(isGreen(pixel(composite.image, x: 114, y: 5)))
        #expect(isBlue(pixel(composite.image, x: 5, y: 194)))
        #expect(isYellow(pixel(composite.image, x: 114, y: 194)))
    }

    @Test("A rotated source page composites the way it displays")
    func aRotatedSourceComposites() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)
        // /Rotate 90 displays the 120x200 crop as 200x120, turned clockwise:
        // the unrotated bottom-left (blue) lands top-left.
        let layer = try await scratch.pdfLayer(
            bytes: PDFFixture.quadrantPDF(rotate: 90),
            sourcePageIndex: 0,
            transform: PageSpaceTransform(a: 200, b: 0, c: 0, d: 120, tx: 0, ty: 0)
        )

        let composite = try await composited(
            renderer,
            request: StaticLayerRequest(
                layers: [layer],
                geometry: PageGeometry(width: 200, height: 120),
                pixelsPerPagePoint: 1
            )
        )
        #expect(isBlue(pixel(composite.image, x: 5, y: 5)))
        #expect(isRed(pixel(composite.image, x: 194, y: 5)))
        #expect(isYellow(pixel(composite.image, x: 5, y: 114)))
        #expect(isGreen(pixel(composite.image, x: 194, y: 114)))
    }

    @Test("A pdf layer is placed by its transform, not stretched to the page")
    func placementFollowsTheTransform() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)
        // The 120x200 source placed at (100, 200) as a 120x200 patch on the
        // canonical page.
        let layer = try await scratch.pdfLayer(
            bytes: PDFFixture.quadrantPDF(rotate: 0),
            sourcePageIndex: 0,
            transform: PageSpaceTransform(a: 120, b: 0, c: 0, d: 200, tx: 100, ty: 200)
        )

        let composite = try await composited(
            renderer,
            request: StaticLayerRequest(layers: [layer], geometry: .canonical, pixelsPerPagePoint: 1)
        )
        #expect(isRed(pixel(composite.image, x: 110, y: 210)), "inside the placed rect, top-left quadrant")
        #expect(isYellow(pixel(composite.image, x: 210, y: 390)), "inside, bottom-right quadrant")
        #expect(isWhite(pixel(composite.image, x: 110, y: 150)), "above it is bare page")
        #expect(isWhite(pixel(composite.image, x: 300, y: 250)), "beside it is bare page")
    }

    @Test("An image layer over a pdf layer composites; neither poisons the other")
    func anImageOverAPDFComposites() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)
        let worksheet = try await scratch.pdfLayer(
            bytes: PDFFixture.quadrantPDF(rotate: 0),
            sourcePageIndex: 0,
            transform: PageSpaceTransform(a: 120, b: 0, c: 0, d: 200, tx: 0, ty: 0)
        )
        // A green patch over the top-left (red) quadrant only.
        let sticker = try await scratch.imageLayer(
            color: .green,
            transform: PageSpaceTransform(a: 40, b: 0, c: 0, d: 40, tx: 10, ty: 10)
        )

        let composite = try await composited(
            renderer,
            request: StaticLayerRequest(
                layers: [worksheet, sticker],
                geometry: Self.quadrantGeometry,
                pixelsPerPagePoint: 1
            )
        )
        #expect(isGreen(pixel(composite.image, x: 30, y: 30)), "the image draws above the worksheet")
        #expect(isRed(pixel(composite.image, x: 5, y: 5)), "the worksheet shows where the image does not")
        #expect(isYellow(pixel(composite.image, x: 114, y: 194)))
    }

    @Test("A pdf composite's bytes count against the cache bound")
    func pdfCompositeBytesAreCounted() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)
        let layer = try await scratch.pdfLayer(
            bytes: PDFFixture.quadrantPDF(rotate: 0),
            sourcePageIndex: 0,
            transform: PageSpaceTransform(a: 120, b: 0, c: 0, d: 200, tx: 0, ty: 0)
        )

        let composite = try await composited(
            renderer,
            request: StaticLayerRequest(
                layers: [layer], geometry: Self.quadrantGeometry, pixelsPerPagePoint: 1
            )
        )
        #expect(composite.byteCount > 0)
        #expect(await renderer.cachedByteCount == composite.byteCount)
    }

    // MARK: - The refusals that remain are the genuine ones

    @Test("A pdf layer whose asset is missing refuses the composite")
    func aMissingAssetRefuses() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)
        let layer = LayerEnvelope(
            layerID: UUID(),
            kind: .pdf,
            payload: try PDFLayerRef(assetID: UUID(), sourcePageIndex: 0).encodedPayload(),
            pageSpaceTransform: PageSpaceTransform(a: 120, b: 0, c: 0, d: 200, tx: 0, ty: 0)
        )
        let render = await renderer.composite(
            for: StaticLayerRequest(
                layers: [layer], geometry: Self.quadrantGeometry, pixelsPerPagePoint: 1
            )
        )
        guard case .refused = render else {
            Issue.record("a missing pdf asset rendered as \(render)")
            return
        }
    }

    @Test("An asset that is not a PDF refuses, never a plausible wrong picture")
    func unreadableAssetBytesRefuse() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)
        let layer = try await scratch.pdfLayer(
            bytes: Data("not a pdf".utf8),
            sourcePageIndex: 0,
            transform: PageSpaceTransform(a: 120, b: 0, c: 0, d: 200, tx: 0, ty: 0)
        )
        let render = await renderer.composite(
            for: StaticLayerRequest(
                layers: [layer], geometry: Self.quadrantGeometry, pixelsPerPagePoint: 1
            )
        )
        guard case .refused(let why) = render else {
            Issue.record("unreadable pdf bytes rendered as \(render)")
            return
        }
        #expect(why.contains(layer.layerID.uuidString))
    }

    @Test("A source page index outside the document refuses")
    func anOutOfRangeSourcePageRefuses() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)
        let layer = try await scratch.pdfLayer(
            bytes: PDFFixture.quadrantPDF(rotate: 0),
            sourcePageIndex: 7,
            transform: PageSpaceTransform(a: 120, b: 0, c: 0, d: 200, tx: 0, ty: 0)
        )
        let render = await renderer.composite(
            for: StaticLayerRequest(
                layers: [layer], geometry: Self.quadrantGeometry, pixelsPerPagePoint: 1
            )
        )
        guard case .refused = render else {
            Issue.record("an out-of-range source page rendered as \(render)")
            return
        }
    }

    @Test("A pdf payload that will not decode refuses")
    func anUndecodablePayloadRefuses() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)
        let layer = LayerEnvelope(
            layerID: UUID(),
            kind: .pdf,
            payload: Data("garbage".utf8),
            pageSpaceTransform: PageSpaceTransform(a: 120, b: 0, c: 0, d: 200, tx: 0, ty: 0)
        )
        let render = await renderer.composite(
            for: StaticLayerRequest(
                layers: [layer], geometry: Self.quadrantGeometry, pixelsPerPagePoint: 1
            )
        )
        guard case .refused = render else {
            Issue.record("an undecodable pdf payload rendered as \(render)")
            return
        }
    }

    @Test("An unrecognized kind still refuses the whole composite")
    func anUnknownKindStillRefuses() async throws {
        let scratch = try Scratch()
        let renderer = StaticLayerRenderer(store: scratch.store)
        let stranger = LayerEnvelope(
            layerID: UUID(),
            rawKind: "sticker",
            payload: Data(),
            pageSpaceTransform: PageSpaceTransform(a: 10, b: 0, c: 0, d: 10, tx: 0, ty: 0)
        )
        let render = await renderer.composite(
            for: StaticLayerRequest(layers: [stranger], geometry: .canonical, pixelsPerPagePoint: 1)
        )
        guard case .refused(let why) = render else {
            Issue.record("an unknown kind rendered as \(render)")
            return
        }
        #expect(why.contains("sticker"))
    }

    // MARK: - Through the session: the pink box is gone

    @Test("An imported PDF page shows its worksheet, not the refusal tint")
    @MainActor
    func anImportedPDFPageComposites() async throws {
        let scratch = try Scratch()
        let session = EditorSession(store: scratch.store, debounce: .milliseconds(10))
        await session.start()

        let root = session.pages.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        _ = try await session.importPDF(PDFFixture.quadrantPDF(rotate: 0))
        root.layoutIfNeeded()

        // Turn to the imported page the way a settled scroll does.
        let scroll = session.pages.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width, y: 0)
        session.pages.scrollViewDidEndDecelerating(scroll)
        root.layoutIfNeeded()

        let canvas = try #require(session.currentCanvas, "the imported page must be an editable canvas")
        let backdrop = try #require(canvas.backdrop, "a pdf-backed page carries a backdrop")
        let page = backdrop.pageLayerForTesting
        try await waitUntil("the worksheet composites") { page.contents != nil }
        #expect(page.backgroundColor == nil, "a composited page is its texture, not a tint")
    }

    @Test("An image imported onto a pdf-backed page composites with it")
    @MainActor
    func anImageOnAPDFPageComposites() async throws {
        let scratch = try Scratch()
        let session = EditorSession(store: scratch.store, debounce: .milliseconds(10))
        await session.start()

        let root = session.pages.view!
        root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        root.layoutIfNeeded()

        let imported = try await session.importPDF(PDFFixture.quadrantPDF(rotate: 0))
        let pageID = try #require(imported.first)
        root.layoutIfNeeded()

        let scroll = session.pages.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width, y: 0)
        session.pages.scrollViewDidEndDecelerating(scroll)
        root.layoutIfNeeded()

        let canvas = try #require(session.currentCanvas)
        let backdrop = try #require(canvas.backdrop)
        let page = backdrop.pageLayerForTesting
        try await waitUntil("the worksheet composites") { page.contents != nil }
        let before = page.contents as! CGImage

        _ = try await session.importImage(
            Scratch.solidPNG(width: 64, height: 64, color: .green),
            format: .png,
            sourceWidth: 64,
            sourceHeight: 64,
            onPage: pageID
        )
        try await waitUntil("the image recomposites over the worksheet") {
            page.contents != nil && (page.contents as! CGImage) !== before
        }
        #expect(page.backgroundColor == nil, "the image on a pdf page must never trip a refusal")
    }

    // MARK: - Helpers

    private func composited(
        _ renderer: StaticLayerRenderer,
        request: StaticLayerRequest
    ) async throws -> StaticComposite {
        let render = await renderer.composite(for: request)
        guard case .composited(let composite) = render else {
            throw CompositeFailure(render: "\(render)")
        }
        return composite
    }

    private struct CompositeFailure: Error, CustomStringConvertible {
        let render: String
        var description: String { "expected a composite, got \(render)" }
    }

    @MainActor
    private func waitUntil(
        _ what: String,
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    // MARK: Pixels — read the way StaticLayerRenderTests reads them

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("could not build a one-pixel context")
            return (0, 0, 0)
        }
        context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func near(_ value: Int, _ target: Int) -> Bool { abs(value - target) <= 12 }
    private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 255) && near(p.g, 0) && near(p.b, 0)
    }
    private func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 0) && near(p.g, 255) && near(p.b, 0)
    }
    private func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 0) && near(p.g, 0) && near(p.b, 255)
    }
    private func isYellow(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 255) && near(p.g, 255) && near(p.b, 0)
    }
    private func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 255) && near(p.g, 255) && near(p.b, 255)
    }

    // MARK: A scratch document

    private final class Scratch {
        let root: URL
        let store: DocumentStore

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tubernotes-pdfrender-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("JustACanvas.tubernotes/pages"),
                withIntermediateDirectories: true
            )
            store = DocumentStore(directoryURL: root.appendingPathComponent("JustACanvas.tubernotes"))
        }

        /// Writes PDF bytes as an asset and returns the pdf layer naming it.
        func pdfLayer(
            bytes: Data,
            sourcePageIndex: Int,
            transform: PageSpaceTransform
        ) async throws -> LayerEnvelope {
            let assetID = UUID()
            try await store.writeAsset(bytes, assetID: assetID, format: .pdf)
            return try LayerEnvelope.pdf(
                layerID: UUID(),
                ref: PDFLayerRef(assetID: assetID, sourcePageIndex: sourcePageIndex),
                pageSpaceTransform: transform
            )
        }

        func imageLayer(color: UIColor, transform: PageSpaceTransform) async throws -> LayerEnvelope {
            let assetID = UUID()
            try await store.writeAsset(
                Self.solidPNG(width: 64, height: 64, color: color), assetID: assetID, format: .png
            )
            return try LayerEnvelope.image(
                layerID: UUID(),
                ref: ImageLayerRef(assetID: assetID, format: .png),
                pageSpaceTransform: transform
            )
        }

        static func solidPNG(width: Int, height: Int, color: UIColor) -> Data {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                preconditionFailure("could not build a \(width)x\(height) context")
            }
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else {
                preconditionFailure("the context yielded no image")
            }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                out, "public.png" as CFString, 1, nil
            ) else {
                preconditionFailure("no PNG destination")
            }
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination), "PNG encoding failed")
            return out as Data
        }
    }
}
