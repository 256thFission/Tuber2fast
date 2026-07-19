import Foundation
import PDFKit

/// App-owned persistence for the single active document used by the critical path.
/// Page records hold only stable identities and relative ink paths; screen coordinates
/// never enter this store.
final class DocumentStore {
    private struct Manifest: Codable {
        var currentDocument: NotebookDocument
    }

    private let fileManager: FileManager
    private let rootURL: URL

    init(rootName: String = "documents") {
        fileManager = .default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootURL = documents.appendingPathComponent(rootName, isDirectory: true)
    }

    func loadDocument() -> NotebookDocument? {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return manifest.currentDocument
    }

#if DEBUG
    func resetForDeterministicVerification() {
        try? fileManager.removeItem(at: rootURL)
    }
#endif

    func saveDocument(_ document: NotebookDocument) throws {
        try ensureRoot()
        let data = try JSONEncoder().encode(Manifest(currentDocument: document))
        try data.write(to: manifestURL, options: .atomic)
    }

    func drawingData(for document: NotebookDocument) -> [UUID: Data] {
        Dictionary(uniqueKeysWithValues: document.pages.compactMap { page in
            guard let reference = page.inkReference,
                  let data = try? Data(contentsOf: rootURL.appendingPathComponent(reference.relativePath)) else {
                return nil
            }
            return (page.id, data)
        })
    }

    func saveDrawing(_ data: Data, pageID: UUID, in document: inout NotebookDocument) throws {
        guard let index = document.pages.firstIndex(where: { $0.id == pageID }) else { return }
        let relativePath = "ink/\(pageID.uuidString).drawing"
        let destination = rootURL.appendingPathComponent(relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        document.pages[index].inkReference = InkReference(relativePath: relativePath)
        try saveDocument(document)
    }

    func importPDF(from sourceURL: URL) throws -> (NotebookDocument, PDFDocument) {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let source = PDFDocument(url: sourceURL), source.pageCount > 0 else {
            throw StoreError.invalidPDF
        }

        let documentID = UUID()
        let relativePath = "pdf/\(documentID.uuidString).pdf"
        let destination = rootURL.appendingPathComponent(relativePath)
        try ensureRoot()
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        let bookmark = try destination.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: rootURL
        )
        let pageIDs = (0 ..< source.pageCount).map { _ in UUID() }
        let currentPageID = pageIDs.first
        let document = NotebookDocument(
            id: documentID,
            title: sourceURL.deletingPathExtension().lastPathComponent,
            source: .importedPDF(bookmarkData: bookmark),
            pages: pageIDs.enumerated().map { index, pageID in
                PageRecord(
                    id: pageID,
                    index: index,
                    background: .pdf(documentID: documentID, pageIndex: index),
                    inkReference: nil,
                    annotations: []
                )
            },
            currentPageID: currentPageID
        )
        try saveDocument(document)
        return (document, PDFDocument(url: destination) ?? source)
    }

    func pdfDocument(for document: NotebookDocument) -> PDFDocument? {
        guard case let .importedPDF(bookmarkData) = document.source else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: rootURL,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return PDFDocument(url: url)
    }

    private var manifestURL: URL {
        rootURL.appendingPathComponent("current-document.json")
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    enum StoreError: LocalizedError {
        case invalidPDF

        var errorDescription: String? {
            "That file could not be opened as a PDF."
        }
    }
}
