import Foundation
import Testing

// MARK: - The checker

/// One Swift source as the checker sees it: a repo-relative path and its code
/// with comments and string literals removed.
struct CheckedSource: Sendable, Equatable {
    let path: String
    let code: String
}

/// The structural rules of `Docs/Contract.md`, as pure functions over a
/// directory of Swift sources.
///
/// Pure and parameterised by a root directory on purpose. The rules used to be
/// written inline against the real source tree, which meant the only way to
/// learn whether they still bite was to break the real source tree. Now the
/// suite below points the same functions at a temp directory holding planted
/// violations, so **the recursion and each rule have a test that fails when the
/// rule dies** — see `Docs/Queue.md`, `contract-checker-is-blind`.
enum ContractChecker {

    // MARK: Enumeration

    /// Directories never walked, by name.
    ///
    /// Hidden entries (`.git`, `.build`, `.swiftpm`) are already skipped by
    /// `.skipsHiddenFiles`; these are the build products that are not hidden.
    /// A `.swift` file inside DerivedData is a copy of one that is already
    /// checked, or generated code nobody wrote — either way, counting it twice
    /// is how a checker starts crying wolf.
    static let ignoredDirectoryNames: Set<String> = [
        "DerivedData", "build", "Build", "Pods", "Carthage", "node_modules",
    ]

    /// Directory extensions never walked: bundles, not source directories.
    static let ignoredDirectoryExtensions: Set<String> = [
        "xcodeproj", "xcworkspace", "framework", "app", "bundle", "playground", "xcassets",
    ]

    /// The deepest nesting the walk will follow before failing loud.
    ///
    /// Symlinks are skipped, so no cycle can exist and this is not a
    /// termination guard — it is a claim about the shape of a source tree. A
    /// tree 32 deep means something is wrong with the *input*, and the failure
    /// mode this whole item exists to kill is a checker that shrugs at input it
    /// does not understand.
    static let maximumDepth = 32

    /// Every `.swift` file under `root`, at any depth, sorted by path.
    ///
    /// Recursive: the defect this replaced used `contentsOfDirectory(atPath:)`,
    /// which does not descend, so the first source placed in a subdirectory
    /// would have dropped out of all three rules with every test still green.
    ///
    /// Symbolic links are skipped rather than followed — a linked file would be
    /// checked twice under two paths, and a linked directory could leave the
    /// tree entirely. `swiftFileCountViaSubpaths` counts them, so a symlinked
    /// source shows up as a disagreement rather than as silence.
    static func swiftFileURLs(under root: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CheckerFailure.notADirectory(root.path)
        }

        var found: [URL] = []
        try walk(root, depth: 0, into: &found)
        return found.sorted { $0.path < $1.path }
    }

    private static func walk(_ directory: URL, depth: Int, into found: inout [URL]) throws {
        precondition(
            depth <= maximumDepth,
            "source tree nests deeper than \(maximumDepth) levels at \(directory.path); "
                + "the checker refuses to guess at a tree it does not understand"
        )

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        for entry in entries {
            let values = try entry.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }

            if values.isDirectory == true {
                if ignoredDirectoryNames.contains(entry.lastPathComponent) { continue }
                if ignoredDirectoryExtensions.contains(entry.pathExtension) { continue }
                try walk(entry, depth: depth + 1, into: &found)
            } else if values.isRegularFile == true, entry.pathExtension == "swift" {
                found.append(entry)
            }
        }
    }

    /// A second, independent count of the same set, through a different API.
    ///
    /// Load-bearing, and not redundant with the plausibility floor below. The
    /// enumeration bug this item names returned a *plausible* number of files —
    /// the whole top level — while seeing nothing below it. A floor would have
    /// stayed green forever. `subpathsOfDirectory` descends by its own code
    /// path, so an enumeration that stops descending disagrees with it on the
    /// first subdirectory that exists.
    static func swiftFileCountViaSubpaths(under root: URL) throws -> Int {
        try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { subpath in
            guard subpath.hasSuffix(".swift") else { return false }
            let components = subpath.split(separator: "/").map(String.init)
            return !components.contains { component in
                component.hasPrefix(".")
                    || ignoredDirectoryNames.contains(component)
                    || ignoredDirectoryExtensions.contains(URL(fileURLWithPath: component).pathExtension)
            }
        }.count
    }

    /// Every Swift source under `root`, as (path relative to `root`, prefixed
    /// with `label`, and code with comments and strings removed).
    static func sources(under root: URL, label: String) throws -> [CheckedSource] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let basePath = base.path

        return try swiftFileURLs(under: base).map { url in
            let full = url.standardizedFileURL.path
            precondition(
                full.hasPrefix(basePath + "/"),
                "enumerated \(full), which is not under the root \(basePath) it was asked about"
            )
            let relative = String(full.dropFirst(basePath.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            return CheckedSource(
                path: label.isEmpty ? relative : "\(label)/\(relative)",
                code: codeOnly(text)
            )
        }
    }

    enum CheckerFailure: Error, CustomStringConvertible {
        case notADirectory(String)

        var description: String {
            switch self {
            case .notADirectory(let path):
                return "\(path) is not a directory the checker can read; it cannot see the source tree"
            }
        }
    }

    // MARK: Comment and string stripping

    /// Source with comments and string literals removed.
    ///
    /// Load-bearing: the deleted shell gate's file-I/O rule once failed on a
    /// *comment* reading "fputs, not FileHandle.write(to:)". A checker that
    /// reads prose as code cries wolf, and a check that cries wolf gets
    /// disabled by the next person in a hurry — which is worse than not having
    /// it.
    ///
    /// KNOWN DEFECT: this is a scanner, not a lexer, and two constructs are
    /// beyond it. A `\(...)` interpolation is discarded with the string that
    /// contains it, so `"\(FileManager.default)"` is invisible to every rule.
    /// Multi-line literals (`"""`) are read as a pair of empty strings around
    /// the body, which usually swallows the body the same way but is not the
    /// same thing. Both under-report rather than cry wolf, which is the wrong
    /// direction for this item — recorded rather than fixed because the fix is
    /// a Swift lexer and no application source does either today.
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

    // MARK: Rule — UI framework imports

    /// The modules a durable value type may not import.
    /// `Docs/Contract.md`, *Owners*: "Durable value types import Foundation only."
    static let uiFrameworkModules: Set<String> = ["UIKit", "PencilKit"]

    /// Declaration kinds Swift permits in a scoped import: `import struct UIKit.X`.
    private static let importKindSpecifiers: Set<String> = [
        "struct", "class", "enum", "protocol", "typealias", "func", "var", "let",
        "actor", "macro", "precedencegroup", "operator", "init", "subscript",
    ]

    /// The UI frameworks a source imports, however it spells the import.
    ///
    /// A plain `trimmed == "import UIKit"` comparison missed every real spelling
    /// but one: `@preconcurrency import UIKit`, `@_exported import UIKit`,
    /// `import struct UIKit.UIEdgeInsets`, `import UIKit.UIView`, a second
    /// statement after a semicolon, and doubled whitespace all slipped past it.
    /// Each of those is a way to acquire the whole framework's vocabulary, so
    /// each is the violation the rule names.
    static func importedUIFrameworks(in code: String) -> [String] {
        var found: [String] = []

        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            for statement in line.split(separator: ";", omittingEmptySubsequences: false) {
                var tokens = statement
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)

                // Attributes precede the keyword: @_exported, @preconcurrency,
                // @_implementationOnly, @_spi(...).
                while let first = tokens.first, first.hasPrefix("@") { tokens.removeFirst() }

                guard tokens.first == "import" else { continue }
                tokens.removeFirst()

                if let kind = tokens.first, importKindSpecifiers.contains(kind) { tokens.removeFirst() }
                guard let path = tokens.first else { continue }

                // `UIKit.UIView` is UIKit. The first component names the module.
                let module = String(path.split(separator: ".").first ?? "")
                if uiFrameworkModules.contains(module) { found.append(module) }
            }
        }

        return found
    }

    static func importsUIFramework(_ code: String) -> Bool {
        !importedUIFrameworks(in: code).isEmpty
    }

    // MARK: Rule — file I/O

    /// Tokens that mean this source reaches the file system.
    ///
    /// `Docs/Contract.md`, golden rules 3 and 4: `DocumentStore` is the one
    /// writer of durable state and `PageCanvasController` never reads or writes
    /// files. This is an allowlist rule — the list below is what "touches
    /// storage" is spelled as, not a list of known offenders.
    ///
    /// `fputs` is deliberately absent: `CanvasLog` writes to `stderr`, and a
    /// stream is not storage. `UserDefaults` is deliberately present: it is
    /// durable state landing on disk without passing through `DocumentStore`,
    /// which is the rule, not the API.
    static let forbiddenFileIOTokens = [
        "FileManager",
        "FileHandle",
        "FileWrapper",
        "NSFileCoordinator",
        "UserDefaults",
        "OutputStream",
        "InputStream",
        "contentsOfDirectory",
        ".write(to:",
        ".write(toFile:",
        "Data(contentsOf:",
        "Data(contentsOfFile:",
        "String(contentsOf:",
        "String(contentsOfFile:",
        "fopen(",
        "freopen(",
    ]

    static func fileIOTokens(in code: String) -> [String] {
        forbiddenFileIOTokens.filter { code.contains($0) }
    }

    // MARK: Rule — one PKCanvasView construction site

    /// How many times this source constructs a `PKCanvasView`.
    ///
    /// Counts `PKCanvasView(`, `PKCanvasView (`, and `PKCanvasView.init(`;
    /// `PKCanvasViewDelegate` and a bare type reference are not construction.
    ///
    /// KNOWN DEFECT: a `PKCanvasView` subclass constructed by its own name, and
    /// `let v: PKCanvasView = .init()`, are invisible here. Both are visible to
    /// review, and both would need a type checker rather than a token scan.
    static func canvasConstructionCount(in code: String) -> Int {
        var count = 0
        var searchStart = code.startIndex

        while let hit = code.range(of: "PKCanvasView", range: searchStart..<code.endIndex) {
            var i = hit.upperBound
            func skipWhitespace() {
                while i < code.endIndex, code[i] == " " || code[i] == "\t" || code[i] == "\n" {
                    i = code.index(after: i)
                }
            }
            skipWhitespace()
            if code[i...].hasPrefix(".init") {
                i = code.index(i, offsetBy: 5)
                skipWhitespace()
            }
            if i < code.endIndex, code[i] == "(" { count += 1 }
            searchStart = hit.upperBound
        }

        return count
    }

    static func canvasConstructionSites(in sources: [CheckedSource]) -> [CanvasConstructionSite] {
        sources.compactMap { source in
            let count = canvasConstructionCount(in: source.code)
            return count > 0 ? CanvasConstructionSite(path: source.path, count: count) : nil
        }
    }
}

/// One file that constructs `PKCanvasView`, and how many times.
struct CanvasConstructionSite: Sendable, Equatable {
    let path: String
    let count: Int
}

// MARK: - The rules, checked against the real source tree

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
///   negative test found it. Here, `CheckerOwnTests` is permanent rather than a
///   ritual someone performed once.
///
/// Each rule is expressed as an **allowlist of what may do the forbidden
/// thing**, never a blocklist of known offenders, so a new file breaks the test
/// without anyone remembering to update anything. `staleAllowlistEntries`
/// keeps the allowlists honest in the other direction: an entry naming a file
/// that no longer exists is removed by the suite failing, not by anyone
/// remembering.
@Suite("Contract structure")
struct ContractStructureTests {

    // MARK: - Locating the source

    /// The repository root, derived from this file's own compile-time path.
    ///
    /// This file lives at `<root>/TuberNotesTests/ContractStructureTests.swift`,
    /// so two components up is the root. Resolved at compile time, which means
    /// no scheme environment variable and no `$(SRCROOT)` that might expand to
    /// a literal string.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let appDirectory = repoRoot.appendingPathComponent("TuberNotesApp")

    /// The fewest Swift sources the application can plausibly have.
    ///
    /// The old guard was `names.isEmpty`, which fires only if `TuberNotesApp/`
    /// is emptied entirely — an enumeration that returned one file read as a
    /// clean run. This floor and the cross-check in `theEnumerationSeesTheTree`
    /// are the two halves of "a broken enumerator is a failure, not a pass".
    /// Lower it only alongside a real deletion of that many files.
    static let minimumPlausibleSourceCount = 10

    /// Every Swift file under `TuberNotesApp/`, at any depth.
    ///
    /// Fails rather than returning empty when the tree cannot be read. A check
    /// that silently passes when it cannot find its input is decoration — that
    /// is precisely how the deleted gate's worktree rule stayed green forever.
    static func appSources() throws -> [CheckedSource] {
        #expect(
            FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("project.yml").path),
            "resolved repo root has no project.yml: \(repoRoot.path) — this test cannot see the source tree"
        )

        let sources = try ContractChecker.sources(under: appDirectory, label: "TuberNotesApp")

        #expect(
            sources.count >= minimumPlausibleSourceCount,
            """
            found only \(sources.count) Swift sources under \(appDirectory.path), expected at least \
            \(minimumPlausibleSourceCount). Either the tree shrank or the enumeration is broken; \
            a checker that reads too few files reports green while seeing nothing.
            """
        )

        return sources
    }

    /// Allowlist entries that name a file that no longer exists.
    ///
    /// A stale entry is not harmless: it is a standing permission nobody is
    /// reviewing, and it silently survives the rename that should have expired
    /// it. The throwaway spike's entry, in particular, must die with its file.
    static func staleAllowlistEntries(_ allowed: Set<String>, in sources: [CheckedSource]) -> [String] {
        let present = Set(sources.map(\.path))
        return allowed.subtracting(present).sorted()
    }

    // MARK: - The enumeration itself

    /// The recursion is the rule that carries every other rule. It gets its own
    /// test against the real tree, not only against planted fixtures.
    @Test("The enumeration sees the whole source tree, at every depth")
    func theEnumerationSeesTheTree() throws {
        let sources = try Self.appSources()
        let independentCount = try ContractChecker.swiftFileCountViaSubpaths(under: Self.appDirectory)

        #expect(
            sources.count == independentCount,
            """
            two independent enumerations of \(Self.appDirectory.path) disagree: the walk found \
            \(sources.count) Swift files, subpathsOfDirectory found \(independentCount). Either \
            the walk stopped descending, or a source is a symbolic link — the walk skips those \
            and this count does not.
            """
        )

        // Paths are repo-relative and carry their subdirectories, because the
        // allowlists are written in those terms.
        for source in sources {
            #expect(source.path.hasPrefix("TuberNotesApp/"), "\(source.path) is not repo-relative")
            #expect(source.path.hasSuffix(".swift"), "\(source.path) is not a Swift source")
        }
    }

    /// The checker polices every `.swift` file on disk under `TuberNotesApp/`,
    /// which is sound only while every such file is also compiled into the app
    /// target. `project.yml` declares that whole directory as one source path,
    /// so today the two sets are identical and policing disk is policing the
    /// build.
    ///
    /// If that ever stops being true — an `excludes:` key, a narrower glob — the
    /// choice has to be made again rather than inherited, so this test fails and
    /// says so. Policing disk is the safe direction of the two: an unbuilt file
    /// that names `PKCanvasView(` is a violation waiting for one line of YAML,
    /// and the failure mode of over-policing is an argument, while the failure
    /// mode of under-policing is the silence this whole item is about.
    @Test("Every policed file is a file the app target compiles")
    func policedFilesAreTargetFiles() throws {
        let yaml = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        #expect(
            lines.contains("- path: TuberNotesApp"),
            """
            project.yml no longer declares TuberNotesApp as a whole source path, so the set of files \
            on disk is no longer the set of files compiled. Decide what the checker polices and \
            say so here.
            """
        )
        #expect(
            !lines.contains { $0.hasPrefix("excludes:") || $0.hasPrefix("includes:") },
            """
            project.yml filters its sources. The checker polices everything on disk under \
            TuberNotesApp/, which is now more (or less) than the target compiles — reconcile the \
            two deliberately.
            """
        )
    }

    // MARK: - Rules

    /// UIKit and PencilKit may be imported only by the owners of
    /// frame-frequency canvas state and by the owner of the background lease.
    ///
    /// `Docs/Contract.md`, *Owners*: "Durable value types import Foundation
    /// only." This is the rule Swift 6 isolation cannot express, and the one a
    /// hurried change breaks first.
    static let uiFrameworkImportAllowlist: Set<String> = [
        "TuberNotesApp/DrawingSnapshot.swift", // the immutable value that carries a drawing out of the runtime
        "TuberNotesApp/PageCanvasController.swift",   // the live PencilKit canvas
        "TuberNotesApp/PagedCanvasController.swift",  // paging and gesture arbitration
        "TuberNotesApp/EditorLifecycle.swift",        // the background-execution lease
        // The shape tool. Both files are the canvas runtime: one builds the
        // live values PencilKit renders (`PKStroke`s from a drag), the other
        // is `PageCanvasController`'s own drag handling and its preview
        // layer, split out for size rather than made a second owner.
        "TuberNotesApp/ShapeSynthesis.swift",
        "TuberNotesApp/ShapeToolRuntime.swift",
        // The static-layer backdrop: `PageCanvasController`'s own sibling
        // CALayer stack under the transparent PKCanvasView, mirrored by one
        // transform per scroll tick. Frame-frequency work on a UIKit view
        // hierarchy — the canvas runtime, split out for size exactly as the
        // shape tool is, and not a second owner.
        //
        // `StaticLayerRenderer.swift` is deliberately *not* here: it decodes
        // and composites off-main and imports CoreGraphics and ImageIO only,
        // because nothing in it is a view, a layer, or frame-frequency work.
        "TuberNotesApp/PageBackdrop.swift",
        // THROWAWAY SPIKE — CanvasFeatureComplete device spike 1. Compiled
        // only under TN_SPIKE_MIRROR and instruments the canvas runtime,
        // where UIKit is already allowed; the entry dies with the file.
        "TuberNotesApp/SpikeMirrorFidelity.swift",
    ]

    /// `DocumentStore` is the only writer of durable state.
    static let fileIOAllowlist: Set<String> = ["TuberNotesApp/DocumentStore.swift"]

    @Test("Only the canvas runtime imports the UI frameworks")
    func onlyTheCanvasRuntimeImportsUIFrameworks() throws {
        for source in try Self.appSources() where !Self.uiFrameworkImportAllowlist.contains(source.path) {
            let imports = ContractChecker.importedUIFrameworks(in: source.code)
            #expect(
                imports.isEmpty,
                """
                \(source.path) imports \(imports.joined(separator: ", ")). Only the canvas runtime and \
                EditorLifecycle may. If this file genuinely owns frame-frequency canvas \
                state, that is a contract change: update Docs/Contract.md and this allowlist.
                """
            )
        }
    }

    /// `PageCanvasController` never reads or writes files; `DocumentStore` is
    /// the only writer of durable state. `Docs/Contract.md`, golden rule 4.
    @Test("Only DocumentStore touches the file system")
    func onlyDocumentStoreTouchesTheFileSystem() throws {
        for source in try Self.appSources() where !Self.fileIOAllowlist.contains(source.path) {
            let hits = ContractChecker.fileIOTokens(in: source.code)
            #expect(
                hits.isEmpty,
                """
                \(source.path) performs file I/O (\(hits.joined(separator: ", "))). \
                DocumentStore is the one writer of durable state; everything else \
                receives and returns values.
                """
            )
        }
    }

    /// `PKCanvasView` is constructed at exactly one code site.
    /// `Docs/Contract.md`, *Performance*, names this a hard invariant.
    ///
    /// One site, not a singleton: future scenes and virtualized page editors
    /// must be able to own independent active canvases.
    @Test("Exactly one PKCanvasView construction site")
    func exactlyOnePKCanvasViewConstructionSite() throws {
        let sites = ContractChecker.canvasConstructionSites(in: try Self.appSources())
        let described = sites.map { "\($0.path) (\($0.count))" }

        #expect(
            sites.count == 1,
            """
            expected exactly one file constructing PKCanvasView, found: \
            \(described.isEmpty ? "none" : described.joined(separator: ", "))
            """
        )
        #expect(
            sites.reduce(0) { $0 + $1.count } == 1,
            "PKCanvasView is constructed more than once: \(described.joined(separator: ", "))"
        )
    }

    /// An allowlist entry naming a file that no longer exists.
    @Test("No allowlist entry outlives its file")
    func allowlistsNameFilesThatExist() throws {
        let sources = try Self.appSources()

        let staleImports = Self.staleAllowlistEntries(Self.uiFrameworkImportAllowlist, in: sources)
        #expect(
            staleImports.isEmpty,
            """
            the UI-framework import allowlist names files that do not exist: \
            \(staleImports.joined(separator: ", ")). A permission nobody can see is a permission \
            nobody reviews — delete the entry, or fix the path if the file moved.
            """
        )

        let staleIO = Self.staleAllowlistEntries(Self.fileIOAllowlist, in: sources)
        #expect(
            staleIO.isEmpty,
            "the file-I/O allowlist names files that do not exist: \(staleIO.joined(separator: ", "))."
        )
    }
}

// MARK: - Tests of the checker itself

/// The rules are only worth trusting if they can fail.
///
/// `Docs/Queue.md`, `contract-checker-is-blind`: "The recursion is covered by
/// the checker's own tests, because an untested checker can go dead and keep
/// passing." These plant real `.swift` files in real subdirectories of a temp
/// tree and assert each rule catches them. Hermetic on purpose — a test that
/// writes into `TuberNotesApp/` and then crashes leaves the repository dirty
/// and the next run lying.
@Suite("Contract structure — the checker")
struct ContractCheckerOwnTests {

    // MARK: A planted source tree

    /// Creates a fresh temp directory, runs `body` against its root, and
    /// removes the tree either way.
    ///
    /// Hermetic on purpose. The obvious way to test this checker is to drop a
    /// file into `TuberNotesApp/` and take it out again; a run that fails
    /// between those two steps leaves the repository dirty and the next run
    /// lying about a violation nobody wrote.
    private func withPlantedTree(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("contract-checker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            try body(root)
        } catch {
            try FileManager.default.removeItem(at: root)
            throw error
        }
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to relativePath: String, under root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: The recursion

    @Test("Enumeration descends into subdirectories, at every depth")
    func enumerationDescends() throws {
        try withPlantedTree { root in
            try write("import Foundation\n", to: "Top.swift", under: root)
            try write("import Foundation\n", to: "One/Second.swift", under: root)
            try write("import Foundation\n", to: "One/Two/Third.swift", under: root)
            try write("import Foundation\n", to: "One/Two/Three/Fourth.swift", under: root)
            try write("not swift\n", to: "One/Notes.md", under: root)

            let sources = try ContractChecker.sources(under: root, label: "Planted")

            #expect(sources.map(\.path) == [
                "Planted/One/Second.swift",
                "Planted/One/Two/Third.swift",
                "Planted/One/Two/Three/Fourth.swift",
                "Planted/Top.swift",
            ])
            let independentCount = try ContractChecker.swiftFileCountViaSubpaths(under: root)
            #expect(independentCount == 4)
        }
    }

    @Test("Enumeration skips hidden directories and build products")
    func enumerationSkipsArtifacts() throws {
        try withPlantedTree { root in
            try write("import Foundation\n", to: "Real.swift", under: root)
            try write("import UIKit\n", to: ".build/Hidden.swift", under: root)
            try write("import UIKit\n", to: "DerivedData/Copy.swift", under: root)
            try write("import UIKit\n", to: "Generated.xcodeproj/Inside.swift", under: root)

            let sources = try ContractChecker.sources(under: root, label: "Planted")
            #expect(sources.map(\.path) == ["Planted/Real.swift"])

            // The independent count must apply the same exclusions, or the
            // cross-check in the real suite would fire on every clean tree.
            let independentCount = try ContractChecker.swiftFileCountViaSubpaths(under: root)
            #expect(independentCount == 1)
        }
    }

    @Test("Enumeration does not follow symbolic links")
    func enumerationSkipsSymlinks() throws {
        try withPlantedTree { root in
            try write("import Foundation\n", to: "Real/Source.swift", under: root)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("Link.swift"),
                withDestinationURL: root.appendingPathComponent("Real/Source.swift")
            )

            let sources = try ContractChecker.sources(under: root, label: "Planted")
            #expect(sources.map(\.path) == ["Planted/Real/Source.swift"])
        }
    }

    @Test("Enumeration of a path that is not a directory fails rather than returning nothing")
    func enumerationOfNonDirectoryFails() throws {
        try withPlantedTree { root in
            try write("import Foundation\n", to: "Real.swift", under: root)
            #expect(throws: ContractChecker.CheckerFailure.self) {
                _ = try ContractChecker.swiftFileURLs(under: root.appendingPathComponent("Real.swift"))
            }
            #expect(throws: ContractChecker.CheckerFailure.self) {
                _ = try ContractChecker.swiftFileURLs(under: root.appendingPathComponent("Nowhere"))
            }
        }
    }

    // MARK: Each rule, planted in a new subdirectory

    /// The queue item's exit condition, stated as a test: a `.swift` file
    /// planted in a *new subdirectory*, violating each of the three rules,
    /// fails the suite. Before the recursion landed, all three of these
    /// assertions saw an empty list.
    @Test("A violation planted in a new subdirectory is caught — all three rules")
    func plantedSubdirectoryViolationsAreCaught() throws {
        try withPlantedTree { root in
            try write("import Foundation\n", to: "Innocent.swift", under: root)
            try write(
                "import Foundation\nimport UIKit\n",
                to: "Deep/Nested/RogueImport.swift", under: root
            )
            try write(
                "import Foundation\nlet url = URL(fileURLWithPath: p)\nlet d = try Data(contentsOf: url)\n",
                to: "Deep/RogueIO.swift", under: root
            )
            try write(
                "import PencilKit\nlet canvas = PKCanvasView()\n",
                to: "Deep/Nested/Deeper/RogueCanvas.swift", under: root
            )

            let sources = try ContractChecker.sources(under: root, label: "Planted")

            let imports = sources.filter { !ContractChecker.importedUIFrameworks(in: $0.code).isEmpty }
            #expect(imports.map(\.path) == [
                "Planted/Deep/Nested/Deeper/RogueCanvas.swift",
                "Planted/Deep/Nested/RogueImport.swift",
            ])

            let io = sources.filter { !ContractChecker.fileIOTokens(in: $0.code).isEmpty }
            #expect(io.map(\.path) == ["Planted/Deep/RogueIO.swift"])

            let sites = ContractChecker.canvasConstructionSites(in: sources)
            #expect(sites.map(\.path) == ["Planted/Deep/Nested/Deeper/RogueCanvas.swift"])
            #expect(sites.map(\.count) == [1])
        }
    }

    @Test("A clean planted tree trips nothing")
    func aCleanPlantedTreeTripsNothing() throws {
        try withPlantedTree { root in
            try write("import Foundation\nimport Observation\n", to: "A.swift", under: root)
            try write("import Foundation\nlet x = 1\n", to: "Sub/B.swift", under: root)

            let sources = try ContractChecker.sources(under: root, label: "Planted")
            #expect(sources.count == 2)
            #expect(sources.allSatisfy { ContractChecker.importedUIFrameworks(in: $0.code).isEmpty })
            #expect(sources.allSatisfy { ContractChecker.fileIOTokens(in: $0.code).isEmpty })
            #expect(ContractChecker.canvasConstructionSites(in: sources).isEmpty)
        }
    }

    @Test("A stale allowlist entry is reported")
    func staleAllowlistEntriesAreReported() {
        let sources = [CheckedSource(path: "TuberNotesApp/Present.swift", code: "")]
        #expect(
            ContractStructureTests.staleAllowlistEntries(
                ["TuberNotesApp/Present.swift", "TuberNotesApp/Gone.swift"],
                in: sources
            ) == ["TuberNotesApp/Gone.swift"]
        )
    }

    // MARK: The rules, on synthetic source

    @Test("Every spelling of a UI-framework import is caught")
    func everySpellingOfAUIImportIsCaught() {
        let caught = [
            "import UIKit",
            "import PencilKit",
            "import  UIKit",
            "\timport UIKit",
            "@preconcurrency import UIKit",
            "@_exported import UIKit",
            "@_implementationOnly import PencilKit",
            "import struct UIKit.UIEdgeInsets",
            "import class PencilKit.PKDrawing",
            "import UIKit.UIView",
            "import Foundation; import UIKit",
            "import UIKit;",
        ]
        for line in caught {
            #expect(
                ContractChecker.importsUIFramework(ContractChecker.codeOnly(line + "\n")),
                "the import rule missed \(line)"
            )
        }

        let ignored = [
            "import Foundation",
            "import os",
            "import SwiftUI",
            "let importUIKit = 1",
            "#if canImport(UIKit)",
            "func doImport() {}",
        ]
        for line in ignored {
            #expect(
                !ContractChecker.importsUIFramework(ContractChecker.codeOnly(line + "\n")),
                "the import rule tripped on \(line)"
            )
        }
    }

    @Test("Every spelling of a PKCanvasView construction is counted once")
    func canvasConstructionCounting() {
        #expect(ContractChecker.canvasConstructionCount(in: "let a = PKCanvasView()") == 1)
        #expect(ContractChecker.canvasConstructionCount(in: "let a = PKCanvasView ()") == 1)
        #expect(ContractChecker.canvasConstructionCount(in: "let a = PKCanvasView.init()") == 1)
        #expect(ContractChecker.canvasConstructionCount(in: "let a = PKCanvasView(frame: .zero)") == 1)
        #expect(
            ContractChecker.canvasConstructionCount(in: "let a = PKCanvasView()\nlet b = PKCanvasView()") == 2
        )
        #expect(ContractChecker.canvasConstructionCount(in: "var d: PKCanvasViewDelegate?") == 0)
        #expect(ContractChecker.canvasConstructionCount(in: "func f(_ v: PKCanvasView) {}") == 0)
        #expect(ContractChecker.canvasConstructionCount(in: "let t = PKCanvasView.self") == 0)

        // Two files whose text abuts must not form a construction across the
        // seam. The rule counts per source, never over a joined blob.
        let seam = [
            CheckedSource(path: "A.swift", code: "let t = PKCanvasView"),
            CheckedSource(path: "B.swift", code: "() "),
        ]
        #expect(ContractChecker.canvasConstructionSites(in: seam).isEmpty)
    }

    @Test("Every spelling of file I/O is caught")
    func fileIOTokensAreCaught() {
        let caught = [
            "FileManager.default.removeItem(at: url)",
            "let h = FileHandle(forWritingAtPath: p)",
            "try data.write(to: url)",
            "try data.write(toFile: p, options: [])",
            "let d = try Data(contentsOf: url)",
            "let s = try String(contentsOf: url, encoding: .utf8)",
            "let s = try String(contentsOfFile: p, encoding: .utf8)",
            "let out = OutputStream(url: url, append: false)",
            "let f = fopen(path, \"w\")",
            "UserDefaults.standard.set(1, forKey: \"k\")",
            "let names = try fm.contentsOfDirectory(atPath: p)",
        ]
        for line in caught {
            #expect(
                !ContractChecker.fileIOTokens(in: ContractChecker.codeOnly(line + "\n")).isEmpty,
                "the file-I/O rule missed \(line)"
            )
        }

        // A stream is not storage: CanvasLog's stderr mirror must stay legal.
        #expect(ContractChecker.fileIOTokens(in: "fputs(message, stderr)").isEmpty)
    }

    /// Prose is not code. A comment or a string that mentions a forbidden token
    /// must not trip any rule — this is the exact false positive that made the
    /// old shell gate cry wolf.
    @Test("A comment does not trip the checker")
    func aCommentDoesNotTripTheChecker() {
        let source = """
        import Foundation
        // We use fputs, not FileHandle.write(to:), because the stream is not storage.
        /* A block comment mentioning FileManager.default.removeItem and
           PKCanvasView() and even import UIKit on its own line. */
        let message = "FileManager could not open PKCanvasView("
        let escaped = "a quote \\" then FileManager again"
        """
        let code = ContractChecker.codeOnly(source)

        #expect(!ContractChecker.importsUIFramework(code), "an import named inside a comment was read as code")
        #expect(ContractChecker.canvasConstructionCount(in: code) == 0, "a comment or string was read as a construction site")
        #expect(ContractChecker.fileIOTokens(in: code).isEmpty, "a comment or string was read as file I/O")
    }
}
