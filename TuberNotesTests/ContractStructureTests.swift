import XCTest

/// The structural rules of `Docs/Contract.md`, machine-checked.
///
/// These were enforced by a shell gate until the gate was removed, and
/// `Docs/Unproven.md` recorded the loss as a regression. They are tests rather
/// than a script for three reasons:
///
/// - they run inside the thing that already decides — CI and `Cmd-U` — so they
///   need no new entrypoint and no second verdict vocabulary;
/// - they fail like any other test, so nothing here resembles the gate; and
/// - **the checker itself is testable.** The shell gate once looked green while
///   two of its rules were dead code: a `|` inside a regex collided with the `|`
///   used as a field separator and the pattern silently truncated. Only a
///   negative test found it. Here, `testTheCheckerCatchesAPlantedViolation` and
///   `testACommentDoesNotTripTheChecker` are permanent rather than a ritual
///   someone performed once.
///
/// Each rule is expressed as an **allowlist of what may do the forbidden
/// thing**, never a blocklist of known offenders, so a new file breaks the test
/// without anyone remembering to update anything.
final class ContractStructureTests: XCTestCase {

    // MARK: - Locating the source

    /// The repository root, derived from this file's own compile-time path.
    ///
    /// This file lives at `<root>/TuberNotesTests/ContractStructureTests.swift`,
    /// so two components up is the root. Resolved at compile time, which means
    /// no scheme environment variable and no `$(SRCROOT)` that might expand to
    /// a literal string.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every Swift file under `TuberNotesApp/`, as (relative path, contents).
    ///
    /// Fails rather than returning empty when the tree cannot be read. A check
    /// that silently passes when it cannot find its input is decoration — that
    /// is precisely how the deleted gate's worktree rule stayed green forever.
    private func appSources(file: StaticString = #filePath, line: UInt = #line) throws -> [(path: String, code: String)] {
        let root = Self.repoRoot
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path),
            "resolved repo root has no project.yml: \(root.path) — this test cannot see the source tree",
            file: file, line: line
        )

        let appDir = root.appendingPathComponent("TuberNotesApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: appDir.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()

        XCTAssertFalse(names.isEmpty, "no Swift sources found under \(appDir.path)", file: file, line: line)

        return try names.map { name in
            let text = try String(contentsOf: appDir.appendingPathComponent(name), encoding: .utf8)
            return ("TuberNotesApp/\(name)", Self.codeOnly(text))
        }
    }

    // MARK: - The checker

    /// Source with comments and string literals removed.
    ///
    /// Load-bearing: the deleted gate's file-I/O rule once failed on a *comment*
    /// reading "fputs, not FileHandle.write(to:)". A checker that reads prose as
    /// code cries wolf, and a check that cries wolf gets disabled by the next
    /// person in a hurry — which is worse than not having it.
    static func codeOnly(_ source: String) -> String {
        var out = ""
        let chars = Array(source)
        var i = 0
        var inLineComment = false
        var inBlockComment = false
        var inString = false

        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            if inLineComment {
                if c == "\n" { inLineComment = false; out.append(c) }
            } else if inBlockComment {
                if c == "*", next == "/" { inBlockComment = false; i += 1 }
            } else if inString {
                if c == "\\" { i += 1 }            // skip the escaped character
                else if c == "\"" { inString = false }
            } else if c == "/", next == "/" {
                inLineComment = true; i += 1
            } else if c == "/", next == "*" {
                inBlockComment = true; i += 1
            } else if c == "\"" {
                inString = true
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    // MARK: - Rules

    /// UIKit and PencilKit may be imported only by the owners of
    /// frame-frequency canvas state and by the owner of the background lease.
    ///
    /// `Docs/Contract.md`, *Owners*: "Durable value types import Foundation
    /// only." This is the rule Swift 6 isolation cannot express, and the one a
    /// hurried change breaks first.
    func testOnlyTheCanvasRuntimeImportsUIFrameworks() throws {
        let allowed: Set<String> = [
            "TuberNotesApp/PageCanvasController.swift",   // the live PencilKit canvas
            "TuberNotesApp/PagedCanvasController.swift",  // paging and gesture arbitration
            "TuberNotesApp/EditorLifecycle.swift",        // the background-execution lease
        ]

        for source in try appSources() where !allowed.contains(source.path) {
            XCTAssertFalse(
                Self.importsUIFramework(source.code),
                "\(source.path) imports UIKit or PencilKit. Only the canvas runtime and "
                    + "EditorLifecycle may. If this file genuinely owns frame-frequency canvas "
                    + "state, that is a contract change: update Docs/Contract.md and this allowlist."
            )
        }
    }

    /// `PageCanvasController` never reads or writes files; `DocumentStore` is
    /// the only writer of durable state. `Docs/Contract.md`, golden rule 4.
    func testOnlyDocumentStoreTouchesTheFileSystem() throws {
        let allowed: Set<String> = ["TuberNotesApp/DocumentStore.swift"]

        for source in try appSources() where !allowed.contains(source.path) {
            let hits = Self.fileIOTokens.filter { source.code.contains($0) }
            XCTAssertTrue(
                hits.isEmpty,
                "\(source.path) performs file I/O (\(hits.joined(separator: ", "))). "
                    + "DocumentStore is the one writer of durable state; everything else "
                    + "receives and returns values."
            )
        }
    }

    /// `PKCanvasView` is constructed at exactly one code site.
    /// `Docs/Contract.md`, *Performance*, names this a hard invariant.
    ///
    /// One site, not a singleton: future scenes and virtualized page editors
    /// must be able to own independent active canvases.
    func testExactlyOnePKCanvasViewConstructionSite() throws {
        var sites: [String] = []
        for source in try appSources() {
            let count = Self.occurrences(of: "PKCanvasView(", in: source.code)
            if count > 0 { sites.append("\(source.path) (\(count))") }
        }

        XCTAssertEqual(
            sites.count, 1,
            "expected exactly one file constructing PKCanvasView, found: \(sites.isEmpty ? "none" : sites.joined(separator: ", "))"
        )
        XCTAssertEqual(
            Self.occurrences(of: "PKCanvasView(", in: try appSources().map(\.code).joined()), 1,
            "PKCanvasView is constructed more than once: \(sites.joined(separator: ", "))"
        )
    }

    // MARK: - Tests of the checker itself

    /// The rules above are only worth trusting if they can fail. This plants
    /// each violation in synthetic source and asserts it is caught.
    func testTheCheckerCatchesAPlantedViolation() {
        XCTAssertTrue(Self.importsUIFramework(Self.codeOnly("import Foundation\nimport UIKit\n")))
        XCTAssertTrue(Self.importsUIFramework(Self.codeOnly("import PencilKit\n")))
        XCTAssertFalse(Self.importsUIFramework(Self.codeOnly("import Foundation\nimport os\n")))

        let twoSites = Self.codeOnly("let a = PKCanvasView()\nlet b = PKCanvasView()\n")
        XCTAssertEqual(Self.occurrences(of: "PKCanvasView(", in: twoSites), 2)

        let io = Self.codeOnly("FileManager.default.removeItem(at: url)")
        XCTAssertFalse(Self.fileIOTokens.filter { io.contains($0) }.isEmpty)
    }

    /// Prose is not code. A comment or a string that mentions a forbidden token
    /// must not trip any rule — this is the exact false positive that made the
    /// old shell gate cry wolf.
    func testACommentDoesNotTripTheChecker() {
        let source = """
        import Foundation
        // We use fputs, not FileHandle.write(to:), because the stream is not storage.
        /* A block comment mentioning FileManager.default.removeItem and
           PKCanvasView() and even import UIKit on its own line. */
        let message = "FileManager could not open PKCanvasView("
        let escaped = "a quote \\" then FileManager again"
        """
        let code = Self.codeOnly(source)

        XCTAssertFalse(Self.importsUIFramework(code), "an import named inside a comment was read as code")
        XCTAssertEqual(Self.occurrences(of: "PKCanvasView(", in: code), 0, "a comment or string was read as a construction site")
        XCTAssertTrue(Self.fileIOTokens.filter { code.contains($0) }.isEmpty, "a comment or string was read as file I/O")
    }

    // MARK: - Primitives

    static let fileIOTokens = [
        "FileManager",
        "FileHandle",
        ".write(to:",
        "Data(contentsOf:",
        "contentsOfDirectory",
    ]

    /// Matches a real import line only — anchored per line, so `import` inside
    /// an identifier or trailing text cannot match.
    static func importsUIFramework(_ code: String) -> Bool {
        code.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "import UIKit" || trimmed == "import PencilKit"
        }
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
