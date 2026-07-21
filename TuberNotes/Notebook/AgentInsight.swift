import Foundation
import UIKit

/// Result of asking the agent to look at a page selection.
struct AgentInsight: Equatable {
    /// The complete bounded assistant response exactly as returned by the text
    /// extractor. Markdown remains source text here; interpretation belongs to
    /// the presentation layer.
    let body: String
    let toolCalls: [AgentToolCall]

    init(body: String, toolCalls: [AgentToolCall] = []) {
        self.body = body
        self.toolCalls = toolCalls
    }

    /// Compatibility initializer for deterministic/demo responses that are
    /// authored as a summary plus bullets. New provider responses use `body`.
    init(summary: String, items: [String]) {
        body = ([summary] + items.map { "- \($0)" }).joined(separator: "\n")
        toolCalls = []
    }

    /// Transitional projections for callers that have not yet adopted `body`.
    /// They never mutate or replace the canonical response source.
    var summary: String {
        body.split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? body
    }

    var items: [String] {
        body.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") || trimmed.hasPrefix("* ") else {
                return nil
            }
            return String(trimmed.dropFirst(2))
        }
    }
}

/// Bounded, immutable full-page context supplied with a notebook chat turn.
struct AgentPageImage: Equatable, Sendable {
    let pageID: UUID
    let pageNumber: Int
    let imageData: Data
    let mediaType: String
}

enum AgentToolCall: Equatable, Sendable {
    case placePins(pageNumber: Int, pins: [PinDraft])
    case switchPage(pageNumber: Int)
}

/// Boundary for "look at what I circled and tell me what you see". Complements the
/// existing `AgentClient`/`SelectionArtifact` boundary (which returns Pin events);
/// this one returns human-readable text that is persisted as an Agentic Layer Pin.
protocol AgentInsightClient: Sendable {
    func analyze(
        _ selection: SelectionArtifact,
        question: String?,
        pageImages: [AgentPageImage]
    ) async throws -> AgentInsight
    var generation: UUID? { get }
}

enum AgentError: LocalizedError {
    case server(statusCode: Int)
    case parse
    case unavailable
    case signInRequired
    case openAISignInRequired(generation: UUID)

    var errorDescription: String? {
        switch self {
        case .server(let statusCode) where statusCode == 401 || statusCode == 403:
            "The provider rejected this access. Check agent provider settings and try again."
        case .server(let statusCode) where statusCode == 429:
            "The provider is busy or this access has reached its limit. Wait, then try again."
        case .server(let statusCode):
            "The provider request failed (HTTP \(statusCode)). Try again."
        case .parse:         "Couldn't read the assistant's response."
        case .unavailable:   "The agent service is unavailable."
        case .signInRequired:
            "Sign in with OpenAI to analyze this page."
        case .openAISignInRequired:
            "OpenAI sign-in expired or was rejected. Sign in again and retry."
        }
    }
}

/// Runs with no provider access so the app is fully functional out of the box.
struct MockAgentInsightClient: AgentInsightClient {
    let generation: UUID? = nil

    func analyze(_ selection: SelectionArtifact, question: String?, pageImages: [AgentPageImage]) async throws -> AgentInsight {
        try? await Task.sleep(nanoseconds: 700_000_000)
        return AgentInsight(
            summary: "Demo mode. Configure an agent provider in the assistant settings to get real descriptions. I can see you've drawn on the page and marked a region.",
            items: [
                "Handwritten strokes detected",
                "One circled / marked area",
                "Add provider access to enable real analysis"
            ]
        )
    }
}

struct SignedOutAgentInsightClient: AgentInsightClient {
    let generation: UUID? = nil

    func analyze(_ selection: SelectionArtifact, question: String?, pageImages: [AgentPageImage]) async throws -> AgentInsight {
        throw AgentError.signInRequired
    }
}

private func defaultInsightPrompt(_ question: String?) -> String {
    let task = question ?? "Help the student learn from the selected notebook work."
    return """
    \(task)

    Give a direct, useful teaching response grounded in the visible selection. Infer the \
    likely learning need when the work makes it reasonably clear. Explain the relevant \
    reasoning, why it matters, and a concrete next step or self-check. Do not merely \
    describe or transcribe what is visible. Do not say "incomplete question", ask the \
    student to provide context, or label the response "Follow-up" or "Follow-up branch". \
    If the evidence is genuinely unreadable or too ambiguous to answer safely, return one \
    brief neutral sentence without inventing facts. Use readable Markdown and stay concise.
    """
}

private func parseInsight(_ text: String) -> AgentInsight {
    AgentInsight(body: text)
}

#if DEBUG
private func performInsightRequest(
    body: [String: Any],
    access: AgentProviderAccess,
    session: URLSession
) async throws -> AgentInsight {
    let route = access.provider.route(for: .insight)
    var request = URLRequest(url: route.endpoint)
    request.httpMethod = "POST"
    access.prepare(&request)
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw AgentError.unavailable }
    guard (200..<300).contains(http.statusCode) else {
        throw AgentError.server(statusCode: http.statusCode)
    }
    guard let content = try ResponsesTextExtractor.text(from: data) else {
        throw AgentError.parse
    }
    return parseInsight(content)
}

/// OpenAI's vision-capable Chat Completions route, authorized by shared provider access.
struct OpenAIVisionClient: AgentInsightClient {
    let access: AgentProviderAccess
    private let session: URLSession
    let generation: UUID? = nil

    init(
        access: AgentProviderAccess,
        session: URLSession = AgentProviderNetworking.ephemeralSession()
    ) {
        self.access = access
        self.session = session
    }

    func analyze(_ selection: SelectionArtifact, question: String?, pageImages: [AgentPageImage]) async throws -> AgentInsight {
        let crop = selection.crop
        let dataURL = "data:\(crop.mediaType);base64,\(crop.imageData.base64EncodedString())"

        let body: [String: Any] = [
            "model": access.model,
            "max_tokens": 500,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": defaultInsightPrompt(question)],
                    ["type": "image_url", "image_url": ["url": dataURL]]
                ]
            ]]
        ]
        return try await performInsightRequest(body: body, access: access, session: session)
    }
}

/// External gateway route from the named workspace. It uses the Responses wire API and
/// the shared bounded SSE/text parser instead of the branch's unbounded line splitting.
struct RightCodeResponsesClient: AgentInsightClient {
    let access: AgentProviderAccess
    private let session: URLSession
    let generation: UUID? = nil

    init(
        access: AgentProviderAccess,
        session: URLSession = AgentProviderNetworking.ephemeralSession()
    ) {
        self.access = access
        self.session = session
    }

    func analyze(_ selection: SelectionArtifact, question: String?, pageImages: [AgentPageImage]) async throws -> AgentInsight {
        let crop = selection.crop
        let dataURL = "data:\(crop.mediaType);base64,\(crop.imageData.base64EncodedString())"
        let body: [String: Any] = [
            "model": access.model,
            "stream": true,
            "store": false,
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": defaultInsightPrompt(question)],
                    ["type": "input_image", "image_url": dataURL]
                ]
            ]]
        ]

        return try await performInsightRequest(body: body, access: access, session: session)
    }
}
#endif

/// Normal-app vision request authorized by a short-lived, memory-only ChatGPT login.
/// This remains separate from the API-key provider route so failures cannot fall back
/// to another credential or to demo output.
struct OpenAICodexVisionClient: AgentInsightClient {
    private static let maximumResponseBytes = 4 * 1_024 * 1_024

    let route: AgentResponseRoute
    let transport: OpenAICodexResponsesTransport
    var generation: UUID? { route.generation }

    init(
        route: AgentResponseRoute,
        transport: OpenAICodexResponsesTransport = OpenAICodexResponsesTransport()
    ) {
        self.route = route
        self.transport = transport
    }

    func analyze(
        _ selection: SelectionArtifact,
        question: String?,
        pageImages: [AgentPageImage]
    ) async throws -> AgentInsight {
        try await perform(
            selection,
            prompt: defaultInsightPrompt(question),
            pageImages: pageImages,
            allowsNotebookTools: true
        )
    }

    /// The intervention path supplies its complete teaching policy so it is
    /// not diluted by the general conversation prompt.
    func analyzeTeaching(
        _ selection: SelectionArtifact,
        instruction: String
    ) async throws -> AgentInsight {
        try await perform(selection, prompt: instruction, pageImages: [], allowsNotebookTools: false)
    }

    private func perform(
        _ selection: SelectionArtifact,
        prompt: String,
        pageImages: [AgentPageImage],
        allowsNotebookTools: Bool
    ) async throws -> AgentInsight {
        let crop = selection.crop
        let dataURL = "data:\(crop.mediaType);base64,\(crop.imageData.base64EncodedString())"
        var content: [[String: Any]] = [
            ["type": "input_text", "text": prompt + Self.toolPolicy],
            ["type": "input_image", "image_url": dataURL, "detail": "original"]
        ]
        for image in pageImages.prefix(3) where !image.imageData.isEmpty {
            content.append([
                "type": "input_text",
                "text": "Full notebook page \(image.pageNumber)."
            ])
            content.append([
                "type": "input_image",
                "image_url": "data:\(image.mediaType);base64,\(image.imageData.base64EncodedString())",
                "detail": "original"
            ])
        }
        var body: [String: Any] = [
            "model": route.model,
            "stream": true,
            "store": false,
            "input": [[
                "role": "user",
                "content": content
            ]]
        ]
        if allowsNotebookTools {
            body["tools"] = Self.notebookTools
            body["tool_choice"] = "auto"
        }

        do {
            let requestBody = try JSONSerialization.data(withJSONObject: body)
            let data = try await transport.send(
                body: requestBody,
                route: route,
                capability: .insight,
                maximumRequestBytes: 20 * 1_024 * 1_024,
                maximumResponseBytes: Self.maximumResponseBytes
            )
            let text = try ResponsesTextExtractor.text(from: data) ?? ""
            let calls = allowsNotebookTools ? try Self.toolCalls(from: data) : []
            guard !text.isEmpty || !calls.isEmpty else {
                throw AgentError.parse
            }
            return AgentInsight(body: text, toolCalls: calls)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenAICodexTransportError {
            switch error {
            case .unauthorized(let generation):
                throw AgentError.openAISignInRequired(generation: generation)
            case .invalidResponse:
                throw AgentError.parse
            case .unsupported, .unavailable:
                throw AgentError.unavailable
            }
        } catch let error as AgentError {
            throw error
        } catch {
            // Never surface provider bodies, request metadata, or bearer-token-bearing errors.
            throw AgentError.unavailable
        }
    }

    private static let toolPolicy = """

    You may use place_pins to attach concise guidance to a visible location on any supplied page. You may use switch_page only when the student explicitly asks to navigate; never switch pages merely because another page is relevant. Coordinates are normalized across the full target page. Otherwise answer in text.
    """

    private static let notebookTools: [[String: Any]] = [
        [
            "type": "function", "name": "place_pins",
            "description": "Place one or more teaching Pins on a supplied notebook page.",
            "strict": true,
            "parameters": [
                "type": "object", "additionalProperties": false,
                "required": ["page_number", "pins"],
                "properties": [
                    "page_number": ["type": "integer", "minimum": 1],
                    "pins": [
                        "type": "array", "minItems": 1, "maxItems": 8,
                        "items": [
                            "type": "object", "additionalProperties": false,
                            "required": ["x", "y", "kind", "teaser", "body"],
                            "properties": [
                                "x": ["type": "number", "minimum": 0, "maximum": 1],
                                "y": ["type": "number", "minimum": 0, "maximum": 1],
                                "kind": ["type": "string", "enum": ["issue", "explanation"]],
                                "teaser": ["type": "string", "minLength": 1, "maxLength": 120],
                                "body": ["type": "string", "minLength": 1, "maxLength": 2000]
                            ]
                        ]
                    ]
                ]
            ]
        ],
        [
            "type": "function", "name": "switch_page",
            "description": "Switch to a supplied notebook page only when the student explicitly asks to navigate.",
            "strict": true,
            "parameters": [
                "type": "object", "additionalProperties": false,
                "required": ["page_number"],
                "properties": ["page_number": ["type": "integer", "minimum": 1]]
            ]
        ]
    ]

    private static func toolCalls(from data: Data) throws -> [AgentToolCall] {
        let payloads = (try? ResponsesSSEDecoder.payloads(from: data)) ?? []
        let response = payloads.reversed().compactMap { payload -> [String: Any]? in
            guard payload["type"] as? String == "response.completed" else { return nil }
            return payload["response"] as? [String: Any]
        }.first ?? (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let output = response["output"] as? [[String: Any]] ?? []
        return try output.compactMap { item in
            guard item["type"] as? String == "function_call",
                  let name = item["name"] as? String,
                  let arguments = item["arguments"] as? String,
                  arguments.utf8.count <= 256 * 1_024,
                  let bytes = arguments.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { return nil }
            guard let pageNumber = (object["page_number"] as? NSNumber)?.intValue,
                  pageNumber > 0 else { throw AgentError.parse }
            if name == "switch_page" {
                return .switchPage(pageNumber: pageNumber)
            }
            guard name == "place_pins",
                  let rawPins = object["pins"] as? [[String: Any]],
                  (1...8).contains(rawPins.count) else { throw AgentError.parse }
            let pins = try rawPins.map { raw -> PinDraft in
                guard let x = (raw["x"] as? NSNumber)?.doubleValue,
                      let y = (raw["y"] as? NSNumber)?.doubleValue,
                      let kindRaw = raw["kind"] as? String,
                      let kind = AnnotationKind(rawValue: kindRaw),
                      let teaser = raw["teaser"] as? String,
                      let body = raw["body"] as? String else { throw AgentError.parse }
                let target = CropNormalizedPoint(x: x, y: y)
                guard target.isFiniteAndInUnitBounds,
                      !teaser.isEmpty, teaser.count <= 120,
                      !body.isEmpty, body.count <= 2_000 else { throw AgentError.parse }
                return PinDraft(id: UUID(), target: target, targetRegion: nil, kind: kind, teaser: teaser, body: body, citations: [])
            }
            return .placePins(pageNumber: pageNumber, pins: pins)
        }
    }
}

enum AgentInsightClientFactory {
    /// Mints a single route at the user action. Normal Notebook code never receives
    /// a token, endpoint, account ID, or provider response body.
    @MainActor static func make(runtimeAccess: AgentRuntimeAccess? = nil) -> any AgentInsightClient {
        if runtimeAccess == nil {
            let stored = UserDefaults.standard.string(forKey: AgentProviderAccess.modelStorageKey)
            let model = OpenAICodexConstants.supportedModels.contains(stored ?? "")
                ? stored!
                : OpenAICodexConstants.defaultModel
            guard let route = OpenAICodexLoginSession.shared.route(for: .insight, model: model) else {
                return SignedOutAgentInsightClient()
            }
            return OpenAICodexVisionClient(route: route)
        }
        guard let runtimeAccess else { return SignedOutAgentInsightClient() }
        switch runtimeAccess {
        case .provider(let access):
#if DEBUG
            switch access.provider {
            case .openAI:
                return OpenAIVisionClient(access: access)
            case .rightCode:
                return RightCodeResponsesClient(access: access)
            }
#else
            _ = access
            return MockAgentInsightClient()
#endif
        case .openAICodex(let access):
            guard let route = OpenAICodexLoginSession.shared.route(for: .insight, model: access.model) else {
                return SignedOutAgentInsightClient()
            }
            return OpenAICodexVisionClient(route: route)
        }
    }
}
