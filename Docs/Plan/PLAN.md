# TuberNotes greenfield execution plan

This is the sole coordination document for the `postoai` orphan branch. Work
one line at a time and append a dated session entry before stopping.

## Status board

| Line | Status | Exit |
|---|---|---|
| G0 — Foundational contracts | Complete | Data and Just a Canvas contracts committed on an orphan root |
| G1 — Empty iPad application shell | Complete | New project installs and launches a blank non-editable root on named iPad |
| G2 — Live canvas runtime | Complete | One stable PencilKit runtime draws, erases, pans, zooms, undoes, and redoes |
| G3 — One-file persistence | Complete | Model, direct autosave, atomic replacement, recovery, and lifecycle behavior pass |
| G4 — Performance baseline | Pending | Fixed device trace and measurements recorded; evidence-based budgets proposed |
| G5 — Phillip canvas verdict | Pending | Phillip accepts or returns bounded findings from normal app |
| P1 — Multi-page durable form | Complete | Format version 2 directory, version 1 migration, per-page save |
| P2 — Horizontal paged navigation | Pending | Swipe turns and snaps one page; live canvas count stays bounded |
| P3 — Append past the last page | Pending | Swiping past the end yields a writable page, durable once inked |
| P4 — Phillip pagination verdict | Pending | Phillip accepts or returns bounded findings on turn feel |

Lines are sequential. G1 must not prebuild G3 abstractions; each line adds only
what its exit requires while conforming to the complete contract.

P1–P4 belong to `Docs/Milestones/PagesAndTurning.md` and begin after G5. P1 is
the durable form alone, with no navigation: it must be provable by tests and a
migration before any paging view exists, because a format defect discovered
after the UI is built costs both.

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
- 2026-07-29 — Extended G4's baseline trace to a worst case. The trace as
  written drew for five minutes on one page height and could not reach the
  failure it exists to find: every save serializes the whole `PKDrawing`, so
  cost scales with total ink, which the "scale with visible or changed content"
  rule forbids and which §5a's downward growth amplifies. The trace now builds a
  maximum-extents, densely inked document and runs continuous writing on it, and
  records serialize and save cost as p50/p95/max distributions plus bytes per
  save, cumulative bytes, stroke count and extents per measurement, and thermal
  state. `DataContract.md` §9 and the milestone's baseline trace both changed.
- 2026-07-29 — Pre-committed G4's disqualification criteria before any
  measurement exists, so the data decides instead of being argued with
  afterward. A breach of p95 serialize duration or cumulative trace write volume
  disqualifies the one-file whole-drawing format as the notebook substrate and
  promotes the `DESPIKING_PROPOSAL.md` package writer to the next plan line.
  Proposed thresholds awaiting Phillip's approval, measured by nobody: p95
  serialize ≤ 50 ms, cumulative trace write volume ≤ 250 MB.
- 2026-07-29 — Permitted adaptive debounce and automatic save retry. The
  debounce becomes `max(500 ms, 4 × the most recent serialize duration)`, with
  500 ms as a hard floor, so small documents are unchanged and large ones stop
  chaining whole-document serializations during continuous writing; it is the
  mitigation available without a format change and does not retire the §9 test.
  A failed save reschedules itself with doubling backoff capped at five seconds,
  resetting on success, rather than waiting for the user to draw again. Phillip
  set the ceiling at five seconds, not the half minute first proposed: the wait
  is time the document spends knowingly unsaved, so a long ceiling buys nothing
  and only delays recovery once the cause clears. The
  background flush stays a single best-effort pass and deliberately runs neither
  the loop nor the backoff, because the iPadOS execution lease is finite.
  `DataContract.md` §5 and §6 changed; the milestone follows them.
- 2026-07-29 — Rejected a size-driven debounce in favour of the duration-driven
  one. Phillip's objection: bytes describe what a document contains, not what an
  edit cost, so once placed images or lasso operations exist a document holding
  one large image would sit at the ceiling permanently and throttle ink saves it
  did not cause. Recorded in §5 because the idea is likely to recur. The wider
  point stands: no control signal distinguishes a small change from a large
  document while every save rewrites the whole file, so the mitigation stays a
  safety valve and the format remains what §9 is measuring.
- 2026-07-30 — Phillip reversed downward page growth. The bounded growing page
  is removed and geometry is immutable again, superseding the 2026-07-29
  overrule of immutable geometry. A lengthening page is not the reading model
  the product wants; more writing surface comes from turning to the next page.
  `DataContract.md` §5a is rewritten from "page extension" to "fixed page
  geometry", and grown heights are now rejected on load rather than adopted.
- 2026-07-30 — Phillip chose GoodNotes-style horizontal paged page turning,
  with a new page created automatically on swiping past the last one. This is
  multi-page, which Just a Canvas §4 excludes, so it is a new milestone rather
  than a line of this one. It requires a page-list file format with a real v1
  migration, canvas recycling across pages (breaking the single-construction-site
  invariant gate 10 enforces), and per-page saving, because rewriting every page
  on every save violates the scale-with-changed-content rule outright.

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

### 2026-07-29 — Save-cost contract amendments

- Amended `DataContract.md` §9 and the milestone's baseline trace so G4 can find
  the total-ink cliff: two added trace steps build a maximum-extents, densely
  inked document and write on it continuously, and cost is recorded as a
  distribution rather than a single sample. Existing steps 1–4 kept intact.
- Recorded G4's disqualification criteria in §9 in advance of measurement, with
  the two thresholds marked explicitly as proposals for Phillip and not as
  findings. No measurement has been taken.
- Amended §5 and §6 to permit the two save-policy changes being implemented
  concurrently: adaptive debounce with a 500 ms floor, and automatic retry with
  doubling backoff capped at five seconds. §5's pseudocode now describes the
  actual algorithm, including the fresh debounce after a save rather than
  immediate re-serialization, and §6 records that the background flush is one
  best-effort pass with no loop and no backoff.
- Scope was documentation only. No application code was changed in this session;
  `TuberNotesApp/` was being edited concurrently by another agent and was read
  only to confirm what the amendments describe.
- Remaining divergence from the amended contract, unchanged here: §6 now
  requires a single background pass, while `EditorSession.flushForBackground`
  still calls the looping `saveIfNeeded`; §5 now requires automatic retry, which
  `performAutosavePass` does not yet do. Both are the concurrent
  implementation's work. `CanvasFile.validated()` still couples the durable
  value to the app's global width constant rather than to per-document
  immutability.
- Status board unchanged, for the same reason as the preceding session: no
  `Tools/gate.sh` run has been recorded on this branch.

### 2026-07-29 — G3 save-path hardening

- The imported implementation did not build. `Thread.isMainThread` in
  `DrawingSnapshot.serialized()`, introduced by `306ab29`, is unavailable from an
  async context and failed gate 30 under warnings-as-errors, so gates 40–60 had
  never run on this branch and the adopted code arrived unverified. The
  off-main evidence is now read from a synchronous closure and retained.
- A failed autosave now reschedules itself with doubling backoff capped at five
  seconds, resetting on success, per the amended §5. `saveIfNeeded` still
  refuses to loop on failure but arms one retry timer before returning, because
  it cancels the debounce on entry and a failed Retry tap would otherwise have
  reintroduced the original defect.
- `flushForBackground` awaits any in-flight save and then performs at most one
  more, per the amended §6. Still-dirty stays dirty for `resumeForForeground`.
- The debounce is now `max(500 ms, 4 × last serialize duration)`, measured where
  the serialization happens and returned to the session rather than timed twice.
- The load-suppression flag is deleted. A test established that PencilKit
  delivers `canvasViewDrawingDidChange` synchronously, inside the `drawing`
  assignment — one callback, before the statement returns — so the flag was
  redundant rather than inert, and would have gone silently inert had delivery
  ever moved off the assignment. The surviving mechanism is the session's phase
  guard, which holds under either behavior and also covers `.failed`, where
  autosaving would overwrite a document that could not be read. The install
  ordering is now enforced by precondition instead of described by comment.
- Evidence: `Tools/gate.sh` at 2026-07-29T23:54:46Z — 10-structure, 20-generate,
  30-build, 40-test, 50-sim-launch PASS; 60-device SKIP; **verdict INCOMPLETE**.
  40 tests pass. Gate 60 was blocked solely by a locked iPad (developer disk
  image services unavailable); pairing, Developer Mode, signing, and SDK all
  passed on iPad Air (5th generation), iPadOS 26.5.2.
- Outstanding evidence, and the reason this line is not done: no device
  evidence was collected. Pencil feel, palm rejection, Pencil/touch separation,
  pan/zoom behavior, and the 500 ms floor under real handwriting are all
  unproven, as is Phillip's verdict. Unlocking the iPad and rerunning gate 60 is
  the remaining step.
- Found and not fixed: serialize cost is roughly 2.6× higher cold than warm
  (126 ms versus 48 ms at 20,000 strokes / 4.6 MB), and the session measures only
  warm, so the adaptive debounce systematically under-estimates a cold first
  save — relevant to the §9 distribution. `isEditable` on the canvas is a second
  representation of readiness alongside the session's `phase`. §5's pseudocode
  requires a fresh debounce rather than immediate re-serialization, while
  `saveIfNeeded`'s loop still serializes back to back on the user-initiated
  Retry path.
- Status board unchanged: the verdict was INCOMPLETE, which is never reported as
  success.

### 2026-07-30 — G1–G3 device evidence

- The iPad was unlocked and reconnected. `Tools/preflight-device.sh` returned
  READY: the `developer disk image services unavailable` block that caused the
  previous SKIP is cleared, and the development profile was already trusted, so
  the second precondition never fired.
- Evidence: `Tools/gate.sh` at 2026-07-30T07:00:04Z — 10-structure, 20-generate,
  30-build, 40-test, 50-sim-launch, 60-device all PASS; **verdict PASS**
  (`Artifacts/gate-report.md`). Signed device build, install, launch, and
  process-running all confirmed on `Phillip’s iPad`, iPad Air (5th generation),
  iPadOS 26.5.2, device id `2DD98ECC-A26A-5730-943B-01DD63DC4117`, bundle
  `com.tubernotes.greenfield`. No new crash reports; the `.ips` files under
  `Artifacts/device-diagnostics/` all predate the save-path fixes.
- G1–G3 are marked complete on that PASS, `Tools/gate.sh` being the sole
  arbiter of done.
- Not performed, and not claimed: the milestone §6 hand-exercised checks. Launch
  first-contact ink, scroll and zoom against the page, background-flush
  survival, autosave spacing under continuous writing, and the five-second retry
  were not exercised by hand on the device. Page extension was likewise never
  exercised, and is now moot — see the next entry.
- G5 remains pending. Pencil feel, stroke fidelity, palm rejection, and
  Pencil/touch separation are Phillip's verdict alone and remain unrendered.

### 2026-07-30 — Remove downward page growth

- Reversed the 2026-07-29 growth decision at Phillip's direction. `PageGeometry`
  loses `extended(from:)`, `maximumExtents`, and `maximumHeight`; `initialHeight`
  becomes `height`, and `isValidHeight` is now an equality check. `EditorSession`
  loses `pageHeight`, `canExtend`, and `extendPage`; `PageCanvasController` loses
  `setPageHeight` and its `pageHeight` property, and now writes `contentSize`
  exactly once at construction. The extend control is gone from `RootCanvasView`.
- A grown height on disk is rejected, not adopted. Accepting one would strand ink
  below a page edge that no longer exists with no way to scroll to it, so
  `CanvasFile.validated()` refuses it and there is a regression test for exactly
  that file shape. No document written by the extension-era build was ever
  shipped, so no migration is owed.
- `DataContract.md` §4, §5a, §2 rule 7, and §11 amended; the milestone's page
  extension section, journey step, and two acceptance gates removed;
  `Docs/Handoffs/DeviceVerification.md` §6 and §7 corrected, since they told the
  next agent to exercise a control that no longer exists and to watch for a
  precondition that no longer exists.
- Evidence: `Tools/gate.sh` at 2026-07-30T07:2Z — 10-structure, 20-generate,
  30-build, 40-test, 50-sim-launch, 60-device all PASS; **verdict PASS**, built,
  installed, and launched on `Phillip’s iPad`. 33 tests pass, down from 40:
  seven page-extension tests were deleted rather than weakened.
- Not done: the pagination milestone itself is unwritten. G4's baseline trace
  still describes a maximum-extents document that can no longer exist and needs
  rewriting before G4 runs.

### 2026-07-30 — Pages and Turning specified

- Wrote `Docs/Milestones/PagesAndTurning.md` and the `CONTRACT:` amendments it
  needs, before any implementation, because three of them change rules that
  `Tools/gate.sh` enforces and one changes the durable format.
- New `DataContract.md` §4a: a document becomes a directory — one index plus one
  file per page — superseding §4's single-file and no-package rules. §4 stays
  normative as the version 1 format that §4a migrates from. The design point is
  that a save writes only changed page files; rewriting an unchanged page is
  specified as a defect, not an inefficiency, because rewriting every page on
  every save is exactly the failure the scale-with-changed-content rule exists
  to prevent.
- Write ordering is normative: page files first, then the index. A crash between
  them strands an inert orphan page file; the reverse order would strand an
  index naming a file that does not exist, which is an unopenable document. So a
  dangling reference is fatal on load and an orphan is ignored.
- Version 1 migration is real and owed, unlike the page-geometry reversal:
  version 1 files exist on Phillip's iPad. The version 1 file is kept untouched
  until the version 2 document is written, so an interrupted migration is not
  data loss.
- §2 gains rules 7a and 7b: a canvas owns one page and never learns its index,
  and page turning is navigation rather than editing, so it is not undoable.
- §9's one-canvas-per-session invariant is replaced by a *bounded* live canvas
  count that must not grow with page count, with retirement releasing the canvas.
  Retention that grows with pages visited is the multi-page form of the
  monotonic-retention failure §9 already forbade. `Tools/gate.sh` gate 10 checks
  the single construction site, which still holds and is unchanged.
- Named in the milestone rather than discovered later: `PKCanvasView` is itself a
  `UIScrollView`, so a paging scroll view and the canvas's own pinch-zoom fight
  over a horizontal drag. The committed rule is that a turn is available at
  fit-width scale or at a page's horizontal edge, and pans otherwise.
- Also specified: a page appended by overswiping is durable only once it takes
  ink, so an accidental swipe past the end does not permanently grow the
  document. This is the one deliberate divergence between screen and file.
- Status board gains P1–P4. P1 is the durable form with no navigation at all,
  deliberately: a format defect found after the paging UI exists costs both.
- No application code changed in this entry. Nothing is claimed as working.

### 2026-07-30 — P1 multi-page durable form

- Added `DocumentIndex` and `PageFile`, and rewrote `DocumentStore` around the
  §4a directory: `document.plist` plus one file per page under `pages/`. The
  store writes page files first and the index only when it changed, so an
  ordinary ink save touches exactly one file.
- Migration from format version 1 runs on load and leaves the version 1 file on
  disk. Tests cover identity and byte fidelity, that the source survives, that
  migration does not run twice, and that a version 1 file carrying a grown page
  height fails to migrate rather than being adopted.
- `EditorSession` now holds a `DocumentIndex` instead of loose IDs and saves
  only the current page. Navigation is deliberately absent: this line is the
  durable form alone, and the document still has exactly one page.
- Found and fixed while testing, and it is the reason two lifecycle tests
  failed: the store's cached "index as last written" was treated as authority on
  what is on disk. With the index file gone but the cache intact, a save wrote
  page files and skipped the index — producing exactly the unopenable document
  §4a's write ordering exists to prevent. The cache is now a hint, confirmed by
  one `stat` per save.
- Evidence: `Tools/gate.sh` — all six gates PASS including device build,
  install, and launch on `Phillip’s iPad`. 50 tests pass, up from 33.
- Not done, and not claimed: no page turning exists yet, so nothing here has
  been exercised by hand on the device beyond launch. The migration has not been
  run against a real version 1 document on the iPad — see the next entry.
