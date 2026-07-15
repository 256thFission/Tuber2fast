import Foundation

/// Future product-runtime retrieval boundary. No retrieval implementation belongs in M0.
protocol KnowledgeSearching {
    func searchTextbook(query: String) async throws -> [KnowledgeHit]
    func searchNotebook(query: String) async throws -> [KnowledgeHit]
}

struct KnowledgeHit: Sendable, Equatable {
    let title: String
    let excerpt: String
}

