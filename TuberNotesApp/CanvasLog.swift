import Foundation
import os

/// Diagnostics for a system whose most important behavior cannot be tested by
/// any gate on the build machine.
///
/// Two sinks, because neither alone is enough on device:
///
/// - `Logger` writes to the unified log. It is the right sink for structured,
///   low-overhead logging and for the signposts G4's baseline will need, but
///   reading it back off a device requires root (`log collect --device-udid`)
///   or Console.app, so it cannot be part of an automated gate.
/// - stderr is captured live by `devicectl device process launch --console`,
///   which needs no privileges. This is what makes device behavior observable
///   from a script.
///
/// The stderr mirror is opt-in via the `TN_TRACE` environment variable and
/// compiled out of release builds, so an ordinary run pays nothing. Nothing
/// here may be called per Pencil sample, pan tick, or zoom tick: the coarse
/// drawing-change callback is the finest event this logs.
enum CanvasLog {
    private static let subsystem = "com.tubernotes.greenfield"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let canvas = Logger(subsystem: subsystem, category: "canvas")
    static let save = Logger(subsystem: subsystem, category: "save")
    static let contract = Logger(subsystem: subsystem, category: "contract")

    #if DEBUG
    private static let mirrorsToStderr = ProcessInfo.processInfo.environment["TN_TRACE"] != nil
    #else
    private static let mirrorsToStderr = false
    #endif

    /// One event, to both sinks. `category` names the `Logger` it belongs to.
    static func event(_ logger: Logger, _ category: StaticString, _ message: String) {
        logger.log("\(message, privacy: .public)")
        guard mirrorsToStderr else { return }
        // stderr only. This is a stream the launcher captures, not storage.
        fputs("TN[\(category)] \(message)\n", stderr)
    }

    /// Logs an uncaught Objective-C exception before the process dies.
    ///
    /// A crash report gives the stack but none of the app's own state, and
    /// UIKit exceptions surface with no app frames at all. This records the
    /// name, reason, and throw-time stack while the process is still alive.
    static func installCrashDiagnostics() {
        NSSetUncaughtExceptionHandler { exception in
            let frames = exception.callStackSymbols.prefix(24).joined(separator: "\n  ")
            let report = """
                UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "no reason")
                  \(frames)
                """
            CanvasLog.contract.fault("\(report, privacy: .public)")
            fputs("TN[fatal] \(report)\n", stderr)
        }
    }
}
