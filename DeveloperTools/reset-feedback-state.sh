#!/usr/bin/env bash
# Clear Debug feedback-thread state without uninstalling TuberNotes or touching
# any product data outside the feedback-thread store.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HOST_MIRROR="$ROOT/.feedback-threads"
BUNDLE_ID="com.tubernotes.app"
DEVICE_ID=""
CONFIRMED=0

usage() {
    cat <<'EOF'
Usage: DeveloperTools/reset-feedback-state.sh --device <device-id> --confirm

Clears stale Debug feedback questions from both sides of the physical-device
review loop:
  1. validates that com.tubernotes.app is installed on the named device;
  2. clears only this repo's gitignored .feedback-threads host mirror;
  3. launches TuberNotes once with TUBER_RESET_FEEDBACK_STATE=1;
  4. relaunches TuberNotes normally so the reset flag is not retained.

Required:
  --device <device-id>  Physical iPad identifier accepted by devicectl
  --confirm             Explicitly authorize deletion of Debug feedback state

This command does not uninstall the app and does not delete notebooks, PDFs,
ink, Pins, Pencil fixtures, or other product data.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --device)
            (($# >= 2)) || die "--device requires a value"
            DEVICE_ID="$2"
            shift 2
            ;;
        --confirm)
            CONFIRMED=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1 (run with --help)"
            ;;
    esac
done

[[ -n "$DEVICE_ID" ]] || die "--device is required"
[[ "$CONFIRMED" == "1" ]] || die "refusing to clear feedback state without --confirm"
command -v xcrun >/dev/null 2>&1 || die "xcrun is unavailable"

# Resolve and compare paths before any deletion. Refuse a symlink so the fixed
# repo-local boundary cannot be redirected elsewhere.
[[ ! -L "$HOST_MIRROR" ]] || die "$HOST_MIRROR must not be a symbolic link"
[[ "$HOST_MIRROR" == "$ROOT/.feedback-threads" ]] || die "unexpected host mirror path"

device_apps_json="$(mktemp -t tubernotes-feedback-reset.XXXXXX.json)"
trap 'rm -f "$device_apps_json"' EXIT

printf 'Validating TuberNotes on physical device %s...\n' "$DEVICE_ID"
xcrun devicectl device info apps \
    --device "$DEVICE_ID" \
    --bundle-id "$BUNDLE_ID" \
    --json-output "$device_apps_json" \
    --quiet
grep -Fq "$BUNDLE_ID" "$device_apps_json" \
    || die "$BUNDLE_ID is not installed on device $DEVICE_ID"

printf 'Clearing repo host mirror: %s\n' "$HOST_MIRROR"
rm -rf -- "$HOST_MIRROR"
mkdir -p -- "$HOST_MIRROR"

printf 'Resetting Debug feedback state in TuberNotes...\n'
xcrun devicectl device process launch \
    --device "$DEVICE_ID" \
    --terminate-existing \
    --environment-variables '{"TUBER_RESET_FEEDBACK_STATE":"1"}' \
    "$BUNDLE_ID"

printf 'Relaunching TuberNotes without the reset flag...\n'
xcrun devicectl device process launch \
    --device "$DEVICE_ID" \
    --terminate-existing \
    "$BUNDLE_ID"

printf 'Feedback state reset complete for device %s.\n' "$DEVICE_ID"
