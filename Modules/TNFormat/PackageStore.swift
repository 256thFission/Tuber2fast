import Foundation
import TNCore
import TNModel

/// One page's contribution to a save.
package struct PageWrite: Sendable, Equatable {
    /// The page file as it should read after this save. Complete, not a diff.
    package let file: PageFile
    package let ink: InkWrite
    /// Layers whose files must be written this save. A layer named by
    /// `file.layers` and absent here is asserted to be already on disk.
    package let layerFiles: [Layer]

    package init(file: PageFile, ink: InkWrite, layerFiles: [Layer]) {
        self.file = file
        self.ink = ink
        self.layerFiles = layerFiles
    }

    package var pageID: PageID { file.pageID }

    /// A page written for the first time with nothing on it.
    package static func newBlank(_ page: PageID) -> PageWrite {
        PageWrite(file: .empty(pageID: page), ink: .unchanged, layerFiles: [])
    }
}

package enum InkWrite: Sendable, Equatable {
    case unchanged
    case archive(Data)
}

package struct SaveBatch: Sendable, Equatable {
    /// The intended index. Always given; written only if `indexChanged`.
    package let index: NotebookIndex
    package let indexChanged: Bool
    package let pages: [PageWrite]

    package init(index: NotebookIndex, indexChanged: Bool, pages: [PageWrite]) {
        self.index = index
        self.indexChanged = indexChanged
        self.pages = pages
    }
}

package enum PageRefusal: Error, Sendable, Equatable {
    case invalidPageFile(PageFault)
    case layerFileMissing(LayerID)
    case layerNotInPage(LayerID)
    case invalidLayer(LayerFault)
    case danglingAsset(LayerID, AssetRef)
    case inkWithoutHasInk
    case hasInkWithoutContainer
    case staging(String)
}

package struct SaveReport: Sendable, Equatable {
    /// Pages whose files are present after this save (written or unchanged).
    package let committed: Set<PageID>
    package let refusals: [PageID: PageRefusal]
    package let indexWritten: Bool
    /// The intended index intersected with present pages was empty, so the
    /// index was withheld. Every page in the batch stays dirty.
    package let indexWithheld: Bool
}

package struct LoadedNotebook: Sendable, Equatable {
    package let index: NotebookIndex
    package let pageFaults: [PageID: [PageFault]]
}

package struct PageBytes: Sendable, Equatable {
    package let file: PageFile
    package let inkArchive: Data?
    package let layers: [Result<Layer, LayerFault>]
    package let faults: [PageFault]
    /// A valid container was found under `hasInk == false`: the ink is
    /// real, and the next save must record it.
    package let inkRecordNeeded: Bool

    package var isPlaceholder: Bool {
        !faults.isEmpty || layers.contains { if case .failure = $0 { true } else { false } }
    }
}

package struct CompactReport: Sendable, Equatable {
    package var removed: [String] = []
    package var kept: [String] = []
    package var layerReclamationSuspended = false
    package var assetReclamationSuspended = false
}

/// The store: one per package, the only writer of its bytes.
///
/// A save plans, stages, and publishes in three phases (D10). Nothing is
/// deleted by a save or by an open; `compact()` is the one deletion
/// authority (D11).
package actor PackageStore {
    package nonisolated let layout: PackageLayout
    private let fs: any PackageFileSystem
    private var lastIndex: NotebookIndex?

    package static let freeSpaceSlack: Int64 = 4 * 1024 * 1024
    package static let compactMinimumAge: TimeInterval = 24 * 60 * 60
    package static let tempPrefix = "tmp-"

    package init(root: URL, fileSystem: any PackageFileSystem = PosixFileSystem()) {
        self.layout = PackageLayout(root: root)
        self.fs = fileSystem
    }

    /// A new package: directories, one blank page file per page, the index.
    package static func create(
        root: URL,
        index: NotebookIndex,
        fileSystem: any PackageFileSystem = PosixFileSystem()
    ) async throws(FormatFault) -> PackageStore {
        let store = PackageStore(root: root, fileSystem: fileSystem)
        try await store.createDirectories()
        let batch = SaveBatch(index: index, indexChanged: true, pages: index.pageIDs.map(PageWrite.newBlank))
        let report = try await store.save(batch)
        guard report.indexWritten else { throw .invalidWrite("create could not commit an index") }
        return store
    }

    private func createDirectories() throws(FormatFault) {
        for directory in layout.directories {
            do { try fs.createDirectory(directory) } catch let error as FileSystemError { throw .io(error) } catch { throw .invalidWrite("\(error)") }
        }
    }

    // MARK: Open

    package func load() throws(FormatFault) -> LoadedNotebook {
        let data: Data
        do {
            data = try fs.read(layout.indexURL)
        } catch let error as FileSystemError {
            if error.code == ENOENT { throw .noPackage }
            throw .io(error)
        } catch {
            throw .indexUnreadable("\(error)")
        }
        let index = try IndexFile.decode(data)
        let validated: NotebookIndex
        do {
            validated = try index.validated()
        } catch {
            throw .indexInvalid(error)
        }
        var faults = validated.pageFaults.mapValues { [$0] }
        for page in validated.pageIDs where !fs.exists(layout.pageURL(page)) {
            faults[page, default: []].append(.missingPageFile)
        }
        lastIndex = validated
        return LoadedNotebook(index: validated, pageFaults: faults)
    }

    private func currentIndex() throws(FormatFault) -> NotebookIndex {
        if let lastIndex { return lastIndex }
        return try load().index
    }

    package func loadPage(_ page: PageID) throws(FormatFault) -> PageBytes {
        let index = try currentIndex()
        let fileData: Data
        do {
            fileData = try fs.read(layout.pageURL(page))
        } catch let error as FileSystemError where error.code == ENOENT {
            return PageBytes(file: .empty(pageID: page), inkArchive: nil, layers: [], faults: [.missingPageFile], inkRecordNeeded: false)
        } catch {
            return PageBytes(file: .empty(pageID: page), inkArchive: nil, layers: [], faults: [.pageFileUnreadable("\(error)")], inkRecordNeeded: false)
        }
        let file: PageFile
        do {
            file = try Codecs.decodeStrict(PageFile.self, from: fileData, expectedKeys: DurableKeys.pageFile).validated(expecting: page)
        } catch let fault as PageFault {
            return PageBytes(file: .empty(pageID: page), inkArchive: nil, layers: [], faults: [fault], inkRecordNeeded: false)
        } catch {
            return PageBytes(file: .empty(pageID: page), inkArchive: nil, layers: [], faults: [.pageFileUnreadable("\(error)")], inkRecordNeeded: false)
        }

        var faults: [PageFault] = []
        var inkArchive: Data?
        var inkRecordNeeded = false
        let inkURL = layout.inkURL(page)
        if file.hasInk {
            do {
                let container = try fs.read(inkURL)
                inkArchive = try InkContainer.decode(container, expecting: index.notebookID, page: page).archive
            } catch let error as FileSystemError where error.code == ENOENT {
                faults.append(.missingInk)
            } catch let fault as InkContainerFault {
                faults.append(.inkContainerInvalid(fault))
            } catch {
                faults.append(.pageFileUnreadable("ink: \(error)"))
            }
        } else if fs.exists(inkURL) {
            // A crash between publish phases: the container landed, the page
            // file recording it did not. The container is the ink.
            if let container = try? fs.read(inkURL),
               let decoded = try? InkContainer.decode(container, expecting: index.notebookID, page: page) {
                inkArchive = decoded.archive
                inkRecordNeeded = true
                TNLog.event(.format, "page \(page) has a container under hasInk=false; adopting it")
            }
        }

        let layers = file.layers.map { layerID -> Result<Layer, LayerFault> in
            do {
                return LayerFile.decode(try fs.read(layout.layerURL(layerID)), expecting: layerID)
            } catch let error as FileSystemError where error.code == ENOENT {
                return .failure(.fileMissing(layerID))
            } catch {
                return .failure(.fileUnreadable(layerID, "\(error)"))
            }
        }
        for case .success(let layer) in layers {
            if let asset = layer.payload.asset, !fs.exists(layout.assetURL(asset)) {
                faults.append(.layerRefused(RefusedLayer(id: layer.id, fault: .danglingAsset(layer.id, asset))))
            }
        }
        for case .failure(let fault) in layers {
            faults.append(.layerRefused(RefusedLayer(id: Self.layerID(of: fault), fault: fault)))
        }
        return PageBytes(file: file, inkArchive: inkArchive, layers: layers, faults: faults, inkRecordNeeded: inkRecordNeeded)
    }

    private static func layerID(of fault: LayerFault) -> LayerID {
        switch fault {
        case .unknownKind(let id, _), .fileMissing(let id), .fileUnreadable(let id, _),
             .invalidTransform(let id), .invalidNaturalSize(let id), .negativeSourcePageIndex(let id),
             .invalidSourceExtent(let id), .linkTransformNotIdentity(let id), .invalidLinkRect(let id),
             .danglingAsset(let id, _), .sourceExtentDisagrees(let id):
            id
        case .idMismatch(let expected, _):
            expected
        }
    }

    // MARK: Save

    private struct Staged {
        let page: PageID
        var leaves: [(temp: URL, final: URL)] = []
        var pageFile: (temp: URL, final: URL)?
        var temps: [URL] { leaves.map(\.temp) + (pageFile.map { [$0.temp] } ?? []) }
    }

    package func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport {
        // ---- plan: no I/O beyond stats and reads of what is already there
        var seen = Set<PageID>()
        for write in batch.pages {
            guard seen.insert(write.pageID).inserted else { throw .invalidWrite("page \(write.pageID) written twice in one batch") }
            guard batch.index.record(of: write.pageID) != nil else { throw .invalidWrite("page \(write.pageID) is not in the intended index") }
        }
        let intended: NotebookIndex
        do { intended = try batch.index.validated() } catch { throw .indexInvalid(error) }

        var refusals: [PageID: PageRefusal] = [:]
        var planned: [(write: PageWrite, pageFileData: Data, layerData: [(LayerID, Data)], skip: Bool)] = []
        var bytesNeeded: Int64 = 0

        for write in batch.pages {
            switch plan(write, notebookID: intended.notebookID) {
            case .failure(let refusal):
                refusals[write.pageID] = refusal
            case .success(let plan):
                planned.append((write, plan.pageFileData, plan.layerData, plan.skip))
                if case .archive(let archive) = write.ink { bytesNeeded += Int64(archive.count) + Int64(InkContainer.headerLength) }
                bytesNeeded += Int64(plan.pageFileData.count) + plan.layerData.reduce(0) { $0 + Int64($1.1.count) }
            }
        }
        let indexData = try Codecs.encode(intended)
        bytesNeeded += Int64(indexData.count)

        do {
            let available = try fs.availableBytes(at: layout.root)
            if available < bytesNeeded + Self.freeSpaceSlack {
                throw FormatFault.insufficientSpace(needed: bytesNeeded + Self.freeSpaceSlack, available: available)
            }
        } catch let fault as FormatFault {
            throw fault
        } catch let error as FileSystemError {
            throw .io(error)
        } catch {
            throw .invalidWrite("\(error)")
        }

        // ---- stage: every file to a temp path, barrier before close
        var staged: [Staged] = []
        var unchanged = Set<PageID>()
        for plan in planned {
            if plan.skip { unchanged.insert(plan.write.pageID); continue }
            var entry = Staged(page: plan.write.pageID)
            do {
                if case .archive(let archive) = plan.write.ink {
                    let final = layout.inkURL(plan.write.pageID)
                    let temp = tempURL(beside: final)
                    let container = InkContainer.encode(notebookID: intended.notebookID, pageID: plan.write.pageID, archive: archive)
                    try fs.stage(container, at: temp)
                    entry.leaves.append((temp, final))
                }
                for (layerID, data) in plan.layerData {
                    let final = layout.layerURL(layerID)
                    let temp = tempURL(beside: final)
                    try fs.stage(data, at: temp)
                    entry.leaves.append((temp, final))
                }
                let final = layout.pageURL(plan.write.pageID)
                let temp = tempURL(beside: final)
                try fs.stage(plan.pageFileData, at: temp)
                entry.pageFile = (temp, final)
                staged.append(entry)
            } catch {
                for temp in entry.temps { try? fs.remove(temp) }
                refusals[plan.write.pageID] = .staging("\(error)")
                TNLog.event(.format, "page \(plan.write.pageID) refused at staging: \(error)")
            }
        }

        // ---- publish 1: leaves, then sync their directories
        do {
            for entry in staged { for leaf in entry.leaves { try fs.publish(leaf.temp, to: leaf.final) } }
            try fs.syncDirectory(layout.inkDirectory)
            try fs.syncDirectory(layout.layersDirectory)
            // ---- publish 2: page files, then sync pages/
            for entry in staged { if let pageFile = entry.pageFile { try fs.publish(pageFile.temp, to: pageFile.final) } }
            try fs.syncDirectory(layout.pagesDirectory)
        } catch {
            for entry in staged { for temp in entry.temps where fs.exists(temp) { try? fs.remove(temp) } }
            throw Self.ioFault(error)
        }

        // ---- publish 3: the index, if it changed, naming only present pages
        var indexWritten = false
        var indexWithheld = false
        if batch.indexChanged {
            let present = intended.pages.filter { fs.exists(layout.pageURL($0.id)) }
            if present.isEmpty {
                indexWithheld = true
                TNLog.event(.format, "index withheld: no intended page is present")
            } else {
                let committedIndex = intended.withPages(present)
                let data = try Codecs.encode(committedIndex)
                let temp = tempURL(beside: layout.indexURL)
                do {
                    try fs.stage(data, at: temp)
                    try fs.publish(temp, to: layout.indexURL)
                    try fs.syncDirectory(layout.root)
                } catch {
                    try? fs.remove(temp)
                    throw Self.ioFault(error)
                }
                lastIndex = committedIndex
                indexWritten = true
            }
        }

        let committed = Set(staged.map(\.page)).union(unchanged)
        return SaveReport(committed: committed, refusals: refusals, indexWritten: indexWritten, indexWithheld: indexWithheld)
    }

    private static func ioFault(_ error: any Error) -> FormatFault {
        if let fs = error as? FileSystemError { return .io(fs) }
        return .invalidWrite("\(error)")
    }

    private struct PagePlan {
        let pageFileData: Data
        let layerData: [(LayerID, Data)]
        /// Nothing about this page changes on disk; it is present as it is.
        let skip: Bool
    }

    private func plan(_ write: PageWrite, notebookID: NotebookID) -> Result<PagePlan, PageRefusal> {
        let file: PageFile
        do { file = try write.file.validated(expecting: write.pageID) } catch { return .failure(.invalidPageFile(error)) }

        let writtenLayers = Set(write.layerFiles.map(\.id))
        for layerID in file.layers where !writtenLayers.contains(layerID) && !fs.exists(layout.layerURL(layerID)) {
            return .failure(.layerFileMissing(layerID))
        }
        var layerData: [(LayerID, Data)] = []
        for layer in write.layerFiles {
            guard file.layers.contains(layer.id) else { return .failure(.layerNotInPage(layer.id)) }
            do { _ = try layer.validated() } catch { return .failure(.invalidLayer(error)) }
            if let asset = layer.payload.asset, !fs.exists(layout.assetURL(asset)) {
                return .failure(.danglingAsset(layer.id, asset))
            }
            do { layerData.append((layer.id, try LayerFile.encode(layer))) } catch { return .failure(.staging(error.description)) }
        }
        switch write.ink {
        case .archive:
            guard file.hasInk else { return .failure(.inkWithoutHasInk) }
        case .unchanged:
            if file.hasInk, !fs.exists(layout.inkURL(write.pageID)) { return .failure(.hasInkWithoutContainer) }
        }
        let pageFileData: Data
        do { pageFileData = try Codecs.encode(file) } catch { return .failure(.staging(error.description)) }

        var skip = false
        if case .unchanged = write.ink, layerData.isEmpty, let existing = try? fs.read(layout.pageURL(write.pageID)), existing == pageFileData {
            skip = true
        }
        return .success(PagePlan(pageFileData: pageFileData, layerData: layerData, skip: skip))
    }

    private func tempURL(beside final: URL) -> URL {
        final.deletingLastPathComponent()
            .appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)-\(final.lastPathComponent)")
    }

    // MARK: Assets

    /// Assets are immutable and published at import, before any layer names
    /// them. Writing an asset that exists is a no-op.
    package func writeAsset(_ data: Data, _ ref: AssetRef) throws(FormatFault) {
        guard data.count <= AssetBounds.maxBytes else { throw .invalidWrite("asset \(ref.fileName) exceeds \(AssetBounds.maxBytes) bytes") }
        let final = layout.assetURL(ref)
        if fs.exists(final) { return }
        let temp = tempURL(beside: final)
        do {
            try fs.stage(data, at: temp)
            try fs.publish(temp, to: final)
            try fs.syncDirectory(layout.assetsDirectory)
        } catch {
            try? fs.remove(temp)
            throw Self.ioFault(error)
        }
    }

    package func readAsset(_ ref: AssetRef) throws(FormatFault) -> Data {
        do { return try fs.read(layout.assetURL(ref)) } catch { throw Self.ioFault(error) }
    }

    package func assetExists(_ ref: AssetRef) -> Bool { fs.exists(layout.assetURL(ref)) }

    // MARK: View state (disposable)

    package func readView() -> ViewState? {
        guard let data = try? fs.read(layout.viewURL),
              let view = try? Codecs.decodeStrict(ViewState.self, from: data, expectedKeys: DurableKeys.view)
        else { return nil }
        return view
    }

    package func writeView(_ view: ViewState) throws(FormatFault) {
        let data = try Codecs.encode(view)
        let temp = tempURL(beside: layout.viewURL)
        do {
            try fs.stage(data, at: temp)
            try fs.publish(temp, to: layout.viewURL)
        } catch {
            try? fs.remove(temp)
            throw Self.ioFault(error)
        }
    }

    // MARK: Identity

    /// Duplicate's rewrite: a new notebook identity in the index and in every
    /// ink container header. Page identities are preserved.
    package func rewriteNotebookID(_ newID: NotebookID) async throws(FormatFault) {
        let loaded = try load()
        let old = loaded.index.notebookID
        var pages: [PageWrite] = []
        for page in loaded.index.pageIDs {
            let bytes = try loadPage(page)
            guard bytes.faults.isEmpty else { continue }
            let ink: InkWrite
            if let archive = bytes.inkArchive {
                ink = .archive(archive)
            } else {
                ink = .unchanged
            }
            pages.append(PageWrite(file: bytes.file, ink: ink, layerFiles: []))
        }
        let index = loaded.index.withNotebookID(newID)
        lastIndex = index
        let report = try await save(SaveBatch(index: index, indexChanged: true, pages: pages))
        guard report.indexWritten else { throw .invalidWrite("rewriteNotebookID from \(old) to \(newID) did not commit") }
    }

    // MARK: Compact

    /// The one deletion authority. Reads every page and layer file, deletes
    /// what no committed page reaches, and only if it is older than a day.
    package func compact(now: Date = Date()) throws(FormatFault) -> CompactReport {
        var report = CompactReport()
        let index = try load().index
        let indexPages = Set(index.pageIDs)

        var reachableLayers = Set<LayerID>()
        var reachableAssets = Set<String>()
        for page in index.pageIDs {
            guard let data = try? fs.read(layout.pageURL(page)),
                  let file = try? Codecs.decodeStrict(PageFile.self, from: data, expectedKeys: DurableKeys.pageFile)
            else {
                // A page file we cannot read may name any layer.
                report.layerReclamationSuspended = true
                report.assetReclamationSuspended = true
                continue
            }
            reachableLayers.formUnion(file.layers)
        }
        if !report.layerReclamationSuspended {
            for layerID in reachableLayers {
                guard let data = try? fs.read(layout.layerURL(layerID)),
                      case .success(let layer) = LayerFile.decode(data, expecting: layerID)
                else {
                    // A layer we cannot open may name any asset.
                    report.assetReclamationSuspended = true
                    continue
                }
                if let asset = layer.payload.asset { reachableAssets.insert(asset.fileName) }
            }
        }

        func consider(_ url: URL, keep: Bool) {
            if keep { return }
            let name = url.lastPathComponent
            if let mtime = try? fs.modificationTime(url), now.timeIntervalSince(mtime) < Self.compactMinimumAge {
                report.kept.append(name)
                return
            }
            do {
                try fs.remove(url)
                report.removed.append(name)
            } catch {
                report.kept.append(name)
            }
        }

        for directory in layout.directories {
            let names = (try? fs.list(directory)) ?? []
            for name in names {
                let url = directory.appendingPathComponent(name)
                if name.hasPrefix(Self.tempPrefix) { consider(url, keep: false); continue }
                switch directory {
                case layout.pagesDirectory:
                    let id = PackageLayout.pageID(fromFileName: name, extension: "json")
                    consider(url, keep: id.map(indexPages.contains) ?? false)
                case layout.inkDirectory:
                    let id = PackageLayout.pageID(fromFileName: name, extension: "tnink")
                    consider(url, keep: id.map(indexPages.contains) ?? false)
                case layout.layersDirectory:
                    if report.layerReclamationSuspended { continue }
                    let id = PackageLayout.pageID(fromFileName: name, extension: "json").map { LayerID(raw: $0.raw) }
                    consider(url, keep: id.map(reachableLayers.contains) ?? false)
                case layout.assetsDirectory:
                    if report.assetReclamationSuspended { continue }
                    consider(url, keep: reachableAssets.contains(name))
                default:
                    continue
                }
            }
        }
        TNLog.event(.format, "compact removed \(report.removed.count), kept \(report.kept.count)")
        return report
    }
}

/// The index file with its nested key sets checked, so a page record or a
/// paper object with a missing or extra key refuses by name.
package enum IndexFile {
    package static func decode(_ data: Data) throws(FormatFault) -> NotebookIndex {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { throw .indexUnreadable("\(error)") }
        guard let top = object as? [String: Any] else { throw .indexUnreadable("top level is not an object") }
        try Self.check(Set(top.keys), against: DurableKeys.index)
        guard let pages = top["pages"] as? [[String: Any]] else { throw .corruptJSON("pages is not an array of objects") }
        for page in pages {
            try Self.check(Set(page.keys), against: DurableKeys.pageRecord)
            guard let paper = page["paper"] as? [String: Any] else { throw .corruptJSON("paper is not an object") }
            try Self.check(Set(paper.keys), against: DurableKeys.paper)
        }
        do {
            return try Codecs.decoder().decode(NotebookIndex.self, from: data)
        } catch let error as DecodingError {
            throw FormatFault(decoding: error)
        } catch {
            throw .indexUnreadable("\(error)")
        }
    }

    private static func check(_ keys: Set<String>, against expected: Set<String>) throws(FormatFault) {
        if let missing = expected.subtracting(keys).sorted().first { throw .missingKey(missing) }
        if let extra = keys.subtracting(expected).sorted().first { throw .unknownKey(extra) }
    }
}
