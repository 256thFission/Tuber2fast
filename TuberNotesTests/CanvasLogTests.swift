import Foundation
import Testing

@testable import TuberNotes

/// The trace sink's gate and its wire format.
///
/// Neither half is observable from a simulator run — nothing here delivers a
/// Pencil sample, and the tests run in Debug while the build that ships is
/// Release. What *is* checkable is the shape of the decision: that the gate is
/// `TN_TRACE` and nothing else, that no configuration check has grown back
/// around the mirror, and that the bytes the app writes are the bytes
/// `Tools/device` greps for. The rest is device evidence.
@Suite("Canvas log")
struct CanvasLogTests {

    // MARK: - The gate

    @Test("An environment without TN_TRACE leaves the stderr mirror off")
    func mirrorIsOffWithoutTheVariable() {
        #expect(CanvasLog.stderrMirrorIsEnabled(in: [:]) == false)
        #expect(CanvasLog.stderrMirrorIsEnabled(in: ["HOME": "/var/mobile"]) == false)
        // Near misses. A prefix match here would turn the mirror on for a
        // variable nobody set.
        #expect(CanvasLog.stderrMirrorIsEnabled(in: ["TN_TRACE_LEVEL": "1"]) == false)
        #expect(CanvasLog.stderrMirrorIsEnabled(in: ["tn_trace": "1"]) == false)
    }

    @Test("TN_TRACE turns the mirror on by presence, whatever its value")
    func mirrorIsOnByPresence() {
        #expect(CanvasLog.stderrMirrorIsEnabled(in: ["TN_TRACE": "1"]))
        // Presence, not truthiness. Someone who typed the variable at all wants
        // the trace, and a launcher that spells "on" as an empty string must not
        // silently produce a capture the digest then calls NO TRACE CAPTURED.
        #expect(CanvasLog.stderrMirrorIsEnabled(in: ["TN_TRACE": ""]))
        #expect(CanvasLog.stderrMirrorIsEnabled(in: ["TN_TRACE": "0"]))
    }

    // MARK: - The wire format

    /// `Tools/device`'s digest decides a capture is non-empty by grepping for
    /// `TN[`, brackets the app's own fatal with `TN[fatal]`, and reads the
    /// stream a line at a time. Each of those is an assumption about this
    /// string, held here so the two cannot drift apart silently.
    @Test("A mirrored line is the line Tools/device greps for")
    func mirroredLineMatchesTheDigest() {
        let line = CanvasLog.stderrLine(CanvasLog.Category.canvas.rawValue, "first touch reached the canvas")
        #expect(line == "TN[canvas] first touch reached the canvas\n")
        #expect(line.hasPrefix("TN["))
        #expect(line.hasSuffix("\n"))

        // The crash handler's bracket, which the digest counts separately from
        // a Swift trap.
        #expect(CanvasLog.stderrLine(CanvasLog.fatalLabel, "UNCAUGHT").hasPrefix("TN[fatal] "))

        // Every category is bracketed with its own name, so the two sinks
        // cannot disagree about which stream an event belongs to.
        for category in [CanvasLog.Category.lifecycle, .canvas, .save, .contract] {
            #expect(CanvasLog.stderrLine(category.rawValue, "x") == "TN[\(category.rawValue)] x\n")
        }
    }

    // MARK: - No configuration check around the mirror

    /// The regression this file exists for: the mirror was wrapped in
    /// `#if DEBUG` while every distributed build is `-configuration Release`,
    /// so the only sink readable without a Mac was compiled out of the only
    /// build most contributors ever hold.
    ///
    /// A Debug test run cannot observe a Release binary, so this is checked
    /// structurally — the same technique, and the same comment-stripping
    /// checker, `ContractChecker` uses. Reading the source is the only
    /// way this specific mistake is catchable at all from CI.
    @Test("CanvasLog carries no build-configuration check")
    func theMirrorIsNotCompiledOutOfRelease() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TuberNotesApp/CanvasLog.swift")

        let code = ContractChecker.codeOnly(try String(contentsOf: source, encoding: .utf8))

        #expect(
            !code.contains("#if"),
            """
            CanvasLog is conditionally compiled again. Every distributed build is \
            -configuration Release; a trace path Debug alone carries has never run in \
            the build that ships, and TN_TRACE is already the gate.
            """
        )
        // Ties the function the tests above exercise to the flag the shipping
        // code actually reads. Checked against comment-stripped code, which is
        // also why the variable's own name cannot be asserted here: `codeOnly`
        // removes string literals, and `"TN_TRACE"` is one.
        #expect(
            code.contains("stderrMirrorIsEnabled(in: ProcessInfo.processInfo.environment)"),
            """
            the cached mirror flag is no longer initialized from stderrMirrorIsEnabled, \
            so the gate these tests exercise is not the gate the app runs.
            """
        )
    }
}
