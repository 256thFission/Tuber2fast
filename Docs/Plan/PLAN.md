# TuberNotes greenfield execution plan

This is the sole coordination document for the `postoai` orphan branch. Work
one line at a time and append a dated session entry before stopping.

## Status board

| Line | Status | Exit |
|---|---|---|
| G0 — Foundational contracts | Complete | Data and Just a Canvas contracts committed on an orphan root |
| G1 — Empty iPad application shell | Pending | New project installs and launches a blank non-editable root on named iPad |
| G2 — Live canvas runtime | Pending | One stable PencilKit runtime draws, erases, pans, zooms, undoes, and redoes |
| G3 — One-file persistence | Pending | Model, direct autosave, atomic replacement, recovery, and lifecycle behavior pass |
| G4 — Performance baseline | Pending | Fixed device trace and measurements recorded; evidence-based budgets proposed |
| G5 — Phillip canvas verdict | Pending | Phillip accepts or returns bounded findings from normal app |

Lines are sequential. G1 must not prebuild G3 abstractions; each line adds only
what its exit requires while conforming to the complete contract.

## Decision log

- 2026-07-21 — Chose an orphan `postoai` history and a separate worktree. The
  prior app remains behavioral reference only; no implementation is inherited.
- 2026-07-21 — Replaced a five-hop layered interpretation with three runtime
  planes: interactive runtime, editor authority, and document authority, with
  presentation and storage/resources attached at explicit boundaries.
- 2026-07-21 — Made page space the durable geometry. Normalized coordinates are
  interchange-only.
- 2026-07-21 — Defined Just a Canvas as a production-shaped one-page vertical
  slice with durability and performance gates, not a UI prototype.
- 2026-07-22 — Clarified three authority boundaries after review: document and
  storage may share one concrete owner; all undo inputs route to exactly one
  active domain; and the drawing-commit responsibility is the sole push path
  from live PencilKit state to storage. The later direct-save simplification
  removed the interim revision and command language.
- 2026-07-22 — Clarified that architectural contracts are documented mutation
  surfaces, not Swift protocols. Just a Canvas uses concrete owners and direct
  APIs; commit bridging and undo routing begin as responsibilities inside
  `EditorSession`, not mandatory helper types.
- 2026-07-22 — Removed undefined rotation and crop placeholders from the current
  durable model. Just a Canvas persists immutable portrait width/height only;
  source-mapping semantics are deferred until a feature actually requires them.
- 2026-07-22 — Removed document commands, events, and durable revision counters
  from Just a Canvas. The editor coalesces with private in-memory generations;
  one concrete async `save` call returns only after atomic persistence.
- 2026-07-22 — Phillip approved a full simplicity pass after independent
  review. The current contracts supersede earlier G0 descriptions where they
  conflict: four concrete owners, two editor save booleans, one change callback,
  one binary property-list file, and one awaited atomic save. All future-only
  authorities and fixed performance guesses were removed.
- 2026-07-29 — Adopted the application implementation from
  `github.com/256thFission/Tuber2fast.git`, which was authored without `Docs/`
  and is therefore the origin of the divergences below. `postoai` was reset onto
  that history and `Docs/` layered back on top.
- 2026-07-29 — Phillip overruled immutable page geometry. The page grows
  downward one whole increment at a time to a bounded maximum; width remains
  immutable per document. A writing surface that cannot be lengthened is not the
  product, and deferring growth would have built the geometry, zoom, and
  validation paths twice. New `DataContract.md` §5a is normative; the milestone's
  "one fixed portrait page geometry" is superseded.
- 2026-07-29 — Phillip loosened the one-live-canvas rule. The invariant is now
  one retained `PKCanvasView` per editor session with one construction site, not
  one per process, because scene-scoped and virtualized page editors must own
  independent active canvases. The runtime `CONTRACT VIOLATION` assertion that
  enforced the process-global form is intentionally gone; gate 50 still greps for
  the string but no longer has an emitter.
- 2026-07-29 — Accepted `EditorLifecycle` as a fifth owner, superseding "prune
  Just a Canvas to four owners". It earns the exception in §3 by isolating the
  UIKit background-execution lease out of `EditorSession`, holds no durable
  state, and is enumerated in `Tools/lib.sh`.

## Session log

### 2026-07-21 — G0 foundational contracts

- Created the empty orphan branch in a sibling worktree without modifying
  `main`.
- Added the operating guide, data/ownership contract, Just a Canvas milestone,
  and sequential plan.
- Scope was documentation only. No Xcode project, application code, dependency,
  fixture, tool, or inherited artifact was added.
- Acceptance evidence: root-history check, tree inspection, and final diff/tree
  inspection before commit.

### 2026-07-22 — G0 contract boundary corrections

- Initially distinguished document acceptance from persistence completion; the
  later direct-save simplification replaced both with one awaited save result.
- Defined one undo router and PencilKit-only routing for the first milestone.
- Named the drawing commit bridge, its push sequence, generation/coalescing
  rules, failure behavior, and isolation boundary.
- Scope remained documentation-only; application implementation did not start.

### 2026-07-22 — G0 concrete-implementation simplification

- Replaced the protocol-suggestive dependency diagram with concrete owners and
  direct method/event flow.
- Prohibited speculative `EditorContract`, `DocumentContract`, service-container,
  commit-bridge, and undo-router abstractions for Just a Canvas.
- Reduced the milestone's source tree from a prescribed type-per-role layout to
  seven illustrative concrete files, with further splitting only when earned.
- Scope remained documentation-only; application implementation did not start.

### 2026-07-22 — G0 page-geometry closure

- Removed undefined `QuarterTurns` and `SourceCropGeometry` fields from the
  current durable model rather than allowing G3 to guess their semantics.
- Defined the Just a Canvas page-space origin, axes, bounds, and immutable
  portrait width/height constraints.
- Required a future rotated/imported-source work line to define rotation, crop,
  composition, source mapping, encoding, and migration before implementation.
- Scope remained documentation-only; application implementation did not start.

### 2026-07-22 — G0 direct-save simplification

- Removed the command/reducer/event/revision machinery that had been projected
  backward from a future multi-page editor.
- Defined one direct `DocumentStore.save` call: successful return is the only
  save acknowledgment and failure throws.
- Kept only private editor generations for coalescing and stale-completion
  handling; they are neither durable nor product state.
- Scope remained documentation-only; application implementation did not start.

### 2026-07-22 — G0 approved pruning pass

- Incorporated an independent read-only simplicity review approved by Phillip.
- Reduced the data contract from 575 lines to a Just-a-Canvas-only contract and
  removed future presentation, PDF, normalized-coordinate, cache, resource,
  virtualization, multi-page, and semantic-undo rules.
- Replaced generations with editor-owned `dirty` and `saveInFlight` booleans.
- Defined one concrete binary property-list file with exact primitive field
  semantics; removed packages, manifests, references, checksums, and assets.
- Corrected durability: a returned save must restore exactly that drawing; only
  an interrupted unreturned save may recover the prior or new complete file.
- Merged model and atomic persistence implementation into G3. G4 records a fixed
  baseline trace before proposing evidence-based numeric budgets.
- Scope remained documentation-only; application implementation did not start.

### 2026-07-29 — Remote implementation review and contract reconciliation

- Reviewed every file imported from `Tuber2fast.git`: 29 files at initial import
  plus the 18-file `306ab29` hardening pass. The code was written without access
  to `Docs/`, so it cited a `DataContract.md` §5a that did not exist here.
- Contract amended rather than code reverted, on Phillip's decision: §5a page
  extension added, §2 owner table extended to five owners with rule 7 (canvas
  renders the height it is given) and rule 8 (`EditorLifecycle` owns only the
  lease), §3 UIKit allowance recorded, §4 width/height field rules rewritten,
  §9 canvas invariant loosened, §11 extension tests required.
- Milestone updated to match: page growth moved from excluded to included, one
  canvas per editor session, page-extension behavior and gates added.
- Adopted `DESPIKING_PROPOSAL.md` as a forward document only. It re-proposes the
  package/generation machinery the 2026-07-22 pruning pass removed and must not
  reorder this plan; G4 baseline and G5 verdict still come first.
- Scope was documentation only. No application code was changed in this session.
- Open findings recorded against the adopted code, none yet fixed: a failed
  autosave does not reschedule itself (`EditorSession.performAutosavePass`);
  `CanvasFile.validated()` couples the durable value to the app's global width
  constant rather than per-document immutability; `flushForBackground` loops
  while dirty on a bounded lease; whole-drawing serialization scales with total
  ink rather than changed content, to be measured at G4.
- Status board unchanged. G1–G3 code exists but no `Tools/gate.sh` run has been
  recorded on this branch, and status is not flipped without gate evidence.
