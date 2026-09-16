import Foundation
import TNCore
import TNModel

/// The chosen theme, in `UserDefaults`.
///
/// A preference, on `ToolPaletteDefaults`' reasoning: it writes no notebook
/// and no library state, which is why it may sit on
/// `ContractStructureTests`' `fileIOAllowlist`. Losing it costs the app one
/// launch in the wrong colours and a tap to put it back.
struct ThemeDefaults {
    /// One key for the whole choice, which is one value.
    private static let key = "tn.theme"

    // `UserDefaults` is thread-safe by documentation and unmarked in the
    // SDK. The unsafety is the annotation gap, not a value this file shares.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// `nil` when the key is absent, when the bytes do not decode, or when
    /// the id names a theme this build has no row for.
    ///
    /// That last one is why an unknown id is an answer here and a trap
    /// anywhere else: a preference is external data, and a build that ships
    /// fewer themes than the one that wrote it opens on the system's own
    /// light and dark rather than refusing to draw.
    func load() -> ThemeChoice? {
        guard let data = defaults.data(forKey: Self.key),
              let choice = try? PropertyListDecoder().decode(ThemeChoice.self, from: data)
        else { return nil }
        if case .preset(let id) = choice, Theme.preset(id) == nil { return nil }
        return choice
    }

    func save(_ choice: ThemeChoice) {
        do {
            defaults.set(try PropertyListEncoder().encode(choice), forKey: Self.key)
        } catch {
            // One enum over one string cannot fail to encode, so one that
            // did is a programmer error. Dropping the write instead would be
            // a preference that forgets without ever saying so.
            TNPrecondition.fail("the theme choice could not be encoded: \(error)")
        }
    }
}
