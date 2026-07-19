#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
socket_path="$repo_root/.feedback-threads/codex-app-server.sock"
codex_bin=${TUBER_CODEX_BIN:-/Applications/ChatGPT.app/Contents/Resources/codex}

if [[ ! -x "$codex_bin" ]]; then
  codex_bin=$(command -v codex || true)
fi
if [[ -z "$codex_bin" || ! -x "$codex_bin" ]]; then
  echo "No Codex CLI found. Set TUBER_CODEX_BIN to its absolute path." >&2
  exit 1
fi
if [[ ! -S "$socket_path" ]]; then
  echo "The TuberNotes feedback app-server is not running. Arm a feedback wake first." >&2
  exit 1
fi

if [[ $# -gt 0 ]]; then
  exec "$codex_bin" --remote "unix://$socket_path" resume "$1"
fi
exec "$codex_bin" --remote "unix://$socket_path"
