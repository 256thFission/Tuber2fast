import Foundation
import TNCore
import TNEditor
import TNLibrary

/// One preference in `UserDefaults`: one `Codable` value under one key.
///
/// This file writes preferences and never notebook or library state, and
/// that is the whole reason it may sit on `ContractStructureTests`'
/// `fileIOAllowlist`. The file I/O rule exists so durable document state has
/// one writer and a known write order; a preference has no integrity to
/// protect, no relationship to any other file, and losing it costs a tap.
/// `Docs/Contract.md`, *A preference is one value under one key*.
struct PreferenceDefaults<Value: Codable>: Sendable {
    private let key: String

    // `UserDefaults` is thread-safe by documentation and unmarked in the
    // SDK, and the store protocols are `Sendable` because their owners hold
    // one. The unsafety is the SDK's annotation gap, not a shared mutable
    // value this type owns.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(key: String, _ defaults: UserDefaults) {
        self.key = key
        self.defaults = defaults
    }

    /// `nil` when the key is absent or the bytes do not decode, so a
    /// hand-edited preference opens on its built-in default. Nothing is
    /// corrected in place: half a value read back disagrees with itself.
    func load() -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? PropertyListDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        do {
            defaults.set(try PropertyListEncoder().encode(value), forKey: key)
        } catch {
            // Every preference is enums, numbers, strings and maps over
            // closed sets, none of which can fail to encode, so one that did
            // is a programmer error. Dropping the write instead would be a
            // preference that forgets without ever saying so.
            TNPrecondition.fail("the preference \(key) could not be encoded: \(error)")
        }
    }
}

extension PreferenceDefaults: ToolPaletteStore where Value == ToolPaletteRecord {}
extension PreferenceDefaults: LibraryViewOptionsStore where Value == LibraryViewOptions {}
