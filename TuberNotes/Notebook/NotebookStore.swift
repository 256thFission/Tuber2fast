import Combine
import Foundation
import PDFKit
import UIKit

enum PDFNotebookImportError: LocalizedError {
    case empty
    case unreadable

    var errorDescription: String? {
        switch self {
        case .empty:
            "The selected PDF does not contain any pages."
        case .unreadable:
            "The selected PDF could not be read."
        }
    }
}

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

    private func knowledgeCorpusURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).knowledge.json")
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        notebooks = urls
            .filter {
                $0.pathExtension == "json"
                    && !$0.lastPathComponent.hasSuffix(".knowledge.json")
            }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? Self.decoder.decode(Notebook.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func notebook(id: UUID) -> Notebook? {
        if let inMemory = notebooks.first(where: { $0.id == id }) { return inMemory }
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? Self.decoder.decode(Notebook.self, from: data)
    }

    /// Returns the persisted corpus for one explicitly selected imported textbook.
    /// `nil` means that notebook has no imported corpus sidecar; malformed data is returned
    /// so the Knowledge resolver can reject it rather than silently using a fixture.
    func knowledgeCorpusData(forImportedTextbook id: UUID) throws -> Data? {
        let corpusURL = knowledgeCorpusURL(for: id)
        guard FileManager.default.fileExists(atPath: corpusURL.path) else { return nil }
        return try Data(contentsOf: corpusURL)
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

    @discardableResult
    func importPDF(from sourceURL: URL) throws -> Notebook {
        let isAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let document = PDFDocument(url: sourceURL), !document.isLocked else {
            throw PDFNotebookImportError.unreadable
        }
        guard document.pageCount > 0 else {
            throw PDFNotebookImportError.empty
        }

        let sourceTitle = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let notebookID = UUID()
        let notebookTitle = sourceTitle.isEmpty ? "Imported PDF" : sourceTitle
        let pixelSize = CGSize(
            width: NotebookPageLayout.size.width * 2,
            height: NotebookPageLayout.size.height * 2
        )
        var pageTexts: [String?] = []
        let pages = try (0 ..< document.pageCount).map { pageIndex in
            guard let pdfPage = document.page(at: pageIndex),
                  let imageData = Self.rasterizedPageData(pdfPage, pixelSize: pixelSize) else {
                throw PDFNotebookImportError.unreadable
            }
            pageTexts.append(pdfPage.string)
            return NotebookPage(
                template: .plain,
                images: [PlacedImage(
                    imageData: imageData,
                    rect: CGRect(x: 0, y: 0, width: 1, height: 1)
                )]
            )
        }

        let notebook = Notebook(
            id: notebookID,
            title: notebookTitle,
            cover: .slate,
            pages: pages,
            settings: NotebookSettings(showsPageLock: true)
        )
        let corpus = OfflineKnowledgeCorpus.pages(
            documentID: notebookID,
            documentTitle: notebookTitle,
            pageTexts: pageTexts
        )
        let corpusData = try JSONEncoder().encode(corpus)
        try corpusData.write(to: knowledgeCorpusURL(for: notebookID), options: .atomic)
        save(notebook)
        return notebook
    }

    private static func rasterizedPageData(_ page: PDFPage, pixelSize: CGSize) -> Data? {
        let thumbnail = page.thumbnail(of: pixelSize, for: .mediaBox)
        guard thumbnail.size.width > 0, thumbnail.size.height > 0 else { return nil }

        let scale = min(
            pixelSize.width / thumbnail.size.width,
            pixelSize.height / thumbnail.size.height
        )
        let fittedSize = CGSize(
            width: thumbnail.size.width * scale,
            height: thumbnail.size.height * scale
        )
        let fittedRect = CGRect(
            x: (pixelSize.width - fittedSize.width) / 2,
            y: (pixelSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
            thumbnail.draw(in: fittedRect)
        }.pngData()
    }

    func delete(_ notebook: Notebook) {
        try? FileManager.default.removeItem(at: url(for: notebook.id))
        try? FileManager.default.removeItem(at: knowledgeCorpusURL(for: notebook.id))
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
