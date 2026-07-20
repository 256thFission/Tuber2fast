import Foundation

// MARK: - Spatial contracts

/// A top-left-origin point normalized over one complete logical page.
public struct PagePoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite && (0 ... 1).contains(x) && (0 ... 1).contains(y)
    }
}

/// A top-left-origin rectangle normalized over one complete logical page.
public struct PageRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1 && y + height <= 1
    }
}

/// A point normalized within the encoded selection crop.
public struct CropPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite && (0 ... 1).contains(x) && (0 ... 1).contains(y)
    }
}

public struct CropRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width >= 0 && height >= 0
            && x + width <= 1 && y + height <= 1
    }
}

public struct PageDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let index: Int

    public init(id: UUID, index: Int) {
        self.id = id
        self.index = index
    }
}

public struct SelectionContext: Codable, Equatable, Sendable {
    public var documentTitle: String?
    public var sourceDocumentID: UUID?
    public var pageNumber: Int?
    public var nearbyText: String?

    public init(
        documentTitle: String? = nil,
        sourceDocumentID: UUID? = nil,
        pageNumber: Int? = nil,
        nearbyText: String? = nil
    ) {
        self.documentTitle = documentTitle
        self.sourceDocumentID = sourceDocumentID
        self.pageNumber = pageNumber
        self.nearbyText = nearbyText
    }
}

public struct SelectionCrop: Equatable, Sendable {
    public let imageData: Data
    public let mediaType: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let pageBounds: PageRect

    public init(
        imageData: Data,
        mediaType: String,
        pixelWidth: Int,
        pixelHeight: Int,
        pageBounds: PageRect
    ) {
        self.imageData = imageData
        self.mediaType = mediaType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pageBounds = pageBounds
    }

    public var isValid: Bool {
        !imageData.isEmpty && !mediaType.isEmpty && pixelWidth > 1 && pixelHeight > 1
            && pageBounds.isValid
    }
}

public struct SelectionArtifact: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let documentID: UUID
    public let pageID: UUID
    public let pageIndex: Int
    public let lassoPath: [PagePoint]
    public let pageBounds: PageRect
    public let crop: SelectionCrop
    public let context: SelectionContext

    public init(
        id: UUID = UUID(),
        documentID: UUID,
        pageID: UUID,
        pageIndex: Int,
        lassoPath: [PagePoint],
        pageBounds: PageRect,
        crop: SelectionCrop,
        context: SelectionContext
    ) {
        self.id = id
        self.documentID = documentID
        self.pageID = pageID
        self.pageIndex = pageIndex
        self.lassoPath = lassoPath
        self.pageBounds = pageBounds
        self.crop = crop
        self.context = context
    }
}

// MARK: - Agent contracts

public enum InvestigationIntent: Codable, Equatable, Sendable {
    case explain
    case check
    case ask(question: String)
}

public struct InvestigationRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let intent: InvestigationIntent
    public let selection: SelectionArtifact
    public let conversationID: String?

    public init(
        id: UUID = UUID(),
        intent: InvestigationIntent,
        selection: SelectionArtifact,
        conversationID: String? = nil
    ) {
        self.id = id
        self.intent = intent
        self.selection = selection
        self.conversationID = conversationID
    }
}

public enum ProductToolName: String, Codable, Equatable, Sendable {
    case searchTextbook = "search_textbook"
    case searchNotebook = "search_notebook"
    case placePins = "place_pins"
}

public struct ToolInvocationSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let tool: ProductToolName
    public let userVisibleStatus: String

    public init(id: UUID = UUID(), tool: ProductToolName, userVisibleStatus: String) {
        self.id = id
        self.tool = tool
        self.userVisibleStatus = userVisibleStatus
    }
}

public struct AgentFailure: Error, Codable, Equatable, Sendable {
    public enum Code: String, Codable, Equatable, Sendable {
        case unavailable, unauthorized, timedOut, invalidResponse, cancelled
    }

    public let code: Code
    public let userMessage: String
    public let recoverable: Bool

    public init(code: Code, userMessage: String, recoverable: Bool) {
        self.code = code
        self.userMessage = userMessage
        self.recoverable = recoverable
    }
}

public enum AnnotationKind: String, Codable, Equatable, Sendable {
    case confirmation, issue, explanation, source, uncertainty, suggestion
}

public enum AnnotationStatus: String, Codable, Equatable, Sendable {
    case streaming, complete, failed
}

public struct Citation: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var pageNumber: Int?
    public var url: URL?
    public var excerpt: String?

    public init(
        id: UUID = UUID(),
        title: String,
        pageNumber: Int? = nil,
        url: URL? = nil,
        excerpt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.pageNumber = pageNumber
        self.url = url
        self.excerpt = excerpt
    }
}

public struct PinDraft: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var target: CropPoint
    public var targetRegion: CropRect?
    public var kind: AnnotationKind
    public var teaser: String
    public var body: String
    public var citations: [Citation]

    public init(
        id: UUID = UUID(),
        target: CropPoint,
        targetRegion: CropRect? = nil,
        kind: AnnotationKind,
        teaser: String,
        body: String,
        citations: [Citation] = []
    ) {
        self.id = id
        self.target = target
        self.targetRegion = targetRegion
        self.kind = kind
        self.teaser = teaser
        self.body = body
        self.citations = citations
    }
}

public struct Pin: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let pageID: UUID
    public let threadID: UUID
    public var target: PagePoint
    public var targetRegion: PageRect?
    public var kind: AnnotationKind
    public var teaser: String
    public var body: String
    public var citations: [Citation]
    public var status: AnnotationStatus

    public init(
        id: UUID,
        pageID: UUID,
        threadID: UUID,
        target: PagePoint,
        targetRegion: PageRect? = nil,
        kind: AnnotationKind,
        teaser: String,
        body: String,
        citations: [Citation] = [],
        status: AnnotationStatus
    ) {
        self.id = id
        self.pageID = pageID
        self.threadID = threadID
        self.target = target
        self.targetRegion = targetRegion
        self.kind = kind
        self.teaser = teaser
        self.body = body
        self.citations = citations
        self.status = status
    }
}

public enum AgentEvent: Equatable, Sendable {
    case accepted
    case inspectingSelection
    case toolStarted(ToolInvocationSummary)
    case toolFinished(ToolInvocationSummary)
    case pinStarted(PinDraft)
    case pinDelta(id: UUID, bodyDelta: String)
    case pinCompleted(PinDraft)
    /// A transcript-only response. Unlike Pin events, these never mutate canvas annotations.
    case messageStarted(id: UUID)
    case messageDelta(id: UUID, textDelta: String)
    case messageCompleted(id: UUID, text: String)
    case completed(conversationID: String?)
    case failed(AgentFailure)
}

public protocol AgentClient: Sendable {
    func investigate(_ request: InvestigationRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(investigationID: UUID) async
}

// MARK: - Persistable conversation

public struct ConversationTurn: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Equatable, Sendable { case user, assistant }

    public let id: UUID
    public let role: Role
    public var text: String
    public var isStreaming: Bool

    public init(id: UUID = UUID(), role: Role, text: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

public struct PinConversation: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sourcePinID: UUID
    public let selection: SelectionArtifactRecord
    public var conversationID: String
    public var turns: [ConversationTurn]

    public init(
        id: UUID,
        sourcePinID: UUID,
        selection: SelectionArtifactRecord,
        conversationID: String,
        turns: [ConversationTurn]
    ) {
        self.id = id
        self.sourcePinID = sourcePinID
        self.selection = selection
        self.conversationID = conversationID
        self.turns = turns
    }
}

/// Host-persistable PointBack state. The host decides storage lifetime and namespace.
public struct PointBackArchive: Codable, Equatable, Sendable {
    public var pins: [Pin]
    public var conversations: [PinConversation]

    public init(pins: [Pin] = [], conversations: [PinConversation] = []) {
        self.pins = pins
        self.conversations = conversations
    }
}

/// Codable host-persistence form. Image bytes stay host-owned and are restored separately.
public struct SelectionArtifactRecord: Codable, Equatable, Sendable {
    public let documentID: UUID
    public let pageID: UUID
    public let pageIndex: Int
    public let lassoPath: [PagePoint]
    public let pageBounds: PageRect
    public let context: SelectionContext

    public init(_ artifact: SelectionArtifact) {
        documentID = artifact.documentID
        pageID = artifact.pageID
        pageIndex = artifact.pageIndex
        lassoPath = artifact.lassoPath
        pageBounds = artifact.pageBounds
        context = artifact.context
    }
}
