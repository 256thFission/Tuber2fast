#if DEBUG
import Foundation

struct DebugCodexConfiguration: Sendable {
    static let defaultModel = "gpt-5.6-terra"

    let accessToken: String
    let accountID: String?
    let model: String

    static func processEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        guard environment["TUBER_AGENT_MODE"] == "codex",
              let token = environment["TUBER_CODEX_ACCESS_TOKEN"], !token.isEmpty else { return nil }
        let override = environment["TUBER_CODEX_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            accessToken: token,
            accountID: environment["TUBER_CODEX_ACCOUNT_ID"],
            model: override.flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        )
    }
}

struct DebugCodexTransport: Sendable {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    let configuration: DebugCodexConfiguration
    private let session: URLSession

    init(configuration: DebugCodexConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? Self.ephemeralSession()
    }

    func request(for investigation: InvestigationRequest) throws -> URLRequest {
        guard investigation.conversationID == nil else { throw TransportError.invalidRequest }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("opencode", forHTTPHeaderField: "originator")
        request.setValue(investigation.id.uuidString, forHTTPHeaderField: "session-id")
        request.setValue("TuberNotes-Debug/1", forHTTPHeaderField: "User-Agent")
        if let accountID = configuration.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body(for: investigation))
        return request
    }

    /// Opens the response as bytes and dispatches each SSE JSON payload before the connection closes.
    /// Returning true from `onPayload` terminates the HTTP task immediately after a typed terminal event.
    func send(
        _ request: URLRequest,
        onPayload: ([String: Any]) async throws -> Bool
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.prefersIncrementalDelivery = true
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw TransportError.unavailable }
        guard (200 ... 299).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403: throw TransportError.unauthorized
            case 408, 504: throw TransportError.timedOut
            case 400 ... 499: throw TransportError.invalidRequest
            default: throw TransportError.unavailable
            }
        }

        var decoder = ResponsesSSEDecoder()
        for try await byte in bytes {
            try Task.checkCancellation()
            for record in try decoder.feed(byte) {
                try Task.checkCancellation()
                switch record {
                case .done:
                    return
                case let .payload(payload):
                    if try await onPayload(payload) { return }
                }
            }
        }
        try decoder.finish()
    }

    private func body(for request: InvestigationRequest) -> [String: Any] {
        let crop = request.selection.crop
        let image = "data:\(crop.mediaType);base64,\(crop.imageData.base64EncodedString())"
        let context = request.selection.context.nearbyText ?? ""
        let intent: String = switch request.intent {
        case .explain: "explain"
        case .check: "check"
        case let .ask(question): "answer: \(question)"
        }
        return [
            "model": configuration.model,
            "stream": true,
            "store": false,
            "parallel_tool_calls": false,
            "reasoning": ["effort": "medium", "summary": "auto"],
            "text": ["verbosity": "low"],
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": "Intent: \(intent). Inspect the selected work. Nearby text: \(context). Place concise pins using crop-normalized coordinates where x=0 is left, x=1 is right, y=0 is top, and y=1 is bottom."],
                    ["type": "input_image", "image_url": image, "detail": "original"]
                ]
            ]],
            "tool_choice": ["type": "function", "name": "place_pins"],
            "tools": [[
                "type": "function", "name": "place_pins",
                "description": "Place proposed notes over the selected crop.",
                "strict": true,
                "parameters": Self.placePinsSchema()
            ]]
        ]
    }

    private static func placePinsSchema() -> [String: Any] {
        [
            "type": "object", "additionalProperties": false, "required": ["pins"],
            "properties": ["pins": [
                "type": "array", "minItems": 1, "maxItems": 8,
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["x", "y", "kind", "teaser", "body"],
                    "properties": [
                        "x": ["type": "number", "minimum": 0, "maximum": 1],
                        "y": ["type": "number", "minimum": 0, "maximum": 1],
                        "kind": ["type": "string", "enum": ["confirmation", "issue", "explanation", "source", "uncertainty", "suggestion"]],
                        "teaser": ["type": "string"], "body": ["type": "string"]
                    ]
                ]
            ]]
        ]
    }

    private static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }

    enum TransportError: Error {
        case unauthorized
        case timedOut
        case invalidRequest
        case unavailable
    }
}
#endif
