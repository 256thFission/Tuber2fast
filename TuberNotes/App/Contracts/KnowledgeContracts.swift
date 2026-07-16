import Foundation

struct KnowledgeQuery: Codable, Equatable, Sendable {
    let documentID: UUID?
    let text: String
    let limit: Int
}

struct KnowledgeHit: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let documentID: UUID
    let documentTitle: String
    let pageNumber: Int
    let sectionTitle: String?
    let excerpt: String
    let score: Double?
}
