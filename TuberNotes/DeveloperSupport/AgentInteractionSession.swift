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
    @Published private(set) var resetGeneration = 0

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

    var hasPendingPenCapture: Bool {
        activeRequest?.kind == .penFixture
            && activeRequest?.status == .awaitingHuman
            && hasCapturedStroke
    }

    var bannerTitle: String {
        activeRequest?.title ?? "Agent request"
    }

    var bannerPrompt: String {
        activeRequest?.prompt ?? ""
    }

    func reload() {
        activate(PenFixtureStore.resolveActiveRequest())
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
            var captured = request
            captured.eventCount = fixture.events.count
            captured.fixturePath = "Documents/pen-fixtures/\(fixture.name).json"
            activeRequest = captured
            lastCapturedFixtureName = fixture.name
            hasCapturedStroke = true
            statusMessage = "Captured \(fixture.events.count) points. Use Capture or Reset."
            print("TuberNotes drafted fixture \(fixture.name) for request \(request.id)")
        } catch {
            statusMessage = "Failed to save fixture: \(error.localizedDescription)"
        }
    }

    func confirmPenCapture() {
        guard var request = activeRequest,
              hasPendingPenCapture,
              let fixtureName = request.fixtureName else { return }
        request.status = .recorded
        request.completedAt = Date()
        request.fixturePath = "Documents/pen-fixtures/\(fixtureName).json"
        let notes = draftNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        request.humanNotes = notes.isEmpty ? nil : notes
        do {
            try PenFixtureStore.completeRequest(request)
            advanceAfterTerminal(message: "Indexed capture as \(fixtureName)")
            print("TuberNotes recorded fixture \(fixtureName) for request \(request.id)")
        } catch {
            statusMessage = "Failed to finalize fixture: \(error.localizedDescription)"
        }
    }

    func resetScenario() {
        if hasPendingPenCapture, let fixtureName = activeRequest?.fixtureName {
            try? PenFixtureStore.deleteFixture(named: fixtureName)
            activeRequest?.eventCount = nil
            activeRequest?.fixturePath = nil
            lastCapturedFixtureName = nil
            hasCapturedStroke = false
        }
        draftNotes = ""
        resetGeneration += 1
        statusMessage = activeRequest?.kind == .penFixture
            ? "Canvas reset. Draw the requested stroke once."
            : "Scenario reset to its initial state."
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
            advanceAfterTerminal(message: "Recorded verdict: \(verdict.rawValue)")
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

    private func activate(_ request: AgentInteractionRequest?) {
        activeRequest = request
        hasCapturedStroke = request?.status == .recorded || request?.status == .answered
        guard let request else { return }
        if request.status == .awaitingHuman {
            statusMessage = request.kind == .penFixture
                ? "Draw the requested stroke once with Apple Pencil."
                : "Review the running UI, then choose a verdict."
        }
    }

    private func advanceAfterTerminal(message: String) {
        draftNotes = ""
        let next = PenFixtureStore.resolveActiveRequest()
        activate(next)
        if next == nil {
            statusMessage = message
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    // Pick up newly pushed requests without relaunching.
                    let latest = PenFixtureStore.resolveActiveRequest()
                    if latest?.id != self.activeRequest?.id
                        || self.activeRequest?.status != .awaitingHuman {
                        self.activate(latest)
                    }
                }
            }
        }
    }
}
#endif
