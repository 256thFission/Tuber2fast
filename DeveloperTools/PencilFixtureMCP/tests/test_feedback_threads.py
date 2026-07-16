from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import server


class FeedbackThreadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote"
        self.target = {"kind": "device", "id": "ipad-test"}
        names = (
            "FEEDBACK_STORE",
            "FEEDBACK_THREADS",
            "FEEDBACK_COLLECTED",
            "FEEDBACK_ATTACHMENTS",
            "FEEDBACK_LEDGER",
            "FEEDBACK_LOCK",
            "FEEDBACK_EVENT_LOG",
        )
        self.original_paths = {name: getattr(server, name) for name in names}
        server.FEEDBACK_STORE = self.root / ".feedback-threads"
        server.FEEDBACK_THREADS = server.FEEDBACK_STORE / "threads"
        server.FEEDBACK_COLLECTED = server.FEEDBACK_STORE / "collected"
        server.FEEDBACK_ATTACHMENTS = server.FEEDBACK_STORE / "attachments"
        server.FEEDBACK_LEDGER = server.FEEDBACK_STORE / "queue.json"
        server.FEEDBACK_LOCK = server.FEEDBACK_STORE / "store.lock"
        server.FEEDBACK_EVENT_LOG = server.FEEDBACK_STORE / "event-log.jsonl"
        self.patchers = [
            mock.patch.object(server, "_select_target", return_value=self.target),
            mock.patch.object(server, "_push_to_target", side_effect=self._push),
            mock.patch.object(server, "_pull_from_target", side_effect=self._pull),
            mock.patch.object(server, "_launch_target", return_value={"process": "test"}),
        ]
        for patcher in self.patchers:
            patcher.start()

    def tearDown(self):
        for patcher in reversed(self.patchers):
            patcher.stop()
        for name, value in self.original_paths.items():
            setattr(server, name, value)
        self.temporary.cleanup()

    def _target_root(self):
        return self.remote / "device-ipad-test"

    def _push(self, target, local_file, relative_destination):
        destination = self._target_root() / relative_destination
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(local_file, destination)
        return {"target": target["kind"], "path": str(destination)}

    def _pull(self, target, relative_source, local_destination):
        source = self._target_root() / relative_source
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

    def _create(self, label):
        return server.create_feedback_thread(
            label,
            f"Objective {label}",
            f"Review {label}",
            scenario=f"scenario-{label}",
            requester_id="terra-test",
            idempotency_key=f"create-{label}",
        )

    def test_fifo_awaiting_model_retains_slot_and_resolution_advances(self):
        first = self._create("first")
        second = self._create("second")
        self.assertEqual(first["state"], "open")
        self.assertEqual(second["state"], "queued")

        waiting = server.set_feedback_thread_state(
            first["feedback_thread_id"],
            "awaiting-model",
            first["owner_token"],
            "model",
            "wait-first",
            1,
            1,
        )
        self.assertEqual(waiting["state"], "awaiting-model")
        self.assertEqual(server._read_feedback_thread(second["feedback_thread_id"])["state"], "queued")

        server.set_feedback_thread_state(
            first["feedback_thread_id"],
            "resolved",
            first["owner_token"],
            "model",
            "resolve-first",
            1,
            1,
        )
        self.assertEqual(server._read_feedback_thread(second["feedback_thread_id"])["state"], "open")
        self.assertEqual(server._load_feedback_ledger()["activeFeedbackThreadID"], second["feedback_thread_id"])

    def test_human_requested_reopen_has_priority_over_existing_waiters(self):
        first = self._create("priority-first")
        second = self._create("priority-second")
        third = self._create("priority-third")
        server.set_feedback_thread_state(
            first["feedback_thread_id"], "resolved", first["owner_token"], "model",
            "resolve-priority-first", 1, 1,
        )
        reopened = server.set_feedback_thread_state(
            first["feedback_thread_id"], "queued", first["owner_token"], "human",
            "human-reopen-priority-first", 1, 1,
        )
        self.assertEqual(reopened["state"], "queued")
        first_record = server._read_feedback_thread(first["feedback_thread_id"])
        third_record = server._read_feedback_thread(third["feedback_thread_id"])
        self.assertLess(first_record["queueSequence"], third_record["queueSequence"])

        server.set_feedback_thread_state(
            second["feedback_thread_id"], "resolved", second["owner_token"], "model",
            "resolve-priority-second", 1, 1,
        )
        self.assertEqual(server._read_feedback_thread(first["feedback_thread_id"])["state"], "open")
        self.assertEqual(server._read_feedback_thread(third["feedback_thread_id"])["state"], "queued")

    def test_owner_idempotency_and_optimistic_concurrency(self):
        created = self._create("owner")
        thread_id = created["feedback_thread_id"]
        token = created["owner_token"]
        duplicate_create = server.create_feedback_thread(
            "owner", "Objective owner", "Review owner", requester_id="terra-test",
            idempotency_key="create-owner", owner_token=token,
        )
        self.assertTrue(duplicate_create["idempotent"])
        with self.assertRaises(PermissionError):
            server.get_feedback_thread(thread_id, "wrong")

        posted = server.post_thread_message(thread_id, "Revision ready", token, "revision-1", 1)
        duplicate = server.post_thread_message(thread_id, "ignored duplicate", token, "revision-1")
        self.assertEqual(posted["message"]["id"], duplicate["message"]["id"])
        self.assertTrue(duplicate["idempotent"])
        with self.assertRaises(RuntimeError):
            server.set_feedback_thread_state(
                thread_id, "resolved", token, "model", "stale-resolve", 1, 1
            )

    def test_single_choice_validation_and_append_only_message(self):
        created = self._create("choice")
        result = server.ask_thread_question(
            created["feedback_thread_id"],
            "Which is better?",
            created["owner_token"],
            "choice-1",
            kind="single-choice",
            options=[{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
            allows_comment=True,
            allows_attachment=True,
            expected_last_sequence=1,
        )
        self.assertEqual(result["message"]["sequence"], 2)
        self.assertEqual(result["message"]["interaction"]["kind"], "single-choice")
        with self.assertRaises(ValueError):
            server.ask_thread_question(
                created["feedback_thread_id"], "Bad", created["owner_token"], "bad-choice",
                kind="single-choice", options=[{"id": "a", "label": "A"}],
            )

    def test_collection_mirrors_human_attachment_and_export(self):
        created = self._create("attachment")
        thread_id = created["feedback_thread_id"]
        remote_thread_dir = self._target_root() / server._feedback_remote_root() / thread_id
        remote_thread = json.loads((remote_thread_dir / "thread.json").read_text())
        remote_thread.update({"lastSequence": 2, "lastHumanSequence": 2, "revision": remote_thread["revision"] + 1})
        message = {
            "id": "feedback-message-human",
            "feedbackThreadID": thread_id,
            "sequence": 2,
            "author": "human",
            "body": "The drift starts here.",
            "createdAt": server._utc_now(),
            "interaction": None,
            "attachments": [{
                "id": "attachment-one",
                "kind": "annotated-screenshot",
                "cleanPath": "attachments/attachment-one-clean.png",
                "annotatedPath": "attachments/attachment-one-annotated.png",
                "pixelWidth": 2732,
                "pixelHeight": 2048,
                "orientation": "landscape",
                "scenario": "scenario-attachment",
                "surfaceRevision": 0,
            }],
        }
        remote_thread["messageIDs"].append(message["id"])
        (remote_thread_dir / "thread.json").write_text(json.dumps(remote_thread))
        (remote_thread_dir / "messages").mkdir(parents=True, exist_ok=True)
        (remote_thread_dir / "messages" / "000002.json").write_text(json.dumps(message))
        (remote_thread_dir / "attachments").mkdir(parents=True, exist_ok=True)
        (remote_thread_dir / "attachments" / "attachment-one-clean.png").write_bytes(b"clean")
        (remote_thread_dir / "attachments" / "attachment-one-annotated.png").write_bytes(b"annotated")
        device_event = {
            "eventID": "device-event-one",
            "event": "annotated-screenshot-sent",
            "feedbackThreadID": thread_id,
            "timestamp": server._utc_now(),
            "source": "device",
            "sourceSequence": 1,
        }
        device_event_log = self._target_root() / server._feedback_remote_root() / "events.jsonl"
        device_event_log.write_text(json.dumps(device_event) + "\n")

        updates = server.collect_thread_updates(thread_id, created["owner_token"], after_sequence=1)
        self.assertEqual([item["sequence"] for item in updates["messages"]], [2])
        paths = updates["attachments"][0]["collectedPaths"]
        self.assertTrue(Path(paths["cleanPath"]).exists())
        self.assertTrue(Path(paths["annotatedPath"]).exists())
        exported = server.export_feedback_thread(thread_id, created["owner_token"])
        self.assertTrue(Path(exported["markdown_path"]).exists())
        self.assertEqual(len(exported["attachment_paths"]), 2)
        server.collect_thread_updates(thread_id, created["owner_token"], after_sequence=1)
        merged_events = [json.loads(line) for line in server.FEEDBACK_EVENT_LOG.read_text().splitlines()]
        self.assertEqual(sum(event.get("eventID") == "device-event-one" for event in merged_events), 1)
        self.assertTrue((server.FEEDBACK_COLLECTED / thread_id / "device-events.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
