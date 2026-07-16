import Foundation

/// Coordinator-owned document identity shared by the app and spatial surface.
struct NotebookDocument: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var source: DocumentSource
    var pages: [PageRecord]
    var currentPageID: UUID?
}

enum DocumentSource: Codable, Equatable, Sendable {
    case bundledPDF(resourceName: String)
    case importedPDF(bookmarkData: Data)
    case notebook(defaultPaperStyle: PaperStyle)
}

struct PageRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var index: Int
    var background: PageBackground
    var inkReference: InkReference?
    var annotations: [PageAnnotation]
}

enum PageBackground: Codable, Equatable, Sendable {
    case pdf(documentID: UUID, pageIndex: Int)
    case blank(style: PaperStyle, dimensions: PageDimensions)
}

enum PaperStyle: String, Codable, Equatable, Sendable {
    case plain
    case ruled
    case grid
    case tuberDotGrid
}

struct PageDimensions: Codable, Equatable, Sendable {
    let width: Double
    let height: Double

    static let tuberPortrait = PageDimensions(width: 768, height: 1024)
}

struct InkReference: Codable, Equatable, Sendable {
    let relativePath: String
}
