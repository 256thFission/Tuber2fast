import Foundation
import UIKit

/// Result of asking the agent to look at a page selection.
struct AgentInsight: Equatable {
    let summary: String
    let items: [String]
}

/// Boundary for "look at what I circled and tell me what you see". Complements the
/// existing `AgentClient`/`SpatialSelection` boundary (which returns `[Pin]`); this
/// one returns human-readable text for the toggleable assistant sidebar.
protocol AgentInsightClient {
    func analyze(_ selection: SpatialSelection, question: String?) async throws -> AgentInsight
}

enum AgentError: LocalizedError {
    case server(String)
    case parse
    case noKey

    var errorDescription: String? {
        switch self {
        case .server(let m): "Service error: \(m)"
        case .parse:         "Couldn't read the assistant's response."
        case .noKey:         "No API key set."
        }
    }
}

/// Runs with no network/key so the app is fully functional out of the box.
struct MockAgentInsightClient: AgentInsightClient {
    func analyze(_ selection: SpatialSelection, question: String?) async throws -> AgentInsight {
        try? await Task.sleep(nanoseconds: 700_000_000)
        return AgentInsight(
            summary: "Demo mode. Add an OpenAI API key in the assistant settings to get real descriptions. I can see you've drawn on the page and marked a region.",
            items: [
                "Handwritten strokes detected",
                "One circled / marked area",
                "Add a key to enable real analysis"
            ]
        )
    }
}

/// Sends the captured page image to OpenAI's vision-capable chat endpoint.
///
/// Security note: putting an API key directly in the app is fine for local dev,
/// but for anything shipped you should proxy requests through your own backend
/// so the key never lives on device.
struct OpenAIVisionClient: AgentInsightClient {
    let apiKey: String
    var model: String = "gpt-4o-mini"

    func analyze(_ selection: SpatialSelection, question: String?) async throws -> AgentInsight {
        let dataURL = "data:image/jpeg;base64,\(selection.imageData.base64EncodedString())"
        let prompt = question ?? """
        This is a page from a handwritten notebook. The user has drawn on it and may have \
        circled or marked something. Describe what you see, focusing on anything circled or \
        marked. Reply with a one-paragraph summary, then a short bullet list (using "- ") of \
        the distinct things you notice. Keep it concise.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 500,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": dataURL]]
                ]
            ]]
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AgentError.server(String(data: data, encoding: .utf8) ?? "Unknown error")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw AgentError.parse }

        return Self.parse(content)
    }

    static func parse(_ text: String) -> AgentInsight {
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
}

enum AgentClientFactory {
    /// Returns the real client when a key is present, otherwise the offline demo client.
    static func make(apiKey: String) -> AgentInsightClient {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? MockAgentInsightClient() : OpenAIVisionClient(apiKey: key)
    }
}
