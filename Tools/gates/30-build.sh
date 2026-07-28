#!/bin/bash
# Gate 30 — compile for the pinned simulator.
#
# Warnings are errors in project.yml, so a clean exit here also means no new
# warnings. Compilation is necessary but never behavioral proof (AGENTS.md).

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT" || exit 1

LOG="$ARTIFACTS/build.log"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath "$DERIVED_DATA" \
  >"$LOG" 2>&1
status=$?

if [ "$status" -ne 0 ]; then
  fail "build failed; last 40 lines:"
  tail -40 "$LOG" >&2
  exit "$status"
fi

if grep -qE '^.*: warning: ' "$LOG"; then
  fail "build emitted warnings:"
  grep -E '^.*: warning: ' "$LOG" | sort -u | sed 's/^/      /' >&2
  exit 1
fi

pass "built clean for $SIM_NAME (log: Artifacts/build.log)"
