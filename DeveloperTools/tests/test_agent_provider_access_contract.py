import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
NOTEBOOK = ROOT / "TuberNotes" / "Notebook"
HARNESS = ROOT / "TuberNotes" / "AgentHarness"


class AgentProviderAccessContractTests(unittest.TestCase):
    def test_toolbar_hands_provider_presentation_off_after_popover_dismissal(self):
        notebook_view = (NOTEBOOK / "NotebookView.swift").read_text()
        toolbar = (NOTEBOOK / "NotebookToolbar.swift").read_text()

        self.assertIn("openProviderAccessAfterToolbarSettings = true", notebook_view)
        self.assertIn("guard openProviderAccessAfterToolbarSettings else { return }", notebook_view)
        self.assertIn(".onDisappear(perform: onDismiss)", toolbar)
        settings_route = notebook_view.split("private var toolbarSettingsButton", 1)[1].split(
            "private var isAnalysisAccessConfigured", 1
        )[0]
        self.assertNotIn("asyncAfter", settings_route)

    def test_normal_ui_exposes_provider_model_and_both_entry_points(self):
        notebook_view = (NOTEBOOK / "NotebookView.swift").read_text()
        sidebar = (NOTEBOOK / "AgentSidebarView.swift").read_text()
        toolbar = (NOTEBOOK / "NotebookToolbar.swift").read_text()

        self.assertIn("AgentProviderAccess.providerStorageKey", notebook_view)
        self.assertIn("AgentProviderAccess.modelStorageKey", notebook_view)
        self.assertIn("return \"\\(access.provider.label) · \\(access.model)\"", notebook_view)
        self.assertIn('accessibilityIdentifier("settings-analysis-access")', toolbar)
        self.assertIn('accessibilityIdentifier("assistant-provider-access")', sidebar)
        self.assertIn("providerAccessValue", sidebar)
        self.assertIn("providerAccess.provider.label", sidebar)
        self.assertIn("providerAccess.model", sidebar)

    def test_provider_editor_controls_have_accessibility_contracts(self):
        sidebar = (NOTEBOOK / "AgentSidebarView.swift").read_text()

        for identifier in (
            "agent-provider-popup",
            "agent-provider-picker",
            "agent-provider-credential",
            "agent-model-picker",
            "agent-provider-remove",
            "agent-provider-save",
        ):
            self.assertIn(f'accessibilityIdentifier("{identifier}")', sidebar)
        self.assertIn('accessibilityLabel("\\(provider.label) access credential")', sidebar)
        self.assertIn('accessibilityLabel("Model")', sidebar)
        self.assertIn(".accessibilityValue(modelLabel)", sidebar)

    def test_provider_access_is_shared_and_direct_clients_stay_debug_only(self):
        access = (HARNESS / "AgentClient.swift").read_text()
        insight = (NOTEBOOK / "AgentInsight.swift").read_text()
        transport = (HARNESS / "DebugCodexTransport.swift").read_text()

        self.assertIn("struct AgentProviderAccess", access)
        self.assertIn("static func make(access: AgentProviderAccess?)", insight)
        self.assertIn("DebugCodexAgentClient(access: access)", access)
        self.assertIn("init(access: AgentProviderAccess)", transport)
        self.assertGreaterEqual(insight.count("#if DEBUG"), 2)
        self.assertIn("return MockAgentInsightClient()", insight)

    def test_provider_failures_are_actionable_without_response_body_leakage(self):
        insight = (NOTEBOOK / "AgentInsight.swift").read_text()

        self.assertIn("Check agent provider settings and try again", insight)
        self.assertIn("this access has reached its limit", insight)
        self.assertNotIn("String(data:", insight)
        self.assertNotIn("response body", insight.lower())


if __name__ == "__main__":
    unittest.main()
