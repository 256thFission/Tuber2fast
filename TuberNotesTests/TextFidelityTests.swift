import CoreGraphics
import Foundation
import Testing
@testable import TNCanvas
@testable import TNFormat
@testable import TNModel
@testable import TNRender
import UIKit

/// The two engines must lay the same runs on the same lines at the same
/// baselines, or text jumps at begin and at commit. This is the whole of
/// the plan's evidence for the single builder: per-line ink bounds within
/// one pixel, per-run colour exactly.
@Suite("Text fidelity: the renderer and the live text view agree")
@MainActor
struct TextFidelityTests {
    private struct NoAssets: AssetReading {
        func readAsset(_ ref: AssetRef) async throws(FormatFault) -> Data { throw .invalidWrite("no assets here") }
    }

    private static let red = RGBA8(red: 200, green: 0, blue: 0, alpha: 255)
    private static let blue = RGBA8(red: 0, green: 0, blue: 200, alpha: 255)

    private static func style(_ size: Double, bold: Bool = false, italic: Bool = false, underline: Bool = false, color: RGBA8 = TextStyle.body.color) -> TextStyle {
        TextStyle(font: .system, size: size, bold: bold, italic: italic, underline: underline, color: color)
    }

    private static let fixtures: [(name: String, layer: TextLayer)] = [
        ("wrapping paragraph", TextLayer(
            rect: PageRect(x: 40, y: 40, width: 220, height: 200),
            runs: [TextRun(string: "The quick brown fox jumps over the lazy dog and keeps going past the edge of the box.", style: style(16))],
            alignment: .leading)),
        ("mixed sizes and colours on one line", TextLayer(
            rect: PageRect(x: 40, y: 300, width: 400, height: 80),
            runs: [TextRun(string: "small ", style: style(12, color: red)), TextRun(string: "BIG ", style: style(28, color: blue)), TextRun(string: "bold", style: style(18, bold: true))],
            alignment: .leading)),
        ("centered", TextLayer(rect: PageRect(x: 40, y: 400, width: 300, height: 60), runs: [TextRun(string: "centered line", style: style(16))], alignment: .center)),
        ("trailing", TextLayer(rect: PageRect(x: 40, y: 480, width: 300, height: 60), runs: [TextRun(string: "trailing line", style: style(16))], alignment: .trailing)),
        ("trailing newline", TextLayer(rect: PageRect(x: 40, y: 560, width: 300, height: 80), runs: [TextRun(string: "line one\nline two\n", style: style(16))], alignment: .leading)),
        // No descenders on this line, so the underline is the only ink below
        // the baseline and its presence shows as extra rows.
        ("underlined run", TextLayer(rect: PageRect(x: 40, y: 660, width: 300, height: 60), runs: [TextRun(string: "small ", style: style(16)), TextRun(string: "underlined", style: style(16, underline: true, color: red))], alignment: .leading)),
    ]

    @Test("Per-line ink bounds agree within a pixel and per-run colours exactly, for every fixture")
    func enginesAgree() async throws {
        let scale: CGFloat = 2
        let geometry = PageGeometry.letter
        let renderer = Renderer(assets: NoAssets())
        let layers = Self.fixtures.map { Layer(id: LayerID(), transform: .identity, payload: .text($0.layer)) }
        let composite = try #require(await renderer.composite(geometry: geometry, paper: .drawn(.blank), layers: layers, scale: scale))
        // The requested scale is under the pixel cap, so the picture is the
        // page at exactly that many pixels per point.
        #expect(composite.image.width == Int((geometry.width * scale).rounded(.up)))

        // The underline's extent is each engine's own (KNOWN DEFECT at
        // TextTypesetting), so glyph bounds are compared on the plain run,
        // and the underlined fixture only has to show more ink below than
        // its plain twin in both engines.
        let plainTwins = Self.fixtures.filter { $0.layer.runs.contains(where: \.underline) }.map { fixture in
            (fixture.name, TextLayer(
                rect: fixture.layer.rect,
                runs: fixture.layer.runs.map { run in
                    let style = run.style
                    return TextRun(string: run.string, style: TextStyle(font: style.font, size: style.size, bold: style.bold, italic: style.italic, underline: false, color: style.color))
                },
                alignment: fixture.layer.alignment))
        }
        let plainLayers = plainTwins.map { Layer(id: LayerID(), transform: .identity, payload: .text($0.1)) }
        let plainComposite = try #require(await renderer.composite(geometry: geometry, paper: .drawn(.blank), layers: plainLayers, scale: scale))

        for fixture in Self.fixtures {
            let rect = fixture.layer.rect
            let region = CGRect(x: rect.x * scale, y: rect.y * scale, width: rect.width * scale, height: rect.height * scale)
            let rendered = try Self.pixels(of: composite.image, region: region)
            let live = try Self.overlayPixels(fixture.layer, scale: scale)
            var renderedLines = Self.inkLines(rendered)
            var liveLines = Self.inkLines(live)
            if let plain = plainTwins.first(where: { $0.0 == fixture.name })?.1 {
                let plainRendered = Self.inkLines(try Self.pixels(of: plainComposite.image, region: region))
                let plainLive = Self.inkLines(try Self.overlayPixels(plain, scale: scale))
                #expect(
                    (renderedLines.last?.bottom ?? 0) > (plainRendered.last?.bottom ?? 0) && (liveLines.last?.bottom ?? 0) > (plainLive.last?.bottom ?? 0),
                    "\(fixture.name): the underline adds ink below the glyphs in both engines (renderer \(renderedLines) vs \(plainRendered); text view \(liveLines) vs \(plainLive))"
                )
                renderedLines = plainRendered
                liveLines = plainLive
            }
            #expect(renderedLines.count == liveLines.count, "\(fixture.name): renderer has \(renderedLines.count) lines, text view has \(liveLines.count)")
            for (index, pair) in zip(renderedLines, liveLines).enumerated() {
                #expect(
                    abs(pair.0.top - pair.1.top) <= 1 && abs(pair.0.bottom - pair.1.bottom) <= 1
                        && abs(pair.0.left - pair.1.left) <= 1 && abs(pair.0.right - pair.1.right) <= 1,
                    "\(fixture.name), line \(index): renderer \(pair.0), text view \(pair.1)"
                )
            }
            let colours = Set(fixture.layer.runs.map(\.style.color.hex))
            #expect(
                Self.coloursFound(rendered, among: colours) == Self.coloursFound(live, among: colours),
                "\(fixture.name): renderer shows \(Self.coloursFound(rendered, among: colours).sorted()), text view \(Self.coloursFound(live, among: colours).sorted())"
            )
        }
    }

    // MARK: - Pixels

    struct Pixels {
        let width: Int
        let height: Int
        /// Premultiplied RGBA, row-major.
        let bytes: [UInt8]
        func at(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let offset = (y * width + x) * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
        /// Ink is anything that is neither transparent nor white.
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let p = at(x, y)
            return p.a > 8 && (p.r < 247 || p.g < 247 || p.b < 247)
        }
    }

    struct LineBounds: CustomStringConvertible {
        var top: Int, bottom: Int, left: Int, right: Int
        var description: String { "rows \(top)-\(bottom) cols \(left)-\(right)" }
    }

    /// Both images go through one context format so the bytes compare.
    private static func pixels(of image: CGImage, region: CGRect) throws -> Pixels {
        let width = Int(region.width.rounded()), height = Int(region.height.rounded())
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // The region is in the image's own top-left pixel space; CGContext draws y-up.
        context.draw(image, in: CGRect(x: -region.minX, y: -(CGFloat(image.height) - region.maxY), width: CGFloat(image.width), height: CGFloat(image.height)))
        let data = try #require(context.data)
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private static func overlayPixels(_ layer: TextLayer, scale: CGFloat) throws -> Pixels {
        let view = TextEditingView(text: layer, typing: .body, theme: .macaron)
        view.hideChromeForTesting()
        let host = UIView(frame: CGRect(x: 0, y: 0, width: layer.rect.width, height: layer.rect.height))
        view.frame = host.bounds
        host.addSubview(view)
        host.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: host.bounds, format: format).image { context in
            host.layer.render(in: context.cgContext)
        }
        let cgImage = try #require(image.cgImage)
        return try pixels(of: cgImage, region: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    }

    /// Runs of ink rows, each with its column extent.
    private static func inkLines(_ pixels: Pixels) -> [LineBounds] {
        var lines: [LineBounds] = []
        var current: LineBounds?
        for y in 0..<pixels.height {
            var left: Int?, right: Int?
            for x in 0..<pixels.width where pixels.isInk(x, y) {
                if left == nil { left = x }
                right = x
            }
            if let left, let right {
                if var line = current {
                    line.bottom = y
                    line.left = min(line.left, left)
                    line.right = max(line.right, right)
                    current = line
                } else {
                    current = LineBounds(top: y, bottom: y, left: left, right: right)
                }
            } else if let line = current {
                lines.append(line)
                current = nil
            }
        }
        if let line = current { lines.append(line) }
        return lines
    }

    /// Which of the fixture's colours appear as fully opaque, unblended pixels.
    private static func coloursFound(_ pixels: Pixels, among colours: Set<String>) -> Set<String> {
        var found: Set<String> = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let p = pixels.at(x, y)
                guard p.a == 255 else { continue }
                let colour = RGBA8(red: p.r, green: p.g, blue: p.b, alpha: 255).hex
                if colours.contains(colour) { found.insert(colour) }
            }
        }
        return found
    }
}
