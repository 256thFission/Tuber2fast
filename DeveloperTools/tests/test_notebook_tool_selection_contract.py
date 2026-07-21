import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLBAR = REPO_ROOT / "TuberNotes/Notebook/NotebookToolbar.swift"
NOTEBOOK_VIEW = REPO_ROOT / "TuberNotes/Notebook/NotebookView.swift"
REFINEMENT_OVERLAY = REPO_ROOT / "TuberNotes/SpatialCanvas/DrawingRefinementOverlay.swift"


class NotebookToolSelectionContractTests(unittest.TestCase):
    def test_tool_buttons_keep_tap_selection_and_priority_width_hold(self):
        source = TOOLBAR.read_text()
        tool_button = source[
            source.index("private func toolButton"):
            source.index("private var lassoButton")
        ]

        self.assertIn("Button {\n            activateToolbarTool(tool)", tool_button)
        self.assertIn(
            ".highPriorityGesture(widthAdjustmentGesture(for: tool))",
            tool_button,
        )
        self.assertIn(
            "TapGesture().onEnded { _ in activateToolbarTool(tool) }",
            tool_button,
        )
        self.assertIn("vm.selectTool(tool)", tool_button)

    def test_refinement_lasso_bubble_is_anchored_to_magic_lasso_button(self):
        toolbar = TOOLBAR.read_text()
        notebook_view = NOTEBOOK_VIEW.read_text()
        refinement_overlay = REFINEMENT_OVERLAY.read_text()

        self.assertIn(
            ".anchorPreference(key: RefinementButtonBoundsPreferenceKey.self, value: .bounds)",
            toolbar,
        )
        self.assertIn(
            ".overlayPreferenceValue(RefinementButtonBoundsPreferenceKey.self)",
            toolbar,
        )
        self.assertIn("x: buttonFrame.midX", toolbar)
        self.assertIn("y: buttonFrame.minY - 30", toolbar)
        self.assertIn("private var refinementLassoBubble", toolbar)
        self.assertIn('accessibilityIdentifier("ai-lasso-button")', toolbar)
        self.assertIn("isLassoActive: $isRefinementLassoActive", notebook_view)
        self.assertIn("@Binding var isLassoActive: Bool", refinement_overlay)
        self.assertNotIn("private var controls", refinement_overlay)


if __name__ == "__main__":
    unittest.main()
