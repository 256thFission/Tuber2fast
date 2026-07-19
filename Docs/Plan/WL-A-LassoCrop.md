# WL-A — Genuine Magic Lasso capture and crop

Status: complete — physical-device verifier PASS 2026-07-19
Owner subsystem: `SpatialCanvas` (SPEC §14 WP1)
Depends on: P0. Blocks WL-B step 3.
Subagent-eligible: yes (single subsystem, concrete return contract).

## Objective

Implement the real lasso input path that the hero demo needs:

- explicit lasso tool mode on the spatial surface (SPEC §5.1 `CanvasToolMode`);
- Pencil path capture with near-closed auto-completion and degenerate-path
  rejection (SPEC §5.2);
- selection glow/lift rendering with optional outside-dim (SPEC §5.3);
- crop compositing of the visible PDF background **plus** page ink into a
  `SelectionArtifact` with a PNG `SelectionCrop`, using the frozen
  `SpatialContracts` / `InteractionContracts` types and
  `SpatialCoordinateTransform` seam only.

## Files in scope

- `TuberNotes/SpatialCanvas/*` (new files allowed inside this directory)
- `TuberNotes/DeveloperSupport/DevelopmentScenario.swift` — upgrade the
  `lasso-crop` fixture from `later-milestone` to a deterministic canned lasso
  path over the M0Demo PDF page with canned ink, readiness `app-wired` when the
  surface renders it.
- `TuberNotes/App/RootView.swift` — only the minimal branch to render the
  `lasso-crop` scenario; no investigation UI (that is WL-B).

## Non-goals

- Action strip, intents, agent calls (WL-B)
- Pin visual design (Pins owns it)
- Coordinate math outside the frozen transform seam
- OCR, document library, contract changes

## Acceptance evidence

- `lasso-crop` scenario PASS with rendered runtime evidence: verifier shows the
  selection rendered and an inspectable crop PNG artifact containing visible
  PDF **and** ink pixels, retained under the scenario artifact directory.
- Crop-to-page round-trip checks for the canned path (page-normalized →
  crop-relative → page-normalized within tolerance).
- Degenerate path (no meaningful area) rejected without corrupting page state.
- Ordinary ink mode still creates ink and never invokes selection (SPEC §5.1).
- Evidence Packet per `Docs/templates/EvidencePacket.md`.

## Human review (queued, non-blocking)

Lasso feel with a real Pencil stroke via `human-device-loop` +
`request_pen_fixture`. One stroke request, then separately one feel verdict.

## Stop conditions

- Crop artifact mechanically accepted → stop, hand to WL-B.
- A frozen-contract change appears necessary → stop, escalate.
- Two verification failures without a narrower fix → stop, report evidence.

## Session log

- 2026-07-19 — Implemented Pencil-only Magic Lasso capture in `SpatialCanvas`
  with near-close completion, far-open and degenerate rejection, selection
  glow/outside dimming, and PDF + page-ink PNG compositing into the frozen
  `SelectionArtifact` contract. Added the app-wired deterministic `lasso-crop`
  fixture and minimal RootView branch. No frozen contracts changed.
- 2026-07-19 — Local simulator build passed. Deterministic geometry diagnostics
  passed for near-close, far-open, degenerate area, and crop-to-page round-trip
  (`<= 1e-6`). Simulator crop inspection confirmed PDF and ink pixels. An
  `ink-pages` launch emitted no selection artifact or crop.
- 2026-07-19 — Exact physical iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117` preflight passed. `lasso-crop`
  final verifier PASS artifacts:
  `tmp/verify/20260719-145756-lasso-crop/`; retained crop
  `lasso-selection-crop.png` is a validated 578×556 PNG containing visible PDF
  ruled content and black PencilKit ink. `ink-pages` verifier PASS artifacts:
  `tmp/verify/20260719-145712-ink-pages/`; runtime evidence has canned ink and
  null selection fields.
- Scope note: the coordinator explicitly authorized the smallest
  acceptance-support exception in `DeveloperTools/verify-scenario.sh` so the
  child requirement could produce a real nonce-matched lasso/crop verifier
  PASS. `TuberNotes.xcodeproj/project.pbxproj` changed only to register the new
  in-scope `SpatialCanvas/MagicLasso.swift` source file. Final diff otherwise
  stayed within the child file list. Physical screenshots, attached console,
  crash diagnostics, and human Pencil feel/visual-taste verdict were not
  collected; Pencil feel remains queued and non-blocking per this work-line.
