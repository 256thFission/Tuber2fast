import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook
@testable import TNRender

/// A sticker is a photo insert from a different source. These prove the
/// source and that the insert is the same one.
@Suite("Stickers")
@MainActor
struct StickerTests {
    @Test("Every catalogued sticker renders, normalizes to HEIC, and keeps its transparent corner")
    func everyStickerDecodes() throws {
        #expect(StickerCatalogue.all.count >= 12 && StickerCatalogue.all.count <= 24)
        #expect(Set(StickerCatalogue.all.map(\.symbol)).count == StickerCatalogue.all.count, "no symbol twice")
        for sticker in StickerCatalogue.all {
            let png = try #require(StickerCatalogue.png(sticker), "\(sticker.symbol) has no render")
            let normalized = try #require(ImageImport.normalize(png), "\(sticker.symbol) did not normalize")
            #expect(normalized.size == PixelSize(width: StickerCatalogue.edgePixels, height: StickerCatalogue.edgePixels))
            let heic = try #require(Self.decode(normalized.heic), "\(sticker.symbol)'s HEIC did not decode")
            #expect(Self.alpha(at: (0, 0), in: heic) == 0, "\(sticker.symbol): the corner is paper, not white")
            let centre = StickerCatalogue.edgePixels / 2
            let anyInk = [(centre, centre), (centre, centre / 2), (centre, centre * 3 / 2)]
                .contains { Self.alpha(at: $0, in: heic) > 0 }
            #expect(anyInk, "\(sticker.symbol): nothing was drawn")
        }
    }

    @Test("Inserting a sticker is a photo insert: the same layer kind, format and undo entry, at a quarter of the page")
    func stickerInsertIsAnImageInsert() async throws {
        let scratch = try Scratch("sticker-insert")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let editor = EditorViewModel(binding: binding, palette: ToolPalette(store: MemoryPaletteStore()))
        let page = notebook.pageIDs[0]
        binding.windowChanged(to: [page])
        try await waitUntil { surface.installed.contains(page) }

        await editor.importImage(try Fixture.imageData(width: 512, height: 512))
        await editor.importSticker(StickerCatalogue.all[0])
        #expect(editor.lastContentError == nil)
        let layers = try #require(notebook.state(of: page)?.content?.layers)
        #expect(layers.count == 2)
        let photo = layers[0], sticker = layers[1]
        guard case .image(let photoImage) = photo.payload, case .image(let stickerImage) = sticker.payload else {
            Issue.record("both inserts are image layers")
            return
        }
        #expect(stickerImage.asset.format == photoImage.asset.format)
        #expect(stickerImage.naturalSize == photoImage.naturalSize, "both sources are 512 square")
        #expect(sticker.locked == photo.locked)
        #expect(sticker.transform.b == 0 && sticker.transform.c == 0, "upright, like the photo")

        let geometry = try #require(notebook.index.record(of: page)?.geometry)
        let edge = min(geometry.width, geometry.height) * EditorViewModel.stickerFraction
        #expect(abs(sticker.transform.a - edge) < 1e-9 && abs(sticker.transform.d - edge) < 1e-9)
        #expect(abs(sticker.transform.tx + edge / 2 - geometry.width / 2) < 1e-9, "centred")
        #expect(abs(sticker.transform.ty + edge / 2 - geometry.height / 2) < 1e-9, "centred")
        #expect(photo.transform.a > sticker.transform.a, "a photo takes more of the page")

        let store = PackageStore(root: scratch.packageURL)
        let bytes = try await store.readAsset(stickerImage.asset)
        #expect(ImageImport.normalize(bytes) != nil, "the asset is written before the layer names it")

        #expect(notebook.canUndo)
        #expect(notebook.undo() == page)
        #expect(notebook.state(of: page)?.content?.layers.map(\.id) == [photo.id], "one entry per insert")
        _ = await notebook.close()
    }

    @Test("The binding answers a sticker with the composite that carries the layer, and refuses one under an open text box")
    func bindingSeesTheSticker() async throws {
        let scratch = try Scratch("sticker-binding")
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let editor = EditorViewModel(binding: binding, palette: ToolPalette(store: MemoryPaletteStore()))
        let page = notebook.pageIDs[0]
        binding.windowChanged(to: [page])
        try await waitUntil { surface.installed.contains(page) }

        await editor.importSticker(StickerCatalogue.all[1])
        let inserted = try #require(notebook.state(of: page)?.content?.layers.first?.id)
        try await waitUntil { surface.layersSeen[page]?.map(\.id) == [inserted] }
        #expect(binding.layerTransformed(on: page, layer: inserted, to: .placing(sourceWidth: 512, sourceHeight: 512, at: (10, 10), scale: 0.1)) == .accepted,
                "the frame moves it as it moves a photo")

        binding.textBoxRequested(on: page, at: PagePoint(x: 30, y: 40), style: .body, alignment: .leading)
        await editor.importSticker(StickerCatalogue.all[2])
        #expect(editor.lastContentError != nil)
        #expect(notebook.state(of: page)?.content?.layers.filter { if case .image = $0.payload { true } else { false } }.count == 1,
                "nothing was inserted under the box")
        _ = await notebook.close()
    }

    // MARK: Pixels

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The alpha byte of one pixel, read through an RGBA8 context so the
    /// decoder's own layout does not matter.
    private static func alpha(at point: (x: Int, y: Int), in image: CGImage) -> UInt8 {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -point.x, y: -(image.height - 1 - point.y), width: image.width, height: image.height))
        return pixel[3]
    }
}
