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

    /// What the caret types with. The paragraph's box is this style's own
    /// line; `restateParagraphs` widens it once a larger run is typed.
    package static func attributes(for style: TextStyle, alignment: TextAlignment) -> [NSAttributedString.Key: Any] {
        attributes(for: style, paragraph: paragraphStyle(alignment, lineHeight: wholeLineHeight(of: style)))
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

    /// The line box is explicit, and so is where the baseline sits in it.
    ///
    /// Left to themselves the two engines disagree by a fraction of a point
    /// per line (each counts the font's leading and rounds differently;
    /// measured at 2 px by the fourth line at 2x) and, given only a floor,
    /// pad it on opposite sides of the baseline (3 px, every line). So every
    /// paragraph's lines are exactly `lineHeight` tall, the tallest run's
    /// whole-point height, and the text view's layout manager is told to
    /// ignore font leading. Measured with that box (iOS 26 simulator, in
    /// `TextFidelityTests`), TextKit 1 advances by exactly the height and
    /// puts the baseline `height - descent` below the line top, unrounded,
    /// descent being the largest font descent on the line; that is the rule
    /// `placedLines` applies for the renderer.
    private static func paragraphStyle(_ alignment: TextAlignment, lineHeight: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return paragraph
    }

    private static func wholeLineHeight(of style: TextStyle) -> CGFloat {
        CGFloat(lineHeight(of: style))
    }

    package static func attributed(_ runs: [TextRun], alignment: TextAlignment) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        for run in runs {
            attributed.append(NSAttributedString(string: run.string, attributes: attributes(for: run.style, alignment: alignment)))
        }
        restateParagraphs(in: attributed, alignment: alignment)
        return attributed
    }

    /// Gives every paragraph the box of its tallest run, whichever run
    /// starts it. The text view calls this after a change, so a larger run
    /// typed into a paragraph widens the box before commit, not at it.
    package static func restateParagraphs(in attributed: NSMutableAttributedString, alignment: TextAlignment) {
        let string = attributed.string as NSString
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            var tallest: CGFloat = 0
            attributed.enumerateAttribute(styleKey, in: paragraph) { value, _, _ in
                if let style = value as? TextStyle { tallest = max(tallest, wholeLineHeight(of: style)) }
            }
            attributed.addAttribute(.paragraphStyle, value: paragraphStyle(alignment, lineHeight: tallest), range: paragraph)
            location = NSMaxRange(paragraph)
        }
    }

    /// A line the renderer draws: where `CTFramesetter` broke and flushed
    /// it, at the baseline TextKit would give it. `baseline` is measured
    /// down from the top of the box.
    package struct PlacedLine {
        package let line: CTLine
        package let x: CGFloat
        package let baseline: CGFloat
    }

    package static func placedLines(_ attributed: NSAttributedString, width: CGFloat) -> [PlacedLine] {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // Tall enough that the framesetter never drops a line for want of
        // room; the renderer clips to the rect, the way the box's edge does.
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 1_000_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var top: CGFloat = 0
        return zip(lines, origins).map { line, origin in
            let range = CTLineGetStringRange(line)
            let paragraph = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            // The fonts of the runs, as TextKit reads them; the line's own
            // typographic bounds can include a fallback glyph's font.
            var ascent: CGFloat = 0, descent: CGFloat = 0
            attributed.enumerateAttribute(.font, in: NSRange(location: range.location, length: range.length)) { value, _, _ in
                guard let font = value as? UIFont else { return }
                ascent = max(ascent, font.ascender)
                descent = max(descent, -font.descender)
            }
            let height = paragraph.map(\.maximumLineHeight).flatMap { $0 > 0 ? $0 : nil } ?? ceil(ascent + descent)
            let placed = PlacedLine(line: line, x: origin.x, baseline: top + height - descent)
            top += height
            return placed
        }
    }

    // KNOWN DEFECT: the underline's extent is each engine's own drawing, not
    // an attribute this builder can set. Measured at 2x on "plain underlined"
    // at 16 pt: the framesetter's underline reached column 231, the text
    // view's 228, glyph ink identical. The fidelity test compares glyph
    // bounds on a plain twin of that fixture and only checks that both
    // engines underline.

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

    /// Ascent, descent and leading of the resolved font, in whole points:
    /// the box every line of this style sits in.
    package static func lineHeight(of style: TextStyle) -> Double {
        let font = resolve(style)
        return ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }
}
