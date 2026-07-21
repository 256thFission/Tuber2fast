import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
NOTEBOOK_VIEW = REPO_ROOT / "TuberNotes/Notebook/NotebookView.swift"
TOOLBAR = REPO_ROOT / "TuberNotes/Notebook/NotebookToolbar.swift"
MAGIC_LASSO = REPO_ROOT / "TuberNotes/SpatialCanvas/MagicLasso.swift"


class MagicLassoPolishContractTests(unittest.TestCase):
    def test_regular_and_magic_lasso_controls_stay_separate(self):
        toolbar = TOOLBAR.read_text()
        view = NOTEBOOK_VIEW.read_text()

        self.assertIn('accessibilityIdentifier("tool-lasso")', toolbar)
        self.assertIn('accessibilityIdentifier("tool-magic-eraser")', toolbar)
        self.assertIn("private var lassoButton", toolbar)
        self.assertIn("private var refinementButton", toolbar)
        self.assertIn("MagicLassoOverlay(", view)

    def test_bottom_magic_lasso_menu_arms_guidance_or_direct_chat(self):
        toolbar = TOOLBAR.read_text()
        menu = toolbar.split("private var refinementLassoBubble", 1)[1].split(
            "private func widthAdjustmentGesture", 1
        )[0]

        self.assertIn("var onRefinementChatModeChanged: (Bool) -> Void", toolbar)
        self.assertIn("private func armRefinementLasso(sendToChat: Bool)", toolbar)
        self.assertIn("onRefinementChatModeChanged(sendToChat)", toolbar)
        self.assertIn("isLassoActive = false", toolbar)
        self.assertIn("isRefinementLassoActive = true", toolbar)
        self.assertIn('Label("Guidance Pins"', menu)
        self.assertIn("armRefinementLasso(sendToChat: false)", menu)
        self.assertIn('accessibilityIdentifier("refinement-lasso-guidance")', menu)
        self.assertIn('Label("Send to Chat"', menu)
        self.assertIn("armRefinementLasso(sendToChat: true)", menu)
        self.assertIn('accessibilityIdentifier("refinement-lasso-send-to-chat")', menu)

    def test_trace_and_seal_motion_is_restrained_and_accessible(self):
        source = MAGIC_LASSO.read_text()
        finish = source.split("private func finish", 1)[1].split(
            "private func normalized", 1
        )[0]

        self.assertIn("traceAccentLayer", source)
        self.assertIn("UIColor.systemCyan.withAlphaComponent", source)
        self.assertIn("lineDashPattern = [3, 11]", source)
        self.assertIn('forKey: "magic-trace-drift"', source)
        self.assertIn("private func animateLoopSeal()", source)
        self.assertIn('forKey: "magic-loop-seal"', source)
        self.assertIn('forKey: "magic-loop-seal-accent"', source)
        self.assertIn("UIAccessibility.isReduceMotionEnabled", source)

        # Invalid loops keep the existing red warning and never run the seal.
        invalid, valid = finish.split("boundaryLayer.strokeColor = UIColor.systemIndigo.cgColor", 1)
        self.assertIn("UIColor.systemRed.cgColor", invalid)
        self.assertIn("notificationOccurred(.warning)", invalid)
        self.assertNotIn("animateLoopSeal()", invalid)

        # A successful capture seals the same closed path delivered downstream.
        self.assertIn("captured = closed", valid)
        self.assertIn("render(closed, selected: true, drawing: false)", valid)
        self.assertIn("animateLoopSeal()", valid)
        self.assertIn("onCapturedPath?(closed, bounds.size)", valid)

    def test_direct_chat_mode_is_armed_then_routes_the_captured_selection(self):
        view = NOTEBOOK_VIEW.read_text()

        direct_chat_state = re.search(
            r"@State\s+private var\s+"
            r"(?P<state>\w*(?:magic|refinement|lasso)\w*chat\w*)\s*=\s*false",
            view,
            flags=re.IGNORECASE,
        )
        self.assertIsNotNone(
            direct_chat_state,
            "NotebookView needs an explicit Magic Lasso direct-chat arming state",
        )
        state = direct_chat_state.group("state")

        self.assertRegex(
            view,
            rf"onRefinementChatModeChanged:\s*\{{[^}}]*{re.escape(state)}\s*=\s*\$0",
        )
        capture = view.split("private func handleMagicEraserCapture", 1)[1].split(
            "private func submitMagicGuidance", 1
        )[0]
        self.assertRegex(capture, rf"\bif\s+{re.escape(state)}\b")
        self.assertIn("analyzeCurrentPage(selection: selection)", capture)
        self.assertIn("showAgentChatTab = true", capture)


if __name__ == "__main__":
    unittest.main()
