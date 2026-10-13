import Foundation
import TNCore
import TNLibrary

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

/// The hooks that take a value, parsed once: what the theme screenshot
/// driver opens each shot on. `-TNTheme` is read by `Workspace.launchChoice`,
/// beside the preference it overrides.
///
/// One sheet per launch, because two presented in one frame do not both
/// show. A value no case has is logged and ignored, as `-TNTheme`'s is.
struct LaunchScene: Equatable {
    enum Sheet: String {
        case settings, export, addPage, paper, navigator, linkTarget
    }

    enum Dialog: String {
        case insert
    }

    /// `-TNSheet <name>`.
    var sheet: Sheet?
    /// `-TNLibrary documents|trash`.
    var section: LibrarySection?
    /// `-TNLayout grid|list`, shown without being saved.
    var layout: LibraryLayout?
    /// `-TNDialog insert`.
    var dialog: Dialog?
    /// `-TNTray`: the colour tray open on the first swatch.
    var tray = false
    /// `-TNSeed`: the library `Workspace.seed` builds.
    var seed = false

    /// Empty in Release, where `LaunchHooks.arguments` is.
    static let current = LaunchScene(LaunchHooks.arguments)

    init(_ arguments: [String]) {
        func value<T>(_ flag: String, _ parse: (String) -> T?) -> T? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            let raw = arguments[index + 1]
            guard let parsed = parse(raw) else {
                TNLog.event(.lifecycle, "\(flag) names nothing it opens: \(raw)")
                return nil
            }
            return parsed
        }
        sheet = value("-TNSheet", Sheet.init(rawValue:))
        section = value("-TNLibrary") { ["documents": .documents, "trash": .trash][$0] }
        layout = value("-TNLayout", LibraryLayout.init(rawValue:))
        dialog = value("-TNDialog", Dialog.init(rawValue:))
        tray = arguments.contains("-TNTray")
        seed = arguments.contains("-TNSeed")
    }

    /// Whether the shot is of the editor rather than the library.
    var opensEditor: Bool {
        tray || dialog != nil || (sheet != nil && sheet != .settings)
    }
}
