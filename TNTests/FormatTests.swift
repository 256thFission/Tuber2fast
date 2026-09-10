import Foundation
import Testing
@testable import TNFormat
@testable import TNModel

@Suite("Format: key sets are pinned")
struct KeySetPins {
    @Test("notebook.json carries exactly its keys, and each page record and paper exactly theirs")
    func indexKeys() throws {
        let data = try Codecs.encode(Fixture.index(pages: 2))
        let top = try jsonObject(data)
        #expect(Set(top.keys) == DurableKeys.index)
        let pages = try #require(top["pages"] as? [[String: Any]])
        for page in pages {
            #expect(Set(page.keys) == DurableKeys.pageRecord)
            #expect(Set(try #require(page["paper"] as? [String: Any]).keys) == DurableKeys.paper)
        }
        #expect(top["formatVersion"] as? Int == 2)
    }

    @Test("pages/<id>.json carries exactly its keys")
    func pageFileKeys() throws {
        let data = try Codecs.encode(PageFile(pageID: PageID(), hasInk: true, inkIndex: 1, layers: [LayerID()]))
        #expect(Set(try jsonObject(data).keys) == DurableKeys.pageFile)
    }

    @Test("Each layer kind's file carries exactly its keys, payload keyed by kind")
    func layerFileKeys() throws {
        let cases: [(Layer, Set<String>)] = [
            (Fixture.imageLayer(), DurableKeys.image),
            (Fixture.pdfLayer(), DurableKeys.pdf),
            (Fixture.linkLayer(to: PageID()), DurableKeys.link),
        ]
        for (layer, payloadKeys) in cases {
            let top = try jsonObject(try LayerFile.encode(layer))
            let kind = layer.payload.kind.rawValue
            #expect(Set(top.keys) == DurableKeys.layerFile(kind: kind))
            #expect(Set(try #require(top[kind] as? [String: Any]).keys) == payloadKeys)
        }
    }

    @Test("view.json carries exactly its key")
    func viewKeys() throws {
        #expect(Set(try jsonObject(try Codecs.encode(ViewState(currentPageID: PageID()))).keys) == DurableKeys.view)
    }
}

@Suite("Format: strict decode refuses by name")
struct StrictDecode {
    @Test("Deleting any index key refuses naming it; adding one refuses too")
    func indexDeleteEachKey() throws {
        let base = try jsonObject(try Codecs.encode(Fixture.index(pages: 1)))
        for key in DurableKeys.index {
            var object = base
            object.removeValue(forKey: key)
            #expect(throws: FormatFault.missingKey(key)) { try IndexFile.decode(try jsonData(object)) }
        }
        var extra = base
        extra["title"] = "x"
        #expect(throws: FormatFault.unknownKey("title")) { try IndexFile.decode(try jsonData(extra)) }

        var pages = try #require(base["pages"] as? [[String: Any]])
        for key in DurableKeys.pageRecord {
            var page = pages[0]
            page.removeValue(forKey: key)
            var object = base
            object["pages"] = [page]
            #expect(throws: FormatFault.missingKey(key)) { try IndexFile.decode(try jsonData(object)) }
        }
        pages[0]["paper"] = [:]
        var object = base
        object["pages"] = pages
        #expect(throws: FormatFault.missingKey("kind")) { try IndexFile.decode(try jsonData(object)) }
    }

    @Test("A newer format version refuses by number, an unknown paper refuses the page only")
    func versionAndPaper() throws {
        var object = try jsonObject(try Codecs.encode(Fixture.index(pages: 1)))
        object["formatVersion"] = 3
        let newer = try IndexFile.decode(try jsonData(object))
        #expect(throws: NotebookIndexFault.unsupportedFormatVersion(3)) { try newer.validated() }

        object["formatVersion"] = 2
        var pages = try #require(object["pages"] as? [[String: Any]])
        pages[0]["paper"] = ["kind": "parchment"]
        object["pages"] = pages
        let index = try IndexFile.decode(try jsonData(object)).validated()
        #expect(index.pageFaults[index.pageIDs[0]] == .unknownPaper("parchment"))
    }

    @Test("Deleting any page-file key refuses naming it")
    func pageFileDeleteEachKey() throws {
        let base = try jsonObject(try Codecs.encode(PageFile(pageID: PageID(), hasInk: false, inkIndex: 0, layers: [])))
        for key in DurableKeys.pageFile {
            var object = base
            object.removeValue(forKey: key)
            #expect(throws: FormatFault.missingKey(key)) {
                try Codecs.decodeStrict(PageFile.self, from: try jsonData(object), expectedKeys: DurableKeys.pageFile)
            }
        }
    }

    @Test("A layer file missing a key, or of unknown kind, refuses the layer and names why")
    func layerFileRefusals() throws {
        for layer in [Fixture.imageLayer(), Fixture.pdfLayer(), Fixture.linkLayer(to: PageID())] {
            let base = try jsonObject(try LayerFile.encode(layer))
            for key in DurableKeys.layerFile(kind: layer.payload.kind.rawValue) where key != "layerID" && key != "kind" {
                var object = base
                object.removeValue(forKey: key)
                guard case .failure(let fault) = LayerFile.decode(try jsonData(object), expecting: layer.id) else {
                    Issue.record("\(layer.payload.kind) without \(key) decoded"); continue
                }
                guard case .fileUnreadable(_, let detail) = fault else { Issue.record("wrong fault \(fault)"); continue }
                #expect(detail.contains(key))
            }
        }
        var unknown = try jsonObject(try LayerFile.encode(Fixture.imageLayer()))
        unknown["kind"] = "text"
        unknown["text"] = ["body": "hi"]
        unknown.removeValue(forKey: "image")
        let id = LayerID(raw: UUID(uuidString: unknown["layerID"] as! String)!)
        #expect(LayerFile.decode(try jsonData(unknown), expecting: id) == .failure(.unknownKind(id, kind: "text")))
    }

    @Test("A link layer with a non-identity transform, or an external target, round-trips or refuses as specified")
    func linkShapes() throws {
        let external = Layer(id: LayerID(), transform: .identity, payload: .link(LinkLayer(
            rect: PageRect(x: 1, y: 1, width: 10, height: 10), style: .button,
            target: .externalPage(notebook: NotebookID(), page: PageID()))))
        #expect(LayerFile.decode(try LayerFile.encode(external), expecting: external.id) == .success(external))
        let skewed = Fixture.linkLayer(to: PageID()).withTransform(.scale(2))
        #expect(LayerFile.decode(try LayerFile.encode(skewed), expecting: skewed.id) == .failure(.linkTransformNotIdentity(skewed.id)))
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
        #expect(try InkContainer.decode(data, expecting: notebook, page: page).archive == archive)

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
        #expect(page1.layers == [.success(layer)])
        #expect(page1.file.inkIndex == 1)
        let page2 = try await reopened.loadPage(index.pageIDs[2])
        #expect(page2.inkArchive == nil)
        #expect(page2.faults.isEmpty)
        #expect(page2.file.hasInk == false)
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
            PageWrite(file: PageFile(pageID: index.pageIDs[0], hasInk: true, inkIndex: 0, layers: []), ink: .archive(Fixture.archive(7)), layerFiles: []),
            PageWrite(file: PageFile(pageID: index.pageIDs[1], hasInk: true, inkIndex: 1, layers: try await store.loadPage(index.pageIDs[1]).file.layers), ink: .unchanged, layerFiles: []),
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
        let newPage = PageRecord(id: PageID(), geometry: .letter, paper: .grid)
        let intended = index.withPages(index.pages + [newPage])
        let dangling = Fixture.imageLayer()  // its asset was never written
        let batch = SaveBatch(index: intended, indexChanged: true, pages: [
            PageWrite(file: PageFile(pageID: newPage.id, hasInk: false, inkIndex: 1, layers: [dangling.id]), ink: .unchanged, layerFiles: [dangling]),
            PageWrite(file: PageFile(pageID: index.pageIDs[2], hasInk: true, inkIndex: 0, layers: []), ink: .archive(Fixture.archive(5)), layerFiles: []),
        ])
        let report = try await store.save(batch)
        #expect(report.refusals[newPage.id] == .danglingAsset(dangling.id, dangling.payload.asset!))
        #expect(report.indexWritten)
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
            PageWrite(file: PageFile(pageID: index.pageIDs[0], hasInk: false, inkIndex: 1, layers: [dangling.id]), ink: .unchanged, layerFiles: [dangling]),
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

    @Test("hasInk=true with no container is a page fault, never a blank")
    func missingInkIsAFault() async throws {
        let scratch = try Scratch("missingink")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        try FileManager.default.removeItem(at: store.layout.inkURL(index.pageIDs[0]))
        let bytes = try await PackageStore(root: scratch.packageURL).loadPage(index.pageIDs[0])
        #expect(bytes.faults == [.missingInk])
        #expect(bytes.isPlaceholder)
    }

    @Test("Writing ink to a page whose file says hasInk=false is refused")
    func inkRequiresHasInk() async throws {
        let scratch = try Scratch("inkflag")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        let batch = SaveBatch(index: index, indexChanged: false, pages: [
            PageWrite(file: PageFile(pageID: index.pageIDs[2], hasInk: false, inkIndex: 0, layers: []), ink: .archive(Fixture.archive(1)), layerFiles: []),
        ])
        let report = try await store.save(batch)
        #expect(report.refusals[index.pageIDs[2]] == .inkWithoutHasInk)
    }

    @Test("No free space refuses before anything is written")
    func freeSpacePreflight() async throws {
        let scratch = try Scratch("nospace")
        _ = try await Fixture.populated(at: scratch.packageURL)
        let store = PackageStore(root: scratch.packageURL, fileSystem: NoSpaceFileSystem())
        let loaded = try await store.load()
        let batch = SaveBatch(index: loaded.index, indexChanged: false, pages: [
            PageWrite(file: PageFile(pageID: loaded.index.pageIDs[0], hasInk: true, inkIndex: 0, layers: []), ink: .archive(Fixture.archive(8)), layerFiles: []),
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
        let newPage = PageRecord(id: PageID(), geometry: .letter, paper: .dotted)
        let intended = index.withPages(index.pages + [newPage])
        let ids = index.pageIDs
        let batch = SaveBatch(index: intended, indexChanged: true, pages: [
            PageWrite(file: PageFile(pageID: ids[0], hasInk: true, inkIndex: 0, layers: []), ink: .archive(Fixture.archive(21)), layerFiles: []),
            PageWrite(file: PageFile(pageID: ids[1], hasInk: true, inkIndex: 2, layers: [existingLayer.id, added.id]), ink: .unchanged, layerFiles: [added]),
            PageWrite(file: PageFile(pageID: newPage.id, hasInk: true, inkIndex: 0, layers: []), ink: .archive(Fixture.archive(22)), layerFiles: []),
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
            for case .failure(let fault) in bytes.layers {
                if case .fileMissing = fault { Issue.record("\(context): page file names a missing layer file") }
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
            PageWrite(file: PageFile(pageID: index.pageIDs[1], hasInk: true, inkIndex: 0, layers: []), ink: .unchanged, layerFiles: []),
        ])
        _ = try await store.save(batch)
        #expect(PosixFileSystem().exists(layout.layerURL(layer.id)))
        let asset = layer.payload.asset!
        #expect(PosixFileSystem().exists(layout.assetURL(asset)))
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
        #expect(!PosixFileSystem().exists(temp))
        #expect(!PosixFileSystem().exists(orphanPage))
        #expect(!PosixFileSystem().exists(layout.assetURL(asset)))
        #expect(PosixFileSystem().exists(layout.layerURL(layer.id)), "young orphan kept")
        try scratch.backdate(layout.layerURL(layer.id), by: 2 * 86_400)
        report = try await store.compact()
        #expect(!PosixFileSystem().exists(layout.layerURL(layer.id)))
        #expect(report.removed.count == 1)
    }

    @Test("A layer this build cannot open suspends asset reclamation for the whole notebook")
    func unknownKindSuspends() async throws {
        let scratch = try Scratch("suspend")
        let (store, index, layer) = try await Fixture.populated(at: scratch.packageURL)
        let layout = store.layout
        var object = try jsonObject(try PosixFileSystem().read(layout.layerURL(layer.id)))
        object["kind"] = "hologram"
        object["hologram"] = object.removeValue(forKey: "image")
        try jsonData(object).write(to: layout.layerURL(layer.id))
        let orphanAsset = layout.assetURL(AssetRef(id: AssetID(), format: .heic))
        try Data([3]).write(to: orphanAsset)
        try scratch.backdate(orphanAsset, by: 2 * 86_400)
        let report = try await store.compact()
        #expect(report.assetReclamationSuspended)
        #expect(PosixFileSystem().exists(orphanAsset))
        _ = index
    }
}
