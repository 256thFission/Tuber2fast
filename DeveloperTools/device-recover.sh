#!/usr/bin/env bash
# Recover the pinned-iPad tooling after an orphaned session or a stuck
# "Device is busy (Connecting…)" CoreDevice state. Safe to run any time; it
# only touches this repository's device processes and user-level daemons.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SESSION_TOOL="$ROOT/DeveloperTools/device_session.py"

echo "== 1/4 Current device lock =="
python3 "$SESSION_TOOL" lock-status || true

echo "== 2/4 Reclaiming: kill orphaned verifier/xcodebuild/devicectl, clear lock =="
python3 "$SESSION_TOOL" recover

echo "== 3/4 Resetting user-level CoreDevice daemon (auto-relaunches) =="
if pgrep -x CoreDeviceService >/dev/null 2>&1; then
    pkill -x CoreDeviceService && echo "CoreDeviceService restarted"
else
    echo "CoreDeviceService not running (will start on demand)"
fi
if pgrep -f "Xcode.app/Contents/MacOS/Xcode" >/dev/null 2>&1; then
    echo "WARNING: Xcode.app is open and can hold the destination ('Device is busy')."
    echo "         Quit Xcode before agent verification runs."
fi

echo "== 4/4 Validating the pinned iPad =="
if python3 "$SESSION_TOOL" check; then
    echo "RECOVERED: device session is healthy. Re-run your verifier."
else
    cat <<'EOF'
STILL BLOCKED. Escalate in order:
  1. Unlock the iPad, keep its screen on, reseat the cable.
  2. Reboot the iPad (clears the device-side remoted peer; fixes most stalls).
  3. sudo pkill remoted   (Mac-side daemon; needs sudo, auto-relaunches)
  4. Reboot the Mac; accept the trust prompt on the iPad if it reappears.
EOF
    exit 1
fi
