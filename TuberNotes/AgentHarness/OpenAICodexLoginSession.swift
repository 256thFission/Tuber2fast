import Combine
import Foundation

enum OpenAICodexConstants {
    static let issuer = URL(string: "https://auth.openai.com")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let deviceAuthorizationEndpoint = issuer.appending(path: "api/accounts/deviceauth/usercode")
    static let deviceTokenEndpoint = issuer.appending(path: "api/accounts/deviceauth/token")
    static let tokenEndpoint = issuer.appending(path: "oauth/token")
    static let deviceVerificationURL = issuer.appending(path: "codex/device")
    static let deviceRedirectURI = "https://auth.openai.com/deviceauth/callback"
    static let codexAPIEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    static let originator = "opencode"

    // Compatibility is intentionally pinned to the OpenCode 1.18.3 device-flow shape.
    static let compatibilityVersion = "1.18.3"
    static let defaultModel = "gpt-5.6-terra"
    static let supportedModels = [
        defaultModel,
        "gpt-5.6-sol",
        "gpt-5.6-luna",
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.3-codex-spark"
    ]

    static let userAgent = "TuberNotes/1 (OpenCode-compatible \(compatibilityVersion))"
}

struct OpenAICodexAccess: Sendable {
    let accessToken: String
    let accountID: String?
    let model: String
    let expiresAt: Date
    let generation: UUID
}

/// The product-facing capabilities supported by the temporary, memory-only
/// OpenAI session. Notebook code can retain this route as a request snapshot,
/// but cannot read its authorization material or endpoint.
enum AgentCapability: Sendable {
    case insight
    case structuredPins
}

/// Opaque authorization snapshot for exactly one provider request. It is minted
/// on the main actor at the user's action and remains valid only for the login
/// generation that produced it.
struct AgentResponseRoute: Sendable {
    let model: String
    let generation: UUID
    let expiresAt: Date
    private let accessToken: String
    private let accountID: String?

    fileprivate init(access: OpenAICodexAccess) {
        model = access.model
        generation = access.generation
        expiresAt = access.expiresAt
        accessToken = access.accessToken
        accountID = access.accountID
    }

    func prepare(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let requestID = UUID().uuidString
        request.setValue(OpenAICodexConstants.originator, forHTTPHeaderField: "originator")
        request.setValue(requestID, forHTTPHeaderField: "session-id")
        request.setValue(requestID, forHTTPHeaderField: "x-request-id")
        request.setValue(OpenAICodexConstants.userAgent, forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
    }
}

private final class OpenAICodexRejectRedirectsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum OpenAICodexNetworking {
    static func ephemeralSession(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(
            configuration: configuration,
            delegate: OpenAICodexRejectRedirectsDelegate(),
            delegateQueue: nil
        )
    }
}

@MainActor
final class OpenAICodexLoginSession: ObservableObject {
    enum Phase: Equatable, Sendable {
        case signedOut
        case requestingCode
        case awaitingUser(code: String, verificationURL: URL)
        case polling(code: String, verificationURL: URL)
        case exchanging
        case signedIn
        case failed(message: String)
    }

    static let shared = OpenAICodexLoginSession()

    @Published private(set) var phase: Phase = .signedOut

    private static let attemptLifetime: Duration = .seconds(5 * 60)
    private static let pollingSafetyMargin: Duration = .seconds(3)
    private static let maximumResponseBytes = 64 * 1024

    private struct Credential {
        let accessToken: String
        let accountID: String?
        let expiresAt: Date
        let generation: UUID
    }

    private struct DeviceCodeResponse: Decodable {
        let deviceAuthID: String
        let userCode: String
        let interval: String

        enum CodingKeys: String, CodingKey {
            case deviceAuthID = "device_auth_id"
            case userCode = "user_code"
            case interval
        }
    }

    private struct DeviceCodeRequest: Encodable {
        let clientID: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
        }
    }

    private struct DeviceTokenRequest: Encodable {
        let deviceAuthID: String
        let userCode: String

        enum CodingKeys: String, CodingKey {
            case deviceAuthID = "device_auth_id"
            case userCode = "user_code"
        }
    }

    private struct DeviceTokenResponse: Decodable {
        let authorizationCode: String
        let codeVerifier: String

        enum CodingKeys: String, CodingKey {
            case authorizationCode = "authorization_code"
            case codeVerifier = "code_verifier"
        }
    }

    private struct TokenResponse: Decodable {
        let idToken: String?
        let accessToken: String
        let expiresIn: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private enum PollResult {
        case pending
        case authorized(DeviceTokenResponse)
    }

    private enum LoginError: Error {
        case expired
        case unavailable
        case malformedResponse
        case exchangeRejected
        case providerRejected

        var userMessage: String {
            switch self {
            case .expired:
                "OpenAI sign-in expired. Please try again."
            case .unavailable:
                "OpenAI sign-in is temporarily unavailable. Check your connection and try again."
            case .malformedResponse:
                "OpenAI returned an unexpected sign-in response. Please try again."
            case .exchangeRejected:
                "OpenAI could not finish sign-in. Please try again."
            case .providerRejected:
                "OpenAI declined the sign-in request. Please try again."
            }
        }
    }

    private let session: URLSession
    private var credential: Credential?
    private var attemptTask: Task<Void, Never>?
    private var attemptID: UUID?

    private init() {
        session = OpenAICodexNetworking.ephemeralSession(
            requestTimeout: 30,
            resourceTimeout: 30
        )
    }

    /// Starts a fresh, memory-only device authorization attempt.
    func start() {
        clearAttemptAndCredential()

        let id = UUID()
        attemptID = id
        phase = .requestingCode
        attemptTask = Task { [weak self] in
            guard let self else { return }
            await self.runAttempt(id: id)
        }
    }

    /// Confirms that the existing polling loop should continue. The server's minimum
    /// interval and safety margin still apply, so this never creates or accelerates a loop.
    func checkStatus() {
        guard attemptID != nil else { return }
        switch phase {
        case let .awaitingUser(code, verificationURL):
            // Give immediate UI feedback while the existing loop continues to
            // respect the server's scheduled polling interval.
            phase = .polling(code: code, verificationURL: verificationURL)
        case .polling:
            break
        default:
            break
        }
    }

    func cancel() {
        switch phase {
        case .requestingCode, .awaitingUser, .polling, .exchanging, .failed:
            clearAttemptAndCredential()
            phase = .signedOut
        case .signedOut, .signedIn:
            break
        }
    }

    func signOut() {
        clearAttemptAndCredential()
        phase = .signedOut
    }

    func access(model: String) -> OpenAICodexAccess? {
        guard let credential else { return nil }
        // Rendering asks for snapshots from computed SwiftUI state. Expiry
        // publication belongs to the scheduled task, never this accessor.
        guard Date.now < credential.expiresAt else { return nil }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OpenAICodexConstants.supportedModels.contains(trimmedModel) else { return nil }
        return OpenAICodexAccess(
            accessToken: credential.accessToken,
            accountID: credential.accountID,
            model: trimmedModel,
            expiresAt: credential.expiresAt,
            generation: credential.generation
        )
    }

    func route(for capability: AgentCapability, model: String) -> AgentResponseRoute? {
        // The capability is deliberately selected here so adding a new runtime
        // action must pass through AgentHarness, even while temporary Codex
        // access currently shares the same Responses endpoint.
        _ = capability
        return access(model: model).map(AgentResponseRoute.init(access:))
    }

    func isCurrent(generation: UUID) -> Bool {
        guard let credential else { return false }
        return credential.generation == generation && Date.now < credential.expiresAt
    }

    /// Clears only the session that minted the failed request.
    func invalidate(generation: UUID) {
        guard credential?.generation == generation else { return }
        clearAttemptAndCredential()
        phase = .signedOut
    }

    private func runAttempt(id: UUID) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.attemptLifetime)

        do {
            let deviceCode = try await requestDeviceCode()
            try requireCurrentAttempt(id, before: deadline, clock: clock)

            let userCode = try nonempty(deviceCode.userCode)
            let deviceAuthID = try nonempty(deviceCode.deviceAuthID)
            guard let intervalSeconds = Int(deviceCode.interval),
                  (1 ... 300).contains(intervalSeconds) else {
                throw LoginError.malformedResponse
            }

            phase = .awaitingUser(
                code: userCode,
                verificationURL: OpenAICodexConstants.deviceVerificationURL
            )
            await Task.yield()

            while true {
                try requireCurrentAttempt(id, before: deadline, clock: clock)
                phase = .polling(
                    code: userCode,
                    verificationURL: OpenAICodexConstants.deviceVerificationURL
                )

                switch try await poll(deviceAuthID: deviceAuthID, userCode: userCode) {
                case .pending:
                    try requireCurrentAttempt(id, before: deadline, clock: clock)
                    phase = .awaitingUser(
                        code: userCode,
                        verificationURL: OpenAICodexConstants.deviceVerificationURL
                    )
                    try await waitForNextPoll(
                        intervalSeconds: intervalSeconds,
                        id: id,
                        deadline: deadline,
                        clock: clock
                    )

                case let .authorized(authorization):
                    try requireCurrentAttempt(id, before: deadline, clock: clock)
                    phase = .exchanging
                    let tokens = try await exchange(authorization)
                    try requireCurrentAttempt(id, before: deadline, clock: clock)
                    try establishSession(tokens: tokens, generation: id)
                    scheduleExpiry(generation: id)
                    return
                }
            }
        } catch is CancellationError {
            // Cancellation is always paired with a synchronous state transition.
        } catch let error as LoginError {
            fail(error, id: id)
        } catch {
            fail(.unavailable, id: id)
        }
    }

    private func requestDeviceCode() async throws -> DeviceCodeResponse {
        var request = jsonRequest(url: OpenAICodexConstants.deviceAuthorizationEndpoint)
        request.httpBody = try JSONEncoder().encode(
            DeviceCodeRequest(clientID: OpenAICodexConstants.clientID)
        )
        let (data, response) = try await responseData(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw response.statusCode >= 500 ? LoginError.unavailable : LoginError.providerRejected
        }

        let decoded: DeviceCodeResponse = try decode(data)
        _ = try nonempty(decoded.deviceAuthID)
        _ = try nonempty(decoded.userCode)
        return decoded
    }

    private func poll(deviceAuthID: String, userCode: String) async throws -> PollResult {
        var request = jsonRequest(url: OpenAICodexConstants.deviceTokenEndpoint)
        request.httpBody = try JSONEncoder().encode(
            DeviceTokenRequest(deviceAuthID: deviceAuthID, userCode: userCode)
        )
        let (data, response) = try await responseData(for: request)

        switch response.statusCode {
        case 200 ... 299:
            let decoded: DeviceTokenResponse = try decode(data)
            _ = try nonempty(decoded.authorizationCode)
            _ = try nonempty(decoded.codeVerifier)
            return .authorized(decoded)
        case 403, 404:
            return .pending
        case 500 ... 599:
            throw LoginError.unavailable
        default:
            throw LoginError.providerRejected
        }
    }

    private func exchange(_ authorization: DeviceTokenResponse) async throws -> TokenResponse {
        let authorizationCode = try nonempty(authorization.authorizationCode)
        let verifier = try nonempty(authorization.codeVerifier)
        let fields = [
            ("grant_type", "authorization_code"),
            ("code", authorizationCode),
            ("redirect_uri", OpenAICodexConstants.deviceRedirectURI),
            ("client_id", OpenAICodexConstants.clientID),
            ("code_verifier", verifier)
        ]

        var request = baseRequest(url: OpenAICodexConstants.tokenEndpoint)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(fields).data(using: .utf8)

        let (data, response) = try await responseData(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw response.statusCode >= 500 ? LoginError.unavailable : LoginError.exchangeRejected
        }

        let decoded: TokenResponse = try decode(data)
        _ = try nonempty(decoded.accessToken)
        if let expiresIn = decoded.expiresIn,
           (!expiresIn.isFinite || expiresIn <= 0) {
            throw LoginError.malformedResponse
        }
        return decoded
    }

    private func establishSession(tokens: TokenResponse, generation: UUID) throws {
        let accessToken = try nonempty(tokens.accessToken)
        let expiresIn = tokens.expiresIn ?? 3_600
        let expiresAt = Date.now.addingTimeInterval(expiresIn)
        let accountID = Self.extractAccountID(idToken: tokens.idToken, accessToken: tokens.accessToken)

        // Only the access token and optional routing claim survive this call. The ID and
        // refresh tokens, authorization code, and verifier are deliberately not retained.
        credential = Credential(
            accessToken: accessToken,
            accountID: accountID,
            expiresAt: expiresAt,
            generation: generation
        )
        phase = .signedIn
    }

    /// Replaces the login task with a maintenance task that captures no authorization
    /// code, verifier, refresh token, ID token, device ID, or user code. Returning from
    /// `runAttempt` then releases its short-lived authorization response values.
    private func scheduleExpiry(generation: UUID) {
        attemptID = nil
        attemptTask = Task { [weak self] in
            guard let self else { return }
            await self.expireSessionWhenNeeded(generation: generation)
        }
    }

    private func expireSessionWhenNeeded(generation: UUID) async {
        guard let expiresAt = credential?.expiresAt,
              credential?.generation == generation else { return }
        let remaining = max(0, expiresAt.timeIntervalSinceNow)
        do {
            try await Task.sleep(for: .seconds(remaining))
        } catch {
            return
        }

        guard credential?.generation == generation else { return }
        credential = nil
        attemptID = nil
        attemptTask = nil
        phase = .signedOut
    }

    private func waitForNextPoll(
        intervalSeconds: Int,
        id: UUID,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws {
        let delay = Duration.seconds(intervalSeconds) + Self.pollingSafetyMargin
        let scheduled = clock.now.advanced(by: delay)
        let target = min(scheduled, deadline)

        while clock.now < target {
            try requireCurrentAttempt(id, before: deadline, clock: clock)
            let remaining = clock.now.duration(to: target)
            let slice = min(remaining, .milliseconds(250))
            try await Task.sleep(for: slice)
        }

        try requireCurrentAttempt(id, before: deadline, clock: clock)
    }

    private func requireCurrentAttempt(
        _ id: UUID,
        before deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws {
        try Task.checkCancellation()
        guard attemptID == id else { throw CancellationError() }
        guard clock.now < deadline else { throw LoginError.expired }
    }

    private func fail(_ error: LoginError, id: UUID) {
        guard attemptID == id else { return }
        credential = nil
        attemptID = nil
        attemptTask = nil
        phase = .failed(message: error.userMessage)
    }

    private func clearAttemptAndCredential() {
        attemptTask?.cancel()
        attemptTask = nil
        attemptID = nil
        credential = nil
    }

    private func jsonRequest(url: URL) -> URLRequest {
        var request = baseRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func baseRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue(OpenAICodexConstants.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func responseData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LoginError.malformedResponse
            }
            var data = Data()
            data.reserveCapacity(min(Self.maximumResponseBytes, 8 * 1_024))
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else {
                    bytes.task.cancel()
                    throw LoginError.malformedResponse
                }
                data.append(byte)
            }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as LoginError {
            throw error
        } catch {
            throw LoginError.unavailable
        }
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        guard !data.isEmpty, data.count <= Self.maximumResponseBytes else {
            throw LoginError.malformedResponse
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw LoginError.malformedResponse
        }
    }

    private func nonempty(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LoginError.malformedResponse }
        return trimmed
    }

    private func formEncoded(_ fields: [(String, String)]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }

    private static func extractAccountID(idToken: String?, accessToken: String) -> String? {
        if let idToken,
           let claims = jwtClaims(idToken),
           let accountID = accountID(from: claims) {
            return accountID
        }
        if let claims = jwtClaims(accessToken),
           let accountID = accountID(from: claims) {
            return accountID
        }
        return nil
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data),
              let claims = object as? [String: Any] else {
            return nil
        }
        return claims
    }

    private static func accountID(from claims: [String: Any]) -> String? {
        if let direct = nonemptyClaim(claims["chatgpt_account_id"]) {
            return direct
        }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let namespaced = nonemptyClaim(auth["chatgpt_account_id"]) {
            return namespaced
        }
        if let organizations = claims["organizations"] as? [[String: Any]],
           let first = organizations.first,
           let organizationID = nonemptyClaim(first["id"]) {
            return organizationID
        }
        return nil
    }

    private static func nonemptyClaim(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
