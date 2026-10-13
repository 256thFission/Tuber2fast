import Foundation
import TNCore
import TNFormat
import TNModel

/// A folder's colour. Named, not bytes: a name maps to something the app can
/// draw differently in light and dark, and a name this build does not ship
/// refuses the sidecar at decode rather than falling back to a colour nobody
/// chose. The mapping to a drawable colour is the app's, because `TNLibrary`
/// may not import SwiftUI (`Docs/Contract.md` — Structure).
///
/// `.neutral` is what every folder drew before decoration existed, and is
/// what "undecorated" means here: a value, not an absence.
package enum FolderColor: String, Codable, Sendable, CaseIterable {
    case neutral, red, orange, yellow, green, blue, purple, pink
}

/// A folder's glyph. The raw value *is* the SF Symbol name, so the app draws
/// `symbol.rawValue` and keeps no second table; the case name is the idea,
/// and `.folder` is the filled folder every folder drew before this.
package enum FolderSymbol: String, Codable, Sendable, CaseIterable {
    case folder = "folder.fill"
    case star = "star.fill"
    case heart = "heart.fill"
    case book = "book.closed.fill"
    case briefcase = "briefcase.fill"
    case school = "graduationcap.fill"
}

/// The pair a cell draws with. Not `Codable`: the two durable keys are flat
/// on `FolderFile`, so the flat key check below pins them with no nested
/// check of its own.
package struct FolderDecoration: Sendable, Equatable {
    package let color: FolderColor
    package let symbol: FolderSymbol

    package init(color: FolderColor, symbol: FolderSymbol) {
        self.color = color
        self.symbol = symbol
    }

    /// What a folder gets when it is made and nobody has chosen yet.
    package static let plain = FolderDecoration(color: .neutral, symbol: .folder)
}

/// A folder's identity and decoration sidecar: `.folder.json`.
package struct FolderFile: Codable, Sendable, Equatable {
    package let formatVersion: UInt32
    package let folderID: FolderID
    package let color: FolderColor
    package let symbol: FolderSymbol
    package static let currentFormatVersion: UInt32 = 1

    package init(folderID: FolderID, decoration: FolderDecoration) {
        self.formatVersion = Self.currentFormatVersion
        self.folderID = folderID
        self.color = decoration.color
        self.symbol = decoration.symbol
    }

    package var decoration: FolderDecoration { FolderDecoration(color: color, symbol: symbol) }
}

package struct FolderID: BrandedID {
    package let raw: UUID
    package init(raw: UUID) { self.raw = raw }
}

package enum ItemKind: String, Sendable, Codable {
    case folder, notebook

    /// The directory an item of this kind named `name` is stored as: a
    /// notebook is a package, a folder is its name.
    package func fileName(for name: String) -> String {
        self == .notebook ? "\(name).\(PackageLayout.packageExtension)" : name
    }
}

/// Paths relative to `Notebooks/`, where the root is the empty string.
package enum LibraryPath {
    package static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : "\(folder)/\(name)"
    }

    package static func parent(of path: String) -> String {
        path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
    }
}

/// What an item is, whatever it is called and wherever it sits. A star, a
/// link, or anything else that must survive a rename or a move names an
/// item this way rather than by path.
package enum ItemIdentity: Hashable, Codable, Sendable {
    case notebook(NotebookID)
    case folder(FolderID)
}

/// One entry in a listing. `id` is the relative path under the root.
package struct LibraryItem: Sendable, Equatable, Identifiable {
    package let id: String
    package let name: String
    package let kind: ItemKind
    package let notebookID: NotebookID?
    package let folderID: FolderID?
    /// Nil for a notebook, which has no sidecar to hold one, and for a folder
    /// whose sidecar is unreadable — the same nil that drops `folderID`.
    package let decoration: FolderDecoration?
    /// Why a folder's sidecar could not be read, shown beside the folder.
    /// Nil when it was read, and for a notebook.
    package let fault: LibraryError?
    package let createdAt: Date
    package let modifiedAt: Date

    package var relativePath: String { id }

    /// The folder this item sits in, empty at the root. Derived from the
    /// path rather than stored, because the path *is* the identity: a
    /// second copy could only disagree with it.
    package var parentPath: String { LibraryPath.parent(of: id) }

    /// Nil when the sidecar that holds the identity is unreadable.
    package var identity: ItemIdentity? {
        if let notebookID { return .notebook(notebookID) }
        if let folderID { return .folder(folderID) }
        return nil
    }
}

/// `Favorites.json` beside `Notebooks/`: which identities are starred.
///
/// Identities, not paths, so a star needs no rewriting when the item is
/// renamed or moved. An identity that resolves to nothing is kept rather
/// than pruned: the item is usually in the trash, and recovering it must
/// bring its star back.
package struct FavoritesFile: Codable, Sendable, Equatable {
    package let formatVersion: UInt32
    package let notebooks: [NotebookID]
    package let folders: [FolderID]
    package static let currentFormatVersion: UInt32 = 1

    package init(notebooks: [NotebookID], folders: [FolderID]) {
        self.formatVersion = Self.currentFormatVersion
        self.notebooks = notebooks
        self.folders = folders
    }
}

/// What a closed notebook's cover is rendered from: its first page, read
/// once. `version` is the package's newest modification time in
/// milliseconds, so a save moves the key and the cover re-renders.
package struct CoverSource: Sendable {
    package let pageID: PageID
    package let geometry: PageGeometry
    package let paper: Paper?
    package let bytes: PageBytes
    package let version: UInt64

    package static func version(at date: Date) -> UInt64 {
        UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded()))
    }
}

/// `Trash/<container>/origin.json`.
package struct TrashOrigin: Codable, Sendable, Equatable {
    package let formatVersion: UInt32
    package let originFolderID: FolderID?
    package let originPathHint: String
    package let originName: String
    package let deletedAt: Date
    package static let currentFormatVersion: UInt32 = 1
}

package struct TrashEntry: Sendable, Equatable, Identifiable {
    /// The container directory name under `Trash/`.
    package let id: String
    /// The item's, from the item the container holds.
    package let name: String
    package let kind: ItemKind
    /// Where the item came from and when, or why `origin.json` could not
    /// say, shown in place of the date.
    package let origin: Result<TrashOrigin, LibraryError>
    package let notebookID: NotebookID?
}

package enum LibraryError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidName(String)
    case itemNotFound(String)
    case notAFolder(String)
    case notANotebook(String)
    case alreadyExists(String)
    case destinationInsideSource
    case notebookIsOpen(name: String)
    /// A package whose identity another package holds (*A `NotebookID` is
    /// minted once and never rewritten*).
    case identityCollision(String)
    /// A sidecar this build cannot read, named by its file (*An unreadable
    /// sidecar refuses only the item it describes*).
    case unreadable(file: String, reason: String)
    case format(FormatFault)
    case io(String)

    package var description: String {
        switch self {
        case .invalidName(let name): "invalid name \(name)"
        case .itemNotFound(let path): "not found: \(path)"
        case .notAFolder(let path): "not a folder: \(path)"
        case .notANotebook(let path): "not a notebook: \(path)"
        case .alreadyExists(let path): "already exists: \(path)"
        case .destinationInsideSource: "a folder cannot move into itself"
        case .notebookIsOpen(let name): "close \(name) first"
        case .identityCollision: "another notebook shares its identity"
        case .unreadable(let file, let reason): "\(file) cannot be read: \(reason)"
        case .format(let fault): fault.description
        case .io(let detail): detail
        }
    }
}

/// Every byte of library I/O. Paths are relative to `Notebooks/`; a
/// notebook is a `.tubernotes` package directory, a folder is any other
/// directory. The trash and the staging area are siblings of `Notebooks/`
/// under `base`, so a scan of the tree never sees either.
package actor LibraryStore {
    package nonisolated let base: URL
    package nonisolated var notebooksRoot: URL { base.appendingPathComponent("Notebooks", isDirectory: true) }
    package nonisolated var trashRoot: URL { base.appendingPathComponent("Trash", isDirectory: true) }
    package nonisolated var stagingRoot: URL { base.appendingPathComponent("Staging", isDirectory: true) }

    /// What every sidecar is committed through, and what every
    /// `PackageStore` this library builds is handed, so a test can fault both.
    package nonisolated let fileSystem: any PackageFileSystem
    /// The steps an open or a duplicate runs on an older package; a test
    /// hands in its own.
    private let ladder: [MigrationStep]
    private let fm = FileManager.default
    private static let folderSidecar = ".folder.json"
    private static let originSidecar = "origin.json"
    private static let favoritesKeys: Set<String> = ["formatVersion", "notebooks", "folders"]
    private static let folderKeys: Set<String> = ["formatVersion", "folderID", "color", "symbol"]
    /// `originFolderID` is left out when the item came from the root.
    private static let originKeys: Set<String> = ["formatVersion", "originPathHint", "originName", "deletedAt"]

    package init(
        base: URL,
        fileSystem: any PackageFileSystem = PosixFileSystem(),
        ladder: [MigrationStep] = IndexFile.migrationSteps
    ) throws(LibraryError) {
        self.base = base
        self.fileSystem = fileSystem
        self.ladder = ladder
        for directory in [notebooksRoot, trashRoot, stagingRoot] {
            do {
                // Complete-until-first-unlock: a background save after the
                // device locks must not fail with EPERM.
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
            } catch {
                throw .io("create \(directory.path): \(error)")
            }
        }
        // Nothing in Staging is the only copy of anything, so what a process
        // that died left there goes (*Staging is scratch*). A leftover that
        // will not go costs space, not data, and is tried again next launch.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? [] {
            do {
                try FileManager.default.removeItem(at: stagingRoot.appendingPathComponent(name))
            } catch {
                TNLog.event(.library, "Staging leftover \(name) not swept: \(error)")
            }
        }
    }

    /// `Application Support/TuberNotes`: backed up, never file-shared.
    package static func defaultBase() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("TuberNotes", isDirectory: true)
    }

    // MARK: Paths and names

    package static func validate(name: String) throws(LibraryError) {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), !name.hasPrefix(".") else {
            throw .invalidName(name)
        }
    }

    package nonisolated func url(of relativePath: String) -> URL {
        relativePath.isEmpty ? notebooksRoot : notebooksRoot.appendingPathComponent(relativePath)
    }

    private static func displayName(of fileName: String) -> String {
        let suffix = ".\(PackageLayout.packageExtension)"
        return fileName.hasSuffix(suffix) ? String(fileName.dropLast(suffix.count)) : fileName
    }

    private func kind(at url: URL) -> ItemKind? {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url.pathExtension == PackageLayout.packageExtension ? .notebook : .folder
    }

    private func existing(_ relativePath: String) throws(LibraryError) -> (URL, ItemKind) {
        let url = url(of: relativePath)
        guard let kind = kind(at: url) else { throw .itemNotFound(relativePath) }
        return (url, kind)
    }

    private func modifiedAt(_ url: URL, kind: ItemKind) -> Date {
        func mtime(_ u: URL) -> Date {
            (try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast
        }
        guard kind == .notebook else { return mtime(url) }
        let layout = PackageLayout(root: url)
        return [layout.indexURL, layout.pagesDirectory, layout.inkDirectory, layout.layersDirectory].map(mtime).max() ?? .distantPast
    }

    private func createdAt(_ url: URL) -> Date {
        (try? fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? .distantPast
    }

    /// Version, identity and birth date in one read of the index's header, so
    /// a listing opens each package once rather than twice, and a package at
    /// a version this build cannot open still lists as itself.
    private func indexHeader(ofPackageAt url: URL) -> IndexFile.Header? {
        guard let data = try? Data(contentsOf: PackageLayout(root: url).indexURL) else { return nil }
        return try? IndexFile.header(data)
    }

    private func notebookID(ofPackageAt url: URL) -> NotebookID? {
        indexHeader(ofPackageAt: url)?.notebookID
    }

    /// A sidecar read strictly, its version before any key, as the index's
    /// is. A sidecar has no ladder, so another version is refused by its
    /// number. `optional` names a key the encoder leaves out for a nil.
    private static func readSidecar<T: Decodable>(
        _ type: T.Type, at url: URL, version: UInt32, keys: Set<String>, optional: Set<String> = []
    ) throws(LibraryError) -> T {
        let file = url.lastPathComponent
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw .unreadable(file: file, reason: error.localizedDescription) }
        do throws(FormatFault) {
            let top = try Codecs.topLevelObject(of: data)
            guard let found = top["formatVersion"] as? UInt32 else { throw .missingKey("formatVersion") }
            if found > version { throw .newerFormat(found: found) }
            if found < version { throw .olderFormat(found: found) }
            try Codecs.checkKeys(Set(top.keys).subtracting(optional), against: keys)
            return try Codecs.decode(type, from: data)
        } catch {
            throw .unreadable(file: file, reason: error.description)
        }
    }

    private func item(at relativePath: String, url: URL, kind: ItemKind) -> LibraryItem {
        let header = kind == .notebook ? indexHeader(ofPackageAt: url) : nil
        // One read of the sidecar, for both the identity and the decoration:
        // the listing opened it for the identity already, so two more keys in
        // it cost nothing.
        var sidecar: FolderFile?
        var fault: LibraryError?
        if kind == .folder {
            do { sidecar = try folderFile(of: relativePath) } catch { fault = error }
        }
        return LibraryItem(
            id: relativePath,
            name: Self.displayName(of: url.lastPathComponent),
            kind: kind,
            notebookID: header?.notebookID,
            folderID: sidecar?.folderID,
            decoration: sidecar?.decoration,
            fault: fault,
            createdAt: header?.createdAt ?? createdAt(url),
            modifiedAt: modifiedAt(url, kind: kind)
        )
    }

    /// Every way an item enters a directory: one rename that refuses an
    /// occupied target, then an fsync of the directory it left, unless that
    /// is Staging or the one it entered, and of the one it entered. A target
    /// that exists is `.alreadyExists` and is left as it was.
    private func land(_ source: URL, at target: URL, doing action: String) throws(LibraryError) {
        let left = source.deletingLastPathComponent()
        let entered = target.deletingLastPathComponent()
        let unsynced = [stagingRoot, entered].map(\.standardizedFileURL.path)
        let directories = unsynced.contains(left.standardizedFileURL.path) ? [entered] : [left, entered]
        do {
            try fileSystem.publishExclusive(source, to: target)
            for directory in directories { try fileSystem.syncDirectory(directory) }
        } catch let error as FileSystemError where error.code == EEXIST {
            throw .alreadyExists(Self.displayName(of: target.lastPathComponent))
        } catch {
            throw .io("\(action): \(error)")
        }
    }

    /// Lands `source` in `parent` as `name`, or as the first free `name (1)`,
    /// `name (2)` and so on, and returns where it landed (*A taken name
    /// becomes `Name (n)`*). Each candidate is claimed by the landing itself,
    /// not checked before it, so two of these in flight land under two names.
    private func freeName(
        _ name: String, kind: ItemKind, in parent: URL, landing source: URL, doing action: String
    ) throws(LibraryError) -> URL {
        var candidate = name
        var taken = 0
        while true {
            let target = parent.appendingPathComponent(kind.fileName(for: candidate), isDirectory: true)
            do throws(LibraryError) {
                try land(source, at: target, doing: action)
                return target
            } catch .alreadyExists {
                taken += 1
                candidate = "\(name) (\(taken))"
            }
        }
    }

    // MARK: The tree

    package func list(folder relativePath: String) throws(LibraryError) -> [LibraryItem] {
        let folderURL = url(of: relativePath)
        guard relativePath.isEmpty || kind(at: folderURL) == .folder else { throw .notAFolder(relativePath) }
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: folderURL.path) } catch { throw .io("list \(relativePath): \(error)") }
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            let child = folderURL.appendingPathComponent(name)
            guard let kind = kind(at: child) else { return nil }
            return item(at: LibraryPath.join(relativePath, name), url: child, kind: kind)
        }
    }

    /// Every item under `folder`, depth first, with full paths: a folder,
    /// then everything inside it, then the next. What a search over the whole
    /// library, the favorites and the identity scan read.
    ///
    /// A fresh walk each time it is asked. The store keeps no tree: a cached
    /// one would be a second copy of the file system, and the file system is
    /// the authority.
    package func listTree(under folder: String) throws(LibraryError) -> [LibraryItem] {
        var found: [LibraryItem] = []
        for item in try list(folder: folder) {
            found.append(item)
            if item.kind == .folder {
                found.append(contentsOf: try listTree(under: item.relativePath))
            }
        }
        return found
    }

    /// The folders directly inside `relativePath`, for a destination picker.
    package func listFolders(in relativePath: String) throws(LibraryError) -> [LibraryItem] {
        try list(folder: relativePath).filter { $0.kind == .folder }
    }

    package func createFolder(named name: String, in folder: String) throws(LibraryError) -> LibraryItem {
        try Self.validate(name: name)
        let parent = url(of: folder)
        guard folder.isEmpty || kind(at: parent) == .folder else { throw .notAFolder(folder) }
        let staged = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staged) }
        do {
            try fileSystem.createDirectory(staged)
            let sidecar = FolderFile(folderID: FolderID(), decoration: .plain)
            try fileSystem.writeAtomically(Codecs.encode(sidecar), to: staged.appendingPathComponent(Self.folderSidecar), syncing: staged)
        } catch let fault as FormatFault {
            throw .format(fault)
        } catch {
            throw .io("create folder \(name): \(error)")
        }
        let target = try freeName(name, kind: .folder, in: parent, landing: staged, doing: "create folder \(name)")
        return item(at: LibraryPath.join(folder, target.lastPathComponent), url: target, kind: .folder)
    }

    /// The sidecar, or why it cannot be read: it is missing, at another
    /// version, or names a colour or symbol this build does not ship. The
    /// fault costs the folder its identity, which costs it its star and its
    /// trash container name, and its decoration, and nothing else.
    package func folderFile(of folder: String) throws(LibraryError) -> FolderFile {
        try Self.readSidecar(
            FolderFile.self, at: url(of: folder).appendingPathComponent(Self.folderSidecar),
            version: FolderFile.currentFormatVersion, keys: Self.folderKeys
        )
    }

    package func folderID(of folder: String) -> FolderID? { try? folderFile(of: folder).folderID }

    /// A new one-page notebook, committed whole in Staging before it is
    /// published. Its page is US Letter and blank paper unless told
    /// otherwise. Returns its listing item, named as asked or with the first
    /// free suffix after it.
    package func createNotebook(
        named name: String, in folder: String,
        geometry: PageGeometry = .letter, paper: DrawnPaper = .blank
    ) async throws(LibraryError) -> LibraryItem {
        try Self.validate(name: name)
        let parent = url(of: folder)
        guard folder.isEmpty || kind(at: parent) == .folder else { throw .notAFolder(folder) }
        let index = NotebookIndex.new(
            notebookID: NotebookID(), firstPage: PageID(), createdAt: Date(),
            geometry: geometry, paper: paper
        )
        let staged = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staged) }
        do {
            _ = try await PackageStore.create(root: staged, index: index, fileSystem: fileSystem)
        } catch {
            throw .format(error)
        }
        let target = try freeName(name, kind: .notebook, in: parent, landing: staged, doing: "create \(name)")
        return item(at: LibraryPath.join(folder, target.lastPathComponent), url: target, kind: .notebook)
    }

    package func rename(at relativePath: String, to newName: String) throws(LibraryError) -> LibraryItem {
        try Self.validate(name: newName)
        let (source, kind) = try existing(relativePath)
        let fileName = kind.fileName(for: newName)
        let target = source.deletingLastPathComponent().appendingPathComponent(fileName, isDirectory: true)
        guard target != source else { return item(at: relativePath, url: source, kind: kind) }
        guard self.kind(at: target) == nil else { throw .alreadyExists(newName) }
        try land(source, at: target, doing: "rename \(relativePath)")
        return item(at: LibraryPath.join(LibraryPath.parent(of: relativePath), fileName), url: target, kind: kind)
    }

    package func move(at relativePath: String, toFolder folder: String) throws(LibraryError) -> LibraryItem {
        let (source, kind) = try existing(relativePath)
        let parent = url(of: folder)
        guard folder.isEmpty || self.kind(at: parent) == .folder else { throw .notAFolder(folder) }
        if kind == .folder, folder == relativePath || folder.hasPrefix(relativePath + "/") { throw .destinationInsideSource }
        let target = parent.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        // Into the folder it is already in is nothing happening, not a
        // collision with itself. `rename` carries the same line, and every
        // caller — the picker, whose "Move here" confirms the level showing,
        // and a drop on the cell's own parent — reaches this the same way.
        guard target != source else { return item(at: relativePath, url: source, kind: kind) }
        guard self.kind(at: target) == nil else { throw .alreadyExists(source.lastPathComponent) }
        try land(source, at: target, doing: "move \(relativePath)")
        return item(at: LibraryPath.join(folder, source.lastPathComponent), url: target, kind: kind)
    }

    // MARK: Covers

    /// The first page of a closed notebook, with the version its files are
    /// at. A folder is not a notebook and says so.
    package func coverSource(of relativePath: String) async throws(LibraryError) -> CoverSource {
        let (url, kind) = try existing(relativePath)
        guard kind == .notebook else { throw .notANotebook(relativePath) }
        let packageStore = PackageStore(root: url, fileSystem: fileSystem)
        let loaded: LoadedNotebook
        do { loaded = try await packageStore.load() } catch { throw .format(error) }
        guard let record = loaded.index.pages.first else { throw .format(.indexInvalid(.noPages)) }
        let bytes: PageBytes
        do { bytes = try await packageStore.loadPage(record.id) } catch { throw .format(error) }
        return CoverSource(
            pageID: record.id,
            geometry: record.geometry,
            paper: record.paper.paper,
            bytes: bytes,
            version: CoverSource.version(at: modifiedAt(url, kind: .notebook))
        )
    }

    // MARK: Favorites

    package nonisolated var favoritesURL: URL { base.appendingPathComponent("Favorites.json") }

    /// The starred identities. No file means nothing is starred.
    package func favorites() throws(LibraryError) -> Set<ItemIdentity> {
        guard fm.fileExists(atPath: favoritesURL.path) else { return [] }
        let file = try Self.readSidecar(
            FavoritesFile.self, at: favoritesURL,
            version: FavoritesFile.currentFormatVersion, keys: Self.favoritesKeys
        )
        return Set(file.notebooks.map(ItemIdentity.notebook) + file.folders.map(ItemIdentity.folder))
    }

    /// Reads the set, changes one identity, writes the whole file. A set has
    /// no partial state worth recovering, so the write is atomic and total.
    /// A file that does not read refuses the change and is not written over.
    package func setFavorite(_ identity: ItemIdentity, _ starred: Bool) throws(LibraryError) {
        var set = try favorites()
        if starred { set.insert(identity) } else { set.remove(identity) }
        var notebooks: [NotebookID] = []
        var folders: [FolderID] = []
        for identity in set {
            switch identity {
            case .notebook(let id): notebooks.append(id)
            case .folder(let id): folders.append(id)
            }
        }
        // A set has no order; sorting gives the file one, so an unchanged
        // set of stars writes unchanged bytes.
        let file = FavoritesFile(
            notebooks: notebooks.sorted { $0.description < $1.description },
            folders: folders.sorted { $0.description < $1.description }
        )
        do {
            try fileSystem.writeAtomically(Codecs.encode(file), to: favoritesURL, syncing: base)
        } catch let fault as FormatFault {
            throw .format(fault)
        } catch {
            throw .io("write favorites: \(error)")
        }
    }

    /// Every starred item that is still in the tree, in tree order. A star on
    /// a trashed item is kept in the file and shows nowhere until it comes
    /// back.
    package func listFavorites() throws(LibraryError) -> [LibraryItem] {
        let starred = try favorites()
        guard !starred.isEmpty else { return [] }
        return try listTree(under: "").filter { $0.identity.map(starred.contains) ?? false }
    }

    // MARK: Decoration

    /// Reads the sidecar, replaces its two decoration fields, and writes the
    /// file whole and atomically — `setFavorite`'s shape, for the same
    /// reason: the file is small and has no partial state worth recovering.
    /// The identity is read back rather than passed in, so decorating cannot
    /// mint a second `FolderID` for a folder that already has one.
    package func setDecoration(_ decoration: FolderDecoration, at relativePath: String) throws(LibraryError) {
        let (url, kind) = try existing(relativePath)
        guard kind == .folder else { throw .notAFolder(relativePath) }
        let current = try folderFile(of: relativePath)
        let file = FolderFile(folderID: current.folderID, decoration: decoration)
        do {
            try fileSystem.writeAtomically(Codecs.encode(file), to: url.appendingPathComponent(Self.folderSidecar), syncing: url)
        } catch let fault as FormatFault {
            throw .format(fault)
        } catch {
            throw .io("write decoration \(relativePath): \(error)")
        }
    }

    // MARK: Trash

    package func trash(at relativePath: String) throws(LibraryError) -> TrashEntry {
        let (source, kind) = try existing(relativePath)
        let parentPath = LibraryPath.parent(of: relativePath)
        let notebookID = kind == .notebook ? notebookID(ofPackageAt: source) : nil
        let containerName = switch kind {
        case .notebook: notebookID?.description ?? UUID().uuidString
        case .folder: (folderID(of: relativePath) ?? FolderID()).description
        }
        let container = trashRoot.appendingPathComponent(containerName, isDirectory: true)
        // A container that holds an item is a second item under this identity.
        // One that holds only its sidecar is an interrupted trash or recovery,
        // and is cleared below.
        if !held(in: container).isEmpty { throw .alreadyExists(containerName) }
        let origin = TrashOrigin(
            formatVersion: TrashOrigin.currentFormatVersion,
            originFolderID: parentPath.isEmpty ? nil : folderID(of: parentPath),
            originPathHint: parentPath,
            originName: source.lastPathComponent,
            deletedAt: Date()
        )
        do {
            if fm.fileExists(atPath: container.path) { try fm.removeItem(at: container) }
            try fm.createDirectory(at: container, withIntermediateDirectories: false)
            try fileSystem.writeAtomically(Codecs.encode(origin), to: container.appendingPathComponent(Self.originSidecar), syncing: container)
        } catch let fault as FormatFault {
            throw .format(fault)
        } catch {
            throw .io("trash \(relativePath): \(error)")
        }
        try land(source, at: container.appendingPathComponent(source.lastPathComponent, isDirectory: true), doing: "trash \(relativePath)")
        return TrashEntry(
            id: containerName, name: Self.displayName(of: origin.originName), kind: kind,
            origin: .success(origin), notebookID: notebookID
        )
    }

    /// The items a trash container holds, by file name: its directories.
    /// `origin.json`, and a temp file a crash left beside it, are not items.
    private func held(in container: URL) -> [(fileName: String, kind: ItemKind)] {
        ((try? fm.contentsOfDirectory(atPath: container.path)) ?? []).sorted().compactMap { name in
            kind(at: container.appendingPathComponent(name)).map { (name, $0) }
        }
    }

    /// The item a trash container holds and where it came from, or nil when
    /// it holds none. The entry is the item, not its record, so a record
    /// that does not read is the entry's fault and hides nothing.
    private func trashed(in container: URL) -> (fileName: String, kind: ItemKind, origin: Result<TrashOrigin, LibraryError>)? {
        guard let item = held(in: container).first else { return nil }
        let origin = Result { () throws(LibraryError) -> TrashOrigin in
            try Self.readSidecar(
                TrashOrigin.self, at: container.appendingPathComponent(Self.originSidecar),
                version: TrashOrigin.currentFormatVersion, keys: Self.originKeys, optional: ["originFolderID"]
            )
        }
        return (item.fileName, item.kind, origin)
    }

    /// Every container that holds an item, including one whose `origin.json`
    /// does not read: that entry carries the fault in place of its record.
    package func listTrash() throws(LibraryError) -> [TrashEntry] {
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: trashRoot.path) } catch { throw .io("list trash: \(error)") }
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { containerName in
            let container = trashRoot.appendingPathComponent(containerName)
            guard let found = trashed(in: container) else { return nil }
            let item = container.appendingPathComponent(found.fileName)
            return TrashEntry(
                id: containerName, name: Self.displayName(of: found.fileName), kind: found.kind,
                origin: found.origin, notebookID: found.kind == .notebook ? notebookID(ofPackageAt: item) : nil
            )
        }
    }

    /// Restores the original name, or the first free suffix after it when
    /// that is taken; falls back to the root when the origin folder is gone,
    /// or when the record that says where it was could not be read.
    package func recover(_ entry: TrashEntry) throws(LibraryError) -> LibraryItem {
        let container = trashRoot.appendingPathComponent(entry.id)
        guard let found = trashed(in: container) else { throw .itemNotFound(entry.id) }
        let source = container.appendingPathComponent(found.fileName)
        var folder = ""
        if case .success(let record) = found.origin, self.kind(at: url(of: record.originPathHint)) == .folder {
            folder = record.originPathHint
        }
        let target = try freeName(
            Self.displayName(of: found.fileName), kind: found.kind, in: url(of: folder),
            landing: source, doing: "recover \(entry.id)"
        )
        do { try fm.removeItem(at: container) } catch { throw .io("recover \(entry.id): \(error)") }
        return item(at: LibraryPath.join(folder, target.lastPathComponent), url: target, kind: found.kind)
    }

    /// Every container under `Trash/`. Each one that holds an item is listed,
    /// so this takes what the listing shows and containers holding nothing.
    package func emptyTrash() throws(LibraryError) {
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: trashRoot.path) } catch { throw .io("list trash: \(error)") }
        for name in names where !name.hasPrefix(".") {
            do { try fm.removeItem(at: trashRoot.appendingPathComponent(name)) } catch { throw .io("delete \(name): \(error)") }
        }
    }

    package func deletePermanently(_ entry: TrashEntry) throws(LibraryError) {
        do { try fm.removeItem(at: trashRoot.appendingPathComponent(entry.id)) } catch { throw .io("delete \(entry.id): \(error)") }
    }

    // MARK: Duplicate

    /// A copy with its own notebook identity, built in Staging and published
    /// like a new notebook. Page identities are preserved, which keeps
    /// internal links internal. The copy of an older package runs the ladder
    /// before it takes its identity; the original stays as it was.
    package func duplicateNotebook(at relativePath: String) async throws(LibraryError) -> LibraryItem {
        let (source, kind) = try existing(relativePath)
        guard kind == .notebook else { throw .notANotebook(relativePath) }
        let staged = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staged) }
        do { try fm.copyItem(at: source, to: staged) } catch { throw .io("stage duplicate of \(relativePath): \(error)") }
        try run(try migrationSteps(forPackageAt: staged), on: staged, migrating: relativePath)
        do {
            try await PackageStore(root: staged, fileSystem: fileSystem).rewriteNotebookID(NotebookID())
        } catch {
            throw .format(error)
        }
        let target = try freeName(
            "\(Self.displayName(of: source.lastPathComponent)) copy", kind: .notebook,
            in: source.deletingLastPathComponent(), landing: staged, doing: "land duplicate of \(relativePath)"
        )
        return item(at: LibraryPath.join(LibraryPath.parent(of: relativePath), target.lastPathComponent), url: target, kind: .notebook)
    }

    // MARK: Migration

    /// Brings an older package to the current version before it opens: the
    /// steps run on a clone in Staging, the clone is loaded whole and synced,
    /// and one exchange swaps it in for the original (*An older notebook is
    /// migrated on open*). A current package, and one whose index does not
    /// read, are left to the open; a newer one is refused. Only
    /// `Library.checkout` calls it, inside its reservation.
    package func upgradePackage(at relativePath: String) async throws(LibraryError) {
        let live = url(of: relativePath)
        let steps = try migrationSteps(forPackageAt: live)
        guard !steps.isEmpty else { return }
        let staged = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // The clone until the exchange, the original after it.
        defer { try? fm.removeItem(at: staged) }
        do { try fm.copyItem(at: live, to: staged) } catch { throw .io("stage migration of \(relativePath): \(error)") }
        try run(steps, on: staged, migrating: relativePath)
        // Loading every page proves the steps left a package this build
        // reads. A page it refuses is refused again on open and does not
        // refuse the migration (*Refuse at the narrowest scope*).
        let clone = PackageStore(root: staged, fileSystem: fileSystem)
        do {
            for page in try await clone.load().index.pageIDs { _ = try await clone.loadPage(page) }
        } catch {
            throw .format(error)
        }
        do {
            for directory in PackageLayout(root: staged).directories { try fileSystem.syncDirectory(directory) }
            try fileSystem.exchange(staged, live)
            try fileSystem.syncDirectory(live.deletingLastPathComponent())
        } catch {
            throw .io("migrate \(relativePath): \(error)")
        }
        TNLog.event(.library, "migrated \(relativePath) by \(steps.count) steps")
    }

    /// None when the package is current or its index does not read, which
    /// the load that follows refuses with its own fault.
    private func migrationSteps(forPackageAt url: URL) throws(LibraryError) -> ArraySlice<MigrationStep> {
        guard let header = indexHeader(ofPackageAt: url) else { return [] }
        do { return try IndexFile.steps(from: header.formatVersion, in: ladder) } catch { throw .format(error) }
    }

    /// Runs `steps` on `staged`, a copy in Staging and never a live package.
    private func run(_ steps: ArraySlice<MigrationStep>, on staged: URL, migrating relativePath: String) throws(LibraryError) {
        do {
            for step in steps { try step(staged, fileSystem) }
        } catch let fault as FormatFault {
            throw .format(fault)
        } catch {
            throw .io("migrate \(relativePath): \(error)")
        }
    }

    // MARK: Identity index

    /// Every notebook identity under the root and in the trash, by relative
    /// path. Off-main by being here. The first package found under an
    /// identity holds it; a later one is a collision, recorded and never
    /// rewritten.
    package func scanIdentities() throws(LibraryError) -> IdentityIndex {
        var index = IdentityIndex()
        for item in try listTree(under: "") where item.kind == .notebook {
            guard let id = item.notebookID else { continue }
            if index.live[id] == nil { index.live[id] = item.relativePath } else { index.collisions[item.relativePath] = id }
        }
        for entry in try listTrash() {
            if let id = entry.notebookID { index.trashed[id] = entry.id }
        }
        return index
    }
}

/// `notebookID` to relative path, plus the trashed ones by container and
/// the collided packages by path. In memory only; rebuilt by scanning.
package struct IdentityIndex: Sendable, Equatable {
    package var live: [NotebookID: String] = [:]
    package var trashed: [NotebookID: String] = [:]
    /// Each package found after the first under its identity, by path.
    package var collisions: [String: NotebookID] = [:]

    package enum Resolution: Sendable, Equatable {
        case live(path: String)
        case trashed(container: String)
        case collided
        case missing
    }

    package func resolve(_ id: NotebookID) -> Resolution {
        if collisions.values.contains(id) { return .collided }
        if let path = live[id] { return .live(path: path) }
        if let container = trashed[id] { return .trashed(container: container) }
        return .missing
    }
}
