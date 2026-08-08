import Foundation
import PencilKit
import TuberCore

/// A copied, immutable snapshot of a PencilKit drawing.
///
/// In the iOS 26 SDK, `PKDrawing` is a `Sendable` value. Reading the canvas
/// property takes a value snapshot on the main actor; the value can then cross
/// to a utility task with compiler-checked transfer safety. The long-term page
/// store still replaces whole-drawing serialization with a measured,
/// page-bounded persistence boundary.
package struct DrawingSnapshot: Sendable {
    private let drawing: PKDrawing

    @MainActor
    package init(drawing: PKDrawing) {
        self.drawing = drawing
    }

    /// The copied drawing, for rebuilding a canvas from ink that never reached
    /// disk.
    ///
    /// Main actor only, and no encoding: this hands back the same value `init`
    /// copied. A page that retired dirty and then returns to the live window is
    /// rebuilt from this rather than from the last bytes that were saved, which
    /// is what stops a fast turn away and back from restoring pre-edit ink
    /// (`Contract.md` — Owners, golden rule 5: custody, not a second copy).
    @MainActor
    package var drawingValue: PKDrawing { drawing }

    /// Serializes off the main actor and reports how long it took.
    ///
    /// The duration is returned rather than only logged because `EditorSession`
    /// derives the autosave debounce from it (`Contract.md` — Saving): the cost of
    /// a whole-drawing serialization is only knowable here, and measuring it a
    /// second time on the session side would mean serializing twice.
    ///
    /// `Task.detached` rather than a bare `nonisolated` call, for both of the
    /// reasons `CONTRIBUTING.md` — Getting off the main actor allows: it fixes
    /// the priority at `.utility`, and a detached task inherits no
    /// cancellation, which is what this path wants. These are the bytes of a
    /// save already in progress — protected work, and uncancellable here by
    /// construction rather than by anyone remembering.
    package func serialized() async -> (data: Data, duration: Duration) {
        await Task.detached(priority: .utility) { [self] in
            let clock = ContinuousClock()
            let started = clock.now
            let data = drawing.dataRepresentation()
            let duration = started.duration(to: clock.now)
            // `Thread.isMainThread` is unavailable from an async context, and
            // the point of this field is to prove that this work is off main —
            // so it is read from a synchronous closure, which is a legal
            // context for it. Dropping the field would drop the evidence.
            let onMainThread = { Thread.isMainThread }()
            CanvasLog.event(
                .save,
                "serialized drawing snapshot; bytes=\(data.count) "
                    + "duration=\(duration) "
                    + "mainThread=\(onMainThread)"
            )
            return (data, duration)
        }.value
    }
}
