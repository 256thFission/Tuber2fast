import Foundation
import TNCore

/// The faces text is set in, by the name a run stores. Closed, so a saved
/// style naming any other face does not decode, rather than being drawn in
/// whatever face CoreText falls back to.
package enum TextFont: String, Sendable, Codable {
    case system
}

/// A run minus its string: what a selection is styled with and what the
/// caret types with. No format change; `TextRun` keeps its flat keys.
package struct TextStyle: Sendable, Equatable, Codable {
    package let font: TextFont
    package let size: Double
    package let bold: Bool
    package let italic: Bool
    package let underline: Bool
    package let color: RGBA8

    package init(font: TextFont, size: Double, bold: Bool, italic: Bool, underline: Bool, color: RGBA8) {
        self.font = font
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.color = color
    }

    /// The system face at 16 points, opaque black. Taste, not measurement;
    /// `Docs/Unproven.md` is where that stays recorded.
    package static let body = TextStyle(
        font: .system, size: 16, bold: false, italic: false, underline: false,
        color: RGBA8(red: 0, green: 0, blue: 0, alpha: 255)
    )

    /// This style with the named fields changed and every other kept.
    package func with(
        size: Double? = nil, bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil, color: RGBA8? = nil
    ) -> TextStyle {
        TextStyle(
            font: font, size: size ?? self.size, bold: bold ?? self.bold, italic: italic ?? self.italic,
            underline: underline ?? self.underline, color: color ?? self.color
        )
    }
}

extension TextRun {
    package init(string: String, style: TextStyle) {
        self.init(
            string: string, font: style.font.rawValue, size: style.size,
            bold: style.bold, italic: style.italic, underline: style.underline,
            color: style.color.hex
        )
    }

    /// Parses through the one colour parser. Every stored run passed
    /// `isValid`, so a font or colour that does not parse here is a bug.
    package var style: TextStyle {
        guard let face = TextFont(rawValue: font), let parsed = RGBA8(hex: color) else {
            TNPrecondition.fail("a text run's font \(font) or colour \(color) does not parse; isValid was not run on it")
        }
        return TextStyle(font: face, size: size, bold: bold, italic: italic, underline: underline, color: parsed)
    }

    /// Adjacent runs of one style become one run, and an empty run merges
    /// away unless it is the whole text. Applied at commit.
    package static func merging(_ runs: [TextRun]) -> [TextRun] {
        var merged: [TextRun] = []
        for run in runs {
            if let last = merged.last, last.style == run.style {
                merged[merged.count - 1] = TextRun(string: last.string + run.string, style: last.style)
            } else if run.string.isEmpty, !merged.isEmpty {
                continue
            } else {
                merged.append(run)
            }
        }
        if merged.count > 1, merged.first?.string.isEmpty == true { merged.removeFirst() }
        return merged
    }
}
