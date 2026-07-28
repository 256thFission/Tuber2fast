#!/bin/bash
# Gate 20 — regenerate the Xcode project from project.yml.
#
# The project file is a build artifact. Regenerating on every run guarantees
# that what is compiled is what project.yml describes, and that nobody's local
# Xcode edits silently became load-bearing.

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
cd "$REPO_ROOT" || exit 1

command -v xcodegen >/dev/null 2>&1 || { fail "xcodegen not installed (brew install xcodegen)"; exit 1; }

rm -rf "$PROJECT"
if ! out="$(xcodegen generate 2>&1)"; then
  printf '%s\n' "$out" >&2
  exit 1
fi
pass "project regenerated from project.yml"

# The scheme the later gates drive must actually exist.
if xcodebuild -project "$PROJECT" -list 2>/dev/null | grep -q "^        $SCHEME$"; then
  pass "scheme '$SCHEME' present"
else
  fail "scheme '$SCHEME' missing from the generated project"
  exit 1
fi
