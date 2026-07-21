import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        guard case let .failed(message) = self else { return "failed" }
        return message
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

private actor ScriptedSearcher: KnowledgeSearching {
    private let scripted: [[KnowledgeHit]]
    private var index = 0

    init(_ scripted: [[KnowledgeHit]]) { self.scripted = scripted }

    func searchTextbook(_ query: KnowledgeQuery) async throws -> [KnowledgeHit] {
        guard index < scripted.count else { throw CheckFailure.failed("unexpected local search") }
        let result = scripted[index]
        index += 1
        return result
    }

    func callCount() -> Int { index }
}

private final class InvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ToolInvocationSummary?] = []

    func append(_ value: ToolInvocationSummary?) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var nonNilCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.compactMap { $0 }.count
    }
}

private func payload(output: [[String: Any]], text: String? = nil) throws -> Data {
    var object: [String: Any] = ["id": UUID().uuidString, "output": output]
    if let text { object["output_text"] = text }
    return try JSONSerialization.data(withJSONObject: object)
}

private func searchCall(_ callID: String, arguments: String) -> [String: Any] {
    [
        "type": "function_call",
        "name": "search_textbook",
        "call_id": callID,
        "arguments": arguments
    ]
}

private let initialBody: [String: Any] = [
    "model": "scripted",
    "stream": true,
    "store": false,
    "input": [["role": "user", "content": []]]
]

private let hit = KnowledgeHit(
    id: UUID(uuidString: "86000000-0000-0000-0000-000000000001")!,
    documentID: UUID(uuidString: "86000000-0000-0000-0000-000000000002")!,
    documentTitle: "Imported Algebra",
    pageNumber: 12,
    sectionTitle: "Inverse Operations",
    excerpt: "Apply the inverse operation to both sides.",
    score: 1.5
)

private func testTypedSearchToFinalAnswer() async throws {
    let searcher = ScriptedSearcher([[hit]])
    let recorder = InvocationRecorder()
    let responses = [
        try payload(output: [searchCall("call-1", arguments: #"{"query":"inverse operation","limit":3}"#)]),
        try payload(output: [], text: "Use the inverse operation on both sides.")
    ]
    var requests: [[String: Any]] = []
    let result = try await OpenAICodexVisionClient.runNotebookResponseLoop(
        initialBody: initialBody,
        model: "scripted",
        toolMode: .searchOnly,
        knowledgeSearcher: searcher,
        onToolInvocation: { recorder.append($0) }
    ) { body in
        requests.append(body)
        return responses[requests.count - 1]
    }

    try check(result.body == "Use the inverse operation on both sides.", "final answer should be returned")
    try check(result.knowledgeHits == [hit], "only the local typed hit should be retained")
    try check(result.toolInvocations.count == 1, "one actual search should produce one summary")
    try check(recorder.nonNilCount == 1, "one actual search should report one live invocation")
    try check(requests.count == 2, "one search should require exactly two provider responses")
    try check(requests[1]["previous_response_id"] == nil, "store:false continuation must be stateless")
    let input = try (requests[1]["input"] as? [[String: Any]]).unwrap("missing follow-up input")
    let resultItem = try input.last.unwrap("missing function result")
    try check(resultItem["type"] as? String == "function_call_output", "follow-up should append a function result")
    try check(resultItem["call_id"] as? String == "call-1", "function result should preserve call_id linkage")
    let output = try (resultItem["output"] as? String).unwrap("missing typed output")
    let decoded = try JSONDecoder().decode([KnowledgeHit].self, from: Data(output.utf8))
    try check(decoded == [hit], "provider output must serialize the exact local KnowledgeHit")
    let followUpTools = try (requests[1]["tools"] as? [[String: Any]]).unwrap("missing follow-up tools")
    try check(
        followUpTools.compactMap { $0["name"] as? String } == ["search_textbook"],
        "teaching follow-up must remain search-only"
    )
}

private func testZeroHitsTerminates() async throws {
    let searcher = ScriptedSearcher([[]])
    let responses = [
        try payload(output: [searchCall("empty", arguments: #"{"query":"not in corpus","limit":2}"#)]),
        try payload(output: [searchCall("retry", arguments: #"{"query":"invent page 99","limit":2}"#)])
    ]
    var responseIndex = 0
    let result = try await OpenAICodexVisionClient.runNotebookResponseLoop(
        initialBody: initialBody,
        model: "scripted",
        toolMode: .all,
        knowledgeSearcher: searcher,
        onToolInvocation: { _ in }
    ) { _ in
        defer { responseIndex += 1 }
        return responses[responseIndex]
    }
    let zeroHitSearchCount = await searcher.callCount()
    try check(zeroHitSearchCount == 1, "zero hits must not execute a nested retry")
    try check(responseIndex == 2, "zero hits should stop after the linked provider follow-up")
    try check(result.knowledgeHits.isEmpty, "zero-hit result must retain no source")
    try check(result.body.contains("couldn't find relevant evidence"), "zero hits should return a safe no-source answer")
}

private func testMalformedAndBounds() async throws {
    let malformedSearcher = ScriptedSearcher([[hit]])
    do {
        _ = try await OpenAICodexVisionClient.runNotebookResponseLoop(
            initialBody: initialBody,
            model: "scripted",
            toolMode: .all,
            knowledgeSearcher: malformedSearcher,
            onToolInvocation: { _ in }
        ) { _ in
            try payload(output: [searchCall("bad", arguments: #"{"query":"algebra","limit":3,"page_number":12}"#)])
        }
        throw CheckFailure.failed("model-supplied page target should be rejected")
    } catch is AgentError {}
    let malformedSearchCount = await malformedSearcher.callCount()
    try check(malformedSearchCount == 0, "malformed arguments must not reach Knowledge")

    let parallelSearcher = ScriptedSearcher([[hit]])
    do {
        _ = try await OpenAICodexVisionClient.runNotebookResponseLoop(
            initialBody: initialBody,
            model: "scripted",
            toolMode: .all,
            knowledgeSearcher: parallelSearcher,
            onToolInvocation: { _ in }
        ) { _ in
            try payload(output: [
                searchCall("parallel-1", arguments: #"{"query":"algebra","limit":1}"#),
                searchCall("parallel-2", arguments: #"{"query":"inverse","limit":1}"#)
            ])
        }
        throw CheckFailure.failed("parallel search calls should be rejected")
    } catch is AgentError {}
    let parallelSearchCount = await parallelSearcher.callCount()
    try check(parallelSearchCount == 0, "parallel calls must not reach Knowledge")

    let boundedSearcher = ScriptedSearcher([[hit], [hit], [hit]])
    var responseCount = 0
    do {
        _ = try await OpenAICodexVisionClient.runNotebookResponseLoop(
            initialBody: initialBody,
            model: "scripted",
            toolMode: .all,
            knowledgeSearcher: boundedSearcher,
            onToolInvocation: { _ in }
        ) { _ in
            responseCount += 1
            return try payload(output: [searchCall("call-\(responseCount)", arguments: #"{"query":"algebra","limit":1}"#)])
        }
        throw CheckFailure.failed("third search call should exceed the bound")
    } catch is AgentError {}
    try check(responseCount == 3, "provider response count must be bounded at three")
    let boundedSearchCount = await boundedSearcher.callCount()
    try check(boundedSearchCount == 2, "local search executions must be bounded at two")
}

private func testNoInvocationWithoutSearch() async throws {
    let searcher = ScriptedSearcher([])
    let recorder = InvocationRecorder()
    let result = try await OpenAICodexVisionClient.runNotebookResponseLoop(
        initialBody: initialBody,
        model: "scripted",
        toolMode: .all,
        knowledgeSearcher: searcher,
        onToolInvocation: { recorder.append($0) }
    ) { _ in try payload(output: [], text: "Answer from the visible worksheet.") }
    try check(result.knowledgeHits.isEmpty, "plain answer should have no textbook hits")
    try check(recorder.nonNilCount == 0, "plain answer must not fabricate a search invocation")
}

private func testTeachingToolSurface() throws {
    let searchOnly = OpenAICodexVisionClient.notebookTools(for: .searchOnly)
    let names = searchOnly.compactMap { $0["name"] as? String }
    try check(names == ["search_textbook"], "teaching mode should advertise only textbook search")
    try check(!names.contains("place_pins"), "teaching mode must not expose place_pins")
    try check(!names.contains("switch_page"), "teaching mode must not expose switch_page")
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw CheckFailure.failed(message) }
        return self
    }
}

@main
private enum PC26LiveSearchChecks {
    static func main() async {
        do {
            try await testTypedSearchToFinalAnswer()
            try await testZeroHitsTerminates()
            try await testMalformedAndBounds()
            try await testNoInvocationWithoutSearch()
            try testTeachingToolSurface()
            print("PASS PC-26 scripted live textbook search checks")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
