#!/bin/bash
# Shared configuration and helpers for the TuberNotes gate harness.
#
# Exit-code convention used by every gate script:
#   0  PASS  — the gate ran and the contract held
#   2  SKIP  — the gate could not run (missing hardware); never counts as PASS
#   *  FAIL  — the contract was violated, or the gate itself broke

set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

PROJECT="$REPO_ROOT/TuberNotes.xcodeproj"
SCHEME="TuberNotes"
APP_NAME="TuberNotes"
BUNDLE_ID="com.tubernotes.greenfield"
DERIVED_DATA="$REPO_ROOT/DerivedData"
ARTIFACTS="$REPO_ROOT/Artifacts"

# The pinned simulator. Fixed on purpose: a moving destination makes results
# incomparable between sessions.
SIM_NAME="${TN_SIM_NAME:-iPad Pro 11-inch (M5)}"

# The named physical iPad from the milestone's device gates.
DEVICE_NAME="${TN_DEVICE_NAME:-Phillip’s iPad}"

# Sources that are allowed to touch live UI frameworks. PageCanvasController
# operates PencilKit/UIKit canvas state. EditorLifecycle uses UIApplication only
# for a bounded background save lease. Adding a file here is an ownership
# decision, not a convenience.
UIKIT_ALLOWED_FILES=(
  "TuberNotesApp/EditorLifecycle.swift"
  "TuberNotesApp/PageCanvasController.swift"
)

# Sources allowed to perform file I/O. Empty until G3 introduces DocumentStore.
FILE_IO_ALLOWED_FILES=(
  "TuberNotesApp/DocumentStore.swift"
)

APP_SOURCES="$REPO_ROOT/TuberNotesApp"

log()  { printf '  %s\n' "$*"; }
pass() { printf '  ✓ %s\n' "$*"; }
fail() { printf '  ✗ %s\n' "$*" >&2; FAILED=1; }
skip() { printf '  ⊘ SKIP: %s\n' "$*" >&2; }

# Every Swift source in the repo, relative to the repo root.
swift_sources() {
  cd "$REPO_ROOT" || return 1
  find TuberNotesApp TuberNotesTests -name '*.swift' -type f 2>/dev/null | sort
}

# App sources only. Ownership rules constrain the app; a test may import
# PencilKit precisely so it can verify what the app's one canvas owner does.
app_swift_sources() {
  cd "$REPO_ROOT" || return 1
  find TuberNotesApp -name '*.swift' -type f 2>/dev/null | sort
}

is_allowed() {
  local needle="$1"; shift
  local candidate
  for candidate in "$@"; do
    [ "$candidate" = "$needle" ] && return 0
  done
  return 1
}

mkdir -p "$ARTIFACTS"
