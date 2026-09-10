import Foundation

/// The one trap for programmer errors in the v2 modules.
///
/// Every "this cannot happen" in the contract routes through here so a test
/// can observe the trap instead of dying with it. In Release it is
/// `preconditionFailure`. In Debug the handler is swappable: a test installs
/// one that records the message and throws control back, then asserts on
/// what was recorded. The swap exists only in Debug, which is what keeps the
/// Release binary free of a hook nobody meant to ship.
package enum TNPrecondition {
    #if DEBUG
    /// The Debug-only handler. `nil` means trap, exactly as Release does.
    ///
    /// Not `…ForTesting`: it is a Debug facility, and the rule that test-only
    /// members live under `#if DEBUG` is satisfied by the block it sits in.
    nonisolated(unsafe) package static var debugHandler: (@Sendable (String) -> Void)?
    #endif

    package static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        if condition() { return }
        fail(message(), file: file, line: line)
    }

    package static func fail(
        _ message: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Never {
        TNLog.violation("\(file):\(line) \(message)")
        #if DEBUG
        if let debugHandler {
            debugHandler(message)
            // A handler that returns has chosen to observe rather than die.
            // The caller's control flow still needs a `Never`; a recorded
            // trap that continues would be a second, silent failure mode.
            // Tests that install a handler must not return from it on a
            // path they expect to continue; they unwind via an error or
            // never reach here twice.
            fatalError("TNPrecondition handler returned: \(message)")
        }
        #endif
        preconditionFailure(message, file: file, line: line)
    }
}
