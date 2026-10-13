import CoreGraphics
import PencilKit
import TNCore
import TNModel
import UIKit

/// A colour the strip can show and the runtime can draw.
///
/// Not an enum: the colour well vends colours no list can hold. Alpha is
/// always FF for ink. The highlighter's translucency is PencilKit's, and a
/// translucent colour laid on top of it would dim twice, so `init(_:)`
/// forces FF and decoding refuses anything else.
package struct ToolColor: Equatable, Sendable, Codable {
    package let rgba: RGBA8

    /// Forces alpha FF, whatever the bytes said.
    package init(rgba: RGBA8) {
        self.rgba = RGBA8(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: 0xFF)
    }

    /// Resolves in sRGB. A colour the strip's own well vended is always
    /// representable; a pattern or an unresolved dynamic colour is a
    /// programmer error and traps.
    package init(_ color: UIColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            TNPrecondition.fail("a tool colour with no sRGB components: \(color)")
        }
        self.init(rgba: RGBA8(
            red: Self.byte(red),
            green: Self.byte(green),
            blue: Self.byte(blue),
            alpha: 0xFF
        ))
    }

    /// A wide-gamut colour from the system picker has components outside
    /// `0...1` by definition, and the durable form is eight bits of sRGB.
    /// The bound is the conversion, not a contract clamp of an invalid
    /// value: without it the multiplication traps on the way to `UInt8`.
    private static func byte(_ component: CGFloat) -> UInt8 {
        UInt8(min(255, max(0, (component * 255).rounded())))
    }

    /// Built from the four bytes. Nothing here parses.
    package var uiColor: UIColor {
        UIColor(
            red: CGFloat(rgba.red) / 255,
            green: CGFloat(rgba.green) / 255,
            blue: CGFloat(rgba.blue) / 255,
            alpha: 1
        )
    }

    // The stored colours are one value, not four fields with their own
    // names: a preference written by an older build reads back as an
    // `RGBA8` or as nothing at all.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode(RGBA8.self)
        // Not corrected to FF. A record whose alpha is anything else was
        // hand-edited, and the whole palette falls back to the built-in
        // default rather than half of it being silently rewritten.
        guard decoded.alpha == 0xFF else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "a tool colour whose alpha is \(decoded.alpha) and not FF"
            )
        }
        self.rgba = decoded
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rgba)
    }

    /// The two a fresh palette writes in, and the only drawing colours the
    /// app names at all. Every other colour on offer is the theme's, and a
    /// second list of shipped inks beside it would be a list to keep in
    /// step with seven presets.
    package static let black = ToolColor(hex: "#1C1C1FFF")
    package static let yellow = ToolColor(hex: "#F2C200FF")

    /// A literal spelled the way the durable form is spelled, so the two
    /// cannot drift. A literal that is not a colour is a programmer error.
    private init(hex: String) {
        guard let parsed = RGBA8(hex: hex) else {
            TNPrecondition.fail("a default tool colour that is not a colour: \(hex)")
        }
        self.init(rgba: parsed)
    }
}

package enum ToolWidth: String, Sendable, Codable, CaseIterable {
    case thin, medium, thick
}

/// The three inks a stroke can be laid in, each carrying its own widths.
///
/// The table lives here rather than on `ToolWidth`, so a fourth kind is one
/// case and one row, and `ToolWidth` never learns who uses it.
package enum InkKind: String, Sendable, Codable, CaseIterable {
    case pen, pencil, highlighter

    /// Page points.
    ///
    /// The numbers are taste, not measurement: nothing has held a Pencil to
    /// them yet. `Docs/Unproven.md` is where that stays recorded.
    package func points(_ width: ToolWidth) -> CGFloat {
        switch self {
        case .pen, .pencil:
            switch width {
            case .thin: 2
            case .medium: 5
            case .thick: 12
            }
        case .highlighter:
            switch width {
            case .thin: 12
            case .medium: 22
            case .thick: 36
            }
        }
    }
}

/// What the palette remembers for one ink kind: the attributes, never a
/// tool, so a slot cannot hold the wrong kind.
package struct InkPreset: Equatable, Sendable, Codable {
    package var color: ToolColor
    package var width: ToolWidth

    package init(color: ToolColor, width: ToolWidth) {
        self.color = color
        self.width = width
    }
}

/// What the palette remembers for the text tool: a style to type with and
/// an alignment, never a tool.
package struct TextPreset: Equatable, Sendable, Codable {
    package var style: TextStyle
    package var alignment: TextAlignment

    package init(style: TextStyle, alignment: TextAlignment) {
        self.style = style
        self.alignment = alignment
    }

    package static let body = TextPreset(style: .body, alignment: .leading)
}

/// What the editor is doing with the Pencil. The app picks one and the
/// binding turns it into the `CanvasTool` the runtime applies: a `PKTool`
/// for ink, a style to type with for text.
package enum EditorTool: Equatable, Sendable {
    case ink(InkKind, InkPreset)
    case text(TextStyle, TextAlignment)
    /// The object eraser deletes whole strokes and has no width, as
    /// GoodNotes' has none. Two cases, so a width on it is unrepresentable
    /// rather than ignored.
    case eraseObject
    case erasePixel(ToolWidth)
    case lasso

    /// Page points, inside the range PencilKit will keep.
    ///
    /// `.thin` is PencilKit's own minimum rather than a number of ours, and
    /// that is not taste. A `PKEraserTool` built below the minimum reports
    /// the minimum back: the first draft asked for 8 and the simulator
    /// handed back 16.4, which is a width the person picked being quietly
    /// replaced. Naming the bound is how the thinnest eraser stays the
    /// thinnest eraser that exists. The other two are taste, like
    /// `InkKind.points`, and both were observed to survive verbatim.
    /// `EditorToolTests` holds every one of them against the type's bounds,
    /// so a toolchain that moves them fails a test instead of clamping.
    package static func pixelEraserPoints(_ width: ToolWidth) -> CGFloat {
        switch width {
        case .thin: PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange.lowerBound
        case .medium: 20
        case .thick: 44
        }
    }

    // What the tool carries is asked of the tool. The bar enables a control
    // from these and re-reads them at the tap, and the view model's setters
    // trap on exactly the tools they answer no for.

    /// The width the tool draws or erases at, or nil when it has none.
    package var width: ToolWidth? {
        switch self {
        case .ink(_, let preset): preset.width
        case .erasePixel(let width): width
        case .eraseObject, .lasso, .text: nil
        }
    }

    /// Whether a width can be set: on every tool that has one, and on the
    /// object eraser, which a width makes the pixel eraser. The lasso and
    /// text are the band's tools, not the bar's.
    package var takesWidth: Bool {
        switch self {
        case .ink, .erasePixel, .eraseObject: true
        case .lasso, .text: false
        }
    }

    /// The colour a stroke lands in, or nil for a tool that lays no ink.
    /// Text's colour is its style's, which the swatches never set.
    package var color: ToolColor? {
        if case .ink(_, let preset) = self { preset.color } else { nil }
    }

    /// Which of the palette's kinds the tool is: what the bar holds sunk,
    /// and what a tab opens on. The lasso is none of them.
    package var kind: ToolPalette.Kind? {
        switch self {
        case .ink(let kind, _): .ink(kind)
        case .eraseObject, .erasePixel: .eraser
        case .text: .text
        case .lasso: nil
        }
    }

    /// `.highlighter` becomes `.marker` here and nowhere else: highlighter
    /// is the product word and the contract's, and one translation at the
    /// boundary is the whole tax.
    package var canvasTool: CanvasTool {
        switch self {
        case .ink(let kind, let preset):
            .ink(PKInkingTool(Self.inkType(kind), color: preset.color.uiColor, width: kind.points(preset.width)))
        case .text(let style, let alignment):
            .text(style, alignment)
        case .eraseObject:
            .ink(PKEraserTool(.vector))
        case .erasePixel(let width):
            // `.fixedWidthBitmap`, spelled out. `PKEraserTool(.bitmap,
            // width:)` builds this type anyway and reports it back under
            // this name, so asking for `.bitmap` was asking for a tool
            // PencilKit does not make.
            .ink(PKEraserTool(.fixedWidthBitmap, width: Self.pixelEraserPoints(width)))
        case .lasso:
            .ink(PKLassoTool())
        }
    }

    private static func inkType(_ kind: InkKind) -> PKInkingTool.InkType {
        switch kind {
        case .pen: .pen
        case .pencil: .pencil
        case .highlighter: .marker
        }
    }
}
