import Foundation

/// The sole writer of the saved canvas file (`DataContract.md` §2, §4).
///
/// It is an actor so that encoding and disk I/O are off the main actor by
/// construction rather than by discipline, and so two saves can never interleave.
/// This is the one actor the contract permits beyond the main actor.
///
/// The store never reaches into the canvas. It receives a complete immutable
/// value and returns only after that value is durable.
actor DocumentStore {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `nil` means no file exists — a first launch, not an error.
    ///
    /// A decode error, unsupported version, or invalid geometry throws, and the
    /// source file is left exactly as it was. A damaged document is never
    /// silently replaced with a blank one.
    func load() throws -> CanvasFile? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }

        do {
            let decoded = try PropertyListDecoder().decode(CanvasFile.self, from: data)
            return try decoded.validated()
        } catch {
            // A refusal to open a document is the most alarming thing this type
            // can do, so it says exactly what it read. Without the path and the
            // leading bytes, an unreadable file is indistinguishable from a bug
            // in the reader.
            let prefix = data.prefix(8).map { String(format: "%02x", $0) }.joined()
            CanvasLog.event(
                CanvasLog.save, "save",
                "refusing to open \(fileURL.path): \(data.count) bytes, starts \(prefix), error \(error)"
            )
            throw error
        }
    }

    /// Encodes a complete file and atomically replaces the one prior file.
    ///
    /// Returns only after the replacement succeeds. If the process ends during a
    /// save that never returned, the next launch finds either the prior or the
    /// new complete file — `.atomic` writes to a temporary file and renames, so
    /// there is no window in which a partial file is visible at `fileURL`.
    func save(_ file: CanvasFile) throws {
        let validated = try file.validated()

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(validated)

        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        try data.write(to: fileURL, options: .atomic)
    }
}

extension DocumentStore {
    /// The one document of this milestone. A later multi-document milestone owns
    /// naming; this is deliberately a fixed path, not a scheme.
    static func defaultFileURL() throws -> URL {
        try FileManager.default
            .url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("JustACanvas.canvas")
    }
}
