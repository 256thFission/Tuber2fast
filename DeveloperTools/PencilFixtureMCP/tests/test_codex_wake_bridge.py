from __future__ import annotations

import json
import unittest
from unittest import mock

import codex_wake_bridge as bridge


class FakeTransport:
    def __init__(self, messages):
        self.messages = iter(messages)
        self.sent = []
        self.socket = mock.Mock()

    def send_json(self, value):
        self.sent.append(value)

    def receive_json(self):
        return next(self.messages)

    def close(self):
        pass


class CodexWakeBridgeTests(unittest.TestCase):
    def test_idle_thread_starts_exact_requested_thread(self):
        transport = FakeTransport([
            {"id": 1, "result": {"userAgent": "test"}},
            {
                "id": 2,
                "result": {
                    "thread": {"id": "thread-one", "status": {"type": "idle"}, "turns": []}
                },
            },
            {"id": 3, "result": {"turn": {"id": "turn-one", "status": "inProgress"}}},
        ])
        with mock.patch.object(bridge, "ensure_app_server"), mock.patch.object(
            bridge, "UnixWebSocket", return_value=transport
        ):
            client = bridge.AppServerClient()
            result = client.dispatch("thread-one", "wake", "wake-one")

        requests = transport.sent
        self.assertEqual(result, {"mode": "start", "turn_id": "turn-one"})
        self.assertEqual(requests[-1]["method"], "turn/start")
        self.assertEqual(requests[-1]["params"]["threadId"], "thread-one")
        self.assertEqual(requests[-1]["params"]["clientUserMessageId"], "wake-one")

    def test_active_thread_is_steered_with_turn_precondition(self):
        transport = FakeTransport([
            {"id": 1, "result": {"userAgent": "test"}},
            {
                "id": 2,
                "result": {
                    "thread": {
                        "id": "thread-one",
                        "status": {"type": "active"},
                        "turns": [{"id": "turn-active", "status": "inProgress"}],
                    }
                },
            },
            {"id": 3, "result": {"turn": {"id": "turn-active", "status": "inProgress"}}},
        ])
        with mock.patch.object(bridge, "ensure_app_server"), mock.patch.object(
            bridge, "UnixWebSocket", return_value=transport
        ):
            client = bridge.AppServerClient()
            result = client.dispatch("thread-one", "wake", "wake-one")

        requests = transport.sent
        self.assertEqual(result, {"mode": "steer", "turn_id": "turn-active"})
        self.assertEqual(requests[-1]["method"], "turn/steer")
        self.assertEqual(requests[-1]["params"]["expectedTurnId"], "turn-active")

    def test_bridge_keeps_transport_until_dispatched_turn_completes(self):
        transport = FakeTransport([
            {"method": "item/completed", "params": {"item": {"id": "item-one"}}},
            {
                "method": "turn/completed",
                "params": {"turn": {"id": "turn-one", "status": "completed"}},
            },
        ])
        client = object.__new__(bridge.AppServerClient)
        client.transport = transport

        turn = client.wait_for_turn_completed("turn-one", timeout_seconds=12)

        self.assertEqual(turn["status"], "completed")
        transport.socket.settimeout.assert_called_once_with(12)


if __name__ == "__main__":
    unittest.main()
