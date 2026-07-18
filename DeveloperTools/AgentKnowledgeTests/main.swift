import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

private func recordedRequest(id: UUID = UUID()) -> InvestigationRequest {
    let documentID = UUID(uuidString: "83000000-0000-0000-0000-000000000001")!
    let pageID = UUID(uuidString: "83000000-0000-0000-0000-000000000002")!
    let bounds = PageNormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
    return InvestigationRequest(
        id: id,
        intent: .check,
        selection: SelectionArtifact(
            id: UUID(uuidString: "83000000-0000-0000-0000-000000000003")!,
            documentID: documentID,
            pageID: pageID,
            pageIndex: 0,
            lassoPath: [
                PageNormalizedPoint(x: 0.1, y: 0.2),
                PageNormalizedPoint(x: 0.6, y: 0.2),
                PageNormalizedPoint(x: 0.6, y: 0.6),
                PageNormalizedPoint(x: 0.1, y: 0.2)
            ],
            pageBounds: bounds,
            crop: SelectionCrop(
                imageData: Data([0x01]),
                mediaType: "image/png",
                pixelWidth: 500,
                pixelHeight: 400,
                pageBounds: bounds
            ),
            context: SelectionContext(
                documentTitle: "Fixture",
                sourceDocumentID: documentID,
                pageNumber: 1,
                nearbyText: "3x - 7 = 11"
            )
        ),
        conversationID: nil
    )
}

private func collect(
    _ client: RecordedAgentClient,
    request: InvestigationRequest = recordedRequest()
) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in client.investigate(request) {
        events.append(event)
    }
    return events
}

private func testRecordedSuccess() async throws {
    let client = RecordedAgentClient(eventDelay: .milliseconds(1))
    let events = try await collect(client)
    try check(events.count == 8, "recorded success should emit eight ordered events")
    try check(events.first == .accepted, "recorded success should begin with accepted")
    try check(events.last == .completed(conversationID: "recorded-hero"), "recorded success should complete")
}

private func testRecordedCancellation() async throws {
    let client = RecordedAgentClient(eventDelay: .milliseconds(20))
    let request = recordedRequest()
    var events: [AgentEvent] = []

    for try await event in client.investigate(request) {
        events.append(event)
        if event == .accepted {
            await client.cancel(investigationID: request.id)
            await client.cancel(investigationID: request.id)
        }
    }

    try check(events.count == 2, "cancellation should stop all late recorded events")
    try check(events.first == .accepted, "cancellation fixture should first be accepted")
    guard case let .failed(failure) = events.last else {
        throw CheckFailure.failed("cancellation should finish with a failure event")
    }
    try check(failure.code == .cancelled, "cancellation should use the cancelled failure code")
}

private func testRecordedVariants() async throws {
    let retrieval = try await collect(
        RecordedAgentClient(scenario: .retrieval, eventDelay: .milliseconds(1))
    )
    try check(retrieval.contains { event in
        guard case let .toolStarted(tool) = event else { return false }
        return tool.tool == .searchTextbook
    }, "retrieval should expose a textbook tool phase")
    try check(retrieval.contains { event in
        guard case let .pinCompleted(pin) = event else { return false }
        return pin.citations.first?.pageNumber == 12
    }, "retrieval should complete a cited Pin")

    let expectedFailure = AgentFailure(
        code: .timedOut,
        userMessage: "Recorded timeout.",
        recoverable: true
    )
    let failure = try await collect(
        RecordedAgentClient(scenario: .failure(expectedFailure), eventDelay: .milliseconds(1))
    )
    try check(failure.last == .failed(expectedFailure), "failure fixture should preserve its typed failure")

    let invalid = try await collect(
        RecordedAgentClient(scenario: .invalidCoordinates, eventDelay: .milliseconds(1))
    )
    try check(!invalid.contains { event in
        if case .pinStarted = event { return true }
        if case .pinCompleted = event { return true }
        return false
    }, "invalid coordinates must never reach the Pin event boundary")
    guard case let .failed(invalidFailure) = invalid.last else {
        throw CheckFailure.failed("invalid coordinates should finish with a failure event")
    }
    try check(invalidFailure.code == .invalidResponse, "invalid coordinates should be rejected")
}

private func testOfflineKnowledgeSearch() async throws {
    let searcher = OfflineTextbookKnowledgeSearcher()
    let knownHits = try await searcher.searchTextbook(
        KnowledgeQuery(documentID: nil, text: "inverse operation both sides", limit: 5)
    )
    try check(knownHits.first?.documentTitle == "Algebra Essentials", "known query should find algebra")
    try check(knownHits.first?.pageNumber == 12, "known query should return the expected page")

    let filteredMiss = try await searcher.searchTextbook(
        KnowledgeQuery(
            documentID: OfflineTextbookKnowledgeSearcher.physicsDocumentID,
            text: "inverse operation",
            limit: 5
        )
    )
    try check(filteredMiss.isEmpty, "document filtering should exclude other textbooks")

    let limited = try await searcher.searchTextbook(
        KnowledgeQuery(documentID: nil, text: "term", limit: 1)
    )
    try check(limited.count == 1, "result limits should be honored")

    let empty = try await searcher.searchTextbook(
        KnowledgeQuery(documentID: nil, text: "  --  ", limit: 5)
    )
    try check(empty.isEmpty, "empty normalized queries should return no results")
}

private func testCorpusFailures() throws {
    do {
        _ = try OfflineTextbookKnowledgeSearcher(corpusData: nil)
        throw CheckFailure.failed("missing corpus should throw")
    } catch OfflineKnowledgeCorpusError.missingCorpus {
        // Expected.
    }

    do {
        _ = try OfflineTextbookKnowledgeSearcher(corpusData: Data("not-json".utf8))
        throw CheckFailure.failed("malformed corpus should throw")
    } catch OfflineKnowledgeCorpusError.malformedCorpus {
        // Expected.
    }

    do {
        _ = try OfflineTextbookKnowledgeSearcher(corpusData: Data("[]".utf8))
        throw CheckFailure.failed("empty corpus should be rejected")
    } catch OfflineKnowledgeCorpusError.invalidCorpus {
        // Expected.
    }
}

@main
private struct AgentKnowledgeChecks {
    static func main() async throws {
        try await testRecordedSuccess()
        try await testRecordedCancellation()
        try await testRecordedVariants()
        try await testOfflineKnowledgeSearch()
        try testCorpusFailures()
        print("AGENT_KNOWLEDGE_CHECKS: PASS")
    }
}
