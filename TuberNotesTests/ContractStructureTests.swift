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

    /// The framework imports this checker can see, and which it therefore
    /// decides the placement of. `Docs/Contract.md`, *Owners*: "Durable value
    /// types import Foundation only."
    ///
    /// `CoreGraphics` joined the list with phase 3's `pdf` kind. It is not a UI
    /// framework, and it is here for the rule behind the rule rather than the
    /// name: "durable value types import Foundation only" is a ban on acquiring
    /// a graphics framework's whole vocabulary, and `CGPDFDocument` arrives with
    /// `CGContext`, `CGImage`, and every drawing call attached. Without the
    /// entry, any file could import it and the checker would say nothing.
    ///
    /// **`SwiftUI` is deliberately absent, and the reason changed with the
    /// module split.** It used to be absent because a flat allowlist would have
    /// had to name the SwiftUI files. It is absent now because the *compiler*
    /// refuses it: no target below the app aliases `SwiftUI` to anything that
    /// exists (`project.yml`, the `Framework` template), so `import SwiftUI` in
    /// the canvas runtime is a build failure, not a test failure. A rule the
    /// link graph holds does not belong in a token scanner.
    static let uiFrameworkModules: Set<String> = ["UIKit", "PencilKit", "CoreGraphics"]

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
        // POSIX, qualified: the v2 commit protocol needs a barrier the
        // Foundation APIs above cannot issue, and the qualification is what
        // keeps `rename(` from matching the library's rename intention.
        "fcntl(",
        "fsync(",
        "Darwin.open(",
        "Darwin.rename(",
        "Darwin.unlink(",
        "Darwin.mkdir(",
        "opendir(",
    ]

    static func fileIOTokens(in code: String) -> [String] {
        forbiddenFileIOTokens.filter { code.contains($0) }
    }

    // MARK: Rule — test-only members exist only in Debug

    /// What a member written for the tests is spelled as here.
    static let testOnlySuffix = "ForTesting"

    /// Lines naming a `…ForTesting` member outside a `#if DEBUG` block.
    ///
    /// Test-only members used to ship as ordinary app API — fifteen of them,
    /// two able to *suspend a production path*: a save that awaited a delay
    /// nothing in the app ever set, and a renderer that awaited a gate. A
    /// member that does not exist in Release cannot do that, so the rule is
    /// that none of them exists there.
    ///
    /// Uses are flagged as well as declarations, deliberately: a production
    /// line that reads or awaits one is the same fact from the other end.
    /// The scan runs on comment-stripped code, so prose naming the suffix —
    /// including this rule's own explanation at each site — does not trip it.
    ///
    /// `#if DEBUG` only. `#if os(iOS)` around such a member is not the rule
    /// being asked for and is reported, which is the fail-closed direction:
    /// the argument happens at review rather than in silence.
    static func testOnlyMembersOutsideDebug(in code: String) -> [String] {
        var conditionals: [Bool] = []
        var found: [String] = []

        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                conditionals.append(trimmed == "#if DEBUG")
            } else if trimmed.hasPrefix("#elseif") || trimmed.hasPrefix("#else") {
                // The other branch of a DEBUG conditional is not DEBUG.
                if !conditionals.isEmpty { conditionals[conditionals.count - 1] = false }
            } else if trimmed.hasPrefix("#endif") {
                if !conditionals.isEmpty { conditionals.removeLast() }
            } else if trimmed.contains(testOnlySuffix), !conditionals.contains(true) {
                found.append(trimmed)
            }
        }

        return found
    }

    // MARK: Rule — one PKCanvasView construction site

    /// The type names that name a live ink surface.
    ///
    /// `InkCanvasView` is this project's `PKCanvasView` subclass — it exists to
    /// refuse PencilKit's editing menu and adds no state — so constructing one
    /// *is* constructing a canvas, and the rule below must see it. Adding it
    /// here closes half of the KNOWN DEFECT this scan used to carry: a subclass
    /// constructed by its own name was invisible. It is invisible no longer,
    /// but only for the subclass this list knows about, which is why a new one
    /// belongs here on the same commit that introduces it.
    static let canvasTypeNames = ["PKCanvasView", "InkCanvasView"]

    /// How many times this source constructs a live canvas.
    ///
    /// Counts `T(`, `T (`, and `T.init(` for each name in `canvasTypeNames`;
    /// `PKCanvasViewDelegate`, a superclass clause, and a bare type reference
    /// are not construction.
    ///
    /// KNOWN DEFECT: `let v: PKCanvasView = .init()` is still invisible here,
    /// as is a subclass this file has not been told about. Both are visible to
    /// review, and both would need a type checker rather than a token scan.
    static func canvasConstructionCount(in code: String) -> Int {
        canvasTypeNames.reduce(0) { $0 + constructionCount(of: $1, in: code) }
    }

    private static func constructionCount(of typeName: String, in code: String) -> Int {
        var count = 0
        var searchStart = code.startIndex

        while let hit = code.range(of: typeName, range: searchStart..<code.endIndex) {
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

    /// Every module's source directory, repo-relative, in graph order. The app
    /// target's directory is last because it is the top of the graph.
    ///
    /// This is the list the split turned into the unit of every rule below.
    /// Before it, one flat allowlist of file paths spanned three frameworks, so
    /// a file allowlisted for CoreGraphics could add `import PencilKit`
    /// silently — and every entry was a hardcoded path that expired the moment
    /// anything moved.
    static let moduleDirectories = [
        "Modules/TuberCore",
        "Modules/TuberModel",
        "Modules/TuberStore",
        "Modules/TuberRender",
        "Modules/TuberCanvas",
        "TuberNotesApp",
        // v2 (Docs/Forks/fundamental-rewrite.md, Part 8). Policed from the
        // first commit, so the rewrite is never a module nobody watches.
        "Modules/TNCore",
        "Modules/TNModel",
        "Modules/TNFormat",
        "Modules/TNNotebook",
        "Modules/TNLibrary",
        "Modules/TNRender",
        "Modules/TNCanvas",
        "Modules/TNEditor",
    ]

    /// The module a policed path belongs to: the last component of its
    /// directory, which is the target name for every entry above.
    static func module(of path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        return components.count >= 2 ? components[components.count - 2] : ""
    }

    /// The fewest Swift sources the application can plausibly have, across
    /// every module.
    ///
    /// The old guard was `names.isEmpty`, which fires only if the source tree
    /// is emptied entirely — an enumeration that returned one file read as a
    /// clean run. This floor and the cross-check in `theEnumerationSeesTheTree`
    /// are the two halves of "a broken enumerator is a failure, not a pass".
    /// Lower it only alongside a real deletion of that many files.
    static let minimumPlausibleSourceCount = 20

    /// Every Swift file in every module, at any depth.
    ///
    /// Fails rather than returning empty when the tree cannot be read. A check
    /// that silently passes when it cannot find its input is decoration — that
    /// is precisely how the deleted gate's worktree rule stayed green forever.
    static func appSources() throws -> [CheckedSource] {
        #expect(
            FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("project.yml").path),
            "resolved repo root has no project.yml: \(repoRoot.path) — this test cannot see the source tree"
        )

        var sources: [CheckedSource] = []
        for directory in moduleDirectories {
            let url = repoRoot.appendingPathComponent(directory)
            let found = try ContractChecker.sources(under: url, label: directory)
            #expect(
                !found.isEmpty,
                """
                \(directory) holds no Swift sources. Either a module was emptied or the enumeration \
                is broken; a checker that reads no files reports green while seeing nothing.
                """
            )
            sources += found
        }

        #expect(
            sources.count >= minimumPlausibleSourceCount,
            """
            found only \(sources.count) Swift sources across \(moduleDirectories.count) modules, \
            expected at least \(minimumPlausibleSourceCount). Either the tree shrank or the \
            enumeration is broken.
            """
        )

        return sources.sorted { $0.path < $1.path }
    }

    /// Allowlist entries that name a file that no longer exists.
    ///
    /// A stale entry is not harmless: it is a standing permission nobody is
    /// reviewing, and it silently survives the rename that should have expired
    /// it. An entry earned by a file that is gone must die with that file —
    /// this check is what makes deleting the file enough.
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

        for directory in Self.moduleDirectories {
            let url = Self.repoRoot.appendingPathComponent(directory)
            let walked = sources.filter { $0.path.hasPrefix(directory + "/") }.count
            let independentCount = try ContractChecker.swiftFileCountViaSubpaths(under: url)
            #expect(
                walked == independentCount,
                """
                two independent enumerations of \(url.path) disagree: the walk found \(walked) \
                Swift files, subpathsOfDirectory found \(independentCount). Either the walk \
                stopped descending, or a source is a symbolic link — the walk skips those and \
                this count does not.
                """
            )
        }

        // Paths are repo-relative and carry their subdirectories, because every
        // rule below is written in those terms.
        for source in sources {
            #expect(
                Self.moduleDirectories.contains(where: { source.path.hasPrefix($0 + "/") }),
                "\(source.path) is not under a declared module directory"
            )
            #expect(source.path.hasSuffix(".swift"), "\(source.path) is not a Swift source")
            #expect(
                Self.moduleUIFrameworkPolicy[Self.module(of: source.path)] != nil,
                "\(source.path) belongs to no module the import policy names"
            )
        }
    }

    /// The checker polices every `.swift` file on disk under each module
    /// directory, which is sound only while every such file is also compiled
    /// into that module's target. `project.yml` declares each whole directory
    /// as one source path, so today the two sets are identical and policing
    /// disk is policing the build.
    ///
    /// Since the split this test is doing more than it was: it is also the one
    /// place the checker's idea of the module list and `project.yml`'s idea of
    /// it are held against each other. A sixth framework whose directory nobody
    /// added to `moduleDirectories` would otherwise be policed by nothing.
    ///
    /// If that ever stops being true — an `excludes:` key, a narrower glob — the
    /// choice has to be made again rather than inherited, so this test fails and
    /// says so. Policing disk is the safe direction of the two: an unbuilt file
    /// that names `PKCanvasView(` is a violation waiting for one line of YAML,
    /// and the failure mode of over-policing is an argument, while the failure
    /// mode of under-policing is the silence this whole item is about.
    @Test("Every policed file is a file its module compiles, and every module is policed")
    func policedFilesAreTargetFiles() throws {
        let yaml = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for directory in Self.moduleDirectories {
            #expect(
                lines.contains("- path: \(directory)"),
                """
                project.yml no longer declares \(directory) as a whole source path, so the set of \
                files on disk is no longer the set of files compiled. Decide what the checker \
                polices and say so here.
                """
            )
        }

        let declared = Set(
            lines
                .filter { $0.hasPrefix("- path: ") }
                .map { String($0.dropFirst("- path: ".count)) }
        )
        #expect(
            declared.subtracting(Self.moduleDirectories).subtracting(["TuberNotesTests", "TNTests"]).isEmpty,
            """
            project.yml declares source paths this checker does not police: \
            \(declared.subtracting(Self.moduleDirectories).subtracting(["TuberNotesTests", "TNTests"]).sorted()). \
            A new module policed by nothing is the silence the split was supposed to end — add it \
            to moduleDirectories and to moduleUIFrameworkPolicy.
            """
        )

        #expect(
            !lines.contains { $0.hasPrefix("excludes:") || $0.hasPrefix("includes:") },
            """
            project.yml filters its sources. The checker polices everything on disk under each \
            module directory, which is now more (or less) than the targets compile — reconcile the \
            two deliberately.
            """
        )
    }

    /// Golden rule 2's import half is the compiler's now, and this is the one
    /// line of it a test can still lose silently.
    ///
    /// The ban itself needs no test: `import SwiftUI` below the app target does
    /// not compile, and a build failure is not something a suite has to notice.
    /// What a suite *can* notice is the flag going missing — delete
    /// `-module-alias SwiftUI=…` from `project.yml` and every module quietly
    /// regains SwiftUI with no test anywhere turning red. So this asserts the
    /// mechanism exists, and leaves the enforcement to the mechanism.
    @Test("No module below the app target can import SwiftUI")
    func swiftUIIsBannedBelowTheAppTarget() throws {
        let yaml = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        #expect(
            yaml.contains("-module-alias SwiftUI="),
            """
            project.yml no longer aliases SwiftUI away from the framework targets, so the canvas \
            runtime can import it again and nothing but review would say so. Golden rule 2's \
            import half is enforced there and nowhere else — restore it, or decide deliberately \
            that a scanner rule replaces it.
            """
        )
    }

    // MARK: - Rules

    /// Which of the three scanned frameworks each module may import.
    ///
    /// `Docs/Contract.md`, *Owners*: "Durable value types import Foundation
    /// only", and "UIKit and PencilKit may be imported only by the canvas
    /// runtime ... and by the owner of the background-execution lease."
    ///
    /// **This replaced a twenty-three-entry allowlist of file paths.** The
    /// allowlist could not express the rule it was enforcing: it was one flat
    /// set across three frameworks, so a file permitted CoreGraphics could add
    /// `import PencilKit` in silence, and every entry expired the moment a file
    /// moved. The module is the honest unit — a file's permissions are now a
    /// property of where it lives, which is the same fact the link graph
    /// already carries, and there is nothing left to keep in sync per file.
    ///
    /// The scanner is still the enforcement for these three because the
    /// compiler cannot be: PencilKit requires UIKit and Foundation requires
    /// CoreGraphics, so aliasing either away (the trick `project.yml` uses for
    /// SwiftUI) breaks the transitive load as well as the written import.
    static let moduleUIFrameworkPolicy: [String: Set<String>] = [
        // Foundation and os. The floor of the graph imports nothing else.
        "TuberCore": [],
        // PencilKit, and only for `DrawingSnapshot` — the immutable box that
        // carries a drawing out of the canvas runtime. Phillip's decision of
        // 2026-08-07 (`project.yml`, TuberModel): this project no longer claims
        // that no durable value type imports PencilKit. CoreGraphics is still
        // refused here, which is the half of the old rule that was really about
        // durable values acquiring a drawing vocabulary.
        "TuberModel": ["PencilKit"],
        // The one target that touches files, and it does so in Foundation.
        "TuberStore": [],
        // Off-main decode and composite: CoreGraphics and ImageIO, no view, no
        // layer, no frame-frequency state. `PDFSource` opens a source PDF with
        // `CGPDFDocument` — PDFKit would bring a whole document *view* stack
        // for a page count and a page box, and `project.yml` does not link it.
        "TuberRender": ["CoreGraphics"],
        // The canvas runtime: everything that owns frame-frequency state. This
        // is the module the two named exceptions in *Owners* describe.
        "TuberCanvas": ["UIKit", "PencilKit", "CoreGraphics"],
        // The SwiftUI shell, the pickers, `EditorLifecycle` — which imports
        // UIKit for the background-execution lease, the second named exception
        // — and `EditorSession`. This module is where SwiftUI is allowed, and
        // it is allowed nowhere else by the compiler rather than by this table.
        "TuberNotesApp": ["UIKit", "PencilKit", "CoreGraphics"],
        // v2. TNModel carries PencilKit and CoreGraphics for value types that
        // cross the seams (PKDrawing, CGImage); the format touches files in
        // Foundation and POSIX and draws nothing.
        "TNCore": [],
        "TNModel": ["PencilKit", "CoreGraphics"],
        "TNFormat": [],
        // Custody holds PKDrawing values; nothing here draws or touches a file.
        "TNNotebook": ["PencilKit"],
        // The tree and the trash, in Foundation. Holds Notebooks (PencilKit
        // arrives transitively) but writes no UI import.
        "TNLibrary": ["PencilKit"],
        // Composites and thumbnails: CoreGraphics (CoreText and ImageIO are
        // not policed), PencilKit for a thumbnail's ink. No UIKit.
        "TNRender": ["CoreGraphics", "PencilKit"],
        // The driven runtime: everything that owns frame-frequency state.
        "TNCanvas": ["UIKit", "PencilKit", "CoreGraphics"],
        // The binding and the editor view model.
        "TNEditor": ["UIKit", "PencilKit", "CoreGraphics"],
    ]

    /// Files whose **module** is the claim, not merely their imports.
    ///
    /// The per-module policy above cannot express this. It permits `TuberCanvas`
    /// UIKit, so `PaperTemplateRenderer.swift` moved into the canvas runtime
    /// would satisfy every other rule in this file while being exactly what the
    /// design forbids: paper drawn where frame-frequency work lives, one
    /// refactor from a `CAShapeLayer` on the main thread. And `PageTemplate` is
    /// a durable value — `Contract.md` — Owners: "Durable value types import
    /// Foundation only" — so the vocabulary it may not acquire is *all* of it,
    /// CoreGraphics included, however `TuberModel`'s row above reads.
    ///
    /// Two entries rather than a rule, because two files is what there is; a
    /// third would be the moment to ask what the rule really is. Neither can
    /// outlive its file: the test below requires **exactly one** match per
    /// name, so a rename fails here rather than passing over nothing.
    static let filesPlacedByDesign: [String: (module: String, forbidden: Set<String>)] = [
        "PageTemplate.swift": ("TuberModel", ["UIKit", "PencilKit", "CoreGraphics"]),
        "PaperTemplateRenderer.swift": ("TuberRender", ["UIKit", "PencilKit"]),
    ]

    @Test("A template is a name in the model and marks in the renderer, and nowhere else")
    func templateFilesArePlacedByDesign() throws {
        let sources = try Self.appSources()
        for (name, rule) in Self.filesPlacedByDesign {
            let matches = sources.filter { $0.path.hasSuffix("/" + name) }
            #expect(
                matches.count == 1,
                "expected exactly one \(name) in the source tree, found \(matches.map(\.path))"
            )
            guard let source = matches.first else { continue }
            #expect(
                Self.module(of: source.path) == rule.module,
                """
                \(source.path) must live in \(rule.module). Moving it changes which frameworks it \
                may import and, for the renderer, whether paper can be drawn on a frame path.
                """
            )
            let forbidden = Set(ContractChecker.importedUIFrameworks(in: source.code))
                .intersection(rule.forbidden)
            #expect(
                forbidden.isEmpty,
                "\(source.path) imports \(forbidden.sorted().joined(separator: ", ")), which it may not."
            )
        }
    }

    /// `DocumentStore` is the only writer of durable state.
    ///
    /// `ImportPickers.swift` is here for one read, not a write: a document
    /// picked from the Files picker arrives as a security-scoped URL outside
    /// the sandbox, and its bytes must be read where the scope is held. That
    /// file is the *user's source*, not the document's durable state — the
    /// bytes become durable only by passing through `EditorSession.importPDF`
    /// and then the store, which remains the one writer.
    ///
    /// Still a file-path allowlist rather than a module one, deliberately:
    /// TuberStore is a whole module that may touch files, but the app target's
    /// one permitted read is a single file's business and naming the module
    /// would licence the whole SwiftUI shell.
    static let fileIOAllowlist: Set<String> = [
        "Modules/TuberStore/DocumentStore.swift",
        "Modules/TuberStore/LibraryStore.swift",
        "TuberNotesApp/ImportPickers.swift",
        // v2: the one file that names a file API. The store above it uses the
        // seam this file defines.
        "Modules/TNFormat/PosixFileSystem.swift",
        // v2: the library tree, trash, and staging moves.
        "Modules/TNLibrary/LibraryStore.swift",
    ]

    @Test("Each module imports only the frameworks its place in the graph allows")
    func eachModuleImportsOnlyWhatItsPlaceAllows() throws {
        for source in try Self.appSources() {
            let module = Self.module(of: source.path)
            let permitted = Self.moduleUIFrameworkPolicy[module] ?? []
            let violations = Set(ContractChecker.importedUIFrameworks(in: source.code))
                .subtracting(permitted)
            #expect(
                violations.isEmpty,
                """
                \(source.path) imports \(violations.sorted().joined(separator: ", ")), which \(module) \
                may not. Either the file is in the wrong module — move it — or the module's place in \
                the graph changed, which is a contract change: update Docs/Contract.md, project.yml, \
                and moduleUIFrameworkPolicy together.
                """
            )
        }
    }

    /// File I/O is confined to `TuberStore`'s actors, one per storage domain —
    /// `DocumentStore` for a document's insides, `LibraryStore` for the
    /// library tree — plus the import picker's security-scoped read, each
    /// named individually in the allowlist. `Docs/Contract.md`, golden rules
    /// 3 and 4; the library rows are staged in `Docs/Contract.proposed.md`,
    /// L2.
    @Test("File I/O is confined to TuberStore's actors, one per storage domain")
    func fileIOIsConfinedToTheStorageActors() throws {
        for source in try Self.appSources() where !Self.fileIOAllowlist.contains(source.path) {
            let hits = ContractChecker.fileIOTokens(in: source.code)
            #expect(
                hits.isEmpty,
                """
                \(source.path) performs file I/O (\(hits.joined(separator: ", "))). \
                TuberStore's actors are the writers of durable state, one per storage \
                domain; everything else receives and returns values.
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

    /// Nothing written for the tests exists in the build people hold.
    ///
    /// The allowlist is empty and stays empty: a `…ForTesting` member that
    /// must exist in Release is not a test-only member, and should be named
    /// for whatever it actually is.
    @Test("Test-only members exist only in Debug")
    func testOnlyMembersAreDebugOnly() throws {
        for source in try Self.appSources() {
            let leaks = ContractChecker.testOnlyMembersOutsideDebug(in: source.code)
            #expect(
                leaks.isEmpty,
                """
                \(source.path) names a test-only member outside `#if DEBUG`: \
                \(leaks.joined(separator: " / ")). It ships in Release, where it is app API \
                nobody meant to write — and a test-only suspension point there can hold a \
                production path.
                """
            )
        }
    }

    /// An allowlist entry naming a file that no longer exists.
    ///
    /// One allowlist is left to keep honest. The UI-framework half of this test
    /// died with the twenty-three-entry path allowlist it policed: a module
    /// policy has no paths to go stale, and `policedFilesAreTargetFiles` covers
    /// the failure that replaced it — a module `project.yml` builds that no
    /// policy names.
    @Test("No allowlist entry outlives its file")
    func allowlistsNameFilesThatExist() throws {
        let sources = try Self.appSources()

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

    /// The rule can go dead in two directions, so both are planted: a member
    /// outside the conditional must be caught, and one inside it must not.
    @Test("A test-only member outside #if DEBUG is caught, and one inside is not")
    func testOnlyMembersOutsideDebugAreCaught() {
        let shipped = """
            struct A {
                var thingForTesting: Int { 1 }
            }
            """
        #expect(ContractChecker.testOnlyMembersOutsideDebug(in: shipped).count == 1)

        let gated = """
            struct A {
                #if DEBUG
                var thingForTesting: Int { 1 }
                #endif
            }
            """
        #expect(ContractChecker.testOnlyMembersOutsideDebug(in: gated).isEmpty)

        // The other branch of a DEBUG conditional is not DEBUG.
        let elseBranch = """
            #if DEBUG
            let a = 1
            #else
            var thingForTesting: Int { 1 }
            #endif
            """
        #expect(ContractChecker.testOnlyMembersOutsideDebug(in: elseBranch).count == 1)

        // A conditional that is not DEBUG does not satisfy the rule.
        let wrongCondition = """
            #if os(iOS)
            var thingForTesting: Int { 1 }
            #endif
            """
        #expect(ContractChecker.testOnlyMembersOutsideDebug(in: wrongCondition).count == 1)

        // And the scan is over stripped code, so prose cannot trip it —
        // `CheckedSource.code` is what the rule reads.
        #expect(
            ContractChecker.testOnlyMembersOutsideDebug(
                in: ContractChecker.codeOnly("// a comment about somethingForTesting\nlet x = 1\n")
            ).isEmpty
        )
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
            // Not an oversight: SwiftUI is the compiler's to refuse below the
            // app target, so the scanner has no opinion about it anywhere.
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
