import Foundation

#if DEBUG
enum FeedbackThreadState: String, Codable, CaseIterable {
    case queued, open, blocked, resolved, cancelled
    case awaitingModel = "awaiting-model"

    var ownsDeviceSlot: Bool { self == .open || self == .awaitingModel }
}

enum FeedbackAuthor: String, Codable { case model, human, system }

struct FeedbackChoice: Codable, Equatable, Identifiable {
    var id: String
    var label: String
}

struct FeedbackInteraction: Codable, Equatable {
    enum Kind: String, Codable { case freeText = "free-text", singleChoice = "single-choice", liveAB = "live-ab-comparison" }
    enum State: String, Codable { case awaitingHuman = "awaiting-human", answered, cancelled, expired }

    var kind: Kind
    var state: State
    var options: [FeedbackChoice]?
    var allowsComment: Bool?
    var allowsAttachment: Bool?
    var comparisonID: String?
}

struct FeedbackSurfaceDirective: Codable, Equatable {
    var scenario: String?
    var comparisonID: String?
    var variantID: String?
    var surfaceRevision: Int?
    var resetPolicy: String?
}

struct FeedbackAttachment: Codable, Equatable, Identifiable {
    var id: String
    var messageID: String
    var kind: String
    var cleanPath: String
    var annotatedPath: String
    var caption: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var orientation: String
    var scenario: String?
    var surfaceRevision: Int
    var createdAt: Date
}

struct FeedbackMessage: Codable, Equatable, Identifiable {
    var id: String
    var feedbackThreadID: String
    var sequence: Int
    var author: FeedbackAuthor
    var body: String?
    var createdAt: Date
    var interaction: FeedbackInteraction?
    var attachments: [FeedbackAttachment]
    var surfaceDirective: FeedbackSurfaceDirective?
    var inReplyTo: String?
    var idempotencyKey: String
    var selectedOptionID: String?
}

struct FeedbackThread: Codable, Equatable, Identifiable {
    struct Requester: Codable, Equatable { var id: String }
    struct Owner: Codable, Equatable { var tokenHash: String; var tokenRequired: Bool }
    struct Target: Codable, Equatable { var kind: String; var id: String }
    struct Delivery: Codable, Equatable { var target: Target; var pinnedAt: Date }

    var schemaVersion: Int
    var id: String
    var title: String
    var objective: String
    var state: FeedbackThreadState
    var createdAt: Date
    var updatedAt: Date
    var requester: Requester
    var owner: Owner
    var scenario: String
    var surfaceRevision: Int
    var queueSequence: Int
    var lastSequence: Int
    var lastHumanSequence: Int
    var lastConsumedSequence: Int
    var revision: Int
    var eventSequence: Int
    var messageIDs: [String]
    var messageIdempotency: [String: Int]
    var delivery: Delivery
    var activeComparisonID: String?
    var activeVariantID: String?

    // Messages have their own append-only files and are never encoded into thread.json.
    var messages: [FeedbackMessage] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, objective, state, createdAt, updatedAt, requester, owner
        case scenario, surfaceRevision, queueSequence, lastSequence, lastHumanSequence
        case lastConsumedSequence, revision, eventSequence, messageIDs, messageIdempotency, delivery
        case activeComparisonID, activeVariantID
    }
}

enum FeedbackThreadStore {
    static let rootName = "feedback-threads"

    static var rootURL: URL {
        ensureDirectory(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(rootName, isDirectory: true))
    }

    static var eventLogURL: URL { rootURL.appendingPathComponent("events.jsonl") }

    static func loadAll() -> [FeedbackThread] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return directories.compactMap { directory in
            let threadURL = directory.appendingPathComponent("thread.json")
            guard let data = try? Data(contentsOf: threadURL),
                  var value = try? decoder.decode(FeedbackThread.self, from: data) else { return nil }
            value.messages = loadMessages(feedbackThreadID: value.id)
            return value
        }.sorted { ($0.queueSequence, $0.id) < ($1.queueSequence, $1.id) }
    }

    static func save(_ feedbackThread: FeedbackThread) throws {
        let directory = feedbackThreadDirectory(feedbackThread.id)
        let url = directory.appendingPathComponent("thread.json")
        // Preserve backend-owned fields that this Debug UI does not interpret.
        var merged = ((try? Data(contentsOf: url)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }) ?? [:]
        let encoded = try encoder.encode(feedbackThread)
        let known = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        merged.merge(known) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func appendMessage(_ message: FeedbackMessage, to feedbackThread: inout FeedbackThread) throws {
        let messagesURL = ensureDirectory(feedbackThreadDirectory(feedbackThread.id).appendingPathComponent("messages", isDirectory: true))
        let file = messagesURL.appendingPathComponent(String(format: "%06d.json", message.sequence))
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try encoder.encode(message).write(to: file, options: .atomic)
        do {
            feedbackThread.lastSequence = message.sequence
            if message.author == .human { feedbackThread.lastHumanSequence = message.sequence }
            feedbackThread.messageIDs.append(message.id)
            feedbackThread.messageIdempotency[message.idempotencyKey] = message.sequence
            feedbackThread.messages.append(message)
            feedbackThread.updatedAt = message.createdAt
            feedbackThread.revision += 1
            try save(feedbackThread)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    static func attachmentDirectory(feedbackThreadID: String) -> URL {
        ensureDirectory(feedbackThreadDirectory(feedbackThreadID).appendingPathComponent("attachments", isDirectory: true))
    }

    static func appendEvent(_ name: String, feedbackThreadID: String, values: [String: String] = [:]) {
        let sequenceKey = "feedback-thread-device-event-sequence"
        let defaults = UserDefaults.standard
        let sourceSequence = defaults.integer(forKey: sequenceKey) + 1
        defaults.set(sourceSequence, forKey: sequenceKey)
        var event: [String: Any] = values
        event["eventID"] = "device-event-\(UUID().uuidString.lowercased())"
        event["event"] = name
        event["feedbackThreadID"] = feedbackThreadID
        event["timestamp"] = ISO8601DateFormatter().string(from: Date())
        event["source"] = "device"
        event["sourceSequence"] = sourceSequence
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let line = String(data: data, encoding: .utf8),
              let bytes = (line + "\n").data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: eventLogURL.path) {
            try? bytes.write(to: eventLogURL, options: .atomic)
        } else if let handle = try? FileHandle(forWritingTo: eventLogURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        }
    }

    private static func feedbackThreadDirectory(_ id: String) -> URL {
        ensureDirectory(rootURL.appendingPathComponent(id, isDirectory: true))
    }

    private static func loadMessages(feedbackThreadID: String) -> [FeedbackMessage] {
        let url = feedbackThreadDirectory(feedbackThreadID).appendingPathComponent("messages", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap {
            guard let data = try? Data(contentsOf: $0), let message = try? decoder.decode(FeedbackMessage.self, from: data),
                  message.feedbackThreadID == feedbackThreadID else { return nil }
            return message
        }
    }

    private static var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }

    private static var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        return value
    }

    @discardableResult
    private static func ensureDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
#endif
