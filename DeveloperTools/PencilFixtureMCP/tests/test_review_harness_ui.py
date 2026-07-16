from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]


class ReviewHarnessUISourceTests(unittest.TestCase):
    def test_banner_is_floating_collapsible_and_draggable(self):
        source = (ROOT / "TuberNotes/DeveloperSupport/AgentRequestBanner.swift").read_text()
        self.assertIn("@State private var isCollapsed", source)
        self.assertIn("DragGesture()", source)
        self.assertIn("if !isCollapsed", source)
        self.assertIn(".frame(maxWidth: 520", source)

    def test_request_change_rebinds_and_rebuilds_scenario_surface(self):
        source = (ROOT / "TuberNotes/App/RootView.swift").read_text()
        self.assertIn(".overlay(alignment: .topLeading)", source)
        self.assertIn(".onChange(of: agentSession.activeRequest?.id)", source)
        self.assertIn("displayedScenario = requestedScenario", source)
        self.assertIn("document = displayedScenario.fixture.document", source)
        self.assertIn("surfaceGeneration += 1", source)

    def test_feedback_threads_use_backend_wire_layout_and_explicit_identity(self):
        source = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThread.swift").read_text()
        self.assertIn('appendingPathComponent("thread.json")', source)
        self.assertIn('appendingPathComponent("messages"', source)
        self.assertIn('String(format: "%06d.json"', source)
        self.assertIn("var feedbackThreadID: String", source)
        self.assertIn("Messages have their own append-only files", source)

    def test_feedback_ui_has_only_minimal_bar_and_full_screen_history(self):
        source = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        self.assertIn("struct FeedbackThreadBar", source)
        self.assertIn("struct FeedbackThreadView", source)
        self.assertIn(".fullScreenCover", source)
        self.assertNotIn("ExpandedPanel", source)
        self.assertIn('Button("Capture & Annotate"', source)

    def test_capture_is_human_triggered_and_hides_feedback_ui(self):
        root = (ROOT / "TuberNotes/App/RootView.swift").read_text()
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        self.assertIn("session.requestCapture()", views)
        self.assertIn("captureViewportAfterOverlayDismissal", root)
        self.assertIn(".opacity(feedbackSession.isCapturing ? 0 : 1)", root)
        self.assertIn('Button("Cancel")', views)
        self.assertIn('Button("Send")', views)

    def test_live_ab_seam_is_bounded_and_pen_fixture_path_stays_separate(self):
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        session = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadSession.swift").read_text()
        legacy = (ROOT / "TuberNotes/DeveloperSupport/AgentRequestBanner.swift").read_text()
        self.assertIn('comparisonButton("A"', views)
        self.assertIn('comparisonButton("B"', views)
        self.assertIn('Button("Reset")', views)
        self.assertIn('comparisonID == "pin-presentation-01"', session)
        self.assertIn("request.kind == .penFixture", legacy)


if __name__ == "__main__":
    unittest.main()
