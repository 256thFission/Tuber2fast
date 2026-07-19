#!/usr/bin/env bash
# Lightweight physical-iPad TuberNotes scenario verification.
# Builds, installs, launches a named DEBUG scenario, pulls compact runtime
# evidence, and reports mechanical pass/fail. Visible inspection and Apple
# Pencil feel remain human-only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="TuberNotes.xcodeproj"
SCHEME="TuberNotes"
BUNDLE_ID="com.tubernotes.app"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/DerivedDataDevice}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/TuberNotes.app"
SKIP_BUILD="${SKIP_BUILD:-0}"
FORCE_MECHANICAL_FAILURE="${FORCE_MECHANICAL_FAILURE:-0}"
VERIFY_NONCE="$(uuidgen)"
DEVICE_SESSION_TOOL="$ROOT/DeveloperTools/device_session.py"

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
  lasso-crop      PDF + ink Magic Lasso selection with retained PNG crop
  pin-drift       Stable Pin before/after deterministic viewport transition
  edge-pins       Four Pins near the page edges
  agent-recorded-success    Recorded success sequence ending in one Pin
  agent-recorded-retrieval  Recorded retrieval sequence ending in one cited Pin
  agent-recorded-failure    Recorded recoverable failure with no Pin
  hero-recorded   Recorded agent-to-Pin stub; genuine lasso/crop pending

Environment:
  SKIP_BUILD=1                Reuse an existing DerivedData build
  DERIVED_DATA=…              Override DerivedData path (default: ./DerivedDataDevice)
  FORCE_MECHANICAL_FAILURE=1  Intentionally fail one isolated assertion after capture

Run `DeveloperTools/device-preflight.sh --device <device-id>` first. The
verifier consumes that explicit session and never discovers or falls back to
another target. It checks build/install/launch, the DEBUG
fixture-declaration marker, and (for App-wired scenarios) a separate
runtime-rendered state snapshot. Physical-device screenshots, console logs,
crash diagnostics, navigation, pixel comparison, Pin-drift measurement, and
visual-quality judgments require separately reported evidence.
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
    REQUIRES_SELECTION_CROP=false
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
        lasso-crop)
            FAMILY="selection"
            EXPECTED_STATE="known PDF and ink selection with an inspectable crop artifact"
            INTEGRATION_READINESS="app-wired"
            EXPECTED_PAGE_COUNT=3
            EXPECTED_PAGE_INDEX=1
            EXPECTED_PAGE_ID="20000000-0000-0000-0000-000000000012"
            EXPECTED_PEN_FIXTURE_COUNT=1
            REQUIRES_RUNTIME_EVIDENCE=true
            EXPECTED_RUNTIME_SURFACE="spatial-canvas"
            EXPECTED_RUNTIME_PEN_FIXTURE="lasso-crop-ink"
            REQUIRES_SELECTION_CROP=true
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
        agent-recorded-success)
            FAMILY="agent"
            EXPECTED_STATE="complete recorded agent event sequence ending in one proposed Pin"
            INTEGRATION_READINESS="app-wired"
            REQUIRES_RUNTIME_EVIDENCE=true
            EXPECTED_RUNTIME_SURFACE="recorded-hero-stub"
            EXPECTED_RUNTIME_PAGE_ID="70000000-0000-0000-0000-000000000011"
            EXPECTED_RUNTIME_ANNOTATION_IDS="70000000-0000-0000-0000-000000000001"
            EXPECTED_RUNTIME_HERO_STATUS="Proposed Pin ready"
            ;;
        agent-recorded-retrieval)
            FAMILY="agent"
            EXPECTED_STATE="recorded textbook retrieval tool sequence ending in one cited Pin"
            INTEGRATION_READINESS="app-wired"
            REQUIRES_RUNTIME_EVIDENCE=true
            EXPECTED_RUNTIME_SURFACE="recorded-hero-stub"
            EXPECTED_RUNTIME_PAGE_ID="70000000-0000-0000-0000-000000000011"
            EXPECTED_RUNTIME_ANNOTATION_IDS="70000000-0000-0000-0000-000000000003"
            EXPECTED_RUNTIME_HERO_STATUS="Proposed Pin ready"
            ;;
        agent-recorded-failure)
            FAMILY="agent"
            EXPECTED_STATE="recoverable recorded provider failure with no proposed Pin"
            INTEGRATION_READINESS="app-wired"
            REQUIRES_RUNTIME_EVIDENCE=true
            EXPECTED_RUNTIME_SURFACE="recorded-hero-stub"
            EXPECTED_RUNTIME_PAGE_ID="70000000-0000-0000-0000-000000000011"
            EXPECTED_RUNTIME_HERO_STATUS="The recorded provider is temporarily unavailable."
            ;;
        hero-recorded)
            FAMILY="hero"
            EXPECTED_STATE="fixture selection and action strip; genuine lasso integration remains pending"
            INTEGRATION_READINESS="partial-stub"
            REQUIRES_RUNTIME_EVIDENCE=true
            EXPECTED_RUNTIME_SURFACE="recorded-hero-stub"
            EXPECTED_RUNTIME_PAGE_COUNT=1
            EXPECTED_RUNTIME_PAGE_INDEX=0
            EXPECTED_RUNTIME_PAGE_ID="70000000-0000-0000-0000-000000000011"
            EXPECTED_RUNTIME_HERO_STATUS="Selection ready"
            ;;
        *)
            return 1
            ;;
    esac
    EXPECTED_RUNTIME_PAGE_COUNT="${EXPECTED_RUNTIME_PAGE_COUNT:-$EXPECTED_PAGE_COUNT}"
    EXPECTED_RUNTIME_PAGE_INDEX="${EXPECTED_RUNTIME_PAGE_INDEX:-$EXPECTED_PAGE_INDEX}"
    EXPECTED_RUNTIME_PAGE_ID="${EXPECTED_RUNTIME_PAGE_ID:-$EXPECTED_PAGE_ID}"
}

SCENARIO="blank-canvas"
scenario_set=0
while (($#)); do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        --*)
            echo "FAIL: unknown option '$1'" >&2
            exit 2
            ;;
        *)
            [[ $scenario_set -eq 0 ]] || { echo "FAIL: only one scenario may be supplied" >&2; exit 2; }
            SCENARIO="$1"
            scenario_set=1
            shift
            ;;
    esac
done

mkdir -p "$ROOT/tmp"
set +e
DEVICE_ID="$(python3 "$DEVICE_SESSION_TOOL" resolve 2>"$ROOT/tmp/device-session-error.log")"
session_exit=$?
set -e
if [[ $session_exit -ne 0 || -z "$DEVICE_ID" ]]; then
    echo "FAIL: no valid physical-iPad session; run DeveloperTools/device-preflight.sh --device <device-id>" >&2
    [[ ! -s "$ROOT/tmp/device-session-error.log" ]] || tail -n 5 "$ROOT/tmp/device-session-error.log" >&2
    exit 2
fi

if ! scenario_metadata "$SCENARIO"; then
    echo "FAIL: unknown or not-yet-runnable scenario '$SCENARIO'" >&2
    echo "Run DeveloperTools/verify-scenario.sh --help for the M0 allowlist." >&2
    exit 2
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
ARTIFACT_DIR="$ROOT/tmp/verify/${STAMP}-${SCENARIO}"
mkdir -p "$ARTIFACT_DIR"
cp "$ROOT/.tubernotes-device-session.json" "$ARTIFACT_DIR/device-session.json"

BUILD_LOG="$ARTIFACT_DIR/build.log"
INSTALL_LOG="$ARTIFACT_DIR/install.log"
LAUNCH_LOG="$ARTIFACT_DIR/launch.log"
CONSOLE_LOG="$ARTIFACT_DIR/console.log"
CONSOLE_ERRORS="$ARTIFACT_DIR/console-errors.txt"
SCREENSHOT_LOG="$ARTIFACT_DIR/screenshot.log"
SCREENSHOT_INFO="$ARTIFACT_DIR/screenshot-info.txt"
SCENARIO_SELECTION="$ARTIFACT_DIR/scenario-selection.json"
SCENARIO_ASSERTIONS="$ARTIFACT_DIR/scenario-assertions.txt"
RUNTIME_EVIDENCE="$ARTIFACT_DIR/runtime-rendered.json"
RUNTIME_ASSERTIONS="$ARTIFACT_DIR/runtime-assertions.txt"
SELECTION_CROP="$ARTIFACT_DIR/lasso-selection-crop.png"
SELECTION_CROP_ASSERTIONS="$ARTIFACT_DIR/selection-crop-assertions.txt"
CRASH_HITS="$ARTIFACT_DIR/crash-hits.txt"
SUMMARY="$ARTIFACT_DIR/summary.txt"

pass=1
build_status="skipped"
launch_status="unknown"
screenshot_status="not-captured-physical-device"
scenario_marker_status="not-captured"
crash_status="not-collected-physical-device"
console_status="not-collected-physical-device"
runtime_evidence_status="not-captured"
selection_crop_status="not-required"

note() {
    printf '%s\n' "$*" | tee -a "$SUMMARY"
}

note "TuberNotes verify-scenario"
note "scenario: $SCENARIO"
note "fixture_family: $FAMILY"
note "expected_state: $EXPECTED_STATE"
note "integration_readiness: $INTEGRATION_READINESS"
note "physical_device: $DEVICE_ID"
note "artifacts: $ARTIFACT_DIR"
note "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
note ""

if [[ "$SKIP_BUILD" != "1" ]]; then
    set +e
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination "platform=iOS,id=$DEVICE_ID" \
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

set +e
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >"$INSTALL_LOG" 2>&1
install_exit=$?
set -e
if [[ $install_exit -ne 0 ]]; then
    note "INSTALL: FAIL (exit $install_exit)"
    note "install_log: $INSTALL_LOG"
    tail -n 40 "$INSTALL_LOG" | tee -a "$SUMMARY"
    note "RESULT: FAIL"
    note "artifact_dir: $ARTIFACT_DIR"
    exit 1
fi
note "INSTALL: pass"

set +e
launch_environment="{\"TUBER_SCENARIO\":\"$SCENARIO\",\"TUBER_VERIFY_NONCE\":\"$VERIFY_NONCE\"}"
xcrun devicectl device process launch \
    --device "$DEVICE_ID" \
    --terminate-existing \
    --environment-variables "$launch_environment" \
    "$BUNDLE_ID" \
    >"$LAUNCH_LOG" 2>&1
launch_exit=$?
set -e

if [[ $launch_exit -eq 0 ]]; then
    launch_status="pass"
else
    launch_status="fail"
    pass=0
fi

note "INSTALL_LOG: $INSTALL_LOG"
note "LAUNCH: $launch_status"
note "launch_log: $LAUNCH_LOG"

sleep 3
printf '%s\n' "Physical-device screenshot capture is outside this script; inspect in TuberNotes and record it separately." >"$SCREENSHOT_LOG"
printf '%s\n' "not captured" >"$SCREENSHOT_INFO"

note "SCREENSHOT: $screenshot_status"
note "screenshot: not collected"
note "screenshot_info: $SCREENSHOT_INFO"

pull_device_file() {
    local relative_source="$1"
    local destination="$2"
    local pull_log="$3"
    local expected_nonce="$4"
    local attempt
    for attempt in $(seq 1 10); do
        rm -f -- "$destination"
        if xcrun devicectl device copy from \
            --device "$DEVICE_ID" \
            --domain-type appDataContainer \
            --domain-identifier "$BUNDLE_ID" \
            --source "$relative_source" \
            --destination "$destination" >"$pull_log" 2>&1 \
            && [[ -s "$destination" ]]; then
            if python3 - "$destination" "$expected_nonce" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
raise SystemExit(0 if payload.get("verificationNonce") == sys.argv[2] else 1)
PY
            then
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

pull_device_artifact() {
    local relative_source="$1"
    local destination="$2"
    local pull_log="$3"
    local attempt
    for attempt in $(seq 1 10); do
        rm -f -- "$destination"
        if xcrun devicectl device copy from \
            --device "$DEVICE_ID" \
            --domain-type appDataContainer \
            --domain-identifier "$BUNDLE_ID" \
            --source "$relative_source" \
            --destination "$destination" >"$pull_log" 2>&1 \
            && [[ -s "$destination" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

if pull_device_file "Documents/developer-evidence/scenario-selection.json" "$SCENARIO_SELECTION" "$ARTIFACT_DIR/scenario-pull.log" "$VERIFY_NONCE"; then
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
    if pull_device_file "Documents/developer-evidence/runtime-rendered.json" "$RUNTIME_EVIDENCE" "$ARTIFACT_DIR/runtime-pull.log" "$VERIFY_NONCE"; then
        set +e
        python3 - "$RUNTIME_EVIDENCE" "$SCENARIO" "$EXPECTED_RUNTIME_SURFACE" \
            "$EXPECTED_RUNTIME_PAGE_COUNT" "$EXPECTED_RUNTIME_PAGE_INDEX" "$EXPECTED_RUNTIME_PAGE_ID" \
            "$EXPECTED_RUNTIME_PEN_FIXTURE" "$EXPECTED_RUNTIME_ANNOTATION_IDS" \
            "$EXPECTED_RUNTIME_HERO_STATUS" "$VERIFY_NONCE" "$REQUIRES_SELECTION_CROP" \
            >"$RUNTIME_ASSERTIONS" 2>&1 <<'PY'
import json
import sys

(
    evidence_path, scenario, surface, page_count, page_index, page_id,
    pen_fixture, annotation_ids, hero_status, verification_nonce,
) = sys.argv[1:11]
requires_selection_crop = len(sys.argv) > 11 and sys.argv[11] == "true"
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

if requires_selection_crop:
    selection_expectations = {
        "selectionCropPath": "Documents/developer-evidence/lasso-selection-crop.png",
        "selectionCropMediaType": "image/png",
        "selectionPathPointCount": 5,
    }
    for key, expected_value in selection_expectations.items():
        observed = evidence.get(key)
        if observed != expected_value:
            failures.append(f"{key}: expected={expected_value!r} observed={observed!r}")
    for key in ("selectionCropPixelWidth", "selectionCropPixelHeight"):
        observed = evidence.get(key)
        if not isinstance(observed, int) or observed <= 0:
            failures.append(f"{key}: expected=positive-int observed={observed!r}")
    selection_id = evidence.get("selectionID")
    if not isinstance(selection_id, str) or not selection_id:
        failures.append(f"selectionID: expected=non-empty-string observed={selection_id!r}")

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

if [[ "$REQUIRES_SELECTION_CROP" == "true" ]]; then
    if pull_device_artifact \
        "Documents/developer-evidence/lasso-selection-crop.png" \
        "$SELECTION_CROP" "$ARTIFACT_DIR/selection-crop-pull.log"; then
        set +e
        python3 - "$SELECTION_CROP" "$RUNTIME_EVIDENCE" >"$SELECTION_CROP_ASSERTIONS" 2>&1 <<'PY'
import json
import struct
import sys

crop_path, runtime_path = sys.argv[1:]
with open(crop_path, "rb") as crop_file:
    header = crop_file.read(24)
if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
    print("selection crop is not a valid PNG header")
    raise SystemExit(1)
width, height = struct.unpack(">II", header[16:24])
with open(runtime_path, encoding="utf-8") as runtime_file:
    runtime = json.load(runtime_file)
expected = (runtime.get("selectionCropPixelWidth"), runtime.get("selectionCropPixelHeight"))
if (width, height) != expected:
    print(f"selection crop dimensions expected={expected!r} observed={(width, height)!r}")
    raise SystemExit(1)
print(f"selection crop PNG assertions passed width={width} height={height}")
PY
        crop_assert_exit=$?
        set -e
        if [[ $crop_assert_exit -eq 0 ]]; then
            selection_crop_status="pass"
        else
            selection_crop_status="fail-crop-assertions"
            pass=0
        fi
    else
        selection_crop_status="fail-missing"
        printf '%s\n' "selection crop missing from app data container" >"$SELECTION_CROP_ASSERTIONS"
        pass=0
    fi
fi

printf '%s\n' "Not collected by the physical-device verifier; report a separate attached console session if used." >"$CONSOLE_LOG"
: >"$CONSOLE_ERRORS"
printf '%s\n' "Not collected by the physical-device verifier; report device diagnostics separately if inspected." >"$CRASH_HITS"

note "CONSOLE: $console_status"
note "console_log: $CONSOLE_LOG"
note "console_errors: $CONSOLE_ERRORS"
note "SCENARIO_MARKER: $scenario_marker_status"
note "scenario_selection: $SCENARIO_SELECTION"
note "scenario_assertions: $SCENARIO_ASSERTIONS"
note "RUNTIME_EVIDENCE: $runtime_evidence_status"
note "runtime_rendered: $RUNTIME_EVIDENCE"
note "runtime_assertions: $RUNTIME_ASSERTIONS"
note "SELECTION_CROP: $selection_crop_status"
if [[ "$REQUIRES_SELECTION_CROP" == "true" ]]; then
    note "selection_crop: $SELECTION_CROP"
    note "selection_crop_assertions: $SELECTION_CROP_ASSERTIONS"
fi
note "CRASH_STATUS: $crash_status"
note "crash_hits: $CRASH_HITS"

if [[ "$FORCE_MECHANICAL_FAILURE" == "1" ]]; then
    printf '%s\n' "intentional expected=stable-anchor observed=offset-by-3pt" >"$ARTIFACT_DIR/intentional-failure.txt"
    note "MECHANICAL_ASSERTION: FAIL (intentional isolated failure requested)"
    note "intentional_failure: $ARTIFACT_DIR/intentional-failure.txt"
    pass=0
fi

if [[ $pass -eq 1 ]]; then
    note "MECHANICAL_ASSERTION: PASS (physical-device build/install/launch, fixture declaration, and required runtime-rendered evidence)"
else
    note "MECHANICAL_ASSERTION: FAIL (one or more required mechanical checks failed or were incomplete)"
fi

if [[ "$INTEGRATION_READINESS" == "partial-stub" ]]; then
    note "UI_EXPECTED_STATE: PARTIAL/STUB; genuine lasso capture and crop are not implemented"
elif [[ "$INTEGRATION_READINESS" == "ready-for-app-wiring" ]]; then
    note "UI_EXPECTED_STATE: PENDING coordinator App wiring; this result does not accept the described UI state"
else
    note "UI_EXPECTED_STATE: requires inspection on the physical iPad; verifier does not capture or judge the visible frame"
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
