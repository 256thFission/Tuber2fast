import Combine
import Foundation
import PencilKit

#if DEBUG
@MainActor
final class AgentInteractionSession: ObservableObject {
    @Published private(set) var activeRequest: AgentInteractionRequest?
    @Published private(set) var lastCapturedFixtureName: String?
    @Published var draftNotes: String = ""
    @Published private(set) var statusMessage: String?

    private var hasCapturedStroke = false
    private var pollTask: Task<Void, Never>?

    init() {
        reload()
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    var isRecordingPen: Bool {
        guard let activeRequest else { return false }
        return activeRequest.kind == .penFixture && activeRequest.status == .awaitingHuman && !hasCapturedStroke
    }

    var bannerTitle: String {
        activeRequest?.title ?? "Agent request"
    }

    var bannerPrompt: String {
        activeRequest?.prompt ?? ""
    }

    func reload() {
        activeRequest = PenFixtureStore.resolveActiveRequest()
        hasCapturedStroke = activeRequest?.status == .recorded || activeRequest?.status == .answered
        if let activeRequest, activeRequest.status == .awaitingHuman {
            statusMessage = activeRequest.kind == .penFixture
                ? "Draw the requested stroke once with Apple Pencil."
                : "Review the running UI, then choose a verdict."
        }
    }

    func handleDrawingChange(drawing: PKDrawing, canvasSize: CGSize) {
        guard isRecordingPen,
              let request = activeRequest,
              let fixtureName = request.fixtureName,
              let fixture = PenFixtureRecorder.makeFixture(
                name: fixtureName,
                description: request.prompt,
                requestID: request.id,
                drawing: drawing,
                canvasSize: canvasSize
              ) else { return }

        do {
            try PenFixtureStore.saveFixture(fixture)
            var completed = request
            completed.status = .recorded
            completed.completedAt = Date()
            completed.eventCount = fixture.events.count
            if !draftNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completed.humanNotes = draftNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try PenFixtureStore.completeRequest(completed)
            activeRequest = completed
            lastCapturedFixtureName = fixture.name
            hasCapturedStroke = true
            statusMessage = "Captured \(fixture.events.count) points · indexed as \(fixture.name)"
            print("TuberNotes recorded fixture \(fixture.name) for request \(request.id)")
        } catch {
            statusMessage = "Failed to save fixture: \(error.localizedDescription)"
        }
    }

    func submitVerdict(_ verdict: AgentInteractionRequest.Verdict) {
        guard var request = activeRequest, request.status == .awaitingHuman || request.status == .recorded else { return }
        request.verdict = verdict
        request.status = .answered
        request.completedAt = Date()
        let notes = draftNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        request.humanNotes = notes.isEmpty ? request.humanNotes : notes
        do {
            try PenFixtureStore.completeRequest(request)
            activeRequest = request
            statusMessage = "Recorded verdict: \(verdict.rawValue)"
        } catch {
            statusMessage = "Failed to save verdict: \(error.localizedDescription)"
        }
    }

    func dismissCompleted() {
        guard let activeRequest, activeRequest.status != .awaitingHuman else { return }
        self.activeRequest = nil
        draftNotes = ""
        statusMessage = nil
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    // Pick up newly pushed requests without relaunching.
                    if self.activeRequest == nil || self.activeRequest?.status == .awaitingHuman {
                        let latest = PenFixtureStore.resolveActiveRequest()
                        if latest?.id != self.activeRequest?.id {
                            self.reload()
                        }
                    }
                }
            }
        }
    }
}
#endif
