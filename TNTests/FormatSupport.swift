import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import TNFormat
@testable import TNModel

/// A scratch directory per test, deleted when the value goes away.
final class Scratch: Sendable {
    let root: URL

    init(_ name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tn-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var packageURL: URL { root.appendingPathComponent("Scratch.tubernotes", isDirectory: true) }

    func copyPackage(to name: String) throws -> URL {
        let destination = root.appendingPathComponent("\(name).tubernotes", isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: packageURL, to: destination)
        return destination
    }

    func backdate(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }
}

enum Fixture {
    static func archive(_ seed: UInt8, count: Int = 2048) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: Int($0) &* 7 &+ Int(seed)) })
    }

    static func index(
        pages: Int, notebookID: NotebookID = NotebookID(), bookmarks: [PageBookmark] = []
    ) -> NotebookIndex {
        NotebookIndex(
            notebookID: notebookID,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            pages: (0..<pages).map { _ in PageRecord(id: PageID(), geometry: .letter, paper: .drawn(.lined)) },
            bookmarks: bookmarks
        )
    }

    /// A PDF of `pages` pages, each `width` by `height` points.
    static func pdfData(pages: Int, width: Double = 400, height: Double = 600) throws -> Data {
        let output = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: output))
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in 0..<pages {
            context.beginPage(mediaBox: &box)
            context.setFillColor(CGColor(srgbRed: 0.2 + 0.1 * Double(page), green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: width - 40, height: height - 40))
            context.endPage()
        }
        context.closePDF()
        return output as Data
    }

    /// A PDF of blank pages the shapes `pdfData` cannot make: one page per
    /// size, a size of zero being a page with an empty box, each turned by
    /// `rotation` degrees and cropped to `cropBox` when one is given.
    /// CoreGraphics writes the pages, because PDFKit will not write an empty
    /// media box; PDFKit turns and crops them, because CoreGraphics cannot
    /// write a rotation.
    static func shapedPDF(sizes: [CGSize], rotation: Int = 0, cropBox: CGRect? = nil) throws -> Data {
        let output = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: output))
        let context = try #require(CGContext(consumer: consumer, mediaBox: nil, nil))
        for size in sizes {
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.endPage()
        }
        context.closePDF()
        guard rotation != 0 || cropBox != nil else { return output as Data }
        let document = try #require(PDFDocument(data: output as Data))
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            page.rotation = rotation
            if let cropBox { page.setBounds(cropBox, for: .cropBox) }
        }
        return try #require(document.dataRepresentation())
    }

    /// A PNG of the given pixel size, for the image-import path to normalize.
    static func imageData(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func imageLayer(asset: AssetRef = AssetRef(id: AssetID(), format: .heic)) -> Layer {
        Layer(
            id: LayerID(),
            transform: .placing(sourceWidth: 300, sourceHeight: 200, at: (10, 20), scale: 1),
            payload: .image(ImageLayer(asset: asset, naturalSize: PixelSize(width: 300, height: 200)))
        )
    }

    static func pdfLayer(asset: AssetRef = AssetRef(id: AssetID(), format: .pdf)) -> Layer {
        Layer(
            id: LayerID(),
            transform: .placing(sourceWidth: 612, sourceHeight: 792, at: (0, 0), scale: 1),
            payload: .pdf(PDFLayer(asset: asset, sourcePageIndex: 0, sourceExtent: SourceExtent(x: 0, y: 0, width: 612, height: 792, rotation: 0)))
        )
    }

    static func textLayer() -> Layer {
        Layer(
            id: LayerID(),
            transform: .identity,
            payload: .text(TextLayer(
                rect: PageRect(x: 30, y: 30, width: 300, height: 80),
                runs: [
                    TextRun(string: "Hello, ", style: .body),
                    TextRun(string: "world", style: .body.with(bold: true, color: RGBA8(red: 0x19, green: 0x71, blue: 0xC2, alpha: 0xFF))),
                ],
                alignment: .leading))
        )
    }

    static func linkLayer(to page: PageID) -> Layer {
        Layer(
            id: LayerID(),
            transform: .identity,
            payload: .link(LinkLayer(rect: PageRect(x: 40, y: 40, width: 160, height: 44), target: .internalPage(page)))
        )
    }

    /// A three-page notebook: page 0 with ink, page 1 with an image layer and
    /// ink, page 2 blank. Returns the store and the index it committed.
    static func populated(at url: URL, fileSystem: any PackageFileSystem = PosixFileSystem()) async throws -> (PackageStore, NotebookIndex, Layer) {
        let index = index(pages: 3)
        let store = try await PackageStore.create(root: url, index: index, fileSystem: fileSystem)
        let layer = imageLayer()
        try await store.writeAsset(archive(9, count: 512), layer.payload.asset!)
        let ids = index.pageIDs
        let batch = SaveBatch(index: index, indexChanged: false, pages: [
            PageWrite(file: PageFile(pageID: ids[0], hasInk: true, layers: []), ink: .archive(archive(1)), layerFiles: []),
            PageWrite(file: PageFile(pageID: ids[1], hasInk: true, layers: [layer.id]), ink: .archive(archive(2)), layerFiles: [layer]),
        ])
        let report = try await store.save(batch)
        try #require(report.refusals.isEmpty)
        return (store, index, layer)
    }
}

/// The mean of one pixel's three channels: 255 is white paper, a stroke is dark.
func luminance(of image: CGImage, x: Int, y: Int) -> Int {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return (Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])) / 3
}

/// An exported page drawn back into a bitmap, white ground, `scale`
/// pixels per point. A CGImage's first row is the top of the page.
func rasterized(_ page: CGPDFPage, scale: Double) throws -> CGImage {
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

/// A PNG drawn into the four-byte layout `luminance(of:x:y:)` reads,
/// whatever layout the file decodes to.
func redrawn(png data: Data) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let context = try #require(CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return try #require(context.makeImage())
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// The key set of every object in a JSON tree, by where it sits: keys
/// joined by `.`, `[]` for an array's elements, and `(name)` after an object
/// that names its own `kind` or `scope`, because that name decides its keys.
/// The paths the key-set pins are written at.
func keySets(of node: Any, at path: String) -> [(path: String, keys: Set<String>)] {
    switch node {
    case let object as [String: Any]:
        let here = ((object["kind"] ?? object["scope"]) as? String).map { "\(path)(\($0))" } ?? path
        return [(here, Set(object.keys))] + object.flatMap { keySets(of: $0.value, at: "\(here).\($0.key)") }
    case let array as [Any]:
        return array.flatMap { keySets(of: $0, at: "\(path)[]") }
    default:
        return []
    }
}
