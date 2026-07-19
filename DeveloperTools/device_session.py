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
BUNDLE_ID = "com.tubernotes.app"
SCHEMA_VERSION = 1


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    start = subparsers.add_parser("start", help="validate and pin one physical iPad")
    start.add_argument("--device", required=True)
    subparsers.add_parser("check", help="validate the pinned iPad and print the session")
    subparsers.add_parser("resolve", help="validate the pinned iPad and print only its identifier")
    subparsers.add_parser("show", help="print the stored session without accessing the device")
    args = parser.parse_args()
    try:
        if args.command == "start":
            payload = session_payload(inspect_device(args.device))
            write_session(payload)
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
