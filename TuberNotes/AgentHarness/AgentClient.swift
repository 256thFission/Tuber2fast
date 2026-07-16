import Foundation

/// Boundary for the AI agent shipped inside TuberNotes. Development agents and MCPs do not conform to this.
protocol AgentClient: Sendable {
    func investigate(_ request: InvestigationRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(investigationID: UUID) async
}
