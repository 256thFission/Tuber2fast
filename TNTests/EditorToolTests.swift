import CoreGraphics
import Foundation
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
        for color in ToolColor.defaults {
            #expect(ToolColor(color.uiColor) == color)
        }
    }

    @Test("The first four defaults are the four inks this replaced, byte for byte")
    func defaultsOpenWithTheFourOldInks() {
        #expect(ToolColor.defaults.count == 7)
        #expect(ToolColor.defaults.prefix(4).map(\.rgba.hex) == [
            "#1C1C1FFF", "#1A70C7FF", "#C42929FF", "#2B823DFF",
        ])
        // No duplicates: two identical swatches would be two slots spent on
        // one colour, and `used(_:)` excludes the defaults by value.
        #expect(Set(ToolColor.defaults.map(\.rgba.hex)).count == ToolColor.defaults.count)
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
        for (kind, inkType, width) in expected {
            let preset = InkPreset(color: .red, width: .medium)
            let tool = try #require(EditorTool.ink(kind, preset).pkTool as? PKInkingTool)
            #expect(tool.inkType == inkType)
            #expect(tool.width == width)
            #expect(ToolColor(tool.color) == ToolColor.red)
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

    // MARK: The record

    @Test("A palette record round-trips through a property list")
    func recordRoundTrips() throws {
        let record = ToolPaletteRecord(
            lastKind: .ink(.pencil),
            inks: [
                .pen: InkPreset(color: .blue, width: .thin),
                .pencil: InkPreset(color: ToolColor(rgba: RGBA8(red: 9, green: 8, blue: 7, alpha: 0xFF)), width: .thick),
                .highlighter: InkPreset(color: .yellow, width: .medium),
            ],
            eraserMode: .pixel,
            pixelEraserWidth: .thick,
            recentColors: [ToolColor(rgba: RGBA8(red: 1, green: 2, blue: 3, alpha: 0xFF))]
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
