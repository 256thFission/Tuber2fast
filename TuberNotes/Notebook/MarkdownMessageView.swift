import Foundation
import SwiftUI

/// A bounded, presentation-only Markdown renderer for persisted assistant text.
/// The source string is never rewritten; parsing produces transient display blocks.
struct MarkdownMessageView: View {
    let source: String

    private let document: AssistantMarkdownDocument

    init(source: String) {
        self.source = source
        self.document = AssistantMarkdownDocument(source: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if document.blocks.isEmpty {
                Text("No response content")
                    .foregroundStyle(.secondary)
                    .italic()
                    .accessibilityLabel("Assistant response is empty")
            } else {
                ForEach(document.blocks) { block in
                    MarkdownBlockView(block: block)
                }
                if document.wasTruncated {
                    Text("Response shortened for display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("This response was shortened for display")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }
}

/// Markdown-free text for compact previews, Pin labels, and accessibility values.
enum MarkdownTextProjection {
    static func plainText(from source: String, limit: Int = 500) -> String {
        let document = AssistantMarkdownDocument(source: source)
        var pieces: [String] = []
        for block in document.blocks {
            let text: String
            switch block.kind {
            case .paragraph, .heading, .quote:
                text = inlinePlainText(block.text)
            case .listItem(let ordinal):
                let prefix = ordinal.map { "\($0). " } ?? ""
                text = prefix + inlinePlainText(block.text)
            case .code:
                text = block.text
            }
            let normalized = text
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
            if !normalized.isEmpty { pieces.append(normalized) }
        }
        let joined = pieces.joined(separator: " · ")
        guard joined.count > limit else { return joined }
        return String(joined.prefix(max(0, limit))).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func inlinePlainText(_ source: String) -> String {
        let safe = AssistantMarkdownSanitizer.prepareInline(source)
        guard let attributed = try? AttributedString(
            markdown: safe,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else { return source }
        return String(attributed.characters)
    }
}

private struct AssistantMarkdownDocument {
    static let maximumInputCharacters = 100_000
    static let maximumBlocks = 2_000
    static let maximumNesting = 4
    static let maximumBlockCharacters = 10_000

    let blocks: [AssistantMarkdownBlock]
    let wasTruncated: Bool

    init(source: String) {
        let bounded = String(source.prefix(Self.maximumInputCharacters))
        var parser = AssistantMarkdownBlockParser(source: bounded)
        blocks = parser.parse()
        wasTruncated = source.count > bounded.count || parser.wasTruncated
    }
}

private struct AssistantMarkdownBlock: Identifiable {
    enum Kind {
        case paragraph
        case heading(level: Int)
        case listItem(ordinal: Int?)
        case quote
        case code(language: String?)
    }

    let id: Int
    let kind: Kind
    let text: String
    let depth: Int
}

private struct AssistantMarkdownBlockParser {
    private let lines: [Substring]
    private var index = 0
    private var nextID = 0
    private(set) var wasTruncated = false

    init(source: String) {
        lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    }

    mutating func parse() -> [AssistantMarkdownBlock] {
        var result: [AssistantMarkdownBlock] = []
        var paragraph: [String] = []

        func bounded(_ text: String) -> String {
            String(text.prefix(AssistantMarkdownDocument.maximumBlockCharacters))
        }
        func joinedParagraph(_ lines: [String]) -> String {
            // Two trailing spaces are CommonMark's explicit hard line break.
            lines.enumerated().map { offset, line in
                guard offset < lines.count - 1 else { return line }
                return line.hasSuffix("  ") ? String(line.dropLast(2)) + "\n" : line + " "
            }.joined()
        }
        func indentationDepth(_ line: Substring) -> Int {
            let spaces = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { count, character in
                count + (character == "\t" ? 4 : 1)
            }
            return min(spaces / 2, AssistantMarkdownDocument.maximumNesting)
        }
        func listPayload(_ line: Substring) -> (Int?, Substring)? {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                return (nil, trimmed.dropFirst(2))
            }
            var digits = ""
            var cursor = trimmed.startIndex
            while cursor < trimmed.endIndex, trimmed[cursor].isNumber, digits.count < 9 {
                digits.append(trimmed[cursor])
                cursor = trimmed.index(after: cursor)
            }
            guard !digits.isEmpty, cursor < trimmed.endIndex, trimmed[cursor] == "." else { return nil }
            cursor = trimmed.index(after: cursor)
            guard cursor < trimmed.endIndex, trimmed[cursor].isWhitespace else { return nil }
            return (Int(digits), trimmed[trimmed.index(after: cursor)...])
        }
        func headingPayload(_ line: Substring) -> (Int, Substring)? {
            let hashes = line.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
            return (min(hashes, 3), line.dropFirst(hashes + 1))
        }
        func append(_ kind: AssistantMarkdownBlock.Kind, _ text: String, depth: Int = 0) {
            guard result.count < AssistantMarkdownDocument.maximumBlocks else {
                wasTruncated = true
                return
            }
            let clipped = bounded(text)
            if clipped.count < text.count { wasTruncated = true }
            result.append(.init(id: nextID, kind: kind, text: clipped, depth: depth))
            nextID += 1
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            append(.paragraph, joinedParagraph(paragraph))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count, result.count < AssistantMarkdownDocument.maximumBlocks {
            let line = lines[index]
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushParagraph()
                let fence = line.hasPrefix("```") ? "```" : "~~~"
                let languageText = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let language = languageText.isEmpty ? nil : String(languageText.prefix(40))
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].hasPrefix(fence) {
                    code.append(String(lines[index]))
                    index += 1
                }
                if index < lines.count { index += 1 }
                append(.code(language: language), code.joined(separator: "\n"))
                continue
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if let (level, payload) = headingPayload(line) {
                flushParagraph()
                append(.heading(level: level), String(payload))
            } else if let (ordinal, payload) = listPayload(line) {
                flushParagraph()
                append(.listItem(ordinal: ordinal), String(payload), depth: indentationDepth(line))
            } else {
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                if trimmed.hasPrefix(">") {
                    flushParagraph()
                    let payload = trimmed.dropFirst().drop(while: { $0 == " " })
                    append(.quote, String(payload), depth: min(indentationDepth(line), AssistantMarkdownDocument.maximumNesting))
                } else {
                    paragraph.append(String(line))
                }
            }
            index += 1
        }
        flushParagraph()
        if index < lines.count { wasTruncated = true }
        return result
    }
}

private struct MarkdownBlockView: View {
    let block: AssistantMarkdownBlock

    var body: some View {
        switch block.kind {
        case .paragraph:
            inlineText(block.text)
        case .heading(let level):
            inlineText(block.text)
                .font(headingFont(level))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, level == 1 ? 4 : 1)
        case .listItem(let ordinal):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ordinal.map { "\($0)." } ?? "•")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                    .accessibilityHidden(true)
                inlineText(block.text)
            }
            .padding(.leading, CGFloat(block.depth) * 16)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(listAccessibilityLabel(ordinal: ordinal, text: block.text))
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.65))
                    .frame(width: 3)
                    .accessibilityHidden(true)
                inlineText(block.text).foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(block.depth) * 12)
            .accessibilityLabel("Quote. \(MarkdownTextProjection.plainText(from: block.text))")
        case .code(let language):
            VStack(alignment: .leading, spacing: 5) {
                if let language {
                    Text(language).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(verbatim: block.text)
                        .font(.callout.monospaced())
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(10)
                }
            }
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Code\(language.map { " in \($0)" } ?? ""). \(block.text)")
        }
    }

    private func inlineText(_ source: String) -> Text {
        Text(AssistantMarkdownSanitizer.attributedInline(source))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.bold()
        case 2: .headline
        default: .subheadline.bold()
        }
    }

    private func listAccessibilityLabel(ordinal: Int?, text: String) -> String {
        let prefix = ordinal.map { "List item \($0). " } ?? "List item. "
        return prefix + MarkdownTextProjection.plainText(from: text)
    }
}

private enum AssistantMarkdownSanitizer {
    static func attributedInline(_ source: String) -> AttributedString {
        let prepared = prepareInline(source)
        guard var result = try? AttributedString(
            markdown: prepared,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else { return AttributedString(source) }

        for run in result.runs {
            if let link = run.link, !isAllowed(link) {
                result[run.range].link = nil
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].font = .system(.body, design: .monospaced)
                result[run.range].backgroundColor = Color.secondary.opacity(0.12)
            }
        }
        return result
    }

    /// Escapes HTML and converts Markdown images to inert alt text in one linear pass.
    static func prepareInline(_ source: String) -> String {
        var output = ""
        output.reserveCapacity(source.count)
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "!", source.index(after: index) < source.endIndex,
               source[source.index(after: index)] == "[",
               let closeLabel = source[source.index(index, offsetBy: 2)...].firstIndex(of: "]") {
                guard source.index(after: closeLabel) < source.endIndex,
                      source[source.index(after: closeLabel)] == "(",
                      let closeDestination = source[source.index(after: source.index(after: closeLabel))...]
                        .firstIndex(of: ")") else {
                    // A malformed image-like suffix is emitted literally once.
                    // Breaking here avoids rescanning the same suffix for every
                    // subsequent `![` on the main thread.
                    for character in source[index...] { appendEscaped(character, to: &output) }
                    break
                }
                let altStart = source.index(index, offsetBy: 2)
                let alt = source[altStart..<closeLabel]
                output += alt.isEmpty ? "Image omitted" : "Image: \(alt)"
                index = source.index(after: closeDestination)
                continue
            }
            appendEscaped(source[index], to: &output)
            index = source.index(after: index)
        }
        return output
    }

    private static func appendEscaped(_ character: Character, to output: inout String) {
        if character.unicodeScalars.allSatisfy({ scalar in
            scalar == "\n" || scalar == "\t"
                || (!CharacterSet.controlCharacters.contains(scalar)
                    && !isBidirectionalControl(scalar.value))
        }) == false { return }
        switch character {
        case "&": output += "&amp;"
        case "<": output += "&lt;"
        case ">": output += "&gt;"
        default: output.append(character)
        }
    }

    private static func isBidirectionalControl(_ value: UInt32) -> Bool {
        (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
    }

    private static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host?.isEmpty == false
    }
}
