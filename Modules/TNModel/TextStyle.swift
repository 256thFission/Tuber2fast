import Foundation
import TNCore

/// A run minus its string: what a selection is styled with and what the
/// caret types with. No format change; `TextRun` keeps its flat keys.
package struct TextStyle: Sendable, Equatable {
    package let font: String
    package let size: Double
    package let bold: Bool
    package let italic: Bool
    package let underline: Bool
    package let color: RGBA8

    package init(font: String, size: Double, bold: Bool, italic: Bool, underline: Bool, color: RGBA8) {
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
        font: "system", size: 16, bold: false, italic: false, underline: false,
        color: RGBA8(red: 0, green: 0, blue: 0, alpha: 255)
    )
}

extension TextRun {
    package init(string: String, style: TextStyle) {
        self.init(
            string: string, font: style.font, size: style.size,
            bold: style.bold, italic: style.italic, underline: style.underline,
            color: style.color.hex
        )
    }

    /// Parses through the one colour parser. Every stored run passed
    /// `isValid`, so a colour that does not parse here is a bug.
    package var style: TextStyle {
        guard let parsed = RGBA8(hex: color) else {
            TNPrecondition.fail("a text run's colour \(color) does not parse; isValid was not run on it")
        }
        return TextStyle(font: font, size: size, bold: bold, italic: italic, underline: underline, color: parsed)
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
