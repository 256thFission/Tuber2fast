import PencilKit
import UIKit

/// The ink surface, with PencilKit's editing menu refused.
///
/// A `PKCanvasView` that is first responder vends the standard editing actions —
/// **Select All**, **Insert Space**, **Paste** — and a finger tap raises a menu
/// offering them. Phillip's device verdict (2026-08-07): tapping an image
/// brought up that menu, which "does not make sense and should probably be
/// suppressed". It does not make sense because none of those actions belongs to
/// this application's model of a page:
///
/// - *Select All* selects **ink**, and this project's selection is a
///   `LayerSelectionRuntime` selection of one static layer. Two selections with
///   one visible chrome is the invalid state, not the menu.
/// - *Insert Space* reflows the drawing downward, which is page growth by
///   another name — `PageGeometry` records that downward growth was tried and
///   removed deliberately.
/// - *Paste* has no defined meaning here: nothing in this build ever puts ink
///   or a layer on the pasteboard, so the item is either inert or a route into
///   a durable state no owner authored.
///
/// **The canvas cannot simply stop being first responder**: `PKToolPicker`
/// shows itself *for* a first responder, so resigning would take the tool
/// picker with it. The menu is therefore refused at the responder, which is the
/// supported place to refuse it, and the refusal is total — this canvas vends
/// no editing actions at all. When undo, copy, or paste do get a defined
/// meaning here, this is the one place that has to change, and it will fail
/// loudly by doing nothing rather than quietly by doing the wrong thing.
///
/// ## Which half of this actually does the work — measured, not assumed
///
/// **The interaction is the mechanism; the responder override is a belt whose
/// effect is unproven.** A `PKCanvasView` hosted in a key window, carrying ink,
/// and first responder answers `false` to `selectAll:`, `paste:`, `copy:`,
/// `cut:` and `delete:` *without* any override — `InkCanvasViewTests` asserts
/// exactly that, and it passes with the override removed. So the menu is not
/// built from actions this responder vends; it is presented by a
/// `UIEditMenuInteraction` PencilKit installs on a view inside the canvas,
/// which `removeEditMenuInteractions` finds (one, every time — the test and the
/// device log agree).
///
/// `canPerformAction` stays anyway, and its keep-reason is narrow: *Insert
/// Space* is not a public selector, so nothing here can name it to test it, and
/// a responder declining actions is the supported way to decline them. It costs
/// one method. It is not evidence of anything, and this note is here so nobody
/// later mistakes it for the fix.
///
/// KNOWN CONSEQUENCE: PencilKit's **lasso** selection menu — cut, copy, delete,
/// duplicate on a lassoed set of strokes — is very likely presented by the same
/// interaction, so removing it removes that too. Nothing here can tell the two
/// apart: they are one interaction, and the tap menu is the one Phillip asked to
/// lose. Which matters more is a device verdict, and it is an easy one to take —
/// lasso some ink and see whether a menu appears.
final class InkCanvasView: PKCanvasView {
    /// No editing action is available on this canvas — see the type's note,
    /// including why this is a belt rather than the mechanism.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    /// An editing-menu interaction is refused at installation rather than
    /// removed afterwards: removal races whatever added it, refusal does not.
    override func addInteraction(_ interaction: any UIInteraction) {
        if interaction is UIEditMenuInteraction {
            CanvasLog.event(.canvas, "refused a UIEditMenuInteraction on the ink canvas")
            return
        }
        super.addInteraction(interaction)
    }

    /// Removes any editing-menu interaction already installed on this view or
    /// on a view inside it, and answers what it found — for the log, and for a
    /// test.
    ///
    /// The recursion is the point: `addInteraction` above catches only the ones
    /// added to the canvas itself, and PencilKit's content views are its own.
    /// This is a sweep at a known moment (the page becoming active), not a
    /// policy — if the device log shows it removing something on every page,
    /// that is the signal that the refusal needs a different mechanism rather
    /// than a repeat sweep.
    @discardableResult
    func removeEditMenuInteractions() -> Int {
        Self.removeEditMenuInteractions(from: self)
    }

    private static func removeEditMenuInteractions(from view: UIView) -> Int {
        var removed = 0
        for interaction in view.interactions where interaction is UIEditMenuInteraction {
            view.removeInteraction(interaction)
            removed += 1
        }
        for subview in view.subviews {
            removed += removeEditMenuInteractions(from: subview)
        }
        return removed
    }

    /// What is actually attached to this canvas, once per session.
    ///
    /// A diagnostic, not a mechanism. The suppression above is a hypothesis
    /// about *where* the menu comes from; this is how the next device run tells
    /// us whether the hypothesis was right, without another round of guessing.
    /// It runs once, off any frame path.
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
