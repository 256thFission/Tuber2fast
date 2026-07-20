#!/usr/bin/env python3
"""Create and validate the explicit physical-iPad session used by developer tools."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SESSION_FILE = ROOT / ".tubernotes-device-session.json"
LOCK_FILE = ROOT / ".tubernotes-device-lock.json"
BUNDLE_ID = "com.tubernotes.app"
SCHEMA_VERSION = 1
XCODE_GUI_MARKER = "Xcode.app/Contents/MacOS/Xcode"


class DeviceSessionError(RuntimeError):
    pass


def _run_json(command: list[str]) -> dict[str, Any]:
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as handle:
        output_path = Path(handle.name)
    try:
        result = subprocess.run(
            [*command, "--json-output", str(output_path), "--quiet"],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "command failed"
            raise DeviceSessionError(detail)
        return json.loads(output_path.read_text())
    except (OSError, json.JSONDecodeError, subprocess.TimeoutExpired) as exc:
        raise DeviceSessionError(str(exc)) from exc
    finally:
        output_path.unlink(missing_ok=True)


def _listed_devices(payload: dict[str, Any]) -> list[dict[str, Any]]:
    devices = payload.get("result", {}).get("devices", [])
    return devices if isinstance(devices, list) else []


def _validate_physical_ipad(device: dict[str, Any], requested_id: str) -> None:
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    failures: list[str] = []
    if device.get("identifier") != requested_id:
        failures.append("identifier mismatch")
    if hardware.get("reality") != "physical":
        failures.append("target is not physical hardware")
    if hardware.get("deviceType") != "iPad":
        failures.append("target is not an iPad")
    if hardware.get("platform") != "iOS":
        failures.append("target is not iOS")
    if properties.get("bootState") != "booted":
        failures.append("iPad is not booted")
    if properties.get("developerModeStatus") != "enabled":
        failures.append("Developer Mode is not enabled")
    if not properties.get("ddiServicesAvailable"):
        failures.append("developer services are unavailable")
    if connection.get("pairingState") != "paired":
        failures.append("iPad is not paired")
    if connection.get("tunnelState") != "connected":
        failures.append("iPad transport is not connected")
    if failures:
        raise DeviceSessionError("; ".join(failures))


def inspect_device(device_id: str) -> dict[str, Any]:
    payload = _run_json(["xcrun", "devicectl", "list", "devices"])
    device = next((item for item in _listed_devices(payload) if item.get("identifier") == device_id), None)
    if device is None:
        raise DeviceSessionError(f"physical iPad {device_id} is not currently available")
    _validate_physical_ipad(device, device_id)
    return device


def _app_is_installed(device_id: str) -> bool:
    try:
        payload = _run_json(
            [
                "xcrun",
                "devicectl",
                "device",
                "info",
                "apps",
                "--device",
                device_id,
                "--bundle-id",
                BUNDLE_ID,
            ]
        )
    except DeviceSessionError:
        return False
    return BUNDLE_ID in json.dumps(payload, sort_keys=True)


def session_payload(device: dict[str, Any]) -> dict[str, Any]:
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    device_id = str(device["identifier"])
    return {
        "schemaVersion": SCHEMA_VERSION,
        "deviceID": device_id,
        "deviceName": properties.get("name"),
        "udid": hardware.get("udid"),
        "deviceType": hardware.get("deviceType"),
        "reality": hardware.get("reality"),
        "platform": hardware.get("platform"),
        "osVersion": properties.get("osVersionNumber"),
        "developerModeStatus": properties.get("developerModeStatus"),
        "transportType": connection.get("transportType"),
        "bundleID": BUNDLE_ID,
        "appInstalledAtPreflight": _app_is_installed(device_id),
        "preparedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def write_session(payload: dict[str, Any]) -> None:
    SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{SESSION_FILE.name}.", dir=SESSION_FILE.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, SESSION_FILE)
    finally:
        temporary.unlink(missing_ok=True)


def load_session(*, validate_live: bool) -> dict[str, Any]:
    if not SESSION_FILE.exists():
        raise DeviceSessionError(
            "no physical-iPad session is configured; run "
            "DeveloperTools/device-preflight.sh --device <device-id>"
        )
    try:
        payload = json.loads(SESSION_FILE.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise DeviceSessionError(f"invalid device session: {exc}") from exc
    if payload.get("schemaVersion") != SCHEMA_VERSION or not payload.get("deviceID"):
        raise DeviceSessionError("invalid or unsupported physical-iPad session")
    if payload.get("reality") != "physical" or payload.get("deviceType") != "iPad":
        raise DeviceSessionError("configured target is not a physical iPad")
    if validate_live:
        inspect_device(str(payload["deviceID"]))
    return payload


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def read_lock() -> dict[str, Any] | None:
    if not LOCK_FILE.exists():
        return None
    try:
        payload = json.loads(LOCK_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict) or not isinstance(payload.get("pid"), int):
        return None
    return payload


def _write_lock(payload: dict[str, Any]) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{LOCK_FILE.name}.", dir=LOCK_FILE.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, LOCK_FILE)
    finally:
        temporary.unlink(missing_ok=True)


def acquire_lock(pid: int, label: str) -> None:
    existing = read_lock()
    if existing is not None and existing["pid"] != pid and _pid_alive(existing["pid"]):
        raise DeviceSessionError(
            f"device is locked by live process {existing['pid']} "
            f"({existing.get('label', 'unlabeled')}, since {existing.get('acquiredAt', 'unknown')}); "
            "wait for it, or run DeveloperTools/device-recover.sh if it is orphaned"
        )
    # Missing, stale (owner dead), or re-entrant lock: (re)take it.
    _write_lock(
        {
            "schemaVersion": SCHEMA_VERSION,
            "pid": pid,
            "label": label,
            "acquiredAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        }
    )


def release_lock(pid: int, *, force: bool = False) -> None:
    existing = read_lock()
    if existing is None:
        return
    if not force and existing["pid"] != pid and _pid_alive(existing["pid"]):
        raise DeviceSessionError(
            f"device lock belongs to live process {existing['pid']} "
            f"({existing.get('label', 'unlabeled')}); not releasing"
        )
    LOCK_FILE.unlink(missing_ok=True)


def _process_table() -> list[tuple[int, str]]:
    result = subprocess.run(
        ["ps", "-axo", "pid=,command="],
        capture_output=True,
        text=True,
        check=False,
    )
    table: list[tuple[int, str]] = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        try:
            table.append((int(parts[0]), parts[1]))
        except ValueError:
            continue
    return table


def _is_contender(command: str) -> bool:
    if "verify-scenario.sh" in command:
        return True
    if "xcodebuild" in command and (str(ROOT) in command or "DerivedDataDevice" in command):
        return True
    if "devicectl device" in command and ("install" in command or "launch" in command or "copy" in command):
        return True
    return False


def find_contenders(*, exclude: set[int] | None = None) -> list[tuple[int, str]]:
    """Processes from any conversation/instance that may hold the pinned iPad."""
    skip = {os.getpid(), os.getppid()} | (exclude or set())
    lock = read_lock()
    if lock is not None and _pid_alive(lock["pid"]):
        skip.add(lock["pid"])  # reported separately as the lock owner
    return [(pid, cmd) for pid, cmd in _process_table() if pid not in skip and _is_contender(cmd)]


def xcode_gui_running() -> bool:
    return any(XCODE_GUI_MARKER in cmd for _, cmd in _process_table())


def _kill_processes(processes: list[tuple[int, str]]) -> list[str]:
    import signal
    import time

    actions: list[str] = []
    for pid, cmd in processes:
        try:
            os.kill(pid, signal.SIGTERM)
            actions.append(f"TERM {pid}: {cmd[:120]}")
        except (ProcessLookupError, PermissionError):
            continue
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and any(_pid_alive(pid) for pid, _ in processes):
        time.sleep(0.2)
    for pid, cmd in processes:
        if _pid_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
                actions.append(f"KILL {pid}: {cmd[:120]}")
            except (ProcessLookupError, PermissionError):
                continue
    return actions


def guard_exclusive(*, reclaim: bool) -> list[str]:
    """Fail when another conversation's session may hold the iPad; reclaim kills orphans."""
    messages: list[str] = []
    lock = read_lock()
    lock_owner_alive = lock is not None and _pid_alive(lock["pid"])
    contenders = find_contenders()
    if reclaim:
        victims = list(contenders)
        if lock_owner_alive:
            for pid, cmd in _process_table():
                if pid == lock["pid"]:
                    victims.append((pid, cmd))
                    break
        if victims:
            messages.extend(_kill_processes(victims))
        LOCK_FILE.unlink(missing_ok=True)
        return messages
    problems: list[str] = []
    if lock_owner_alive:
        problems.append(
            f"device lock held by live process {lock['pid']} ({lock.get('label', 'unlabeled')})"
        )
    for pid, cmd in contenders:
        problems.append(f"active device process {pid}: {cmd[:120]}")
    if problems:
        raise DeviceSessionError(
            "the pinned iPad is in use by another session:\n  "
            + "\n  ".join(problems)
            + "\nWait for it, or run DeveloperTools/device-recover.sh to reclaim."
        )
    if lock is not None and not lock_owner_alive:
        LOCK_FILE.unlink(missing_ok=True)
        messages.append(f"cleared stale device lock (dead pid {lock['pid']})")
    return messages


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    start = subparsers.add_parser("start", help="validate and pin one physical iPad")
    start.add_argument("--device", required=True)
    start.add_argument(
        "--reclaim",
        action="store_true",
        help="kill orphaned verifier/xcodebuild/devicectl processes and clear the lock first",
    )
    subparsers.add_parser("check", help="validate the pinned iPad and print the session")
    subparsers.add_parser("resolve", help="validate the pinned iPad and print only its identifier")
    subparsers.add_parser("show", help="print the stored session without accessing the device")
    acquire = subparsers.add_parser("acquire", help="take the cross-session device lock")
    acquire.add_argument("--pid", type=int, required=True)
    acquire.add_argument("--label", required=True)
    release = subparsers.add_parser("release", help="release the cross-session device lock")
    release.add_argument("--pid", type=int, required=True)
    release.add_argument("--force", action="store_true")
    subparsers.add_parser("lock-status", help="print the current device lock, if any")
    subparsers.add_parser(
        "recover",
        help="kill orphaned device processes from any session and clear the lock",
    )
    args = parser.parse_args()
    try:
        if args.command == "start":
            for message in guard_exclusive(reclaim=args.reclaim):
                print(f"guard: {message}")
            if xcode_gui_running():
                print(
                    "WARNING: Xcode.app is running and may hold the destination "
                    "('Device is busy'); quit Xcode before agent verification.",
                    file=os.sys.stderr,
                )
            payload = session_payload(inspect_device(args.device))
            write_session(payload)
        elif args.command == "acquire":
            acquire_lock(args.pid, args.label)
            payload = read_lock() or {}
        elif args.command == "release":
            release_lock(args.pid, force=args.force)
            payload = {"released": True}
        elif args.command == "lock-status":
            lock = read_lock()
            if lock is None:
                payload = {"locked": False}
            else:
                payload = {**lock, "locked": True, "ownerAlive": _pid_alive(lock["pid"])}
        elif args.command == "recover":
            actions = guard_exclusive(reclaim=True)
            payload = {"actions": actions or ["nothing to recover"]}
        else:
            payload = load_session(validate_live=args.command != "show")
        if args.command == "resolve":
            print(payload["deviceID"])
        else:
            print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    except DeviceSessionError as exc:
        parser.exit(1, f"ERROR: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
