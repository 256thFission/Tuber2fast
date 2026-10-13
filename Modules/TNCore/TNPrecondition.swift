import Foundation

/// The one trap for programmer errors in the v2 modules.
///
/// Every "this cannot happen" in the contract routes through here. It logs a
/// violation at fault level, then calls `preconditionFailure`, in every
/// configuration. Under -O `preconditionFailure` drops its message, so the
/// reason survives only in that violation line. A trap cannot be observed
/// in-process on iOS, so no test reaches one.
package enum TNPrecondition {
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
        TNLog.violation(at: "\(file):\(line)", message)
        preconditionFailure(message, file: file, line: line)
    }
}
