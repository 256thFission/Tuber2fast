"""Development-only PencilFixtureMCP for TuberNotes.

Pushes agent interaction requests into the Debug app on a connected simulator
or physical device, where the human sees the prompt, draws once, and the app
indexes the result. Agents collect durable JSON without Mac-side human steps.
"""

from __future__ import annotations

import json
import fcntl
import hashlib
import hmac
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

APP_ID = "com.tubernotes.app"
ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / "Fixtures"
LOCAL_STORE = ROOT / ".pencil-fixtures"
REQUESTS = LOCAL_STORE / "requests"
COLLECTED = LOCAL_STORE / "collected"
QUEUE_LEDGER = LOCAL_STORE / "queue-ledger.json"
QUEUE_LOCK = LOCAL_STORE / "queue.lock"
QUEUE_SCHEMA_VERSION = 2
DEFAULT_STALE_AFTER_SECONDS = 3600.0
_THREAD_LOCK = threading.RLock()
FEEDBACK_STORE = ROOT / ".feedback-threads"
FEEDBACK_THREADS = FEEDBACK_STORE / "threads"
FEEDBACK_COLLECTED = FEEDBACK_STORE / "collected"
FEEDBACK_ATTACHMENTS = FEEDBACK_STORE / "attachments"
FEEDBACK_LEDGER = FEEDBACK_STORE / "queue.json"
FEEDBACK_LOCK = FEEDBACK_STORE / "store.lock"
FEEDBACK_EVENT_LOG = FEEDBACK_STORE / "event-log.jsonl"
FEEDBACK_SCHEMA_VERSION = 1
FEEDBACK_STATES = {"queued", "open", "awaiting-model", "blocked", "resolved", "cancelled"}
FEEDBACK_SLOT_STATES = {"open", "awaiting-model"}
FEEDBACK_TERMINAL_STATES = {"resolved", "cancelled"}
FEEDBACK_QUESTION_KINDS = {"free-text", "single-choice"}
_FEEDBACK_THREAD_LOCK = threading.RLock()
mcp = FastMCP("PencilFixtureMCP")


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _safe_name(name: str) -> str:
    value = re.sub(r"[^a-z0-9-]+", "-", name.lower()).strip("-")
    if not value:
        raise ValueError("Name must contain a letter or digit")
    return value[:48]


def _run(cmd: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, capture_output=True, text=True, env=env)


def _simulator_data_dir(simulator_id: str = "booted") -> Path:
    result = _run(["xcrun", "simctl", "get_app_container", simulator_id, APP_ID, "data"])
    return Path(result.stdout.strip())


def _booted_simulator_udid() -> str | None:
    result = _run(["xcrun", "simctl", "list", "devices", "booted"], check=False)
    if result.returncode != 0:
        return None
    match = re.search(r"\(([0-9A-F-]{36})\)\s+\(Booted\)", result.stdout)
    return match.group(1) if match else None


def _available_device_id() -> str | None:
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as handle:
        json_path = Path(handle.name)
    try:
        result = _run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", str(json_path)],
            check=False,
        )
        if result.returncode != 0 or not json_path.exists():
            return None
        payload = json.loads(json_path.read_text())
    finally:
        json_path.unlink(missing_ok=True)

    devices = (
        payload.get("result", {}).get("devices")
        or payload.get("devices")
        or []
    )
    for device in devices:
        state = str(device.get("connectionProperties", {}).get("tunnelState")
                    or device.get("state")
                    or "").lower()
        availability = str(device.get("availabilityError") or "")
        identifier = (
            device.get("identifier")
            or device.get("hardwareProperties", {}).get("udid")
            or device.get("udid")
        )
        # Prefer connected/available physical devices.
        if identifier and not availability and ("connected" in state or "available" in state or state == ""):
            # Skip if explicitly unavailable.
            info = str(device).lower()
            if "unavailable" in info:
                continue
            return str(identifier)
    return None


def _ensure_local_dirs() -> None:
    REQUESTS.mkdir(parents=True, exist_ok=True)
    COLLECTED.mkdir(parents=True, exist_ok=True)
    FIXTURES.mkdir(parents=True, exist_ok=True)


def _atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(handle, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _ensure_feedback_dirs() -> None:
    for path in (FEEDBACK_THREADS, FEEDBACK_COLLECTED, FEEDBACK_ATTACHMENTS):
        path.mkdir(parents=True, exist_ok=True)


@contextmanager
def _locked_feedback_store() -> Any:
    """Serialize thread, message sequence, queue, and event mutations."""
    _ensure_feedback_dirs()
    with _FEEDBACK_THREAD_LOCK:
        with FEEDBACK_LOCK.open("a+") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def _empty_feedback_ledger() -> dict[str, Any]:
    return {
        "schemaVersion": FEEDBACK_SCHEMA_VERSION,
        "nextQueueSequence": 1,
        "nextPrioritySequence": -1,
        "activeFeedbackThreadID": None,
        "creationKeys": {},
        "feedbackThreads": {},
        "updatedAt": _utc_now(),
    }


def _load_feedback_ledger() -> dict[str, Any]:
    if not FEEDBACK_LEDGER.exists():
        return _empty_feedback_ledger()
    try:
        value = json.loads(FEEDBACK_LEDGER.read_text())
    except (OSError, json.JSONDecodeError):
        return _empty_feedback_ledger()
    value.setdefault("schemaVersion", FEEDBACK_SCHEMA_VERSION)
    value.setdefault("nextQueueSequence", 1)
    value.setdefault("nextPrioritySequence", -1)
    value.setdefault("activeFeedbackThreadID", None)
    value.setdefault("creationKeys", {})
    value.setdefault("feedbackThreads", {})
    return value


def _save_feedback_ledger(ledger: dict[str, Any]) -> None:
    ledger["schemaVersion"] = FEEDBACK_SCHEMA_VERSION
    ledger["updatedAt"] = _utc_now()
    _atomic_write_json(FEEDBACK_LEDGER, ledger)


def _feedback_thread_dir(feedback_thread_id: str) -> Path:
    return FEEDBACK_THREADS / feedback_thread_id


def _feedback_thread_file(feedback_thread_id: str) -> Path:
    return _feedback_thread_dir(feedback_thread_id) / "thread.json"


def _feedback_message_file(feedback_thread_id: str, sequence: int) -> Path:
    return _feedback_thread_dir(feedback_thread_id) / "messages" / f"{sequence:06d}.json"


def _read_feedback_thread(feedback_thread_id: str) -> dict[str, Any]:
    path = _feedback_thread_file(feedback_thread_id)
    if not path.exists():
        raise FileNotFoundError(f"Unknown feedback thread: {feedback_thread_id}")
    value = json.loads(path.read_text())
    if value.get("id") != feedback_thread_id:
        raise RuntimeError(f"Feedback thread identity mismatch for {feedback_thread_id}")
    return value


def _write_feedback_thread(value: dict[str, Any]) -> None:
    _atomic_write_json(_feedback_thread_file(value["id"]), value)


def _read_feedback_messages(feedback_thread_id: str) -> list[dict[str, Any]]:
    directory = _feedback_thread_dir(feedback_thread_id) / "messages"
    if not directory.exists():
        return []
    messages = [json.loads(path.read_text()) for path in sorted(directory.glob("*.json"))]
    for message in messages:
        if message.get("feedbackThreadID") != feedback_thread_id:
            raise RuntimeError(f"Message identity mismatch in feedback thread {feedback_thread_id}")
    return messages


def _feedback_owner_token_hash(owner_token: str) -> str:
    return hashlib.sha256(owner_token.encode("utf-8")).hexdigest()


def _validate_feedback_owner(value: dict[str, Any], owner_token: str | None) -> None:
    if not owner_token:
        raise PermissionError(f"owner_token is required for feedback thread {value['id']}")
    expected = value.get("owner", {}).get("tokenHash")
    if not expected or not hmac.compare_digest(expected, _feedback_owner_token_hash(owner_token)):
        raise PermissionError(f"owner_token does not own feedback thread {value['id']}")


def _append_feedback_event(event_type: str, thread: dict[str, Any], **fields: Any) -> dict[str, Any]:
    event = {
        "eventID": f"feedback-event-{uuid.uuid4().hex}",
        "event": event_type,
        "feedbackThreadID": thread["id"],
        "timestamp": _utc_now(),
        "sequence": thread.get("eventSequence", 0) + 1,
        "source": "backend",
        "sourceSequence": thread.get("eventSequence", 0) + 1,
        "requesterID": thread.get("requester", {}).get("id"),
        "scenario": thread.get("scenario"),
        "surfaceRevision": thread.get("surfaceRevision", 0),
        **{key: value for key, value in fields.items() if value is not None},
    }
    thread["eventSequence"] = event["sequence"]
    FEEDBACK_EVENT_LOG.parent.mkdir(parents=True, exist_ok=True)
    with FEEDBACK_EVENT_LOG.open("a") as stream:
        stream.write(json.dumps(event, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    return event


def _merge_device_feedback_events(device_log: Path, feedback_thread_id: str) -> int:
    """Merge one device event stream into the canonical Mac JSONL by event ID."""
    if not device_log.exists():
        return 0
    existing_ids: set[str] = set()
    if FEEDBACK_EVENT_LOG.exists():
        for line in FEEDBACK_EVENT_LOG.read_text().splitlines():
            try:
                event_id = json.loads(line).get("eventID")
            except json.JSONDecodeError:
                continue
            if event_id:
                existing_ids.add(str(event_id))

    merged: list[dict[str, Any]] = []
    for line in device_log.read_text().splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        event_id = str(event.get("eventID") or "")
        if event.get("feedbackThreadID") != feedback_thread_id or not event_id or event_id in existing_ids:
            continue
        event.setdefault("source", "device")
        existing_ids.add(event_id)
        merged.append(event)
    if not merged:
        return 0

    FEEDBACK_EVENT_LOG.parent.mkdir(parents=True, exist_ok=True)
    with FEEDBACK_EVENT_LOG.open("a") as stream:
        for event in merged:
            stream.write(json.dumps(event, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    return len(merged)


def _feedback_remote_root() -> Path:
    return Path("Documents") / "feedback-threads"


def _push_feedback_snapshot(thread: dict[str, Any], message: dict[str, Any] | None = None) -> str | None:
    """Best-effort device mirror; local durability does not depend on device availability."""
    target = thread["delivery"]["target"]
    try:
        _push_to_target(target, _feedback_thread_file(thread["id"]), _feedback_remote_root() / thread["id"] / "thread.json")
        if message is not None:
            _push_to_target(
                target,
                _feedback_message_file(thread["id"], message["sequence"]),
                _feedback_remote_root() / thread["id"] / "messages" / f"{message['sequence']:06d}.json",
            )
        _push_to_target(target, FEEDBACK_LEDGER, _feedback_remote_root() / "queue.json")
        return None
    except Exception as exc:  # noqa: BLE001
        return str(exc)


def _normalize_idempotency_key(value: str) -> str:
    key = value.strip()
    if not key:
        raise ValueError("idempotency_key must not be empty")
    if len(key) > 200:
        raise ValueError("idempotency_key must be 200 characters or fewer")
    return key


def _message_response(thread: dict[str, Any], message: dict[str, Any], *, idempotent: bool) -> dict[str, Any]:
    return {
        "feedback_thread_id": thread["id"],
        "state": thread["state"],
        "message": message,
        "last_sequence": thread["lastSequence"],
        "revision": thread["revision"],
        "idempotent": idempotent,
    }


def _append_feedback_message_locked(
    thread: dict[str, Any],
    *,
    author: str,
    body: str | None,
    idempotency_key: str,
    interaction: dict[str, Any] | None = None,
    attachments: list[dict[str, Any]] | None = None,
    surface_directive: dict[str, Any] | None = None,
    in_reply_to: str | None = None,
) -> tuple[dict[str, Any], bool]:
    key = _normalize_idempotency_key(idempotency_key)
    existing_sequence = thread.setdefault("messageIdempotency", {}).get(key)
    if existing_sequence is not None:
        return json.loads(_feedback_message_file(thread["id"], int(existing_sequence)).read_text()), True
    if thread["state"] in FEEDBACK_TERMINAL_STATES:
        raise RuntimeError(f"Feedback thread {thread['id']} is {thread['state']} and immutable")
    normalized_body = body.strip() if body is not None else None
    if not normalized_body and not interaction and not attachments:
        raise ValueError("A feedback message needs body, interaction, or attachments")
    sequence = int(thread.get("lastSequence", 0)) + 1
    message = {
        "id": f"feedback-message-{uuid.uuid4().hex}",
        "feedbackThreadID": thread["id"],
        "sequence": sequence,
        "author": author,
        "body": normalized_body,
        "createdAt": _utc_now(),
        "interaction": interaction,
        "attachments": attachments or [],
        "surfaceDirective": surface_directive,
        "inReplyTo": in_reply_to,
        "idempotencyKey": key,
    }
    _atomic_write_json(_feedback_message_file(thread["id"], sequence), message)
    thread["lastSequence"] = sequence
    thread["messageIDs"].append(message["id"])
    thread["messageIdempotency"][key] = sequence
    thread["updatedAt"] = message["createdAt"]
    thread["revision"] = int(thread.get("revision", 0)) + 1
    _append_feedback_event("message-posted", thread, messageID=message["id"], messageSequence=sequence, author=author)
    _write_feedback_thread(thread)
    return message, False


@contextmanager
def _locked_ledger() -> Any:
    """Serialize queue mutations across threads and independent MCP processes."""
    _ensure_local_dirs()
    with _THREAD_LOCK:
        with QUEUE_LOCK.open("a+") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def _empty_ledger() -> dict[str, Any]:
    return {
        "schemaVersion": QUEUE_SCHEMA_VERSION,
        "nextSequence": 1,
        "updatedAt": _utc_now(),
        "requests": {},
    }


def _load_ledger() -> dict[str, Any]:
    if not QUEUE_LEDGER.exists():
        return _empty_ledger()
    try:
        ledger = json.loads(QUEUE_LEDGER.read_text())
    except (OSError, json.JSONDecodeError):
        return _empty_ledger()
    ledger.setdefault("schemaVersion", QUEUE_SCHEMA_VERSION)
    ledger.setdefault("nextSequence", 1)
    ledger.setdefault("requests", {})
    return ledger


def _save_ledger(ledger: dict[str, Any]) -> None:
    ledger["schemaVersion"] = QUEUE_SCHEMA_VERSION
    ledger["updatedAt"] = _utc_now()
    _atomic_write_json(QUEUE_LEDGER, ledger)


def _read_local_request(request_id: str) -> dict[str, Any]:
    path = _request_paths(request_id)["local"]
    if not path.exists():
        raise FileNotFoundError(f"Unknown interaction request: {request_id}")
    payload = json.loads(path.read_text())
    if payload.get("id") != request_id:
        raise RuntimeError(f"Local request identity mismatch for {request_id}")
    return payload


def _owner_token_hash(owner_token: str) -> str:
    return hashlib.sha256(owner_token.encode("utf-8")).hexdigest()


def _validate_owner(request: dict[str, Any], owner_token: str | None) -> str:
    owner = request.get("owner")
    # Compatibility is intentionally limited to records created before schema v2.
    if not owner:
        return "request-id-only-legacy"
    expected = owner.get("tokenHash")
    if not owner_token:
        raise PermissionError(f"owner_token is required for request {request['id']}")
    if not expected or not hmac.compare_digest(expected, _owner_token_hash(owner_token)):
        raise PermissionError(f"owner_token does not own request {request['id']}")
    return "owner-token"


def _parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _is_expired(request: dict[str, Any]) -> bool:
    expires_at = _parse_timestamp(request.get("expiresAt"))
    return expires_at is not None and expires_at <= datetime.now(timezone.utc)


def _target_key(target: dict[str, str]) -> str:
    return f"{target['kind']}:{target['id']}"


def _request_paths(request_id: str) -> dict[str, Path]:
    return {
        "local": REQUESTS / f"{request_id}.json",
        "pending_rel": Path("Documents") / "agent-requests" / "pending" / f"{request_id}.json",
        "completed_rel": Path("Documents") / "agent-requests" / "completed" / f"{request_id}.json",
        "fixture_rel": Path("Documents") / "pen-fixtures",
        "index_rel": Path("Documents") / "pen-fixtures" / "index.json",
    }


def _write_request(request: dict[str, Any]) -> Path:
    _ensure_local_dirs()
    path = REQUESTS / f"{request['id']}.json"
    _atomic_write_json(path, request)
    return path


def _push_to_simulator(local_file: Path, relative_destination: Path, simulator_id: str = "booted") -> dict[str, str]:
    data_dir = _simulator_data_dir(simulator_id)
    destination = data_dir / relative_destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(local_file, destination)
    return {"target": "simulator", "id": simulator_id, "path": str(destination)}


def _pull_from_simulator(
    relative_source: Path,
    local_destination: Path,
    simulator_id: str = "booted",
) -> Path | None:
    source = _simulator_data_dir(simulator_id) / relative_source
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


def _push_to_device(device_id: str, local_file: Path, relative_destination: Path) -> dict[str, str]:
    # Copy into app data container; destination is relative to the container root.
    _run(
        [
            "xcrun",
            "devicectl",
            "device",
            "copy",
            "to",
            "--device",
            device_id,
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            APP_ID,
            "--source",
            str(local_file),
            "--destination",
            str(relative_destination),
        ]
    )
    return {"target": "device", "device": device_id, "path": str(relative_destination)}


def _pull_from_device(device_id: str, relative_source: Path, local_destination: Path) -> Path | None:
    local_destination.parent.mkdir(parents=True, exist_ok=True)
    result = _run(
        [
            "xcrun",
            "devicectl",
            "device",
            "copy",
            "from",
            "--device",
            device_id,
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            APP_ID,
            "--source",
            str(relative_source),
            "--destination",
            str(local_destination),
        ],
        check=False,
    )
    if result.returncode != 0:
        return None
    return local_destination if local_destination.exists() else None


def _launch_simulator(env: dict[str, str], simulator_id: str = "booted") -> dict[str, str]:
    merged = os.environ.copy()
    for key, value in env.items():
        merged[f"SIMCTL_CHILD_{key}"] = value
    result = _run(
        ["xcrun", "simctl", "launch", "--terminate-running-process", simulator_id, APP_ID],
        env=merged,
    )
    return {"target": "simulator", "id": simulator_id, "process": result.stdout.strip()}


def _launch_device(device_id: str, env: dict[str, str]) -> dict[str, str]:
    result = _run(
        [
            "xcrun",
            "devicectl",
            "device",
            "process",
            "launch",
            "--device",
            device_id,
            "--terminate-existing",
            "--environment-variables",
            json.dumps(env),
            APP_ID,
        ],
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "device launch failed")
    return {"target": "device", "device": device_id, "process": result.stdout.strip()}


def _select_target(prefer_device: bool = True) -> dict[str, str]:
    if prefer_device:
        device_id = _available_device_id()
        if device_id:
            return {"kind": "device", "id": device_id}
    simulator_id = _booted_simulator_udid()
    if simulator_id:
        return {"kind": "simulator", "id": simulator_id}
    device_id = _available_device_id()
    if device_id:
        return {"kind": "device", "id": device_id}
    raise RuntimeError("No booted simulator or available connected device found")


def _push_to_target(target: dict[str, str], local_file: Path, relative_destination: Path) -> dict[str, str]:
    if target["kind"] == "simulator":
        return _push_to_simulator(local_file, relative_destination, target["id"])
    return _push_to_device(target["id"], local_file, relative_destination)


def _pull_from_target(
    target: dict[str, str],
    relative_source: Path,
    local_destination: Path,
) -> Path | None:
    if target["kind"] == "simulator":
        return _pull_from_simulator(relative_source, local_destination, target["id"])
    return _pull_from_device(target["id"], relative_source, local_destination)


def _launch_target(target: dict[str, str], env: dict[str, str]) -> dict[str, str]:
    if target["kind"] == "simulator":
        return _launch_simulator(env, target["id"])
    return _launch_device(target["id"], env)


def _active_ledger_entries(ledger: dict[str, Any]) -> list[dict[str, Any]]:
    active: list[dict[str, Any]] = []
    for request_id, entry in ledger["requests"].items():
        if entry.get("state") not in {"queued", "delivered"}:
            continue
        try:
            request = _read_local_request(request_id)
        except (FileNotFoundError, json.JSONDecodeError, RuntimeError):
            entry["state"] = "missing"
            continue
        if _is_expired(request):
            request["status"] = "cancelled"
            request["completedAt"] = request.get("completedAt") or _utc_now()
            request["cancellationReason"] = request.get("cancellationReason") or "stale-expired"
            request.setdefault("delivery", {})["state"] = "cancelled"
            _write_request(request)
            entry["state"] = "cancelled"
            continue
        active.append(entry)
    return sorted(active, key=lambda entry: (entry.get("sequence", 0), entry.get("id", "")))


def _delivery_response(request: dict[str, Any], owner_token: str, *, idempotent: bool) -> dict[str, Any]:
    return {
        **request,
        "owner_token": owner_token,
        "local_request": str(_request_paths(request["id"])["local"]),
        "idempotent": idempotent,
        "human_step": "On the connected test device, complete only the single request shown in the banner. Queued requests advance automatically.",
    }


def _deliver_request_locked(
    request: dict[str, Any],
    ledger: dict[str, Any],
    owner_token: str,
    *,
    should_launch: bool,
) -> dict[str, Any]:
    entry = ledger["requests"][request["id"]]
    if entry.get("state") == "delivered":
        return _delivery_response(request, owner_token, idempotent=True)

    target = request["delivery"]["target"]
    request["delivery"].update(
        {
            "state": "delivered",
            "deliveredAt": _utc_now(),
            "launchAttempted": should_launch,
        }
    )
    local_path = _write_request(request)
    try:
        request["delivery"]["pushed"] = _push_to_target(
            target,
            local_path,
            _request_paths(request["id"])["pending_rel"],
        )
        if should_launch:
            request["delivery"]["launch"] = _launch_target(
                target,
                {
                    "TUBER_SCENARIO": request.get("scenario") or "blank-canvas",
                },
            )
        entry["state"] = "delivered"
        entry["deliveredAt"] = request["delivery"]["deliveredAt"]
    except Exception as exc:  # noqa: BLE001
        request["delivery"]["state"] = "delivery-failed"
        request["delivery"]["error"] = str(exc)
        entry["state"] = "delivery-failed"
        entry["error"] = str(exc)
    _write_request(request)
    _save_ledger(ledger)
    return _delivery_response(request, owner_token, idempotent=False)


def _enqueue_request(
    request: dict[str, Any],
    owner_token: str,
    *,
    prefer_device: bool,
) -> dict[str, Any]:
    with _locked_ledger():
        ledger = _load_ledger()
        existing_entry = ledger["requests"].get(request["id"])
        if existing_entry:
            existing = _read_local_request(request["id"])
            _validate_owner(existing, owner_token)
            return _delivery_response(existing, owner_token, idempotent=True)
        active = _active_ledger_entries(ledger)
        target = dict(active[0]["target"]) if active else _select_target(prefer_device=prefer_device)
        sequence = int(ledger.get("nextSequence", 1))
        ledger["nextSequence"] = sequence + 1
        request["delivery"] = {
            "sequence": sequence,
            "state": "queued",
            "target": target,
            "selectedAt": _utc_now(),
            "launchAttempted": False,
        }
        ledger["requests"][request["id"]] = {
            "id": request["id"],
            "requesterID": request["requester"]["id"],
            "sequence": sequence,
            "state": "queued",
            "target": target,
            "createdAt": request["createdAt"],
            "expiresAt": request.get("expiresAt"),
        }
        _write_request(request)
        _save_ledger(ledger)
        return _deliver_request_locked(
            request,
            ledger,
            owner_token,
            should_launch=not active,
        )


def _deliver_request(request_id: str, owner_token: str) -> dict[str, Any]:
    """Idempotent internal retry seam used by pure tests and future recovery tooling."""
    with _locked_ledger():
        request = _read_local_request(request_id)
        _validate_owner(request, owner_token)
        ledger = _load_ledger()
        entry = ledger["requests"].get(request_id)
        if not entry:
            raise RuntimeError(f"Request {request_id} is missing from queue ledger")
        active_others = [item for item in _active_ledger_entries(ledger) if item["id"] != request_id]
        return _deliver_request_locked(
            request,
            ledger,
            owner_token,
            should_launch=not active_others and entry.get("state") != "delivered",
        )


def _request_target(
    request: dict[str, Any],
    *,
    prefer_device: bool,
) -> tuple[dict[str, str], bool]:
    target = request.get("delivery", {}).get("target")
    if target:
        return dict(target), False
    # Pre-v2 compatibility: select once, persist, and never switch on later polls.
    target = _select_target(prefer_device=prefer_device)
    request["delivery"] = {
        "sequence": None,
        "state": "legacy-pinned",
        "target": target,
        "selectedAt": _utc_now(),
    }
    _write_request(request)
    return target, True


def _validate_collected_payload(
    local_request: dict[str, Any],
    payload: dict[str, Any],
    target: dict[str, str],
) -> None:
    request_id = local_request["id"]
    if payload.get("id") != request_id:
        raise RuntimeError(f"Collected payload for {request_id} contained id {payload.get('id')!r}")
    local_requester = local_request.get("requester", {}).get("id")
    payload_requester = payload.get("requester", {}).get("id")
    if local_requester and payload_requester != local_requester:
        raise RuntimeError(f"Collected payload requester mismatch for {request_id}")
    payload_target = payload.get("delivery", {}).get("target")
    if payload_target and _target_key(payload_target) != _target_key(target):
        raise RuntimeError(f"Collected payload target mismatch for {request_id}")


def _record_local_terminal(request: dict[str, Any], state: str) -> None:
    _write_request(request)
    ledger = _load_ledger()
    entry = ledger["requests"].get(request["id"])
    if entry:
        entry["state"] = state
        entry["completedAt"] = request.get("completedAt") or _utc_now()
        _save_ledger(ledger)


def _collect_request(
    request_id: str,
    *,
    owner_token: str | None,
    prefer_device: bool = True,
) -> dict[str, Any]:
    _ensure_local_dirs()
    paths = _request_paths(request_id)
    with _locked_ledger():
        local_request = _read_local_request(request_id)
        owner_validation = _validate_owner(local_request, owner_token)
        target, legacy_target_selected = _request_target(local_request, prefer_device=prefer_device)
    stamp = request_id
    out_dir = COLLECTED / stamp
    out_dir.mkdir(parents=True, exist_ok=True)

    completed_local = out_dir / "request.json"
    fixture_dir = out_dir / "pen-fixtures"
    index_local = out_dir / "index.json"

    completed = _pull_from_target(target, paths["completed_rel"], completed_local)
    _pull_from_target(target, paths["fixture_rel"], fixture_dir)
    _pull_from_target(target, paths["index_rel"], index_local)

    result: dict[str, Any] = {
        "id": request_id,
        "target": target,
        "collected_dir": str(out_dir),
        "status": "pending",
        "owner_validation": owner_validation,
        "legacy_target_selected": legacy_target_selected,
    }

    if completed and completed.exists():
        payload = json.loads(completed.read_text())
        _validate_collected_payload(local_request, payload, target)
        payload.setdefault("requester", local_request.get("requester"))
        payload.setdefault("owner", local_request.get("owner"))
        payload.setdefault("delivery", local_request.get("delivery"))
        result["status"] = payload.get("status", "completed")
        result["request"] = payload
        fixture_name = payload.get("fixtureName")
        if fixture_name and fixture_dir.exists():
            source = fixture_dir / f"{fixture_name}.json"
            if source.exists():
                dest = FIXTURES / f"{fixture_name}.json"
                shutil.copy2(source, dest)
                result["fixture_path"] = str(dest)
                result["fixture"] = json.loads(source.read_text())
                payload["fixturePath"] = str(dest)
        if index_local.exists():
            result["index"] = json.loads(index_local.read_text())
        with _locked_ledger():
            _record_local_terminal(payload, "completed")
        return result

    # Still pending?
    pending_local = out_dir / "pending.json"
    pending = _pull_from_target(target, paths["pending_rel"], pending_local)
    if pending and pending.exists():
        pending_payload = json.loads(pending.read_text())
        _validate_collected_payload(local_request, pending_payload, target)
        result["request"] = pending_payload
        result["status"] = result["request"].get("status", "awaiting-human")
    return result


def _normalized_requester_id(requester_id: str) -> str:
    value = requester_id.strip()
    if not value:
        raise ValueError("requester_id must not be empty")
    if len(value) > 128:
        raise ValueError("requester_id must be 128 characters or fewer")
    return value


def _new_request(
    *,
    kind: str,
    title: str,
    prompt: str,
    scenario: str,
    requester_id: str,
    fixture_name: str | None,
    stale_after_seconds: float,
) -> tuple[dict[str, Any], str]:
    if stale_after_seconds <= 0:
        raise ValueError("stale_after_seconds must be greater than zero")
    now = datetime.now(timezone.utc).replace(microsecond=0)
    request_id = f"{kind}-{uuid.uuid4().hex}"
    owner_token = secrets.token_urlsafe(32)
    request = {
        "schemaVersion": QUEUE_SCHEMA_VERSION,
        "id": request_id,
        "kind": kind,
        "title": title,
        "prompt": prompt,
        "status": "awaiting-human",
        "createdAt": now.isoformat().replace("+00:00", "Z"),
        "completedAt": None,
        "expiresAt": (now + timedelta(seconds=stale_after_seconds)).isoformat().replace("+00:00", "Z"),
        "cancellationReason": None,
        "fixtureName": fixture_name,
        "fixturePath": None,
        "eventCount": None,
        "verdict": None,
        "humanNotes": None,
        "scenario": scenario,
        "screenshotHint": None,
        "requester": {"id": _normalized_requester_id(requester_id)},
        "owner": {
            "tokenHash": _owner_token_hash(owner_token),
            "tokenRequired": True,
        },
    }
    return request, owner_token


def _cancel_request(
    request_id: str,
    *,
    owner_token: str | None,
    reason: str,
    prefer_device: bool,
) -> dict[str, Any]:
    normalized_reason = reason.strip() or "cancelled-by-requester"
    with _locked_ledger():
        request = _read_local_request(request_id)
        owner_validation = _validate_owner(request, owner_token)
        if request.get("status") in {"cancelled", "recorded", "answered"}:
            return {
                "id": request_id,
                "status": request.get("status"),
                "idempotent": True,
                "owner_validation": owner_validation,
                "target": request.get("delivery", {}).get("target"),
            }
        target, legacy_target_selected = _request_target(request, prefer_device=prefer_device)
        request["status"] = "cancelled"
        request["completedAt"] = _utc_now()
        request["cancellationReason"] = normalized_reason
        request.setdefault("delivery", {})["state"] = "cancelled"
        _record_local_terminal(request, "cancelled")

    delivery_error: str | None = None
    try:
        _push_to_target(target, _request_paths(request_id)["local"], _request_paths(request_id)["pending_rel"])
    except Exception as exc:  # noqa: BLE001
        delivery_error = str(exc)
    return {
        "id": request_id,
        "status": "cancelled",
        "idempotent": False,
        "owner_validation": owner_validation,
        "target": target,
        "legacy_target_selected": legacy_target_selected,
        "cancellationReason": normalized_reason,
        "delivery_error": delivery_error,
    }


@mcp.tool()
def request_pen_fixture(
    description: str,
    scenario: str = "blank-canvas",
    prefer_device: bool = True,
    requester_id: str = "anonymous-agent",
    stale_after_seconds: float = DEFAULT_STALE_AFTER_SECONDS,
) -> dict:
    """Push a Pencil capture request into the Debug app on the connected test device.

    The app shows the agent prompt at the top. The human draws once; the app
    indexes the fixture. Call collect_interaction / await_interaction afterward.
    """
    unique_suffix = uuid.uuid4().hex[:12]
    fixture_name = f"{_safe_name(description)[:35]}-{unique_suffix}"
    request, owner_token = _new_request(
        kind="pen-fixture",
        title="Pencil capture",
        prompt=description,
        scenario=scenario,
        requester_id=requester_id,
        fixture_name=fixture_name,
        stale_after_seconds=stale_after_seconds,
    )
    return _enqueue_request(request, owner_token, prefer_device=prefer_device)


@mcp.tool()
def request_human_review(
    prompt: str,
    title: str = "Human review",
    scenario: str = "blank-canvas",
    prefer_device: bool = True,
    requester_id: str = "anonymous-agent",
    stale_after_seconds: float = DEFAULT_STALE_AFTER_SECONDS,
) -> dict:
    """Push a review request into the Debug app banner for a verdict + optional note."""
    request, owner_token = _new_request(
        kind="review",
        title=title,
        prompt=prompt,
        scenario=scenario,
        requester_id=requester_id,
        fixture_name=None,
        stale_after_seconds=stale_after_seconds,
    )
    return _enqueue_request(request, owner_token, prefer_device=prefer_device)


@mcp.tool()
def collect_interaction(
    request_id: str,
    prefer_device: bool = True,
    owner_token: str | None = None,
) -> dict:
    """Pull a completed interaction (fixture, verdict, notes, index) from the connected device."""
    return _collect_request(request_id, owner_token=owner_token, prefer_device=prefer_device)


@mcp.tool()
def await_interaction(
    request_id: str,
    timeout_seconds: float = 180.0,
    prefer_device: bool = True,
    owner_token: str | None = None,
) -> dict:
    """Poll until the human completes the in-app request, then return the collected artifacts."""
    deadline = time.time() + timeout_seconds
    last: dict[str, Any] = {}
    while time.time() < deadline:
        last = _collect_request(request_id, owner_token=owner_token, prefer_device=prefer_device)
        status = last.get("status")
        if status in {"recorded", "answered", "cancelled"}:
            return last
        time.sleep(2.0)
    last["status"] = "timeout"
    last["message"] = f"Timed out after {timeout_seconds:.0f}s waiting for request {request_id}"
    return last


@mcp.tool()
def cancel_interaction(
    request_id: str,
    owner_token: str | None = None,
    reason: str = "cancelled-by-requester",
    prefer_device: bool = True,
) -> dict:
    """Cancel one owned pending request without changing its pinned delivery target."""
    return _cancel_request(
        request_id,
        owner_token=owner_token,
        reason=reason,
        prefer_device=prefer_device,
    )


@mcp.tool()
def list_interactions(prefer_device: bool = True) -> dict:
    """Return the on-device interaction index plus locally collected entries."""
    _ensure_local_dirs()
    target = _select_target(prefer_device=prefer_device)
    index_local = COLLECTED / "_index.json"
    if target["kind"] == "simulator":
        pulled = _pull_from_simulator(Path("Documents") / "pen-fixtures" / "index.json", index_local)
    else:
        pulled = _pull_from_device(target["id"], Path("Documents") / "pen-fixtures" / "index.json", index_local)

    index = json.loads(index_local.read_text()) if pulled and index_local.exists() else {"entries": []}
    local_requests = sorted(REQUESTS.glob("*.json"))
    return {
        "target": target,
        "index": index,
        "local_requests": [json.loads(path.read_text()) for path in local_requests],
        "collected_dirs": sorted(path.name for path in COLLECTED.iterdir() if path.is_dir()),
    }


@mcp.tool()
def list_pen_fixtures() -> list[dict]:
    """List committed fixtures and any currently installed simulator fixtures."""
    paths = {path.stem: path for path in FIXTURES.glob("*.json")}
    try:
        sim_dir = _simulator_data_dir() / "Documents" / "pen-fixtures"
        paths.update({path.stem: path for path in sim_dir.glob("*.json") if path.name != "index.json"})
    except Exception:
        pass
    return [
        {
            "name": name,
            "path": str(path),
            "source": "repo" if FIXTURES in path.parents else "device-or-simulator",
        }
        for name, path in sorted(paths.items())
    ]


@mcp.tool()
def get_pen_fixture(name: str) -> dict:
    """Return a normalized Pencil event fixture by name."""
    safe_name = _safe_name(name)
    candidates = [
        FIXTURES / f"{safe_name}.json",
    ]
    try:
        candidates.append(_simulator_data_dir() / "Documents" / "pen-fixtures" / f"{safe_name}.json")
    except Exception:
        pass
    for path in candidates:
        if path.exists():
            return json.loads(path.read_text())
    raise FileNotFoundError(safe_name)


@mcp.tool()
def replay_pen_fixture(name: str, prefer_device: bool = False) -> dict:
    """Install a fixture and relaunch through the app's controlled replay seam."""
    safe_name = _safe_name(name)
    source = FIXTURES / f"{safe_name}.json"
    if not source.exists():
        # Fall back to simulator copy if present.
        try:
            candidate = _simulator_data_dir() / "Documents" / "pen-fixtures" / f"{safe_name}.json"
            if candidate.exists():
                source = candidate
        except Exception as exc:  # noqa: BLE001
            raise FileNotFoundError(safe_name) from exc
    if not source.exists():
        raise FileNotFoundError(safe_name)

    target = _select_target(prefer_device=prefer_device)
    rel = Path("Documents") / "pen-fixtures" / f"{safe_name}.json"
    if target["kind"] == "simulator":
        _push_to_simulator(source, rel)
        launch = _launch_simulator({"TUBER_PEN_FIXTURE": safe_name, "TUBER_SCENARIO": "blank-canvas"})
    else:
        _push_to_device(target["id"], source, rel)
        launch = _launch_device(target["id"], {"TUBER_PEN_FIXTURE": safe_name, "TUBER_SCENARIO": "blank-canvas"})
    return {"name": safe_name, "status": "launched", **launch}


def _advance_feedback_queue_locked(ledger: dict[str, Any]) -> dict[str, Any] | None:
    active_id = ledger.get("activeFeedbackThreadID")
    if active_id:
        try:
            active = _read_feedback_thread(active_id)
        except (FileNotFoundError, json.JSONDecodeError, RuntimeError):
            active = None
        if active and active.get("state") in FEEDBACK_SLOT_STATES:
            return active
        ledger["activeFeedbackThreadID"] = None

    candidates = sorted(
        (
            entry
            for entry in ledger["feedbackThreads"].values()
            if entry.get("state") == "queued"
        ),
        key=lambda entry: (entry.get("queueSequence", 0), entry.get("id", "")),
    )
    if not candidates:
        return None
    next_entry = candidates[0]
    thread = _read_feedback_thread(next_entry["id"])
    thread["state"] = "open"
    thread["updatedAt"] = _utc_now()
    thread["revision"] = int(thread.get("revision", 0)) + 1
    next_entry["state"] = "open"
    ledger["activeFeedbackThreadID"] = thread["id"]
    _append_feedback_event("thread-activated", thread)
    _write_feedback_thread(thread)
    return thread


def _feedback_create_response(
    thread: dict[str, Any], owner_token: str, *, idempotent: bool, delivery_error: str | None = None
) -> dict[str, Any]:
    return {
        "feedback_thread_id": thread["id"],
        "owner_token": owner_token,
        "state": thread["state"],
        "queue_sequence": thread["queueSequence"],
        "last_sequence": thread["lastSequence"],
        "revision": thread["revision"],
        "target": thread["delivery"]["target"],
        "local_thread": str(_feedback_thread_file(thread["id"])),
        "idempotent": idempotent,
        "delivery_error": delivery_error,
        "human_step": "Review and reply in the active feedback thread on the pinned test device.",
    }


@mcp.tool()
def create_feedback_thread(
    title: str,
    objective: str,
    prompt: str,
    scenario: str = "blank-canvas",
    requester_id: str = "anonymous-agent",
    idempotency_key: str | None = None,
    prefer_device: bool = True,
    owner_token: str | None = None,
) -> dict:
    """Create an owned persistent feedback thread and enqueue it on one pinned target."""
    normalized_title = title.strip()
    normalized_objective = objective.strip()
    normalized_prompt = prompt.strip()
    if not normalized_title or not normalized_objective or not normalized_prompt:
        raise ValueError("title, objective, and prompt must not be empty")
    requester = _normalized_requester_id(requester_id)
    creation_key = _normalize_idempotency_key(idempotency_key or f"create-{uuid.uuid4().hex}")
    scoped_key = f"{requester}:{creation_key}"
    token = owner_token or secrets.token_urlsafe(32)

    with _locked_feedback_store():
        ledger = _load_feedback_ledger()
        existing_id = ledger["creationKeys"].get(scoped_key)
        if existing_id:
            thread = _read_feedback_thread(existing_id)
            _validate_feedback_owner(thread, owner_token)
            return _feedback_create_response(thread, owner_token, idempotent=True)

        active = _advance_feedback_queue_locked(ledger)
        target = dict(active["delivery"]["target"]) if active else None
        if target is None:
            target = next(
                (
                    dict(entry["target"])
                    for entry in sorted(ledger["feedbackThreads"].values(), key=lambda value: value.get("queueSequence", 0))
                    if entry.get("state") not in FEEDBACK_TERMINAL_STATES and entry.get("target")
                ),
                None,
            )
        if target is None:
            target = _select_target(prefer_device=prefer_device)
        feedback_thread_id = f"feedback-{uuid.uuid4().hex}"
        created_at = _utc_now()
        queue_sequence = int(ledger["nextQueueSequence"])
        state = "queued" if active else "open"
        thread = {
            "schemaVersion": FEEDBACK_SCHEMA_VERSION,
            "id": feedback_thread_id,
            "title": normalized_title,
            "objective": normalized_objective,
            "state": state,
            "createdAt": created_at,
            "updatedAt": created_at,
            "requester": {"id": requester},
            "owner": {"tokenHash": _feedback_owner_token_hash(token), "tokenRequired": True},
            "scenario": scenario.strip() or "blank-canvas",
            "surfaceRevision": 0,
            "queueSequence": queue_sequence,
            "lastSequence": 0,
            "lastHumanSequence": 0,
            "lastConsumedSequence": 0,
            "revision": 1,
            "eventSequence": 0,
            "messageIDs": [],
            "messageIdempotency": {},
            "delivery": {"target": target, "pinnedAt": created_at},
        }
        _write_feedback_thread(thread)
        _append_feedback_event("thread-created", thread)
        _append_feedback_event("thread-activated" if state == "open" else "thread-queued", thread)
        _write_feedback_thread(thread)
        message, _ = _append_feedback_message_locked(
            thread,
            author="model",
            body=normalized_prompt,
            idempotency_key=f"{creation_key}:initial",
            interaction={"kind": "free-text", "state": "awaiting-human", "allowsAttachment": True},
        )
        ledger["nextQueueSequence"] = queue_sequence + 1
        ledger["creationKeys"][scoped_key] = feedback_thread_id
        ledger["feedbackThreads"][feedback_thread_id] = {
            "id": feedback_thread_id,
            "queueSequence": queue_sequence,
            "state": state,
            "target": target,
        }
        if state == "open":
            ledger["activeFeedbackThreadID"] = feedback_thread_id
        _save_feedback_ledger(ledger)
        delivery_error = _push_feedback_snapshot(thread, message)
        if state == "open" and delivery_error is None:
            try:
                _launch_target(target, {"TUBER_SCENARIO": thread["scenario"]})
            except Exception as exc:  # noqa: BLE001
                delivery_error = str(exc)
        return _feedback_create_response(thread, token, idempotent=False, delivery_error=delivery_error)


@mcp.tool()
def post_thread_message(
    feedback_thread_id: str,
    body: str,
    owner_token: str,
    idempotency_key: str,
    expected_last_sequence: int | None = None,
    surface_directive: dict[str, Any] | None = None,
) -> dict:
    """Append one idempotent model message without implicitly resetting the product surface."""
    with _locked_feedback_store():
        thread = _read_feedback_thread(feedback_thread_id)
        _validate_feedback_owner(thread, owner_token)
        if expected_last_sequence is not None and expected_last_sequence != thread["lastSequence"]:
            raise RuntimeError(
                f"stale feedback thread: expected last sequence {expected_last_sequence}, actual {thread['lastSequence']}"
            )
        message, duplicate = _append_feedback_message_locked(
            thread,
            author="model",
            body=body,
            idempotency_key=idempotency_key,
            surface_directive=surface_directive,
        )
        delivery_error = None if duplicate else _push_feedback_snapshot(thread, message)
        return {**_message_response(thread, message, idempotent=duplicate), "delivery_error": delivery_error}


@mcp.tool()
def ask_thread_question(
    feedback_thread_id: str,
    prompt: str,
    owner_token: str,
    idempotency_key: str,
    kind: str = "free-text",
    options: list[dict[str, str]] | None = None,
    allows_comment: bool = True,
    allows_attachment: bool = True,
    expected_last_sequence: int | None = None,
) -> dict:
    """Append a free-text or single-choice question; answers remain append-only."""
    if kind not in FEEDBACK_QUESTION_KINDS:
        raise ValueError(f"Unsupported question kind: {kind}")
    normalized_options: list[dict[str, str]] = []
    if kind == "single-choice":
        if not options or len(options) < 2:
            raise ValueError("single-choice questions require at least two options")
        seen: set[str] = set()
        for option in options:
            option_id = str(option.get("id", "")).strip()
            label = str(option.get("label", "")).strip()
            if not option_id or not label or option_id in seen:
                raise ValueError("single-choice option IDs and labels must be nonempty and IDs unique")
            seen.add(option_id)
            normalized_options.append({"id": option_id, "label": label})
    elif options:
        raise ValueError("options are only valid for single-choice questions")

    with _locked_feedback_store():
        thread = _read_feedback_thread(feedback_thread_id)
        _validate_feedback_owner(thread, owner_token)
        if expected_last_sequence is not None and expected_last_sequence != thread["lastSequence"]:
            raise RuntimeError(
                f"stale feedback thread: expected last sequence {expected_last_sequence}, actual {thread['lastSequence']}"
            )
        interaction = {
            "kind": kind,
            "state": "awaiting-human",
            "options": normalized_options,
            "allowsComment": bool(allows_comment),
            "allowsAttachment": bool(allows_attachment),
        }
        message, duplicate = _append_feedback_message_locked(
            thread,
            author="model",
            body=prompt,
            idempotency_key=idempotency_key,
            interaction=interaction,
        )
        if not duplicate:
            _append_feedback_event("interaction-presented", thread, messageID=message["id"], interactionKind=kind)
            _write_feedback_thread(thread)
        delivery_error = None if duplicate else _push_feedback_snapshot(thread, message)
        return {**_message_response(thread, message, idempotent=duplicate), "delivery_error": delivery_error}


def _copy_collected_attachments(feedback_thread_id: str, message: dict[str, Any], remote_dir: Path) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    destination = FEEDBACK_ATTACHMENTS / feedback_thread_id
    for metadata in message.get("attachments") or []:
        attachment = dict(metadata)
        if not attachment.get("id"):
            raise RuntimeError(f"Collected attachment is missing an ID in message {message.get('id')}")
        owning_message = attachment.get("messageID")
        if owning_message and owning_message != message.get("id"):
            raise RuntimeError(f"Collected attachment owner mismatch in message {message.get('id')}")
        attachment["messageID"] = message.get("id")
        collected_paths: dict[str, str] = {}
        for key in ("cleanPath", "annotatedPath"):
            relative = attachment.get(key)
            if not relative:
                continue
            candidate = (remote_dir / relative).resolve()
            if remote_dir.resolve() not in candidate.parents or not candidate.is_file():
                continue
            destination.mkdir(parents=True, exist_ok=True)
            target = destination / candidate.name
            shutil.copy2(candidate, target)
            collected_paths[key] = str(target)
        if collected_paths:
            attachment["collectedPaths"] = collected_paths
        results.append(attachment)
    return results


def _sync_feedback_thread_from_target(feedback_thread_id: str) -> None:
    local_thread = _read_feedback_thread(feedback_thread_id)
    target = local_thread["delivery"]["target"]
    remote_dir = FEEDBACK_COLLECTED / feedback_thread_id / "device"
    pulled = _pull_from_target(target, _feedback_remote_root() / feedback_thread_id, remote_dir)
    if not pulled or not remote_dir.exists() or not (remote_dir / "thread.json").exists():
        return
    device_events = FEEDBACK_COLLECTED / feedback_thread_id / "device-events.jsonl"
    pulled_events = _pull_from_target(target, _feedback_remote_root() / "events.jsonl", device_events)
    if pulled_events:
        _merge_device_feedback_events(device_events, feedback_thread_id)
    remote_thread = json.loads((remote_dir / "thread.json").read_text())
    if remote_thread.get("id") != feedback_thread_id:
        raise RuntimeError(f"Collected feedback thread identity mismatch for {feedback_thread_id}")
    if int(remote_thread.get("lastSequence", 0)) < int(local_thread.get("lastSequence", 0)):
        return
    remote_messages_dir = remote_dir / "messages"
    for path in sorted(remote_messages_dir.glob("*.json")) if remote_messages_dir.exists() else []:
        message = json.loads(path.read_text())
        sequence = int(message.get("sequence", 0))
        if message.get("feedbackThreadID") != feedback_thread_id or sequence <= 0:
            raise RuntimeError(f"Invalid collected message for feedback thread {feedback_thread_id}")
        local_path = _feedback_message_file(feedback_thread_id, sequence)
        if local_path.exists():
            existing = json.loads(local_path.read_text())
            if existing.get("id") != message.get("id"):
                raise RuntimeError(f"Append-only message conflict at sequence {sequence}")
        else:
            message["attachments"] = _copy_collected_attachments(feedback_thread_id, message, remote_dir)
            _atomic_write_json(local_path, message)
            _append_feedback_event("message-collected", local_thread, messageID=message.get("id"), messageSequence=sequence)
    remote_thread["owner"] = local_thread["owner"]
    remote_thread["delivery"] = local_thread["delivery"]
    remote_thread.setdefault("messageIdempotency", local_thread.get("messageIdempotency", {}))
    remote_thread["eventSequence"] = max(
        int(remote_thread.get("eventSequence", 0)), int(local_thread.get("eventSequence", 0))
    )
    _write_feedback_thread(remote_thread)
    ledger = _load_feedback_ledger()
    entry = ledger["feedbackThreads"].get(feedback_thread_id)
    if entry:
        activated: dict[str, Any] | None = None
        entry["state"] = remote_thread["state"]
        entry["queueSequence"] = remote_thread.get("queueSequence", entry.get("queueSequence", 0))
        if remote_thread["state"] in {"blocked", *FEEDBACK_TERMINAL_STATES}:
            if ledger.get("activeFeedbackThreadID") == feedback_thread_id:
                ledger["activeFeedbackThreadID"] = None
            activated = _advance_feedback_queue_locked(ledger)
        elif remote_thread["state"] in FEEDBACK_SLOT_STATES:
            ledger["activeFeedbackThreadID"] = feedback_thread_id
        _save_feedback_ledger(ledger)
        if activated:
            _push_feedback_snapshot(activated)


@mcp.tool()
def collect_thread_updates(
    feedback_thread_id: str,
    owner_token: str,
    after_sequence: int = 0,
) -> dict:
    """Collect new device messages and screenshot metadata using an exclusive sequence cursor."""
    if after_sequence < 0:
        raise ValueError("after_sequence must not be negative")
    with _locked_feedback_store():
        thread = _read_feedback_thread(feedback_thread_id)
        _validate_feedback_owner(thread, owner_token)
        _sync_feedback_thread_from_target(feedback_thread_id)
        thread = _read_feedback_thread(feedback_thread_id)
        messages = [message for message in _read_feedback_messages(feedback_thread_id) if message["sequence"] > after_sequence]
        attachments = [attachment for message in messages for attachment in message.get("attachments") or []]
        return {
            "feedback_thread_id": feedback_thread_id,
            "state": thread["state"],
            "messages": messages,
            "attachments": attachments,
            "after_sequence": after_sequence,
            "next_cursor": thread["lastSequence"],
            "last_sequence": thread["lastSequence"],
            "revision": thread["revision"],
        }


@mcp.tool()
def await_thread_response(
    feedback_thread_id: str,
    owner_token: str,
    after_sequence: int,
    timeout_seconds: float = 180.0,
) -> dict:
    """Poll until a newer human message or terminal/blocked state is collected."""
    deadline = time.time() + timeout_seconds
    last: dict[str, Any] = {}
    while time.time() < deadline:
        last = collect_thread_updates(feedback_thread_id, owner_token, after_sequence)
        human_messages = [message for message in last["messages"] if message.get("author") == "human"]
        if human_messages or last["state"] in {"blocked", *FEEDBACK_TERMINAL_STATES}:
            last["status"] = "response"
            return last
        time.sleep(2.0)
    last["status"] = "timeout"
    last["message"] = f"Timed out after {timeout_seconds:.0f}s waiting for feedback thread {feedback_thread_id}"
    return last


@mcp.tool()
def set_feedback_thread_state(
    feedback_thread_id: str,
    state: str,
    owner_token: str,
    actor: str,
    idempotency_key: str,
    expected_last_sequence: int,
    last_consumed_sequence: int,
) -> dict:
    """Optimistically transition lifecycle state and advance FIFO when the slot is released."""
    if state not in FEEDBACK_STATES:
        raise ValueError(f"Unsupported requested state: {state}")
    if actor not in {"model", "human", "system"}:
        raise ValueError(f"Unsupported actor: {actor}")
    key = _normalize_idempotency_key(idempotency_key)
    with _locked_feedback_store():
        thread = _read_feedback_thread(feedback_thread_id)
        _validate_feedback_owner(thread, owner_token)
        existing = thread.setdefault("stateIdempotency", {}).get(key)
        if existing:
            return {**existing, "idempotent": True}
        if expected_last_sequence != thread["lastSequence"] or last_consumed_sequence < thread["lastSequence"]:
            raise RuntimeError(
                f"stale feedback thread: expected/consumed {expected_last_sequence}/{last_consumed_sequence}, "
                f"actual {thread['lastSequence']}"
            )
        current = thread["state"]
        if current == "cancelled" or (current == "resolved" and state not in {"open", "queued"}):
            raise RuntimeError(f"Feedback thread {feedback_thread_id} is {current} and immutable")
        if state == "queued" and current not in {"blocked", "resolved"}:
            raise RuntimeError("Only blocked or explicitly reopened resolved feedback threads may re-enter the queue")
        if current == state:
            result = {
                "feedback_thread_id": feedback_thread_id,
                "state": state,
                "actor": actor,
                "last_consumed_sequence": last_consumed_sequence,
            }
            thread["stateIdempotency"][key] = result
            _write_feedback_thread(thread)
            return {**result, "idempotent": True}

        ledger = _load_feedback_ledger()
        if state == "open":
            active_id = ledger.get("activeFeedbackThreadID")
            if active_id and active_id != feedback_thread_id:
                raise RuntimeError(f"Feedback thread {active_id} already owns the device slot")
        thread["state"] = state
        thread["lastConsumedSequence"] = last_consumed_sequence
        thread["updatedAt"] = _utc_now()
        thread["revision"] = int(thread.get("revision", 0)) + 1
        event_name = {
            "blocked": "thread-blocked",
            "resolved": "thread-resolved",
            "cancelled": "thread-cancelled",
            "queued": "thread-reopened" if current == "resolved" else "thread-requeued",
            "open": "thread-reopened" if current == "resolved" else "thread-opened",
            "awaiting-model": "thread-awaiting-model",
        }[state]
        _append_feedback_event(event_name, thread, actor=actor, lastConsumedSequence=last_consumed_sequence)
        result = {
            "feedback_thread_id": feedback_thread_id,
            "state": state,
            "actor": actor,
            "last_consumed_sequence": last_consumed_sequence,
            "revision": thread["revision"],
        }
        thread["stateIdempotency"][key] = result
        entry = ledger["feedbackThreads"][feedback_thread_id]
        entry["state"] = state
        activated: dict[str, Any] | None = None
        if state == "queued":
            if actor == "human":
                queue_sequence = int(ledger["nextPrioritySequence"])
                ledger["nextPrioritySequence"] = queue_sequence - 1
            else:
                queue_sequence = int(ledger["nextQueueSequence"])
                ledger["nextQueueSequence"] = queue_sequence + 1
            thread["queueSequence"] = queue_sequence
            entry["queueSequence"] = queue_sequence
        _write_feedback_thread(thread)
        if state in FEEDBACK_SLOT_STATES:
            ledger["activeFeedbackThreadID"] = feedback_thread_id
        elif ledger.get("activeFeedbackThreadID") == feedback_thread_id:
            ledger["activeFeedbackThreadID"] = None
            activated = _advance_feedback_queue_locked(ledger)
        elif state == "queued" and not ledger.get("activeFeedbackThreadID"):
            activated = _advance_feedback_queue_locked(ledger)
        if activated and activated["id"] == feedback_thread_id:
            thread = activated
            result["state"] = activated["state"]
            result["revision"] = activated["revision"]
            thread.setdefault("stateIdempotency", {})[key] = result
            _write_feedback_thread(thread)
        _save_feedback_ledger(ledger)
        delivery_error = _push_feedback_snapshot(thread)
        if activated:
            activation_error = _push_feedback_snapshot(activated)
            delivery_error = delivery_error or activation_error
        return {**result, "idempotent": False, "delivery_error": delivery_error}


@mcp.tool()
def get_feedback_thread(feedback_thread_id: str, owner_token: str, include_messages: bool = True) -> dict:
    """Return the durable thread snapshot, optionally with its append-only message history."""
    with _locked_feedback_store():
        thread = _read_feedback_thread(feedback_thread_id)
        _validate_feedback_owner(thread, owner_token)
        public_thread = {key: value for key, value in thread.items() if key != "owner"}
        return {
            "feedback_thread": public_thread,
            "messages": _read_feedback_messages(feedback_thread_id) if include_messages else [],
            "local_thread": str(_feedback_thread_file(feedback_thread_id)),
        }


@mcp.tool()
def export_feedback_thread(feedback_thread_id: str, owner_token: str) -> dict:
    """Export one evidence-oriented Markdown transcript plus durable attachment paths."""
    with _locked_feedback_store():
        thread = _read_feedback_thread(feedback_thread_id)
        _validate_feedback_owner(thread, owner_token)
        messages = _read_feedback_messages(feedback_thread_id)
        export_dir = FEEDBACK_COLLECTED / feedback_thread_id / "evidence"
        export_dir.mkdir(parents=True, exist_ok=True)
        attachment_paths: list[str] = []
        lines = [
            f"# {thread['title']}",
            "",
            f"- Feedback thread: `{thread['id']}`",
            f"- State: `{thread['state']}`",
            f"- Scenario: `{thread['scenario']}`",
            f"- Objective: {thread['objective']}",
            "",
            "## Transcript",
            "",
        ]
        for message in messages:
            lines.extend([f"### {message['sequence']}. {message['author']}", "", message.get("body") or "_(attachment/interaction only)_", ""])
            for attachment in message.get("attachments") or []:
                paths = attachment.get("collectedPaths") or {}
                for label, path in sorted(paths.items()):
                    attachment_paths.append(path)
                    lines.append(f"- {label}: `{path}`")
                if paths:
                    lines.append("")
        markdown_path = export_dir / "feedback-thread.md"
        markdown_path.write_text("\n".join(lines).rstrip() + "\n")
        _append_feedback_event("thread-exported", thread, markdownPath=str(markdown_path))
        _write_feedback_thread(thread)
        return {
            "feedback_thread_id": feedback_thread_id,
            "markdown_path": str(markdown_path),
            "attachment_paths": sorted(set(attachment_paths)),
        }


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
