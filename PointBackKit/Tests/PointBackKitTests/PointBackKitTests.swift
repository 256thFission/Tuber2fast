import CoreGraphics
import XCTest
@testable import PointBackKit

final class LassoGeometryTests: XCTestCase {
    func testClosedPathAndCropRoundTrip() throws {
        let captured = [
            PagePoint(x: 0.2, y: 0.2),
            PagePoint(x: 0.8, y: 0.2),
            PagePoint(x: 0.8, y: 0.7),
            PagePoint(x: 0.21, y: 0.21)
        ]
        let closed = try XCTUnwrap(LassoGeometry.closedPath(from: captured))
        let bounds = try XCTUnwrap(LassoGeometry.pageBounds(of: closed))
        XCTAssertEqual(closed.first, closed.last)
        XCTAssertLessThanOrEqual(LassoGeometry.roundTripMaximumError(path: closed, bounds: bounds), 1e-6)
    }

    func testRejectsOpenAndDegeneratePaths() {
        XCTAssertNil(LassoGeometry.closedPath(from: [
            PagePoint(x: 0.1, y: 0.1),
            PagePoint(x: 0.8, y: 0.1),
            PagePoint(x: 0.8, y: 0.8)
        ]))
        XCTAssertNil(LassoGeometry.closedPath(from: [
            PagePoint(x: 0.2, y: 0.2),
            PagePoint(x: 0.4, y: 0.4),
            PagePoint(x: 0.21, y: 0.21)
        ]))
    }
}

final class RecordedAgentClientTests: XCTestCase {
    func testRecordedHeroAndConversationShareConversationID() async throws {
        let client = RecordedAgentClient(eventDelay: .zero)
        let selection = TestValues.selection
        let first = InvestigationRequest(intent: .check, selection: selection)
        let firstEvents = try await collect(client.investigate(first))
        XCTAssertEqual(firstEvents.last, .completed(conversationID: "recorded-hero"))
        XCTAssertTrue(firstEvents.contains { if case .pinCompleted = $0 { true } else { false } })

        let followUp = InvestigationRequest(
            intent: .ask(question: "Why?"),
            selection: selection,
            conversationID: "recorded-hero"
        )
        let followUpEvents = try await collect(client.investigate(followUp))
        XCTAssertEqual(followUpEvents.last, .completed(conversationID: "recorded-hero"))
        XCTAssertTrue(followUpEvents.contains { event in
            guard case let .pinCompleted(pin) = event else { return false }
            return pin.teaser == "Why the sign changes"
        })
    }

    func testInvalidRecordedCoordinatesFailBeforePinDelivery() async throws {
        let client = RecordedAgentClient(scenario: .invalidCoordinates, eventDelay: .zero)
        let events = try await collect(client.investigate(.init(intent: .check, selection: TestValues.selection)))
        XCTAssertFalse(events.contains { if case .pinStarted = $0 { true } else { false } })
        XCTAssertTrue(events.contains { if case .failed = $0 { true } else { false } })
    }

    private func collect(
        _ stream: AsyncThrowingStream<AgentEvent, Error>
    ) async throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}

@MainActor
final class PointBackControllerTests: XCTestCase {
    func testSnapshotPathFeedsHeroAndConversation() async throws {
        let host = TestCanvasHost()
        let controller = PointBackController(
            host: host,
            agent: RecordedAgentClient(eventDelay: .zero)
        )
        await controller.receiveNormalizedPath(TestValues.path)
        XCTAssertEqual(host.snapshotRequests, 1)
        XCTAssertNotNil(controller.selection)

        controller.submit(.check)
        try await eventually { controller.pins.first?.status == .complete }
        let pin = try XCTUnwrap(controller.pins.first)
        controller.openConversation(for: pin.id)
        controller.submitFollowUp("Why?", threadID: pin.threadID)
        try await eventually { controller.snapshot.conversationReplyStatus == "Follow-up reply ready" }
        XCTAssertEqual(controller.snapshot.conversationID, "recorded-hero")
        XCTAssertEqual(controller.snapshot.conversationTurnCount, 3)
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { XCTFail("Condition timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class TestCanvasHost: CanvasHost {
    let documentID = TestValues.documentID
    let pages = [PageDescriptor(id: TestValues.pageID, index: 0)]
    var currentPageID: UUID? = TestValues.pageID
    let changes: AsyncStream<CanvasHostChange>
    private let continuation: AsyncStream<CanvasHostChange>.Continuation
    private(set) var snapshotRequests = 0

    init() {
        let stream = AsyncStream<CanvasHostChange>.makeStream()
        changes = stream.stream
        continuation = stream.continuation
    }

    func projectToWindow(_ point: PagePoint, on pageID: UUID) -> CGPoint? {
        guard pageID == currentPageID else { return nil }
        return CGPoint(x: point.x * 1_000, y: point.y * 1_000)
    }

    func unprojectFromWindow(_ point: CGPoint) -> (pageID: UUID, point: PagePoint)? {
        guard let currentPageID else { return nil }
        return (currentPageID, PagePoint(x: point.x / 1_000, y: point.y / 1_000))
    }

    func snapshot(_ rect: PageRect, on pageID: UUID) async -> SelectionCrop? {
        snapshotRequests += 1
        return SelectionCrop(
            imageData: Data([0x89, 0x50, 0x4e, 0x47]),
            mediaType: "image/png",
            pixelWidth: 400,
            pixelHeight: 300,
            pageBounds: rect
        )
    }

    func selectionContext(on pageID: UUID) -> SelectionContext {
        SelectionContext(
            documentTitle: "Test Canvas",
            sourceDocumentID: documentID,
            pageNumber: 1
        )
    }
}

private enum TestValues {
    static let documentID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    static let pageID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    static let path = [
        PagePoint(x: 0.2, y: 0.2),
        PagePoint(x: 0.8, y: 0.2),
        PagePoint(x: 0.8, y: 0.7),
        PagePoint(x: 0.21, y: 0.21)
    ]
    static let bounds = PageRect(x: 0.2, y: 0.2, width: 0.6, height: 0.5)
    static let selection = SelectionArtifact(
        documentID: documentID,
        pageID: pageID,
        pageIndex: 0,
        lassoPath: path,
        pageBounds: bounds,
        crop: SelectionCrop(
            imageData: Data([0x89, 0x50, 0x4e, 0x47]),
            mediaType: "image/png",
            pixelWidth: 400,
            pixelHeight: 300,
            pageBounds: bounds
        ),
        context: SelectionContext(documentTitle: "Test Canvas", sourceDocumentID: documentID, pageNumber: 1)
    )
}
