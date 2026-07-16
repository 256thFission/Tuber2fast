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


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
