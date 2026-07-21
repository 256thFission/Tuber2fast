import Combine
import Foundation

/// Local, file-backed store for notebooks. One JSON file per notebook in
/// `Documents/Notebooks/<uuid>.json`. Mirrors the on-disk conventions used by
/// `PenFixtureStore`, but lives in the product (non-DEBUG) surface.
@MainActor
final class NotebookStore: ObservableObject {
    static let shared = NotebookStore()

    @Published private(set) var notebooks: [Notebook] = []

    private let directoryName = "Notebooks"

    init() {
        reload()
    }

    private var directory: URL {
        let base = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        notebooks = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? Self.decoder.decode(Notebook.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func notebook(id: UUID) -> Notebook? {
        if let inMemory = notebooks.first(where: { $0.id == id }) { return inMemory }
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? Self.decoder.decode(Notebook.self, from: data)
    }

    @discardableResult
    func createNotebook(title: String, cover: NotebookCover, template: PageTemplate = .linedMedium) -> Notebook {
        let notebook = Notebook(title: title, cover: cover, pages: [NotebookPage(template: template)])
        save(notebook)
        return notebook
    }

    func save(_ notebook: Notebook) {
        var copy = notebook
        copy.updatedAt = Date()

        if let data = try? Self.encoder.encode(copy) {
            try? data.write(to: url(for: copy.id), options: .atomic)
        }

        if let idx = notebooks.firstIndex(where: { $0.id == copy.id }) {
            notebooks[idx] = copy
        } else {
            notebooks.insert(copy, at: 0)
        }
        notebooks.sort { $0.updatedAt > $1.updatedAt }
    }

    func rename(_ notebook: Notebook, to title: String) {
        var copy = notebook
        copy.title = title
        save(copy)
    }

    @discardableResult
    func importSPUD(from sourceURL: URL) throws -> Notebook {
        let isAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: sourceURL)
        let archived = try TuberNoteArchiveCodec.decode(data).notebook
        let imported = Notebook(
            id: UUID(),
            title: archived.title,
            cover: archived.cover,
            pages: archived.pages,
            agenticLayers: archived.agenticLayers,
            createdAt: archived.createdAt,
            updatedAt: Date(),
            settings: archived.settings
        )
        save(imported)
        return imported
    }

    func delete(_ notebook: Notebook) {
        try? FileManager.default.removeItem(at: url(for: notebook.id))
        notebooks.removeAll { $0.id == notebook.id }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
