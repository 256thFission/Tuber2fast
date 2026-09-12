import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PencilKit
import TNCore
import TNFormat
import TNModel

/// What one thumbnail was rendered from. `version` is the notebook's per-page
/// content version, so paper, geometry, layers, and ink are all folded into
/// one number and the key never names them.
package struct ThumbnailKey: Hashable, Sendable {
    package let page: PageID
    package let version: UInt64

    package init(page: PageID, version: UInt64) {
        self.page = page
        self.version = version
    }
}

/// One shape for every bounded in-memory cache in this project: values by
/// key, oldest evicted first once the byte total passes the bound. Each
/// instance still declares its owner, bound, and evictor where it is
/// declared, as the contract requires; this type is the mechanism, not the
/// declaration.
package struct BoundedCache<Key: Hashable, Value> {
    package let bound: Int
    package let cost: (Value) -> Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    package private(set) var bytes = 0

    package init(bound: Int, cost: @escaping (Value) -> Int) {
        self.bound = bound
        self.cost = cost
    }

    package subscript(key: Key) -> Value? { values[key] }

    package var count: Int { values.count }

    /// A key already present is replaced and becomes the newest.
    package mutating func insert(_ value: Value, for key: Key) {
        if let replaced = values.updateValue(value, forKey: key) {
            bytes -= cost(replaced)
            order.removeAll { $0 == key }
        }
        order.append(key)
        bytes += cost(value)
        while bytes > bound, let oldest = order.first {
            order.removeFirst()
            if let removed = values.removeValue(forKey: oldest) { bytes -= cost(removed) }
        }
    }

    package mutating func removeAll() {
        values.removeAll()
        order.removeAll()
        bytes = 0
    }
}

/// Composites and thumbnails, off the main actor. A composite is paper plus
/// every static layer as pixels; the ink is never in it.
///
/// Cache: decoded assets by reference. Owner: this actor. Bound:
/// `assetCacheBound` bytes, evicting oldest first. Evictor:
/// `BoundedCache.insert`, on insert, and `purge()` on memory pressure from
/// the app.
///
/// Cache: page thumbnails by `ThumbnailKey`. Owner: this actor, one per
/// notebook. Bound: `thumbnailCacheBound` bytes, evicting oldest first.
/// Evictor: `BoundedCache.insert`, on insert, and `purge()` on memory
/// pressure from the app.
package actor Renderer {
    package static let maximumLongEdgePixels: CGFloat = 2800
    package static let assetCacheBound = 48 * 1024 * 1024
    /// One value, so `ThumbnailKey` does not carry it. A US Letter thumbnail
    /// is 371 by 480 pixels, about 710 KB; the bound holds about 45.
    package static let thumbnailLongEdgePixels = 480
    package static let thumbnailCacheBound = 32 * 1024 * 1024

    private let assets: any AssetReading
    private var decoded = BoundedCache<AssetRef, DecodedAsset>(bound: Renderer.assetCacheBound, cost: \.bytes)
    private var thumbnails = BoundedCache<ThumbnailKey, CGImage>(bound: Renderer.thumbnailCacheBound, cost: { $0.bytesPerRow * $0.height })

    private enum DecodedAsset {
        case image(CGImage, bytes: Int)
        case pdf(PDFSource, bytes: Int)
        var bytes: Int {
            switch self {
            case .image(_, let bytes), .pdf(_, let bytes): bytes
            }
        }
    }

    package init(assets: any AssetReading) {
        self.assets = assets
    }

    package func purge() {
        decoded.removeAll()
        thumbnails.removeAll()
    }

    /// The scale that fits the long edge under the pixel cap, no more than
    /// `requested`.
    package static func cappedScale(for geometry: PageGeometry, requested: CGFloat) -> CGFloat {
        let longEdge = max(geometry.width, geometry.height)
        return min(requested, maximumLongEdgePixels / longEdge)
    }

    /// Paper and layers at `scale` pixels per point, capped.
    package func composite(geometry: PageGeometry, paper: Paper?, layers: [Layer], scale requested: CGFloat) async -> Composite? {
        let scale = Self.cappedScale(for: geometry, requested: requested)
        let width = Int((geometry.width * scale).rounded(.up)), height = Int((geometry.height * scale).rounded(.up))
        guard let image = await compose(geometry: geometry, paper: paper, layers: layers, scale: scale, width: width, height: height) else { return nil }
        return Composite(image: image)
    }

    /// Paper and layers into one bitmap of exactly `width` by `height`
    /// pixels, drawn at `scale`. A composite rounds the pixels up from its
    /// scale; a thumbnail picks its pixels first and derives the scale.
    private func compose(geometry: PageGeometry, paper: Paper?, layers: [Layer], scale: CGFloat, width: Int, height: Int) async -> CGImage? {
        guard width > 0, height > 0, let context = Self.bitmap(width: width, height: height) else { return nil }
        // Page space: origin top-left, y down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        await drawPage(geometry: geometry, paper: paper, layers: layers, ink: nil, in: context)
        return context.makeImage()
    }

    /// One page into a context already in page space: the white ground, the
    /// paper, every layer, and an ink raster if there is one. The one draw
    /// path, so a composite and an exported page cannot disagree — a
    /// composite passes no ink because the live canvas draws it, and an
    /// export passes the raster because a PDF page has no canvas over it.
    private func drawPage(geometry: PageGeometry, paper: Paper?, layers: [Layer], ink: CGImage?, in context: CGContext) async {
        let pageRect = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(pageRect)
        await draw(paper ?? .drawn(.blank), geometry: geometry, in: context)
        for layer in layers {
            await draw(layer, in: context)
        }
        guard let ink else { return }
        context.saveGState()
        // CGImage draws y-up; flip within the page rectangle, as asset paper does.
        context.translateBy(x: 0, y: geometry.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(ink, in: pageRect)
        context.restoreGState()
    }

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// The ink over the composite, pixel for pixel.
    private static func overlay(_ ink: CGImage?, on composite: CGImage) -> CGImage? {
        guard let ink else { return composite }
        guard let context = bitmap(width: composite.width, height: composite.height) else { return nil }
        let pixels = CGRect(x: 0, y: 0, width: composite.width, height: composite.height)
        context.draw(composite, in: pixels)
        context.draw(ink, in: pixels)
        return context.makeImage()
    }

    // MARK: Thumbnails

    /// The long edge is exactly `thumbnailLongEdgePixels`; the short edge is
    /// the rounded proportion.
    package static func thumbnailPixels(for geometry: PageGeometry) -> (width: Int, height: Int) {
        let long = thumbnailLongEdgePixels
        if geometry.width >= geometry.height {
            return (long, max(1, Int((Double(long) * geometry.height / geometry.width).rounded())))
        }
        return (max(1, Int((Double(long) * geometry.width / geometry.height).rounded())), long)
    }

    package func cachedThumbnail(_ key: ThumbnailKey) -> CGImage? { thumbnails[key] }

    /// The page rendered small: the compose step, then the ink rasterized in
    /// the caller's task, so a cell that scrolls away cancels the work it
    /// asked for. A cancelled render caches nothing.
    package func thumbnail(_ key: ThumbnailKey, geometry: PageGeometry, paper: Paper?, layers: [Layer], ink: PKDrawing) async -> CGImage? {
        if let hit = thumbnails[key] { return hit }
        let (width, height) = Self.thumbnailPixels(for: geometry)
        let scale = CGFloat(max(width, height)) / max(geometry.width, geometry.height)
        if Task.isCancelled { return nil }
        guard let composite = await compose(geometry: geometry, paper: paper, layers: layers, scale: scale, width: width, height: height) else { return nil }
        if Task.isCancelled { return nil }
        let pageRect = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        let inkImage = await Self.rasterize(ink, in: pageRect, scale: scale)
        if Task.isCancelled { return nil }
        guard let image = Self.overlay(inkImage, on: composite) else { return nil }
        thumbnails.insert(image, for: key)
        return image
    }

    /// PencilKit rasterizes the ink on the generic executor, in the caller's
    /// task: a thumbnail is droppable work, so it must inherit cancellation.
    private nonisolated static func rasterize(_ ink: PKDrawing, in rect: CGRect, scale: CGFloat) async -> CGImage? {
        ink.image(from: rect, scale: scale).cgImage
    }

    /// The page's paper. An asset fills the page rectangle exactly: the
    /// geometry was set from the asset's aspect when the paper was applied,
    /// so filling is not stretching.
    private func draw(_ paper: Paper, geometry: PageGeometry, in context: CGContext) async {
        switch paper {
        case .drawn(let drawn):
            PaperRenderer.draw(drawn, geometry: geometry, in: context)
        case .image(let ref):
            guard case .image(let image, _)? = await decodedAsset(ref) else { return }
            context.saveGState()
            // CGImage draws y-up; flip within the page rectangle.
            context.translateBy(x: 0, y: geometry.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height))
            context.restoreGState()
        case .pdf(let ref, let sourcePageIndex):
            guard case .pdf(let source, _)? = await decodedAsset(ref),
                  let page = source.page(at: sourcePageIndex),
                  let extent = PDFSource.displayExtent(of: page)
            else { return }
            context.saveGState()
            context.concatenate(CGAffineTransform(scaleX: geometry.width, y: geometry.height))
            PDFSource.draw(page, extent: extent, in: context)
            context.restoreGState()
        }
    }

    /// Height over width of an asset paper, from the decoded asset. Drawn
    /// paper has no aspect of its own.
    package func aspect(of paper: Paper) async -> Double? {
        switch paper {
        case .drawn:
            return nil
        case .image(let ref):
            guard case .image(let image, _)? = await decodedAsset(ref), image.width > 0 else { return nil }
            return Double(image.height) / Double(image.width)
        case .pdf(let ref, let sourcePageIndex):
            guard case .pdf(let source, _)? = await decodedAsset(ref),
                  let page = source.page(at: sourcePageIndex),
                  let extent = PDFSource.displayExtent(of: page), extent.width > 0
            else { return nil }
            return extent.height / extent.width
        }
    }

    /// A page's composite and its ink as one image at asset resolution: the
    /// long edge at `maximumLongEdgePixels`, which is what a flattened page
    /// becomes as paper. The page it renders is not changed.
    ///
    /// `type` is a UTI: `"public.heic"` for a flatten, which becomes an
    /// asset in the package, and `"public.png"` for a page exported as an
    /// image, which leaves the device lossless. One function, because the
    /// pixels are the same and only the encoder differs.
    package func flattened(geometry: PageGeometry, paper: Paper?, layers: [Layer], ink: PKDrawing, as type: CFString) async -> Data? {
        let scale = Self.cappedScale(for: geometry, requested: .greatestFiniteMagnitude)
        guard let composite = await composite(geometry: geometry, paper: paper, layers: layers, scale: scale) else { return nil }
        let pageRect = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        // PencilKit rasterizes the ink itself, off this actor and off the
        // main one: a flatten is an intention, never a frame.
        let inkImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            ink.image(from: pageRect, scale: scale).cgImage
        }.value
        guard let image = Self.overlay(inkImage, on: composite.image) else { return nil }
        return Self.encode(image, as: type)
    }

    /// The quality key is set for every type and read only by the lossy
    /// ones: PNG ignores it, HEIC uses it.
    private static func encode(_ image: CGImage, as type: CFString) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: Export

    /// One PDF of `pageCount` pages, each asked for in turn and drawn by the
    /// code a composite is drawn by: paper, text, and an imported PDF page
    /// are vector, the ink is a raster at the flatten scale. Pages are
    /// indexed from zero, as every index here is.
    ///
    /// The document and its data are locals, so there is no export state on
    /// this actor: it is reentrant at every `await page(n)`, and composites
    /// for the live canvas are served between pages. A page the source
    /// cannot give, or a cancellation between pages, returns nil — an export
    /// with a hole in it is worse than no export.
    ///
    /// Measured: one US Letter page carrying 300 strokes is 161 KB, so two
    /// hundred such pages are about 32 MB in one `Data` — inside an iPad's
    /// foreground budget, which is why the document is built in memory and
    /// no file is written. The ink raster is 2164 by 2800 pixels while the
    /// page is drawn, 24 MB, and is dropped with the page; the PDF's image
    /// stream is Flate-compressed and a handwriting page is almost entirely
    /// transparent. `RendererExportTests.aPageCostsWhatTheDocCommentSays`
    /// holds the number.
    package func pdf(
        pageCount: Int,
        page: @MainActor (Int) async -> (geometry: PageGeometry, paper: Paper?, layers: [Layer], ink: PKDrawing)?
    ) async -> Data? {
        guard pageCount > 0 else { return nil }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else { return nil }
        // The document's own box; each page names its own below, so this one
        // only has to be valid.
        var documentBox = CGRect(x: 0, y: 0, width: PageGeometry.letter.width, height: PageGeometry.letter.height)
        guard let context = CGContext(consumer: consumer, mediaBox: &documentBox, nil) else { return nil }
        for index in 0..<pageCount {
            if Task.isCancelled { return nil }
            guard let source = await page(index) else { return nil }
            let geometry = source.geometry
            var box = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
            let scale = Self.cappedScale(for: geometry, requested: .greatestFiniteMagnitude)
            // A drawing with no strokes still rasterizes to a full-page
            // transparent image, and a PDF context records that draw as an
            // Image XObject: pixels on a page that has none, which is what
            // "paper, text, and an imported PDF page are vector" promises
            // against. A bitmap does not care — a transparent overlay
            // changes no pixel — so `compose` and `thumbnail` are left as
            // they are.
            let inkImage = source.ink.strokes.isEmpty ? nil : await Self.rasterize(source.ink, in: box, scale: scale)
            if Task.isCancelled { return nil }
            context.beginPage(mediaBox: &box)
            // Page space: origin top-left, y down, in points.
            context.translateBy(x: 0, y: geometry.height)
            context.scaleBy(x: 1, y: -1)
            await drawPage(geometry: geometry, paper: source.paper, layers: source.layers, ink: inkImage, in: context)
            context.endPage()
        }
        if Task.isCancelled { return nil }
        context.closePDF()
        return output as Data
    }

    private func draw(_ layer: Layer, in context: CGContext) async {
        let t = layer.transform
        let affine = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
        switch layer.payload {
        case .image(let image):
            guard case .image(let cgImage, _)? = await decodedAsset(image.asset) else { return }
            context.saveGState()
            context.concatenate(affine)
            // CGImage draws y-up; flip inside the unit square.
            context.translateBy(x: 0, y: 1)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            context.restoreGState()
        case .pdf(let pdf):
            guard case .pdf(let source, _)? = await decodedAsset(pdf.asset), let page = source.page(at: pdf.sourcePageIndex) else { return }
            guard PDFSource.displayExtent(of: page) == pdf.sourceExtent else {
                TNLog.event(.format, "pdf layer \(layer.id) extent disagrees with the asset; not drawn")
                return
            }
            context.saveGState()
            context.concatenate(affine)
            PDFSource.draw(page, extent: pdf.sourceExtent, in: context)
            context.restoreGState()
        case .link(let link):
            let rect = CGRect(x: link.rect.x, y: link.rect.y, width: link.rect.width, height: link.rect.height)
            context.saveGState()
            context.setFillColor(CGColor(srgbRed: 0.17, green: 0.44, blue: 0.76, alpha: 0.15))
            context.setStrokeColor(CGColor(srgbRed: 0.17, green: 0.44, blue: 0.76, alpha: 1))
            context.setLineWidth(1)
            let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            context.addPath(path); context.fillPath()
            context.addPath(path); context.strokePath()
            context.restoreGState()
            Self.drawText(TextLayer(rect: link.rect, runs: [TextRun(string: "Link", size: 13, color: "#2B70C2FF")], alignment: .center), in: context)
        case .text(let text):
            Self.drawText(text, in: context)
        }
    }

    /// One builder with the live text view, so the two engines lay the same
    /// runs on the same lines, and one placement rule, so the baselines
    /// agree. The box is the rect with no inset; the overlay copies that
    /// geometry.
    private static func drawText(_ text: TextLayer, in context: CGContext) {
        let attributed = TextTypesetting.attributed(text.runs, alignment: text.alignment)
        let rect = CGRect(x: text.rect.x, y: text.rect.y, width: text.rect.width, height: text.rect.height)
        context.saveGState()
        context.clip(to: rect)
        // CoreText draws y-up; flip within the rect.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        for placed in TextTypesetting.placedLines(attributed, width: rect.width) {
            context.textPosition = CGPoint(x: placed.x, y: rect.height - placed.baseline)
            CTLineDraw(placed.line, context)
        }
        context.restoreGState()
    }

    private func decodedAsset(_ ref: AssetRef) async -> DecodedAsset? {
        if let cached = decoded[ref] { return cached }
        let data: Data
        do { data = try await assets.readAsset(ref) } catch { return nil }
        let asset: DecodedAsset
        switch ref.format {
        case .heic:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
            else { return nil }
            asset = .image(image, bytes: image.bytesPerRow * image.height)
        case .pdf:
            guard let source = PDFSource(data: data) else { return nil }
            asset = .pdf(source, bytes: data.count)
        }
        decoded.insert(asset, for: ref)
        return asset
    }
}

/// Import-time normalization: any image becomes an upright HEIC with its
/// pixel size known; a PDF is kept as received and its pages measured.
package enum ImageImport {
    package struct Normalized: Sendable {
        package let heic: Data
        package let size: PixelSize
    }

    package static func normalize(_ data: Data) -> Normalized? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        // Orientation: bake it in so the stored pixels are upright.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let upright = Self.upright(image, orientation: orientation) ?? image
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, upright, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Normalized(heic: output as Data, size: PixelSize(width: upright.width, height: upright.height))
    }

    private static func upright(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        guard orientation != .up else { return image }
        let rotated = [CGImagePropertyOrientation.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let width = rotated ? image.height : image.width, height = rotated ? image.width : image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        switch orientation {
        case .down, .downMirrored: context.rotate(by: .pi)
        case .left, .leftMirrored: context.rotate(by: .pi / 2)
        case .right, .rightMirrored: context.rotate(by: -.pi / 2)
        default: break
        }
        if [.upMirrored, .downMirrored, .leftMirrored, .rightMirrored].contains(orientation) { context.scaleBy(x: -1, y: 1) }
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }
}
