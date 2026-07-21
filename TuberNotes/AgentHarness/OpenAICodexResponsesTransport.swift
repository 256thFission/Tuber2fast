import Foundation

/// Redacted failures from the temporary direct-Codex bridge. Provider response
/// bodies and request metadata never leave AgentHarness.
enum OpenAICodexTransportError: Error {
    case unauthorized(generation: UUID)
    case unsupported
    case unavailable
    case invalidResponse
}

/// The only sender for normal-app requests authenticated by the temporary
/// OpenAI session. Capability clients own prompts and parsers; this type owns
/// the endpoint, authorization headers, response bounds, and status policy.
struct OpenAICodexResponsesTransport: Sendable {
    private let session: URLSession

    init(
        session: URLSession = OpenAICodexNetworking.ephemeralSession(
            requestTimeout: 90,
            resourceTimeout: 180
        )
    ) {
        self.session = session
    }

    func send(
        body: Data,
        route: AgentResponseRoute,
        capability: AgentCapability,
        maximumRequestBytes: Int = 12 * 1_024 * 1_024,
        maximumResponseBytes: Int
    ) async throws -> Data {
        guard !body.isEmpty,
              body.count <= maximumRequestBytes else {
            throw OpenAICodexTransportError.invalidResponse
        }
        guard Date.now < route.expiresAt else {
            throw OpenAICodexTransportError.unauthorized(generation: route.generation)
        }
        _ = capability

        do {
            var request = URLRequest(url: OpenAICodexConstants.codexAPIEndpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
            route.prepare(&request)
            request.httpBody = body

            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else {
                throw OpenAICodexTransportError.unavailable
            }
            switch http.statusCode {
            case 200..<300:
                break
            case 401, 403:
                throw OpenAICodexTransportError.unauthorized(generation: route.generation)
            case 400, 404, 405, 415, 422:
                throw OpenAICodexTransportError.unsupported
            default:
                throw OpenAICodexTransportError.unavailable
            }

            var data = Data()
            data.reserveCapacity(min(maximumResponseBytes, 256 * 1_024))
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw OpenAICodexTransportError.invalidResponse
                }
                data.append(byte)
            }
            guard !data.isEmpty else { throw OpenAICodexTransportError.invalidResponse }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenAICodexTransportError {
            throw error
        } catch {
            throw OpenAICodexTransportError.unavailable
        }
    }
}
