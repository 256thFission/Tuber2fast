import Foundation
import os

/// Structured logging for the v2 modules. One `Logger` per stream; the
/// stream name is the category, so a call site cannot pick a logger the
/// category disagrees with.
///
/// Nothing here may run per Pencil sample, pan tick, or zoom tick. The
/// drawing-change report is the finest event that logs.
package enum TNLog {
    private static let subsystem = "com.tubernotes.v2"

    package enum Category: String {
        case format, notebook, library, canvas, lifecycle, contract

        fileprivate var logger: Logger {
            switch self {
            case .format: TNLog.format
            case .notebook: TNLog.notebook
            case .library: TNLog.library
            case .canvas: TNLog.canvas
            case .lifecycle: TNLog.lifecycle
            case .contract: TNLog.contract
            }
        }
    }

    private static let format = Logger(subsystem: subsystem, category: "format")
    private static let notebook = Logger(subsystem: subsystem, category: "notebook")
    private static let library = Logger(subsystem: subsystem, category: "library")
    private static let canvas = Logger(subsystem: subsystem, category: "canvas")
    private static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    private static let contract = Logger(subsystem: subsystem, category: "contract")

    /// `TN_TRACE` present in the environment mirrors every event to stderr,
    /// which is what the device capture scripts read. Presence, not value.
    private static let mirrorsToStderr = ProcessInfo.processInfo.environment["TN_TRACE"] != nil

    package static func event(_ category: Category, _ message: String) {
        category.logger.log("\(message, privacy: .public)")
        guard mirrorsToStderr else { return }
        fputs("TN[\(category.rawValue)] \(message)\n", stderr)
    }

    /// A contract violation that must not be silent in Release. Logged at
    /// fault level under the `contract` stream, and mirrored.
    package static func violation(_ message: String) {
        contract.fault("\(message, privacy: .public)")
        fputs("TN[violation] \(message)\n", stderr)
    }
}
