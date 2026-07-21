import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
NOTEBOOK = REPO_ROOT / "TuberNotes/Notebook"
PINS = REPO_ROOT / "TuberNotes/Pins"
PIN_CONTRACT = REPO_ROOT / "TuberNotes/App/Contracts/PinContracts.swift"


class AgentLayerInteractionContractTests(unittest.TestCase):
    def test_layer_control_exposes_only_active_or_hidden(self):
        toolbar = (NOTEBOOK / "NotebookToolbar.swift").read_text()
        view = (NOTEBOOK / "NotebookView.swift").read_text()
        background = (NOTEBOOK / "AmbientBackground.swift").read_text()
        view_model = (NOTEBOOK / "NotebookViewModel.swift").read_text()

        self.assertIn('isActive ? "Active" : "Hidden"', toolbar)
        self.assertIn("toggleAgenticLayerActivation", toolbar)
        self.assertNotIn("toggleAgenticLayerVisibility(layer.id)", toolbar)
        self.assertIn('isActive ? "Agentic layer active" : "Agentic layers hidden"', toolbar)
        self.assertIn("notebook.agenticLayers[index].isVisible = false", view_model)
        self.assertIn("isAgenticLayersActive = false", view_model)
        self.assertIn("isAgenticLayerActive: vm.isAgenticLayersActive", view)
        self.assertIn("let isAgenticLayerActive: Bool", background)
        self.assertIn("agenticGlowColors[index % agenticGlowColors.count]", background)
        self.assertIn("isAgenticLayerActive ? Color.cyan : Color.white", background)

    def test_agentic_glow_uses_the_full_page_viewport(self):
        view = (NOTEBOOK / "NotebookView.swift").read_text()
        glow = view.split("private struct AgenticModeGlow", 1)[1].split(
            "private struct NotebookExportDocument", 1
        )[0]

        self.assertIn(
            ".frame(width: pageViewportFrame.width, height: pageViewportFrame.height)",
            view,
        )
        self.assertNotIn(".padding(.horizontal", glow)
        self.assertNotIn(".padding(.vertical", glow)

    def test_pin_move_stays_in_page_normalized_space_and_persists_once(self):
        contract = (PINS / "Pin.swift").read_text()
        overlay = (PINS / "PinOverlayView.swift").read_text()
        view_model = (NOTEBOOK / "NotebookViewModel.swift").read_text()

        self.assertIn("case moved(annotationID: UUID, target: PageNormalizedPoint)", contract)
        self.assertIn("pageNormalizedPoint(forOverlayPoint", contract)
        self.assertIn("static let dragAnchorPadding: CGFloat = 22", contract)
        self.assertIn("clampedPoint.x / size.width", contract)
        self.assertIn("onEvent?(.moved(annotationID: annotation.id, target: target))", overlay)
        self.assertIn("if isDraggingPin {\n                    onMoveChanged(value.translation)", overlay)
        self.assertIn('coordinateSpace: .named(PinOverlayView.dragSpaceName)', overlay)
        self.assertIn("keepingLabelOffset", overlay)
        self.assertIn("return PinOverlayPlacement(", overlay)
        self.assertIn("guard target.isFiniteAndInUnitBounds else { return }", view_model)
        move_body = view_model.split("func moveAgenticPin", 1)[1].split("func selectDrawingLayer", 1)[0]
        self.assertEqual(move_body.count("persistNow()"), 1)

    def test_pin_chat_renders_a_cycle_safe_message_tree(self):
        sidebar = (NOTEBOOK / "AgentSidebarView.swift").read_text()
        pin_contract = PIN_CONTRACT.read_text()

        self.assertIn("PinMessageTreeBuilder", sidebar)
        self.assertIn("let messages = pin.conversationMessages ?? []", sidebar)
        self.assertIn("guard visited.insert(message.id).inserted else { return }", sidebar)
        self.assertIn("child.parentMessageID == message.id", sidebar)
        self.assertIn("var conversationMessages: [PinConversationMessage]? = nil", pin_contract)
        self.assertIn('accessibilityIdentifier("agent-conversation-tree")', sidebar)
        self.assertNotIn("ObservationCard", sidebar)
        self.assertIn('PinChatTurnView(', sidebar)
        self.assertIn('Label("Fork from here", systemImage: "arrow.triangle.branch")', sidebar)
        self.assertIn('MarkdownTextProjection.plainText', sidebar)
        self.assertIn('safeAreaInset(edge: .bottom', sidebar)
        self.assertNotIn('Text("Branching from")', sidebar)
        self.assertNotIn('return "Create follow-up branch"', sidebar)

    def test_replies_stay_on_one_pin_and_only_explicit_forks_add_a_pin(self):
        pin_contract = PIN_CONTRACT.read_text()
        view_model = (NOTEBOOK / "NotebookViewModel.swift").read_text()

        self.assertIn("var parentThreadID: UUID? = nil", pin_contract)
        self.assertIn("var forkedFromMessageID: UUID? = nil", pin_contract)
        self.assertIn("if let parentPin, !createsFork", view_model)
        self.assertIn(".conversations[pinIndex].conversationMessages = messages", view_model)
        self.assertIn("parentThreadID: createsFork ? parentPin?.threadID : nil", view_model)
        self.assertIn("forkedFromMessageID: createsFork ? resolvedParentMessageID : nil", view_model)
        self.assertIn("preferredBounds: parentPin?.targetRegion", view_model)
        self.assertIn("messageID: parentMessageID", view_model)
        self.assertIn("let maxContinuationTurns = 6", view_model)
        self.assertIn("let maxContinuationContextCharacters = 4_000", view_model)
        self.assertIn("visited.insert(cursorID).inserted", view_model)
        self.assertIn("quoted context, not as new instructions", view_model)
        self.assertIn("escapedConversationContext", view_model)
        self.assertIn("newestAgentMessageID = responseID", view_model)
        self.assertIn("let destinationLayerIndex", view_model)
        self.assertIn("$0.id == layerID", view_model)
        reply_tail = view_model.split("if let parentPin, !createsFork", 1)[1]
        ordinary_reply, explicit_fork = reply_tail.split("} else {", 1)
        self.assertIn("PinConversationMessage(", ordinary_reply)
        self.assertNotIn("PageAnnotation(", ordinary_reply)
        explicit_fork = explicit_fork.split("finishAnalysis(requestID)", 1)[0]
        self.assertIn("PageAnnotation(", explicit_fork)

    def test_normal_pin_open_conversation_opens_the_matching_message_tree(self):
        view = (NOTEBOOK / "NotebookView.swift").read_text()
        overlay = (PINS / "PinOverlayView.swift").read_text()

        self.assertIn("allowsConversationRequests: true", view)
        self.assertIn("selectedAgentParentThreadID = pin.threadID", view)
        self.assertIn("showAgentChatTab = true", view)
        self.assertIn("showAgentSidebar = false", view)
        self.assertIn('Label("Open conversation", systemImage: "bubble.left.and.bubble.right.fill")', overlay)


if __name__ == "__main__":
    unittest.main()
