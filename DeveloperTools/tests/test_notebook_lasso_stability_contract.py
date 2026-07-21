import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
NOTEBOOK_DIR = REPO_ROOT / "TuberNotes" / "Notebook"


class NotebookLassoStabilityContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.canvas = (NOTEBOOK_DIR / "NotebookCanvas.swift").read_text()
        cls.toolbar = (NOTEBOOK_DIR / "NotebookToolbar.swift").read_text()
        cls.view_model = (NOTEBOOK_DIR / "NotebookViewModel.swift").read_text()

    def test_mode_exit_clears_hidden_selection_state(self):
        self.assertIn("func toggleLasso()", self.view_model)
        self.assertIn("func activateLasso()", self.view_model)
        self.assertIn("func deactivateLasso(preservingSelection: Bool = false)", self.view_model)
        self.assertIn("if !preservingSelection { lassoRect = nil }", self.view_model)
        self.assertIn("vm.activateLasso()", self.toolbar)
        self.assertIn("vm.deactivateLasso()", self.toolbar)
        self.assertIn("vm.deactivateLasso(preservingSelection: true)", self.toolbar)
        self.assertNotIn("isLassoActive = true", self.toolbar)
        self.assertNotIn("isLassoActive = false", self.toolbar)
        self.assertIn("currentDrawingLayerID = id\n        deactivateLasso()", self.view_model)
        self.assertIn("currentDrawingLayerID = layer.id\n        deactivateLasso()", self.view_model)

    def test_degenerate_gesture_clears_model_and_overlay(self):
        complete_lasso = self.canvas.split("func completeLasso", 1)[1].split(
            "func beginMove", 1
        )[0]
        self.assertIn("parent.onLassoChanged(nil)", complete_lasso)
        self.assertIn("view?.lassoView.clear()", complete_lasso)
        self.assertIn("view.lassoView.clear()", complete_lasso)

    def test_active_in_progress_loop_survives_parent_view_updates(self):
        self.assertIn("if !isLassoActive {", self.canvas)
        self.assertNotIn("if !isLassoActive || lassoRect == nil", self.canvas)

    def test_short_tap_survives_lasso_hold_gesture(self):
        lasso_button = self.toolbar.split("private var lassoButton", 1)[1].split(
            "private var lassoHoldGesture", 1
        )[0]
        self.assertIn(".highPriorityGesture(lassoHoldGesture)", lasso_button)
        self.assertIn(".simultaneousGesture(", lasso_button)
        self.assertIn("TapGesture().onEnded { _ in activateLassoTool() }", lasso_button)
        self.assertIn("private func activateLassoTool()", lasso_button)

    def test_selection_and_move_stay_inside_logical_page(self):
        self.assertIn(
            ".intersection(CGRect(origin: .zero, size: NotebookPageLayout.size))",
            self.canvas,
        )
        self.assertIn("let delta = clampedMoveDelta(proposedDelta", self.canvas)
        self.assertIn("let minX = bounds.minX - rect.minX", self.canvas)
        self.assertIn("let maxX = bounds.maxX - rect.maxX", self.canvas)
        self.assertIn("let minY = bounds.minY - rect.minY", self.canvas)
        self.assertIn("let maxY = bounds.maxY - rect.maxY", self.canvas)
        self.assertIn(
            "view.lassoView.isUserInteractionEnabled = isLassoActive && !isPageLocked",
            self.canvas,
        )

    def test_cancelled_loop_and_move_do_not_commit_partial_work(self):
        self.assertIn("view.lassoView.onMoveCancelled", self.canvas)
        self.assertIn("func cancelMove(_ view: ZoomablePageView?)", self.canvas)
        self.assertIn("view.canvasView.drawing = drawingBeforeMove", self.canvas)
        self.assertIn("case .cancelled, .failed:", self.canvas)
        self.assertIn("onMoveCancelled?()", self.canvas)
        self.assertIn("onLoopComplete?([])", self.canvas)
        clear_body = self.canvas.split("func clear()", 1)[1].split(
            "private func startMarching", 1
        )[0]
        self.assertIn("if activeMode == .move", clear_body)
        self.assertIn("onMoveCancelled?()", clear_body)


if __name__ == "__main__":
    unittest.main()
