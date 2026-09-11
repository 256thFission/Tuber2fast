import CoreText
import Foundation
import TNCore
import UIKit

/// The one builder both engines lay out: `CTFramesetter` in the renderer
/// and `UITextView` in the canvas. It lives here because `TNCanvas`
/// imports `TNModel` and nothing else of ours, and two builders drift.
///
/// The keys are UIKit's with UIKit values. Font, paragraph style and
/// underline share their strings with CoreText's; the colour key does not,
/// so this rests on CoreText honouring UIKit's `.foregroundColor` on iOS,
/// which `TuberNotesTests/TextFidelityTests` is the proof of.
package enum TextTypesetting {
    /// Carries the `TextStyle` a range was typed with, so a commit never
    /// reverse-maps a `UIFont`.
    package static let styleKey = NSAttributedString.Key("tnStyle")

    package static func resolve(_ style: TextStyle) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if style.bold { traits.insert(.boldTrait) }
        if style.italic { traits.insert(.italicTrait) }
        let base = style.font == "system"
            ? CTFontCreateUIFontForLanguage(.system, style.size, nil)!
            : CTFontCreateWithName(style.font as CFString, style.size, nil)
        return CTFontCreateCopyWithSymbolicTraits(base, style.size, nil, traits, traits) ?? base
    }

    /// What the caret types with. The paragraph's floor is this style's
    /// own line; `attributed` restates it per paragraph from every run.
    package static func attributes(for style: TextStyle, alignment: TextAlignment) -> [NSAttributedString.Key: Any] {
        attributes(for: style, paragraph: paragraphStyle(alignment, minimumLineHeight: wholeLineHeight(of: style)))
    }

    private static func attributes(for style: TextStyle, paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: resolve(style) as UIFont,
            .foregroundColor: UIColor(
                red: CGFloat(style.color.red) / 255, green: CGFloat(style.color.green) / 255,
                blue: CGFloat(style.color.blue) / 255, alpha: CGFloat(style.color.alpha) / 255
            ),
            .paragraphStyle: paragraph,
            styleKey: style,
        ]
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    /// Every line of a paragraph advances by a whole number of points, the
    /// largest line of any run in it. TextKit 1 rounds each line fragment up
    /// to whole points and `CTFramesetter` does not, so without a floor the
    /// two drift apart by a fraction of a point per line, measured at 2 px
    /// on the fourth line at 2x. A floor both engines honour removes the
    /// rounding instead of tolerating it; a maximum would clamp a larger run
    /// typed into the paragraph, so none is set.
    private static func paragraphStyle(_ alignment: TextAlignment, minimumLineHeight: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        paragraph.minimumLineHeight = minimumLineHeight
        return paragraph
    }

    private static func wholeLineHeight(of style: TextStyle) -> CGFloat {
        ceil(CGFloat(lineHeight(of: style)))
    }

    package static func attributed(_ runs: [TextRun], alignment: TextAlignment) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        var ranges: [(range: NSRange, style: TextStyle)] = []
        for run in runs {
            let style = run.style
            let piece = NSAttributedString(string: run.string, attributes: attributes(for: style, paragraph: paragraphStyle(alignment, minimumLineHeight: wholeLineHeight(of: style))))
            ranges.append((NSRange(location: attributed.length, length: piece.length), style))
            attributed.append(piece)
        }
        // A paragraph's floor is its tallest run's, whichever run starts it.
        let string = attributed.string as NSString
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            let floor = ranges
                .filter { NSIntersectionRange($0.range, paragraph).length > 0 }
                .map { wholeLineHeight(of: $0.style) }
                .max() ?? 0
            attributed.addAttribute(.paragraphStyle, value: paragraphStyle(alignment, minimumLineHeight: floor), range: paragraph)
            location = NSMaxRange(paragraph)
        }
        return attributed
    }

    // KNOWN DEFECT: the underline's extent is each engine's own drawing, not
    // an attribute this builder can set. Measured at 2x on "plain underlined"
    // at 16 pt: the framesetter's underline reaches column 231, the text
    // view's 228, glyph ink identical. The fidelity test compares glyph
    // bounds for that fixture and only checks that both engines underline.

    /// The commit walk. A range without `styleKey` (paste, dictation, an
    /// IME's marked text) is a run in `typing`. Not merged; the notebook
    /// merges.
    package static func runs(of attributed: NSAttributedString, typing: TextStyle) -> [TextRun] {
        var runs: [TextRun] = []
        let string = attributed.string as NSString
        attributed.enumerateAttribute(styleKey, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            runs.append(TextRun(string: string.substring(with: range), style: value as? TextStyle ?? typing))
        }
        return runs
    }

    /// Ascent, descent and leading of the resolved font, in points.
    package static func lineHeight(of style: TextStyle) -> Double {
        let font = resolve(style)
        return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }
}
