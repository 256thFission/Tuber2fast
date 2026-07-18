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
VERIFY_NONCE="$(uuidgen)"

print_help() {
    cat <<'EOF'
Usage: DeveloperTools/verify-scenario.sh [scenario]

M0 scenarios:
  blank-canvas    Blank scaffold canvas with no canned ink or Pins (default)
  fake-pin        One deterministic interior Pin
  multi-pin       Three deterministic interior Pins
  pdf-pages       Clean three-page M0Demo PDF fixture; page 2 selected
  blank-notebook  One branded dot-grid notebook page
  notebook-pages  Three dot-grid pages; distinct ink on appended pages 2 and 3
  ink-pages       Three-page M0Demo PDF; distinct ink on pages 1 and 3
  pin-drift       Stable Pin before/after deterministic viewport transition
  edge-pins       Four Pins near the page edges
  hero-recorded   Recorded agent-to-Pin stub; genuine lasso/crop pending

Environment:
  SKIP_BUILD=1                Reuse an existing DerivedData build
  DERIVED_DATA=…              Override DerivedData path (default: ./DerivedData)
  FORCE_MECHANICAL_FAILURE=1  Intentionally fail one isolated assertion after capture

The verifier checks build/install/launch, screenshot integrity, crash evidence,
console capture/fatal patterns, the DEBUG fixture-declaration marker, and (for
App-wired scenarios) a separate runtime-rendered state snapshot. It does not
automate navigation, compare pixels, measure Pin drift, or judge visual quality.
EOF
}

scenario_metadata() {
    EXPECTED_PAGE_COUNT=1
    EXPECTED_PAGE_INDEX=0
    EXPECTED_PAGE_ID="10000000-0000-0000-0000-000000000002"
    EXPECTED_PEN_FIXTURE_COUNT=0
    EXPECTED_ANNOTATION_COUNT=0
    EXPECTS_VIEWPORT_TRANSITION=false
    REQUIRES_RUNTIME_EVIDENCE=false
    EXPECTED_RUNTIME_SURFACE=""
    EXPECTED_RUNTIME_PAGE_COUNT=""
    EXPECTED_RUNTIME_PAGE_INDEX=""
    EXPECTED_RUNTIME_PAGE_ID=""
    EXPECTED_RUNTIME_PEN_FIXTURE=""
    EXPECTED_RUNTIME_ANNOTATION_IDS=""
    EXPECTED_RUNTIME_HERO_STATUS=""
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
            EXPECTED_ANNOTATION_COUNT=1
            ;;
        multi-pin)
            FAMILY="pins"
            EXPECTED_STATE="three deterministic Pins at distinct interior targets without catastrophic overlap"
            INTEGRATION_READINESS="scaffold-rendered"
            EXPECTED_ANNOTATION_COUNT=3
            ;;
        pdf-pages)
            FAMILY="pdf"
            EXPECTED_STATE="clean M0Demo PDF with three stable pages, showing page 2 of 3"
            INTEGRATION_READINESS="app-wired"
            EXPECTED_PAGE_COUNT=3
            EXPECTED_PAGE_INDEX=1
            EXPECTED_PAGE_ID="20000000-0000-0000-0000-000000000012"
            REQUIRES_RUNTIME_EVIDENCE=true
            EXPECTED_RUNTIME_SURFACE="spatial-canvas"
            ;;
        blank-notebook)
            FAMILY="notebook"
            EXPECTED_STATE="new notebook with one branded TuberNotes dot-grid page and no ink"
            INTEGRATION_READINESS="app-wired"
            EXPECTED_PAGE_ID="30000000-0000-0000-0000-000000000011"
            REQUIRES_RUNTIME_EVIDENCE=true
            EXPECTED_RUNTIME_SURFACE="spatial-canvas"
            ;;
        notebook-pages)
            FAMILY="notebook"
            EXPECTED_STATE="three dot-grid pages, with distinct canned drawings on appended pages 2 and 3, showing page 3"
            INTEGRATION_READINESS="app-wired"
            EXPECTED_PAGE_COUNT=3
            EXPECTED_PAGE_INDEX=2
            EXPECTED_PAGE_ID="30000000-0000-0000-0000-000000000013"
            EXPECTED_PEN_FIXTURE_COUNT=2
            REQUIRES_RUNTIME_EVIDENCE=true
            EXPECTED_RUNTIME_SURFACE="spatial-canvas"
            EXPECTED_RUNTIME_PEN_FIXTURE="notebook-page-3"
            ;;
        ink-pages)
            FAMILY="ink"
            EXPECTED_STATE="M0Demo PDF with distinct canned drawings on pages 1 and 3, showing page 3"
            INTEGRATION_READINESS="app-wired"
            EXPECTED_PAGE_COUNT=3
            EXPECTED_PAGE_INDEX=2
            EXPECTED_PAGE_ID="20000000-0000-0000-0000-000000000013"
            EXPECTED_PEN_FIXTURE_COUNT=2
            REQUIRES_RUNTIME_EVIDENCE=true
            EXPECTED_RUNTIME_SURFACE="spatial-canvas"
            EXPECTED_RUNTIME_PEN_FIXTURE="pdf-page-3-ink"
            ;;
        pin-drift)
            FAMILY="spatial"
            EXPECTED_STATE="one stable Pin target at (0.58, 0.42), checked before and after a deterministic viewport transition"
            INTEGRATION_READINESS="app-wired"
            EXPECTED_PAGE_COUNT=3
            EXPECTED_PAGE_INDEX=1
            EXPECTED_PAGE_ID="20000000-0000-0000-0000-000000000012"
            EXPECTED_ANNOTATION_COUNT=1
            EXPECTS_VIEWPORT_TRANSITION=true
            REQUIRES_RUNTIME_EVIDENCE=true
            EXPECTED_RUNTIME_SURFACE="spatial-canvas"
            EXPECTED_RUNTIME_ANNOTATION_IDS="45555555-5555-5555-5555-555555555555"
            ;;
        edge-pins)
            FAMILY="pins"
            EXPECTED_STATE="four deterministic Pins near the top, right, bottom, and left edges with unclipped labels"
            INTEGRATION_READINESS="app-wired"
            EXPECTED_ANNOTATION_COUNT=4
            REQUIRES_RUNTIME_EVIDENCE=true
            EXPECTED_RUNTIME_SURFACE="standalone-pin-surface"
            EXPECTED_RUNTIME_ANNOTATION_IDS="46666666-6666-6666-6666-666666666661,46666666-6666-6666-6666-666666666662,46666666-6666-6666-6666-666666666663,46666666-6666-6666-6666-666666666664"
            ;;
        hero-recorded)
            FAMILY="hero"
            EXPECTED_STATE="recorded agent-to-Pin stub; genuine lasso capture and crop remain pending"
            INTEGRATION_READINESS="partial-stub"
            REQUIRES_RUNTIME_EVIDENCE=true
            EXPECTED_RUNTIME_SURFACE="recorded-hero-stub"
            EXPECTED_RUNTIME_PAGE_COUNT=1
            EXPECTED_RUNTIME_PAGE_INDEX=0
            EXPECTED_RUNTIME_PAGE_ID="70000000-0000-0000-0000-000000000011"
            EXPECTED_RUNTIME_ANNOTATION_IDS="70000000-0000-0000-0000-000000000001"
            EXPECTED_RUNTIME_HERO_STATUS="Proposed Pin ready"
            ;;
        *)
            return 1
            ;;
    esac
    EXPECTED_RUNTIME_PAGE_COUNT="${EXPECTED_RUNTIME_PAGE_COUNT:-$EXPECTED_PAGE_COUNT}"
    EXPECTED_RUNTIME_PAGE_INDEX="${EXPECTED_RUNTIME_PAGE_INDEX:-$EXPECTED_PAGE_INDEX}"
    EXPECTED_RUNTIME_PAGE_ID="${EXPECTED_RUNTIME_PAGE_ID:-$EXPECTED_PAGE_ID}"
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
SCENARIO_ASSERTIONS="$ARTIFACT_DIR/scenario-assertions.txt"
RUNTIME_EVIDENCE="$ARTIFACT_DIR/runtime-rendered.json"
RUNTIME_ASSERTIONS="$ARTIFACT_DIR/runtime-assertions.txt"
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
runtime_evidence_status="not-captured"
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
SIMCTL_CHILD_TUBER_VERIFY_NONCE="$VERIFY_NONCE" \
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
        shasum -a 256 "$SCREENSHOT" >>"$SCREENSHOT_INFO"
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
    && cp "$data_container/Documents/developer-evidence/scenario-selection.json" "$SCENARIO_SELECTION" 2>/dev/null; then
    set +e
    python3 - "$SCENARIO_SELECTION" "$SCENARIO" "$FAMILY" "$INTEGRATION_READINESS" \
        "$EXPECTED_STATE" "$EXPECTED_PAGE_COUNT" "$EXPECTED_PAGE_INDEX" "$EXPECTED_PAGE_ID" \
        "$EXPECTED_PEN_FIXTURE_COUNT" "$EXPECTED_ANNOTATION_COUNT" "$EXPECTS_VIEWPORT_TRANSITION" \
        "$VERIFY_NONCE" \
        >"$SCENARIO_ASSERTIONS" 2>&1 <<'PY'
import json
import sys

(
    marker_path, scenario, family, readiness, expected_state, page_count,
    page_index, page_id, pen_count, annotation_count, viewport_transition,
    verification_nonce,
) = sys.argv[1:]
with open(marker_path, encoding="utf-8") as marker_file:
    marker = json.load(marker_file)

expected = {
    "scenario": scenario,
    "verificationNonce": verification_nonce,
    "fixtureFamily": family,
    "integrationReadiness": readiness,
    "expectedState": expected_state,
    "pageCount": int(page_count),
    "currentPageIndex": int(page_index),
    "currentPageID": page_id,
    "expectsViewportTransition": viewport_transition == "true",
}
failures = []
for key, expected_value in expected.items():
    observed = marker.get(key)
    if observed != expected_value:
        failures.append(f"{key}: expected={expected_value!r} observed={observed!r}")

counts = {
    "penFixturePageIDs": int(pen_count),
    "annotationIDs": int(annotation_count),
}
for key, expected_count in counts.items():
    observed = marker.get(key)
    if not isinstance(observed, list) or len(observed) != expected_count:
        failures.append(f"{key}: expected_count={expected_count} observed={observed!r}")

if failures:
    print("fixture assertions failed")
    print("\n".join(failures))
    raise SystemExit(1)
print("fixture assertions passed")
for key, value in expected.items():
    print(f"{key}={value}")
for key, value in counts.items():
    print(f"{key}.count={value}")
PY
    marker_assert_exit=$?
    set -e
    if [[ $marker_assert_exit -eq 0 ]]; then
        scenario_marker_status="pass"
    else
        scenario_marker_status="fail-fixture-assertions"
        pass=0
    fi
else
    scenario_marker_status="fail-missing-or-mismatched"
    printf '%s\n' "scenario marker missing from app data container" >"$SCENARIO_ASSERTIONS"
    pass=0
fi

if [[ "$REQUIRES_RUNTIME_EVIDENCE" == "true" ]]; then
    if [[ $container_exit -eq 0 && -n "$data_container" ]] \
        && cp "$data_container/Documents/developer-evidence/runtime-rendered.json" "$RUNTIME_EVIDENCE" 2>/dev/null; then
        set +e
        python3 - "$RUNTIME_EVIDENCE" "$SCENARIO" "$EXPECTED_RUNTIME_SURFACE" \
            "$EXPECTED_RUNTIME_PAGE_COUNT" "$EXPECTED_RUNTIME_PAGE_INDEX" "$EXPECTED_RUNTIME_PAGE_ID" \
            "$EXPECTED_RUNTIME_PEN_FIXTURE" "$EXPECTED_RUNTIME_ANNOTATION_IDS" \
            "$EXPECTED_RUNTIME_HERO_STATUS" "$VERIFY_NONCE" >"$RUNTIME_ASSERTIONS" 2>&1 <<'PY'
import json
import sys

(
    evidence_path, scenario, surface, page_count, page_index, page_id,
    pen_fixture, annotation_ids, hero_status, verification_nonce,
) = sys.argv[1:]
with open(evidence_path, encoding="utf-8") as evidence_file:
    evidence = json.load(evidence_file)

expected = {
    "schemaVersion": 1,
    "scenario": scenario,
    "verificationNonce": verification_nonce,
    "surfaceKind": surface,
    "pageCount": int(page_count),
    "currentPageIndex": int(page_index),
    "currentPageID": page_id,
    "renderedPenFixtureName": pen_fixture or None,
    "renderedAnnotationIDs": sorted(filter(None, annotation_ids.split(","))),
    "heroStatus": hero_status or None,
}
failures = []
for key, expected_value in expected.items():
    observed = evidence.get(key)
    if observed != expected_value:
        failures.append(f"{key}: expected={expected_value!r} observed={observed!r}")

recorded_at = evidence.get("recordedAt")
if not isinstance(recorded_at, str) or not recorded_at:
    failures.append(f"recordedAt: expected=non-empty-string observed={recorded_at!r}")

if failures:
    print("runtime-rendered assertions failed")
    print("\n".join(failures))
    raise SystemExit(1)
print("runtime-rendered assertions passed")
for key, value in expected.items():
    print(f"{key}={value!r}")
print(f"recordedAt={recorded_at}")
PY
        runtime_assert_exit=$?
        set -e
        if [[ $runtime_assert_exit -eq 0 ]]; then
            runtime_evidence_status="pass"
        else
            runtime_evidence_status="fail-runtime-assertions"
            pass=0
        fi
    else
        runtime_evidence_status="fail-missing"
        printf '%s\n' \
            "runtime-rendered evidence missing; fixture declarations do not prove App rendering" \
            >"$RUNTIME_ASSERTIONS"
        pass=0
    fi
else
    runtime_evidence_status="not-required"
    printf '%s\n' "runtime-rendered evidence is not required for this scenario" >"$RUNTIME_ASSERTIONS"
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
    pass=0
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
note "scenario_assertions: $SCENARIO_ASSERTIONS"
note "RUNTIME_EVIDENCE: $runtime_evidence_status"
note "runtime_rendered: $RUNTIME_EVIDENCE"
note "runtime_assertions: $RUNTIME_ASSERTIONS"
note "CRASH_STATUS: $crash_status"
note "crash_hits: $CRASH_HITS"

if [[ "$FORCE_MECHANICAL_FAILURE" == "1" ]]; then
    printf '%s\n' "intentional expected=stable-anchor observed=offset-by-3pt" >"$ARTIFACT_DIR/intentional-failure.txt"
    note "MECHANICAL_ASSERTION: FAIL (intentional isolated failure requested)"
    note "intentional_failure: $ARTIFACT_DIR/intentional-failure.txt"
    pass=0
fi

if [[ $pass -eq 1 ]]; then
    note "MECHANICAL_ASSERTION: PASS (launch, fixture declaration, required runtime-rendered evidence, screenshot integrity, console capture/fatal scan, new-crash scan)"
else
    note "MECHANICAL_ASSERTION: FAIL (one or more required mechanical checks failed or were incomplete)"
fi

if [[ "$INTEGRATION_READINESS" == "partial-stub" ]]; then
    note "UI_EXPECTED_STATE: PARTIAL/STUB; genuine lasso capture and crop are not implemented"
elif [[ "$INTEGRATION_READINESS" == "ready-for-app-wiring" ]]; then
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
