#!/bin/bash
# Gate 50 — install and launch on the pinned simulator.
#
# This is the first gate that is behavioral rather than textual: the app must
# actually stay alive, and must do so without a crash report or a fatal-error
# line in the device log.

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FAILED=0
cd "$REPO_ROOT" || exit 1

APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/$APP_NAME.app"
[ -d "$APP" ] || { fail "no built app at $APP (run gate 30 first)"; exit 1; }

UDID="$(xcrun simctl list devices available \
  | grep -F "$SIM_NAME (" \
  | head -1 \
  | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
[ -n "$UDID" ] || { fail "simulator '$SIM_NAME' not found"; exit 1; }

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || {
  fail "simulator failed to boot"; exit 1;
}

START_EPOCH="$(date +%s)"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
xcrun simctl install "$UDID" "$APP" || { fail "install failed"; exit 1; }
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null || { fail "launch failed"; exit 1; }

# Stay-alive check: simulator apps are host processes, so pgrep is authoritative.
alive=0
for _ in $(seq 1 20); do
  if pgrep -f "$APP_NAME.app/$APP_NAME" >/dev/null 2>&1; then alive=1; else alive=0; break; fi
  /bin/sleep 0.25
done
if [ "$alive" -eq 1 ]; then
  pass "app launched and stayed alive for 5s"
else
  fail "app exited within 5s of launch"
fi

xcrun simctl io "$UDID" screenshot "$ARTIFACTS/sim-launch.png" >/dev/null 2>&1 \
  && pass "screenshot: Artifacts/sim-launch.png" \
  || fail "screenshot capture failed"

# Fatal errors and contract assertions surface in the device log.
xcrun simctl spawn "$UDID" log show --style compact --last 2m \
  --predicate "processImagePath CONTAINS \"$APP_NAME\"" \
  >"$ARTIFACTS/sim-console.log" 2>/dev/null
if grep -qE 'Fatal error|CONTRACT VIOLATION|Precondition failed' "$ARTIFACTS/sim-console.log"; then
  fail "fatal error or contract assertion in console:"
  grep -E 'Fatal error|CONTRACT VIOLATION|Precondition failed' "$ARTIFACTS/sim-console.log" | head -10 | sed 's/^/      /' >&2
else
  pass "console clean (Artifacts/sim-console.log)"
fi

# Crash reports written after the launch instant.
crashes="$(find "$HOME/Library/Logs/DiagnosticReports" -name "$APP_NAME*" -newermt "@$START_EPOCH" 2>/dev/null)"
if [ -n "$crashes" ]; then
  fail "crash report(s) generated:"
  printf '%s\n' "$crashes" | sed 's/^/      /' >&2
else
  pass "no crash reports"
fi

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
exit "$FAILED"
