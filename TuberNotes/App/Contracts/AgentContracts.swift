import Foundation

struct InvestigationRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let intent: InvestigationIntent
    let selection: SelectionArtifact
    let conversationID: String?
}

enum AgentEvent: Equatable, Sendable {
    case accepted
    case inspectingSelection
    case toolStarted(ToolInvocationSummary)
    case toolFinished(ToolInvocationSummary)
    case pinStarted(PinDraft)
    case pinDelta(id: UUID, bodyDelta: String)
    case pinCompleted(PinDraft)
    case completed(conversationID: String?)
    case failed(AgentFailure)
}

enum ProductToolName: String, Codable, Equatable, Sendable {
    case searchTextbook = "search_textbook"
    case placePins = "place_pins"
}

struct ToolInvocationSummary: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let tool: ProductToolName
    let userVisibleStatus: String
}

struct AgentFailure: Error, Codable, Equatable, Sendable {
    enum Code: String, Codable, Equatable, Sendable {
        case unavailable
        case unauthorized
        case timedOut
        case invalidResponse
        case cancelled
    }

    let code: Code
    let userMessage: String
    let recoverable: Bool
}
