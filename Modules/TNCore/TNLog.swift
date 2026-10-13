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
        case format, notebook, library, canvas, gesture, lifecycle, contract
    }

    /// `TN_TRACE` present in the environment mirrors every event to stderr,
    /// which is what the device capture scripts read. Presence, not value.
    private static let mirrorsToStderr = ProcessInfo.processInfo.environment["TN_TRACE"] != nil

    /// The text is private in the unified log: a message can carry a file
    /// path, and a path names the person's folders and notebooks. The stderr
    /// mirror is not redacted.
    package static func event(_ category: Category, _ message: @autoclosure () -> String) {
        let text = message()
        Logger(subsystem: subsystem, category: category.rawValue).log("\(text, privacy: .private)")
        guard mirrorsToStderr else { return }
        fputs("TN[\(category.rawValue)] \(text)\n", stderr)
    }

    /// A contract violation that must not be silent in Release. Logged at
    /// fault level under the `contract` stream, and mirrored. The location
    /// is public, so a Release trap still says where it happened in the
    /// unified log; the message is private, as an event's is.
    package static func violation(at location: String, _ message: String) {
        Logger(subsystem: subsystem, category: Category.contract.rawValue)
            .fault("\(location, privacy: .public) \(message, privacy: .private)")
        fputs("TN[violation] \(location) \(message)\n", stderr)
    }
}
