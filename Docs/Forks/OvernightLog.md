# Overnight log — CanvasFeatureComplete grind

Written by the agent while Phillip sleeps. Every decision taken without him,
every discovery, and every item that needs him in the morning. Newest entries
appended at the bottom of each section. Branch: `canvas-feature-complete`
(off `postoai`).

## Done and green before the grind started (evening, with Phillip)

- **Phase 1 — ink becomes a layer**: `3a1a627`, reviewed
  (approve-with-nits), review fixes in `dee6044` (refused-save guard reads
  disk not memory; duplicate-layerID invariant; corrupt-legacy tests;
  suite converted to Swift Testing). 77 tests green.
- **CONTRACT: amendment** `f6522bd` — Phillip authorized the Owners golden
  rule 5 generalization and the Durable form layer-envelope block. Already
  in `Docs/Contract.md`; the parallel contract below builds on top of it.
- **Spike 1 scaffolding** `f78a050` — mirror-fidelity spike behind
  `TN_SPIKE_MIRROR`, variants A (sibling) and B (inside-PKCanvasView).
  Green with flag off, builds with flag on.
- Both merged into `canvas-feature-complete` at `277786b`.

## Decisions taken overnight

(Each entry: what was decided, why, and where it landed.)

## Discoveries

(Anything learned that the docs didn't predict.)

## Morning items — Phillip must address

1. **Device spike 1 protocol** — run the mirror-fidelity checklist on the
   iPad (see the spike agent's protocol: pinch/fling/rubber-band against
   the fiducials with variant A; one stroke with variant B). Phases 2+
   rendering built on the presumed sibling answer; if the device
   contradicts it, the rendering scaffold needs revisiting.
2. **Device evidence for phase 1** — touches editor session + durable
   form; PR-template device pass still owed.
3. **`Docs/Contract.proposed.md`** — the parallel contract. Review, edit,
   adopt what you accept (each section notes which phase required it).
4. (appended as they arise)
