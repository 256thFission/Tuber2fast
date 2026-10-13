import CryptoKit
import Foundation
import ImageIO
import PDFKit
import PencilKit
import Testing
import UIKit
@testable import TNEditor
@testable import TNFormat
@testable import TNLibrary
@testable import TNModel
@testable import TNNotebook
@testable import TNRender

/// `Fixtures/Golden/v<N>/` (`Docs/Contract.md`, *A golden corpus pins every
/// version the format has written*): a library as a build at format version
/// N left it, and `manifest.sha256` naming every file in it with its digest.
/// What the generator wrote is spelled here once, for it and for the tests
/// that read the corpus back.
enum Golden {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Golden", isDirectory: true)
    static let current = directory.appendingPathComponent("v\(NotebookIndex.currentFormatVersion)", isDirectory: true)
    static let manifestName = "manifest.sha256"

    static let blank = "Blank.tubernotes"
    static let physics = "Physics"
    static let lecture = "Physics/Lecture.tubernotes"
    static let week = "Physics/Week 1"
    static let worksheet = "Physics/Week 1/Worksheet.tubernotes"
    static let physicsDecoration = FolderDecoration(color: .blue, symbol: .school)
    static let marks = ["Homework 1", ""]

    /// Blank's third page: a box at each alignment, the first holding a run
    /// in each style a run can carry, the last one locked.
    static let boxes: [(alignment: TextAlignment, runs: [TextRun])] = {
        let styles: [TextStyle] = [
            .body,
            .body.with(bold: true),
            .body.with(italic: true),
            .body.with(underline: true),
            .body.with(color: RGBA8(red: 0xC2, green: 0x19, blue: 0x19, alpha: 0xFF)),
            .body.with(size: 32),
        ]
        return [
            (.leading, styles.enumerated().map { TextRun(string: "Style \($0.offset). ", style: $0.element) }),
            (.center, [TextRun(string: "Centred", style: .body)]),
            (.trailing, [TextRun(string: "Locked", style: .body)]),
        ]
    }()

    static func packageURL(_ path: String) -> URL {
        current.appendingPathComponent("Notebooks").appendingPathComponent(path)
    }

    /// The tool the bar hands the canvas for `kind` at `width`.
    static func tool(_ kind: InkKind, _ width: ToolWidth) throws -> PKInkingTool {
        let canvasTool = EditorTool.ink(kind, InkPreset(color: kind == .highlighter ? .yellow : .black, width: width)).canvasTool
        let inking: PKInkingTool? = if case .ink(let tool) = canvasTool { tool as? PKInkingTool } else { nil }
        return try #require(inking)
    }

    /// Every ink at every width, in the order Blank's first page holds them.
    static func everyTool() throws -> [PKInkingTool] {
        try InkKind.allCases.flatMap { kind in try ToolWidth.allCases.map { try tool(kind, $0) } }
    }

    static func line(
        _ kind: InkKind, _ width: ToolWidth, from: (Double, Double), to: (Double, Double), mask: UIBezierPath? = nil
    ) throws -> PKStroke {
        let tool = try tool(kind, width)
        return Ink.line(from: CGPoint(x: from.0, y: from.1), to: CGPoint(x: to.0, y: to.1), width: tool.width, type: tool.ink.inkType, mask: mask)
    }

    /// A letter page, a letter page turned a quarter, and an A5 landscape.
    static func lecturePDF() throws -> Data {
        let sizes = [CGSize(width: 612, height: 792), CGSize(width: 612, height: 792), CGSize(width: 595.28, height: 419.53)]
        let document = try #require(PDFDocument(data: try Fixture.shapedPDF(sizes: sizes)))
        let turned = try #require(document.page(at: 1))
        turned.rotation = 90
        return try #require(document.dataRepresentation())
    }

    /// Every file under `root`, hidden ones among them, by path from it. A
    /// `.DS_Store` is the Finder's, not the corpus's.
    static func files(under root: URL) throws -> [String] {
        let base = root.resolvingSymlinksInPath().path + "/"
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var paths: [String] = []
        for case let url as URL in enumerator where url.lastPathComponent != ".DS_Store" {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            paths.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count)))
        }
        return paths.sorted()
    }

    /// `shasum -a 256` lines for every file under `root` but the manifest:
    /// what the generator writes beside the files and the test recomputes.
    static func manifest(of root: URL) throws -> String {
        try files(under: root).filter { $0 != manifestName }.map { path in
            let digest = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(path)))
            return digest.map { String(format: "%02x", $0) }.joined() + "  " + path + "\n"
        }.joined()
    }

    /// A copy of the current corpus as a library base, for anything that
    /// opens a library: `LibraryStore` makes its directories and sweeps
    /// Staging, and nothing may write to the checked-in files.
    static func copy(_ name: String) throws -> Scratch {
        let scratch = try Scratch(name)
        for item in try FileManager.default.contentsOfDirectory(atPath: current.path) where item != manifestName {
            try FileManager.default.copyItem(at: current.appendingPathComponent(item), to: scratch.root.appendingPathComponent(item))
        }
        return scratch
    }

    /// What a file is, by where it sits, and its production reader: the
    /// file's kind, which its key-set pins start from, and a read that
    /// answers the bytes this build writes for what it read, or nil for a
    /// file that is not JSON. A staged file that was never published reads
    /// as the file it would have become.
    static func reader(of path: String) throws -> (family: String, read: (Data) throws -> Data?)? {
        let url = current.appendingPathComponent(path)
        var name = url.lastPathComponent
        // `tmp-<UUID>-<name>`, as `tempURL(beside:)` spells it.
        if name.hasPrefix(PackageStore.tempPrefix) { name = String(name.dropFirst(PackageStore.tempPrefix.count + 37)) }
        let identity = UUID.canonical(String(name.prefix(36)))
        switch (url.deletingLastPathComponent().lastPathComponent, name) {
        case (_, "Favorites.json"):
            return (name, { try Codecs.encode(Codecs.decodeStrict(FavoritesFile.self, from: $0)) })
        case (_, ".folder.json"):
            return (name, { try Codecs.encode(Codecs.decodeStrict(FolderFile.self, from: $0)) })
        case (_, "origin.json"):
            return (name, { try Codecs.encode(Codecs.decodeStrict(TrashOrigin.self, from: $0)) })
        case (_, "notebook.json"):
            return (name, { try Codecs.encode(IndexFile.decode($0).validated()) })
        case (_, "view.json"):
            return (name, { try Codecs.encode(Codecs.decodeStrict(ViewState.self, from: $0)) })
        case ("pages", _):
            let page = PageID(raw: try #require(identity))
            return ("page", { try Codecs.encode(Codecs.decodeStrict(PageFile.self, from: $0).validated(expecting: page)) })
        case ("layers", _):
            let layer = LayerID(raw: try #require(identity))
            return ("layer", { try LayerFile.encode(LayerFile.decode($0, expecting: layer).get()) })
        case ("ink", _):
            let page = PageID(raw: try #require(identity))
            let package = PackageLayout(root: url.deletingLastPathComponent().deletingLastPathComponent())
            let notebook = try IndexFile.header(Data(contentsOf: package.indexURL)).notebookID
            return ("ink", { _ = try PKDrawing(data: InkContainer.decode($0, expecting: notebook, page: page)); return nil })
        case ("assets", _):
            switch try #require(AssetRef(fileName: name)).format {
            case .heic:
                return ("heic", { data in
                    _ = try #require(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
                    return nil
                })
            case .pdf:
                return ("pdf", { data in
                    try #require((PDFSource(data: data)?.pageCount ?? 0) > 0)
                    return nil
                })
            }
        default:
            return nil
        }
    }
}

@Suite("Format: the golden corpus")
@MainActor
struct GoldenCorpusTests {
    @Test("Every version's corpus is the bytes its manifest names, no more and no fewer")
    func manifestsHold() throws {
        let versions = try FileManager.default.contentsOfDirectory(atPath: Golden.directory.path).filter { $0.hasPrefix("v") }
        #expect(versions.contains(Golden.current.lastPathComponent))
        for version in versions {
            let root = Golden.directory.appendingPathComponent(version)
            let written = try String(contentsOf: root.appendingPathComponent(Golden.manifestName), encoding: .utf8)
            #expect(written.split(separator: "\n") == (try Golden.manifest(of: root)).split(separator: "\n"), "\(version)")
        }
    }

    @Test("Every file reads through its production reader, every JSON file encodes again byte for byte, and every kind of file is there")
    func everyFileReads() throws {
        var families = Set<String>()
        for path in try Golden.files(under: Golden.current) where path != Golden.manifestName {
            guard let reader = try Golden.reader(of: path) else {
                Issue.record("\(path) is no file the format writes")
                continue
            }
            families.insert(reader.family)
            let data = try Data(contentsOf: Golden.current.appendingPathComponent(path))
            do {
                if let again = try reader.read(data) { #expect(again == data, "\(path) encodes again differently") }
            } catch {
                Issue.record("\(path) does not read: \(error)")
            }
        }
        #expect(families == [
            "notebook.json", "view.json", "page", "layer", "ink", "heic", "pdf", ".folder.json", "Favorites.json", "origin.json",
        ])
    }

    @Test("Every object in the corpus carries exactly its pin's keys, and every pin is in the corpus")
    func keySetsAreThePins() throws {
        let pins = packageKeyPins.merging(sidecarKeyPins) { first, _ in first }
        var seen = Set<String>()
        for path in try Golden.files(under: Golden.current) where path.hasSuffix(".json") {
            let family = try #require(try Golden.reader(of: path)).family
            for object in keySets(of: try jsonObject(Data(contentsOf: Golden.current.appendingPathComponent(path))), at: family) {
                seen.insert(object.path)
                #expect(pins[object.path] == object.keys, "\(path): \(object.path)")
            }
        }
        #expect(seen == Set(pins.keys))
    }

    @Test("The library reads back as the generator left it: the tree, the decoration, the stars, the trash")
    func libraryReads() async throws {
        let scratch = try Golden.copy("golden-library")
        let store = try LibraryStore(base: scratch.root)
        let tree = try await store.listTree(under: "")
        #expect(tree.map(\.relativePath) == [Golden.blank, Golden.physics, Golden.lecture, Golden.week, Golden.worksheet])
        #expect(tree.allSatisfy { $0.fault == nil && $0.identity != nil })
        #expect(try await store.folderFile(of: Golden.physics).decoration == Golden.physicsDecoration)
        #expect(try await store.folderFile(of: Golden.week).decoration == .plain)
        let starred = tree.filter { [Golden.blank, Golden.physics].contains($0.relativePath) }.compactMap(\.identity)
        #expect(try await store.favorites() == Set(starred))
        let origins = try await store.listTrash().map { try $0.origin.get() }
        #expect(Set(origins.map { LibraryPath.join($0.originPathHint, $0.originName) }) == ["Old notes.tubernotes", "Physics/Old folder"])
    }

    @Test("Blank reads back as flow 1 wrote it: four papers, every ink, text in every style, links, marks, page two in view")
    func blankReads() async throws {
        let root = Golden.packageURL(Golden.blank)
        let store = PackageStore(root: root)
        let loaded = try await store.load()
        #expect(loaded.pageFaults.isEmpty)
        let index = loaded.index
        let ids = index.pageIDs
        #expect(index.pages.map(\.paper) == DrawnPaper.allCases.map(Paper.drawn))
        #expect(index.bookmarks == [PageBookmark(page: ids[0], title: Golden.marks[0]), PageBookmark(page: ids[3], title: Golden.marks[1])])
        #expect(await store.readView() == ViewState(currentPageID: ids[1]))
        var pages: [PageBytes] = []
        for id in ids { pages.append(try await store.loadPage(id)) }
        #expect(pages.allSatisfy { $0.faults.isEmpty && !$0.inkRecordNeeded })

        // Every ink at every width, then the stroke the pixel eraser cut and
        // the one that ran off the page.
        let strokes = try PKDrawing(data: try #require(pages[0].inkArchive)).strokes
        let tools = try Golden.everyTool()
        try #require(strokes.count == tools.count + 2)
        for (stroke, tool) in zip(strokes, tools) {
            let point = try #require(stroke.path.first)
            #expect(stroke.ink.inkType == tool.ink.inkType)
            #expect(abs(point.size.width - tool.width) < 0.01)
        }
        #expect(strokes[tools.count].mask != nil)
        let paper = CGRect(x: 0, y: 0, width: index.pages[0].width, height: index.pages[0].height)
        #expect(!paper.contains(strokes[tools.count + 1].renderBounds))

        // Drawn on and erased to nothing: the flag stays, and its container
        // holds an empty drawing.
        #expect(pages[1].file.hasInk)
        let erased = try PKDrawing(data: try #require(pages[1].inkArchive))
        #expect(erased.strokes.isEmpty)

        // Never drawn on: no flag and no container.
        #expect(!pages[2].file.hasInk && pages[2].inkArchive == nil)
        #expect(!FileManager.default.fileExists(atPath: PackageLayout(root: root).inkURL(ids[2]).path))
        let boxes = pages[2].layers.compactMap { if case .text(let text) = $0.payload { text } else { nil } }
        #expect(boxes.map(\.alignment) == Golden.boxes.map(\.alignment))
        #expect(boxes.map(\.runs) == Golden.boxes.map(\.runs))
        #expect(pages[2].layers.map(\.locked) == [false, false, true])

        let lecture = try await PackageStore(root: Golden.packageURL(Golden.lecture)).load().index
        let targets = pages[3].layers.compactMap { if case .link(let link) = $0.payload { link.target } else { nil } }
        #expect(targets == [.internalPage(ids[1]), .externalPage(notebook: lecture.notebookID, page: lecture.pageIDs[0])])
    }

    @Test("Lecture reads back as flow 2 wrote it: a PDF's pages turned and sized as it says, highlights, a clipping, a turned photo, photo paper")
    func lectureReads() async throws {
        let store = PackageStore(root: Golden.packageURL(Golden.lecture))
        let loaded = try await store.load()
        #expect(loaded.pageFaults.isEmpty)
        let records = loaded.index.pages
        try #require(records.count == 4)
        let pdf = try #require(records[0].paperAsset)
        #expect(records.prefix(3).map(\.paper) == (0..<3).map { Paper.pdf(pdf, sourcePageIndex: $0) })
        let sizes = records.prefix(3).map { [$0.width, $0.height].map { ($0 * 100).rounded() / 100 } }
        #expect(sizes == [[612, 792], [792, 612], [595.28, 419.53]])
        #expect(records[3].paperAsset?.format == .heic)
        for record in records.dropFirst() {
            #expect(try await store.loadPage(record.id).faults.isEmpty)
        }

        let slide = try await store.loadPage(records[0].id)
        #expect(slide.faults.isEmpty)
        let highlights = try PKDrawing(data: try #require(slide.inkArchive))
        #expect(highlights.strokes.map(\.ink.inkType) == [.marker, .marker])
        try #require(slide.layers.count == 2)
        guard case .pdf(let clipping) = slide.layers[0].payload, case .image = slide.layers[1].payload else {
            Issue.record("the slide's layers are \(slide.layers.map(\.payload.kind))")
            return
        }
        #expect(clipping.asset == pdf && clipping.sourcePageIndex == 2)
        #expect(slide.layers[1].transform.b != 0, "the photo is turned on the page")
    }

    @Test("Worksheet reads back as flow 3 wrote it, with what a crash left beside it")
    func worksheetReads() async throws {
        let layout = PackageLayout(root: Golden.packageURL(Golden.worksheet))
        let store = PackageStore(root: layout.root)
        let loaded = try await store.load()
        #expect(loaded.pageFaults.isEmpty)
        let records = loaded.index.pages
        try #require(records.count == 2)
        guard case .pdf(let pdf, 0) = records[0].paper, case .image(let flattened) = records[1].paper else {
            Issue.record("the worksheet's papers are \(records.map(\.paper))")
            return
        }
        let sheet = try await store.loadPage(records[0].id)
        #expect(sheet.faults.isEmpty && !sheet.inkRecordNeeded)
        let answers = try PKDrawing(data: try #require(sheet.inkArchive))
        #expect(answers.strokes.count == 3)

        // The hand-in page's first stroke: its container landed, its page
        // file did not, and open adopts it.
        let handIn = try await store.loadPage(records[1].id)
        #expect(handIn.faults.isEmpty && handIn.inkRecordNeeded && !handIn.file.hasInk)
        let adopted = try PKDrawing(data: try #require(handIn.inkArchive))
        #expect(adopted.strokes.count == 1)

        // The answers' next save, staged and never published, which no reader opens.
        let ink = try FileManager.default.contentsOfDirectory(atPath: layout.inkDirectory.path)
        #expect(ink.filter { $0.hasPrefix(PackageStore.tempPrefix) }.count == 1)

        // A new page whose box and page file landed and whose index did not,
        // beside the blank first page the import took the place of, whose
        // file waits for compact.
        let named = Set(records.map { layout.pageURL($0.id).lastPathComponent })
        var strays: [[LayerKind]] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: layout.pagesDirectory.path) where !named.contains(name) {
            let stray = try await store.loadPage(PageID(raw: try #require(UUID.canonical(String(name.prefix(36))))))
            #expect(stray.faults.isEmpty)
            strays.append(stray.layers.map(\.payload.kind))
        }
        #expect(strays.sorted { $0.count < $1.count } == [[], [.text]])

        // A photo whose layer never landed.
        let assets = try FileManager.default.contentsOfDirectory(atPath: layout.assetsDirectory.path)
        #expect(Set(assets).subtracting([pdf.fileName, flattened.fileName]).count == 1)
    }

    @Test("A copy carried one version up, with a key this build does not write, is refused by its number and changes nothing")
    func aNewerNotebookIsRefusedByItsNumber() async throws {
        let scratch = try Golden.copy("golden-newer")
        let package = scratch.root.appendingPathComponent("Notebooks").appendingPathComponent(Golden.blank)
        let indexURL = PackageLayout(root: package).indexURL
        let newer = NotebookIndex.currentFormatVersion + 1
        var object = try jsonObject(Data(contentsOf: indexURL))
        object["formatVersion"] = newer
        object["title"] = "Homework"
        try jsonData(object).write(to: indexURL)
        let before = try Golden.manifest(of: package)

        let library = Library(store: try LibraryStore(base: scratch.root))
        var refusal: LibraryError?
        if case .failed(let error) = await library.checkout(Golden.blank, schedule: fast) { refusal = error }
        #expect(refusal == LibraryError.format(.newerFormat(found: newer)))
        #expect(refusal?.description == "made by a newer TuberNotes; update the app")
        #expect(try Golden.manifest(of: package) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.store.stagingRoot.path).isEmpty)
    }
}

#if DEBUG
/// Writes the corpus for the current version into `Fixtures/Golden/v<N>/`,
/// over whatever is there, through the APIs the three flows use. Run it on
/// purpose and alone; `TEST_RUNNER_` is how the variable reaches the
/// simulator's test process:
///
///     TEST_RUNNER_TN_WRITE_GOLDEN=1 xcodebuild test -project TuberNotes.xcodeproj \
///       -scheme TuberNotes -only-testing:TNTests/GoldenCorpusGenerator \
///       -destination "platform=iOS Simulator,name=$(< Tools/pinned-simulator)"
@Suite("Format: the golden corpus generator")
@MainActor
struct GoldenCorpusGenerator {
    @Test(
        "Writes the corpus for the current version",
        .enabled(if: ProcessInfo.processInfo.environment["TN_WRITE_GOLDEN"] != nil, "Rewrites the checked-in corpus, so it runs only on purpose")
    )
    func write() async throws {
        let scratch = try Scratch("golden-write")
        let library = Library(store: try LibraryStore(base: scratch.root))
        let store = library.store
        let physics = try await store.createFolder(named: Golden.physics, in: "")
        try await store.setDecoration(Golden.physicsDecoration, at: physics.relativePath)
        _ = try await store.createFolder(named: "Week 1", in: physics.relativePath)
        let lecture = try await writeLecture(in: library)
        try await writeWorksheet(in: library)
        let blank = try await writeBlank(in: library, linkingTo: lecture)
        try await store.setFavorite(blank, true)
        try await store.setFavorite(try #require(physics.identity), true)
        let oldNotes = try await store.createNotebook(named: "Old notes", in: "")
        _ = try await library.trash(at: oldNotes.relativePath)
        let oldFolder = try await store.createFolder(named: "Old folder", in: physics.relativePath)
        _ = try await library.trash(at: oldFolder.relativePath)
        try placeCrashLeftovers(in: store.url(of: Golden.worksheet))

        let files = FileManager.default
        if files.fileExists(atPath: Golden.current.path) { try files.removeItem(at: Golden.current) }
        try files.createDirectory(at: Golden.current, withIntermediateDirectories: true)
        for name in ["Notebooks", "Trash", "Favorites.json"] {
            try files.copyItem(at: scratch.root.appendingPathComponent(name), to: Golden.current.appendingPathComponent(name))
        }
        try Golden.manifest(of: Golden.current)
            .write(to: Golden.current.appendingPathComponent(Golden.manifestName), atomically: true, encoding: .utf8)
    }

    /// Flow 2: a lecture PDF in place of the blank first page, highlights,
    /// a clipping of the third slide, a photo turned on the page, and a photo
    /// as a new page's paper. Returns the notebook and its first slide, for
    /// Blank's link into it.
    private func writeLecture(in library: Library) async throws -> (notebook: NotebookID, page: PageID) {
        let item = try await library.store.createNotebook(named: "Lecture", in: Golden.physics)
        let notebook = try await open(item.relativePath, in: library)
        let pdf = try Golden.lecturePDF()
        let slides = try await notebook.importPDF(pdf)
        let asset = try #require(notebook.paper(of: slides[0])?.asset)
        notebook.inkChanged(on: slides[0], PKDrawing(strokes: [
            try Golden.line(.highlighter, .medium, from: (72, 120), to: (420, 120)),
            try Golden.line(.highlighter, .thick, from: (72, 180), to: (300, 180)),
        ]))
        let extent = try #require(PDFSource(data: pdf)?.page(at: 2).flatMap { PDFSource.displayExtent(of: $0) })
        let clipping = Layer(
            id: LayerID(),
            transform: .placing(sourceWidth: extent.width, sourceHeight: extent.height, at: (72, 420), scale: 0.5),
            payload: .pdf(PDFLayer(asset: asset, sourcePageIndex: 2, sourceExtent: extent)))
        try await notebook.addLayer(clipping, assetData: pdf, on: slides[0])
        try await notebook.importImage(try Fixture.imageData(width: 300, height: 200), on: slides[0])
        let photo = try #require(notebook.state(of: slides[0])?.content?.layers.last)
        let turned = photo.transform.concatenating(PageSpaceTransform(a: 0.8, b: 0.6, c: -0.6, d: 0.8, tx: 120, ty: -40))
        #expect(notebook.transformLayer(on: slides[0], layer: photo.id, to: turned) == .accepted)
        let photoPage = notebook.appendPage(after: slides.last)
        try await notebook.importImageAsPaper(try Fixture.imageData(width: 300, height: 400), on: photoPage)
        try await close(notebook, at: item.relativePath, in: library)
        return (notebook.notebookID, slides[0])
    }

    /// Flow 3: a worksheet PDF in place of the blank first page, answers
    /// written on it, and the page flattened into a new one to hand in.
    private func writeWorksheet(in library: Library) async throws {
        let item = try await library.store.createNotebook(named: "Worksheet", in: Golden.week)
        let notebook = try await open(item.relativePath, in: library)
        let sheet = try #require(try await notebook.importPDF(try Fixture.pdfData(pages: 1)).first)
        notebook.inkChanged(on: sheet, PKDrawing(strokes: [
            try Golden.line(.pen, .thin, from: (60, 120), to: (300, 130)),
            try Golden.line(.pen, .medium, from: (60, 220), to: (240, 210)),
            try Golden.line(.pencil, .thin, from: (60, 320), to: (330, 330)),
        ]))
        let flattened = try await notebook.flatten(sheet)
        let geometry = try #require(notebook.index.record(of: sheet)).geometry
        _ = try await notebook.appendPage(after: sheet, geometry: geometry, paper: .asset(.image(flattened)))
        try await close(notebook, at: item.relativePath, in: library)
    }

    /// Flow 1: the four papers; every ink at every width, a stroke the pixel
    /// eraser cut and one that ran off the page; a page drawn on and erased;
    /// text through a session at each alignment, the last box locked; a link
    /// inside the notebook and one into the lecture; a titled and an untitled
    /// mark; and the second page in view. Returns its identity, for a star.
    private func writeBlank(in library: Library, linkingTo lecture: (notebook: NotebookID, page: PageID)) async throws -> ItemIdentity {
        let item = try await library.store.createNotebook(named: "Blank", in: "")
        let notebook = try await open(item.relativePath, in: library)
        var pages = notebook.pageIDs
        for paper in [DrawnPaper.lined, .grid, .dotted] {
            pages.append(try await notebook.appendPage(after: pages.last, geometry: .letter, paper: .drawn(paper)))
        }

        // The pixel eraser masks the stroke it cuts rather than splitting it.
        var strokes = try Golden.everyTool().enumerated().map { offset, tool in
            let y = 72 + 48 * Double(offset)
            return Ink.line(from: CGPoint(x: 72, y: y), to: CGPoint(x: 420, y: y + 12), width: tool.width, type: tool.ink.inkType)
        }
        strokes.append(try Golden.line(.pen, .medium, from: (72, 540), to: (420, 540), mask: UIBezierPath(rect: CGRect(x: 72, y: 520, width: 160, height: 40))))
        strokes.append(try Golden.line(.pen, .medium, from: (480, 700), to: (700, 860)))
        notebook.inkChanged(on: pages[0], PKDrawing(strokes: strokes))

        notebook.inkChanged(on: pages[1], PKDrawing(strokes: [try Golden.line(.pen, .thin, from: (72, 100), to: (300, 100))]))
        notebook.inkChanged(on: pages[1], PKDrawing())

        for (offset, box) in Golden.boxes.enumerated() {
            notebook.createTextBox(on: pages[2], at: PagePoint(x: 72, y: 72 + 140 * Double(offset)), style: .body, alignment: box.alignment)
            let content = try #require(notebook.state(of: pages[2])?.content)
            let layer = try #require(content.layers.first { $0.id == content.textEditing?.layer })
            notebook.endTextEditing(on: pages[2], layer: layer.id, TextLayer(rect: try #require(layer.rect), runs: box.runs, alignment: box.alignment))
        }
        let last = try #require(notebook.state(of: pages[2])?.content?.layers.last)
        #expect(notebook.setLayerLock(last.id, on: pages[2], locked: true) == .accepted)

        try notebook.addLinkLayer(on: pages[3], rect: PageRect(x: 72, y: 72, width: 200, height: 44), target: .internalPage(pages[1]))
        try notebook.addLinkLayer(
            on: pages[3], rect: PageRect(x: 72, y: 160, width: 200, height: 44),
            target: .externalPage(notebook: lecture.notebook, page: lecture.page))
        notebook.bookmark(pages[0], titled: Golden.marks[0])
        notebook.bookmark(pages[3], titled: Golden.marks[1])
        notebook.pageBecameCurrent(pages[1])
        try await close(notebook, at: item.relativePath, in: library)
        return try #require(item.identity)
    }

    /// What a crash leaves beside a saved notebook, placed by hand because no
    /// writer leaves it on purpose: the hand-in page's first stroke, whose
    /// container landed and whose page file did not; the answers' next save,
    /// staged and never published; a new page whose text box and page file
    /// landed and whose index did not; and a photo whose layer never landed.
    private func placeCrashLeftovers(in root: URL) throws {
        let layout = PackageLayout(root: root)
        let index = try IndexFile.decode(Data(contentsOf: layout.indexURL))
        let (sheet, handIn) = (index.pageIDs[0], index.pageIDs[1])
        let stroke = PKDrawing(strokes: [try Golden.line(.pen, .thin, from: (80, 80), to: (240, 90))])
        try InkContainer.encode(notebookID: index.notebookID, pageID: handIn, archive: stroke.dataRepresentation())
            .write(to: layout.inkURL(handIn))
        try Data(contentsOf: layout.inkURL(sheet)).write(to: PosixFileSystem().tempURL(beside: layout.inkURL(sheet)))
        let box = Layer(id: LayerID(), transform: .identity, payload: .text(TextLayer(
            rect: TextLayer.newBox.moved(to: PagePoint(x: 72, y: 72)),
            runs: [TextRun(string: "Never saved", style: .body)], alignment: .leading)))
        try LayerFile.encode(box).write(to: layout.layerURL(box.id))
        let stray = PageFile(pageID: PageID(), hasInk: false, layers: [box.id])
        try Codecs.encode(stray).write(to: layout.pageURL(stray.pageID))
        let flattened = try #require(index.pages[1].paperAsset)
        try Data(contentsOf: layout.assetURL(flattened)).write(to: layout.assetURL(AssetRef(id: AssetID(), format: .heic)))
    }

    /// Checked out as the app opens a notebook, with every page held ready as
    /// the window holds the ones it shows, so an import can take the place of
    /// a blank first page.
    private func open(_ path: String, in library: Library) async throws -> Notebook {
        var opened: Notebook?
        if case .opened(let notebook) = await library.checkout(path, schedule: fast) { opened = notebook }
        let notebook = try #require(opened, "\(path) did not open")
        notebook.windowChanged(to: notebook.pageIDs)
        try await waitUntil { notebook.pageIDs.allSatisfy { notebook.state(of: $0)?.content != nil } }
        return notebook
    }

    private func close(_ notebook: Notebook, at path: String, in library: Library) async throws {
        let outcome = await notebook.close()
        try #require(outcome == .clean, "\(path) closed \(outcome)")
        library.release(path)
    }
}
#endif
