import CoreGraphics
import Foundation
import PDFKit
import PencilKit
import Testing
@testable import TNFormat
@testable import TNModel
@testable import TNRender

/// A renderer over no assets: drawn paper and ink need none.
private struct NoAssets: AssetReading {
    func readAsset(_ ref: AssetRef) async throws(FormatFault) -> Data { throw .invalidWrite("no assets") }
}

@Suite("Renderer: thumbnails and the bounded caches")
struct RendererTests {
    private let letter = PageGeometry.letter
    private let landscape = PageGeometry(width: 792, height: 612)

    @Test("A thumbnail's long edge is exactly the constant, portrait and landscape")
    func longEdgeIsExact() async throws {
        let renderer = Renderer(assets: NoAssets())
        let long = Renderer.thumbnailLongEdgePixels
        let portrait = try #require(await renderer.thumbnail(ThumbnailKey(page: PageID(), version: 1), geometry: letter, paper: .drawn(.blank), layers: [], ink: PKDrawing()))
        #expect(portrait.height == long && portrait.width == 371)
        let wide = try #require(await renderer.thumbnail(ThumbnailKey(page: PageID(), version: 1), geometry: landscape, paper: .drawn(.blank), layers: [], ink: PKDrawing()))
        #expect(wide.width == long && wide.height == 371)
        #expect(Renderer.thumbnailPixels(for: letter) == (371, 480))
    }

    @Test("A stroke is dark at the stroke and the paper is white away from it")
    func inkLandsWhereDrawn() async throws {
        let renderer = Renderer(assets: NoAssets())
        let image = try #require(await renderer.thumbnail(
            ThumbnailKey(page: PageID(), version: 1), geometry: letter, paper: .drawn(.blank), layers: [], ink: Ink.drawing(strokes: 1)))
        // The fixture stroke runs from x 10 to 70 at y 10, in page points.
        let scale = Double(image.height) / letter.height
        #expect(luminance(of: image, x: Int(40 * scale), y: Int(10 * scale)) < 128)
        #expect(luminance(of: image, x: image.width / 2, y: image.height / 2) == 255)
    }

    @Test("A cached thumbnail hits on its key and misses on another version")
    func cacheHitsOnKey() async throws {
        let renderer = Renderer(assets: NoAssets())
        let page = PageID()
        let key = ThumbnailKey(page: page, version: 3)
        #expect(await renderer.cachedThumbnail(key) == nil)
        let rendered = try #require(await renderer.thumbnail(key, geometry: letter, paper: .drawn(.blank), layers: [], ink: PKDrawing()))
        #expect(await renderer.cachedThumbnail(key) === rendered)
        #expect(await renderer.cachedThumbnail(ThumbnailKey(page: page, version: 4)) == nil)
        await renderer.purge()
        #expect(await renderer.cachedThumbnail(key) == nil)
    }

    @Test("A cancelled render caches nothing")
    func cancelledRenderCachesNothing() async throws {
        let renderer = Renderer(assets: NoAssets())
        let key = ThumbnailKey(page: PageID(), version: 1)
        let geometry = letter
        let task = Task { await renderer.thumbnail(key, geometry: geometry, paper: .drawn(.blank), layers: [], ink: PKDrawing()) }
        task.cancel()
        #expect(await task.value == nil)
        #expect(await renderer.cachedThumbnail(key) == nil)
    }

    @Test("Eviction is oldest first, to the byte bound; a replaced key becomes newest")
    func boundedCacheEvictsOldest() {
        var cache = BoundedCache<String, Int>(bound: 10, cost: { $0 })
        cache.insert(4, for: "a")
        cache.insert(4, for: "b")
        cache.insert(4, for: "c")
        #expect(cache["a"] == nil && cache["b"] == 4 && cache["c"] == 4)
        #expect(cache.bytes == 8)
        cache.insert(2, for: "b")
        #expect(cache.bytes == 6)
        cache.insert(4, for: "d")
        #expect(cache["c"] == 4, "exactly at the bound is not over it")
        cache.insert(1, for: "e")
        #expect(cache["c"] == nil, "b was refreshed, so c is the oldest")
        #expect(cache["b"] == 2 && cache["d"] == 4 && cache["e"] == 1)
        #expect(cache.bytes == 7, "eviction stops once under the bound")
        cache.removeAll()
        #expect(cache.count == 0 && cache.bytes == 0)
    }
}

/// A gate for the export tests: the source closure stops at a page and the
/// test decides when it may go on.
private actor Reached {
    private(set) var index = -1
    private var open = false
    func mark(_ index: Int) { self.index = index }
    func release() { open = true }
    func isOpen() -> Bool { open }
}

@Suite("Renderer: export")
struct RendererExportTests {
    private let letter = PageGeometry.letter
    private let landscape = PageGeometry(width: 792, height: 612)

    private func document(_ data: Data) throws -> CGPDFDocument {
        try #require(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
    }

    /// The `Subtype` of every XObject in a page's resources: `Form` is a
    /// vector drawing, `Image` is pixels. Empty means the page is paths and
    /// text alone.
    private func xobjectSubtypes(of page: CGPDFPage) -> [String] {
        final class Found { var names: [String] = [] }
        guard let dictionary = page.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return [] }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return [] }
        let found = Found()
        CGPDFDictionaryApplyFunction(xobjects, { _, object, info in
            guard let info else { return }
            let found = Unmanaged<Found>.fromOpaque(info).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let streamDictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<Int8>?
            if CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype {
                found.names.append(String(cString: subtype))
            }
        }, Unmanaged.passUnretained(found).toOpaque())
        return found.names
    }

    /// An exported page drawn back into a bitmap, white ground, `scale`
    /// pixels per point. A CGImage's first row is the top of the page.
    private func rasterized(_ page: CGPDFPage, scale: Double) throws -> CGImage {
        let box = page.getBoxRect(.mediaBox)
        let context = try #require(CGContext(
            data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)
        return try #require(context.makeImage())
    }

    @Test("Two pages are two PDF pages, each with its own geometry as its media box")
    func pagesCarryTheirGeometry() async throws {
        let renderer = Renderer(assets: NoAssets())
        let geometries = [letter, landscape]
        let data = try #require(await renderer.pdf(pageCount: 2) { index in
            (geometries[index], .drawn(.lined), [], PKDrawing())
        })
        let document = try document(data)
        #expect(document.numberOfPages == 2)
        for (index, geometry) in geometries.enumerated() {
            let box = try #require(document.page(at: index + 1)).getBoxRect(.mediaBox)
            #expect(box.width == geometry.width && box.height == geometry.height)
        }
    }

    @Test("Text exports as text, not as a picture of text")
    func textIsVector() async throws {
        let renderer = Renderer(assets: NoAssets())
        let data = try #require(await renderer.pdf(pageCount: 1) { _ in
            (self.letter, .drawn(.blank), [Fixture.textLayer()], PKDrawing())
        })
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let text = page.string ?? ""
        #expect(text.contains("Hello"), "the fixture's first run, extracted from the PDF: \(text)")
        #expect(text.contains("world"), "the fixture's second run, extracted from the PDF: \(text)")
    }

    @Test("A stroke is dark at the stroke and the paper is white away from it")
    func inkLandsWhereDrawn() async throws {
        let renderer = Renderer(assets: NoAssets())
        let data = try #require(await renderer.pdf(pageCount: 1) { _ in
            (self.letter, .drawn(.blank), [], Ink.drawing(strokes: 1))
        })
        let page = try #require(try document(data).page(at: 1))
        let scale = 2.0
        let image = try rasterized(page, scale: scale)
        // The fixture stroke runs from x 10 to 70 at y 10, in page points from
        // the top; a CGImage's first row is the top of the page.
        #expect(luminance(of: image, x: Int(40 * scale), y: Int(10 * scale)) < 128)
        #expect(luminance(of: image, x: image.width / 2, y: image.height / 2) == 255)
        #expect(xobjectSubtypes(of: page) == ["Image"], "the ink, and only the ink, is pixels")
    }

    @Test("A lined page with no ink and no layers carries no pixels at all")
    func drawnPaperIsPaths() async throws {
        let renderer = Renderer(assets: NoAssets())
        let data = try #require(await renderer.pdf(pageCount: 1) { _ in
            (self.letter, .drawn(.lined), [], PKDrawing())
        })
        let page = try #require(try document(data).page(at: 1))
        #expect(xobjectSubtypes(of: page).isEmpty)
    }

    /// `drawPDFPage` into a PDF context inlines the source page's marks
    /// rather than wrapping them in a form, so the proof that the paper
    /// survived is two halves: its marks are on the page, and there is no
    /// `Image` among the page's XObjects.
    @Test("An imported PDF page stays vector when it is exported again")
    func pdfPaperStaysVector() async throws {
        let scratch = try Scratch("render-export-pdf-paper")
        let store = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1))
        let asset = AssetRef(id: AssetID(), format: .pdf)
        try await store.writeAsset(try Fixture.pdfData(pages: 1), asset)
        let renderer = Renderer(assets: store)
        let data = try #require(await renderer.pdf(pageCount: 1) { _ in
            (self.letter, .pdf(asset, sourcePageIndex: 0), [], PKDrawing())
        })
        let page = try #require(try document(data).page(at: 1))
        #expect(!xobjectSubtypes(of: page).contains("Image"), "the imported page was rasterized: \(xobjectSubtypes(of: page))")
        // The fixture fills all but a 20-point margin of its own page with
        // one colour, and the paper fills the page rectangle exactly.
        let image = try rasterized(page, scale: 1)
        #expect(luminance(of: image, x: image.width / 2, y: image.height / 2) < 200, "the imported page's marks are on the exported page")
        withExtendedLifetime(scratch) {}
    }

    @Test("A page the source cannot give refuses the whole export")
    func aMissingPageRefuses() async throws {
        let renderer = Renderer(assets: NoAssets())
        let data = await renderer.pdf(pageCount: 3) { index in
            index == 1 ? nil : (self.letter, .drawn(.blank), [], PKDrawing())
        }
        #expect(data == nil, "an export with a hole in it is worse than no export")
    }

    @Test("A cancel between pages returns nothing")
    func cancelBetweenPagesReturnsNil() async throws {
        let renderer = Renderer(assets: NoAssets())
        let reached = Reached()
        let geometry = letter
        let task = Task {
            await renderer.pdf(pageCount: 2) { index in
                await reached.mark(index)
                if index == 0 {
                    while await !reached.isOpen() { try? await Task.sleep(for: .milliseconds(5)) }
                }
                return (geometry, .drawn(.blank), [], PKDrawing())
            }
        }
        while await reached.index != 0 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await reached.release()
        #expect(await task.value == nil)
    }

    @Test("One page as a PNG carries the ink")
    func pageAsPNG() async throws {
        let renderer = Renderer(assets: NoAssets())
        let data = try #require(await renderer.flattened(
            geometry: letter, paper: .drawn(.blank), layers: [], ink: Ink.drawing(strokes: 1), as: "public.png" as CFString))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let scale = Double(image.height) / letter.height
        let redrawn = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        redrawn.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let flat = try #require(redrawn.makeImage())
        #expect(luminance(of: flat, x: Int(40 * scale), y: Int(10 * scale)) < 128)
    }

    /// The number in `pdf`'s doc comment. A page is mostly transparent ink
    /// over a Flate-compressed image stream, so it is far smaller than the
    /// 24 MB raster it was drawn from; if this fails, the doc comment and
    /// the arithmetic behind "two hundred pages fit in memory" are both
    /// wrong.
    @Test("One Letter page of a few hundred strokes is a small number of kilobytes")
    func aPageCostsWhatTheDocCommentSays() async throws {
        let renderer = Renderer(assets: NoAssets())
        let data = try #require(await renderer.pdf(pageCount: 1) { _ in
            (self.letter, .drawn(.lined), [], Ink.drawing(strokes: 300))
        })
        #expect(data.count < 400 * 1024, "one page is \(data.count) bytes")
    }
}
