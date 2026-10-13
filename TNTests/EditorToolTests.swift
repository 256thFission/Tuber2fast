import CoreGraphics
import Foundation

/// The PencilKit tool an editor tool becomes, or nil for text.
extension EditorTool {
    var pkTool: (any PKTool)? {
        if case .ink(let tool) = canvasTool { tool } else { nil }
    }
}
import PencilKit
import Testing
import UIKit
@testable import TNEditor
@testable import TNModel

/// The tool types, and the `PKTool` each one becomes.
///
/// What a simulator can prove here is the translation: which PencilKit tool,
/// which colour bytes, which width. What it cannot prove is how any of them
/// feels under a Pencil, which is a device's verdict.
@Suite("Editor tools")
struct EditorToolTests {

    // MARK: Colour

    @Test("A tool colour is opaque however it was made")
    func toolColorForcesOpacity() {
        let translucent = UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.25)
        #expect(ToolColor(translucent).rgba.alpha == 0xFF)
        #expect(ToolColor(rgba: RGBA8(red: 1, green: 2, blue: 3, alpha: 0x10)).rgba.alpha == 0xFF)

        // The colour itself survives; only the alpha is the tool's to decide.
        let opaque = ToolColor(translucent)
        #expect(opaque.rgba.red == 51)
        #expect(opaque.rgba.green == 102)
        #expect(opaque.rgba.blue == 153)
    }

    @Test("A tool colour round-trips through the UIColor it vends")
    func toolColorRoundTripsThroughUIColor() {
        let offered = Theme.presets.flatMap(\.theme.palette).map { ToolColor(rgba: $0) }
        for color in offered + [.black, .yellow] {
            #expect(ToolColor(color.uiColor) == color)
        }
    }

    @Test("The two inks a fresh palette writes in, byte for byte")
    func theNamedInksAreTheBuiltInPresets() {
        // How many colours the strip offers, and whether any of them
        // repeats, is the theme's question now and `ThemeTests` holds every
        // preset to it. These two are the app's own, whichever theme is on.
        #expect([ToolColor.black, .yellow].map(\.rgba.hex) == ["#141414FF", "#F2C200FF"])
    }

    @Test("The pen's built-in colour is Macaron's first, so a fresh install holds a swatch")
    func theBuiltInPenIsMacaronsFirst() {
        // Named here and not in `TNEditor`, which no theme may be named in.
        // Following the system is Macaron by day and Macaron Dark after
        // dark, and the two share one row.
        #expect(ToolColor.black == ToolColor(rgba: Theme.macaron.palette[0]))
        #expect(ToolColor.black == ToolColor(rgba: Theme.macaronDark.palette[0]))
    }

    @Test("The highlighter draws from its own run of swatches, and every other tool from the pen's")
    func eachToolNamesItsSwatchRun() {
        let preset = InkPreset(color: .black, width: .thin)
        let rows: [(EditorTool, SwatchKey.Run)] = [
            (.ink(.pen, preset), .pen), (.ink(.pencil, preset), .pen), (.ink(.highlighter, preset), .highlighter),
            (.eraseObject, .pen), (.erasePixel(.thick), .pen), (.lasso, .pen), (.text(.body, .center), .pen),
        ]
        for (tool, run) in rows {
            #expect(tool.swatchRun == run, "\(tool)")
        }
    }

    // MARK: pkTool

    @Test("Each ink kind becomes its PencilKit ink, at its own width")
    func inkBecomesAnInkingTool() throws {
        let expected: [(InkKind, PKInkingTool.InkType, CGFloat)] = [
            (.pen, .pen, 5),
            (.pencil, .pencil, 5),
            // Highlighter is the product word; `.marker` is PencilKit's, and
            // this is the one place the two meet.
            (.highlighter, .marker, 22),
        ]
        let scarlet = ToolColor(rgba: RGBA8(red: 0xC4, green: 0x29, blue: 0x29, alpha: 0xFF))
        for (kind, inkType, width) in expected {
            let preset = InkPreset(color: scarlet, width: .medium)
            let tool = try #require(EditorTool.ink(kind, preset).pkTool as? PKInkingTool)
            #expect(tool.inkType == inkType)
            #expect(tool.width == width)
            #expect(ToolColor(tool.color) == scarlet)
        }
    }

    @Test("The three widths of a kind are three different widths")
    func eachKindCarriesThreeWidths() {
        for kind in InkKind.allCases {
            let points = ToolWidth.allCases.map { kind.points($0) }
            #expect(points == points.sorted())
            #expect(Set(points).count == 3)
        }
        #expect(InkKind.pen.points(.thin) == 2)
        #expect(InkKind.pen.points(.thick) == 12)
        #expect(InkKind.highlighter.points(.thin) == 12)
        #expect(InkKind.highlighter.points(.thick) == 36)
    }

    @Test("The object eraser is a vector eraser carrying no width of ours")
    func objectEraserHasNoWidth() throws {
        let tool = try #require(EditorTool.eraseObject.pkTool as? PKEraserTool)
        #expect(tool.eraserType == .vector)
        // Built with the width-free initializer, so what it reports is
        // PencilKit's own default and never a number this project picked.
        #expect(tool.width == PKEraserTool.EraserType.vector.defaultWidth)
    }

    @Test("The pixel eraser keeps every width it is given, because every one is in range")
    func pixelEraserCarriesItsWidth() throws {
        // A width outside PencilKit's range comes back as the bound, not as
        // the number the person picked. Asking for 8 once returned 16.4.
        // This holds the three against the bounds, so a toolchain that moves
        // them fails here rather than erasing at a size nobody chose.
        let valid = PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange
        for width in ToolWidth.allCases {
            let points = EditorTool.pixelEraserPoints(width)
            #expect(valid.contains(points))

            let tool = try #require(EditorTool.erasePixel(width).pkTool as? PKEraserTool)
            #expect(tool.eraserType == .fixedWidthBitmap)
            #expect(tool.width == points)
        }

        let points = ToolWidth.allCases.map(EditorTool.pixelEraserPoints)
        #expect(points == points.sorted())
        #expect(Set(points).count == 3)
        #expect(EditorTool.pixelEraserPoints(.thin) == valid.lowerBound)
    }

    @Test("Lasso is a lasso")
    func lassoIsALasso() {
        #expect(EditorTool.lasso.pkTool is PKLassoTool)
    }

    @Test("The text tool is a style to type with, not a PencilKit tool")
    func textIsAStyle() {
        let bold = TextStyle(font: .system, size: 24, bold: true, italic: false, underline: false, color: TextStyle.body.color)
        guard case .text(let style, let alignment) = EditorTool.text(bold, .center).canvasTool else {
            Issue.record("the text tool became an ink tool"); return
        }
        #expect(style == bold && alignment == .center)
        #expect(EditorTool.text(bold, .center).pkTool == nil)
    }

    @Test("A tool restated is the same tool to the runtime, and any other tool is not")
    func aRestatedToolIsTheSameTool() {
        let bold = TextStyle(font: .system, size: 24, bold: true, italic: false, underline: false, color: TextStyle.body.color)
        let tools: [EditorTool] = [
            .ink(.pen, InkPreset(color: .black, width: .medium)),
            .ink(.pen, InkPreset(color: .black, width: .thick)),
            .ink(.pen, InkPreset(color: .yellow, width: .medium)),
            .ink(.highlighter, InkPreset(color: .yellow, width: .medium)),
            .eraseObject, .erasePixel(.thin), .erasePixel(.thick), .lasso,
            .text(.body, .leading), .text(bold, .leading), .text(.body, .center),
        ]
        for (i, a) in tools.enumerated() {
            for (j, b) in tools.enumerated() {
                #expect((a.canvasTool == b.canvasTool) == (i == j), "\(a) against \(b)")
            }
        }
    }

    // MARK: Capabilities

    @Test("Every tool says which width and colour it carries, whether it takes a width, and its kind")
    func capabilitiesForEveryTool() {
        let violet = ToolColor(rgba: RGBA8(red: 0x7A, green: 0x3F, blue: 0xC4, alpha: 0xFF))
        let rows: [(EditorTool, ToolWidth?, ToolColor?, Bool, ToolPalette.Kind?)] = InkKind.allCases.map {
            (.ink($0, InkPreset(color: violet, width: .thick)), .thick, violet, true, .ink($0))
        } + ToolWidth.allCases.map {
            (.erasePixel($0), $0, nil, true, .eraser)
        } + [
            // No width, but it takes one: a width is how it becomes the
            // pixel eraser.
            (.eraseObject, nil, nil, true, .eraser),
            (.lasso, nil, nil, false, nil),
            // The text style's colour is not the swatches' to set.
            (.text(.body, .center), nil, nil, false, .text),
        ]
        for (tool, width, color, takesWidth, kind) in rows {
            #expect(tool.width == width, "\(tool)")
            #expect(tool.color == color, "\(tool)")
            #expect(tool.takesWidth == takesWidth, "\(tool)")
            #expect(tool.kind == kind, "\(tool)")
        }
    }

    // MARK: The record

    @Test("A palette record round-trips through a property list")
    func recordRoundTrips() throws {
        let record = ToolPaletteRecord(
            lastKind: .ink(.pencil),
            inks: [
                .pen: InkPreset(color: ToolColor(rgba: RGBA8(red: 1, green: 0x70, blue: 0xC7, alpha: 0xFF)), width: .thin),
                .pencil: InkPreset(color: ToolColor(rgba: RGBA8(red: 9, green: 8, blue: 7, alpha: 0xFF)), width: .thick),
                .highlighter: InkPreset(color: .yellow, width: .medium),
            ],
            eraserMode: .pixel,
            pixelEraserWidth: .thick,
            recentColors: [ToolColor(rgba: RGBA8(red: 1, green: 2, blue: 3, alpha: 0xFF))],
            text: TextPreset(style: TextStyle(font: .system, size: 32, bold: false, italic: true, underline: true, color: RGBA8(red: 9, green: 8, blue: 7, alpha: 0xFF)), alignment: .trailing),
            gestures: [.scribble: .erase],
            swatches: [
                SwatchKey(.system, .pen): [.black, ToolColor(rgba: RGBA8(red: 1, green: 2, blue: 3, alpha: 0xFF))],
                SwatchKey(.preset(ThemeID(rawValue: "lime")), .highlighter): ToolColor.highlighterRow,
            ]
        )
        let data = try PropertyListEncoder().encode(record)
        #expect(try PropertyListDecoder().decode(ToolPaletteRecord.self, from: data) == record)
    }

    @Test("A stored colour that is not opaque is an undecodable record")
    func aTranslucentStoredColourIsRefused() throws {
        // Encoded by hand, because the type will not make one: the point is
        // a preference somebody edited, and the answer is the whole record
        // falling back to the default rather than this field being fixed.
        let data = try PropertyListEncoder().encode(
            RGBA8(red: 0x11, green: 0x22, blue: 0x33, alpha: 0x80)
        )
        #expect(throws: (any Error).self) {
            try PropertyListDecoder().decode(ToolColor.self, from: data)
        }
    }
}
