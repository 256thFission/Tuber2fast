import Foundation
import Testing
@testable import TNFormat
@testable import TNModel

/// Every object the package writes and the keys it carries, written out by
/// hand at the paths `keySets(of:at:)` spells, each file's path starting
/// from its name. What this build writes must match them (`KeySetPins`), and
/// so must the golden corpus, in both directions (`GoldenCorpusTests`).
let packageKeyPins: [String: Set<String>] = {
    let layer: Set<String> = ["layerID", "kind", "transform", "locked"]
    let rect: Set<String> = ["x", "y", "width", "height"]
    return [
        "notebook.json": ["formatVersion", "notebookID", "createdAt", "pages", "bookmarks"],
        "notebook.json.pages[]": ["id", "width", "height", "paper"],
        "notebook.json.pages[].paper(blank)": ["kind"],
        "notebook.json.pages[].paper(lined)": ["kind"],
        "notebook.json.pages[].paper(grid)": ["kind"],
        "notebook.json.pages[].paper(dotted)": ["kind"],
        "notebook.json.pages[].paper(image)": ["kind", "asset"],
        "notebook.json.pages[].paper(pdf)": ["kind", "asset", "sourcePageIndex"],
        "notebook.json.bookmarks[]": ["page", "title"],
        "page": ["pageID", "hasInk", "layers"],
        "view.json": ["currentPageID"],
        "layer(image)": layer.union(["image"]),
        "layer(image).image": ["asset", "naturalSize"],
        "layer(image).image.naturalSize": ["width", "height"],
        "layer(pdf)": layer.union(["pdf"]),
        "layer(pdf).pdf": ["asset", "sourcePageIndex", "sourceExtent"],
        "layer(pdf).pdf.sourceExtent": rect.union(["rotation"]),
        "layer(link)": layer.union(["link"]),
        "layer(link).link": ["rect", "target"],
        "layer(link).link.rect": rect,
        "layer(link).link.target(internal)": ["scope", "pageID"],
        "layer(link).link.target(external)": ["scope", "notebookID", "pageID"],
        "layer(text)": layer.union(["text"]),
        "layer(text).text": ["rect", "runs", "alignment"],
        "layer(text).text.rect": rect,
        "layer(text).text.runs[]": ["string", "font", "size", "bold", "italic", "underline", "color"],
    ]
}()

@Suite("Format: key sets are pinned")
struct KeySetPins {
    @Test("Every object in every file this build writes carries exactly its pin's keys, and every pin is written")
    func everyObjectCarriesItsPin() throws {
        let papers: [Paper] = DrawnPaper.allCases.map(Paper.drawn) + [
            .image(AssetRef(id: AssetID(), format: .heic)), .pdf(AssetRef(id: AssetID(), format: .pdf), sourcePageIndex: 3),
        ]
        let plain = NotebookIndex(
            notebookID: NotebookID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            pages: papers.map { PageRecord(id: PageID(), geometry: .letter, paper: $0) },
            bookmarks: [])
        let index = try jsonObject(Codecs.encode(plain.withBookmarks([PageBookmark(page: plain.pageIDs[0], title: "Chapter one")])))
        let external = Layer(id: LayerID(), transform: .identity, payload: .link(LinkLayer(
            rect: PageRect(x: 1, y: 1, width: 10, height: 10),
            target: .externalPage(notebook: NotebookID(), page: PageID()))))
        var written = keySets(of: index, at: "notebook.json")
            + keySets(of: try jsonObject(Codecs.encode(PageFile(pageID: PageID(), hasInk: true, layers: [LayerID()]))), at: "page")
            + keySets(of: try jsonObject(Codecs.encode(ViewState(currentPageID: PageID()))), at: "view.json")
        for layer in [Fixture.imageLayer(), Fixture.pdfLayer(), Fixture.linkLayer(to: PageID()), external, Fixture.textLayer()] {
            written += keySets(of: try jsonObject(LayerFile.encode(layer)), at: "layer")
        }
        for object in written {
            #expect(packageKeyPins[object.path] == object.keys, "\(object.path)")
        }
        #expect(Set(written.map(\.path)) == Set(packageKeyPins.keys))
        #expect(index["formatVersion"] as? Int == 1)
    }
}

@Suite("Format: strict decode refuses by name")
struct StrictDecode {
    @Test("An extra key in any object of any file, at any depth, is refused naming its path")
    func anExtraKeyAtEveryLevelIsRefused() throws {
        var walked = Set<String>()
        for shape in try everyShape() {
            let variants = everyObject(in: shape.object) { path, object in
                walked.insert(path)
                var wide = object
                wide["extra"] = true
                return [(FormatFault.unknownKey(path.isEmpty ? "extra" : "\(path).extra").description, wide)]
            }
            for variant in variants {
                #expect(shape.refusal(try jsonData(try #require(variant.tree as? [String: Any]))) == variant.said, "\(shape.file)")
            }
        }
        #expect(walked.isSuperset(of: [
            "pages[0]", "pages[2].paper", "bookmarks[0]", "image", "image.naturalSize",
            "pdf.sourceExtent", "link.rect", "link.target", "text.rect", "text.runs[1]",
        ]))
    }

    @Test("A key missing from any object of any file, at any depth, is refused naming it")
    func aMissingKeyAtEveryLevelIsRefused() throws {
        for shape in try everyShape() {
            let variants = everyObject(in: shape.object) { path, object in
                object.keys.map { key in
                    var short = object
                    short.removeValue(forKey: key)
                    // A layer file's ID is read before any key, to name the file.
                    let said = path.isEmpty && key == "layerID" ? "layerID is not a canonical UUID" : FormatFault.missingKey(key).description
                    return (said, short)
                }
            }
            for variant in variants {
                #expect(shape.refusal(try jsonData(try #require(variant.tree as? [String: Any]))) == variant.said, "\(shape.file)")
            }
        }
    }

    @Test("A formatVersion that is not a number is refused as missing")
    func unnumberedVersion() throws {
        var unnumbered = try jsonObject(try Codecs.encode(Fixture.index(pages: 1)))
        unnumbered["formatVersion"] = "1"
        #expect(throws: FormatFault.missingKey("formatVersion")) { try IndexFile.decode(try jsonData(unnumbered)) }
    }

    @Test("A newer version that adds a key and drops one refuses by its number, and its header still reads")
    func newerVersionWithChangedKeysRefusesByVersion() throws {
        let index = Fixture.index(pages: 1)
        let newer = NotebookIndex.currentFormatVersion + 1
        var object = try jsonObject(try Codecs.encode(index))
        object["formatVersion"] = newer
        object["title"] = "Physics"
        object.removeValue(forKey: "bookmarks")
        let data = try jsonData(object)
        #expect(throws: FormatFault.newerFormat(found: newer)) { try IndexFile.decode(data) }
        let header = try IndexFile.header(data)
        #expect(header.formatVersion == newer)
        #expect(header.notebookID == index.notebookID)
        #expect(header.createdAt == index.createdAt)
    }

    @Test("A newer version with this version's keys refuses by its number")
    func newerVersionSameShapeRefusesByVersion() throws {
        let newer = NotebookIndex.currentFormatVersion + 1
        var object = try jsonObject(try Codecs.encode(Fixture.index(pages: 1)))
        object["formatVersion"] = newer
        #expect(throws: FormatFault.newerFormat(found: newer)) { try IndexFile.decode(try jsonData(object)) }
    }

    @Test("The decoder refuses an older version by its number before any key: only a step reads that shape")
    func olderVersionIsRefusedBeforeTheLadder() throws {
        let older = NotebookIndex.currentFormatVersion - 1
        var object = try jsonObject(try Codecs.encode(Fixture.index(pages: 1)))
        object["formatVersion"] = older
        object.removeValue(forKey: "bookmarks")
        #expect(throws: FormatFault.olderFormat(found: older)) { try IndexFile.decode(try jsonData(object)) }
    }

    @Test("The ladder ships empty, and carries a version only from as far down as it holds steps")
    func ladderReach() throws {
        #expect(IndexFile.migrationSteps.isEmpty)
        let current = NotebookIndex.currentFormatVersion
        let step: MigrationStep = { _, _ in }
        #expect(try IndexFile.steps(from: current, in: [step]).isEmpty)
        #expect(try IndexFile.steps(from: current - 1, in: [step]).count == 1)
        #expect(throws: FormatFault.olderFormat(found: current - 1)) { try IndexFile.steps(from: current - 1, in: IndexFile.migrationSteps) }
        #expect(throws: FormatFault.newerFormat(found: current + 1)) { try IndexFile.steps(from: current + 1, in: [step]) }
    }

    @Test("A paper kind this build does not write refuses the whole index at the current version, by its name before its keys")
    func paperOfAnUnwrittenKindRefusesTheIndex() throws {
        var object = try jsonObject(try Codecs.encode(Fixture.index(pages: 2)))
        var pages = try #require(object["pages"] as? [[String: Any]])
        let asset = AssetRef(id: AssetID(), format: .heic).fileName
        for paper: [String: Any] in [["kind": "parchment"], ["kind": "parchment", "asset": asset]] {
            pages[1]["paper"] = paper
            object["pages"] = pages
            let data = try jsonData(object)
            let fault = #expect(throws: FormatFault.self) { try IndexFile.decode(data) }
            guard case .corruptJSON(let detail) = fault else { Issue.record("\(String(describing: fault))"); continue }
            #expect(detail.hasSuffix("paper kind parchment is not one this build writes"))
        }
    }

    @Test("A bookmark naming a page the index does not hold refuses the notebook")
    func bookmarkWithoutItsPage() throws {
        let index = Fixture.index(pages: 2)
        let stray = PageID()
        let broken = index.withBookmarks([PageBookmark(page: stray, title: "gone")])
        #expect(throws: NotebookIndexFault.bookmarkedPageMissing(stray)) { try broken.validated() }
        // And through the reader, since that is where a file on disk arrives.
        let decoded = try IndexFile.decode(try Codecs.encode(broken))
        #expect(throws: NotebookIndexFault.bookmarkedPageMissing(stray)) { try decoded.validated() }
    }

    @Test("Two bookmarks for one page refuse the notebook")
    func twoBookmarksForOnePage() throws {
        let index = Fixture.index(pages: 2)
        let page = index.pageIDs[0]
        let broken = index.withBookmarks([
            PageBookmark(page: page, title: "one"),
            PageBookmark(page: page, title: "two"),
        ])
        #expect(throws: NotebookIndexFault.duplicateBookmark(page)) { try broken.validated() }
    }

    @Test("`withPages` that drops a page drops its bookmark, and the result validates")
    func withPagesDropsOrphanedBookmarks() throws {
        // This is publish 3 of a save: a page that failed to stage is dropped
        // from the index that gets written. Without the filter, the written
        // index names a bookmark with no page and this build's own
        // `validated()` refuses to open the notebook ever again.
        let index = Fixture.index(pages: 3)
        let kept = index.pages[0].id
        let dropped = index.pages[1].id
        let marked = index.withBookmarks([
            PageBookmark(page: kept, title: "stays"),
            PageBookmark(page: dropped, title: "goes"),
        ])

        let present = marked.withPages(marked.pages.filter { $0.id != dropped })
        #expect(present.bookmarks.map(\.page) == [kept])
        #expect(throws: Never.self) { try present.validated() }
        // And the bytes it would write read back.
        #expect(try IndexFile.decode(try Codecs.encode(present)).validated() == present)
    }

    @Test("Every paper kind round-trips through the index")
    func paperKinds() throws {
        let heic = AssetRef(id: AssetID(), format: .heic)
        let pdf = AssetRef(id: AssetID(), format: .pdf)
        let papers: [Paper] = DrawnPaper.allCases.map(Paper.drawn) + [.image(heic), .pdf(pdf, sourcePageIndex: 3)]
        let index = NotebookIndex(
            notebookID: NotebookID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            pages: papers.map { PageRecord(id: PageID(), geometry: .letter, paper: $0) },
            bookmarks: [])
        let data = try Codecs.encode(index)
        let decoded = try IndexFile.decode(data).validated()
        #expect(decoded == index)
    }

    @Test("An asset paper naming a file of the other format refuses the index")
    func assetPaperOfTheOtherFormat() throws {
        let assets: [(Paper, AssetRef)] = [
            (.image(AssetRef(id: AssetID(), format: .heic)), AssetRef(id: AssetID(), format: .pdf)),
            (.pdf(AssetRef(id: AssetID(), format: .pdf), sourcePageIndex: 2), AssetRef(id: AssetID(), format: .heic)),
        ]
        for (paper, wrongFormat) in assets {
            let index = NotebookIndex(
                notebookID: NotebookID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                pages: [PageRecord(id: PageID(), geometry: .letter, paper: paper)],
                bookmarks: [])
            let base = try jsonObject(try Codecs.encode(index))
            let paperObject = try #require((base["pages"] as? [[String: Any]])?[0]["paper"] as? [String: Any])
            func data(withPaper object: [String: Any]) throws -> Data {
                var page = try #require((base["pages"] as? [[String: Any]])?[0])
                page["paper"] = object
                var top = base
                top["pages"] = [page]
                return try jsonData(top)
            }
            var mismatched = paperObject
            mismatched["asset"] = wrongFormat.fileName
            #expect(throws: (any Error).self) { try IndexFile.decode(try data(withPaper: mismatched)) }
        }
    }

    @Test("A layer file naming a kind this build does not write is unreadable and says why")
    func layerFileRefusals() throws {
        var unknown = try jsonObject(try LayerFile.encode(Fixture.imageLayer()))
        unknown["kind"] = "hologram"
        unknown["hologram"] = ["body": "hi"]
        unknown.removeValue(forKey: "image")
        let id = LayerID(raw: UUID(uuidString: unknown["layerID"] as! String)!)
        #expect(LayerFile.decode(try jsonData(unknown), expecting: id) == .failure(.fileUnreadable(id, "layer kind hologram is not one this build writes")))
    }

    @Test("A locked layer of every kind round-trips locked, and an unlocked one unlocked")
    func lockRoundTrips() throws {
        for layer in [Fixture.imageLayer(), Fixture.pdfLayer(), Fixture.linkLayer(to: PageID()), Fixture.textLayer()] {
            #expect(layer.locked == false)
            #expect(LayerFile.decode(try LayerFile.encode(layer), expecting: layer.id) == .success(layer))
            let locked = layer.withLock(true)
            let object = try jsonObject(try LayerFile.encode(locked))
            #expect(object["locked"] as? Bool == true)
            let decoded = LayerFile.decode(try LayerFile.encode(locked), expecting: locked.id)
            #expect(decoded == .success(locked))
            #expect(try decoded.get().locked)
            #expect(decoded != .success(layer), "the lock is part of the value")
        }
    }

    @Test("A link layer with a non-identity transform, or an external target, round-trips or refuses as specified")
    func linkShapes() throws {
        let external = Layer(id: LayerID(), transform: .identity, payload: .link(LinkLayer(
            rect: PageRect(x: 1, y: 1, width: 10, height: 10),
            target: .externalPage(notebook: NotebookID(), page: PageID()))))
        #expect(LayerFile.decode(try LayerFile.encode(external), expecting: external.id) == .success(external))
        let skewed = Fixture.linkLayer(to: PageID()).withTransform(.scale(2))
        #expect(LayerFile.decode(try LayerFile.encode(skewed), expecting: skewed.id) == .failure(.linkTransformNotIdentity(skewed.id)))
    }

    @Test("A text layer round-trips its runs and refuses a bad color or a non-identity transform")
    func textShapes() throws {
        let text = Fixture.textLayer()
        #expect(LayerFile.decode(try LayerFile.encode(text), expecting: text.id) == .success(text))
        let bad = Layer(id: LayerID(), transform: .identity, payload: .text(TextLayer(
            rect: PageRect(x: 0, y: 0, width: 10, height: 10),
            runs: [TextRun(string: "x", font: TextFont.system.rawValue, size: 16, bold: false, italic: false, underline: false, color: "red")],
            alignment: .center)))
        #expect(LayerFile.decode(try LayerFile.encode(bad), expecting: bad.id) == .failure(.invalidText(bad.id)))
        let moved = text.withTransform(.translation(x: 1, y: 1))
        #expect(LayerFile.decode(try LayerFile.encode(moved), expecting: moved.id) == .failure(.textTransformNotIdentity(moved.id)))
    }
}

/// A file of every shape the package holds, each layer kind and both link
/// scopes among them, with how its reader words a refusal: nil when the
/// file reads.
private func everyShape() throws -> [(file: String, object: [String: Any], refusal: (Data) -> String?)] {
    func reading(_ read: @escaping (Data) throws -> Void) -> (Data) -> String? {
        { data in
            do { try read(data); return nil } catch { return "\(error)" }
        }
    }
    let papers: [Paper] = [.drawn(.lined), .image(AssetRef(id: AssetID(), format: .heic)), .pdf(AssetRef(id: AssetID(), format: .pdf), sourcePageIndex: 3)]
    let index = NotebookIndex(
        notebookID: NotebookID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        pages: papers.map { PageRecord(id: PageID(), geometry: .letter, paper: $0) },
        bookmarks: [])
    var shapes: [(file: String, object: [String: Any], refusal: (Data) -> String?)] = [
        ("notebook.json", try jsonObject(Codecs.encode(index.withBookmarks([PageBookmark(page: index.pageIDs[0], title: "One")]))),
         reading { _ = try IndexFile.decode($0) }),
        ("page file", try jsonObject(Codecs.encode(PageFile(pageID: PageID(), hasInk: true, layers: [LayerID()]))),
         reading { _ = try Codecs.decodeStrict(PageFile.self, from: $0) }),
        ("view.json", try jsonObject(Codecs.encode(ViewState(currentPageID: PageID()))),
         reading { _ = try Codecs.decodeStrict(ViewState.self, from: $0) }),
    ]
    let external = Layer(id: LayerID(), transform: .identity, payload: .link(LinkLayer(
        rect: PageRect(x: 1, y: 1, width: 10, height: 10),
        target: .externalPage(notebook: NotebookID(), page: PageID()))))
    for layer in [Fixture.imageLayer(), Fixture.pdfLayer(), Fixture.linkLayer(to: PageID()), external, Fixture.textLayer()] {
        shapes.append(("\(layer.payload.kind) layer", try jsonObject(LayerFile.encode(layer)), { data in
            switch LayerFile.decode(data, expecting: layer.id) {
            case .success: nil
            case .failure(.fileUnreadable(_, let detail)): detail
            case .failure(let fault): "\(fault)"
            }
        }))
    }
    return shapes
}

/// The tree once for each object in it and each edit `edits` makes to that
/// object, with what the edit says the reader should answer. Paths are
/// spelled as `Codecs.decodeStrict` spells them.
private func everyObject(
    in node: Any, at path: String = "", _ edits: (String, [String: Any]) -> [(String, [String: Any])]
) -> [(said: String, tree: Any)] {
    switch node {
    case let object as [String: Any]:
        var trees: [(said: String, tree: Any)] = edits(path, object).map { ($0.0, $0.1) }
        for (key, child) in object {
            for edited in everyObject(in: child, at: path.isEmpty ? key : "\(path).\(key)", edits) {
                var copy = object
                copy[key] = edited.tree
                trees.append((edited.said, copy))
            }
        }
        return trees
    case let array as [Any]:
        var trees: [(said: String, tree: Any)] = []
        for (offset, element) in array.enumerated() {
            for edited in everyObject(in: element, at: "\(path)[\(offset)]", edits) {
                var copy = array
                copy[offset] = edited.tree
                trees.append((edited.said, copy))
            }
        }
        return trees
    default:
        return []
    }
}

@Suite("Format: the ink container")
struct InkContainerTests {
    @Test("Round trip, and every header field is checked")
    func roundTripAndTamper() throws {
        let notebook = NotebookID(), page = PageID()
        let archive = Fixture.archive(3)
        let data = InkContainer.encode(notebookID: notebook, pageID: page, archive: archive)
        #expect(data.count == InkContainer.headerLength + archive.count)
        #expect(try InkContainer.decode(data, expecting: notebook, page: page) == archive)

        func tampered(_ mutate: (inout Data) -> Void) -> Data { var copy = data; mutate(&copy); return copy }
        #expect(throws: InkContainerFault.badMagic) { try InkContainer.decode(tampered { $0[0] = 0x58 }, expecting: notebook, page: page) }
        #expect(throws: InkContainerFault.unsupportedVersion(2)) { try InkContainer.decode(tampered { $0[4] = 2 }, expecting: notebook, page: page) }
        #expect(throws: InkContainerFault.notebookIDMismatch) { try InkContainer.decode(data, expecting: NotebookID(), page: page) }
        #expect(throws: InkContainerFault.pageIDMismatch) { try InkContainer.decode(data, expecting: notebook, page: PageID()) }
        #expect(throws: InkContainerFault.lengthMismatch(declared: UInt64(archive.count), actual: archive.count - 1)) {
            try InkContainer.decode(data.dropLast(), expecting: notebook, page: page)
        }
        #expect(throws: InkContainerFault.checksumMismatch) {
            try InkContainer.decode(tampered { $0[InkContainer.headerLength + 5] ^= 0xFF }, expecting: notebook, page: page)
        }
        #expect(throws: InkContainerFault.tooShort) { try InkContainer.decode(data.prefix(10), expecting: notebook, page: page) }
    }

    @Test("CRC32 matches the reference value for a known string")
    func crcReference() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }
}

@Suite("Format: the store")
struct StoreTests {
    @Test("A save is reproduced exactly by a fresh store's load and loadPage")
    func roundTrip() async throws {
        let scratch = try Scratch("roundtrip")
        let (_, index, layer) = try await Fixture.populated(at: scratch.packageURL)
        let reopened = PackageStore(root: scratch.packageURL)
        let loaded = try await reopened.load()
        #expect(loaded.index == index)
        #expect(loaded.pageFaults.isEmpty)
        let page0 = try await reopened.loadPage(index.pageIDs[0])
        #expect(page0.inkArchive == Fixture.archive(1))
        #expect(page0.faults.isEmpty)
        let page1 = try await reopened.loadPage(index.pageIDs[1])
        #expect(page1.inkArchive == Fixture.archive(2))
        #expect(page1.layers == [layer])
        #expect(page1.file.layers == [layer.id])
        let page2 = try await reopened.loadPage(index.pageIDs[2])
        #expect(page2.inkArchive == nil)
        #expect(page2.faults.isEmpty)
        #expect(page2.file.hasInk == false)
    }

    @Test("A page whose paper asset is missing is refused, and the notebook still opens")
    func paperAssetMissing() async throws {
        let scratch = try Scratch("paper-asset")
        let asset = AssetRef(id: AssetID(), format: .heic)
        let index = NotebookIndex(
            notebookID: NotebookID(), createdAt: Date(),
            pages: [PageRecord(id: PageID(), geometry: .letter, paper: .image(asset)),
                    PageRecord(id: PageID(), geometry: .letter, paper: .drawn(.lined))],
            bookmarks: [])
        let store = try await PackageStore.create(root: scratch.packageURL, index: index)
        try await store.writeAsset(Fixture.archive(4, count: 256), asset)
        #expect(try await store.load().pageFaults.isEmpty)

        try FileManager.default.removeItem(at: store.layout.assetURL(asset))
        let loaded = try await PackageStore(root: scratch.packageURL).load()
        #expect(loaded.index.pageIDs == index.pageIDs)
        #expect(loaded.pageFaults[index.pageIDs[0]] == [.paperAssetMissing(asset.fileName)])
        #expect(loaded.pageFaults[index.pageIDs[1]] == nil)
    }

    @Test("No package means noPackage, never nil or a blank notebook")
    func noPackage() async throws {
        let scratch = try Scratch("nopackage")
        await #expect(throws: FormatFault.noPackage) { try await PackageStore(root: scratch.packageURL).load() }
    }

    @Test("An unchanged page is not rewritten; a changed page's file is")
    func writesOnlyWhatChanged() async throws {
        let scratch = try Scratch("onlychanged")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        let layout = store.layout
        let untouched = layout.pageURL(index.pageIDs[1])
        let untouchedInk = layout.inkURL(index.pageIDs[1])
        try scratch.backdate(untouched, by: 3600)
        try scratch.backdate(untouchedInk, by: 3600)
        let before = try PosixFileSystem().modificationTime(untouched)
        let beforeInk = try PosixFileSystem().modificationTime(untouchedInk)

        let batch = SaveBatch(index: index, indexChanged: false, pages: [
            PageWrite(file: PageFile(pageID: index.pageIDs[0], hasInk: true, layers: []), ink: .archive(Fixture.archive(7)), layerFiles: []),
            PageWrite(file: PageFile(pageID: index.pageIDs[1], hasInk: true, layers: try await store.loadPage(index.pageIDs[1]).file.layers), ink: .unchanged, layerFiles: []),
        ])
        let report = try await store.save(batch)
        #expect(report.refusals.isEmpty)
        #expect(report.committed == Set(index.pageIDs.prefix(2)))
        #expect(try PosixFileSystem().modificationTime(untouched) == before)
        #expect(try PosixFileSystem().modificationTime(untouchedInk) == beforeInk)
        #expect(try await store.loadPage(index.pageIDs[0]).inkArchive == Fixture.archive(7))
    }

    @Test("A refused new page is absent from the committed index and the other pages commit")
    func refusedNewPageIsAbsent() async throws {
        let scratch = try Scratch("refusednew")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        let newPage = PageRecord(id: PageID(), geometry: .letter, paper: .drawn(.grid))
        let intended = index.withPages(index.pages + [newPage])
        let dangling = Fixture.imageLayer()  // its asset was never written
        let batch = SaveBatch(index: intended, indexChanged: true, pages: [
            PageWrite(file: PageFile(pageID: newPage.id, hasInk: false, layers: [dangling.id]), ink: .unchanged, layerFiles: [dangling]),
            PageWrite(file: PageFile(pageID: index.pageIDs[2], hasInk: true, layers: []), ink: .archive(Fixture.archive(5)), layerFiles: []),
        ])
        let report = try await store.save(batch)
        #expect(report.refusals[newPage.id] == .danglingAsset(dangling.id, dangling.payload.asset!))
        #expect(report.indexWritten)
        #expect(report.omitted == [newPage.id], "the report names the page the written index left out")
        #expect(report.committed.contains(index.pageIDs[2]))
        let loaded = try await PackageStore(root: scratch.packageURL).load()
        #expect(loaded.index.pageIDs == index.pageIDs)
        #expect(loaded.pageFaults.isEmpty)
    }

    @Test("An empty intersection withholds the index and reports it")
    func emptyIntersectionWithholds() async throws {
        let scratch = try Scratch("withheld")
        let index = Fixture.index(pages: 1)
        let store = PackageStore(root: scratch.packageURL)
        for directory in store.layout.directories { try PosixFileSystem().createDirectory(directory) }
        let dangling = Fixture.imageLayer()
        let batch = SaveBatch(index: index, indexChanged: true, pages: [
            PageWrite(file: PageFile(pageID: index.pageIDs[0], hasInk: false, layers: [dangling.id]), ink: .unchanged, layerFiles: [dangling]),
        ])
        let report = try await store.save(batch)
        #expect(report.indexWithheld)
        #expect(!report.indexWritten)
        await #expect(throws: FormatFault.noPackage) { try await PackageStore(root: scratch.packageURL).load() }
    }

    @Test("A container under hasInk=false is adopted and flagged for recording")
    func hasInkRecovery() async throws {
        let scratch = try Scratch("recovery")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        let page = index.pageIDs[2]
        let container = InkContainer.encode(notebookID: index.notebookID, pageID: page, archive: Fixture.archive(4))
        try container.write(to: store.layout.inkURL(page))
        let bytes = try await store.loadPage(page)
        #expect(bytes.inkArchive == Fixture.archive(4))
        #expect(bytes.inkRecordNeeded)
        #expect(bytes.faults.isEmpty)
    }

    @Test("A container that does not read under hasInk=false refuses the page, never a blank")
    func aBadContainerRefusesThePage() async throws {
        let scratch = try Scratch("badcontainer")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        let page = index.pageIDs[2]
        try Data("torn".utf8).write(to: store.layout.inkURL(page))
        let bytes = try await store.loadPage(page)
        #expect(bytes.faults == [.inkContainerInvalid(.tooShort)])
        #expect(bytes.inkArchive == nil)
        #expect(!bytes.inkRecordNeeded)
    }

    @Test("A stat that fails other than by absence throws the save, and the index keeps every page")
    func aStatFailureIsNotAbsence() async throws {
        let scratch = try Scratch("stat")
        let (_, index, _) = try await Fixture.populated(at: scratch.packageURL)
        let store = PackageStore(root: scratch.packageURL, fileSystem: FaultingFileSystem(faults: [.failStat]))
        let batch = SaveBatch(index: index.withBookmarks([PageBookmark(page: index.pageIDs[0], title: "x")]), indexChanged: true, pages: [
            PageWrite(file: PageFile(pageID: index.pageIDs[0], hasInk: true, layers: []), ink: .archive(Fixture.archive(6)), layerFiles: []),
        ])
        // Page 0 is committed by the save; page 1 is the first the index
        // must look for.
        await #expect(throws: FormatFault.io(FileSystemError(.stat, store.layout.pageURL(index.pageIDs[1]).path, code: EIO))) {
            try await store.save(batch)
        }
        #expect(try await PackageStore(root: scratch.packageURL).load().index == index)
    }

    @Test("A stat that fails other than by absence on open refuses the page it touches, never the notebook")
    func aStatFailureRefusesOnlyItsPage() async throws {
        func stat(_ url: URL) -> FileSystemError { FileSystemError(.stat, url.path, code: EIO) }
        let scratch = try Scratch("stat-page")
        let (_, index, layer) = try await Fixture.populated(at: scratch.packageURL)
        let store = PackageStore(root: scratch.packageURL, fileSystem: FaultingFileSystem(faults: [.failStat]))
        let loaded = try await store.load()
        #expect(loaded.index == index)
        for page in index.pageIDs {
            #expect(loaded.pageFaults[page] == [.pageFileUnreadable("stat: \(stat(store.layout.pageURL(page)))")])
        }
        let asset = try #require(layer.payload.asset)
        let bytes = try await store.loadPage(index.pageIDs[1])
        #expect(bytes.layers.isEmpty)
        #expect(bytes.faults == [.layerRefused(.fileUnreadable(layer.id, "asset \(asset.fileName): \(stat(store.layout.assetURL(asset)))"))])

        let paperScratch = try Scratch("stat-paper")
        let paper = AssetRef(id: AssetID(), format: .heic)
        let papered = NotebookIndex(
            notebookID: NotebookID(), createdAt: Date(),
            pages: [PageRecord(id: PageID(), geometry: .letter, paper: .image(paper))], bookmarks: [])
        try await PackageStore.create(root: paperScratch.packageURL, index: papered).writeAsset(Fixture.archive(4, count: 256), paper)
        let paperStore = PackageStore(root: paperScratch.packageURL, fileSystem: FaultingFileSystem(faults: [.failStat]))
        #expect(try await paperStore.load().pageFaults[papered.pageIDs[0]] == [
            .pageFileUnreadable("stat: \(stat(paperStore.layout.pageURL(papered.pageIDs[0])))"),
            .pageFileUnreadable("paper asset \(paper.fileName): \(stat(paperStore.layout.assetURL(paper)))"),
        ])
    }

    @Test("hasInk=true with no container is a page fault, never a blank")
    func missingInkIsAFault() async throws {
        let scratch = try Scratch("missingink")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        try FileManager.default.removeItem(at: store.layout.inkURL(index.pageIDs[0]))
        let bytes = try await PackageStore(root: scratch.packageURL).loadPage(index.pageIDs[0])
        #expect(bytes.faults == [.missingInk])
        #expect(!bytes.faults.isEmpty)
    }

    @Test("Writing ink to a page whose file says hasInk=false is refused")
    func inkRequiresHasInk() async throws {
        let scratch = try Scratch("inkflag")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        let batch = SaveBatch(index: index, indexChanged: false, pages: [
            PageWrite(file: PageFile(pageID: index.pageIDs[2], hasInk: false, layers: []), ink: .archive(Fixture.archive(1)), layerFiles: []),
        ])
        let report = try await store.save(batch)
        #expect(report.refusals[index.pageIDs[2]] == .inkWithoutHasInk)
    }

    @Test("No free space refuses before anything is written")
    func freeSpacePreflight() async throws {
        let scratch = try Scratch("nospace")
        _ = try await Fixture.populated(at: scratch.packageURL)
        let store = PackageStore(root: scratch.packageURL, fileSystem: FaultingFileSystem(faults: [.noSpace]))
        let loaded = try await store.load()
        let batch = SaveBatch(index: loaded.index, indexChanged: false, pages: [
            PageWrite(file: PageFile(pageID: loaded.index.pageIDs[0], hasInk: true, layers: []), ink: .archive(Fixture.archive(8)), layerFiles: []),
        ])
        var refused = false
        do { _ = try await store.save(batch) } catch FormatFault.insufficientSpace { refused = true } catch { Issue.record("\(error)") }
        #expect(refused)
        #expect(try await PackageStore(root: scratch.packageURL).loadPage(loaded.index.pageIDs[0]).inkArchive == Fixture.archive(1))
        #expect(try PosixFileSystem().list(store.layout.inkDirectory).allSatisfy { !$0.hasPrefix(PackageStore.tempPrefix) })
    }

    @Test("view.json is disposable: written by rename, read back, and nil when invalid")
    func viewState() async throws {
        let scratch = try Scratch("view")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        #expect(await store.readView() == nil)
        try await store.writeView(ViewState(currentPageID: index.pageIDs[1]))
        #expect(await store.readView() == ViewState(currentPageID: index.pageIDs[1]))
        try Data("nonsense".utf8).write(to: store.layout.viewURL)
        #expect(await store.readView() == nil)
    }

    /// Heap memory is what `malloc_zone_from_ptr` recognizes; a mapping is
    /// not in any zone.
    @Test("An asset is read mapped, never into the heap; the index and a page file are read as copies")
    func readAssetIsMapped() async throws {
        let scratch = try Scratch("asset-mapped")
        let (store, index, layer) = try await Fixture.populated(at: scratch.packageURL)
        let asset = try await store.readAsset(try #require(layer.payload.asset))
        #expect(asset == Fixture.archive(9, count: 512))
        #expect(asset.withUnsafeBytes { malloc_zone_from_ptr($0.baseAddress) } == nil, "the asset's bytes are heap")
        for url in [store.layout.indexURL, store.layout.pageURL(index.pageIDs[1])] {
            let copy = try PosixFileSystem().read(url)
            #expect(copy.withUnsafeBytes { malloc_zone_from_ptr($0.baseAddress) } != nil, "\(url.lastPathComponent) was not copied")
        }
    }

    @Test("An exclusive publish onto an existing directory, full or empty, fails with EEXIST and changes neither")
    func publishExclusiveNeverReplaces() throws {
        let scratch = try Scratch("exclusive")
        let fs = PosixFileSystem()
        func directory(_ name: String, holding contents: String?) throws -> URL {
            let url = scratch.root.appendingPathComponent(name, isDirectory: true)
            try fs.createDirectory(url)
            if let contents { try fs.writeAtomically(Data(contents.utf8), to: url.appendingPathComponent("a"), syncing: nil) }
            return url
        }
        let staged = try directory("staged", holding: "new")
        let full = try directory("full", holding: "old")
        // An empty directory is what plain `rename(2)` would silently replace.
        let empty = try directory("empty", holding: nil)

        for target in [full, empty] {
            #expect(throws: FileSystemError(.rename, target.path, code: EEXIST)) { try fs.publishExclusive(staged, to: target) }
        }
        #expect(try fs.read(staged.appendingPathComponent("a")) == Data("new".utf8))
        #expect(try fs.read(full.appendingPathComponent("a")) == Data("old".utf8))
        #expect(try fs.list(empty).isEmpty)

        let free = scratch.root.appendingPathComponent("free", isDirectory: true)
        try fs.publishExclusive(staged, to: free)
        #expect(try !fs.exists(staged))
        #expect(try fs.read(free.appendingPathComponent("a")) == Data("new".utf8))
    }

    @Test("An exchange swaps two directories under different parents whole, and with one side missing moves nothing")
    func exchangeSwapsTwoDirectories() throws {
        let scratch = try Scratch("exchange")
        let fs = PosixFileSystem()
        func directory(_ path: String, holding contents: String) throws -> URL {
            let url = scratch.root.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try fs.writeAtomically(Data(contents.utf8), to: url.appendingPathComponent("a"), syncing: nil)
            return url
        }
        let live = try directory("Notebooks/Physics.tubernotes", holding: "old")
        let staged = try directory("Staging/clone", holding: "new")

        try fs.exchange(staged, live)
        #expect(try fs.read(live.appendingPathComponent("a")) == Data("new".utf8))
        #expect(try fs.read(staged.appendingPathComponent("a")) == Data("old".utf8))

        let missing = scratch.root.appendingPathComponent("Staging/missing", isDirectory: true)
        #expect(throws: FileSystemError(.rename, live.path, code: ENOENT)) { try fs.exchange(missing, live) }
        #expect(try fs.read(live.appendingPathComponent("a")) == Data("new".utf8))
        #expect(try !fs.exists(missing))
    }

    @Test("Duplicate's rewrite stops when the ink listing fails, and leaves the package on its old identity")
    func aFailedListingStopsDuplicate() async throws {
        let scratch = try Scratch("rewrite-list")
        let (_, index, _) = try await Fixture.populated(at: scratch.packageURL)
        let store = PackageStore(root: scratch.packageURL, fileSystem: FaultingFileSystem(faults: [.failList]))
        await #expect(throws: FormatFault.io(FileSystemError(.list, store.layout.inkDirectory.path, code: EIO))) {
            try await store.rewriteNotebookID(NotebookID())
        }
        let reopened = PackageStore(root: scratch.packageURL)
        #expect(try await reopened.load().index.notebookID == index.notebookID)
        #expect(try await reopened.loadPage(index.pageIDs[0]).faults.isEmpty)
    }

    @Test("Duplicate's rewrite changes the notebook identity everywhere and keeps page identities")
    func rewriteNotebookID() async throws {
        let scratch = try Scratch("rewrite")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        let newID = NotebookID()
        try await store.rewriteNotebookID(newID)
        let reopened = PackageStore(root: scratch.packageURL)
        let loaded = try await reopened.load()
        #expect(loaded.index.notebookID == newID)
        #expect(loaded.index.pageIDs == index.pageIDs)
        #expect(try await reopened.loadPage(index.pageIDs[0]).inkArchive == Fixture.archive(1))
        #expect(try await reopened.loadPage(index.pageIDs[0]).faults.isEmpty)
    }
}

@Suite("Format: the write order survives every fault")
struct WriteOrderSweep {
    /// The batch under test: ink changes on an existing page, a new layer on
    /// another, a new page with ink, and an index change.
    static func batch(for index: NotebookIndex, existingLayer: Layer, store: PackageStore) async throws -> (SaveBatch, Layer, PageRecord) {
        let added = Fixture.imageLayer()
        // Through a plain store: the faulting file system counts only the save.
        try await PackageStore(root: store.layout.root).writeAsset(Fixture.archive(11, count: 256), added.payload.asset!)
        let newPage = PageRecord(id: PageID(), geometry: .letter, paper: .drawn(.dotted))
        let intended = index.withPages(index.pages + [newPage])
        let ids = index.pageIDs
        let batch = SaveBatch(index: intended, indexChanged: true, pages: [
            PageWrite(file: PageFile(pageID: ids[0], hasInk: true, layers: []), ink: .archive(Fixture.archive(21)), layerFiles: []),
            PageWrite(file: PageFile(pageID: ids[1], hasInk: true, layers: [existingLayer.id, added.id]), ink: .unchanged, layerFiles: [added]),
            PageWrite(file: PageFile(pageID: newPage.id, hasInk: true, layers: []), ink: .archive(Fixture.archive(22)), layerFiles: []),
        ])
        return (batch, added, newPage)
    }

    /// After any fault, the notebook opens, and every page the index reaches
    /// has its page file, every named layer file exists, and every page
    /// with hasInk has a container. Content faults (torn bytes) are page
    /// scoped and named; nothing is silently blank.
    static func assertInvariants(at url: URL, faultAllowed: Bool, context: String) async throws {
        let store = PackageStore(root: url)
        let loaded = try await store.load()
        for page in loaded.index.pageIDs {
            #expect(!(loaded.pageFaults[page] ?? []).contains(.missingPageFile), "\(context): index reaches a missing page file")
            let bytes = try await store.loadPage(page)
            #expect(!bytes.faults.contains(.missingInk), "\(context): hasInk with no container")
            for case .layerRefused(.fileMissing) in bytes.faults {
                Issue.record("\(context): page file names a missing layer file")
            }
            if !faultAllowed {
                #expect(bytes.faults.isEmpty, "\(context): unexpected page fault \(bytes.faults)")
            }
        }
    }

    @Test("Failing the Nth stage, publish, or directory sync never dangles a reference")
    func failAtN() async throws {
        let scratch = try Scratch("sweep")
        let (_, index, layer) = try await Fixture.populated(at: scratch.packageURL)
        // Dry run to learn the operation counts.
        let dry = FaultingFileSystem(faults: [])
        let dryURL = try scratch.copyPackage(to: "dry")
        let dryStore = PackageStore(root: dryURL, fileSystem: dry)
        _ = try await dryStore.load()
        let (dryBatch, _, _) = try await Self.batch(for: index, existingLayer: layer, store: dryStore)
        _ = try await dryStore.save(dryBatch)
        let counts = dry.counts
        #expect(counts.stages >= 5 && counts.publishes >= 5 && counts.syncs >= 4)

        var modes: [FaultingFileSystem.Fault] = []
        for n in 1...counts.stages { modes.append(.failStage(nth: n)); modes.append(.truncateStage(nth: n, bytes: 3)) }
        for n in 1...counts.publishes { modes.append(.failPublish(nth: n)); modes.append(.discardAfterPublish(nth: n)) }
        for n in 1...counts.syncs { modes.append(.failSync(nth: n)) }

        for mode in modes {
            let url = try scratch.copyPackage(to: "run")
            let fs = FaultingFileSystem(faults: [mode])
            let store = PackageStore(root: url, fileSystem: fs)
            _ = try await store.load()
            let (batch, _, _) = try await Self.batch(for: index, existingLayer: layer, store: store)
            var threw = false
            do { _ = try await store.save(batch) } catch { threw = true }

            // Tearing the index's own bytes (a truncated stage of the last
            // file, or discarding its bytes after its publish) is the case the
            // barrier exists to prevent; the faulting file system models a
            // barrier that did not hold, so the notebook is unreadable and that
            // is the documented outcome. Every other position must hold.
            var barrierCase = false
            if case .discardAfterPublish(let n) = mode, n == counts.publishes { barrierCase = true }
            if case .truncateStage(let n, _) = mode, n == counts.stages { barrierCase = true }
            if barrierCase {
                await #expect(throws: (any Error).self) { try await PackageStore(root: url).load() }
                continue
            }
            let contentFault: Bool
            switch mode {
            case .truncateStage, .discardAfterPublish: contentFault = true
            default: contentFault = false
            }
            try await Self.assertInvariants(at: url, faultAllowed: contentFault, context: "\(mode) threw=\(threw)")
        }
    }
}

@Suite("Format: compact is the one deletion authority")
struct CompactTests {
    @Test("A save deletes nothing; compact removes old orphans and keeps young ones")
    func orphans() async throws {
        let scratch = try Scratch("compact")
        let (store, index, layer) = try await Fixture.populated(at: scratch.packageURL)
        let layout = store.layout
        // Remove the layer from page 1: the file and its asset become orphans.
        let batch = SaveBatch(index: index, indexChanged: false, pages: [
            PageWrite(file: PageFile(pageID: index.pageIDs[1], hasInk: true, layers: []), ink: .unchanged, layerFiles: []),
        ])
        _ = try await store.save(batch)
        #expect(try PosixFileSystem().exists(layout.layerURL(layer.id)))
        let asset = layer.payload.asset!
        #expect(try PosixFileSystem().exists(layout.assetURL(asset)))
        // A stray temp and an orphan page file, both old.
        let temp = layout.pagesDirectory.appendingPathComponent("\(PackageStore.tempPrefix)stale")
        try Data([1]).write(to: temp)
        let orphanPage = layout.pageURL(PageID())
        try Data([2]).write(to: orphanPage)
        try scratch.backdate(temp, by: 2 * 86_400)
        try scratch.backdate(orphanPage, by: 2 * 86_400)
        try scratch.backdate(layout.assetURL(asset), by: 2 * 86_400)
        // The orphan layer file stays young.
        var report = try await store.compact()
        #expect(!report.layerReclamationSuspended && !report.assetReclamationSuspended)
        #expect(try !PosixFileSystem().exists(temp))
        #expect(try !PosixFileSystem().exists(orphanPage))
        #expect(try !PosixFileSystem().exists(layout.assetURL(asset)))
        #expect(try PosixFileSystem().exists(layout.layerURL(layer.id)), "young orphan kept")
        try scratch.backdate(layout.layerURL(layer.id), by: 2 * 86_400)
        report = try await store.compact()
        #expect(try !PosixFileSystem().exists(layout.layerURL(layer.id)))
        #expect(report.removed.count == 1)
    }

    @Test("A paper asset is reachable from the index alone; a stale one still goes")
    func paperAssetsAreReachable() async throws {
        let scratch = try Scratch("compact-paper")
        let paperAsset = AssetRef(id: AssetID(), format: .heic)
        let index = NotebookIndex(
            notebookID: NotebookID(), createdAt: Date(),
            pages: [PageRecord(id: PageID(), geometry: .letter, paper: .image(paperAsset))],
            bookmarks: [])
        let store = try await PackageStore.create(root: scratch.packageURL, index: index)
        try await store.writeAsset(Fixture.archive(5, count: 256), paperAsset)
        let stale = store.layout.assetURL(AssetRef(id: AssetID(), format: .heic))
        try Data([7]).write(to: stale)
        try scratch.backdate(stale, by: 2 * 86_400)
        try scratch.backdate(store.layout.assetURL(paperAsset), by: 2 * 86_400)

        let report = try await store.compact()
        #expect(!report.assetReclamationSuspended)
        #expect(try PosixFileSystem().exists(store.layout.assetURL(paperAsset)), "paper asset kept")
        #expect(try !PosixFileSystem().exists(stale))
    }

    @Test("An asset named only in the keep-set stays; an orphan beside it goes")
    func compactKeepsANamedAsset() async throws {
        let scratch = try Scratch("compact-keeping")
        let store = try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1))
        let held = AssetRef(id: AssetID(), format: .heic)
        let orphan = AssetRef(id: AssetID(), format: .heic)
        try await store.writeAsset(Fixture.archive(1, count: 64), held)
        try await store.writeAsset(Fixture.archive(2, count: 64), orphan)
        let report = try await store.compact(now: .now + 2 * 86_400, keeping: [held])
        #expect(try PosixFileSystem().exists(store.layout.assetURL(held)))
        #expect(report.removed == [orphan.fileName])
    }

    @Test("Live page, ink and layer files are kept by the names the layout writes, however old")
    func compactKeepsLiveFilesByForwardSpelling() async throws {
        let scratch = try Scratch("compact-live")
        let (store, index, layer) = try await Fixture.populated(at: scratch.packageURL)
        let layout = store.layout
        let report = try await store.compact(now: .now + 2 * 86_400)
        #expect(report.removed.isEmpty)
        let live = index.pageIDs.map(layout.pageURL) + index.pageIDs.prefix(2).map(layout.inkURL) + [layout.layerURL(layer.id)]
        for url in live {
            #expect(try PosixFileSystem().exists(url), "\(url.lastPathComponent)")
        }
    }

    @Test("A layer this build cannot open suspends asset reclamation for the whole notebook")
    func unreadableLayerSuspends() async throws {
        let scratch = try Scratch("suspend")
        let (store, _, layer) = try await Fixture.populated(at: scratch.packageURL)
        let layout = store.layout
        var object = try jsonObject(try PosixFileSystem().read(layout.layerURL(layer.id)))
        object.removeValue(forKey: "transform")
        try jsonData(object).write(to: layout.layerURL(layer.id))
        let orphanAsset = layout.assetURL(AssetRef(id: AssetID(), format: .heic))
        try Data([3]).write(to: orphanAsset)
        try scratch.backdate(orphanAsset, by: 2 * 86_400)
        let report = try await store.compact()
        #expect(report.assetReclamationSuspended)
        #expect(try PosixFileSystem().exists(orphanAsset))
    }
}
