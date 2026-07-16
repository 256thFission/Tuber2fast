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
        self.assertIn(".overlay(alignment: .topTrailing)", source)
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

    def test_feedback_ui_keeps_quick_current_turn_and_full_screen_history(self):
        source = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        self.assertIn("struct FeedbackThreadBar", source)
        self.assertIn("struct FeedbackThreadView", source)
        self.assertIn(".fullScreenCover", source)
        self.assertIn("session.currentTurn", source)
        self.assertIn('Button("View Full Thread")', source)
        self.assertIn('TextField("Reply to this turn"', source)
        self.assertIn('Button("Capture & Annotate"', source)

    def test_blocked_thread_has_human_priority_reopen_affordance(self):
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        session = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadSession.swift").read_text()
        self.assertIn('Image(systemName: "chevron.backward")', views)
        self.assertIn("func reopen(_ feedbackThread: FeedbackThread)", session)
        self.assertIn("value.state = hasActive ? .queued : .open", session)
        self.assertIn("value.queueSequence = (feedbackThreads.map", session)

    def test_context_navigation_uses_compact_arrows_and_legible_action_roles(self):
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        session = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadSession.swift").read_text()
        self.assertIn('Image(systemName: "chevron.backward")', views)
        self.assertIn('Image(systemName: "chevron.forward")', views)
        self.assertNotIn('Button("Reopen ', views)
        self.assertIn("func skipForward()", session)
        self.assertIn(".tint(.orange)", views)
        self.assertIn(".tint(.green)", views)

    def test_capture_is_human_triggered_and_hides_feedback_ui(self):
        root = (ROOT / "TuberNotes/App/RootView.swift").read_text()
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        self.assertIn("session.requestCapture()", views)
        self.assertIn("captureViewportAfterOverlayDismissal", root)
        self.assertIn(".opacity(feedbackSession.isCapturing ? 0 : 1)", root)
        self.assertIn('Button("Cancel")', views)
        self.assertIn('Button("Attach")', views)

    def test_annotation_is_a_removable_draft_until_the_final_composer_send(self):
        session = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadSession.swift").read_text()
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()

        self.assertIn("@Published private(set) var pendingCapture", session)
        self.assertIn("func attachCapture(drawing: PKDrawing)", session)
        self.assertIn("pendingCapture = PendingCapture(", session)
        self.assertIn("func removePendingCapture()", session)
        self.assertIn("pendingCapture = nil", session)
        self.assertIn('Button("Attach") { session.attachCapture(drawing: drawing) }', views)
        self.assertIn("session.removePendingCapture()", views)
        self.assertNotIn("sendCapture(", session)
        self.assertNotIn("sendCapture(", views)

        attach_body = session.split("func attachCapture(drawing: PKDrawing)", 1)[1].split(
            "func removePendingCapture()", 1
        )[0]
        self.assertNotIn("appendMessage", attach_body)
        self.assertNotIn("write(to:", attach_body)

        cancel_body = session.split("func cancelCapture()", 1)[1].split(
            "func attachCapture(drawing: PKDrawing)", 1
        )[0]
        self.assertNotIn("appendMessage", cancel_body)
        self.assertNotIn("write(to:", cancel_body)

        append_body = session.split("private func appendHumanMessage", 1)[1]
        self.assertIn("let capture = pendingCapture", append_body)
        self.assertIn("attachments: attachment.map { [$0] } ?? []", append_body)
        self.assertLess(
            append_body.index("try FeedbackThreadStore.appendMessage(message, to: &value)"),
            append_body.index("pendingCapture = nil"),
        )
        self.assertIn("session.sendReply(reply)", views)

    def test_live_ab_seam_is_bounded_and_pen_fixture_path_stays_separate(self):
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        session = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadSession.swift").read_text()
        legacy = (ROOT / "TuberNotes/DeveloperSupport/AgentRequestBanner.swift").read_text()
        self.assertIn('comparisonButton("A"', views)
        self.assertIn('comparisonButton("B"', views)
        self.assertIn('Button("Reset")', views)
        self.assertIn('comparisonID == "pin-presentation-01"', session)
        self.assertIn("isResettingComparison", session)
        self.assertIn('Text("Resetting")', views)
        self.assertIn("request.kind == .penFixture", legacy)

    def test_annotation_uses_native_tool_picker_and_history_prioritizes_annotated_image(self):
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        self.assertIn("PKToolPicker()", views)
        self.assertIn("toolPicker.setVisible(true", views)
        self.assertIn('labeledImage(annotated, label: "Annotated")', views)
        self.assertIn("Clean original retained for collection", views)


if __name__ == "__main__":
    unittest.main()
