# WL-D — Live provider adapter [STRETCH — hard-gated]

Status: not-started
Owner subsystem: `AgentHarness` only
Depends on: P0. Runs last; demo-optional.
Subagent-eligible: yes, with the security boundary below restated verbatim in
the task prompt.

## Objective

Consolidate the retained spike — `DebugCodexTransport.swift`,
`ResponsesSSEDecoder.swift`, `DebugCodexAgentClient.swift`,
`DeveloperTools/CodexAdapterTests/`, and the
`DeveloperTools/OpenCodeAuthReproduction/` findings — into one DEBUG-only
direct adapter behind the `AgentClient` protocol, selected exactly as today via
`TUBER_AGENT_MODE=codex` + locally supplied configuration
(`DebugCodexConfiguration.processEnvironment()`). Recorded remains the default
everywhere.

## Security boundary (absorbed from the deleted OpenCode auth handoff; SPEC §10.1)

- No distributable app may contain a reusable provider secret. A hackathon
  credential is supplied locally, DEBUG-only, never committed, logged, placed
  in fixtures, Info.plist, frozen contracts, or compiled into Release.
- ChatGPT/Codex OAuth is **not** an implementation assumption; reproduction
  work is research evidence, not production auth architecture approval.
- Never inspect, copy, transform, or reuse credentials from
  `~/.codex/auth.json`, `~/.local/share/opencode/auth.json`, Keychain, browser
  storage, environment dumps, or another application.
- Never commit tokens, authorization codes, refresh tokens, PKCE verifiers,
  cookies, account identifiers, callback query strings, raw auth responses, or
  request headers. Synthetic fixtures must be unmistakably fake.
- No automated interactive browser login; no live provider smoke test without
  explicit human authorization at the point account access is needed.
- Diagnostic output redacts authorization values and user content **by
  construction**, not by convention.
- Importing/adapting upstream OpenCode source requires a separate
  license/attribution and architecture review; prefer behavior-level
  reproduction with small original code.

## Files in scope

- `TuberNotes/AgentHarness/*`
- `DeveloperTools/CodexAdapterTests/*`

Forbidden: WL-A/B/C files, Release configuration, frozen contracts,
`RecordedHeroView`/hero scenarios (WL-B owns those surfaces).

## Acceptance evidence (M2 gate, SPEC §16)

- All recorded cases still pass; strict `place_pins` schema validation;
  invalid coordinates rejected.
- Secret scan of the full diff and all artifacts.
- One human-authorized live smoke run producing ≥1 valid, semantically
  relevant PinDraft, with redacted logs retained as the artifact.
- Provider failure surfaces as a recoverable `AgentFailure`.

## Demo gate

The live path may appear in the demo **only** after three consecutive
successful live hero runs on the pinned demo iPad. Otherwise it stays a
backstage flex and the recorded client presents.

## Stop conditions

- Smoke test passes → stop.
- Auth requires an external decision (gateway, provider choice — SPEC
  "explicitly unresolved") → stop, escalate.
- Demo-critical lines (WL-A/B/C/E) need the week's attention → park this line.

## Session log

- (none yet)
