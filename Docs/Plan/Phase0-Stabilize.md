# P0 — Stabilize the tree

Status: in-progress — mechanically accepted; overnight branch archival blocked by uncommitted linked-worktree edits
Owner: coordinator (Phillip + one session; not parallelizable, not subagent work)
Estimated: ~½ day

## Objective

Turn the mixed working tree into a clean base so the five work lines can branch
independently.

## Steps

1. **Secret scan first.** Scan the uncommitted live-spike files
   (`TuberNotes/AgentHarness/DebugCodex*`, `ResponsesSSEDecoder.swift`,
   `DeveloperTools/CodexAdapterTests/`, `DeveloperTools/OpenCodeAuthReproduction/`,
   `DeveloperTools/connect-feedback-codex.sh`) for tokens, auth codes, PKCE
   verifiers, cookies, account IDs, or raw auth responses. Synthetic fixtures
   must be unmistakably fake. Nothing derived from `~/.codex/auth.json` or any
   other app's credentials may be present (SPEC §10.1).
2. **Commit tooling churn** (skills, PencilFixtureMCP, verify-scenario,
   device-preflight/device_session, wake bridge, reset script, tests, Docs
   churn) as its own commit on `codex-tenative-m0`.
3. **Commit the live spike** as a separate commit so WL-D has a clean base and
   M1 history stays legible.
4. **Commit the doc consolidation** (deleted handoffs, `Docs/Plan/`).
5. **Fix `.gitignore`:** ensure `DerivedData*/`, `__pycache__/`, `tmp/`,
   `.tubernotes-device-session.json`, `.feedback-threads/`, `.pencil-fixtures/`
   runtime state are covered. Never commit them.
6. **Branch hygiene:** merge or fast-forward `codex-tenative-m0` → `main`
   (M0 is human-accepted). Archive/delete `codex/feedback-threads-overnight`
   if fully landed. Branch each work line from `main`.

## Acceptance evidence

- `git status` clean on `main`.
- Canonical Debug build passes.
- All currently-runnable scenarios PASS via `DeveloperTools/verify-scenario.sh`
  per `Docs/DeviceWorkflow.md`.
- Secret-scan result recorded in the session log below.

## Stop conditions

- Any credential-like material found in the spike → stop, do not commit,
  report to Phillip.
- Merge conflict with concurrent sessions → stop and reconcile with Phillip
  (another session was observed editing Docs on July 19).

## Session log

- 2026-07-19 — Secret scan passed for all named live-spike sources and harnesses;
  no credential-like material was found. Created separate commits for tooling
  (`6b7bac4`) and the DEBUG live spike (`3d36ab5`); doc consolidation remains
  isolated in `2a1adf5`. Fast-forwarded `main`, created the five work-line
  branches, and verified all ten declared scenarios on physical iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Build and scenario evidence is under
  `tmp/verify/20260719-140420-blank-canvas/` through
  `tmp/verify/20260719-140524-hero-recorded/`. Remaining blocker: linked
  worktree `/Users/phil/Documents/Build_Week/TuberNotes-feedback-threads-overnight`
  has uncommitted edits, so `codex/feedback-threads-overnight` was not archived
  or deleted. No physical screenshot, attached console, crash diagnostics, or
  human visual/Pencil verdict was collected.
