import Foundation
import UIKit

/// Result of asking the agent to look at a page selection.
struct AgentInsight: Equatable {
    let summary: String
    let items: [String]
}

/// Boundary for "look at what I circled and tell me what you see". Complements the
/// existing `AgentClient`/`SelectionArtifact` boundary (which returns Pin events);
/// this one returns human-readable text that is persisted as an Agentic Layer Pin.
protocol AgentInsightClient: Sendable {
    func analyze(_ selection: SelectionArtifact, question: String?) async throws -> AgentInsight
}

enum AgentError: LocalizedError {
    case server(statusCode: Int)
    case parse
    case unavailable

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
        }
    }
}

/// Runs with no provider access so the app is fully functional out of the box.
struct MockAgentInsightClient: AgentInsightClient {
    func analyze(_ selection: SelectionArtifact, question: String?) async throws -> AgentInsight {
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

private func defaultInsightPrompt(_ question: String?) -> String {
    question ?? """
    This is a page from a handwritten notebook. The user has drawn on it and may have \
    circled or marked something. Describe what you see, focusing on anything circled or \
    marked. Reply with a one-paragraph summary, then a short bullet list (using "- ") of \
    the distinct things you notice. Keep it concise.
    """
}

private func parseInsight(_ text: String) -> AgentInsight {
    let lines = text
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    var summary = ""
    var items: [String] = []
    for line in lines {
        if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") {
            items.append(String(line.dropFirst(2)))
        } else if summary.isEmpty {
            summary = line
        }
    }
    if summary.isEmpty { summary = text }
    return AgentInsight(summary: summary, items: items)
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

    init(
        access: AgentProviderAccess,
        session: URLSession = AgentProviderNetworking.ephemeralSession()
    ) {
        self.access = access
        self.session = session
    }

    func analyze(_ selection: SelectionArtifact, question: String?) async throws -> AgentInsight {
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

    init(
        access: AgentProviderAccess,
        session: URLSession = AgentProviderNetworking.ephemeralSession()
    ) {
        self.access = access
        self.session = session
    }

    func analyze(_ selection: SelectionArtifact, question: String?) async throws -> AgentInsight {
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

enum AgentInsightClientFactory {
    /// Returns the selected provider client when configured, otherwise the offline demo client.
    static func make(access: AgentProviderAccess?) -> any AgentInsightClient {
#if DEBUG
        guard let access else { return MockAgentInsightClient() }
        switch access.provider {
        case .openAI:
            return OpenAIVisionClient(access: access)
        case .rightCode:
            return RightCodeResponsesClient(access: access)
        }
#else
        return MockAgentInsightClient()
#endif
    }
}
