import Foundation
import Testing

// MARK: - The checker

/// One Swift source as the checker sees it: a repo-relative path and its code
/// with comments removed and string contents kept.
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
/// rule dies**.
enum ContractChecker {

    // MARK: Enumeration

    /// Every Swift source under `root`, at any depth, sorted by path: its
    /// path relative to `root`, prefixed with `label`, and its code with
    /// comments removed.
    ///
    /// Recursive: the defect this replaced used `contentsOfDirectory(atPath:)`,
    /// which does not descend, so the first source placed in a subdirectory
    /// would have dropped out of every rule with every test still green.
    /// Hidden entries are skipped, so an editor's `.#Foo.swift` is not read.
    static func sources(under root: URL, label: String) throws -> [CheckedSource] {
        try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") && !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
            .sorted()
            .map { relative in
                let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
                return CheckedSource(path: label.isEmpty ? relative : "\(label)/\(relative)", code: withoutComments(text))
            }
    }

    // MARK: Comment stripping

    /// Source with comments removed and string contents kept.
    ///
    /// Load-bearing: the deleted shell gate's file-I/O rule once failed on a
    /// *comment* reading "fputs, not FileHandle.write(to:)". A checker that
    /// reads prose as code cries wolf, and a check that cries wolf gets
    /// disabled by the next person in a hurry — which is worse than not having
    /// it.
    ///
    /// Strings are tracked only so that `//` and `/*` inside a literal are not
    /// read as comments. Their contents are kept, quotes aside, because an
    /// interpolation is code: `"\(FileManager.default)"` reaches the file
    /// system, and so does the same call in a `"""` body or a raw string's
    /// `\#(...)`. The price is that a string naming a forbidden token trips
    /// its rule; no source does that today. This is still a scanner, not a
    /// lexer: a quote it miscounts (a lone `"` in a `"""` body, a string nested
    /// in an interpolation) can make a later comment read as code, or a `//`
    /// in a later string read as a comment.
    static func withoutComments(_ source: String) -> String {
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
                else { out.append(c) }
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

    // MARK: Rule — imports

    /// The frameworks that bring drawing or UI vocabulary with them, which a
    /// file placed by design takes from its own row rather than its module's
    /// (`ContractStructureTests.filesPlacedByDesign`). `Docs/Contract.md`,
    /// *Structure*: UIKit is imported only by `TNCanvas`, `TNEditor`, and the
    /// app.
    ///
    /// `CoreGraphics` is not a UI framework, and it is here because importing
    /// it acquires a graphics framework's whole vocabulary: `CGPDFDocument`
    /// arrives with `CGContext`, `CGImage`, and every drawing call attached.
    ///
    /// `SwiftUI` is absent because no file below the app can import it at all:
    /// no target below the app aliases `SwiftUI` to anything that exists
    /// (`project.yml`, the `Framework` template), so the compiler refuses it
    /// before any row is read.
    static let uiFrameworkModules: Set<String> = ["UIKit", "PencilKit", "CoreGraphics", "CoreText"]

    /// Declaration kinds Swift permits in a scoped import: `import struct UIKit.X`.
    private static let importKindSpecifiers: Set<String> = [
        "struct", "class", "enum", "protocol", "typealias", "func", "var", "let",
        "actor", "macro", "precedencegroup", "operator", "init", "subscript",
    ]

    /// The modules a source imports, ours and the system's, however it spells
    /// the import.
    ///
    /// A plain `trimmed == "import UIKit"` comparison missed every real spelling
    /// but one: `@preconcurrency import UIKit`, `@_exported import UIKit`,
    /// `import struct UIKit.UIEdgeInsets`, `import UIKit.UIView`, a second
    /// statement after a semicolon, and doubled whitespace all slipped past it.
    /// Each of those is a way to acquire the whole framework's vocabulary, so
    /// each is the violation the rule names.
    static func importedModules(in code: String) -> [String] {
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
                found.append(String(path.split(separator: ".").first ?? ""))
            }
        }

        return found
    }

    static func importedUIFrameworks(in code: String) -> [String] {
        importedModules(in: code).filter(uiFrameworkModules.contains)
    }

    static func importsUIFramework(_ code: String) -> Bool {
        !importedUIFrameworks(in: code).isEmpty
    }

    // MARK: Rule — UIKit's vocabulary

    /// Identifiers spelled the way UIKit spells its types: `UI` and a capital.
    ///
    /// PencilKit and PDFKit re-export UIKit, so a module allowed PencilKit for
    /// `PKDrawing` can write `UIBezierPath` without an `import UIKit` anywhere.
    /// The import rule cannot see that; the vocabulary can. `UInt` and `UUID`
    /// do not match.
    static func uiKitIdentifiers(in code: String) -> [String] {
        code.matches(of: #/\bUI[A-Z]\w*/#.wordBoundaryKind(.simple)).map { String($0.output) }
    }

    // MARK: Rule — file I/O

    /// Tokens that mean this source reaches the file system.
    ///
    /// `Docs/Contract.md`, *Structure*: file I/O happens in `PosixFileSystem`,
    /// `LibraryStore`, and `ImportReader`, and nowhere else. This is an
    /// allowlist rule — the list below is what "touches storage" is spelled
    /// as, not a list of known offenders.
    ///
    /// `fputs` is deliberately absent: `TNLog` writes to `stderr`, and a
    /// stream is not storage. `UserDefaults` is deliberately present: it is
    /// durable state landing on disk without passing through a store, which
    /// is the rule, not the API.
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
        "String(contentsOf:",
        "contentsOfFile:",
        "URL.temporaryDirectory",
        ".documentsDirectory",
        "NSTemporaryDirectory",
        "NSHomeDirectory",
        // A transferable the share sheet reads from a file, and UIKit's PDF
        // writer, which writes one.
        "FileRepresentation",
        "writePDF(to:",
        // CoreGraphics and ImageIO reach a file through a CFURL.
        "as CFURL",
        "CreateWithURL",
        "CGDataConsumer(url:",
        "CGDataProvider(url:",
        "fopen(",
        "freopen(",
        // POSIX: the v2 commit protocol needs a barrier the Foundation APIs
        // above cannot issue. A qualified call is a token; `fileIOTokens`
        // matches an unqualified one.
        "fcntl(",
        "fsync(",
        "Darwin.open(",
        "Darwin.rename(",
        "Darwin.unlink(",
        "Darwin.mkdir(",
        "opendir(",
    ]

    /// The tokens above in `code`, and each POSIX call without `Darwin.`,
    /// which compiles anywhere Foundation is imported: a POSIX name and a
    /// first argument with no label. A labelled call, such as the library's
    /// `rename(at:to:)`, does not match. A Swift method of the same name with
    /// one unlabelled argument does, and is called through `self.` instead.
    static func fileIOTokens(in code: String) -> [String] {
        let unqualifiedPOSIXCall = #/(?:^|[^\w.])(open|creat|rename|unlink|mkdir|rmdir|remove|truncate)\(\s*[^\s:(),]+\s*[,)(]/#
        return forbiddenFileIOTokens.filter { code.contains($0) }
            + code.matches(of: unqualifiedPOSIXCall).map { "\($0.output.1)(" }
    }

    // MARK: Rule — what project.yml builds

    private typealias YAMLLine = (indent: Int, text: String)

    /// `project.yml`'s lines, trimmed, without comments and blanks.
    private static func yamlLines(_ yaml: String) -> [YAMLLine] {
        yaml.split(separator: "\n")
            .map { (indent: $0.prefix { $0 == " " }.count, text: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.text.isEmpty && !$0.text.hasPrefix("#") }
    }

    /// The lines under the key at `index`: deeper, or a list item at its depth.
    private static func children(of index: Int, in lines: [YAMLLine]) -> ArraySlice<YAMLLine> {
        let key = lines[index].indent
        let end = lines[(index + 1)...].firstIndex {
            $0.indent < key || ($0.indent == key && !$0.text.hasPrefix("- "))
        }
        return lines[(index + 1)..<(end ?? lines.endIndex)]
    }

    /// Every path a target compiles: each item under a `sources:` key,
    /// `- path: X` or `- X`, and an inline value as written, so
    /// `sources: [A, B]` names no directory and fails closed.
    static func declaredSourcePaths(inYAML yaml: String) -> Set<String> {
        let lines = yamlLines(yaml)
        var declared: Set<String> = []
        for index in lines.indices where lines[index].text.hasPrefix("sources:") {
            let inline = lines[index].text.dropFirst("sources:".count).trimmingCharacters(in: .whitespaces)
            if !inline.isEmpty { declared.insert(inline) }
            let items = children(of: index, in: lines)
            for item in items where item.indent == items.first?.indent && item.text.hasPrefix("- ") {
                let value = item.text.dropFirst("- ".count)
                declared.insert(String(value.hasPrefix("path: ") ? value.dropFirst("path: ".count) : value))
            }
        }
        return declared
    }

    /// The lines that set `OTHER_SWIFT_FLAGS`. The SwiftUI alias is the
    /// `Framework` template's, a target's own value replaces a template's in
    /// XcodeGen, and its `$(inherited)` skips the template, so a second
    /// setting anywhere can drop the alias for a target.
    static func swiftFlagsSettings(inYAML yaml: String) -> [String] {
        yamlLines(yaml).map(\.text).filter { $0.contains("OTHER_SWIFT_FLAGS") }
    }

    /// The names in `names` with no target that takes the `Framework` template.
    static func targetsWithoutFrameworkTemplate(_ names: [String], inYAML yaml: String) -> [String] {
        let lines = yamlLines(yaml)
        return names.filter { name in
            guard let target = lines.firstIndex(where: { $0.text == name + ":" }) else { return true }
            return !children(of: target, in: lines).contains { $0.text == "templates: [Framework]" }
        }
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

    // MARK: Rule — launch hooks read the process in one place

    /// Reads of the process's launch arguments and environment.
    ///
    /// The `-TN…` hooks once read the arguments where each was used, and all
    /// but one ran in Release: the rule above matches a name, and a hook is
    /// not named for the tests. `LaunchHooks.arguments` is empty in Release,
    /// so a hook that reads through it is Debug-only whatever it is called.
    /// `CommandLine.arguments` is the same read by another spelling; a read
    /// through `getenv` or a stored `ProcessInfo` is out of reach of a token
    /// scan.
    static let processReadTokens = [
        "ProcessInfo.processInfo.arguments",
        "ProcessInfo.processInfo.environment",
        "CommandLine.arguments",
    ]

    static func processReads(in code: String) -> [String] {
        processReadTokens.filter { code.contains($0) }
    }

    // MARK: Rule — one PKCanvasView construction site

    /// The live ink surface every canvas type descends from.
    static let canvasBaseTypeName = "PKCanvasView"

    /// `PKCanvasView` and every class in `sources` that inherits from it, at
    /// any depth.
    ///
    /// A subclass is the same surface under another name, so constructing one
    /// *is* constructing a canvas. The names are found, not listed: the list
    /// this replaced still named a subclass deleted with the old engine, and
    /// would have missed the next one. A class joins when any name in its
    /// inheritance clause has already joined, until none does, so the order
    /// the files are read in does not matter.
    static func canvasTypeNames(in sources: [CheckedSource]) -> Set<String> {
        // `class Name<Generics>: inheritance clause {`
        let classDeclaration = #/\bclass\s+(\w+)\s*(?:<[^>]*>)?\s*:([^{]*)\{/#.wordBoundaryKind(.simple)
        let declarations = sources.flatMap { source in
            source.code.matches(of: classDeclaration).map { match in
                (
                    name: String(match.output.1),
                    inherits: Set(match.output.2.matches(of: #/\w+/#).map { String($0.output) })
                )
            }
        }
        var names: Set<String> = [canvasBaseTypeName]
        while let joining = declarations.first(where: {
            !names.contains($0.name) && !$0.inherits.isDisjoint(with: names)
        }) {
            names.insert(joining.name)
        }
        return names
    }

    /// How many times this source constructs one of `typeNames`.
    ///
    /// Counts `T(`, `T (`, `T.init(`, and an annotation's shorthand: `: T =
    /// .init(`, with `T!` and `T?` as well. `PKCanvasViewDelegate`, a
    /// superclass clause, and a bare type reference are not construction.
    /// Construction through a metatype or a typealias is out of reach of a
    /// token scan.
    static func canvasConstructionCount(in code: String, of typeNames: Set<String> = [canvasBaseTypeName]) -> Int {
        typeNames.reduce(0) { $0 + constructionCount(of: $1, in: code) }
    }

    private static func constructionCount(of typeName: String, in code: String) -> Int {
        var count = 0
        var searchStart = code.startIndex

        while let hit = code.range(of: typeName, range: searchStart..<code.endIndex) {
            searchStart = hit.upperBound
            // `MyPKCanvasView(` constructs another type.
            if hit.lowerBound > code.startIndex {
                let before = code[code.index(before: hit.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }
            var i = hit.upperBound
            func skipWhitespace() {
                while i < code.endIndex, code[i] == " " || code[i] == "\t" || code[i] == "\n" {
                    i = code.index(after: i)
                }
            }
            skipWhitespace()
            if code[i...].hasPrefix("!") || code[i...].hasPrefix("?") || code[i...].hasPrefix("=") {
                if code[i] != "=" {
                    i = code.index(after: i)
                    skipWhitespace()
                }
                guard code[i...].hasPrefix("="), !code[i...].hasPrefix("==") else { continue }
                i = code.index(after: i)
                skipWhitespace()
                guard code[i...].hasPrefix(".init") else { continue }
            }
            if code[i...].hasPrefix(".init") {
                i = code.index(i, offsetBy: 5)
                skipWhitespace()
            }
            if i < code.endIndex, code[i] == "(" { count += 1 }
        }

        return count
    }

    static func canvasConstructionSites(in sources: [CheckedSource]) -> [CanvasConstructionSite] {
        let typeNames = canvasTypeNames(in: sources)
        return sources.compactMap { source in
            let count = canvasConstructionCount(in: source.code, of: typeNames)
            return count > 0 ? CanvasConstructionSite(path: source.path, count: count) : nil
        }
    }

    // MARK: Rule — one writer of the tool

    /// The system tool picker observes a first-responder canvas and writes
    /// `canvasView.tool` itself, which makes it a second writer of the tool.
    ///
    /// The window keeps up to three live canvases, and
    /// `PagedCanvasController.apply` is the one place that fans a tool out
    /// to all of them and to every canvas built later. A picker driving the
    /// first responder would leave the other two stale, and a page turn
    /// would change which canvas it drives.
    ///
    /// Naming it is the violation, not constructing it: a stored property, a
    /// `setVisible(_:forFirstResponder:)` call, and an extension on it are
    /// the same second writer by other spellings, and none of them is a
    /// construction. The scan reads comment-stripped code, so this
    /// explanation and the failure message below cannot trip it.
    static let toolPickerTypeName = "PKToolPicker"

    static func namesToolPicker(in code: String) -> Bool {
        code.contains(toolPickerTypeName)
    }

    static func toolPickerSites(in sources: [CheckedSource]) -> [String] {
        sources.filter { namesToolPicker(in: $0.code) }.map(\.path)
    }

    /// The theme global the canvas once read, and the notification that
    /// told it to repaint. The canvas is told the theme through `apply`; a
    /// global it reads is the canvas asking. Assembled, so a search of the
    /// tree for the two names finds that they are gone, this file included.
    static let themeGlobals = ["current", "changed"].map { "Theme." + $0 }

    static func namesThemeGlobal(in code: String) -> Bool {
        themeGlobals.contains { code.contains($0) }
    }

    /// Assignments of the canvas's tool: `canvasView.tool =`, through
    /// `self.`, `?` or `!` as well.
    ///
    /// The picker is one second writer; an assignment is the plainer one. A
    /// Pencil double-tap handler that sets `PKEraserTool` on the canvas it
    /// was handed leaves the other live canvases on the old tool, the same
    /// way a picker would. The receiver is matched by the name it has at the
    /// one site and in every delegate callback, `canvasView`; an assignment
    /// through another name is out of reach of a token scan.
    static func toolAssignmentCount(in code: String) -> Int {
        code.matches(of: #/\bcanvasView\s*[?!]?\s*\.\s*tool\s*=(?!=)/#.wordBoundaryKind(.simple)).count
    }

    /// One path per assignment of the canvas's tool.
    static func toolAssignmentSites(in sources: [CheckedSource]) -> [String] {
        sources.flatMap { Array(repeating: $0.path, count: toolAssignmentCount(in: $0.code)) }
    }
}

/// One file that constructs a canvas, and how many times.
struct CanvasConstructionSite: Sendable, Equatable {
    let path: String
    let count: Int
}

// MARK: - The rules, checked against the real source tree

/// The structural rules of `Docs/Contract.md`, machine-checked. Why they are
/// tests and not a script: `CONTRIBUTING.md`, *Scope discipline*.
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

    /// Every module's source directory, repo-relative: the unit of every rule
    /// below.
    static let moduleDirectories = [
        "TuberNotesApp",
        // Docs/Forks/fundamental-rewrite.md, Part 8.
        "Modules/TNCore",
        "Modules/TNModel",
        "Modules/TNFormat",
        "Modules/TNNotebook",
        "Modules/TNLibrary",
        "Modules/TNRender",
        "Modules/TNCanvas",
        "Modules/TNEditor",
    ]

    /// The module a policed path belongs to: the last component of the
    /// longest entry above that contains it, at any depth, or "" when none
    /// does. That name is the key of every table below.
    static func module(of path: String) -> String {
        let directory = moduleDirectories
            .filter { path.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
        return directory?.split(separator: "/").last.map(String.init) ?? ""
    }

    /// The fewest Swift sources the application can plausibly have, across
    /// every module.
    ///
    /// The old guard was `names.isEmpty`, which fires only if the source tree
    /// is emptied entirely — an enumeration that returned one file read as a
    /// clean run. Lower it only alongside a real deletion of that many files.
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

    static func projectYAML() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
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

    // MARK: - What project.yml builds

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
        let yaml = try Self.projectYAML()
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let declared = ContractChecker.declaredSourcePaths(inYAML: yaml)
        for directory in Self.moduleDirectories {
            #expect(
                declared.contains(directory),
                """
                project.yml no longer declares \(directory) as a whole source path, so the set of \
                files on disk is no longer the set of files compiled. Decide what the checker \
                polices and say so here.
                """
            )
        }

        let unpoliced = declared.subtracting(Self.moduleDirectories).subtracting(["TuberNotesTests", "TNTests"])
        #expect(
            unpoliced.isEmpty,
            """
            project.yml declares source paths this checker does not police: \(unpoliced.sorted()). \
            A new module policed by nothing is the silence the split was supposed to end — add it \
            to moduleDirectories and to moduleImportPolicy.
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

    /// The SwiftUI ban (`Docs/Contract.md`, *Structure*) is the compiler's,
    /// and this is the one line of it a test can still lose silently.
    ///
    /// The ban itself needs no test: `import SwiftUI` below the app target does
    /// not compile, and a build failure is not something a suite has to notice.
    /// What a suite *can* notice is the flag going missing — delete
    /// `-module-alias SwiftUI=…` from `project.yml` and every module quietly
    /// regains SwiftUI with no test anywhere turning red. It goes missing for
    /// one module as quietly: a target that sets its own `OTHER_SWIFT_FLAGS`,
    /// or does not take the `Framework` template. So this asserts the
    /// mechanism reaches every framework, and leaves the enforcement to it.
    @Test("No module below the app target can import SwiftUI")
    func swiftUIIsBannedBelowTheAppTarget() throws {
        let yaml = try Self.projectYAML()
        let flags = ContractChecker.swiftFlagsSettings(inYAML: yaml)
        #expect(
            flags.count == 1 && flags.allSatisfy { $0.contains("-module-alias SwiftUI=") },
            """
            project.yml sets OTHER_SWIFT_FLAGS \(flags.count) times: \(flags). The one that aliases \
            SwiftUI away must be the only one, because a target's own value replaces the Framework \
            template's and its $(inherited) skips the template. The SwiftUI ban in Contract.md, \
            Structure, is enforced there and nowhere else — restore it, or decide deliberately that \
            a scanner rule replaces it.
            """
        )

        let frameworks = Self.moduleDirectories
            .filter { $0.hasPrefix("Modules/") }
            .map { String($0.dropFirst("Modules/".count)) }
        let untemplated = ContractChecker.targetsWithoutFrameworkTemplate(frameworks, inYAML: yaml)
        #expect(
            untemplated.isEmpty,
            """
            \(untemplated.joined(separator: ", ")) does not take the Framework template, which is where \
            SwiftUI is aliased away, so it can import SwiftUI and nothing but review would say so.
            """
        )
    }

    // MARK: - Rules

    /// Every module each module may import, ours and the system's.
    /// `Docs/Contract.md`, *Structure*.
    ///
    /// The rows of ours are each target's `dependencies:` in `project.yml`,
    /// copied rather than read: the graph is the rule, and a test that read it
    /// from the project would let one added line there permit what the
    /// Contract forbids. The app's row leaves out `TNCanvas`, and `TNCanvas`'s
    /// row has only `TNModel` and `TNCore`. Neither is a build error: every
    /// target compiles against one products directory, and
    /// `transitivelyLinkDependencies` embeds `TNCanvas` in the app, so this
    /// table is what refuses both imports.
    ///
    /// The system rows are what each module imports today, and a framework
    /// joins one by an edit here or not at all. `import PDFKit` or `import
    /// ImageIO` looks like a narrow need and brings UIKit's or CoreGraphics's
    /// whole vocabulary with it.
    ///
    /// **This replaced a twenty-three-entry allowlist of file paths.** The
    /// allowlist could not express the rule it was enforcing: it was one flat
    /// set across three frameworks, so a file permitted CoreGraphics could add
    /// `import PencilKit` in silence, and every entry expired the moment a file
    /// moved. The module is the honest unit — a file's permissions are now a
    /// property of where it lives, which is the same fact the link graph
    /// already carries, and there is nothing left to keep in sync per file.
    ///
    /// The scanner is the enforcement because the compiler cannot be:
    /// PencilKit requires UIKit and Foundation requires CoreGraphics, so
    /// aliasing either away (the trick `project.yml` uses for SwiftUI) breaks
    /// the transitive load as well as the written import.
    static let moduleImportPolicy: [String: Set<String>] = [
        // The SwiftUI shell and the workspace. It holds the canvas as a
        // UIViewController through TNEditor and never names TNCanvas.
        "TuberNotesApp": [
            "TNEditor", "TNLibrary", "TNNotebook", "TNRender", "TNFormat", "TNModel", "TNCore",
            "Foundation", "Observation", "SwiftUI", "UIKit", "PencilKit", "CoreGraphics",
            "PhotosUI", "VisionKit", "UniformTypeIdentifiers",
        ],
        "TNCore": ["Foundation", "os"],
        // PencilKit and CoreGraphics for value types that cross the seams
        // (PKDrawing, CGImage).
        "TNModel": ["TNCore", "Foundation", "PencilKit", "CoreGraphics"],
        // The format touches files in Foundation and POSIX and draws nothing.
        "TNFormat": ["TNModel", "TNCore", "Foundation", "Synchronization"],
        // Composites and thumbnails: CoreGraphics, CoreText, ImageIO,
        // PencilKit for a thumbnail's ink. No UIKit.
        "TNRender": [
            "TNFormat", "TNModel", "TNCore",
            "Foundation", "CoreGraphics", "CoreText", "ImageIO", "PencilKit",
        ],
        // Custody holds PKDrawing values; nothing here draws or touches a file.
        "TNNotebook": [
            "TNRender", "TNFormat", "TNModel", "TNCore",
            "Foundation", "Observation", "PencilKit",
        ],
        // The tree and the trash, in Foundation. Holds Notebooks, so PencilKit
        // for their ink, but writes no UI.
        "TNLibrary": [
            "TNNotebook", "TNRender", "TNFormat", "TNModel", "TNCore",
            "Foundation", "Observation", "PencilKit",
        ],
        // The driven runtime: everything that owns frame-frequency state. It
        // cannot name the format, the notebook, or the library.
        "TNCanvas": [
            "TNModel", "TNCore",
            "Foundation", "UIKit", "PencilKit", "CoreGraphics", "CoreText",
        ],
        // The binding and the editor view model: the one module that names
        // both the canvas and the notebook.
        // UniformTypeIdentifiers names what an export's bytes are.
        "TNEditor": [
            "TNCanvas", "TNNotebook", "TNRender", "TNFormat", "TNModel", "TNCore",
            "Foundation", "Observation", "UIKit", "PencilKit", "CoreGraphics", "UniformTypeIdentifiers",
        ],
    ]

    /// Files whose **module** is the claim, not merely their imports.
    ///
    /// The per-module policy above cannot express this. It permits `TNCanvas`
    /// UIKit, so `PaperRenderer.swift` moved into the canvas runtime would
    /// satisfy every other rule in this file while being exactly what the
    /// design forbids: paper drawn where frame-frequency work lives, one
    /// refactor from a `CAShapeLayer` on the main thread. And `Paper` is a
    /// durable value, so the vocabulary it may not acquire is all of it,
    /// CoreGraphics included, however `TNModel`'s row above reads.
    ///
    /// The third entry made this a rule: a file named here takes the four
    /// `uiFrameworkModules` from its own row and not from its module's.
    /// `TextTypesetting.swift` is the
    /// one typesetting builder the renderer and the live text view share,
    /// and `TNModel` is the only module both can see, so it imports UIKit
    /// where nothing else in `TNModel` may. No entry can outlive its file:
    /// the test below requires **exactly one** match per name, so a rename
    /// fails here rather than passing over nothing.
    static let filesPlacedByDesign: [String: (module: String, forbidden: Set<String>)] = [
        "Paper.swift": ("TNModel", ["UIKit", "PencilKit", "CoreGraphics"]),
        "PaperRenderer.swift": ("TNRender", ["UIKit", "PencilKit"]),
        "TextTypesetting.swift": ("TNModel", ["PencilKit"]),
    ]

    /// What a source may import: its module's row, except that a file placed
    /// by design takes the four `uiFrameworkModules` from its own row.
    static func permittedImports(for path: String) -> Set<String> {
        let row = moduleImportPolicy[module(of: path)] ?? []
        let name = String(path.split(separator: "/").last ?? "")
        guard let rule = filesPlacedByDesign[name] else { return row }
        let ui = ContractChecker.uiFrameworkModules
        return row.subtracting(ui).union(ui.subtracting(rule.forbidden))
    }

    /// The imports a source makes that its row does not permit.
    static func forbiddenImports(in source: CheckedSource) -> Set<String> {
        Set(ContractChecker.importedModules(in: source.code)).subtracting(permittedImports(for: source.path))
    }

    /// UIKit's vocabulary in a source whose row does not permit UIKit.
    static func uiKitVocabulary(in source: CheckedSource) -> [String] {
        permittedImports(for: source.path).contains("UIKit") ? [] : ContractChecker.uiKitIdentifiers(in: source.code)
    }

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

    /// `PackageStore` and `LibraryStore` are the writers of durable state.
    ///
    /// `ImportReader.swift` is here for one read, not a write: a document
    /// picked from the Files picker arrives as a security-scoped URL outside
    /// the sandbox, and its bytes must be read where the scope is held. That
    /// file is the *user's source*, not the notebook's durable state — the
    /// bytes become durable only by passing through `Notebook.importPDF`
    /// and then the store, which remains the one writer.
    ///
    /// A file-path allowlist rather than a module one, deliberately: the app
    /// target's one permitted read is a single file's business, and naming
    /// the module would licence the whole SwiftUI shell.
    static let fileIOAllowlist: Set<String> = [
        // The one file that names a file API inside a package.
        "Modules/TNFormat/PosixFileSystem.swift",
        // The library tree, trash, and staging moves.
        "Modules/TNLibrary/LibraryStore.swift",
        // The import picker's security-scoped read.
        "TuberNotesApp/ImportReader.swift",
        // The three preferences: the palette, the library view and the theme
        // choice. It writes no notebook and no library state, which is what
        // the rule is for — a preference has no integrity to protect, no
        // relationship to any other file, and an unreadable one is replaced
        // by its built-in default at the cost of a tap.
        "TuberNotesApp/PreferenceDefaults.swift",
    ]

    @Test("Each module imports only what its place in the graph allows")
    func eachModuleImportsOnlyWhatItsPlaceAllows() throws {
        for source in try Self.appSources() {
            #expect(
                Self.moduleImportPolicy[Self.module(of: source.path)] != nil,
                "\(source.path) belongs to no module the import policy names"
            )
            let violations = Self.forbiddenImports(in: source)
            #expect(
                violations.isEmpty,
                """
                \(source.path) imports \(violations.sorted().joined(separator: ", ")), which \
                \(Self.module(of: source.path)) may not. Either the file is in the wrong module — move \
                it — or the module's place in the graph changed, which is a contract change: update \
                Docs/Contract.md, project.yml, and moduleImportPolicy together.
                """
            )
        }
    }

    /// PencilKit re-exports UIKit, so below `TNCanvas`, `TNEditor` and the app
    /// the import line alone cannot keep UIKit out. `Docs/Contract.md`,
    /// *Structure*.
    @Test("No module below the UIKit modules names a UIKit type")
    func uiKitVocabularyStaysInTheUIKitModules() throws {
        for source in try Self.appSources() {
            let names = Set(Self.uiKitVocabulary(in: source))
            #expect(
                names.isEmpty,
                """
                \(source.path) names \(names.sorted().joined(separator: ", ")), which \
                \(Self.module(of: source.path)) may not: UIKit belongs to TNCanvas, TNEditor and the \
                app, and PencilKit brought it here unseen. Move the code up the graph, or hand this \
                module a value it may hold.
                """
            )
        }
    }

    /// File I/O is confined to the file-primitive seam (`PosixFileSystem`,
    /// which `PackageStore` drives), `LibraryStore` for the library tree,
    /// and the import picker's security-scoped read, each named individually
    /// in the allowlist (Docs/Forks/fundamental-rewrite.md, Part 8).
    @Test("File I/O is confined to the two store files and the import reader")
    func fileIOIsConfinedToTheStorageActors() throws {
        for source in try Self.appSources() where !Self.fileIOAllowlist.contains(source.path) {
            let hits = ContractChecker.fileIOTokens(in: source.code)
            #expect(
                hits.isEmpty,
                """
                \(source.path) performs file I/O (\(hits.joined(separator: ", "))). \
                PackageStore and LibraryStore are the writers of durable state, one per storage \
                domain; everything else receives and returns values. A POSIX name called with an \
                unlabelled argument is read as POSIX: move a real call into PosixFileSystem, and \
                call a Swift method of that name through self.
                """
            )
        }
    }

    /// `PKCanvasView` is constructed at exactly one code site.
    /// `Docs/Contract.md`, *Structure*, names this a hard invariant.
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
            expected exactly one file constructing PKCanvasView or a subclass of it, found: \
            \(described.isEmpty ? "none" : described.joined(separator: ", "))
            """
        )
        #expect(
            sites.reduce(0) { $0 + $1.count } == 1,
            "PKCanvasView is constructed more than once: \(described.joined(separator: ", "))"
        )
    }

    /// The tool strip is the app's, and the system picker is not used.
    /// `Docs/Contract.md`, *The canvas is told, never asks*.
    @Test("No source names the system tool picker")
    func nothingNamesTheSystemToolPicker() throws {
        let sites = ContractChecker.toolPickerSites(in: try Self.appSources())
        #expect(
            sites.isEmpty,
            """
            \(sites.joined(separator: ", ")) names the system tool picker, which writes \
            canvasView.tool itself. PagedCanvasController.apply is the one writer of the tool, \
            across every live canvas and every canvas built after; a picker driving the first \
            responder would leave the others stale.
            """
        )
    }

    /// `Docs/Contract.md`, *Structure*: the canvas's tool is assigned at
    /// exactly one site, where `apply` lands.
    @Test("The canvas's tool is assigned at exactly one site")
    func theToolHasOneWriter() throws {
        let sites = ContractChecker.toolAssignmentSites(in: try Self.appSources())
        #expect(
            sites.count == 1,
            """
            expected exactly one assignment of canvasView.tool, found \(sites.count): \
            \(sites.joined(separator: ", ")). PageCanvasController.apply(tool:) is where a tool \
            lands, and PagedCanvasController.apply fans it out to every live canvas; a second \
            assignment changes one canvas and leaves the others on the old tool.
            """
        )
    }

    /// `Docs/Contract.md`, *Structure* (decided I5): the theme reaches the
    /// canvas through `apply` and no other way. The names are gone from
    /// `TNModel`, so the build refuses them today; this keeps them gone.
    @Test("The canvas is told the theme: no source in TNCanvas names a theme global")
    func theCanvasNamesNoThemeGlobal() throws {
        let sites = try Self.appSources()
            .filter { Self.module(of: $0.path) == "TNCanvas" && ContractChecker.namesThemeGlobal(in: $0.code) }
            .map(\.path)
        #expect(
            sites.isEmpty,
            """
            \(sites.joined(separator: ", ")) names \(ContractChecker.themeGlobals.joined(separator: " or ")). \
            The canvas is told, never asks: the theme arrives with the tool in CanvasEnvironment, and a global \
            the canvas reads is a second route that misses what apply reaches.
            """
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

    /// Who may read the process's launch arguments or environment.
    static let processReadAllowlist: Set<String> = [
        // Every `-TN…` hook, through `arguments`, which is empty in Release.
        "TuberNotesApp/LaunchHooks.swift",
        // `TN_TRACE` mirrors the log to stderr in every configuration, because
        // a friend's Release build is traced by launching it through devicectl
        // with the variable set; only devicectl or Xcode can set it. TNCore
        // sits below the app, so it cannot read through `LaunchHooks`.
        "Modules/TNCore/TNLog.swift",
    ]

    /// A launch hook is a developer's switch, and the build a person holds
    /// has none.
    @Test("Launch arguments are read only in LaunchHooks")
    func launchArgumentsAreReadOnlyInLaunchHooks() throws {
        for source in try Self.appSources() where !Self.processReadAllowlist.contains(source.path) {
            let reads = ContractChecker.processReads(in: source.code)
            #expect(
                reads.isEmpty,
                """
                \(source.path) reads \(reads.joined(separator: ", ")), which runs in Release. A \
                launch hook reads LaunchHooks.arguments, which is empty there.
                """
            )
        }
    }

    /// An allowlist entry naming a file that no longer exists.
    @Test("No allowlist entry outlives its file")
    func allowlistsNameFilesThatExist() throws {
        let sources = try Self.appSources()

        let staleIO = Self.staleAllowlistEntries(Self.fileIOAllowlist, in: sources)
        #expect(
            staleIO.isEmpty,
            "the file-I/O allowlist names files that do not exist: \(staleIO.joined(separator: ", "))."
        )
        let staleReads = Self.staleAllowlistEntries(Self.processReadAllowlist, in: sources)
        #expect(
            staleReads.isEmpty,
            "the launch-read allowlist names files that do not exist: \(staleReads.joined(separator: ", "))."
        )
    }
}

// MARK: - Tests of the checker itself

/// The rules are only worth trusting if they can fail.
///
/// `CONTRIBUTING.md`, *Scope discipline*: "the checker has its own tests",
/// because an untested checker can go dead and keep passing. These plant
/// real `.swift` files in real subdirectories of a temp tree and assert each
/// rule catches them. Hermetic on purpose — a test that writes into
/// `TuberNotesApp/` and then crashes leaves the repository dirty and the
/// next run lying.
@Suite("Contract structure — the checker")
struct ContractCheckerOwnTests {

    // MARK: A planted source tree

    /// Creates a fresh temp directory, runs `body` against its root, and
    /// removes the tree either way.
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
            try write("import UIKit\n", to: ".build/Hidden.swift", under: root)

            let sources = try ContractChecker.sources(under: root, label: "Planted")

            #expect(sources.map(\.path) == [
                "Planted/One/Second.swift",
                "Planted/One/Two/Third.swift",
                "Planted/One/Two/Three/Fourth.swift",
                "Planted/Top.swift",
            ])
        }
    }

    // MARK: Each rule, planted in a new subdirectory

    /// A `.swift` file planted in a *new subdirectory*, violating each of
    /// the three rules, fails the suite. Before the recursion landed, all
    /// three of these assertions saw an empty list.
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
                in: ContractChecker.withoutComments("// a comment about somethingForTesting\nlet x = 1\n")
            ).isEmpty
        )
    }

    @Test("A read of the launch arguments or environment is caught, and prose is not")
    func processReadsAreCaught() throws {
        try withPlantedTree { root in
            try write("let a = ProcessInfo.processInfo.arguments\n", to: "Deep/RogueHook.swift", under: root)
            try write(
                "let t = ProcessInfo.processInfo.environment[\"X\"]\n",
                to: "Deep/Nested/RogueEnvironment.swift", under: root
            )
            try write("let a = CommandLine.arguments\n", to: "RogueCommandLine.swift", under: root)
            try write(
                "// ProcessInfo.processInfo.arguments is read in LaunchHooks.\nlet x = 1\n",
                to: "Innocent.swift", under: root
            )

            let sources = try ContractChecker.sources(under: root, label: "Planted")
            let reads = sources.filter { !ContractChecker.processReads(in: $0.code).isEmpty }
            #expect(Set(reads.map(\.path)) == [
                "Planted/Deep/RogueHook.swift",
                "Planted/Deep/Nested/RogueEnvironment.swift",
                "Planted/RogueCommandLine.swift",
            ])
        }
    }

    @Test("A source naming the system tool picker is caught, however it names it")
    func toolPickerReferencesAreCaught() throws {
        try withPlantedTree { root in
            try write("import PencilKit\nlet picker = PKToolPicker()\n", to: "Deep/Rogue.swift", under: root)
            // Not a construction, and the rule must still bite: a stored
            // picker is the same second writer.
            try write("import PencilKit\nvar picker: PKToolPicker?\n", to: "Deep/Stored.swift", under: root)
            try write("import PencilKit\nlet canvas = PKCanvasView()\n", to: "Innocent.swift", under: root)

            let sources = try ContractChecker.sources(under: root, label: "Planted")
            #expect(Set(ContractChecker.toolPickerSites(in: sources)) == [
                "Planted/Deep/Rogue.swift",
                "Planted/Deep/Stored.swift",
            ])
        }

        // Prose is not code, here as everywhere: the rule reads
        // `CheckedSource.code`, which has the comments taken out.
        #expect(
            !ContractChecker.namesToolPicker(
                in: ContractChecker.withoutComments("// PKToolPicker is deliberately not used.\nlet x = 1\n")
            )
        )
    }

    @Test("A theme global named in code is caught, and one named in prose is not")
    func themeGlobalsAreCaught() {
        let (current, changed) = (ContractChecker.themeGlobals[0], ContractChecker.themeGlobals[1])
        #expect(ContractChecker.namesThemeGlobal(in: "let theme = \(current)\n"))
        #expect(ContractChecker.namesThemeGlobal(in: "center.addObserver(forName: \(changed), object: nil, queue: nil) { _ in }\n"))
        #expect(
            !ContractChecker.namesThemeGlobal(
                in: ContractChecker.withoutComments("// \(current) is gone.\nlet x = 1\n")
            )
        )
    }

    @Test("A file placed by design is judged by its own row, not its module's")
    func placedFilesAreJudgedByTheirOwnRow() {
        let placed = "Modules/TNModel/TextTypesetting.swift"
        #expect(ContractStructureTests.permittedImports(for: placed).contains("UIKit"))
        #expect(!ContractStructureTests.permittedImports(for: placed).contains("PencilKit"))
        #expect(!ContractStructureTests.permittedImports(for: "Modules/TNModel/Layer.swift").contains("UIKit"))
        let violating = Set(ContractChecker.importedUIFrameworks(in: "import PencilKit\n"))
            .subtracting(ContractStructureTests.permittedImports(for: placed))
        #expect(violating == ["PencilKit"])
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

    // MARK: The module graph, planted where it lives

    /// Each planted source's imports that its row does not permit, by path.
    private func forbiddenImports(under root: URL) throws -> [String: Set<String>] {
        let sources = try ContractChecker.sources(under: root, label: "")
        return Dictionary(uniqueKeysWithValues: sources.map {
            ($0.path, ContractStructureTests.forbiddenImports(in: $0))
        })
    }

    @Test("The app importing TNCanvas is caught, and so is TNCanvas reaching past TNModel")
    func appMayNotImportTNCanvas() throws {
        try withPlantedTree { root in
            try write("import SwiftUI\nimport TNEditor\n", to: "TuberNotesApp/Fine.swift", under: root)
            try write("import SwiftUI\nimport TNCanvas\n", to: "TuberNotesApp/Rogue.swift", under: root)
            try write(
                "@preconcurrency import class TNCanvas.PagedCanvasController\n",
                to: "TuberNotesApp/Scoped.swift", under: root
            )
            try write("import TNModel\nimport TNNotebook\n", to: "Modules/TNCanvas/Reach.swift", under: root)

            #expect(try forbiddenImports(under: root) == [
                "TuberNotesApp/Fine.swift": [],
                "TuberNotesApp/Rogue.swift": ["TNCanvas"],
                "TuberNotesApp/Scoped.swift": ["TNCanvas"],
                "Modules/TNCanvas/Reach.swift": ["TNNotebook"],
            ])
        }
    }

    @Test("TNRender importing PDFKit is caught")
    func tnRenderMayNotImportPDFKit() throws {
        try withPlantedTree { root in
            try write(
                "import CoreGraphics\nimport ImageIO\nimport TNFormat\n",
                to: "Modules/TNRender/Fine.swift", under: root
            )
            try write(
                "import Foundation\nimport PDFKit\n",
                to: "Modules/TNRender/PDFSource.swift", under: root
            )

            #expect(try forbiddenImports(under: root) == [
                "Modules/TNRender/Fine.swift": [],
                "Modules/TNRender/PDFSource.swift": ["PDFKit"],
            ])
        }
    }

    @Test("A source in a module's subdirectory belongs to that module")
    func moduleOfSubdirectory() throws {
        #expect(ContractStructureTests.module(of: "Modules/TNRender/Sub/Deeper/Composite.swift") == "TNRender")
        #expect(ContractStructureTests.module(of: "TuberNotesApp/Library/Cells.swift") == "TuberNotesApp")
        #expect(ContractStructureTests.module(of: "Modules/TNRenderer/Composite.swift") == "")

        try withPlantedTree { root in
            try write("import CoreGraphics\n", to: "Modules/TNRender/Sub/Deeper/Composite.swift", under: root)
            try write("import UIKit\n", to: "Modules/TNRender/Sub/Rogue.swift", under: root)

            #expect(try forbiddenImports(under: root) == [
                "Modules/TNRender/Sub/Deeper/Composite.swift": [],
                "Modules/TNRender/Sub/Rogue.swift": ["UIKit"],
            ])
        }
    }

    @Test("UIKit's vocabulary below the UIKit modules is caught without an import")
    func noUIKitIdentifiersBelowUIKitModules() throws {
        try withPlantedTree { root in
            try write(
                "import PencilKit\nlet lasso = UIBezierPath(rect: .zero)\n",
                to: "Modules/TNNotebook/StrokeGestures.swift", under: root
            )
            // Not UIKit's, though they start with a U.
            try write(
                "let n: UInt8 = 1\nlet id = UUID()\n",
                to: "Modules/TNNotebook/Clean.swift", under: root
            )
            try write(
                "// The UIColor bridge lives in TNEditor.\nlet x = 1\n",
                to: "Modules/TNModel/RGBA8.swift", under: root
            )
            // The one file below them that may, and a module that may.
            try write(
                "import UIKit\nlet font = UIFont.systemFont(ofSize: 12)\n",
                to: "Modules/TNModel/TextTypesetting.swift", under: root
            )
            try write("import UIKit\nlet view = UIView()\n", to: "Modules/TNCanvas/Host.swift", under: root)

            let sources = try ContractChecker.sources(under: root, label: "")
            let found = sources.filter { !ContractStructureTests.uiKitVocabulary(in: $0).isEmpty }
            #expect(found.map(\.path) == ["Modules/TNNotebook/StrokeGestures.swift"])
        }
    }

    // MARK: The canvas, planted where it lives

    @Test("A PKCanvasView subclass is a canvas, at any depth, wherever it is declared")
    func canvasSubclassesAreCounted() throws {
        try withPlantedTree { root in
            // Read before its superclass: the derivation must not depend on
            // the order of the files.
            try write("final class DeeperCanvas: HoverPreviewCanvas {}\n", to: "A/Deeper.swift", under: root)
            try write(
                "import PencilKit\nclass HoverPreviewCanvas: PencilKit.PKCanvasView, @unchecked Sendable {}\n",
                to: "B/Hover.swift", under: root
            )
            // A delegate is not a canvas.
            try write(
                "final class Host: UIViewController, PKCanvasViewDelegate {}\nlet host = Host()\n",
                to: "C/Host.swift", under: root
            )
            try write(
                "let a = HoverPreviewCanvas()\nlet b = DeeperCanvas.init(frame: .zero)\n",
                to: "D/Use.swift", under: root
            )

            let sources = try ContractChecker.sources(under: root, label: "Planted")
            #expect(
                ContractChecker.canvasTypeNames(in: sources) == ["PKCanvasView", "HoverPreviewCanvas", "DeeperCanvas"]
            )
            #expect(ContractChecker.canvasConstructionSites(in: sources) == [
                CanvasConstructionSite(path: "Planted/D/Use.swift", count: 2),
            ])
        }
    }

    @Test("An annotation's .init shorthand is a construction")
    func initShorthandIsCounted() throws {
        try withPlantedTree { root in
            try write("let v: PKCanvasView = .init()\n", to: "Plain.swift", under: root)
            try write("var w: PKCanvasView! = .init(frame: .zero)\n", to: "Unwrapped.swift", under: root)
            try write("var x: PKCanvasView? = .init()\n", to: "Optional.swift", under: root)
            // Not constructions: a default of nil, a comparison, a metatype.
            try write(
                "func f(_ v: PKCanvasView? = nil) {}\n"
                    + "let same = t == PKCanvasView.self\n"
                    + "let m: PKCanvasView.Type = PKCanvasView.self\n",
                to: "Neither.swift", under: root
            )

            let sources = try ContractChecker.sources(under: root, label: "Planted")
            #expect(ContractChecker.canvasConstructionSites(in: sources) == [
                CanvasConstructionSite(path: "Planted/Optional.swift", count: 1),
                CanvasConstructionSite(path: "Planted/Plain.swift", count: 1),
                CanvasConstructionSite(path: "Planted/Unwrapped.swift", count: 1),
            ])
        }
    }

    @Test("A second assignment of the canvas's tool is caught")
    func oneToolWriter() throws {
        try withPlantedTree { root in
            try write("canvasView.tool = pkTool\n", to: "Apply.swift", under: root)
            try write(
                "self.canvasView.tool = PKEraserTool(.vector)\ncanvasView?.tool=PKLassoTool()\n",
                to: "Deep/DoubleTap.swift", under: root
            )
            // Not assignments of the canvas's tool.
            try write(
                "self.tool = tool\nif canvasView.tool == other {}\nlet t = canvasView.tool\n",
                to: "Reads.swift", under: root
            )

            let sources = try ContractChecker.sources(under: root, label: "Planted")
            #expect(ContractChecker.toolAssignmentSites(in: sources) == [
                "Planted/Apply.swift",
                "Planted/Deep/DoubleTap.swift",
                "Planted/Deep/DoubleTap.swift",
            ])
        }
    }

    // MARK: project.yml, planted

    /// Today's `project.yml` with one edit planted in memory.
    private func projectYAML(replacing old: String, with new: String) throws -> String {
        let yaml = try ContractStructureTests.projectYAML()
        #expect(yaml.contains(old), "project.yml no longer reads \(old); plant the edit where it does")
        return yaml.replacingOccurrences(of: old, with: new)
    }

    private let canvasTarget = "  TNCanvas:\n    templates: [Framework]\n"

    @Test("A target's own OTHER_SWIFT_FLAGS, which drops the SwiftUI alias, is caught")
    func swiftFlagsAreSetOnce() throws {
        let profiled = try projectYAML(
            replacing: canvasTarget,
            with: canvasTarget + "    settings:\n      base:\n"
                + "        OTHER_SWIFT_FLAGS: \"$(inherited) -Xfrontend -warn-long-function-bodies=200\"\n"
        )
        #expect(ContractChecker.swiftFlagsSettings(inYAML: profiled).count == 2)
    }

    @Test("A framework target without the Framework template is caught")
    func frameworksUseTheTemplate() throws {
        let untemplated = try projectYAML(replacing: canvasTarget, with: "  TNCanvas:\n    type: framework\n")
        #expect(ContractChecker.targetsWithoutFrameworkTemplate(["TNCore", "TNCanvas"], inYAML: untemplated) == ["TNCanvas"])
    }

    @Test("A source path written short, at its key's depth, or inline is a declared path")
    func shortFormSourcesArePoliced() throws {
        let sources = "    sources:\n      - path: Modules/TNCanvas\n"
        for (planted, declared) in [
            (sources + "      - Modules/Shared\n", "Modules/Shared"),
            ("    sources:\n    - path: Modules/TNCanvas\n    - Modules/Shared\n", "Modules/Shared"),
            ("    sources: [Modules/TNCanvas, Modules/Shared]\n", "[Modules/TNCanvas, Modules/Shared]"),
        ] {
            let yaml = try projectYAML(replacing: sources, with: planted)
            #expect(ContractChecker.declaredSourcePaths(inYAML: yaml).contains(declared), "missed \(planted)")
        }
    }

    // MARK: Strings

    /// An interpolation is code, so what a string holds reaches every rule.
    /// The scanner still tracks strings: the last file proves a `//` inside
    /// one is not read as a comment.
    @Test("A string's contents count, and a // inside a string is not a comment")
    func stringLiteralsCount() throws {
        try withPlantedTree { root in
            try write(
                #"let message = "FileManager could not open PKCanvasView(""# + "\n",
                to: "Plain.swift", under: root
            )
            try write(
                #"let path = "\(FileManager.default.temporaryDirectory)""# + "\n",
                to: "Interpolated.swift", under: root
            )
            try write(
                "let body = \"\"\"\n    \\(FileManager.default)\n    \"\"\"\n",
                to: "MultiLine.swift", under: root
            )
            try write(##"let raw = #"\#(FileManager.default)"#"## + "\n", to: "Raw.swift", under: root)
            try write(#"let quoted = "a \" // FileManager""# + "\n", to: "EscapedQuote.swift", under: root)

            let sources = try ContractChecker.sources(under: root, label: "Planted")
            #expect(sources.count == 5)
            for source in sources {
                #expect(
                    ContractChecker.fileIOTokens(in: source.code) == ["FileManager"],
                    "\(source.path) hid FileManager in a string: \(source.code)"
                )
            }
            #expect(ContractChecker.canvasConstructionSites(in: sources).map(\.path) == ["Planted/Plain.swift"])
        }
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
                ContractChecker.importsUIFramework(ContractChecker.withoutComments(line + "\n")),
                "the import rule missed \(line)"
            )
        }

        let ignored = [
            "import Foundation",
            "import os",
            // Not one of the four: the compiler refuses SwiftUI below the app.
            "import SwiftUI",
            "let importUIKit = 1",
            "#if canImport(UIKit)",
            "func doImport() {}",
        ]
        for line in ignored {
            #expect(
                !ContractChecker.importsUIFramework(ContractChecker.withoutComments(line + "\n")),
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
            "let d = NSData(contentsOf: url)",
            "let out = OutputStream(url: url, append: false)",
            "let f = fopen(path, \"w\")",
            "UserDefaults.standard.set(1, forKey: \"k\")",
            "let names = try fm.contentsOfDirectory(atPath: p)",
            "let tmp = URL.temporaryDirectory.appending(path: name)",
            "let docs = URL.documentsDirectory",
            "let tmp = NSTemporaryDirectory()",
            "let home = NSHomeDirectory()",
            "FileRepresentation(exportedContentType: .pdf) { pdf in SentTransferredFile(pdf.url) }",
            "try renderer.writePDF(to: url) { _ in }",
            "let document = CGPDFDocument(url as CFURL)",
            "let destination = CGImageDestinationCreateWithURL(u, type, 1, nil)",
            "let consumer = CGDataConsumer(url: u)",
            "let provider = CGDataProvider(url: u)",
            "let fd = open(url.path(percentEncoded: false), O_RDONLY)",
        ]
        for line in caught {
            #expect(
                !ContractChecker.fileIOTokens(in: ContractChecker.withoutComments(line + "\n")).isEmpty,
                "the file-I/O rule missed \(line)"
            )
        }
        #expect(
            ContractChecker.fileIOTokens(
                in: "open(p, 0); creat(p, 0); rename(a, b); unlink(p); mkdir(p, 0); rmdir(p); remove(p); truncate(p, 0)"
            ) == ["open(", "creat(", "rename(", "unlink(", "mkdir(", "rmdir(", "remove(", "truncate("]
        )

        let ignored = [
            // A stream is not storage: TNLog's stderr mirror must stay legal.
            "fputs(message, stderr)",
            // A labelled call, a member call, or a declaration is not POSIX.
            "let notebook = try await Notebook.open(store: store)",
            "pages.remove(page)",
            "func remove(_ page: Page) {}",
            "let reopened = reopen(notebook)",
        ]
        for line in ignored {
            #expect(ContractChecker.fileIOTokens(in: line).isEmpty, "the file-I/O rule tripped on \(line)")
        }
    }

    /// Prose is not code. A comment that mentions a forbidden token must not
    /// trip any rule — this is the exact false positive that made the old
    /// shell gate cry wolf. A string is not prose: `stringLiteralsCount`.
    @Test("A comment does not trip the checker")
    func aCommentDoesNotTripTheChecker() {
        let source = """
        import Foundation
        // We use fputs, not FileHandle.write(to:), because the stream is not storage.
        /* A block comment mentioning FileManager.default.removeItem and
           PKCanvasView() and even import UIKit on its own line. */
        // canvasView.tool = PKEraserTool(.vector) would be a second writer.
        """
        let code = ContractChecker.withoutComments(source)

        #expect(!ContractChecker.importsUIFramework(code), "an import named inside a comment was read as code")
        #expect(ContractChecker.canvasConstructionCount(in: code) == 0, "a comment was read as a construction site")
        #expect(ContractChecker.fileIOTokens(in: code).isEmpty, "a comment was read as file I/O")
        #expect(ContractChecker.uiKitIdentifiers(in: code).isEmpty, "a comment was read as UIKit's vocabulary")
        #expect(ContractChecker.toolAssignmentCount(in: code) == 0, "a comment was read as a tool assignment")
    }
}
