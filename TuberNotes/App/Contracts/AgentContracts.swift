import Foundation

/// Provenance for an assistant response, copied only from a local textbook hit
/// that was actually returned to the provider. Product code cannot construct a
/// grounded citation from model-authored prose.
struct GroundedCitation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let documentID: UUID
    let documentTitle: String
    let pageNumber: Int
    let sectionTitle: String?
    let excerpt: String

    init(hit: KnowledgeHit) {
        id = hit.id
        documentID = hit.documentID
        documentTitle = hit.documentTitle
        pageNumber = hit.pageNumber
        sectionTitle = hit.sectionTitle
        excerpt = hit.excerpt
    }
}

struct InvestigationRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let intent: InvestigationIntent
    let selection: SelectionArtifact
    let conversationID: String?
}

/// App-owned navigation emitted by explicit user interaction. These requests
/// are not model tools and must never be decoded from an assistant response.
enum AgentNavigationRequest: Equatable, Hashable, Sendable {
    case openNotebook(notebookID: UUID, pageIndex: Int)
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
    case switchPage = "switch_page"
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
