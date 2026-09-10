import Foundation
import os

/// Structured logging for the v2 modules. The category string is the
/// enum's raw value, so a call site cannot pick a logger the category
/// disagrees with.
///
/// Nothing here may run per Pencil sample, pan tick, or zoom tick. The
/// drawing-change report is the finest event that logs.
package enum TNLog {
    private static let subsystem = "com.tubernotes.v2"

    package enum Category: String {
        case format, notebook, library, canvas, lifecycle, contract
    }

    /// `TN_TRACE` present in the environment mirrors every event to stderr,
    /// which is what the device capture scripts read. Presence, not value.
    private static let mirrorsToStderr = ProcessInfo.processInfo.environment["TN_TRACE"] != nil

    package static func event(_ category: Category, _ message: @autoclosure () -> String) {
        let text = message()
        Logger(subsystem: subsystem, category: category.rawValue).log("\(text, privacy: .public)")
        guard mirrorsToStderr else { return }
        fputs("TN[\(category.rawValue)] \(text)\n", stderr)
    }

    /// A contract violation that must not be silent in Release. Logged at
    /// fault level under the `contract` stream, and mirrored.
    package static func violation(_ message: String) {
        Logger(subsystem: subsystem, category: Category.contract.rawValue).fault("\(message, privacy: .public)")
        fputs("TN[violation] \(message)\n", stderr)
    }
}
