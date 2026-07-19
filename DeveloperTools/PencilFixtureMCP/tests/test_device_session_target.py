import inspect
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import server


class DeviceSessionTargetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.session_file = Path(self.temporary.name) / "session.json"
        self.session_file.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "deviceID": "pinned-ipad",
                    "deviceType": "iPad",
                    "reality": "physical",
                }
            )
        )
        self.patcher = mock.patch.object(server, "DEVICE_SESSION_FILE", self.session_file)
        self.patcher.start()

    def tearDown(self):
        self.patcher.stop()
        self.temporary.cleanup()

    def test_target_comes_only_from_session(self):
        self.assertEqual(server._select_target(), {"kind": "device", "id": "pinned-ipad"})

    def test_mismatched_request_target_is_divergence(self):
        with self.assertRaisesRegex(RuntimeError, "Device/host divergence"):
            server._require_session_target({"kind": "device", "id": "other-ipad"})

    def test_public_device_tools_have_no_target_choice_parameter(self):
        tools = (
            server.request_pen_fixture,
            server.request_human_review,
            server.collect_interaction,
            server.await_interaction,
            server.cancel_interaction,
            server.list_interactions,
            server.replay_pen_fixture,
            server.create_feedback_thread,
            server.create_review_run,
        )
        for tool in tools:
            self.assertNotIn("prefer_device", inspect.signature(tool).parameters)


if __name__ == "__main__":
    unittest.main()
