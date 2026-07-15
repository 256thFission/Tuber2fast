#!/usr/bin/env bash
# Lightweight TuberNotes scenario verification.
# Builds, launches a named DEBUG scenario, captures screenshot + logs,
# and prints a compact pass/fail summary with artifact paths.
#
# Does NOT judge visual taste or Apple Pencil feel — those remain human.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="TuberNotes.xcodeproj"
SCHEME="TuberNotes"
SIMULATOR="iPad Pro 13-inch (M5)"
BUNDLE_ID="com.tubernotes.app"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/DerivedData}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/TuberNotes.app"

SCENARIO="${1:-blank-canvas}"
SKIP_BUILD="${SKIP_BUILD:-0}"
case "$SCENARIO" in
  blank-canvas|fake-pin|multi-pin) ;;
  -h|--help)
    cat <<EOF
Usage: DeveloperTools/verify-scenario.sh [scenario]

Scenarios: blank-canvas (default), fake-pin, multi-pin

Environment:
  SKIP_BUILD=1     Reuse existing DerivedData build
  DERIVED_DATA=…   Override DerivedData path (default: ./DerivedData)
EOF
    exit 0
    ;;
  *)
    echo "FAIL: unknown scenario '$SCENARIO' (expected blank-canvas|fake-pin|multi-pin)" >&2
    exit 2
    ;;
esac

STAMP="$(date +%Y%m%d-%H%M%S)"
ARTIFACT_DIR="$ROOT/tmp/verify/${STAMP}-${SCENARIO}"
mkdir -p "$ARTIFACT_DIR"

BUILD_LOG="$ARTIFACT_DIR/build.log"
LAUNCH_LOG="$ARTIFACT_DIR/launch.log"
SCREENSHOT="$ARTIFACT_DIR/screenshot.png"
SUMMARY="$ARTIFACT_DIR/summary.txt"

pass=1
build_status="skipped"
launch_status="unknown"
screenshot_status="missing"
console_status="not-captured"
pid=""

note() {
  printf '%s\n' "$*" | tee -a "$SUMMARY"
}

note "TuberNotes verify-scenario"
note "scenario: $SCENARIO"
note "simulator: $SIMULATOR"
note "artifacts: $ARTIFACT_DIR"
note "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
note ""

if [[ "$SKIP_BUILD" != "1" ]]; then
  set +e
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=$SIMULATOR" \
    -derivedDataPath "$DERIVED_DATA" \
    build >"$BUILD_LOG" 2>&1
  build_exit=$?
  set -e
  if [[ $build_exit -eq 0 ]]; then
    build_status="pass"
  else
    build_status="fail"
    pass=0
    note "BUILD: FAIL (exit $build_exit)"
    note "build_log: $BUILD_LOG"
    note "--- build tail ---"
    tail -n 40 "$BUILD_LOG" | tee -a "$SUMMARY"
    note "--- end build tail ---"
    note ""
    note "RESULT: FAIL"
    note "artifact_dir: $ARTIFACT_DIR"
    exit 1
  fi
else
  if [[ ! -d "$APP_PATH" ]]; then
    note "BUILD: FAIL (SKIP_BUILD=1 but app missing at $APP_PATH)"
    note "RESULT: FAIL"
    note "artifact_dir: $ARTIFACT_DIR"
    exit 1
  fi
  echo "(build skipped)" >"$BUILD_LOG"
  build_status="skipped"
fi

note "BUILD: $build_status"
note "build_log: $BUILD_LOG"

xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
open -a Simulator >/dev/null 2>&1 || true

# Wait briefly for boot readiness.
for _ in $(seq 1 30); do
  if xcrun simctl list devices | grep -F "$SIMULATOR" | grep -q "(Booted)"; then
    break
  fi
  sleep 1
done

xcrun simctl install booted "$APP_PATH" >"$ARTIFACT_DIR/install.log" 2>&1

set +e
SIMCTL_CHILD_TUBER_SCENARIO="$SCENARIO" \
  xcrun simctl launch --terminate-running-process booted "$BUNDLE_ID" \
  >"$LAUNCH_LOG" 2>&1
launch_exit=$?
set -e

if [[ $launch_exit -eq 0 ]]; then
  # simctl launch prints: <bundle-id>: <pid>
  pid="$(awk -F': ' '/:/{print $NF; exit}' "$LAUNCH_LOG" | tr -d '[:space:]')"
  if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
    launch_status="pass"
    console_status="launched pid=$pid"
  else
    launch_status="fail"
    console_status="launch output missing pid"
    pass=0
  fi
else
  launch_status="fail"
  console_status="launch exit $launch_exit"
  pass=0
fi

note "LAUNCH: $launch_status"
note "console: $console_status"
note "launch_log: $LAUNCH_LOG"

# Give the first frame a moment, then screenshot.
sleep 2
set +e
xcrun simctl io booted screenshot "$SCREENSHOT" >"$ARTIFACT_DIR/screenshot.log" 2>&1
shot_exit=$?
set -e
if [[ $shot_exit -eq 0 && -f "$SCREENSHOT" ]]; then
  screenshot_status="captured"
else
  screenshot_status="fail"
  pass=0
fi

note "SCREENSHOT: $screenshot_status"
note "screenshot: $SCREENSHOT"

# Best-effort recent crash sniffs (do not fail solely on absence).
CRASH_DIR="$HOME/Library/Logs/CoreSimulator"
CRASH_HITS="$ARTIFACT_DIR/crash-hits.txt"
: >"$CRASH_HITS"
if [[ -d "$CRASH_DIR" ]]; then
  # shellcheck disable=SC2038
  find "$CRASH_DIR" -type f \( -name '*TuberNotes*' -o -name '*.crash' -o -name '*.ips' \) -mmin -30 2>/dev/null \
    | head -n 20 >"$CRASH_HITS" || true
fi
if [[ -s "$CRASH_HITS" ]]; then
  console_status="possible recent crash artifacts (see crash-hits.txt)"
  note "CRASH_HINTS: present"
  note "crash_hits: $CRASH_HITS"
else
  note "CRASH_HINTS: none recent under CoreSimulator (30m)"
fi

note ""
note "mechanical_checks: process launched; screenshot captured; scenario requested=$SCENARIO"
note "human_only: Apple Pencil feel/latency; visual taste; interaction quality"
note "expected_state: see Docs/Development.md scenario map for '$SCENARIO'"
note ""

if [[ $pass -eq 1 ]]; then
  note "RESULT: PASS"
  note "artifact_dir: $ARTIFACT_DIR"
  echo ""
  echo "PASS  scenario=$SCENARIO  artifacts=$ARTIFACT_DIR"
  exit 0
fi

note "RESULT: FAIL"
note "artifact_dir: $ARTIFACT_DIR"
echo ""
echo "FAIL  scenario=$SCENARIO  artifacts=$ARTIFACT_DIR"
exit 1
