import Foundation

struct PageAnnotation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let pageID: UUID
    let threadID: UUID
    var parentThreadID: UUID? = nil
    /// Literal user-authored question for this turn. Older annotations decode
    /// `nil`; their teaser remains Pin context and is never presented as a
    /// fabricated user message.
    var userPrompt: String? = nil
    /// Follow-up turns and message-level branches owned by this Pin. `nil`
    /// preserves decoding of notebooks written before Pin-owned conversations.
    /// The annotation itself is the implicit root message, identified by
    /// `threadID`.
    var conversationMessages: [PinConversationMessage]? = nil
    var target: PageNormalizedPoint
    var targetRegion: PageNormalizedRect?
    var kind: AnnotationKind
    var teaser: String
    var body: String
    var citations: [Citation]
    var status: AnnotationStatus
}

struct PinConversationMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    /// Either the owning Pin's `threadID` (the initial summary) or another
    /// message ID in the same Pin.
    var parentMessageID: UUID
    var userPrompt: String
    var body: String
}

enum AnnotationKind: String, Codable, Equatable, Sendable {
    case confirmation
    case issue
    case explanation
    case source
    case uncertainty
    case suggestion
}

enum AnnotationStatus: String, Codable, Equatable, Sendable {
    case streaming
    case complete
    case failed
}

struct Citation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var pageNumber: Int?
    var url: URL?
    var excerpt: String?
}

struct PinDraft: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var target: CropNormalizedPoint
    var targetRegion: CropNormalizedRect?
    var kind: AnnotationKind
    var teaser: String
    var body: String
    var citations: [Citation]
}
