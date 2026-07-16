/// Future product-runtime retrieval boundary. No retrieval implementation belongs in M0.
protocol KnowledgeSearching: Sendable {
    func searchTextbook(_ query: KnowledgeQuery) async throws -> [KnowledgeHit]
}
