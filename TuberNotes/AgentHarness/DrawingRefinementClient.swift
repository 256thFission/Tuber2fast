import Foundation
import UIKit

struct DrawingRefinementRequest: Sendable {
    let imageData: Data
    let prompt: String
}

struct RefinedDrawing: Sendable {
    let imageData: Data
}

protocol DrawingRefinementClient: Sendable {
    func refine(_ request: DrawingRefinementRequest) async throws -> RefinedDrawing
}

enum DrawingRefinementError: LocalizedError {
    case notConfigured
    case invalidResponse
    case requestFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI refinement needs a backend endpoint."
        case .invalidResponse:
            return "The refinement service returned an unreadable image."
        case .requestFailed(let statusCode):
            return "The refinement service failed (HTTP \(statusCode))."
        }
    }
}

/// Provider-neutral product boundary. The configured backend owns model credentials and auth.
struct BackendDrawingRefinementClient: DrawingRefinementClient {
    private struct Payload: Encodable {
        let imageBase64: String
        let prompt: String
    }

    let endpoint: URL?

    init(endpoint: URL? = Bundle.main.refinementEndpoint) {
        self.endpoint = endpoint
    }

    func refine(_ request: DrawingRefinementRequest) async throws -> RefinedDrawing {
        guard let endpoint else { throw DrawingRefinementError.notConfigured }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("image/png", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(
            Payload(imageBase64: request.imageData.base64EncodedString(), prompt: request.prompt)
        )

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DrawingRefinementError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DrawingRefinementError.requestFailed(statusCode: httpResponse.statusCode)
        }
        guard UIImage(data: data) != nil else { throw DrawingRefinementError.invalidResponse }
        return RefinedDrawing(imageData: data)
    }
}

private extension Bundle {
    var refinementEndpoint: URL? {
#if DEBUG
        if let value = ProcessInfo.processInfo.environment["TUBER_REFINEMENT_ENDPOINT"],
           let url = URL(string: value) {
            return url
        }
#endif
        guard let value = object(forInfoDictionaryKey: "TuberRefinementEndpoint") as? String,
              !value.isEmpty else { return nil }
        return URL(string: value)
    }
}

#if DEBUG
/// Deterministic visual-verification client. It never contacts a model or network service.
struct PreviewDrawingRefinementClient: DrawingRefinementClient {
    func refine(_ request: DrawingRefinementRequest) async throws -> RefinedDrawing {
        guard let source = UIImage(data: request.imageData) else {
            throw DrawingRefinementError.invalidResponse
        }
        let renderer = UIGraphicsImageRenderer(size: source.size)
        let image = renderer.image { context in
            UIColor.systemBackground.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: source.size))
            source.draw(in: CGRect(origin: .zero, size: source.size))

            let inset = CGRect(origin: .zero, size: source.size).insetBy(dx: 5, dy: 5)
            UIColor.systemIndigo.withAlphaComponent(0.7).setStroke()
            let border = UIBezierPath(roundedRect: inset, cornerRadius: 14)
            border.lineWidth = 4
            border.stroke()
        }
        guard let data = image.pngData() else { throw DrawingRefinementError.invalidResponse }
        return RefinedDrawing(imageData: data)
    }
}
#endif
