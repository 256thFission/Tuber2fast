"""Resume a Codex CLI thread when one TuberNotes feedback wake becomes eligible."""

from __future__ import annotations

import json
import base64
import fcntl
import hashlib
import os
import shutil
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import server


BRIDGE_VERSION = "0.1.0"
DEFAULT_POLL_SECONDS = 1.0
DEFAULT_TIMEOUT_SECONDS = 24 * 60 * 60
APP_SERVER_SOCKET = server.FEEDBACK_STORE / "codex-app-server.sock"
APP_SERVER_LOG = server.FEEDBACK_STORE / "codex-app-server.log"
APP_SERVER_LOCK = server.FEEDBACK_STORE / "codex-app-server.lock"


def _codex_binary() -> str:
    configured = os.environ.get("TUBER_CODEX_BIN")
    candidates = [
        configured,
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        shutil.which("codex"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(candidate)
    raise FileNotFoundError("No Codex CLI binary found; set TUBER_CODEX_BIN")


def _app_server_url() -> str:
    return f"unix://{APP_SERVER_SOCKET}"


def ensure_app_server() -> None:
    """Start one detached local app-server shared by the bridge and Codex CLI."""
    server.FEEDBACK_STORE.mkdir(parents=True, exist_ok=True)
    with APP_SERVER_LOCK.open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if _socket_is_live():
            return
        if APP_SERVER_SOCKET.exists():
            APP_SERVER_SOCKET.unlink()
        log = APP_SERVER_LOG.open("a")
        subprocess.Popen(
            [_codex_binary(), "app-server", "--listen", _app_server_url()],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            start_new_session=True,
            close_fds=True,
        )
        log.close()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if _socket_is_live():
                return
            time.sleep(0.1)
        raise RuntimeError(f"Codex app-server did not create {APP_SERVER_SOCKET}")


def _socket_is_live() -> bool:
    if not APP_SERVER_SOCKET.exists():
        return False
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(0.25)
    try:
        probe.connect(str(APP_SERVER_SOCKET))
        return True
    except OSError:
        return False
    finally:
        probe.close()


class AppServerClient:
    def __init__(self) -> None:
        ensure_app_server()
        self.transport = UnixWebSocket(APP_SERVER_SOCKET)
        self.next_id = 1
        self.request(
            "initialize",
            {
                "clientInfo": {
                    "name": "tubernotes_wake_bridge",
                    "title": "TuberNotes Wake Bridge",
                    "version": BRIDGE_VERSION,
                },
                "capabilities": {"experimentalApi": True},
            },
        )
        self.notify("initialized", {})

    def close(self) -> None:
        self.transport.close()

    def notify(self, method: str, params: dict[str, Any]) -> None:
        self.transport.send_json({"method": method, "params": params})

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        self.transport.send_json({"method": method, "id": request_id, "params": params})
        while True:
            message = self.transport.receive_json()
            if message.get("id") != request_id:
                continue
            if message.get("error"):
                raise RuntimeError(f"Codex {method} failed: {message['error']}")
            return message.get("result") or {}

    def dispatch(self, thread_id: str, prompt: str, wake_id: str) -> dict[str, Any]:
        resumed = self.request("thread/resume", {"threadId": thread_id})
        thread = resumed.get("thread") or {}
        if thread.get("id") != thread_id:
            raise RuntimeError(f"Codex resumed unexpected thread {thread.get('id')!r}")
        turns = thread.get("turns") or []
        active = next((turn for turn in reversed(turns) if turn.get("status") == "inProgress"), None)
        input_value = [{"type": "text", "text": prompt}]
        if active:
            result = self.request(
                "turn/steer",
                {
                    "threadId": thread_id,
                    "expectedTurnId": active["id"],
                    "clientUserMessageId": wake_id,
                    "input": input_value,
                },
            )
            turn = result.get("turn") or active
            return {"mode": "steer", "turn_id": turn.get("id")}
        result = self.request(
            "turn/start",
            {
                "threadId": thread_id,
                "clientUserMessageId": wake_id,
                "input": input_value,
            },
        )
        turn = result.get("turn") or {}
        return {"mode": "start", "turn_id": turn.get("id")}

    def wait_for_turn_completed(self, turn_id: str, timeout_seconds: float = 3600.0) -> dict[str, Any]:
        self.transport.socket.settimeout(timeout_seconds)
        while True:
            message = self.transport.receive_json()
            if message.get("method") != "turn/completed":
                continue
            turn = (message.get("params") or {}).get("turn") or {}
            if turn.get("id") == turn_id:
                return turn


class UnixWebSocket:
    """Small RFC 6455 client for Codex's local Unix-socket transport."""

    def __init__(self, path: Path, timeout_seconds: float = 30.0) -> None:
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(timeout_seconds)
        self.socket.connect(str(path))
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            "GET / HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.socket.sendall(request.encode("ascii"))
        response = self._receive_until(b"\r\n\r\n")
        status = response.split(b"\r\n", 1)[0]
        if status != b"HTTP/1.1 101 Switching Protocols":
            self.socket.close()
            raise RuntimeError(f"Codex WebSocket upgrade failed: {status.decode(errors='replace')}")
        expected = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        )
        headers = response.lower()
        if b"sec-websocket-accept: " + expected.lower() not in headers:
            self.socket.close()
            raise RuntimeError("Codex WebSocket returned an invalid accept key")

    def _receive_until(self, delimiter: bytes) -> bytes:
        value = b""
        while delimiter not in value:
            chunk = self.socket.recv(4096)
            if not chunk:
                raise EOFError("Codex WebSocket closed during handshake")
            value += chunk
        return value

    def _receive_exactly(self, count: int) -> bytes:
        value = b""
        while len(value) < count:
            chunk = self.socket.recv(count - len(value))
            if not chunk:
                raise EOFError("Codex WebSocket closed")
            value += chunk
        return value

    def _send_frame(self, opcode: int, payload: bytes = b"") -> None:
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            header = bytes([0x80 | opcode, 0x80 | length])
        elif length < 65536:
            header = bytes([0x80 | opcode, 0xFE]) + struct.pack("!H", length)
        else:
            header = bytes([0x80 | opcode, 0xFF]) + struct.pack("!Q", length)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.socket.sendall(header + mask + masked)

    def send_json(self, value: dict[str, Any]) -> None:
        self._send_frame(0x1, json.dumps(value, separators=(",", ":")).encode("utf-8"))

    def receive_json(self) -> dict[str, Any]:
        fragments = bytearray()
        while True:
            first, second = self._receive_exactly(2)
            final = bool(first & 0x80)
            opcode = first & 0x0F
            masked = bool(second & 0x80)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._receive_exactly(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._receive_exactly(8))[0]
            mask = self._receive_exactly(4) if masked else None
            payload = self._receive_exactly(length)
            if mask:
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            if opcode == 0x8:
                raise EOFError("Codex WebSocket closed")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode in {0x0, 0x1}:
                fragments.extend(payload)
                if final:
                    return json.loads(fragments.decode("utf-8"))

    def close(self) -> None:
        try:
            self._send_frame(0x8)
        except OSError:
            pass
        self.socket.close()

def _wake_prompt(config: dict[str, Any], wake: dict[str, Any]) -> str:
    return (
        "<feedback_wake>\n"
        f"feedback_thread_id: {config['feedback_thread_id']}\n"
        f"owner_token: {config['owner_token']}\n"
        f"wake_id: {wake['wake_id']}\n"
        f"after_sequence: {wake['after_sequence']}\n"
        "instructions: Collect and interpret the new human response. Acknowledge this wake only after "
        "collection succeeds. If the response is unambiguous and the guided review has another step, "
        "verify its precondition and present exactly that next action in the same feedback thread. Stop "
        "on failure, ambiguity, confusion, or device/host divergence.\n"
        "</feedback_wake>"
    )


def monitor_once(config: dict[str, Any]) -> dict[str, Any]:
    deadline = time.monotonic() + float(config.get("timeout_seconds", DEFAULT_TIMEOUT_SECONDS))
    poll_seconds = max(0.25, float(config.get("poll_seconds", DEFAULT_POLL_SECONDS)))
    last_transient_error: str | None = None
    while time.monotonic() < deadline:
        try:
            wake = server._get_feedback_watch_state(
                config["feedback_thread_id"],
                config["owner_token"],
                int(config.get("after_sequence", 0)),
            )
            last_transient_error = None
        except (OSError, subprocess.SubprocessError) as exc:
            last_transient_error = str(exc)
            time.sleep(poll_seconds)
            continue
        if wake.get("wake_eligible"):
            client = AppServerClient()
            try:
                dispatch = client.dispatch(
                    config["requester_id"],
                    _wake_prompt(config, wake),
                    wake["wake_id"],
                )
                server._record_feedback_wake_dispatch(
                    config["feedback_thread_id"],
                    config["owner_token"],
                    wake["wake_id"],
                    dispatch.get("turn_id"),
                    dispatch["mode"],
                )
                if dispatch.get("turn_id"):
                    client.wait_for_turn_completed(
                        dispatch["turn_id"],
                        timeout_seconds=max(1.0, deadline - time.monotonic()),
                    )
            finally:
                client.close()
            return {"status": "dispatched", "wake_id": wake["wake_id"], **dispatch}
        time.sleep(poll_seconds)
    return {"status": "timeout", "last_transient_error": last_transient_error}


def main() -> None:
    config = json.load(sys.stdin)
    result = monitor_once(config)
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
