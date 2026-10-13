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

/// Why one page's write was refused. `staging` is transient (retry);
/// everything else is the write's own fault and retrying repeats it.
package enum PageRefusal: Error, Sendable, Equatable {
    case invalidPageFile(PageFault)
    case layerFileMissing(LayerID)
    case layerNotInPage(LayerID)
    case invalidLayer(LayerFault)
    case danglingAsset(LayerID, AssetRef)
    case inkWithoutHasInk
    case hasInkWithoutContainer
    case encodeFailed(String)
    case staging(FileSystemError)

    package var isTransient: Bool {
        if case .staging = self { return true }
        return false
    }
}

package struct SaveReport: Sendable, Equatable {
    /// Pages whose files are present after this save (written or unchanged).
    package let committed: Set<PageID>
    package let refusals: [PageID: PageRefusal]
    package let indexWritten: Bool
    /// The intended pages the written index left out because their files
    /// are not present. Empty when no index was written.
    package let omitted: Set<PageID>
    /// The intended index intersected with present pages was empty, so the
    /// index was withheld. Every page in the batch stays dirty.
    package let indexWithheld: Bool
}

package struct LoadedNotebook: Sendable, Equatable {
    package let index: NotebookIndex
    package let pageFaults: [PageID: [PageFault]]
}

/// One page's bytes and what was learned reading them. A page with any
/// fault is a placeholder; `layers` holds only the layers that read.
package struct PageBytes: Sendable, Equatable {
    package let file: PageFile
    package let inkArchive: Data?
    package let layers: [Layer]
    package let faults: [PageFault]
    /// A valid container was found under `hasInk == false`: the ink is
    /// real, and the next save must record it.
    package let inkRecordNeeded: Bool

    package var isPlaceholder: Bool { !faults.isEmpty }
}

package struct CompactReport: Sendable, Equatable {
    package var removed: [String] = []
    package var kept = 0
    package var layerReclamationSuspended = false
    package var assetReclamationSuspended = false
}

/// The store: one per package, the only writer of its bytes.
///
/// A save plans, stages, and publishes in three phases (D10). Nothing is
/// deleted by a save or by an open; `compact()` is the one deletion
/// authority (D11). The store caches nothing about the index; it learns the
/// notebook's identity at open and keeps only that.
package actor PackageStore {
    package nonisolated let layout: PackageLayout
    private let fs: any PackageFileSystem
    private var knownNotebookID: NotebookID?

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
            do { try fs.createDirectory(directory) } catch { throw Self.ioFault(error) }
        }
    }

    private static func ioFault(_ error: any Error) -> FormatFault {
        if let fault = error as? FormatFault { return fault }
        if let error = error as? FileSystemError { return .io(error) }
        return .invalidWrite("\(error)")
    }

    // MARK: Open

    package func load() throws(FormatFault) -> LoadedNotebook {
        let data: Data
        do {
            data = try fs.read(layout.indexURL)
        } catch let error as FileSystemError where error.code == ENOENT {
            throw .noPackage
        } catch {
            throw Self.ioFault(error)
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
        // Stat only: the asset's bytes are the renderer's business, and open
        // reads no page.
        for record in validated.pages {
            guard let asset = record.paperAsset, !fs.exists(layout.assetURL(asset)) else { continue }
            faults[record.id, default: []].append(.paperAssetMissing(asset.fileName))
        }
        knownNotebookID = validated.notebookID
        return LoadedNotebook(index: validated, pageFaults: faults)
    }

    private func notebookID() throws(FormatFault) -> NotebookID {
        if let knownNotebookID { return knownNotebookID }
        return try load().index.notebookID
    }

    package func loadPage(_ page: PageID) throws(FormatFault) -> PageBytes {
        let notebookID = try notebookID()
        func refused(_ fault: PageFault) -> PageBytes {
            PageBytes(file: .empty(pageID: page), inkArchive: nil, layers: [], faults: [fault], inkRecordNeeded: false)
        }
        let fileData: Data
        do {
            fileData = try fs.read(layout.pageURL(page))
        } catch let error as FileSystemError where error.code == ENOENT {
            return refused(.missingPageFile)
        } catch {
            return refused(.pageFileUnreadable("\(error)"))
        }
        let file: PageFile
        do {
            file = try Codecs.decodeStrict(PageFile.self, from: fileData, expectedKeys: DurableKeys.pageFile).validated(expecting: page)
        } catch let fault as PageFault {
            return refused(fault)
        } catch {
            return refused(.pageFileUnreadable("\(error)"))
        }

        var faults: [PageFault] = []
        var inkArchive: Data?
        var inkRecordNeeded = false
        let inkURL = layout.inkURL(page)
        if file.hasInk {
            do {
                let container = try fs.read(inkURL)
                inkArchive = try InkContainer.decode(container, expecting: notebookID, page: page).archive
            } catch let error as FileSystemError where error.code == ENOENT {
                faults.append(.missingInk)
            } catch let fault as InkContainerFault {
                faults.append(.inkContainerInvalid(fault))
            } catch {
                faults.append(.pageFileUnreadable("ink: \(error)"))
            }
        } else if let container = try? fs.read(inkURL),
                  let decoded = try? InkContainer.decode(container, expecting: notebookID, page: page) {
            // A crash between publish phases: the container landed, the page
            // file recording it did not. The container is the ink.
            inkArchive = decoded.archive
            inkRecordNeeded = true
            TNLog.event(.format, "page \(page) has a container under hasInk=false; adopting it")
        }

        var layers: [Layer] = []
        for layerID in file.layers {
            let result: Result<Layer, LayerFault>
            do {
                result = LayerFile.decode(try fs.read(layout.layerURL(layerID)), expecting: layerID)
            } catch let error as FileSystemError where error.code == ENOENT {
                result = .failure(.fileMissing(layerID))
            } catch {
                result = .failure(.fileUnreadable(layerID, "\(error)"))
            }
            switch result {
            case .success(let layer):
                if let asset = layer.payload.asset, !fs.exists(layout.assetURL(asset)) {
                    faults.append(.layerRefused(.danglingAsset(layer.id, asset)))
                } else {
                    layers.append(layer)
                }
            case .failure(let fault):
                faults.append(.layerRefused(fault))
            }
        }
        return PageBytes(file: file, inkArchive: inkArchive, layers: layers, faults: faults, inkRecordNeeded: inkRecordNeeded)
    }

    // MARK: Save

    private struct Staged {
        let page: PageID
        var leaves: [(temp: URL, final: URL)] = []
        var pageFile: (temp: URL, final: URL)?
        var temps: [URL] { leaves.map(\.temp) + (pageFile.map { [$0.temp] } ?? []) }
    }

    private struct PagePlan {
        let write: PageWrite
        let pageFileData: Data
        let layerData: [(LayerID, Data)]
        /// Nothing about this page changes on disk; it is present as it is.
        let skip: Bool
        var bytes: Int64 {
            var total = Int64(pageFileData.count) + layerData.reduce(0) { $0 + Int64($1.1.count) }
            if case .archive(let archive) = write.ink { total += Int64(archive.count + InkContainer.headerLength) }
            return total
        }
    }

    package func save(_ batch: SaveBatch) async throws(FormatFault) -> SaveReport {
        // ---- plan: no writes; stats and reads of what is already there
        var seen = Set<PageID>()
        for write in batch.pages {
            guard seen.insert(write.pageID).inserted else { throw .invalidWrite("page \(write.pageID) written twice in one batch") }
            guard batch.index.record(of: write.pageID) != nil else { throw .invalidWrite("page \(write.pageID) is not in the intended index") }
        }
        let intended: NotebookIndex
        do { intended = try batch.index.validated() } catch { throw .indexInvalid(error) }

        var refusals: [PageID: PageRefusal] = [:]
        var planned: [PagePlan] = []
        for write in batch.pages {
            switch plan(write) {
            case .failure(let refusal): refusals[write.pageID] = refusal
            case .success(let plan): planned.append(plan)
            }
        }
        let indexData: Data? = batch.indexChanged ? try Codecs.encode(intended) : nil
        let bytesNeeded = planned.reduce(Int64(indexData?.count ?? 0)) { $0 + $1.bytes }
        do {
            let available = try fs.availableBytes(at: layout.root)
            if available < bytesNeeded + Self.freeSpaceSlack {
                throw FormatFault.insufficientSpace(needed: bytesNeeded + Self.freeSpaceSlack, available: available)
            }
        } catch {
            throw Self.ioFault(error)
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
                    let temp = fs.tempURL(beside: final)
                    try fs.stage(InkContainer.encode(notebookID: intended.notebookID, pageID: plan.write.pageID, archive: archive), at: temp)
                    entry.leaves.append((temp, final))
                }
                for (layerID, data) in plan.layerData {
                    let final = layout.layerURL(layerID)
                    let temp = fs.tempURL(beside: final)
                    try fs.stage(data, at: temp)
                    entry.leaves.append((temp, final))
                }
                let final = layout.pageURL(plan.write.pageID)
                let temp = fs.tempURL(beside: final)
                try fs.stage(plan.pageFileData, at: temp)
                entry.pageFile = (temp, final)
                staged.append(entry)
            } catch {
                for temp in entry.temps { try? fs.remove(temp) }
                let refusal: PageRefusal = (error as? FileSystemError).map(PageRefusal.staging) ?? .encodeFailed("\(error)")
                refusals[plan.write.pageID] = refusal
                TNLog.event(.format, "page \(plan.write.pageID) refused at staging: \(error)")
            }
        }

        // ---- publish 1: leaves, then sync their directories
        // ---- publish 2: page files, then sync pages/
        do {
            for entry in staged { for leaf in entry.leaves { try fs.publish(leaf.temp, to: leaf.final) } }
            try fs.syncDirectory(layout.inkDirectory)
            try fs.syncDirectory(layout.layersDirectory)
            for entry in staged { if let pageFile = entry.pageFile { try fs.publish(pageFile.temp, to: pageFile.final) } }
            try fs.syncDirectory(layout.pagesDirectory)
        } catch {
            for entry in staged { for temp in entry.temps { try? fs.remove(temp) } }
            throw Self.ioFault(error)
        }

        // ---- publish 3: the index, if it changed, naming only present pages
        let committed = Set(staged.map(\.page)).union(unchanged)
        var indexWritten = false
        var omitted = Set<PageID>()
        var indexWithheld = false
        if let indexData {
            let present = intended.pages.filter { committed.contains($0.id) || fs.exists(layout.pageURL($0.id)) }
            if present.isEmpty {
                indexWithheld = true
                TNLog.event(.format, "index withheld: no intended page is present")
            } else {
                let data = present.count == intended.pages.count ? indexData : try Codecs.encode(intended.withPages(present))
                do { try fs.writeAtomically(data, to: layout.indexURL, syncing: layout.root) } catch { throw Self.ioFault(error) }
                knownNotebookID = intended.notebookID
                indexWritten = true
                omitted = Set(intended.pageIDs).subtracting(present.map(\.id))
            }
        }
        return SaveReport(committed: committed, refusals: refusals, indexWritten: indexWritten, omitted: omitted, indexWithheld: indexWithheld)
    }

    private func plan(_ write: PageWrite) -> Result<PagePlan, PageRefusal> {
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
            do { layerData.append((layer.id, try LayerFile.encode(layer))) } catch { return .failure(.encodeFailed(error.description)) }
        }
        switch write.ink {
        case .archive:
            guard file.hasInk else { return .failure(.inkWithoutHasInk) }
        case .unchanged:
            if file.hasInk, !fs.exists(layout.inkURL(write.pageID)) { return .failure(.hasInkWithoutContainer) }
        }
        let pageFileData: Data
        do { pageFileData = try Codecs.encode(file) } catch { return .failure(.encodeFailed(error.description)) }

        // Nothing to write if the ink is unchanged, no layer file is due,
        // and the page file on disk already reads exactly like this one.
        let skip = write.ink == .unchanged && layerData.isEmpty
            && (try? fs.read(layout.pageURL(write.pageID))) == pageFileData
        return .success(PagePlan(write: write, pageFileData: pageFileData, layerData: layerData, skip: skip))
    }

    // MARK: Assets

    /// Assets are immutable and published at import, before any layer names
    /// them. Writing an asset that exists is a no-op.
    package func writeAsset(_ data: Data, _ ref: AssetRef) throws(FormatFault) {
        guard data.count <= AssetBounds.maxBytes else { throw .invalidWrite("asset \(ref.fileName) exceeds \(AssetBounds.maxBytes) bytes") }
        let final = layout.assetURL(ref)
        if fs.exists(final) { return }
        do { try fs.writeAtomically(data, to: final, syncing: layout.assetsDirectory) } catch { throw Self.ioFault(error) }
    }

    package func readAsset(_ ref: AssetRef) throws(FormatFault) -> Data {
        do { return try fs.read(layout.assetURL(ref)) } catch { throw Self.ioFault(error) }
    }

    // MARK: View state (disposable)

    package func readView() -> ViewState? {
        guard let data = try? fs.read(layout.viewURL),
              let view = try? Codecs.decodeStrict(ViewState.self, from: data, expectedKeys: DurableKeys.view)
        else { return nil }
        return view
    }

    package func writeView(_ view: ViewState) throws(FormatFault) {
        do { try fs.writeAtomically(Codecs.encode(view), to: layout.viewURL, syncing: nil) } catch { throw Self.ioFault(error) }
    }

    // MARK: Identity

    /// Duplicate's rewrite: a new notebook identity in the index and in the
    /// header of every ink container. Payloads are untouched and page
    /// identities are preserved, so no page need be decodable for its
    /// identity to be corrected.
    package func rewriteNotebookID(_ newID: NotebookID) async throws(FormatFault) {
        let loaded = try load()
        let names = (try? fs.list(layout.inkDirectory)) ?? []
        for name in names where !name.hasPrefix(Self.tempPrefix) {
            let url = layout.inkDirectory.appendingPathComponent(name)
            let data: Data
            do { data = try fs.read(url) } catch { throw Self.ioFault(error) }
            let rewritten: Data
            do { rewritten = try InkContainer.rewritingNotebookID(data, to: newID) } catch { continue }
            do { try fs.writeAtomically(rewritten, to: url, syncing: nil) } catch { throw Self.ioFault(error) }
        }
        do { try fs.syncDirectory(layout.inkDirectory) } catch { throw Self.ioFault(error) }
        let report = try await save(SaveBatch(index: loaded.index.withNotebookID(newID), indexChanged: true, pages: []))
        guard report.indexWritten else { throw .invalidWrite("rewriteNotebookID to \(newID) did not commit") }
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
        // Paper is reached from the index, not from a page file: a paper
        // asset stays reachable even for a page whose file will not read.
        for record in index.pages {
            if let asset = record.paperAsset { reachableAssets.insert(asset.fileName) }
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
            if let mtime = try? fs.modificationTime(url), now.timeIntervalSince(mtime) < Self.compactMinimumAge {
                report.kept += 1
                return
            }
            do {
                try fs.remove(url)
                report.removed.append(url.lastPathComponent)
            } catch {
                report.kept += 1
            }
        }

        for directory in layout.directories {
            for name in (try? fs.list(directory)) ?? [] {
                let url = directory.appendingPathComponent(name)
                if name.hasPrefix(Self.tempPrefix) { consider(url, keep: false); continue }
                switch directory {
                case layout.pagesDirectory:
                    let id: PageID? = PackageLayout.identity(fromFileName: name, extension: "json")
                    consider(url, keep: id.map(indexPages.contains) ?? false)
                case layout.inkDirectory:
                    let id: PageID? = PackageLayout.identity(fromFileName: name, extension: "tnink")
                    consider(url, keep: id.map(indexPages.contains) ?? false)
                case layout.layersDirectory:
                    if report.layerReclamationSuspended { continue }
                    let id: LayerID? = PackageLayout.identity(fromFileName: name, extension: "json")
                    consider(url, keep: id.map(reachableLayers.contains) ?? false)
                case layout.assetsDirectory:
                    if report.assetReclamationSuspended { continue }
                    consider(url, keep: reachableAssets.contains(name))
                default:
                    continue
                }
            }
        }
        TNLog.event(.format, "compact removed \(report.removed.count), kept \(report.kept)")
        return report
    }
}

/// The index file with its nested key sets checked, so a page record or a
/// paper object with a missing or extra key refuses by name.
package enum IndexFile {
    /// The three keys that never change name or type, read at any version.
    package struct Header: Decodable, Sendable, Equatable {
        package let formatVersion: UInt32
        package let notebookID: NotebookID
        package let createdAt: Date
    }

    package static func header(_ data: Data) throws(FormatFault) -> Header {
        try Codecs.decode(Header.self, from: data)
    }

    package static func decode(_ data: Data) throws(FormatFault) -> NotebookIndex {
        let top = try Codecs.topLevelObject(of: data)
        // The version is read before any key: another version's key set is
        // not this one's. This is the only version gate a load passes, so an
        // index in memory is always current and save checks no version. An
        // older index is a step's input, never this decoder's.
        guard let version = top["formatVersion"] as? UInt32 else { throw .missingKey("formatVersion") }
        if version > NotebookIndex.currentFormatVersion { throw .newerFormat(found: version) }
        if version < NotebookIndex.currentFormatVersion { throw .olderFormat(found: version) }
        try Codecs.checkKeys(Set(top.keys), against: DurableKeys.index)
        guard let pages = top["pages"] as? [[String: Any]] else { throw .corruptJSON("pages is not an array of objects") }
        for page in pages {
            try Codecs.checkKeys(Set(page.keys), against: DurableKeys.pageRecord)
            guard let paper = page["paper"] as? [String: Any] else { throw .corruptJSON("paper is not an object") }
            guard let kind = paper["kind"] as? String else { throw .missingKey("kind") }
            // An unknown kind is a page's fault, not the index's, so its keys
            // are not pinned: this build cannot know what they should be.
            if PaperKind.isKnownKind(kind) {
                try Codecs.checkKeys(Set(paper.keys), against: DurableKeys.paper(kind: kind))
            }
        }
        guard let bookmarks = top["bookmarks"] as? [[String: Any]] else {
            throw .corruptJSON("bookmarks is not an array of objects")
        }
        for bookmark in bookmarks {
            try Codecs.checkKeys(Set(bookmark.keys), against: DurableKeys.bookmark)
        }
        return try Codecs.decode(NotebookIndex.self, from: data)
    }
}

/// One rung of the ladder: carries the package at the URL, a copy in
/// Staging, from one version to the next. It reads its version's shape as
/// its own input, and writes through the file system it is handed, so its
/// files are staged with the barrier and published by rename as a save's
/// are.
package typealias MigrationStep = @Sendable (URL, any PackageFileSystem) throws -> Void

extension IndexFile {
    /// Oldest first, and the last carries `currentFormatVersion - 1` to the
    /// current version. Empty: every version is 1.
    package static let migrationSteps: [MigrationStep] = []

    /// The steps that carry a package at `version` to the current one: none
    /// for the current version, and a refusal for a newer one or for an
    /// older one the ladder does not reach down to.
    package static func steps(from version: UInt32, in ladder: [MigrationStep]) throws(FormatFault) -> ArraySlice<MigrationStep> {
        let current = NotebookIndex.currentFormatVersion
        if version > current { throw .newerFormat(found: version) }
        let behind = Int(current - version)
        guard behind <= ladder.count else { throw .olderFormat(found: version) }
        return ladder.suffix(behind)
    }
}
