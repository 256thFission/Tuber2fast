import Foundation

/// The one file the app target is allowed to read. A document picked from
/// Files arrives as a security-scoped URL that only this process, only now,
/// may open; the bytes go straight to the notebook, which owns every other
/// byte of I/O.
enum ImportReader {
    static func read(url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }
}
