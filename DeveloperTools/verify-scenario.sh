#!/usr/bin/env bash
# Lightweight TuberNotes scenario verification.
# Builds, launches a named DEBUG scenario, captures compact evidence, and reports
# mechanical pass/fail. Visual taste and Apple Pencil feel remain human-only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="TuberNotes.xcodeproj"
SCHEME="TuberNotes"
SIMULATOR="iPad Pro 13-inch (M5)"
BUNDLE_ID="com.tubernotes.app"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/DerivedData}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/TuberNotes.app"
SKIP_BUILD="${SKIP_BUILD:-0}"
FORCE_MECHANICAL_FAILURE="${FORCE_MECHANICAL_FAILURE:-0}"

print_help() {
    cat <<'EOF'
Usage: DeveloperTools/verify-scenario.sh [scenario]

M0 scenarios:
  blank-canvas    Blank scaffold canvas with no canned ink or Pins (default)
  fake-pin        One deterministic interior Pin
  multi-pin       Three deterministic interior Pins
  pdf-pages       Clean three-page M0Demo PDF fixture; page 1 selected
  blank-notebook  One branded dot-grid notebook page
  notebook-pages  Three dot-grid pages; distinct ink on appended pages 2 and 3
  ink-pages       Three-page M0Demo PDF; distinct ink on pages 1 and 3
  pin-drift       Stable Pin before/after deterministic viewport transition
  edge-pins       Four Pins near the page edges

Environment:
  SKIP_BUILD=1                Reuse an existing DerivedData build
  DERIVED_DATA=…              Override DerivedData path (default: ./DerivedData)
  FORCE_MECHANICAL_FAILURE=1  Intentionally fail one isolated assertion after capture

The verifier checks build/install/launch, screenshot integrity, crash evidence,
and the app's durable DEBUG scenario-selection marker. Expected UI state is
reported separately; fixtures marked ready-for-app-wiring require coordinator
App integration before that UI state can be accepted.
EOF
}

scenario_metadata() {
    case "$1" in
        blank-canvas)
            FAMILY="baseline"
            EXPECTED_STATE="one blank canvas with no canned ink or Pins"
            INTEGRATION_READINESS="scaffold-rendered"
            ;;
        fake-pin)
            FAMILY="pins"
            EXPECTED_STATE="one deterministic Pin at page-normalized target (0.62, 0.34)"
            INTEGRATION_READINESS="scaffold-rendered"
            ;;
        multi-pin)
            FAMILY="pins"
            EXPECTED_STATE="three deterministic Pins at distinct interior targets without catastrophic overlap"
            INTEGRATION_READINESS="scaffold-rendered"
            ;;
        pdf-pages)
            FAMILY="pdf"
            EXPECTED_STATE="clean M0Demo PDF with three stable pages, showing page 1 of 3"
            INTEGRATION_READINESS="ready-for-app-wiring"
            ;;
        blank-notebook)
            FAMILY="notebook"
            EXPECTED_STATE="new notebook with one branded TuberNotes dot-grid page and no ink"
            INTEGRATION_READINESS="ready-for-app-wiring"
            ;;
        notebook-pages)
            FAMILY="notebook"
            EXPECTED_STATE="three dot-grid pages, with distinct canned drawings on appended pages 2 and 3, showing page 3"
            INTEGRATION_READINESS="ready-for-app-wiring"
            ;;
        ink-pages)
            FAMILY="ink"
            EXPECTED_STATE="M0Demo PDF with distinct canned drawings on pages 1 and 3, showing page 3"
            INTEGRATION_READINESS="ready-for-app-wiring"
            ;;
        pin-drift)
            FAMILY="spatial"
            EXPECTED_STATE="one stable Pin target at (0.58, 0.42), checked before and after a deterministic viewport transition"
            INTEGRATION_READINESS="ready-for-app-wiring"
            ;;
        edge-pins)
            FAMILY="pins"
            EXPECTED_STATE="four deterministic Pins near the top, right, bottom, and left edges with unclipped labels"
            INTEGRATION_READINESS="ready-for-app-wiring"
            ;;
        *)
            return 1
            ;;
    esac
}

SCENARIO="${1:-blank-canvas}"
case "$SCENARIO" in
    -h|--help)
        print_help
        exit 0
        ;;
esac

if ! scenario_metadata "$SCENARIO"; then
    echo "FAIL: unknown or not-yet-runnable scenario '$SCENARIO'" >&2
    echo "Run DeveloperTools/verify-scenario.sh --help for the M0 allowlist." >&2
    exit 2
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
ARTIFACT_DIR="$ROOT/tmp/verify/${STAMP}-${SCENARIO}"
mkdir -p "$ARTIFACT_DIR"

BUILD_LOG="$ARTIFACT_DIR/build.log"
INSTALL_LOG="$ARTIFACT_DIR/install.log"
LAUNCH_LOG="$ARTIFACT_DIR/launch.log"
CONSOLE_LOG="$ARTIFACT_DIR/console.log"
CONSOLE_ERRORS="$ARTIFACT_DIR/console-errors.txt"
SCREENSHOT="$ARTIFACT_DIR/screenshot.png"
SCREENSHOT_LOG="$ARTIFACT_DIR/screenshot.log"
SCREENSHOT_INFO="$ARTIFACT_DIR/screenshot-info.txt"
SCENARIO_SELECTION="$ARTIFACT_DIR/scenario-selection.json"
CRASH_HITS="$ARTIFACT_DIR/crash-hits.txt"
SUMMARY="$ARTIFACT_DIR/summary.txt"
LAUNCH_MARKER="$ARTIFACT_DIR/launch.started"

pass=1
build_status="skipped"
launch_status="unknown"
screenshot_status="missing"
scenario_marker_status="not-captured"
crash_status="not-checked"
console_status="not-captured"
pid=""

note() {
    printf '%s\n' "$*" | tee -a "$SUMMARY"
}

note "TuberNotes verify-scenario"
note "scenario: $SCENARIO"
note "fixture_family: $FAMILY"
note "expected_state: $EXPECTED_STATE"
note "integration_readiness: $INTEGRATION_READINESS"
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
    printf '%s\n' "(build skipped; reused $APP_PATH)" >"$BUILD_LOG"
fi

note "BUILD: $build_status"
note "build_log: $BUILD_LOG"

xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
open -a Simulator >/dev/null 2>&1 || true

for _ in $(seq 1 30); do
    if xcrun simctl list devices | grep -F "$SIMULATOR" | grep -q "(Booted)"; then
        break
    fi
    sleep 1
done

xcrun simctl install booted "$APP_PATH" >"$INSTALL_LOG" 2>&1

: >"$LAUNCH_MARKER"
set +e
SIMCTL_CHILD_TUBER_SCENARIO="$SCENARIO" \
    xcrun simctl launch --terminate-running-process booted "$BUNDLE_ID" \
    >"$LAUNCH_LOG" 2>&1
launch_exit=$?
set -e

if [[ $launch_exit -eq 0 ]]; then
    pid="$(awk -F': ' '/:/{print $NF; exit}' "$LAUNCH_LOG" | tr -d '[:space:]')"
    if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
        launch_status="pass"
    else
        launch_status="fail"
        pass=0
    fi
else
    launch_status="fail"
    pass=0
fi

note "INSTALL_LOG: $INSTALL_LOG"
note "LAUNCH: $launch_status${pid:+ (pid=$pid)}"
note "launch_log: $LAUNCH_LOG"

sleep 2
set +e
xcrun simctl io booted screenshot "$SCREENSHOT" >"$SCREENSHOT_LOG" 2>&1
shot_exit=$?
set -e
if [[ $shot_exit -eq 0 && -s "$SCREENSHOT" ]] && sips -g pixelWidth -g pixelHeight "$SCREENSHOT" >"$SCREENSHOT_INFO" 2>&1; then
    if grep -Eq 'pixelWidth: [1-9][0-9]*' "$SCREENSHOT_INFO" && grep -Eq 'pixelHeight: [1-9][0-9]*' "$SCREENSHOT_INFO"; then
        screenshot_status="pass"
    else
        screenshot_status="fail-invalid-dimensions"
        pass=0
    fi
else
    screenshot_status="fail"
    pass=0
fi

note "SCREENSHOT: $screenshot_status"
note "screenshot: $SCREENSHOT"
note "screenshot_info: $SCREENSHOT_INFO"

set +e
data_container="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)"
container_exit=$?
set -e
if [[ $container_exit -eq 0 && -n "$data_container" ]] \
    && cp "$data_container/Documents/developer-evidence/scenario-selection.json" "$SCENARIO_SELECTION" 2>/dev/null \
    && grep -Eq "\"scenario\"[[:space:]]*:[[:space:]]*\"$SCENARIO\"" "$SCENARIO_SELECTION"; then
    scenario_marker_status="pass"
else
    scenario_marker_status="fail-missing-or-mismatched"
    pass=0
fi

set +e
xcrun simctl spawn booted log show \
    --style compact \
    --last 2m \
    --predicate 'process == "TuberNotes"' >"$CONSOLE_LOG" 2>&1
console_exit=$?
set -e
if [[ $console_exit -eq 0 ]]; then
    console_status="captured"
    grep -Ei 'Fatal error|Terminating app due to uncaught exception|abort trap' "$CONSOLE_LOG" >"$CONSOLE_ERRORS" || true
    if [[ -s "$CONSOLE_ERRORS" ]]; then
        console_status="fatal-patterns-present"
        pass=0
    fi
else
    printf '%s\n' "log capture failed with exit $console_exit" >"$CONSOLE_ERRORS"
    console_status="capture-failed"
fi

: >"$CRASH_HITS"
for crash_root in "$HOME/Library/Logs/DiagnosticReports" "$HOME/Library/Logs/CoreSimulator"; do
    if [[ -d "$crash_root" ]]; then
        find "$crash_root" -type f \
            \( -name '*TuberNotes*.crash' -o -name '*TuberNotes*.ips' \) \
            -newer "$LAUNCH_MARKER" -print >>"$CRASH_HITS" 2>/dev/null || true
    fi
done
if [[ -s "$CRASH_HITS" ]]; then
    crash_status="fail-new-report"
    pass=0
else
    crash_status="pass-no-new-report"
fi

note "CONSOLE: $console_status"
note "console_log: $CONSOLE_LOG"
note "console_errors: $CONSOLE_ERRORS"
note "SCENARIO_MARKER: $scenario_marker_status"
note "scenario_selection: $SCENARIO_SELECTION"
note "CRASH_STATUS: $crash_status"
note "crash_hits: $CRASH_HITS"

if [[ "$FORCE_MECHANICAL_FAILURE" == "1" ]]; then
    printf '%s\n' "intentional expected=stable-anchor observed=offset-by-3pt" >"$ARTIFACT_DIR/intentional-failure.txt"
    note "MECHANICAL_ASSERTION: FAIL (intentional isolated failure requested)"
    note "intentional_failure: $ARTIFACT_DIR/intentional-failure.txt"
    pass=0
else
    note "MECHANICAL_ASSERTION: PASS (launch, scenario marker, screenshot integrity, fatal-console scan, new-crash scan)"
fi

if [[ "$INTEGRATION_READINESS" == "ready-for-app-wiring" ]]; then
    note "UI_EXPECTED_STATE: PENDING coordinator App wiring; this result does not accept the described UI state"
else
    note "UI_EXPECTED_STATE: requires screenshot inspection; verifier does not judge layout or taste"
fi
note "human_only: Apple Pencil feel/latency; visual taste; interaction quality"
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
