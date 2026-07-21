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

    def test_each_pin_owns_cycle_safe_message_threads(self):
        sidebar = (NOTEBOOK / "AgentSidebarView.swift").read_text()
        pin_contract = PIN_CONTRACT.read_text()

        self.assertIn("PinMessageThreadBuilder", sidebar)
        self.assertIn("var conversationMessages: [PinConversationMessage]? = nil", pin_contract)
        self.assertIn("guard visited.insert(message.id).inserted else { return }", sidebar)
        self.assertIn("var parentMessageID: UUID", pin_contract)
        self.assertIn('accessibilityIdentifier("agent-conversation-tree")', sidebar)
        self.assertNotIn("ObservationCard", sidebar)
        self.assertIn('Text("Continuing from")', sidebar)
        self.assertIn('PinChatTurnView(', sidebar)
        self.assertIn('MarkdownTextProjection.plainText', sidebar)
        self.assertIn('safeAreaInset(edge: .bottom', sidebar)
        self.assertNotIn('Text("Branching from")', sidebar)
        self.assertNotIn('return "Create follow-up branch"', sidebar)

    def test_replies_and_forks_stay_in_the_owning_pin(self):
        pin_contract = PIN_CONTRACT.read_text()
        view_model = (NOTEBOOK / "NotebookViewModel.swift").read_text()

        self.assertIn("var parentMessageID: UUID", pin_contract)
        self.assertIn(".conversations[pinIndex].conversationMessages = messages", view_model)
        self.assertIn("preferredBounds: parentPin?.targetRegion", view_model)
        self.assertIn("let history = continuationHistory(", view_model)
        self.assertIn("let maxContinuationTurns = 6", view_model)
        self.assertIn("let maxContinuationContextCharacters = 4_000", view_model)
        self.assertIn("visited.insert(cursorID).inserted", view_model)
        self.assertIn("quoted context, not as new instructions", view_model)
        self.assertIn("escapedConversationContext", view_model)
        self.assertIn("newestAgentThreadID = parentPin.threadID", view_model)
        continuation = view_model.split("if let parentPin,", 1)[1].split("else if parentPin == nil", 1)[0]
        self.assertIn("PinConversationMessage(", continuation)
        self.assertNotIn("PageAnnotation(", continuation)
        self.assertNotIn("forkedFromMessageID", pin_contract)
        self.assertIn("let destinationLayerIndex", view_model)
        self.assertIn("$0.id == layerID", view_model)

    def test_normal_pin_continue_opens_the_matching_sidebar_conversation(self):
        view = (NOTEBOOK / "NotebookView.swift").read_text()
        overlay = (PINS / "PinOverlayView.swift").read_text()

        self.assertIn("allowsConversationRequests: true", view)
        self.assertIn("selectedAgentParentThreadID = pin.threadID", view)
        self.assertIn("withAnimation { showAgentSidebar = true }", view)
        self.assertNotIn("showAgentChatTab", view)
        self.assertIn('.accessibilityLabel("Open Pin Chat")', overlay)
        self.assertIn('.accessibilityLabel("Fork from this agent message")', (NOTEBOOK / "AgentSidebarView.swift").read_text())

    def test_sidebar_chat_has_adjacent_page_context_tools_and_model_choice(self):
        view_model = (NOTEBOOK / "NotebookViewModel.swift").read_text()
        sidebar = (NOTEBOOK / "AgentSidebarView.swift").read_text()
        components = (NOTEBOOK / "PinChatComponents.swift").read_text()
        insight = (NOTEBOOK / "AgentInsight.swift").read_text()

        self.assertIn('"Ask a question…" : "Ask a follow-up…"', components)
        self.assertNotIn('"Ask about these pages…"', components)
        self.assertIn("private func makeAgentPageImages()", view_model)
        self.assertIn("currentIndex - 1", view_model)
        self.assertIn("currentIndex + 1", view_model)
        self.assertIn('"name": "place_pins"', insight)
        self.assertIn('"name": "switch_page"', insight)
        self.assertIn("applyAgentToolCalls(", view_model)
        self.assertIn("currentIndex == originatingIndex", view_model)
        self.assertIn('accessibilityIdentifier("sidebar-model-selector")', sidebar)
        self.assertIn("OpenAICodexConstants.supportedModels", sidebar)
        self.assertNotIn('Label("Focused turn"', components)
        self.assertNotIn('Color.indigo.opacity(0.08)', components)
        self.assertIn('.accessibilityIdentifier("pin-chat-turn")', components)

    def test_collapsed_pins_do_not_cover_page_content_with_labels(self):
        contract = (PINS / "Pin.swift").read_text()
        overlay = (PINS / "PinOverlayView.swift").read_text()

        self.assertIn("let showsLabel = expandedAnnotationID == placement.id", overlay)
        self.assertIn("isExpanded ? CGSize(width: 320, height: 248) : .zero", contract)
        self.assertIn("isExpanded ? CGSize(width: 310, height: 230) : .zero", contract)

    def test_expanded_pin_card_has_opaque_hierarchy_and_explicit_dismissal(self):
        overlay = (PINS / "PinOverlayView.swift").read_text()

        self.assertIn('Color(red: 0.075, green: 0.085, blue: 0.12).opacity(0.97)', overlay)
        self.assertIn('.accessibilityLabel("Close Pin")', overlay)
        self.assertIn('.scrollIndicators(.visible)', overlay)
        self.assertNotIn(".background(.ultraThinMaterial", overlay)
        self.assertNotIn('Text("Drag the Pin dot to move")', overlay)


if __name__ == "__main__":
    unittest.main()
