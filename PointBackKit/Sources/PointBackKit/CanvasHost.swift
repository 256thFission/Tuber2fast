import CoreGraphics
import Foundation

public enum CanvasHostChange: Equatable, Sendable {
    case pages
    case currentPage(UUID?)
    case viewport(pageID: UUID)
    case content(pageID: UUID)
}

/// The page-aware seam between PointBackKit and an arbitrary canvas.
///
/// Projection points are expressed in the host window's top-left coordinate system. The package
/// converts them into its transient overlay coordinates and never persists them.
@MainActor
public protocol CanvasHost: AnyObject {
    var documentID: UUID { get }
    var pages: [PageDescriptor] { get }
    var currentPageID: UUID? { get }
    var changes: AsyncStream<CanvasHostChange> { get }

    func projectToWindow(_ point: PagePoint, on pageID: UUID) -> CGPoint?
    func unprojectFromWindow(_ point: CGPoint) -> (pageID: UUID, point: PagePoint)?
    func snapshot(_ rect: PageRect, on pageID: UUID) async -> SelectionCrop?
    func selectionContext(on pageID: UUID) -> SelectionContext
}

public extension CanvasHost {
    func pageDescriptor(id: UUID) -> PageDescriptor? {
        pages.first { $0.id == id }
    }
}

public enum PointBackEvent: Equatable, Sendable {
    case selectionCreated(SelectionArtifact)
    case selectionRejected
    case pinChanged(Pin)
    case conversationOpened(pinID: UUID)
    case stateChanged(PointBackSnapshot)
}

public struct PointBackSnapshot: Equatable, Sendable {
    public let status: String
    public let selection: SelectionArtifact?
    public let pins: [Pin]
    public let conversationPanelOpen: Bool
    public let conversationID: String?
    public let conversationTurnCount: Int?
    public let conversationReplyStatus: String?
    public let conversationSourcePinID: UUID?
    public let archive: PointBackArchive

    public init(
        status: String,
        selection: SelectionArtifact?,
        pins: [Pin],
        conversationPanelOpen: Bool,
        conversationID: String?,
        conversationTurnCount: Int?,
        conversationReplyStatus: String?,
        conversationSourcePinID: UUID?,
        archive: PointBackArchive
    ) {
        self.status = status
        self.selection = selection
        self.pins = pins
        self.conversationPanelOpen = conversationPanelOpen
        self.conversationID = conversationID
        self.conversationTurnCount = conversationTurnCount
        self.conversationReplyStatus = conversationReplyStatus
        self.conversationSourcePinID = conversationSourcePinID
        self.archive = archive
    }
}

public struct PointBackConfiguration: Equatable, Sendable {
    public var seededLassoPath: [PagePoint]?
    public var automaticIntent: InvestigationIntent?
    public var automaticFollowUpQuestion: String?
    public var restoredArchive: PointBackArchive?

    public init(
        seededLassoPath: [PagePoint]? = nil,
        automaticIntent: InvestigationIntent? = nil,
        automaticFollowUpQuestion: String? = nil,
        restoredArchive: PointBackArchive? = nil
    ) {
        self.seededLassoPath = seededLassoPath
        self.automaticIntent = automaticIntent
        self.automaticFollowUpQuestion = automaticFollowUpQuestion
        self.restoredArchive = restoredArchive
    }
}
