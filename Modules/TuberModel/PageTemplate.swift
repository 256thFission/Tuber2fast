import Foundation

/// The paper a document is ruled with — a closed set of names, and nothing
/// more.
///
/// **A name and no measurements.** Spacing, colour, and margins are rendering
/// constants owned by the build that draws them, never durable: a stored
/// spacing number would be a second authority for one picture, and — until a
/// UI sets it — exactly the "field a shipped kind does not read" that
/// `Contract.md` — Forbidden patterns bans. Adding a member is a `CONTRACT:`
/// amendment, as adding a layer kind is.
///
/// **`blank` is a member rather than the absence of one.** An optional would
/// make "no paper" a second representation of a state this enum can already
/// name, and it would leave every render switch with a `nil` arm that is not a
/// case. With `blank` in the set the switch is exhaustive and the compiler
/// enforces that a new member is drawn somewhere.
///
/// **Not a layer**, and the argument is about which file the value lives in:
/// layers live in page files, which are read lazily one at a time, and
/// `EditorSession.warmNeighbourComposites` builds composites for the prefetch
/// window from what the *index* knows, before those pages' files have been
/// read. This is the same argument that put per-page geometry in the index —
/// see `PageRecord`.
package enum PageTemplate: String, Codable, Sendable, Equatable, CaseIterable {
    case blank, lined, grid, dotted
}
