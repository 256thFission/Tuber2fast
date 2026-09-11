import Foundation
import TNCore
import TNFormat
import TNModel

/// A folder's identity and decoration sidecar: `.folder.json`.
package struct FolderFile: Codable, Sendable, Equatable {
    package let formatVersion: UInt32
    package let folderID: FolderID
    package static let currentFormatVersion: UInt32 = 1
    package init(folderID: FolderID) {
        self.formatVersion = Self.currentFormatVersion
        self.folderID = folderID
    }
}

package struct FolderID: BrandedID {
    package let raw: UUID
    package init(raw: UUID) { self.raw = raw }
}

package enum ItemKind: String, Sendable, Codable {
    case folder, notebook
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
    package let createdAt: Date
    package let modifiedAt: Date

    package var relativePath: String { id }

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
    package let name: String
    package let kind: ItemKind
    package let origin: TrashOrigin
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

    private let fm = FileManager.default
    private static let folderSidecar = ".folder.json"
    private static let originSidecar = "origin.json"
    private static let favoritesKeys: Set<String> = ["formatVersion", "notebooks", "folders"]

    package init(base: URL) throws(LibraryError) {
        self.base = base
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

    private static func packageName(_ name: String) -> String { "\(name).\(PackageLayout.packageExtension)" }

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

    /// Identity and birth date in one read of the index, so a listing opens
    /// each package once rather than twice.
    private func indexFacts(ofPackageAt url: URL) -> (id: NotebookID, createdAt: Date)? {
        guard let data = try? Data(contentsOf: PackageLayout(root: url).indexURL),
              let index = try? IndexFile.decode(data)
        else { return nil }
        return (index.notebookID, index.createdAt)
    }

    private func notebookID(ofPackageAt url: URL) -> NotebookID? {
        indexFacts(ofPackageAt: url)?.id
    }

    private func item(at relativePath: String, url: URL, kind: ItemKind) -> LibraryItem {
        let facts = kind == .notebook ? indexFacts(ofPackageAt: url) : nil
        return LibraryItem(
            id: relativePath,
            name: Self.displayName(of: url.lastPathComponent),
            kind: kind,
            notebookID: facts?.id,
            folderID: kind == .folder ? folderID(of: relativePath) : nil,
            createdAt: facts?.createdAt ?? createdAt(url),
            modifiedAt: modifiedAt(url, kind: kind)
        )
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
            let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            return item(at: childPath, url: child, kind: kind)
        }
    }

    /// The folders directly inside `relativePath`, for a destination picker.
    package func listFolders(in relativePath: String) throws(LibraryError) -> [LibraryItem] {
        try list(folder: relativePath).filter { $0.kind == .folder }
    }

    package func createFolder(named name: String, in folder: String) throws(LibraryError) -> LibraryItem {
        try Self.validate(name: name)
        let parent = url(of: folder)
        guard folder.isEmpty || kind(at: parent) == .folder else { throw .notAFolder(folder) }
        let target = parent.appendingPathComponent(name, isDirectory: true)
        guard kind(at: target) == nil else { throw .alreadyExists(name) }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            try Codecs.encode(FolderFile(folderID: FolderID())).write(to: target.appendingPathComponent(Self.folderSidecar))
        } catch let fault as FormatFault {
            throw .format(fault)
        } catch {
            throw .io("create folder \(name): \(error)")
        }
        let path = folder.isEmpty ? name : "\(folder)/\(name)"
        return item(at: path, url: target, kind: .folder)
    }

    package func folderID(of folder: String) -> FolderID? {
        let sidecar = url(of: folder).appendingPathComponent(Self.folderSidecar)
        guard let data = try? Data(contentsOf: sidecar),
              let file = try? Codecs.decodeStrict(FolderFile.self, from: data, expectedKeys: ["formatVersion", "folderID"]),
              file.formatVersion == FolderFile.currentFormatVersion
        else { return nil }
        return file.folderID
    }

    /// A new one-page notebook, committed. Its page is US Letter and blank
    /// paper unless told otherwise. Returns its listing item.
    package func createNotebook(
        named name: String, in folder: String,
        geometry: PageGeometry = .letter, paper: DrawnPaper = .blank
    ) async throws(LibraryError) -> LibraryItem {
        try Self.validate(name: name)
        let parent = url(of: folder)
        guard folder.isEmpty || kind(at: parent) == .folder else { throw .notAFolder(folder) }
        let target = parent.appendingPathComponent(Self.packageName(name), isDirectory: true)
        guard kind(at: target) == nil else { throw .alreadyExists(name) }
        let index = NotebookIndex.new(
            notebookID: NotebookID(), firstPage: PageID(), createdAt: Date(),
            geometry: geometry, paper: paper
        )
        do {
            _ = try await PackageStore.create(root: target, index: index)
        } catch {
            throw .format(error)
        }
        let path = folder.isEmpty ? target.lastPathComponent : "\(folder)/\(target.lastPathComponent)"
        return item(at: path, url: target, kind: .notebook)
    }

    package func rename(at relativePath: String, to newName: String) throws(LibraryError) -> LibraryItem {
        try Self.validate(name: newName)
        let (source, kind) = try existing(relativePath)
        let fileName = kind == .notebook ? Self.packageName(newName) : newName
        let target = source.deletingLastPathComponent().appendingPathComponent(fileName, isDirectory: true)
        guard target != source else { return item(at: relativePath, url: source, kind: kind) }
        guard self.kind(at: target) == nil else { throw .alreadyExists(newName) }
        do { try fm.moveItem(at: source, to: target) } catch { throw .io("rename \(relativePath): \(error)") }
        let parent = relativePath.contains("/") ? String(relativePath[..<relativePath.lastIndex(of: "/")!]) : ""
        let path = parent.isEmpty ? fileName : "\(parent)/\(fileName)"
        return item(at: path, url: target, kind: kind)
    }

    package func move(at relativePath: String, toFolder folder: String) throws(LibraryError) -> LibraryItem {
        let (source, kind) = try existing(relativePath)
        let parent = url(of: folder)
        guard folder.isEmpty || self.kind(at: parent) == .folder else { throw .notAFolder(folder) }
        if kind == .folder, folder == relativePath || folder.hasPrefix(relativePath + "/") { throw .destinationInsideSource }
        let target = parent.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        guard self.kind(at: target) == nil else { throw .alreadyExists(source.lastPathComponent) }
        do { try fm.moveItem(at: source, to: target) } catch { throw .io("move \(relativePath): \(error)") }
        let path = folder.isEmpty ? source.lastPathComponent : "\(folder)/\(source.lastPathComponent)"
        return item(at: path, url: target, kind: kind)
    }

    // MARK: Favorites

    package nonisolated var favoritesURL: URL { base.appendingPathComponent("Favorites.json") }

    /// The starred identities. No file means nothing is starred.
    package func favorites() throws(LibraryError) -> Set<ItemIdentity> {
        guard fm.fileExists(atPath: favoritesURL.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: favoritesURL) } catch { throw .io("read favorites: \(error)") }
        let file: FavoritesFile
        do {
            file = try Codecs.decodeStrict(FavoritesFile.self, from: data, expectedKeys: Self.favoritesKeys)
        } catch {
            throw .format(error)
        }
        guard file.formatVersion == FavoritesFile.currentFormatVersion else {
            throw .format(.corruptJSON("Favorites.json is version \(file.formatVersion)"))
        }
        return Set(file.notebooks.map(ItemIdentity.notebook) + file.folders.map(ItemIdentity.folder))
    }

    /// Reads the set, changes one identity, writes the whole file. A set has
    /// no partial state worth recovering, so the write is atomic and total.
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
            try Codecs.encode(file).write(to: favoritesURL, options: .atomic)
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
        var found: [LibraryItem] = []
        func walk(_ folder: String) throws(LibraryError) {
            for item in try list(folder: folder) {
                if let identity = item.identity, starred.contains(identity) { found.append(item) }
                if item.kind == .folder { try walk(item.relativePath) }
            }
        }
        try walk("")
        return found
    }

    // MARK: Trash

    package func trash(at relativePath: String) throws(LibraryError) -> TrashEntry {
        let (source, kind) = try existing(relativePath)
        let parentPath = relativePath.contains("/") ? String(relativePath[..<relativePath.lastIndex(of: "/")!]) : ""
        let containerName: String
        switch kind {
        case .notebook: containerName = notebookID(ofPackageAt: source)?.description ?? UUID().uuidString
        case .folder: containerName = (folderID(of: relativePath) ?? FolderID()).description
        }
        let container = trashRoot.appendingPathComponent(containerName, isDirectory: true)
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
            try Codecs.encode(origin).write(to: container.appendingPathComponent(Self.originSidecar))
            try fm.moveItem(at: source, to: container.appendingPathComponent(source.lastPathComponent, isDirectory: true))
        } catch let fault as FormatFault {
            throw .format(fault)
        } catch {
            throw .io("trash \(relativePath): \(error)")
        }
        return TrashEntry(id: containerName, name: Self.displayName(of: origin.originName), kind: kind, origin: origin, notebookID: kind == .notebook ? NotebookID(raw: UUID(uuidString: containerName)!) : nil)
    }

    package func listTrash() throws(LibraryError) -> [TrashEntry] {
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: trashRoot.path) } catch { throw .io("list trash: \(error)") }
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { containerName in
            let container = trashRoot.appendingPathComponent(containerName)
            guard let data = try? Data(contentsOf: container.appendingPathComponent(Self.originSidecar)),
                  let origin = try? Codecs.decode(TrashOrigin.self, from: data),
                  origin.formatVersion == TrashOrigin.currentFormatVersion,
                  let kind = kind(at: container.appendingPathComponent(origin.originName))
            else { return nil }
            let notebookID = kind == .notebook ? notebookID(ofPackageAt: container.appendingPathComponent(origin.originName)) : nil
            return TrashEntry(id: containerName, name: Self.displayName(of: origin.originName), kind: kind, origin: origin, notebookID: notebookID)
        }
    }

    /// Restores the original name. Suffixes only on a real collision; falls
    /// back to the root when the origin folder is gone.
    package func recover(_ entry: TrashEntry) throws(LibraryError) -> LibraryItem {
        let container = trashRoot.appendingPathComponent(entry.id)
        let source = container.appendingPathComponent(entry.origin.originName)
        guard let kind = kind(at: source) else { throw .itemNotFound(entry.id) }
        var folder = entry.origin.originPathHint
        if !folder.isEmpty, self.kind(at: url(of: folder)) != .folder { folder = "" }
        let parent = url(of: folder)
        var fileName = entry.origin.originName
        var attempt = 2
        while self.kind(at: parent.appendingPathComponent(fileName)) != nil {
            let display = Self.displayName(of: entry.origin.originName)
            fileName = kind == .notebook ? Self.packageName("\(display) \(attempt)") : "\(display) \(attempt)"
            attempt += 1
        }
        let target = parent.appendingPathComponent(fileName, isDirectory: true)
        do {
            try fm.moveItem(at: source, to: target)
            try fm.removeItem(at: container)
        } catch {
            throw .io("recover \(entry.id): \(error)")
        }
        let path = folder.isEmpty ? fileName : "\(folder)/\(fileName)"
        return item(at: path, url: target, kind: kind)
    }

    /// Every container under `Trash/`, including one whose `origin.json` no
    /// listing could read: emptying is about the bytes, not the entries.
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

    /// A copy with its own notebook identity, born in staging outside the
    /// scanned tree and moved into place atomically. Page identities are
    /// preserved, which keeps internal links internal.
    package func duplicateNotebook(at relativePath: String) async throws(LibraryError) -> LibraryItem {
        let (source, kind) = try existing(relativePath)
        guard kind == .notebook else { throw .notANotebook(relativePath) }
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staged = staging.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staged)
        } catch {
            throw .io("stage duplicate of \(relativePath): \(error)")
        }
        do {
            try await PackageStore(root: staged).rewriteNotebookID(NotebookID())
        } catch {
            try? fm.removeItem(at: staging)
            throw .format(error)
        }
        let display = Self.displayName(of: source.lastPathComponent)
        let parent = source.deletingLastPathComponent()
        var name = "\(display) copy"
        var attempt = 2
        while self.kind(at: parent.appendingPathComponent(Self.packageName(name))) != nil {
            name = "\(display) copy \(attempt)"
            attempt += 1
        }
        let target = parent.appendingPathComponent(Self.packageName(name), isDirectory: true)
        do {
            try fm.moveItem(at: staged, to: target)
            try fm.removeItem(at: staging)
        } catch {
            throw .io("land duplicate of \(relativePath): \(error)")
        }
        let parentPath = relativePath.contains("/") ? String(relativePath[..<relativePath.lastIndex(of: "/")!]) : ""
        let path = parentPath.isEmpty ? target.lastPathComponent : "\(parentPath)/\(target.lastPathComponent)"
        return item(at: path, url: target, kind: .notebook)
    }

    // MARK: Identity index

    /// Every notebook identity under the root and in the trash, by relative
    /// path. Off-main by being here. A colliding identity is re-minted for
    /// the second package found, in place.
    package func scanIdentities() async throws(LibraryError) -> IdentityIndex {
        var live: [NotebookID: String] = [:]
        var collisions: [String] = []
        func walk(_ folder: String) throws(LibraryError) {
            for item in try list(folder: folder) {
                switch item.kind {
                case .folder: try walk(item.relativePath)
                case .notebook:
                    guard let id = item.notebookID else { continue }
                    if live[id] != nil { collisions.append(item.relativePath) } else { live[id] = item.relativePath }
                }
            }
        }
        try walk("")
        for path in collisions {
            let newID = NotebookID()
            do { try await PackageStore(root: url(of: path)).rewriteNotebookID(newID) } catch { throw .format(error) }
            live[newID] = path
            TNLog.event(.library, "re-minted colliding notebook identity at \(path)")
        }
        var trashed: [NotebookID: String] = [:]
        for entry in try listTrash() {
            if let id = entry.notebookID { trashed[id] = entry.id }
        }
        return IdentityIndex(live: live, trashed: trashed)
    }
}

/// `notebookID` to relative path, plus the trashed ones by container. In
/// memory only; rebuilt by scanning.
package struct IdentityIndex: Sendable, Equatable {
    package var live: [NotebookID: String]
    package var trashed: [NotebookID: String]

    package init(live: [NotebookID: String] = [:], trashed: [NotebookID: String] = [:]) {
        self.live = live
        self.trashed = trashed
    }

    package enum Resolution: Sendable, Equatable {
        case live(path: String)
        case trashed(container: String)
        case missing
    }

    package func resolve(_ id: NotebookID) -> Resolution {
        if let path = live[id] { return .live(path: path) }
        if let container = trashed[id] { return .trashed(container: container) }
        return .missing
    }
}
