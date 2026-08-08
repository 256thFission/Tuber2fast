import PencilKit
import UIKit

/// The ink surface, with PencilKit's tap-raised context menu refused and its
/// lasso menu left alone.
///
/// Phillip's device verdict (2026-08-07): tapping an image raised a menu
/// offering **Select All** and **Insert Space**, which "does not make sense and
/// should probably be suppressed". It does not, because none of those actions
/// belongs to this application's model of a page — *Select All* selects ink
/// while this project's selection is one static layer, and *Insert Space*
/// reflows the drawing downward, which is the page growth `PageGeometry` records
/// as tried and removed.
///
/// ## What is actually attached, and which piece to take
///
/// The first attempt at this took the whole editing menu away, and Phillip
/// found the cost immediately: the lasso lost cut, copy and delete. That was a
/// real capability, working before this file existed. Printing PencilKit's own
/// hierarchy is what corrected the aim:
///
/// ```
/// InkCanvasView
///  └ PKTiledView  interactions=[UIEditMenuInteraction,
///                               _UIEditMenuBridgedContextMenuInteraction, …]
///     └ PKSelectionGestureView  interactions=[PKSelectionInteraction]
/// ```
///
/// Two separate things, and only one of them is the complaint:
///
/// - **`UIEditMenuInteraction`** is the *presenter*. PencilKit presents through
///   it when a lasso selection completes. Removing it removes the lasso menu —
///   which is what happened. **It stays.**
/// - **`_UIEditMenuBridgedContextMenuInteraction`** is what bridges that menu to
///   a *context-menu* gesture, which is the tap Phillip is complaining about.
///   **That is the one removed here.**
///
/// It is identified by type name, because it is not public. That is fragile in
/// exactly one direction, and the safe one: if a future PencilKit renames or
/// drops it, nothing is found, nothing is removed, and the tap menu comes back —
/// visible immediately, and never the lasso breaking silently. The count is
/// logged for that reason.
///
/// ## Why there is no `canPerformAction` override
///
/// There was one, returning `false` to everything, and it is gone. A hosted,
/// inked, first-responder `PKCanvasView` was measured answering `false` to
/// `selectAll:`, `paste:`, `copy:`, `cut:` and `delete:` *without* it, so it
/// bought nothing in the state that raised the menu — and a lasso selection is
/// precisely the state where a canvas would begin vending `cut:` and `copy:`,
/// which is the menu this file now exists to protect. An override that cannot
/// be shown to help and can be reasoned to hurt is not a belt.
final class InkCanvasView: PKCanvasView {
    /// The interaction that presents the editing menu as a tap-raised context
    /// menu. Not public, so named as a string; see the type's note for why that
    /// fragility is acceptable here and which way it fails.
    private static let contextMenuBridgeTypeName = "_UIEditMenuBridgedContextMenuInteraction"

    /// Removes the context-menu bridge from this view and every view inside it,
    /// and answers how many it found — for the log, and for a test.
    ///
    /// The recursion is the point: PencilKit installs it on a content view of
    /// its own, never on the canvas. Called when a page becomes the active one,
    /// which is a known moment off every frame path.
    @discardableResult
    func removeContextMenuBridge() -> Int {
        Self.removeContextMenuBridge(from: self)
    }

    private static func removeContextMenuBridge(from view: UIView) -> Int {
        var removed = 0
        for interaction in view.interactions
        where String(describing: type(of: interaction)) == contextMenuBridgeTypeName {
            view.removeInteraction(interaction)
            removed += 1
        }
        for subview in view.subviews {
            removed += removeContextMenuBridge(from: subview)
        }
        return removed
    }

    /// Whether an editing-menu presenter is still installed somewhere inside
    /// this canvas.
    ///
    /// Read by the test that pins the *other* half of this file's rule: the
    /// lasso's menu must survive whatever the removal above does. Nothing in
    /// the app branches on it.
    var hasEditMenuPresenter: Bool {
        Self.hasEditMenuPresenter(in: self)
    }

    private static func hasEditMenuPresenter(in view: UIView) -> Bool {
        if view.interactions.contains(where: { $0 is UIEditMenuInteraction }) { return true }
        return view.subviews.contains { hasEditMenuPresenter(in: $0) }
    }

    /// What is actually attached to this canvas, once per session.
    ///
    /// A diagnostic, not a mechanism — and the one that corrected this file's
    /// aim after the first attempt removed too much. It runs once, off any frame
    /// path, and the next time PencilKit's hierarchy changes shape it is what
    /// says so.
    func describeMenuMachinery() -> String {
        var lines: [String] = []
        func walk(_ view: UIView, depth: Int) {
            let interactions = view.interactions.map { String(describing: type(of: $0)) }
            let gestures = (view.gestureRecognizers ?? []).map { String(describing: type(of: $0)) }
            if !interactions.isEmpty || !gestures.isEmpty {
                lines.append(
                    "\(String(repeating: "·", count: depth))\(type(of: view)) "
                        + "interactions=[\(interactions.joined(separator: ","))] "
                        + "gestures=[\(gestures.joined(separator: ","))]"
                )
            }
            for subview in view.subviews { walk(subview, depth: depth + 1) }
        }
        walk(self, depth: 0)
        return lines.joined(separator: " | ")
    }
}
