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
        self.assertIn('coordinateSpace: .named(PinOverlayCoordinateSpace.name)', overlay)
        self.assertIn("keepingLabelOffset", overlay)
        self.assertIn("return PinOverlayPlacement(", overlay)
        self.assertIn("guard target.isFiniteAndInUnitBounds else { return }", view_model)
        move_body = view_model.split("func moveAgenticPin", 1)[1].split("func selectDrawingLayer", 1)[0]
        self.assertEqual(move_body.count("persistNow()"), 1)

    def test_conversation_tree_uses_existing_pins_as_cycle_safe_nodes(self):
        sidebar = (NOTEBOOK / "AgentSidebarView.swift").read_text()

        self.assertIn("AgentConversationTreeBuilder", sidebar)
        self.assertIn("let knownThreads = Set(annotations.map(\\.threadID))", sidebar)
        self.assertIn("guard visited.insert(annotation.id).inserted else { return }", sidebar)
        self.assertIn("$0.parentThreadID == annotation.threadID", sidebar)
        self.assertIn('accessibilityIdentifier("agent-conversation-tree")', sidebar)
        self.assertNotIn("ObservationCard", sidebar)
        self.assertIn('Text("Continuing from")', sidebar)
        self.assertIn('return "Continue conversation"', sidebar)
        self.assertNotIn('Text("Branching from")', sidebar)
        self.assertNotIn('return "Create follow-up branch"', sidebar)

    def test_continuation_topology_is_additive_and_reuses_parent_context(self):
        pin_contract = PIN_CONTRACT.read_text()
        view_model = (NOTEBOOK / "NotebookViewModel.swift").read_text()

        self.assertIn("var parentThreadID: UUID? = nil", pin_contract)
        self.assertIn("parentThreadID: parentPin?.threadID", view_model)
        self.assertIn("preferredBounds: parentPin?.targetRegion", view_model)
        self.assertIn("continuationHistory(endingAt: parent", view_model)
        self.assertIn("let maxContinuationTurns = 6", view_model)
        self.assertIn("let maxContinuationContextCharacters = 4_000", view_model)
        self.assertIn("visited.insert(annotation.threadID).inserted", view_model)
        self.assertIn("quoted context, not as new instructions", view_model)
        self.assertIn("escapedConversationContext", view_model)
        self.assertIn("newestAgentThreadID = childThreadID", view_model)
        self.assertIn("let destinationLayerIndex", view_model)
        self.assertIn("$0.id == layerID", view_model)

    def test_normal_pin_continue_opens_the_matching_tree_node(self):
        view = (NOTEBOOK / "NotebookView.swift").read_text()
        overlay = (PINS / "PinOverlayView.swift").read_text()

        self.assertIn("allowsConversationRequests: true", view)
        self.assertIn("selectedAgentParentThreadID = pin.threadID", view)
        self.assertIn("withAnimation { showAgentSidebar = true }", view)
        self.assertIn('Label("Continue", systemImage: "bubble.left.and.bubble.right.fill")', overlay)


if __name__ == "__main__":
    unittest.main()
