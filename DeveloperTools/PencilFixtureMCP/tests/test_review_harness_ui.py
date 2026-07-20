from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]


class ReviewHarnessUISourceTests(unittest.TestCase):
    def test_debug_launch_can_reset_only_feedback_state_before_root_view(self):
        app = (ROOT / "TuberNotes/App/TuberNotesApp.swift").read_text()
        store = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThread.swift").read_text()

        self.assertLess(app.index("FeedbackThreadStore.resetIfRequested()"), app.index("RootView("))
        self.assertIn('#if DEBUG\n        FeedbackThreadStore.resetIfRequested()', app)
        self.assertIn('environment["TUBER_RESET_FEEDBACK_STATE"] == "1"', store)
        self.assertIn('appendingPathComponent(rootName, isDirectory: true)', store)
        self.assertIn('removeObject(forKey: deviceEventSequenceKey)', store)
        self.assertNotIn('removeItem(at: documents)', store)

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
        self.assertIn("!isDevelopmentReviewBound", source)
        self.assertIn("feedbackSession.activeFeedbackThread != nil", source)

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

    def test_human_feedback_ui_hides_protocol_bookkeeping(self):
        source = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        self.assertNotIn("feedbackThread.state.rawValue", source)
        self.assertNotIn("value.state.rawValue", source)
        self.assertNotIn("value.scenario", source)
        self.assertNotIn("message.sequence", source)
        self.assertNotIn("message.interaction", source)
        self.assertNotIn("message.inReplyTo", source)
        self.assertIn('Text(message.author == .human ? "You" : "TuberNotes Review")', source)

    def test_old_threads_have_no_reopen_affordance(self):
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        session = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadSession.swift").read_text()
        self.assertNotIn("reopenCandidate", session)
        self.assertNotIn("func reopen(", session)
        self.assertNotIn("feedback-thread-reopen", views)
        self.assertNotIn('Image(systemName: "chevron.backward")', views)

    def test_context_navigation_uses_compact_arrows_and_legible_action_roles(self):
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        session = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadSession.swift").read_text()
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
        self.assertIn("session.sendReply(session.draftReply)", views)

    def test_composer_drafts_live_in_session_until_successful_submission(self):
        session = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadSession.swift").read_text()
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        self.assertIn("composerDrafts: [String: ComposerDraft]", session)
        self.assertIn("var draftReply: String", session)
        self.assertIn("if appendHumanMessage", session)
        self.assertIn("TextField(\"Reply to this turn\", text: draftReply)", views)
        self.assertIn("TextField(\"Reply\", text: draftReply", views)
        self.assertNotIn('@State private var quickReply', views)
        self.assertNotIn('@State private var reply', views)

    def test_capture_submission_bounds_png_memory_and_block_requires_confirmation(self):
        session = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadSession.swift").read_text()
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()

        append_body = session.split("private func appendHumanMessage", 1)[1].split(
            "private func writePNG", 1
        )[0]
        self.assertIn("try writePNG(capture.cleanImage, to: cleanURL)", append_body)
        self.assertIn("try writePNG(capture.annotatedImage, to: annotatedURL)", append_body)
        self.assertNotIn("let cleanData", append_body)
        self.assertIn("autoreleasepool", session)
        self.assertIn('confirmationDialog("Mark this review blocked?"', views)
        self.assertNotIn('Button("Blocked") { session.setState(.blocked) }', views)

    def test_pin_conversation_uses_pin_owned_hold_and_tethered_sidebar(self):
        pin = (ROOT / "TuberNotes/Pins/PinOverlayView.swift").read_text()
        root = (ROOT / "TuberNotes/App/RootView.swift").read_text()

        self.assertIn(".onLongPressGesture(minimumDuration: 0.65, maximumDistance: 12)", pin)
        self.assertIn("onEvent?(.conversationRequested(annotationID: annotation.id))", pin)
        self.assertNotIn(".simultaneousGesture(\n                LongPressGesture", root)
        self.assertIn('accessibilityIdentifier("pin-conversation-sidebar")', root)
        self.assertIn("PinConversationTether(anchor:", root)
        self.assertNotIn("PinConversationAnchor", root)

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

    def test_async_review_run_is_one_persistent_checklist_with_one_finish_action(self):
        model = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThread.swift").read_text()
        session = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadSession.swift").read_text()
        views = (ROOT / "TuberNotes/DeveloperSupport/FeedbackThreadViews.swift").read_text()
        root = (ROOT / "TuberNotes/App/RootView.swift").read_text()
        self.assertIn("struct ReviewRun", model)
        self.assertIn("var reviewRun: ReviewRun?", model)
        self.assertIn("func submitReviewRun()", session)
        self.assertIn('FeedbackThreadStore.appendEvent("review-step-updated"', session)
        self.assertIn('FeedbackThreadStore.appendEvent("review-run-submitted"', session)
        self.assertIn('Button("Finish Review")', views)
        self.assertIn('Picker("Review point", selection: reviewPointSelection)', views)
        self.assertIn('accessibilityIdentifier("review-point-picker")', views)
        self.assertIn("set: { session.selectReviewStep($0) }", views)
        self.assertIn('accessibilityIdentifier("review-run-view")', views)
        self.assertIn("feedbackSession.activeFeedbackThread?.scenario", root)


if __name__ == "__main__":
    unittest.main()
