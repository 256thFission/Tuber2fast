#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUTPUT="${TMPDIR:-/tmp}/tubernotes-codex-adapter-checks"

cd "$ROOT"
xcrun swiftc -D DEBUG -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  TuberNotes/App/Contracts/SpatialContracts.swift \
  TuberNotes/App/Contracts/DocumentContracts.swift \
  TuberNotes/App/Contracts/PinContracts.swift \
  TuberNotes/App/Contracts/KnowledgeContracts.swift \
  TuberNotes/App/Contracts/InteractionContracts.swift \
  TuberNotes/App/Contracts/AgentContracts.swift \
  TuberNotes/AgentHarness/AgentClient.swift \
  TuberNotes/AgentHarness/ResponsesSSEDecoder.swift \
  TuberNotes/AgentHarness/DebugCodexTransport.swift \
  TuberNotes/AgentHarness/DebugCodexAgentClient.swift \
  DeveloperTools/CodexAdapterTests/main.swift \
  -o "$OUTPUT"
"$OUTPUT"
