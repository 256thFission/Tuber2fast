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

    package static func attributes(for style: TextStyle, alignment: TextAlignment) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
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

    package static func attributed(_ runs: [TextRun], alignment: TextAlignment) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        for run in runs {
            attributed.append(NSAttributedString(string: run.string, attributes: attributes(for: run.style, alignment: alignment)))
        }
        return attributed
    }

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
