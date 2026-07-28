#!/bin/bash
# Gate 60 — install and launch on the named physical iPad.
#
# The milestone's device gates cannot be satisfied by a simulator. When the iPad
# is not connected this gate exits 2 (SKIP), which the runner reports loudly and
# which downgrades the overall verdict to INCOMPLETE. A skip is never a pass.

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FAILED=0
cd "$REPO_ROOT" || exit 1

# Every precondition lives in one tool, so the reason for a skip is specific.
bash "$REPO_ROOT/Tools/preflight-device.sh" | sed 's/^/  /'
case "${PIPESTATUS[0]}" in
  0) : ;;
  2) skip "device preflight BLOCKED (see reasons above); device evidence not collected"; exit 2 ;;
  *) fail "device preflight found a misconfiguration (see above)"; exit 1 ;;
esac

DEVICE_ID="$(python3 - "$ARTIFACTS/devices.json" "$DEVICE_NAME" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
want = sys.argv[2]
for d in doc.get("result", {}).get("devices", []):
    if d.get("deviceProperties", {}).get("name", "") == want:
        print(d.get("identifier", ""))
        break
PY
)"
[ -n "$DEVICE_ID" ] || { fail "preflight passed but no device identifier resolved"; exit 1; }

LOG="$ARTIFACTS/device-build.log"
# The destination names the actual iPad rather than generic/platform=iOS.
# Automatic signing can only register a device it has been told about: with a
# generic destination and a team that has no devices yet, provisioning fails
# with "Your team has no devices from which to generate a provisioning profile".
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  >"$LOG" 2>&1 || { fail "device build failed; last 40 lines:"; tail -40 "$LOG" >&2; exit 1; }
pass "signed device build succeeded"

APP="$DERIVED_DATA/Build/Products/Debug-iphoneos/$APP_NAME.app"
[ -d "$APP" ] || { fail "no device app at $APP"; exit 1; }

xcrun devicectl device install app --device "$DEVICE_ID" "$APP" \
  >"$ARTIFACTS/device-install.log" 2>&1 \
  || { fail "install failed; see Artifacts/device-install.log"; exit 1; }
pass "installed on device"

if ! xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" \
     >"$ARTIFACTS/device-launch.log" 2>&1; then
  # A development profile from a personal team must be trusted on the device
  # itself before iOS will launch anything signed with it. Nothing on the Mac
  # can do it, and the raw error blames the code signature, which sends you
  # looking in the wrong place.
  if grep -q "explicitly trusted" "$ARTIFACTS/device-launch.log"; then
    skip "the developer profile is not trusted on '$DEVICE_NAME'; device evidence not collected"
    printf '     → on the iPad: Settings → General → VPN & Device Management →\n' >&2
    printf '       Developer App → trust the Apple Development certificate, then re-run\n' >&2
    exit 2
  fi
  fail "launch failed; see Artifacts/device-launch.log"
  exit 1
fi
pass "launched on device"

if xcrun devicectl device info processes --device "$DEVICE_ID" 2>/dev/null | grep -q "$APP_NAME.app"; then
  pass "process running on device"
else
  fail "app is not among the device's running processes after launch"
fi

exit "$FAILED"
