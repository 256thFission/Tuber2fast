import Foundation

/// The one file the app target is allowed to read. A document picked from
/// Files arrives as a security-scoped URL that only this process, only now,
/// may open; the bytes go straight to the notebook, which owns every other
/// byte of I/O.
enum ImportReader {
    static func read(url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Mapped where the volume allows it, so a 256 MB PDF is not 256 MB of
        // heap on its way to the store; the mapping outlives the scope.
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
