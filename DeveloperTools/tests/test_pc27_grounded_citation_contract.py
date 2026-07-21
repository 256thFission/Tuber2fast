from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class GroundedCitationContractTests(unittest.TestCase):
    def test_product_initializer_accepts_only_a_knowledge_hit(self):
        source = (ROOT / "TuberNotes/App/Contracts/AgentContracts.swift").read_text()
        citation = source.split("struct GroundedCitation", 1)[1].split(
            "struct InvestigationRequest", 1
        )[0]
        self.assertIn("init(hit: KnowledgeHit)", citation)
        self.assertNotIn("init(", citation.replace("init(hit: KnowledgeHit)", ""))

    def test_root_and_follow_up_take_only_first_typed_hit(self):
        source = (ROOT / "TuberNotes/Notebook/NotebookViewModel.swift").read_text()
        mapping = "insight.knowledgeHits.first.map(GroundedCitation.init(hit:))"
        self.assertGreaterEqual(source.count(mapping), 3)
        self.assertNotIn("insight.body", mapping)
        self.assertNotRegex(source, r"GroundedCitation\([^\n]*insight\.body")

    def test_thread_builder_projects_root_and_follow_up_citations(self):
        source = (ROOT / "TuberNotes/Notebook/AgentSidebarView.swift").read_text()
        builder = source.split("private enum PinMessageThreadBuilder", 1)[1].split(
            "private struct AgentConversationTreeItem", 1
        )[0]
        self.assertIn("groundedCitation: message.groundedCitation", builder)
        self.assertIn("groundedCitation: pin.groundedCitation", builder)

    def test_chip_is_a_sibling_beneath_markdown_and_absent_without_a_hit(self):
        source = (ROOT / "TuberNotes/Notebook/PinChatComponents.swift").read_text()
        turn = source.split("struct PinChatTurnView", 1)[1].split(
            "private struct GroundedCitationChip", 1
        )[0]
        markdown_index = turn.index("MarkdownMessageView(source: assistantMarkdown)")
        conditional_index = turn.index("if let groundedCitation")
        chip_index = turn.index("GroundedCitationChip(")
        self.assertLess(markdown_index, conditional_index)
        self.assertLess(conditional_index, chip_index)
        self.assertIn("var onOpenCitation: ((GroundedCitation) -> Void)? = nil", turn)

    def test_inert_chip_is_disabled_until_pc28_supplies_callback(self):
        source = (ROOT / "TuberNotes/Notebook/PinChatComponents.swift").read_text()
        chip = source.split("private struct GroundedCitationChip", 1)[1].split(
            "struct PinChatPendingTurnView", 1
        )[0]
        self.assertIn("let onOpen: (() -> Void)?", chip)
        self.assertIn(".disabled(onOpen == nil)", chip)
        self.assertIn('onOpen == nil ? "" : "Opens the cited textbook page"', chip)


if __name__ == "__main__":
    unittest.main()
