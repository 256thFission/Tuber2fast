import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "DeveloperTools" / "verify-scenario.sh"
SCENARIO_SOURCE = ROOT / "TuberNotes" / "DeveloperSupport" / "DevelopmentScenario.swift"


class VerifyScenarioTruthfulnessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = VERIFIER.read_text()

    def test_pinned_physical_device_session_is_required_and_simulator_fallback_is_absent(self):
        self.assertIn('python3 "$DEVICE_SESSION_TOOL" resolve', self.source)
        self.assertIn('FAIL: no valid physical-iPad session', self.source)
        self.assertIn('-destination "platform=iOS,id=$DEVICE_ID"', self.source)
        self.assertIn('xcrun devicectl device install app', self.source)
        self.assertNotIn('xcrun simctl', self.source)

    def test_mechanical_pass_is_guarded_by_accumulated_pass(self):
        final_assertion = self.source.split(
            'if [[ "$FORCE_MECHANICAL_FAILURE" == "1" ]]', 1
        )[1]
        self.assertIn('if [[ $pass -eq 1 ]]; then', final_assertion)
        guarded = final_assertion.split('if [[ $pass -eq 1 ]]; then', 1)[1]
        pass_line = guarded.index('MECHANICAL_ASSERTION: PASS')
        else_line = guarded.index("else")
        self.assertLess(pass_line, else_line)
        self.assertIn('MECHANICAL_ASSERTION: FAIL', guarded[else_line:])

    def test_runtime_assertions_accept_exact_state_and_reject_divergence(self):
        marker = 'python3 - "$RUNTIME_EVIDENCE"'
        block = self.source.split(marker, 1)[1]
        python_source = block.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        evidence = {
            "schemaVersion": 1,
            "scenario": "edge-pins",
            "verificationNonce": "fresh-launch-nonce",
            "surfaceKind": "standalone-pin-surface",
            "pageCount": 1,
            "currentPageIndex": 0,
            "currentPageID": "10000000-0000-0000-0000-000000000002",
            "renderedPenFixtureName": None,
            "renderedAnnotationIDs": ["pin-a", "pin-b"],
            "heroStatus": None,
            "recordedAt": "2026-07-17T12:00:00Z",
        }
        evidence_path = self._write_evidence(evidence)
        args = [
            str(evidence_path), "edge-pins", "standalone-pin-surface", "1", "0",
            "10000000-0000-0000-0000-000000000002", "", "pin-a,pin-b", "",
            "fresh-launch-nonce",
        ]
        accepted = subprocess.run(
            ["python3", "-c", python_source, *args], capture_output=True, text=True
        )
        self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)

        evidence["renderedAnnotationIDs"] = ["different-pin"]
        evidence_path.write_text(json.dumps(evidence))
        rejected = subprocess.run(
            ["python3", "-c", python_source, *args], capture_output=True, text=True
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("renderedAnnotationIDs", rejected.stdout)

    def test_new_launch_clears_stale_runtime_snapshot(self):
        source = SCENARIO_SOURCE.read_text()
        self.assertIn('appendingPathComponent("runtime-rendered.json")', source)
        self.assertIn("removeItem(at: runtimeURL)", source)
        self.assertIn('environment["TUBER_VERIFY_NONCE"]', source)
        self.assertIn('TUBER_VERIFY_NONCE', self.source)
        self.assertIn('--environment-variables "$launch_environment"', self.source)
        self.assertIn('"verificationNonce": verification_nonce', self.source)

    def _write_evidence(self, value):
        path = ROOT / "tmp" / "verify-runtime-evidence-test.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        self.addCleanup(path.unlink, missing_ok=True)
        return path


if __name__ == "__main__":
    unittest.main()
