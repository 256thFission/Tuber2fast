#!/bin/bash
# Device preflight — every precondition for device work, in one command.
#
#   Tools/preflight-device.sh
#
# Gate 60 can only report "the iPad is not available". That is true but useless:
# the cause may be a cable, a locked screen, Developer Mode, an expired pairing,
# a team mismatch, or an iPadOS version newer than this Xcode supports. This
# tool names the actual cause and the fix.
#
# Exit codes:
#   0  READY    — the device gate can run
#   2  BLOCKED  — something in the physical world must change (plug in, unlock)
#   1  MISCONFIGURED — something in this repo or toolchain is wrong
#
# The distinction matters: BLOCKED is a skip, MISCONFIGURED is a failure.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT" || exit 1

BLOCKED=0
MISCONFIGURED=0

ok()      { printf '  ✓ %s\n' "$1"; }
blocked() { printf '  ⊘ %s\n     → %s\n' "$1" "$2"; BLOCKED=1; }
bad()     { printf '  ✗ %s\n     → %s\n' "$1" "$2" >&2; MISCONFIGURED=1; }

# Compare dotted versions: returns 0 if $1 >= $2.
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

echo "── Host toolchain ──"

if command -v xcodegen >/dev/null 2>&1; then
  ok "xcodegen $(xcodegen --version 2>&1 | awk '{print $NF}')"
else
  bad "xcodegen not installed" "brew install xcodegen"
fi

if command -v xcodebuild >/dev/null 2>&1; then
  ok "$(xcodebuild -version 2>/dev/null | head -1) at $(xcode-select -p)"
else
  bad "xcodebuild not found" "install Xcode and run xcode-select --switch"
fi

SDK_VERSION="$(xcodebuild -showsdks 2>/dev/null | sed -nE 's/.*-sdk iphoneos([0-9.]+).*/\1/p' | sort -V | tail -1)"
if [ -n "$SDK_VERSION" ]; then
  ok "iOS device SDK $SDK_VERSION"
else
  bad "no iOS device SDK installed" "install the iOS platform in Xcode → Settings → Components"
fi

echo
echo "── Signing ──"

TEAM="$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM:[[:space:]]*([A-Z0-9]+).*/\1/p' project.yml | head -1)"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"

if [ -z "$TEAM" ]; then
  bad "project.yml declares no DEVELOPMENT_TEAM" "add DEVELOPMENT_TEAM to project.yml settings"
else
  # The Team ID is the certificate's OU, not the parenthetical in its common
  # name. For "Apple Development" certificates the CN parenthetical is the
  # person identifier, and the two are different strings. Matching on the CN
  # confirmed a DEVELOPMENT_TEAM that was not a team at all, and the failure
  # surfaced much later as "No Account for Team" from xcodebuild.
  #
  # No check here for downloaded provisioning profiles: automatic signing
  # fetches one on demand under -allowProvisioningUpdates, so their absence is
  # not a precondition. Only the build can prove signing works, and that is
  # gate 60's job.
  CERT_TEAMS="$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl crl2pkcs7 -nocrl -certfile /dev/stdin 2>/dev/null \
    | openssl pkcs7 -print_certs -noout 2>/dev/null \
    | sed -nE 's|^subject=.*/OU=([A-Z0-9]{10})/.*|\1|p' | sort -u)"

  if printf '%s\n' "$CERT_TEAMS" | grep -qx "$TEAM"; then
    ok "signing identity present for team $TEAM"
  else
    bad "no codesigning identity whose team (certificate OU) is $TEAM" \
        "teams found in installed certificates: ${CERT_TEAMS:-none}; correct DEVELOPMENT_TEAM in project.yml or sign in to Xcode → Settings → Accounts"
  fi
fi

# Installing this build must never replace the behavioral reference app.
OUR_BUNDLE="$(sed -nE 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*([A-Za-z0-9._-]+).*/\1/p' project.yml | head -1)"
REFERENCE_BUNDLE="com.tubernotes.app"
if [ "$OUR_BUNDLE" = "$REFERENCE_BUNDLE" ]; then
  bad "bundle id collides with the reference app ($REFERENCE_BUNDLE)" \
      "installing would overwrite the comparison app; change PRODUCT_BUNDLE_IDENTIFIER"
else
  ok "bundle id $OUR_BUNDLE (distinct from the reference app)"
fi

DEPLOYMENT_TARGET="$(sed -nE 's/^[[:space:]]*iOS:[[:space:]]*"?([0-9.]+)"?.*/\1/p' project.yml | head -1)"
[ -n "$DEPLOYMENT_TARGET" ] && ok "deployment target iOS $DEPLOYMENT_TARGET"

echo
echo "── Device: $DEVICE_NAME ──"

DEVICE_JSON="$ARTIFACTS/devices.json"
if ! xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1; then
  blocked "devicectl could not enumerate devices" "check that Xcode is installed and no other tool holds the device"
  echo
  printf '  VERDICT: BLOCKED\n'
  exit 2
fi

eval "$(python3 - "$DEVICE_JSON" "$DEVICE_NAME" <<'PY'
import json, sys, shlex
doc = json.load(open(sys.argv[1]))
want = sys.argv[2]
found = None
for d in doc.get("result", {}).get("devices", []):
    if d.get("deviceProperties", {}).get("name", "") == want:
        found = d
        break
def emit(key, value):
    print(f"{key}={shlex.quote(str(value))}")
if found is None:
    emit("D_FOUND", "0")
else:
    conn = found.get("connectionProperties", {})
    prop = found.get("deviceProperties", {})
    hw = found.get("hardwareProperties", {})
    emit("D_FOUND", "1")
    emit("D_ID", found.get("identifier", ""))
    emit("D_PAIRING", conn.get("pairingState", "unknown"))
    emit("D_TUNNEL", conn.get("tunnelState", "unknown"))
    emit("D_LAST_SEEN", conn.get("lastConnectionDate", "never"))
    emit("D_DEVMODE", prop.get("developerModeStatus", "unknown"))
    emit("D_DDI", "1" if prop.get("ddiServicesAvailable") else "0")
    emit("D_OS", prop.get("osVersionNumber", "0"))
    emit("D_MODEL", hw.get("marketingName", "unknown"))
    emit("D_FAMILIES", ",".join(str(f) for f in hw.get("supportedDeviceFamilies", [])))
PY
)"

if [ "${D_FOUND:-0}" != "1" ]; then
  blocked "'$DEVICE_NAME' is not known to this Mac" \
          "connect the iPad by cable and trust this computer, or set TN_DEVICE_NAME"
  echo
  printf '  VERDICT: BLOCKED\n'
  exit 2
fi
ok "found $D_MODEL, iPadOS $D_OS ($D_ID)"

case "$D_PAIRING" in
  paired) ok "paired with this Mac" ;;
  *)      blocked "pairing state is '$D_PAIRING'" "connect by cable and tap Trust on the iPad" ;;
esac

case "$D_DEVMODE" in
  enabled) ok "Developer Mode enabled" ;;
  *)       blocked "Developer Mode is '$D_DEVMODE'" \
                   "on the iPad: Settings → Privacy & Security → Developer Mode → On, then reboot" ;;
esac

# Reachability is proved by talking to the device, not by reading a cached
# field. `devicectl list devices` serves a stored record whose `tunnelState` is
# "disconnected" and `ddiServicesAvailable` false for a device that is plugged
# in and perfectly usable: the tunnel is established lazily, on first real
# request. Trusting the cached value reported BLOCKED for a ready iPad and would
# have downgraded a genuine device run to INCOMPLETE.
DETAILS="$ARTIFACTS/device-details.json"
if xcrun devicectl device info details --device "$D_ID" \
     --json-output "$DETAILS" >/dev/null 2>&1; then
  ok "device answered a live query (tunnel established on demand)"

  LIVE_DDI="$(python3 - "$DETAILS" <<'PY' 2>/dev/null || echo unknown
import json, sys
doc = json.load(open(sys.argv[1]))
props = doc.get("result", {}).get("deviceProperties", {})
print("1" if props.get("ddiServicesAvailable") else "0")
PY
)"
  if [ "$LIVE_DDI" = "1" ]; then
    ok "developer disk image services available"
  else
    blocked "developer disk image services unavailable" \
            "unlock the iPad and leave it unlocked; Xcode mounts the DDI on first connection"
  fi
else
  blocked "device did not answer a live query (last seen $D_LAST_SEEN)" \
          "plug the iPad in and unlock it, or join it to this Mac's network for wireless debugging"
fi

# TARGETED_DEVICE_FAMILY is "2" (iPad) in project.yml.
if printf '%s' "$D_FAMILIES" | tr ',' '\n' | grep -qx "2"; then
  ok "device accepts iPad-family builds"
else
  bad "device does not support device family 2 (iPad)" \
      "this project is iPad-only; use an iPad or change TARGETED_DEVICE_FAMILY"
fi

if [ -n "$DEPLOYMENT_TARGET" ] && ! version_ge "$D_OS" "$DEPLOYMENT_TARGET"; then
  bad "iPadOS $D_OS is older than the deployment target $DEPLOYMENT_TARGET" \
      "update the iPad, or lower the deployment target in project.yml"
else
  ok "iPadOS $D_OS satisfies deployment target ${DEPLOYMENT_TARGET:-unset}"
fi

# An Xcode that predates the device's OS cannot install to it at all.
if [ -n "$SDK_VERSION" ]; then
  sdk_mm="$(printf '%s' "$SDK_VERSION" | cut -d. -f1,2)"
  dev_mm="$(printf '%s' "$D_OS" | cut -d. -f1,2)"
  if version_ge "$sdk_mm" "$dev_mm"; then
    ok "SDK $SDK_VERSION supports iPadOS $D_OS"
  else
    bad "iPadOS $D_OS is newer than the installed SDK $SDK_VERSION" \
        "update Xcode; this Xcode cannot install to that iPadOS"
  fi
fi

echo
if [ "$MISCONFIGURED" -eq 1 ]; then
  printf '  VERDICT: MISCONFIGURED — fix the repo or toolchain before retrying\n'
  exit 1
elif [ "$BLOCKED" -eq 1 ]; then
  printf '  VERDICT: BLOCKED — device evidence cannot be collected yet\n'
  exit 2
fi
printf '  VERDICT: READY — Tools/gate.sh 60 can run\n'
exit 0
