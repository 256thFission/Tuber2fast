import Combine
import PencilKit
import SwiftUI

#if DEBUG
@MainActor
final class FeedbackThreadSession: ObservableObject {
    enum Preference: String, CaseIterable, Identifiable {
        case a = "Prefer A", b = "Prefer B", neither = "Neither", none = "No preference"
        var id: String { rawValue }
    }

    @Published private(set) var feedbackThreads: [FeedbackThread] = []
    @Published private(set) var activeFeedbackThread: FeedbackThread?
    @Published private(set) var resetGeneration = 0
    @Published private(set) var captureRequestGeneration = 0
    @Published private(set) var isCapturing = false
    @Published var isPresentingFullThread = false
    @Published var capturedImage: UIImage?
    @Published var statusMessage: String?

    private var pollTask: Task<Void, Never>?

    init() {
        reload()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }
    }

    deinit { pollTask?.cancel() }

    var activeQuestion: FeedbackMessage? {
        guard let value = activeFeedbackThread else { return nil }
        let answeredIDs = Set(value.messages.compactMap(\.inReplyTo))
        return value.messages.reversed().first {
            $0.interaction?.state == .awaitingHuman && !answeredIDs.contains($0.id)
        }
    }

    var comparisonID: String? {
        activeFeedbackThread?.activeComparisonID
            ?? activeFeedbackThread?.messages.reversed().compactMap { $0.surfaceDirective?.comparisonID ?? $0.interaction?.comparisonID }.first
    }

    var isLiveComparison: Bool { comparisonID == "pin-presentation-01" }
    var activeVariant: String { activeFeedbackThread?.activeVariantID ?? "a" }

    func reload() {
        var loaded = FeedbackThreadStore.loadAll()
        if !loaded.contains(where: { $0.state.ownsDeviceSlot }),
           let index = loaded.firstIndex(where: { $0.state == .queued }) {
            loaded[index].state = .open
            loaded[index].updatedAt = Date()
            loaded[index].revision += 1
            try? FeedbackThreadStore.save(loaded[index])
            FeedbackThreadStore.appendEvent("thread-activated", feedbackThreadID: loaded[index].id)
        }
        feedbackThreads = loaded
        activeFeedbackThread = loaded.filter { $0.state.ownsDeviceSlot }
            .sorted { ($0.queueSequence, $0.id) < ($1.queueSequence, $1.id) }.first
    }

    func sendReply(_ body: String) {
        appendHumanMessage(body: body, selectedOptionID: nil, answering: activeQuestion?.interaction?.kind == .freeText ? activeQuestion?.id : nil)
    }

    func answer(_ questionMessage: FeedbackMessage, optionID: String, comment: String) {
        guard questionMessage.interaction?.kind == .singleChoice, activeQuestion?.id == questionMessage.id else { return }
        appendHumanMessage(body: comment, selectedOptionID: optionID, answering: questionMessage.id)
    }

    func setState(_ state: FeedbackThreadState) {
        guard var value = activeFeedbackThread else { return }
        value.state = state
        value.lastConsumedSequence = value.lastSequence
        value.updatedAt = Date()
        value.revision += 1
        do {
            try FeedbackThreadStore.save(value)
            FeedbackThreadStore.appendEvent("thread-\(state.rawValue)", feedbackThreadID: value.id, values: ["actor": "human", "lastConsumedSequence": "\(value.lastSequence)"])
            reload()
        } catch { statusMessage = error.localizedDescription }
    }

    func selectVariant(_ variant: String) {
        guard var value = activeFeedbackThread, isLiveComparison, variant == "a" || variant == "b" else { return }
        value.activeComparisonID = "pin-presentation-01"
        value.activeVariantID = variant
        value.updatedAt = Date()
        value.revision += 1
        do {
            try FeedbackThreadStore.save(value)
            activeFeedbackThread = value
            resetGeneration += 1
            FeedbackThreadStore.appendEvent("variant-exposed", feedbackThreadID: value.id, values: ["comparisonID": "pin-presentation-01", "variantID": variant])
        } catch { statusMessage = error.localizedDescription }
    }

    func resetComparison() {
        guard let id = activeFeedbackThread?.id, isLiveComparison else { return }
        resetGeneration += 1
        FeedbackThreadStore.appendEvent("comparison-reset", feedbackThreadID: id, values: ["comparisonID": "pin-presentation-01"])
    }

    func submitPreference(_ preference: Preference, comment: String) {
        guard let id = activeFeedbackThread?.id, isLiveComparison else { return }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? preference.rawValue : "\(preference.rawValue): \(trimmed)"
        appendHumanMessage(body: body, selectedOptionID: preference.id, answering: activeQuestion?.id)
        FeedbackThreadStore.appendEvent("comparison-preference", feedbackThreadID: id, values: ["comparisonID": "pin-presentation-01", "preference": preference.id])
    }

    func requestCapture() {
        guard activeFeedbackThread != nil else { return }
        isCapturing = true
        captureRequestGeneration += 1
    }

    func receiveCapturedImage(_ image: UIImage?) {
        isCapturing = false
        capturedImage = image
        if image == nil { statusMessage = "Viewport capture failed." }
    }

    func cancelCapture() {
        capturedImage = nil
        statusMessage = nil
    }

    func sendCapture(drawing: PKDrawing, caption: String) {
        guard var value = activeFeedbackThread, let cleanImage = capturedImage else { return }
        let messageID = "feedback-message-\(UUID().uuidString.lowercased())"
        let attachmentID = "feedback-attachment-\(UUID().uuidString.lowercased())"
        let directory = FeedbackThreadStore.attachmentDirectory(feedbackThreadID: value.id)
        let cleanURL = directory.appendingPathComponent("\(attachmentID)-clean.png")
        let annotatedURL = directory.appendingPathComponent("\(attachmentID)-annotated.png")
        let annotated = UIGraphicsImageRenderer(size: cleanImage.size).image { _ in
            cleanImage.draw(in: CGRect(origin: .zero, size: cleanImage.size))
            drawing.image(from: CGRect(origin: .zero, size: cleanImage.size), scale: cleanImage.scale)
                .draw(in: CGRect(origin: .zero, size: cleanImage.size))
        }
        guard let cleanData = cleanImage.pngData(), let annotatedData = annotated.pngData() else {
            statusMessage = "Could not encode viewport capture."
            return
        }

        let idempotencyKey = "human-capture-\(UUID().uuidString.lowercased())"
        let attachment = FeedbackAttachment(
            id: attachmentID,
            messageID: messageID,
            kind: "annotated-screenshot",
            cleanPath: "attachments/\(cleanURL.lastPathComponent)",
            annotatedPath: "attachments/\(annotatedURL.lastPathComponent)",
            caption: caption.nilIfBlank,
            pixelWidth: cleanImage.cgImage?.width ?? Int(cleanImage.size.width * cleanImage.scale),
            pixelHeight: cleanImage.cgImage?.height ?? Int(cleanImage.size.height * cleanImage.scale),
            orientation: cleanImage.size.width >= cleanImage.size.height ? "landscape" : "portrait",
            scenario: value.scenario,
            surfaceRevision: value.surfaceRevision,
            createdAt: Date()
        )
        let message = FeedbackMessage(
            id: messageID,
            feedbackThreadID: value.id,
            sequence: value.lastSequence + 1,
            author: .human,
            body: caption.nilIfBlank,
            createdAt: Date(),
            interaction: nil,
            attachments: [attachment],
            surfaceDirective: nil,
            inReplyTo: activeQuestion?.id,
            idempotencyKey: idempotencyKey,
            selectedOptionID: nil
        )
        value.state = .awaitingModel
        do {
            try cleanData.write(to: cleanURL, options: .atomic)
            try annotatedData.write(to: annotatedURL, options: .atomic)
            try FeedbackThreadStore.appendMessage(message, to: &value)
            FeedbackThreadStore.appendEvent("annotated-screenshot-sent", feedbackThreadID: value.id, values: ["attachmentID": attachmentID, "messageID": messageID])
            capturedImage = nil
            reload()
        } catch {
            try? FileManager.default.removeItem(at: cleanURL)
            try? FileManager.default.removeItem(at: annotatedURL)
            statusMessage = error.localizedDescription
        }
    }

    private func appendHumanMessage(body: String, selectedOptionID: String?, answering questionID: String?) {
        guard var value = activeFeedbackThread else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || selectedOptionID != nil else { return }
        let idempotencyKey = "human-reply-\(UUID().uuidString.lowercased())"
        let message = FeedbackMessage(
            id: "feedback-message-\(UUID().uuidString.lowercased())",
            feedbackThreadID: value.id,
            sequence: value.lastSequence + 1,
            author: .human,
            body: trimmed.nilIfBlank,
            createdAt: Date(),
            interaction: nil,
            attachments: [],
            surfaceDirective: nil,
            inReplyTo: questionID,
            idempotencyKey: idempotencyKey,
            selectedOptionID: selectedOptionID
        )
        value.state = .awaitingModel
        do {
            try FeedbackThreadStore.appendMessage(message, to: &value)
            FeedbackThreadStore.appendEvent("message-posted", feedbackThreadID: value.id, values: ["messageID": message.id, "author": "human"])
            reload()
        } catch { statusMessage = error.localizedDescription }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
