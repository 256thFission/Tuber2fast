#!/bin/bash
# Gate 40 — unit tests on the pinned simulator.

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT" || exit 1

LOG="$ARTIFACTS/test.log"
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath "$DERIVED_DATA" \
  >"$LOG" 2>&1
status=$?

if [ "$status" -ne 0 ]; then
  fail "tests failed; failures:"
  grep -E 'error:|failed|Test Case .* failed' "$LOG" | head -30 | sed 's/^/      /' >&2
  exit "$status"
fi

# A green run with zero tests is a false pass. Require evidence tests executed.
if ! grep -qE 'Test run with [0-9]+ test|Executed [0-9]+ test|✔|passed after' "$LOG"; then
  fail "test log shows no executed tests; refusing to count this as a pass"
  exit 1
fi

pass "tests passed (log: Artifacts/test.log)"
