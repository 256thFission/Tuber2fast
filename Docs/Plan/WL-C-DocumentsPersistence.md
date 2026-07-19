# WL-C — Real documents: creation, import, persistence, relaunch

Status: in-progress — implementation merged by direction; notebook acceptance remains blocked by device-service timeouts
Owner subsystem: coordinator `App` + `DeveloperSupport` for fixtures
Depends on: P0. Independent of WL-A/B.
Subagent-eligible: yes, per step (each step is a bounded deliverable).

## Objective

1. **Blank-notebook creation as a user action** — branded dot-grid first page;
   page append already exists in `RootView` and moves behind the same flow.
2. **Basic PDF import through the system picker** — one path, no library UI
   (SPEC §4 Required).
3. **Per-page persistence** of ink (`PKDrawing`), annotations, and
   document/page records sufficient for repeatable demos; relaunch restores
   current document, page, ink, and Pins.

Persistence must respect SPEC §12: page-identity stability; **never** store
screen coordinates; page-normalized spatial data only.

## Pre-approved contract addition

New scenario name `persistence-relaunch` (approved by Phillip via acceptance
of this plan, July 19, 2026): launch, apply a canned drawing + Pin, relaunch,
verify identical page identity, ink reference, and annotation IDs via runtime
evidence. Add to `DevelopmentScenario`, `verify-scenario.sh` (with WL-E), and
SPEC §17 in the same change.

DEBUG scenario launches must keep overriding persisted state so the existing
verifier scenarios remain deterministic.

## Files in scope

- `TuberNotes/App/` (creation/import flows, persistence store wiring)
- A new persistence component — propose location `TuberNotes/App/Persistence/`
  (coordinator-owned; it is integration state, not a new subsystem)
- `TuberNotes/DeveloperSupport/DevelopmentScenario.swift` (new scenario)

## Non-goals

- Document library / folders, iCloud/sync, migrations, reordering pages inside
  imported PDFs, rich PDF annotation compatibility, multi-window.

## Acceptance evidence

- `persistence-relaunch` PASS with rendered runtime evidence.
- Import of an external 3-page PDF renders and turns pages.
- Created notebook survives relaunch with ink and appended pages intact.
- All pre-existing scenarios still PASS (fixture override intact).
- Evidence Packet per template.

## Human review (queued)

Creation and import flow feel; add-page discoverability (see
`Docs/ReviewGuides/DocumentsAndInk.md` packet patterns).

## Stop conditions

- Relaunch restoration mechanically proven → stop.
- Persistence pressures a frozen contract (likely candidate: `inkReference`
  semantics in `DocumentContracts`) → stop and escalate; do not improvise a
  parallel representation.
- Two verification failures without a narrower fix → stop, report.

## Session log

- 2026-07-19 — Implemented the branch-local persistence layer, blank notebook
  creation/append flow, system PDF import, and the pre-approved
  `persistence-relaunch` scenario. Generic iOS Debug build, verifier syntax,
  and diff checks passed. Existing `InkReference.relativePath` semantics were
  sufficient; no frozen contract change or parallel representation was needed.
- 2026-07-19 — `persistence-relaunch` passed on physical iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117` after one narrow fixture-binding fix;
  artifacts: `tmp/verify/20260719-150653-persistence-relaunch/`. Runtime
  evidence proved stable page identity, ink reference, and annotation IDs
  across relaunch.
- 2026-07-19 — Guided import evidence passed: an external PDF was copied into
  app-owned storage, parsed as exactly three pages, and persisted with three
  unique page IDs; page navigation reached persisted page index 2. Artifacts:
  `tmp/wl-c-import-evidence.OJkc9f/` and
  `tmp/wl-c-page-turn-evidence.6DTcXo/`. The Codex event bridge did not resume
  automatically, so replies were collected and acknowledged manually.
- 2026-07-19 — Stopped before final acceptance and commit after repeated
  device/host divergence during notebook creation evidence. Feedback container
  copies timed out; after explicit human authorization, exact-device preflight
  passed wired but reported the app unavailable, and both a non-destructive
  reinstall and read-only installed-app query timed out without results. No
  uninstall, feedback reset, or product-data deletion occurred. Notebook
  create/append/relaunch survival and the final existing-scenario sweep remain
  unproven.
- 2026-07-19 — Phillip explicitly directed the coordinator to merge the
  implementation despite the incomplete notebook evidence. The blocker remains
  open and this status is not upgraded to mechanically accepted.
