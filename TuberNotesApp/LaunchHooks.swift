import Foundation

/// The process's launch arguments, which every `-TN…` hook reads: a
/// simulator run that opens on a theme, a sheet or a bar position needs no
/// taps to reach it, so a screenshot of it needs no hands.
///
/// Empty in Release. A hook is a developer's switch, written for one
/// screenshot and tested by none, and the build a person holds has no use
/// for one. `ContractStructureTests` keeps every read of the arguments here.
enum LaunchHooks {
    static var arguments: [String] {
        #if DEBUG
        ProcessInfo.processInfo.arguments
        #else
        []
        #endif
    }
}
