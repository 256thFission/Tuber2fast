from __future__ import annotations

import json
import multiprocessing
import shutil
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

import server


def _enqueue_in_process(request, owner_token, start, results):
    start.wait()
    try:
        response = server._enqueue_request(request, owner_token)
        results.put(("ok", response["id"], response["delivery"]["sequence"]))
    except Exception as exc:  # pragma: no cover - reported to the parent
        results.put(("error", request["id"], repr(exc)))


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote"
        self.launches = self.root / "launches.txt"
        self.selected_target = {"kind": "device", "id": "ipad-a"}

        self.original_paths = {
            name: getattr(server, name)
            for name in (
                "FIXTURES",
                "LOCAL_STORE",
                "REQUESTS",
                "COLLECTED",
                "QUEUE_LEDGER",
                "QUEUE_LOCK",
            )
        }
        server.FIXTURES = self.root / "Fixtures"
        server.LOCAL_STORE = self.root / ".pencil-fixtures"
        server.REQUESTS = server.LOCAL_STORE / "requests"
        server.COLLECTED = server.LOCAL_STORE / "collected"
        server.QUEUE_LEDGER = server.LOCAL_STORE / "queue-ledger.json"
        server.QUEUE_LOCK = server.LOCAL_STORE / "queue.lock"

        self.patchers = [
            mock.patch.object(server, "_select_target", side_effect=self._select_target),
            mock.patch.object(server, "_session_device_id", return_value="ipad-a"),
            mock.patch.object(server, "_push_to_target", side_effect=self._push_to_target),
            mock.patch.object(server, "_pull_from_target", side_effect=self._pull_from_target),
            mock.patch.object(server, "_launch_target", side_effect=self._launch_target),
        ]
        for patcher in self.patchers:
            patcher.start()

    def tearDown(self):
        for patcher in reversed(self.patchers):
            patcher.stop()
        for name, value in self.original_paths.items():
            setattr(server, name, value)
        self.temporary.cleanup()

    def _select_target(self):
        return dict(self.selected_target)

    def _target_root(self, target):
        return self.remote / f"{target['kind']}-{target['id']}"

    def _push_to_target(self, target, local_file, relative_destination):
        destination = self._target_root(target) / relative_destination
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(local_file, destination)
        return {"target": target["kind"], "id": target["id"], "path": str(destination)}

    def _pull_from_target(self, target, relative_source, local_destination):
        source = self._target_root(target) / relative_source
        if not source.exists():
            return None
        local_destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            if local_destination.exists():
                shutil.rmtree(local_destination)
            shutil.copytree(source, local_destination)
        else:
            shutil.copy2(source, local_destination)
        return local_destination

    def _launch_target(self, target, env):
        with self.launches.open("a") as stream:
            stream.write(json.dumps({"target": target, "env": env}) + "\n")
        return {"target": target["kind"], "id": target["id"], "process": "offline-test"}

    def _launch_records(self):
        return [json.loads(line) for line in self.launches.read_text().splitlines()]

    def _request(self, label, *, kind="review", scenario="blank-canvas", stale_after_seconds=3600):
        return server._new_request(
            kind=kind,
            title=label,
            prompt=f"Prompt {label}",
            scenario=scenario,
            requester_id=f"agent-{label}",
            fixture_name=f"fixture-{label}" if kind == "pen-fixture" else None,
            stale_after_seconds=stale_after_seconds,
        )

    def _enqueue(self, label, *, kind="review"):
        request, token = self._request(label, kind=kind)
        response = server._enqueue_request(request, token)
        return request, token, response

    def _complete_remotely(self, request, *, status="answered", verdict="looks-good", notes="done"):
        payload = json.loads(server._request_paths(request["id"])["local"].read_text())
        payload.update(
            {
                "status": status,
                "completedAt": server._utc_now(),
                "verdict": verdict,
                "humanNotes": notes,
            }
        )
        target = payload["delivery"]["target"]
        completed = self._target_root(target) / server._request_paths(request["id"])["completed_rel"]
        completed.parent.mkdir(parents=True, exist_ok=True)
        completed.write_text(json.dumps(payload))
        return payload

    def test_fifo_is_stable_and_completion_advances_in_order(self):
        first, first_token, first_response = self._enqueue("first")
        second, second_token, second_response = self._enqueue("second")
        third, _, third_response = self._enqueue("third")

        self.assertEqual(
            [first_response["delivery"]["sequence"], second_response["delivery"]["sequence"], third_response["delivery"]["sequence"]],
            [1, 2, 3],
        )
        self.assertEqual(len(self._launch_records()), 1)

        ledger = server._load_ledger()
        self.assertEqual([entry["id"] for entry in server._active_ledger_entries(ledger)], [first["id"], second["id"], third["id"]])

        self._complete_remotely(first)
        server._collect_request(first["id"], owner_token=first_token)
        ledger = server._load_ledger()
        self.assertEqual([entry["id"] for entry in server._active_ledger_entries(ledger)], [second["id"], third["id"]])

        self._complete_remotely(second)
        server._collect_request(second["id"], owner_token=second_token)
        ledger = server._load_ledger()
        self.assertEqual([entry["id"] for entry in server._active_ledger_entries(ledger)], [third["id"]])

    def test_queued_requests_preserve_distinct_scenarios_during_advance(self):
        first, first_token = self._request("first-scenario", scenario="blank-canvas")
        second, _ = self._request("second-scenario", scenario="pin-drift")
        server._enqueue_request(first, first_token)
        server._enqueue_request(second, "second-token")

        self.assertEqual(json.loads(server._request_paths(first["id"])["local"].read_text())["scenario"], "blank-canvas")
        self.assertEqual(json.loads(server._request_paths(second["id"])["local"].read_text())["scenario"], "pin-drift")
        self._complete_remotely(first)
        server._collect_request(first["id"], owner_token=first_token)

        active = server._active_ledger_entries(server._load_ledger())
        self.assertEqual([entry["id"] for entry in active], [second["id"]])
        self.assertEqual(json.loads(server._request_paths(second["id"])["local"].read_text())["scenario"], "pin-drift")

    def test_interleaved_processes_share_one_atomic_ledger_and_one_launch(self):
        context = multiprocessing.get_context("fork")
        start = context.Event()
        results = context.Queue()
        requests = [self._request(f"process-{index}") for index in range(4)]
        processes = [
            context.Process(target=_enqueue_in_process, args=(request, token, start, results))
            for request, token in requests
        ]
        for process in processes:
            process.start()
        start.set()
        for process in processes:
            process.join(10)
            self.assertEqual(process.exitcode, 0)

        responses = [results.get(timeout=2) for _ in processes]
        self.assertTrue(all(response[0] == "ok" for response in responses), responses)
        ledger = json.loads(server.QUEUE_LEDGER.read_text())
        self.assertEqual(sorted(entry["sequence"] for entry in ledger["requests"].values()), [1, 2, 3, 4])
        self.assertEqual(ledger["nextSequence"], 5)
        self.assertEqual(len(self._launch_records()), 1)

    def test_duplicate_enqueue_and_delivery_are_idempotent_and_owner_isolated(self):
        request, token = self._request("owner")
        first = server._enqueue_request(request, token)
        duplicate = server._enqueue_request(request, token)
        delivered_again = server._deliver_request(request["id"], token)

        self.assertFalse(first["idempotent"])
        self.assertTrue(duplicate["idempotent"])
        self.assertTrue(delivered_again["idempotent"])
        self.assertEqual(len(self._launch_records()), 1)
        self.assertEqual(len(server._load_ledger()["requests"]), 1)
        persisted = server._request_paths(request["id"])["local"].read_text()
        self.assertNotIn(token, persisted)
        self.assertIn(server._owner_token_hash(token), persisted)

        with self.assertRaises(PermissionError):
            server._collect_request(request["id"], owner_token="wrong-token")
        with self.assertRaises(PermissionError):
            server._cancel_request(
                request["id"], owner_token="wrong-token", reason="not mine"
            )

    def test_queued_launch_does_not_seed_the_legacy_capture_fallback(self):
        self._enqueue("queued-pencil", kind="pen-fixture")

        launches = self._launch_records()
        self.assertEqual(len(launches), 1)
        self.assertEqual(launches[0]["env"], {"TUBER_SCENARIO": "blank-canvas"})
        self.assertNotIn("TUBER_RECORD_PEN_FIXTURE", launches[0]["env"])
        self.assertNotIn("TUBER_PEN_DESCRIPTION", launches[0]["env"])

    def test_collection_uses_pinned_target_and_retains_completion_artifacts(self):
        request, token, _ = self._enqueue("pencil", kind="pen-fixture")
        payload = self._complete_remotely(request, status="recorded", verdict=None, notes="natural stroke")
        target = payload["delivery"]["target"]
        fixture_dir = self._target_root(target) / server._request_paths(request["id"])["fixture_rel"]
        fixture_dir.mkdir(parents=True, exist_ok=True)
        fixture = {"name": request["fixtureName"], "requestID": request["id"], "events": [{"x": 0.1, "y": 0.2}]}
        (fixture_dir / f"{request['fixtureName']}.json").write_text(json.dumps(fixture))
        (fixture_dir / "index.json").write_text(json.dumps({"entries": [{"id": request["id"]}]}))

        self.selected_target = {"kind": "device", "id": "ipad-b"}
        result = server._collect_request(request["id"], owner_token=token)
        duplicate = server._collect_request(request["id"], owner_token=token)

        self.assertEqual(result["target"], {"kind": "device", "id": "ipad-a"})
        self.assertEqual(duplicate["target"], {"kind": "device", "id": "ipad-a"})
        self.assertEqual(result["request"]["requester"]["id"], "agent-pencil")
        self.assertEqual(result["request"]["humanNotes"], "natural stroke")
        self.assertEqual(result["fixture"]["requestID"], request["id"])
        self.assertTrue(Path(result["fixture_path"]).exists())
        self.assertEqual(server._load_ledger()["requests"][request["id"]]["state"], "completed")

    def test_legacy_request_id_only_collection_pins_target_once(self):
        legacy = {
            "id": "legacy-request",
            "kind": "review",
            "title": "Legacy",
            "prompt": "Legacy prompt",
            "status": "awaiting-human",
            "createdAt": server._utc_now(),
        }
        server._write_request(legacy)
        first = server._collect_request(legacy["id"], owner_token=None)
        self.selected_target = {"kind": "device", "id": "ipad-b"}
        second = server._collect_request(legacy["id"], owner_token=None)

        self.assertEqual(first["owner_validation"], "request-id-only-legacy")
        self.assertTrue(first["legacy_target_selected"])
        self.assertFalse(second["legacy_target_selected"])
        self.assertEqual(second["target"], {"kind": "device", "id": "ipad-a"})

    def test_owned_cancel_and_stale_reconciliation_are_terminal(self):
        request, token, _ = self._enqueue("cancel")
        cancelled = server._cancel_request(
            request["id"], owner_token=token, reason="superseded"
        )
        self.assertEqual(cancelled["status"], "cancelled")
        stored = json.loads(server._request_paths(request["id"])["local"].read_text())
        self.assertEqual(stored["cancellationReason"], "superseded")

        stale, stale_token = self._request("stale")
        stale["expiresAt"] = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
        server._enqueue_request(stale, stale_token)
        fresh, _, _ = self._enqueue("fresh")
        stale_stored = json.loads(server._request_paths(stale["id"])["local"].read_text())
        self.assertEqual(stale_stored["status"], "cancelled")
        self.assertEqual(stale_stored["cancellationReason"], "stale-expired")
        active_ids = [entry["id"] for entry in server._active_ledger_entries(server._load_ledger())]
        self.assertEqual(active_ids, [fresh["id"]])


if __name__ == "__main__":
    unittest.main()
