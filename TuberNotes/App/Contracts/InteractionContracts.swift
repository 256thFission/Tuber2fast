import Foundation

enum CanvasToolMode: Equatable, Sendable {
    case ink
    case erase
    case magicLasso
    case navigate
}

enum LassoState: Equatable, Sendable {
    case idle
    case drawing
    case selected(selectionID: UUID)
    case submitting(investigationID: UUID)
    case receiving(investigationID: UUID)
    case completed(investigationID: UUID)
    case failed(investigationID: UUID, recoverable: Bool)
}

enum InvestigationIntent: Codable, Equatable, Sendable {
    case explain
    case check
    case ask(question: String)
}
