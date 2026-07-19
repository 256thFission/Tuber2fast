#!/usr/bin/env bash
# Validate and pin the one physical iPad used by all TuberNotes developer tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec python3 "$ROOT/DeveloperTools/device_session.py" start "$@"
