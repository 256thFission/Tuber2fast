import Foundation
import TNCore
import TNEditor

/// The palette's preferences, in `UserDefaults`.
///
/// This file writes preferences and never notebook or library state, and
/// that is the whole reason it may sit on `ContractStructureTests`'
/// `fileIOAllowlist`. The file I/O rule exists so durable document state has
/// one writer and a known write order; a preference has no integrity to
/// protect, no relationship to any other file, and losing it costs a tap.
struct ToolPaletteDefaults: ToolPaletteStore {
    /// One key for the whole record, matching `ToolPaletteRecord` being one
    /// value: a partial write can only lose the lot, which the built-in
    /// default covers.
    private static let key = "tn.toolPalette"

    // `UserDefaults` is thread-safe by documentation and unmarked in the
    // SDK, and the store protocol is `Sendable` because the palette holds
    // one. The unsafety is the SDK's annotation gap, not a shared mutable
    // value this file owns.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// `nil` when the key is absent or the bytes do not decode, so a
    /// hand-edited preference opens on the built-in default. Nothing is
    /// corrected in place: half a record read back is a palette that
    /// disagrees with itself about which tool is in hand.
    func load() -> ToolPaletteRecord? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? PropertyListDecoder().decode(ToolPaletteRecord.self, from: data)
    }

    func save(_ record: ToolPaletteRecord) {
        do {
            defaults.set(try PropertyListEncoder().encode(record), forKey: Self.key)
        } catch {
            // Enums, four bytes, and a dictionary whose keys are a closed
            // set cannot fail to encode, so one that did is a programmer
            // error. Dropping the write instead would be a preference that
            // forgets without ever saying so.
            TNPrecondition.fail("the tool palette could not be encoded: \(error)")
        }
    }
}
