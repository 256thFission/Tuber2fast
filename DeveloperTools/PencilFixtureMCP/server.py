"""Development-only PencilFixtureMCP for TuberNotes.

Pushes agent interaction requests into the Debug app on a connected simulator
or physical device, where the human sees the prompt, draws once, and the app
indexes the result. Agents collect durable JSON without Mac-side human steps.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

APP_ID = "com.tubernotes.app"
ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / "Fixtures"
LOCAL_STORE = ROOT / ".pencil-fixtures"
REQUESTS = LOCAL_STORE / "requests"
COLLECTED = LOCAL_STORE / "collected"
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


def _simulator_data_dir() -> Path:
    result = _run(["xcrun", "simctl", "get_app_container", "booted", APP_ID, "data"])
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
    path.write_text(json.dumps(request, indent=2) + "\n")
    return path


def _push_to_simulator(local_file: Path, relative_destination: Path) -> dict[str, str]:
    data_dir = _simulator_data_dir()
    destination = data_dir / relative_destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(local_file, destination)
    return {"target": "simulator", "path": str(destination)}


def _pull_from_simulator(relative_source: Path, local_destination: Path) -> Path | None:
    source = _simulator_data_dir() / relative_source
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


def _launch_simulator(env: dict[str, str]) -> dict[str, str]:
    merged = os.environ.copy()
    for key, value in env.items():
        merged[f"SIMCTL_CHILD_{key}"] = value
    result = _run(
        ["xcrun", "simctl", "launch", "--terminate-running-process", "booted", APP_ID],
        env=merged,
    )
    return {"target": "simulator", "process": result.stdout.strip()}


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
    if _booted_simulator_udid():
        return {"kind": "simulator", "id": "booted"}
    device_id = _available_device_id()
    if device_id:
        return {"kind": "device", "id": device_id}
    raise RuntimeError("No booted simulator or available connected device found")


def _deliver_request(request: dict[str, Any], *, prefer_device: bool = True) -> dict[str, Any]:
    local_path = _write_request(request)
    paths = _request_paths(request["id"])
    errors: list[str] = []

    order = ["device", "simulator"] if prefer_device else ["simulator", "device"]
    for kind in order:
        try:
            if kind == "simulator":
                if not _booted_simulator_udid():
                    continue
                pushed = _push_to_simulator(local_path, paths["pending_rel"])
                launch = _launch_simulator(
                    {
                        "TUBER_SCENARIO": request.get("scenario") or "blank-canvas",
                        "TUBER_RECORD_PEN_FIXTURE": request.get("fixtureName") or request["id"],
                        "TUBER_PEN_DESCRIPTION": request["prompt"],
                    }
                )
            else:
                device_id = _available_device_id()
                if not device_id:
                    continue
                pushed = _push_to_device(device_id, local_path, paths["pending_rel"])
                launch = _launch_device(
                    device_id,
                    {
                        "TUBER_SCENARIO": request.get("scenario") or "blank-canvas",
                        "TUBER_RECORD_PEN_FIXTURE": request.get("fixtureName") or request["id"],
                        "TUBER_PEN_DESCRIPTION": request["prompt"],
                    },
                )
            return {
                **request,
                "local_request": str(local_path),
                "delivery": pushed,
                "launch": launch,
                "human_step": "On the connected test device, read the banner and draw once (or tap a verdict). No Mac-side steps.",
            }
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{kind}: {exc}")
            continue

    raise RuntimeError("Failed to deliver request to device or simulator: " + "; ".join(errors))


def _collect_request(request_id: str, *, prefer_device: bool = True) -> dict[str, Any]:
    _ensure_local_dirs()
    paths = _request_paths(request_id)
    target = _select_target(prefer_device=prefer_device)
    stamp = request_id
    out_dir = COLLECTED / stamp
    out_dir.mkdir(parents=True, exist_ok=True)

    completed_local = out_dir / "request.json"
    fixture_dir = out_dir / "pen-fixtures"
    index_local = out_dir / "index.json"

    if target["kind"] == "simulator":
        completed = _pull_from_simulator(paths["completed_rel"], completed_local)
        _pull_from_simulator(paths["fixture_rel"], fixture_dir)
        _pull_from_simulator(paths["index_rel"], index_local)
    else:
        completed = _pull_from_device(target["id"], paths["completed_rel"], completed_local)
        _pull_from_device(target["id"], paths["fixture_rel"], fixture_dir)
        _pull_from_device(target["id"], paths["index_rel"], index_local)

    result: dict[str, Any] = {
        "id": request_id,
        "target": target,
        "collected_dir": str(out_dir),
        "status": "pending",
    }

    if completed and completed.exists():
        payload = json.loads(completed.read_text())
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
        if index_local.exists():
            result["index"] = json.loads(index_local.read_text())
        return result

    # Still pending?
    pending_local = out_dir / "pending.json"
    if target["kind"] == "simulator":
        pending = _pull_from_simulator(paths["pending_rel"], pending_local)
    else:
        pending = _pull_from_device(target["id"], paths["pending_rel"], pending_local)
    if pending and pending.exists():
        result["request"] = json.loads(pending.read_text())
        result["status"] = result["request"].get("status", "awaiting-human")
    return result


@mcp.tool()
def request_pen_fixture(description: str, scenario: str = "blank-canvas", prefer_device: bool = True) -> dict:
    """Push a Pencil capture request into the Debug app on the connected test device.

    The app shows the agent prompt at the top. The human draws once; the app
    indexes the fixture. Call collect_interaction / await_interaction afterward.
    """
    fixture_name = _safe_name(description)
    request_id = f"{fixture_name}-{uuid.uuid4().hex[:8]}"
    request = {
        "id": request_id,
        "kind": "pen-fixture",
        "title": "Pencil capture",
        "prompt": description,
        "status": "awaiting-human",
        "createdAt": _utc_now(),
        "completedAt": None,
        "fixtureName": fixture_name,
        "eventCount": None,
        "verdict": None,
        "humanNotes": None,
        "scenario": scenario,
        "screenshotHint": None,
    }
    return _deliver_request(request, prefer_device=prefer_device)


@mcp.tool()
def request_human_review(
    prompt: str,
    title: str = "Human review",
    scenario: str = "blank-canvas",
    prefer_device: bool = True,
) -> dict:
    """Push a review request into the Debug app banner for a verdict + optional note."""
    request_id = f"review-{_safe_name(title)}-{uuid.uuid4().hex[:8]}"
    request = {
        "id": request_id,
        "kind": "review",
        "title": title,
        "prompt": prompt,
        "status": "awaiting-human",
        "createdAt": _utc_now(),
        "completedAt": None,
        "fixtureName": None,
        "eventCount": None,
        "verdict": None,
        "humanNotes": None,
        "scenario": scenario,
        "screenshotHint": None,
    }
    return _deliver_request(request, prefer_device=prefer_device)


@mcp.tool()
def collect_interaction(request_id: str, prefer_device: bool = True) -> dict:
    """Pull a completed interaction (fixture, verdict, notes, index) from the connected device."""
    return _collect_request(request_id, prefer_device=prefer_device)


@mcp.tool()
def await_interaction(request_id: str, timeout_seconds: float = 180.0, prefer_device: bool = True) -> dict:
    """Poll until the human completes the in-app request, then return the collected artifacts."""
    deadline = time.time() + timeout_seconds
    last: dict[str, Any] = {}
    while time.time() < deadline:
        last = _collect_request(request_id, prefer_device=prefer_device)
        status = last.get("status")
        if status in {"recorded", "answered"}:
            return last
        time.sleep(2.0)
    last["status"] = "timeout"
    last["message"] = f"Timed out after {timeout_seconds:.0f}s waiting for request {request_id}"
    return last


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
