import Foundation

/// Bounded WHATWG-style SSE framing. It deliberately knows nothing about Responses events.
struct ResponsesSSEDecoder {
    enum Record {
        case payload([String: Any])
        case done
    }

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
    private let maximumLineBytes: Int
    private let maximumEventBytes: Int
    private let maximumStreamBytes: Int
    private let maximumRecords: Int
    private var startBytes: [UInt8] = []
    private var isAtStart = true
    private var pendingCarriageReturn = false
    private var line: [UInt8] = []
    private var dataLines: [[UInt8]] = []
    private var eventBytes = 0
    private var streamBytes = 0
    private var recordCount = 0
    private(set) var isTerminated = false

    init(
        maximumLineBytes: Int = 256 * 1_024,
        maximumEventBytes: Int = 1_024 * 1_024,
        maximumStreamBytes: Int = 4 * 1_024 * 1_024,
        maximumRecords: Int = 10_000
    ) {
        self.maximumLineBytes = maximumLineBytes
        self.maximumEventBytes = maximumEventBytes
        self.maximumStreamBytes = maximumStreamBytes
        self.maximumRecords = maximumRecords
    }

    static func payloads(from data: Data) throws -> [[String: Any]] {
        var decoder = ResponsesSSEDecoder()
        var payloads: [[String: Any]] = []
        for byte in data {
            for record in try decoder.feed(byte) {
                if case let .payload(payload) = record {
                    payloads.append(payload)
                }
            }
        }
        try decoder.finish()
        return payloads
    }

    mutating func feed(_ byte: UInt8) throws -> [Record] {
        guard !isTerminated else { return [] }
        streamBytes += 1
        guard streamBytes <= maximumStreamBytes else { throw DecodeError.streamTooLarge }

        if isAtStart {
            startBytes.append(byte)
            let expectedPrefix = Array(Self.byteOrderMark.prefix(startBytes.count))
            if startBytes == expectedPrefix, startBytes.count < Self.byteOrderMark.count { return [] }
            isAtStart = false
            if startBytes == Self.byteOrderMark {
                startBytes.removeAll(keepingCapacity: false)
                return []
            }
            let buffered = startBytes
            startBytes.removeAll(keepingCapacity: false)
            return try buffered.flatMap { try process($0) }
        }
        return try process(byte)
    }

    /// EOF does not dispatch a partially assembled event; a blank line or typed terminal is required.
    mutating func finish() throws {
        guard !isTerminated else { return }
        if isAtStart {
            isAtStart = false
            let buffered = startBytes
            startBytes.removeAll(keepingCapacity: false)
            for byte in buffered { _ = try process(byte) }
        }
        pendingCarriageReturn = false
        if !line.isEmpty {
            _ = try processLine()
        }
        dataLines.removeAll(keepingCapacity: false)
        eventBytes = 0
    }

    private mutating func process(_ byte: UInt8) throws -> [Record] {
        var records: [Record] = []
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            if byte == 0x0A { return records }
        }
        switch byte {
        case 0x0D:
            records += try processLine()
            pendingCarriageReturn = true
        case 0x0A:
            records += try processLine()
        default:
            line.append(byte)
            guard line.count <= maximumLineBytes else { throw DecodeError.lineTooLarge }
        }
        return records
    }

    private mutating func processLine() throws -> [Record] {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else { return try dispatchEvent() }
        guard line.first != 0x3A else { return [] } // comment

        let separator = line.firstIndex(of: 0x3A)
        let fieldBytes = separator.map { Array(line[..<$0]) } ?? line
        guard String(bytes: fieldBytes, encoding: .utf8) == "data" else { return [] }
        var value = separator.map { Array(line[line.index(after: $0)...]) } ?? []
        if value.first == 0x20 { value.removeFirst() }
        eventBytes += value.count + 1
        guard eventBytes <= maximumEventBytes else { throw DecodeError.eventTooLarge }
        dataLines.append(value)
        return []
    }

    private mutating func dispatchEvent() throws -> [Record] {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
        }
        guard !dataLines.isEmpty else { return [] }
        let data = dataLines.enumerated().flatMap { index, bytes in
            index == 0 ? bytes : [UInt8(0x0A)] + bytes
        }
        guard let value = String(bytes: data, encoding: .utf8) else { throw DecodeError.invalidUTF8 }
        if value == "[DONE]" {
            isTerminated = true
            return [.done]
        }
        guard let bytes = value.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw DecodeError.invalidJSON
        }
        recordCount += 1
        guard recordCount <= maximumRecords else { throw DecodeError.tooManyRecords }
        return [.payload(object)]
    }

    enum DecodeError: Error {
        case invalidUTF8
        case invalidJSON
        case lineTooLarge
        case eventTooLarge
        case streamTooLarge
        case tooManyRecords
    }
}

/// Extracts assistant text from either a complete Responses payload or its SSE events.
/// Provider bodies stay inside the transport boundary and are never embedded in errors.
enum ResponsesTextExtractor {
    static func text(from data: Data) throws -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = text(fromResponse: object) {
            return text
        }
        return text(from: try ResponsesSSEDecoder.payloads(from: data))
    }

    static func text(from payloads: [[String: Any]]) -> String? {
        var deltas = ""
        var doneText: String?
        var completedText: String?

        for payload in payloads {
            switch payload["type"] as? String {
            case "response.output_text.delta":
                if let delta = payload["delta"] as? String {
                    deltas += delta
                }
            case "response.output_text.done":
                if let text = payload["text"] as? String, !text.isEmpty {
                    doneText = text
                }
            case "response.completed", "response.incomplete":
                if let response = payload["response"] as? [String: Any] {
                    completedText = text(fromResponse: response)
                }
            default:
                break
            }
        }

        return [completedText, doneText, deltas.isEmpty ? nil : deltas]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }

    static func text(fromResponse response: [String: Any]) -> String? {
        if let text = response["output_text"] as? String, !text.isEmpty {
            return text
        }

        if let output = response["output"] as? [[String: Any]] {
            let pieces = output.flatMap { item -> [String] in
                guard let content = item["content"] as? [[String: Any]] else { return [] }
                return content.compactMap { part in
                    guard part["type"] as? String == "output_text" else { return nil }
                    return part["text"] as? String
                }
            }
            let joined = pieces.joined(separator: "\n")
            if !joined.isEmpty { return joined }
        }

        if let choices = response["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            return content
        }
        return nil
    }
}
