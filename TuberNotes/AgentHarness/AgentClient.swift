import Foundation

/// Boundary for the AI agent shipped inside TuberNotes. Development agents and MCPs do not conform to this.
protocol AgentClient {
    func investigate(_ selection: SpatialSelection) async throws -> [Pin]
}

struct SpatialSelection: Sendable {
    let pageID: UUID
    let normalizedBounds: CGRect
    let imageData: Data
}

