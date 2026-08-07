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
/// The stderr mirror is opt-in via the `TN_TRACE` environment variable and is
/// present in **every** configuration, Release included. It is deliberately not
/// wrapped in a configuration check: `device.yml` archives `-configuration
/// Release` and distributes that build to every registered iPad, so a mirror
/// only Debug carries is compiled out of the one build most contributors will
/// ever hold, and the loud path never runs in the build that ships. A launch
/// that does not set `TN_TRACE` pays one already-initialized `static let` read
/// and a branch per event — the environment is materialized at most once per
/// process, on the first event, never per event.
///
/// Nothing here may be called per Pencil sample, pan tick, or zoom tick: the
/// coarse drawing-change callback is the finest event this logs.
enum CanvasLog {
    private static let subsystem = "com.tubernotes.greenfield"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let canvas = Logger(subsystem: subsystem, category: "canvas")
    static let save = Logger(subsystem: subsystem, category: "save")
    static let contract = Logger(subsystem: subsystem, category: "contract")

    /// One name per event stream. The case is both the `Logger` and the
    /// stderr bracket label, so the two sinks cannot disagree at a call site.
    enum Category: String {
        case lifecycle, canvas, save, contract

        var logger: Logger {
            switch self {
            case .lifecycle: CanvasLog.lifecycle
            case .canvas: CanvasLog.canvas
            case .save: CanvasLog.save
            case .contract: CanvasLog.contract
            }
        }
    }

    /// The gate, as a function of an environment, so the rule can be stated
    /// once and tested without a process to set variables in.
    ///
    /// Presence, not value: `TN_TRACE=0` turns the mirror **on**. A person who
    /// typed the variable at all wants the trace, and a launcher that spells
    /// "off" as an empty string would otherwise silently produce nothing.
    static func stderrMirrorIsEnabled(in environment: [String: String]) -> Bool {
        environment["TN_TRACE"] != nil
    }

    /// Decided once per process. `static let` is initialized under `swift_once`,
    /// so `ProcessInfo.environment` — which materializes the whole environment
    /// dictionary — runs at most once, on the first event, and an event with the
    /// mirror off costs an atomic load and a branch.
    private static let mirrorsToStderr = stderrMirrorIsEnabled(in: ProcessInfo.processInfo.environment)

    /// The exact bytes the mirror writes.
    ///
    /// This format is an interface with `Tools/device`, whose digest decides a
    /// capture is non-empty by grepping for `TN[` and finds the app's own fatal
    /// by grepping for `TN[fatal]`. It is a function so a test can hold the
    /// emitter and that script's patterns against each other; if this string
    /// changes, that script changes with it.
    static func stderrLine(_ label: String, _ message: String) -> String {
        "TN[\(label)] \(message)\n"
    }

    /// The label the crash handler brackets with. Not a `Category`: it names a
    /// process about to die rather than a stream of events.
    static let fatalLabel = "fatal"

    /// One event, to both sinks.
    static func event(_ category: Category, _ message: String) {
        category.logger.log("\(message, privacy: .public)")
        guard mirrorsToStderr else { return }
        // stderr only. This is a stream the launcher captures, not storage.
        fputs(stderrLine(category.rawValue, message), stderr)
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
            // Ungated on purpose, unlike `event`: the process is dying, there is
            // no next launch to re-run with the variable set, and a console
            // that is being watched at all should be told.
            //
            // Every name here is spelled `CanvasLog.…` because this closure
            // becomes a C function pointer: an unqualified static reference
            // reads as a captured context and fails to compile.
            fputs(CanvasLog.stderrLine(CanvasLog.fatalLabel, report), stderr)
        }
    }
}
