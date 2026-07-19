from __future__ import annotations

import asyncio
import io
import json
import shutil
import tempfile
import threading
import unittest
from datetime import timedelta
from pathlib import Path
from unittest import mock

from mcp.shared.memory import create_connected_server_and_client_session

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
            "FEEDBACK_WATCHES",
            "FEEDBACK_LEDGER",
            "FEEDBACK_LOCK",
            "FEEDBACK_EVENT_LOG",
        )
        self.original_paths = {name: getattr(server, name) for name in names}
        server.FEEDBACK_STORE = self.root / ".feedback-threads"
        server.FEEDBACK_THREADS = server.FEEDBACK_STORE / "threads"
        server.FEEDBACK_COLLECTED = server.FEEDBACK_STORE / "collected"
        server.FEEDBACK_ATTACHMENTS = server.FEEDBACK_STORE / "attachments"
        server.FEEDBACK_WATCHES = server.FEEDBACK_STORE / "watches"
        server.FEEDBACK_LEDGER = server.FEEDBACK_STORE / "queue.json"
        server.FEEDBACK_LOCK = server.FEEDBACK_STORE / "store.lock"
        server.FEEDBACK_EVENT_LOG = server.FEEDBACK_STORE / "event-log.jsonl"
        self.patchers = [
            mock.patch.object(server, "_select_target", return_value=self.target),
            mock.patch.object(server, "_session_device_id", return_value="ipad-test"),
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
        created = server._create_feedback_thread(
            label,
            f"Objective {label}",
            f"Review {label}",
            scenario=f"scenario-{label}",
            requester_id="terra-test",
            idempotency_key=f"create-{label}",
        )
        self._device_reload()
        server._collect_thread_updates(created["feedback_thread_id"], created["owner_token"])
        created["state"] = server._read_feedback_thread(created["feedback_thread_id"])["state"]
        return created

    def _device_reload(self):
        root = self._target_root() / server._feedback_remote_root()
        snapshots = []
        for path in root.glob("feedback-*/thread.json"):
            snapshots.append((path, json.loads(path.read_text())))
        if any(thread["state"] in server.FEEDBACK_SLOT_STATES for _, thread in snapshots):
            return
        queued = sorted(
            ((path, thread) for path, thread in snapshots if thread["state"] == "queued"),
            key=lambda item: (item[1]["queueSequence"], item[1]["id"]),
        )
        if queued:
            path, thread = queued[0]
            thread["state"] = "open"
            thread["revision"] += 1
            thread["updatedAt"] = server._utc_now()
            path.write_text(json.dumps(thread))

    def _append_remote_human(self, created, body="Human response"):
        thread_id = created["feedback_thread_id"]
        remote_thread_dir = self._target_root() / server._feedback_remote_root() / thread_id
        remote_thread = json.loads((remote_thread_dir / "thread.json").read_text())
        remote_messages = [
            json.loads(path.read_text())
            for path in sorted((remote_thread_dir / "messages").glob("*.json"))
        ]
        in_reply_to = next(
            (
                message["id"]
                for message in reversed(remote_messages)
                if (message.get("interaction") or {}).get("state") == "awaiting-human"
            ),
            None,
        )
        sequence = int(remote_thread["lastSequence"]) + 1
        message = {
            "id": f"feedback-message-human-{sequence}",
            "feedbackThreadID": thread_id,
            "sequence": sequence,
            "author": "human",
            "body": body,
            "createdAt": server._utc_now(),
            "interaction": None,
            "inReplyTo": in_reply_to,
            "attachments": [],
        }
        remote_thread.update({
            "state": "awaiting-model",
            "lastSequence": sequence,
            "lastHumanSequence": sequence,
            "revision": int(remote_thread["revision"]) + 1,
        })
        remote_thread["messageIDs"].append(message["id"])
        (remote_thread_dir / "thread.json").write_text(json.dumps(remote_thread))
        (remote_thread_dir / "messages").mkdir(parents=True, exist_ok=True)
        (remote_thread_dir / "messages" / f"{sequence:06d}.json").write_text(json.dumps(message))
        return sequence

    def test_external_commands_have_a_hard_timeout(self):
        with mock.patch.object(server.subprocess, "run") as run:
            server._run(["xcrun", "--version"])
        self.assertEqual(run.call_args.kwargs["timeout"], server.COMMAND_TIMEOUT_SECONDS)

    def test_review_run_edits_stay_quiet_until_one_idempotent_finish_wake(self):
        created = server._create_review_run(
            "Async packet",
            "Collect independent human checks",
            [
                {
                    "id": "A1",
                    "title": "First check",
                    "human_instruction": "Inspect the first surface.",
                    "response_kind": "verdict",
                    "scenario": "fake-pin",
                },
                {
                    "id": "A2",
                    "title": "Dependent check",
                    "human_instruction": "Annotate the edge.",
                    "response_kind": "comment",
                    "scenario": "edge-pins",
                    "prerequisite_ids": ["A1"],
                    "allows_attachment": True,
                },
                {
                    "id": "Q1",
                    "title": "Independent choice",
                    "human_instruction": "Choose the clearer option.",
                    "response_kind": "choice",
                    "options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
                },
            ],
            requester_id="terra-test",
            idempotency_key="async-packet",
        )
        self._device_reload()
        server._collect_thread_updates(created["feedback_thread_id"], created["owner_token"])
        thread_id = created["feedback_thread_id"]
        remote_file = self._target_root() / server._feedback_remote_root() / thread_id / "thread.json"
        remote = json.loads(remote_file.read_text())
        self.assertEqual(remote["scenario"], "fake-pin")
        self.assertEqual([step["state"] for step in remote["reviewRun"]["steps"]], ["ready", "locked", "ready"])

        remote["reviewRun"]["steps"][0].update({"state": "passed", "verdict": "passed"})
        remote["reviewRun"]["steps"][1]["state"] = "ready"
        remote["revision"] += 1
        remote_file.write_text(json.dumps(remote))
        quiet = server._get_feedback_watch_state(thread_id, created["owner_token"], after_sequence=1)
        self.assertFalse(quiet["wake_eligible"])

        remote = json.loads(remote_file.read_text())
        for step in remote["reviewRun"]["steps"]:
            if step["state"] in {"ready", "in-progress"}:
                step.update({"state": "passed", "verdict": "passed"})
        remote["reviewRun"].update({"state": "submitted", "submittedAt": server._utc_now()})
        remote_file.write_text(json.dumps(remote))
        submitted_sequence = self._append_remote_human(created, body="A1 — First check: passed")
        wake = server._get_feedback_watch_state(thread_id, created["owner_token"], after_sequence=1)
        self.assertTrue(wake["wake_eligible"])
        self.assertEqual([message["sequence"] for message in wake["human_messages"]], [submitted_sequence])

        collected = server._collect_review_run(thread_id, created["owner_token"])
        self.assertEqual(collected["review_run"]["state"], "collected")
        self.assertFalse(collected["idempotent"])
        duplicate = server._collect_review_run(thread_id, created["owner_token"])
        self.assertTrue(duplicate["idempotent"])
        exported = server._export_review_run(thread_id, created["owner_token"])
        self.assertTrue(Path(exported["review_run_json_path"]).exists())
        self.assertTrue(Path(exported["review_run_markdown_path"]).exists())

    def test_review_run_rejects_agent_gated_and_forward_dependencies(self):
        with self.assertRaisesRegex(ValueError, "human-autonomous"):
            server._normalized_review_run(
                [{"id": "S3", "title": "Stale write", "human_instruction": "Wait.", "classification": "agent-gated"}]
            )
        with self.assertRaisesRegex(ValueError, "earlier step IDs"):
            server._normalized_review_run(
                [{"id": "A2", "title": "Later", "human_instruction": "Inspect.", "prerequisite_ids": ["A1"]}]
            )

    def test_fifo_awaiting_model_retains_slot_and_resolution_advances(self):
        first = self._create("first")
        second = self._create("second")
        self.assertEqual(first["state"], "open")
        self.assertEqual(second["state"], "queued")

        waiting = server._set_feedback_thread_state(
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

        server._set_feedback_thread_state(
            first["feedback_thread_id"],
            "resolved",
            first["owner_token"],
            "model",
            "resolve-first",
            1,
            1,
        )
        self._device_reload()
        server._collect_thread_updates(second["feedback_thread_id"], second["owner_token"])
        self.assertEqual(server._read_feedback_thread(second["feedback_thread_id"])["state"], "open")

    def test_owner_cancel_is_idempotent_and_activates_exactly_one_waiter(self):
        first = self._create("cancel-first")
        second = self._create("cancel-second")
        third = self._create("cancel-third")

        cancelled = server._cancel_feedback_thread(
            first["feedback_thread_id"], "superseded", first["owner_token"]
        )
        self.assertIsNone(cancelled["activated_feedback_thread_id"])
        self._device_reload()
        server._collect_thread_updates(second["feedback_thread_id"], second["owner_token"])
        self.assertEqual(server._read_feedback_thread(second["feedback_thread_id"])["state"], "open")
        self.assertEqual(server._read_feedback_thread(third["feedback_thread_id"])["state"], "queued")
        duplicate = server._cancel_feedback_thread(
            first["feedback_thread_id"], "superseded", first["owner_token"]
        )
        self.assertTrue(duplicate["idempotent"])

    def test_system_cleanup_requires_explicit_confirmation_and_repairs_divergent_queue(self):
        old = self._create("old-ledger-active")
        blocked = self._create("device-blocked-newer")
        waiting = self._create("fresh-waiter")
        blocked_thread = server._read_feedback_thread(blocked["feedback_thread_id"])
        blocked_thread["state"] = "blocked"
        server._write_feedback_thread(blocked_thread)
        server._push_feedback_snapshot(blocked_thread)
        ledger = server._load_feedback_ledger()
        ledger["feedbackThreads"][blocked["feedback_thread_id"]]["state"] = "open"
        # Reproduce duplicate queueSequence corruption without losing FIFO determinism.
        waiting_thread = server._read_feedback_thread(waiting["feedback_thread_id"])
        waiting_thread["queueSequence"] = blocked_thread["queueSequence"]
        server._write_feedback_thread(waiting_thread)
        ledger["feedbackThreads"][waiting["feedback_thread_id"]]["queueSequence"] = blocked_thread["queueSequence"]
        server._save_feedback_ledger(ledger)

        with self.assertRaises(PermissionError):
            server._cancel_feedback_thread(
                old["feedback_thread_id"], "orphaned morning run", system_cleanup=True
            )
        result = server._cancel_feedback_thread(
            old["feedback_thread_id"],
            "orphaned morning run",
            system_cleanup=True,
            confirm_system_cleanup=True,
        )
        self.assertIsNone(result["activated_feedback_thread_id"])
        self._device_reload()
        server._collect_thread_updates(waiting["feedback_thread_id"], waiting["owner_token"])
        self.assertEqual(server._read_feedback_thread(blocked["feedback_thread_id"])["state"], "blocked")
        self.assertEqual(server._read_feedback_thread(waiting["feedback_thread_id"])["state"], "open")

    def test_terminal_snapshot_cannot_remain_active_in_stale_ledger(self):
        terminal = self._create("terminal-stale-active")
        waiting = self._create("terminal-next")
        terminal_thread = server._read_feedback_thread(terminal["feedback_thread_id"])
        terminal_thread["state"] = "cancelled"
        server._write_feedback_thread(terminal_thread)
        ledger = server._load_feedback_ledger()

        server._refresh_feedback_ledger_locked(ledger)

        self.assertIsNone(ledger["activeFeedbackThreadID"])
        self.assertEqual(server._read_feedback_thread(waiting["feedback_thread_id"])["state"], "queued")

    def test_stale_device_snapshot_cannot_resurrect_cancelled_thread(self):
        created = self._create("no-resurrection")
        remote_path = self._target_root() / server._feedback_remote_root() / created["feedback_thread_id"] / "thread.json"
        stale_remote = json.loads(remote_path.read_text())
        server._cancel_feedback_thread(
            created["feedback_thread_id"], "orphan cleanup", created["owner_token"]
        )
        remote_path.write_text(json.dumps(stale_remote))

        updates = server._collect_thread_updates(
            created["feedback_thread_id"], created["owner_token"]
        )

        self.assertEqual(updates["state"], "cancelled")
        self.assertEqual(server._read_feedback_thread(created["feedback_thread_id"])["state"], "cancelled")

    def test_resolved_thread_cannot_be_reopened(self):
        first = self._create("immutable-resolved")
        server._set_feedback_thread_state(
            first["feedback_thread_id"], "resolved", first["owner_token"], "model",
            "resolve-immutable", 1, 1,
        )
        for requested_state in ("queued", "open"):
            with self.assertRaisesRegex(RuntimeError, "resolved and immutable"):
                server._set_feedback_thread_state(
                    first["feedback_thread_id"], requested_state, first["owner_token"], "human",
                    f"no-reopen-{requested_state}", 1, 1,
                )

    def test_owner_idempotency_and_optimistic_concurrency(self):
        created = self._create("owner")
        thread_id = created["feedback_thread_id"]
        token = created["owner_token"]
        duplicate_create = server._create_feedback_thread(
            "owner", "Objective owner", "Review owner", requester_id="terra-test",
            idempotency_key="create-owner", owner_token=token,
        )
        self.assertTrue(duplicate_create["idempotent"])
        with self.assertRaises(PermissionError):
            server._get_feedback_thread(thread_id, "wrong")

        posted = server._post_thread_message(thread_id, "Revision ready", token, "revision-1", 1)
        duplicate = server._post_thread_message(thread_id, "ignored duplicate", token, "revision-1")
        self.assertEqual(posted["message"]["id"], duplicate["message"]["id"])
        self.assertTrue(duplicate["idempotent"])
        with self.assertRaises(RuntimeError):
            server._set_feedback_thread_state(
                thread_id, "resolved", token, "model", "stale-resolve", 1, 1
            )

    def test_feedback_watch_delivers_each_human_sequence_once(self):
        created = self._create("automatic-wake")
        thread_id = created["feedback_thread_id"]
        token = created["owner_token"]
        sequence = self._append_remote_human(created)

        pending = server._get_feedback_watch_state(thread_id, token)
        self.assertTrue(pending["wake_eligible"])
        self.assertEqual([message["sequence"] for message in pending["human_messages"]], [sequence])
        acknowledged = server._acknowledge_feedback_wake(
            thread_id, token, pending["wake_id"], sequence
        )
        self.assertFalse(acknowledged["idempotent"])
        duplicate_ack = server._acknowledge_feedback_wake(
            thread_id, token, pending["wake_id"], sequence
        )
        self.assertTrue(duplicate_ack["idempotent"])
        repeated_poll = server._get_feedback_watch_state(thread_id, token, after_sequence=0)
        self.assertFalse(repeated_poll["wake_eligible"])

    def test_feedback_watch_close_does_not_mutate_thread(self):
        created = self._create("close-watch")
        thread_id = created["feedback_thread_id"]
        token = created["owner_token"]
        state_before = server._read_feedback_thread(thread_id)["state"]

        closed = server._close_feedback_watch(thread_id, token, "task finished")
        duplicate = server._close_feedback_watch(thread_id, token, "task finished")

        self.assertFalse(closed["idempotent"])
        self.assertTrue(duplicate["idempotent"])
        self.assertEqual(server._read_feedback_thread(thread_id)["state"], state_before)

    def test_feedback_watch_rejects_wrong_owner_and_cursor_regression(self):
        created = self._create("watch-owner")
        thread_id = created["feedback_thread_id"]
        token = created["owner_token"]
        sequence = self._append_remote_human(created)
        with self.assertRaises(PermissionError):
            server._get_feedback_watch_state(thread_id, "wrong")
        pending = server._get_feedback_watch_state(thread_id, token)
        server._acknowledge_feedback_wake(thread_id, token, pending["wake_id"], sequence)
        self._append_remote_human(created, "Second response")
        next_pending = server._get_feedback_watch_state(thread_id, token)
        with self.assertRaises(ValueError):
            server._acknowledge_feedback_wake(thread_id, token, next_pending["wake_id"], sequence - 1)

    def test_single_choice_validation_and_append_only_message(self):
        created = self._create("choice")
        self._append_remote_human(created, "Initial answer")
        server._collect_thread_updates(created["feedback_thread_id"], created["owner_token"])
        result = server._ask_thread_question(
            created["feedback_thread_id"],
            "Which is better?",
            created["owner_token"],
            "choice-1",
            kind="single-choice",
            options=[{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
            allows_comment=True,
            allows_attachment=True,
            expected_last_sequence=2,
        )
        self.assertEqual(result["message"]["sequence"], 3)
        self.assertEqual(result["message"]["interaction"]["kind"], "single-choice")
        with self.assertRaises(ValueError):
            server._ask_thread_question(
                created["feedback_thread_id"], "Bad", created["owner_token"], "bad-choice",
                kind="single-choice", options=[{"id": "a", "label": "A"}],
            )

    def test_question_requires_active_slot_and_rejects_unanswered_interaction(self):
        active = self._create("question-active")
        queued = self._create("question-queued")

        with self.assertRaisesRegex(RuntimeError, "already has an unanswered interaction"):
            server._ask_thread_question(
                active["feedback_thread_id"], "Too soon", active["owner_token"], "too-soon"
            )
        with self.assertRaisesRegex(RuntimeError, "does not own the active device slot"):
            server._ask_thread_question(
                queued["feedback_thread_id"], "Not visible", queued["owner_token"], "queued-question"
            )

    def test_question_atomically_reopens_awaiting_model_and_is_idempotent(self):
        created = self._create("question-reopen")
        thread_id = created["feedback_thread_id"]
        token = created["owner_token"]
        self._append_remote_human(created, "Done")
        collected = server._collect_thread_updates(thread_id, token)
        self.assertEqual(collected["state"], "awaiting-model")

        presented = server._ask_thread_question(
            thread_id, "Next focused check", token, "next-question", expected_last_sequence=2
        )

        self.assertEqual(presented["state"], "open")
        self.assertEqual(server._read_feedback_thread(thread_id)["state"], "open")
        ledger = server._load_feedback_ledger()
        self.assertEqual(ledger["activeFeedbackThreadID"], thread_id)
        self.assertEqual(ledger["feedbackThreads"][thread_id]["state"], "open")
        duplicate = server._ask_thread_question(
            thread_id, "Ignored duplicate", token, "next-question"
        )
        self.assertTrue(duplicate["idempotent"])
        self.assertEqual(duplicate["message"]["id"], presented["message"]["id"])

    def test_codex_dispatch_suppresses_duplicate_wake_until_acknowledged(self):
        created = self._create("codex-dispatch")
        thread_id = created["feedback_thread_id"]
        token = created["owner_token"]
        sequence = self._append_remote_human(created, "Ready")

        pending = server._get_feedback_watch_state(thread_id, token, after_sequence=1)
        self.assertTrue(pending["wake_eligible"])
        dispatched = server._record_feedback_wake_dispatch(
            thread_id, token, pending["wake_id"], "turn-test", "start"
        )
        self.assertEqual(dispatched["dispatchedWakeID"], pending["wake_id"])

        duplicate = server._get_feedback_watch_state(thread_id, token, after_sequence=1)
        self.assertFalse(duplicate["wake_eligible"])
        acknowledged = server._acknowledge_feedback_wake(
            thread_id, token, pending["wake_id"], sequence
        )
        self.assertNotIn("dispatchedWakeID", acknowledged)
        self.assertNotIn("bridgePID", acknowledged)

    def test_arm_codex_bridge_passes_owner_capability_only_over_stdin(self):
        created = self._create("codex-arm")

        class CaptureInput(io.StringIO):
            def close(self):
                self.flushed_value = self.getvalue()
                super().close()

        class FakeProcess:
            pid = 4242
            stdin = CaptureInput()

            def terminate(self):
                raise AssertionError("bridge should not be terminated")

        fake_process = FakeProcess()
        with mock.patch.object(server.subprocess, "Popen", return_value=fake_process) as popen:
            armed = server._arm_codex_feedback_wake(
                created["feedback_thread_id"], created["owner_token"], 1, 1.0, 60.0
            )

        command = popen.call_args.args[0]
        self.assertNotIn(created["owner_token"], " ".join(command))
        registration = json.loads(fake_process.stdin.flushed_value)
        self.assertEqual(registration["owner_token"], created["owner_token"])
        self.assertEqual(registration["requester_id"], "terra-test")
        self.assertEqual(armed["bridge_pid"], 4242)

    def test_plain_message_cannot_present_unactionable_step_while_awaiting_model(self):
        created = self._create("plain-message-rejected")
        thread_id = created["feedback_thread_id"]
        token = created["owner_token"]
        self._append_remote_human(created, "Done")
        collected = server._collect_thread_updates(thread_id, token)
        self.assertEqual(collected["state"], "awaiting-model")

        with self.assertRaisesRegex(RuntimeError, "use ask_thread_question"):
            server._post_thread_message(
                thread_id, "Next check", token, "unactionable-next-step", expected_last_sequence=2
            )

        thread = server._read_feedback_thread(thread_id)
        self.assertEqual(thread["state"], "awaiting-model")
        self.assertEqual(thread["lastSequence"], 2)
        self.assertNotIn("unactionable-next-step", thread["messageIdempotency"])

    def test_device_promotion_remains_single_authority_when_third_thread_is_created(self):
        first = self._create("device-authority-first")
        second = self._create("device-authority-second")

        first_remote = (
            self._target_root()
            / server._feedback_remote_root()
            / first["feedback_thread_id"]
            / "thread.json"
        )
        first_snapshot = json.loads(first_remote.read_text())
        first_snapshot["state"] = "blocked"
        first_snapshot["revision"] += 1
        first_remote.write_text(json.dumps(first_snapshot))
        self._device_reload()
        server._collect_thread_updates(first["feedback_thread_id"], first["owner_token"])
        server._collect_thread_updates(second["feedback_thread_id"], second["owner_token"])

        third = server._create_feedback_thread(
            "device-authority-third",
            "Objective device-authority-third",
            "Review device-authority-third",
            scenario="scenario-device-authority-third",
            requester_id="terra-test",
            idempotency_key="create-device-authority-third",
        )

        self.assertEqual(third["state"], "queued")
        states = {
            thread_id: server._read_feedback_thread(thread_id)["state"]
            for thread_id in (
                first["feedback_thread_id"],
                second["feedback_thread_id"],
                third["feedback_thread_id"],
            )
        }
        self.assertEqual(sum(state in server.FEEDBACK_SLOT_STATES for state in states.values()), 1)
        self.assertEqual(states[second["feedback_thread_id"]], "open")

    def test_device_queue_sequence_advances_host_allocator_without_host_promotion(self):
        first = self._create("device-sequence-first")
        second = self._create("device-sequence-second")
        first_thread = server._read_feedback_thread(first["feedback_thread_id"])
        first_thread["state"] = "queued"
        first_thread["queueSequence"] = 7
        server._write_feedback_thread(first_thread)

        ledger = server._load_feedback_ledger()
        server._refresh_feedback_ledger_locked(ledger)

        self.assertEqual(ledger["nextQueueSequence"], 8)
        self.assertEqual(server._read_feedback_thread(second["feedback_thread_id"])["state"], "queued")

    def test_collection_never_advances_or_reassigns_feedback_queue(self):
        active = self._create("collect-active")
        queued = self._create("collect-queued")
        remote_path = (
            self._target_root()
            / server._feedback_remote_root()
            / active["feedback_thread_id"]
            / "thread.json"
        )
        remote = json.loads(remote_path.read_text())
        remote["state"] = "resolved"
        remote["revision"] += 1
        remote_path.write_text(json.dumps(remote))
        ledger_before = server._load_feedback_ledger()

        server._collect_thread_updates(active["feedback_thread_id"], active["owner_token"])

        ledger_after = server._load_feedback_ledger()
        self.assertEqual(ledger_after, ledger_before)
        self.assertEqual(server._read_feedback_thread(queued["feedback_thread_id"])["state"], "queued")

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

        updates = server._collect_thread_updates(thread_id, created["owner_token"], after_sequence=1)
        self.assertEqual([item["sequence"] for item in updates["messages"]], [2])
        paths = updates["attachments"][0]["collectedPaths"]
        self.assertTrue(Path(paths["cleanPath"]).exists())
        self.assertTrue(Path(paths["annotatedPath"]).exists())
        exported = server._export_feedback_thread(thread_id, created["owner_token"])
        self.assertTrue(Path(exported["markdown_path"]).exists())
        self.assertEqual(len(exported["attachment_paths"]), 2)
        server._collect_thread_updates(thread_id, created["owner_token"], after_sequence=1)
        merged_events = [json.loads(line) for line in server.FEEDBACK_EVENT_LOG.read_text().splitlines()]
        self.assertEqual(sum(event.get("eventID") == "device-event-one" for event in merged_events), 1)
        self.assertTrue((server.FEEDBACK_COLLECTED / thread_id / "device-events.jsonl").exists())


class FeedbackThreadProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def test_discovery_remains_responsive_while_await_thread_response_is_pending(self):
        started = threading.Event()

        def pending_collection(*_args, **_kwargs):
            started.set()
            return {"state": "open", "messages": [], "last_sequence": 1}

        with mock.patch.object(server, "_collect_thread_updates", side_effect=pending_collection):
            async with create_connected_server_and_client_session(
                server.mcp,
                read_timeout_seconds=timedelta(seconds=2),
            ) as session:
                await session.initialize()
                pending = asyncio.create_task(
                    session.call_tool(
                        "await_thread_response",
                        {
                            "feedback_thread_id": "feedback-pending",
                            "owner_token": "owner-token",
                            "after_sequence": 1,
                            "timeout_seconds": 0.75,
                        },
                    )
                )
                self.assertTrue(await asyncio.to_thread(started.wait, 0.5))

                loop = asyncio.get_running_loop()
                began = loop.time()
                tools = await asyncio.wait_for(session.list_tools(), timeout=0.25)
                elapsed = loop.time() - began

                tool_names = {tool.name for tool in tools.tools}
                self.assertIn("await_thread_response", tool_names)
                self.assertTrue({
                    "get_feedback_watch_state",
                    "arm_codex_feedback_wake",
                    "acknowledge_feedback_wake",
                    "close_feedback_watch",
                    "create_review_run",
                    "collect_review_run",
                    "export_review_run",
                }.issubset(tool_names))
                self.assertLess(elapsed, 0.25)
                self.assertFalse(pending.done())
                await pending


if __name__ == "__main__":
    unittest.main()
