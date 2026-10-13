import Foundation
import TNCore
import TNModel

/// The undo manager the runtime hands to the responder chain: it registers
/// nothing and it undoes nothing itself.
///
/// Undo is the notebook's (D1): one notebook-wide stack of ink *values*, one
/// entry per tool-use session, an undo restoring the page it happened on
/// whichever page is current. A per-canvas undo stack would be a second
/// authority over the same ink — the one-writer rule's exact failure — and it
/// would die every time a page left the window, which is the state D1 exists to
/// avoid. So every registration PencilKit makes is dropped on the floor, and
/// every route that reaches a responder's undo manager (the three-finger
/// gestures, the shake, the edit menu, a toolbar button wired to the chain) is
/// forwarded up as an intention.
///
/// `canUndo` and `canRedo` are told, not computed: the binding knows the depth
/// of the notebook's stack and states it through
/// `PagedCanvasController.setUndoAvailability(canUndo:canRedo:)`. A
/// manager with no registrations would otherwise answer `false` to both and the
/// system gesture would be inert.
///
/// The runtime holds one and answers `undoManager` with it, so every view
/// under every canvas finds it on the chain;
/// `everyPencilKitViewAnswersWithTheFilter` proves that in the simulator.
/// Whether the system gesture takes that route on a device is owed to the iPad
/// session (`Docs/Unproven.md`). A registration that slips past the overrides
/// below, such as one made with `prepare(withInvocationTarget:)`, holds at
/// most one group, and nothing ever runs it.
package final class FilteringUndoManager: UndoManager {
    /// The seam's reporter, unowned for the same reason the runtime holds it
    /// unowned: the binding owns both and outlives them.
    private unowned let reporter: any CanvasReporting
    private var undoAvailable = false
    private var redoAvailable = false

    package init(reporter: any CanvasReporting) {
        self.reporter = reporter
        super.init()
        // Nothing is grouped because nothing is registered; stating it keeps a
        // future reader from reading the default as a decision.
        groupsByEvent = false
        // What slips past the overrides holds one group, never a history.
        levelsOfUndo = 1
    }

    /// Told by the binding, which owns the notebook's stack.
    @MainActor package func setAvailability(canUndo: Bool, canRedo: Bool) {
        undoAvailable = canUndo
        redoAvailable = canRedo
    }

    // MARK: - Registrations, dropped

    package override func registerUndo(
        withTarget target: Any,
        selector: Selector,
        object anObject: Any?
    ) {}

    /// The closure form. Swift's `registerUndo(withTarget:handler:)` is an
    /// overlay extension and cannot be overridden; it forwards to this, the
    /// refined import of `registerUndoWithTarget:handler:`, which can. That is
    /// why the generic spelling is absent here: overriding it is impossible,
    /// and this is the method it ends up calling.
    package override func __registerUndoWithTarget(
        _ target: Any,
        handler undoHandler: @escaping @MainActor @Sendable (Any) -> Void
    ) {}

    // MARK: - Availability, told

    package override var canUndo: Bool { undoAvailable }
    package override var canRedo: Bool { redoAvailable }

    // MARK: - The gestures, forwarded

    /// `undo()` and `redo()` are `UndoManager`'s, which is not actor-isolated,
    /// and the reports they make are the main actor's. They are called by UIKit
    /// from the responder chain, on the main thread, and `assumeIsolated`
    /// states that rather than hopping — a hop would deliver the intention in a
    /// later turn, after the gesture that meant it.
    package override func undo() {
        MainActor.assumeIsolated {
            TNLog.event(.canvas, "undo gesture reached the runtime")
            reporter.undoRequested()
        }
    }

    package override func redo() {
        MainActor.assumeIsolated {
            TNLog.event(.canvas, "redo gesture reached the runtime")
            reporter.redoRequested()
        }
    }

    /// Another way in to the same intention; `super` would run the stack.
    package override func undoNestedGroup() { undo() }
}
