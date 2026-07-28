#!/bin/bash
# Gate 10 — structural contract checks.
#
# These are cheap, deterministic, and run before anything is compiled. They
# encode the parts of Docs/Architecture/DataContract.md that are decidable by
# reading source text. Every check fails closed: a new file that violates a rule
# breaks the gate without anyone remembering to update an allowlist.

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
FAILED=0
cd "$REPO_ROOT" || exit 1

# Source with line comments stripped.
#
# These checks match source text, and prose is source text: a comment reading
# "fputs, not FileHandle.write(to:)" failed the file-I/O check on a file that
# performs no file I/O. A gate that fails on a sentence describing the rule it
# enforces teaches people to stop writing comments, so the checks below read
# code only. Block comments are not stripped; no check has collided with one.
code_only() { sed 's|//.*||' "$1"; }

# --- 1. No inherited implementation (AGENTS.md: no inherited implementation) -
# Content-hash comparison against the sibling worktree. This proves no file was
# copied without reading, interpreting, or depending on the other branch.
SIBLING="$REPO_ROOT/../TuberNotes"
if [ -d "$SIBLING" ]; then
  sibling_hashes="$(find "$SIBLING" -name '*.swift' -type f \
    -not -path '*/DerivedData*/*' -not -path '*/.git/*' \
    -exec shasum -a 256 {} + 2>/dev/null | awk '{print $1}' | sort -u)"
  copied=0
  while IFS= read -r f; do
    h="$(shasum -a 256 "$f" | awk '{print $1}')"
    if grep -qx "$h" <<<"$sibling_hashes"; then
      fail "inherited file (identical to a file in the sibling worktree): $f"
      copied=1
    fi
  done < <(swift_sources)
  [ "$copied" -eq 0 ] && pass "no source file is byte-identical to the prior implementation"
else
  log "sibling worktree absent; inheritance check not applicable"
fi

# --- 2. Exactly one owner may import the live UI frameworks ------------------
# DataContract §2/§3: PageCanvasController is the only owner that imports and
# operates the live PencilKit view; durable value types import Foundation only.
violation=0
while IFS= read -r f; do
  if grep -qE '^import (PencilKit|UIKit)$' "$f"; then
    if ! is_allowed "$f" "${UIKIT_ALLOWED_FILES[@]}"; then
      fail "imports PencilKit/UIKit but is not the canvas owner: $f"
      violation=1
    fi
  fi
done < <(app_swift_sources)
[ "$violation" -eq 0 ] && pass "PencilKit/UIKit confined to the declared canvas owner"

# --- 3. No custom protocols (DataContract §3) --------------------------------
if hits="$(grep -rnE '^[[:space:]]*(public |internal |private |fileprivate )?protocol [A-Z]' "$APP_SOURCES" 2>/dev/null)"; then
  fail "custom protocol declared; Just a Canvas requires none:"
  printf '%s\n' "$hits" | sed 's/^/      /' >&2
else
  pass "no custom Swift protocols"
fi

# --- 4. Forbidden patterns (DataContract §10) --------------------------------
# Each entry is: <extended regex>::<why it is forbidden>. The separator is '::'
# and not '|' because '|' is alternation inside the patterns themselves.
# `Coordinator` is deliberately absent: UIViewRepresentable.makeCoordinator is
# idiomatic SwiftUI, not the coordinator abstraction the contract forbids.
FORBIDDEN=(
  'import Combine::Combine publishing of interaction state'
  '@Published::observation of state that must not be mirrored'
  'ObservableObject::observation of state that must not be mirrored'
  '(Passthrough|CurrentValue)Subject::event stream'
  '(class|struct|enum) [A-Za-z]*Repository::repository abstraction'
  '(class|struct|enum) [A-Za-z]*(Reducer|ServiceContainer|EventBus)::reducer/container abstraction'
  'NotificationCenter\.default\.post::document event bus'
)
violation=0
for entry in "${FORBIDDEN[@]}"; do
  pattern="${entry%%::*}"; why="${entry##*::}"
  while IFS= read -r f; do
    if hits="$(code_only "$f" | grep -nE "$pattern")"; then
      fail "forbidden pattern ($why) in $f:"
      printf '%s\n' "$hits" | sed 's/^/      /' >&2
      violation=1
    fi
  done < <(app_swift_sources)
done
[ "$violation" -eq 0 ] && pass "no forbidden pattern from DataContract §10"

# --- 5. File I/O confined to the store ---------------------------------------
violation=0
while IFS= read -r f; do
  if code_only "$f" | grep -qE '(Data\(contentsOf|String\(contentsOf|\.write\(to:|FileManager\.default\.(create|remove|replace|copy|move))'; then
    if ! is_allowed "$f" "${FILE_IO_ALLOWED_FILES[@]}"; then
      fail "file I/O outside the document store: $f"
      violation=1
    fi
  fi
done < <(app_swift_sources)
[ "$violation" -eq 0 ] && pass "file I/O confined to the document store"

# --- 6. At most one live canvas view (DataContract §9) -----------------------
count="$(grep -rc 'PKCanvasView(' "$APP_SOURCES" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"
if [ "$count" -gt 1 ]; then
  fail "$count PKCanvasView instantiations; exactly one live canvas is permitted"
else
  pass "PKCanvasView instantiation sites: $count (limit 1)"
fi

# --- 7. The project file is generated, never committed -----------------------
if git ls-files --error-unmatch '*.xcodeproj/project.pbxproj' >/dev/null 2>&1; then
  fail "a .xcodeproj is tracked in git; project.yml is the only project source"
else
  pass "project.yml is the sole project source"
fi

exit "$FAILED"
