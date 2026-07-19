#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PARENT="$REPO_ROOT/tmp/verify"
mkdir -p "$ARTIFACT_PARENT"
ARTIFACT_DIR="$(mktemp -d "$ARTIFACT_PARENT/opencode-auth-reproduction.XXXXXX")"
TEST_LOG="$ARTIFACT_DIR/tests.log"
SCAN_LOG="$ARTIFACT_DIR/secret-scan.log"

export PYTHONDONTWRITEBYTECODE=1

python3 -B -m unittest discover \
  -s "$SCRIPT_DIR/tests" \
  -p 'test_*.py' 2>&1 | tee "$TEST_LOG"

python3 -B "$SCRIPT_DIR/scan_secrets.py" \
  --source "$SCRIPT_DIR" \
  --artifact "$TEST_LOG" 2>&1 | tee "$SCAN_LOG"

# Include the scanner's own output in a final artifact-tree pass.
python3 -B "$SCRIPT_DIR/scan_secrets.py" \
  --source "$SCRIPT_DIR" \
  --artifact "$ARTIFACT_DIR"

printf 'OPENCODE_AUTH_REPRODUCTION_CHECKS: PASS\n'
printf 'ARTIFACT_DIR: %s\n' "$ARTIFACT_DIR"
