# Adversarial review — canvas-feature-complete

Six parallel reviewers attacked the branch (29 commits over `postoai`) from
independent angles: durability/data loss, contract compliance, concurrency
and latency, spatial correctness, test integrity, and docs-vs-reality. All
reviews were read-only; every finding below survived the reviewer's own
refutation attempt. Findings are ranked; each names the mechanism and where
it lives.

**Fix status.** Findings 1–3, 5 (zoom trap), 7, and 9–12 of the numbered
list, plus the amendment-count and documentation defects, were fixed the
same day by four parallel agents and merged (`1b23447`); every code fix
carries a test verified by reverting the fix. Suite after all merges: 239
tests in 19 suites, green. Deliberately NOT fixed — Phillip's decisions:
finding 4 (PDF page editable-over-refusal), A11's wording, the `locked`
envelope amendment, and whether the sub-2× zoom clamp rule (chosen over a
trap in `4e82eff`) wants a `CONTRACT:` tag. Findings 8 (EXIF hole) and 13
(no cancellation) remain open as accepted-for-now; #14's evicted-page trap
is fixed via a typed refusal. Cross-lane confirmations are noted — two independent lenses
finding the same defect is the strongest signal this process produces.

## Critical — fix before adopting anything

### 1. A failed save plus a delete destroys a PDF import's asset, permanently
`DocumentStore.deleteAssetIfUnreferenced` (DocumentStore.swift:160-185)
answers "is anything still referencing this?" from **disk only**. Layers
created by a not-yet-successful save exist only in memory. Sequence: import
a 50-page PDF → asset writes, the save of the 50 referencing layers fails
transiently (disk full — exactly the situation in which a user then deletes
things) → user deletes one pdf layer → `EditorSession.deleteLayer` runs
`reclaim` **unconditionally** (EditorSession.swift:1563), the disk scan
finds zero references, the write-once asset is deleted. The 49 surviving
layers now carry dangling refs; `plan(for:)` throws `danglingAssetRef` on
every subsequent save — **the whole document can never save again**, and
the PDF bytes have no other copy. The store's own soundness comment
(DocumentStore.swift:134-137) holds only for layers that were durable at
least once. No test covers reclaim after a failed save.
Fix shape: skip reclamation while the referencing pages are dirty /
`lastSaveError != nil`, or consult the in-memory layer lists in the scan.

### 2. One poisoned page halts durability for the whole document
Saves are all-or-nothing batches: `beginSave` gathers every dirty page into
one `store.save`, and `plan()` throws before anything writes
(DocumentStore.swift:614-616). Two reachable states poison a page with no
repair path:
- **(a)** A page with an unknown-kind layer K plus a recognized layer I.
  K is never in `staticLayers`, so every write plan drops it; deleting I
  dirties the page; the refusal guard throws `refusedLayerWouldBeLost` —
  and K **cannot be deleted** (`deleteLayer` can't find it:
  `layerNotFound`). Forever.
- **(b)** Two missing-asset layers; deleting one (the advertised repair)
  still writes the other → `danglingAssetRef`, unless the user guesses to
  delete both.

In both, the retry loops at the 5 s cap and **ink drawn on any other page
is never durable again**; a crash loses it. The refusal guard itself is
correct and unbypassable — the defect is the batch coupling plus the
session legally dirtying an unwritable page.

### 3. Stale in-flight composite: a committed layer move visibly snaps back
**Found independently by two reviewers (concurrency and geometry) with the
identical mechanism.** `CompositeKey` deliberately omits transforms; the
cache compensates with `entry.request == request`
(StaticLayerRenderer.swift:141) but the in-flight dedup does not
(StaticLayerRenderer.swift:148) — `inFlight[key]` matches on key alone.
A composite requested after a drag-commit can be handed the **pre-drag**
render; back in the controller the generation check passes (it is the
newest generation), `hideLift()` runs, and `renderedRequest` records the
new request as satisfied — so the layer appears at its old position and
**stays wrong on a static screen** until rotation, a layer edit, or a page
turn, while the durable value holds the new transform. Window: a composite
still in flight across a select-drag-deselect (slow decode / busy store
actor makes this plausible).
Fix shape: compare the running task's full request, or key `inFlight` on
the request rather than the key.

## High — decide before adopting the contract

### 4. An imported PDF page is editable ink over an error tint — and it poisons images too
`StaticLayerRenderer.render` refuses any recognized non-image kind
(StaticLayerRenderer.swift:335), and one refusal refuses the whole
composite. So: (a) an imported PDF page shows the pink `refusedTint` while
the canvas stays fully **editable** — the user inks over a worksheet they
have never seen, and the save binds that ink permanently (contract lens:
cuts against ink integrity and spatial correctness, the top two
priorities); (b) an `image` layer added to a pdf-backed page **also**
renders as refusal — the image the user just placed never appears. "Nothing
rasterizes a PDF" is documented; *editable-over-refusal* and the
image-on-pdf-page interaction are stated nowhere in either contract file.
Decision needed: may a valid-but-unrenderable kind be editable? (Options:
lock pdf pages until 3c; composite per-layer instead of all-or-nothing;
accept and write it down.)

### 5. The envelope's fifth field is in no amendment
`LayerEnvelope.locked` (LayerEnvelope.swift:220) is durable, and absent
decodes as `false` (LayerEnvelope.swift:285) — the exact
"replaced with a default" pattern *Invalid states fail loud* forbids,
justified only by an agent-authored analogy to the pre-layer read-forward
rule. No amendment A3–A15 edits the envelope-shape sentence
`{ layerID, kind, payload, pageSpaceTransform }`. Adopting A11 as drafted
still leaves the contract not matching the bytes on disk.
Fix: amend the envelope definition and bless (or strike) absent-as-false.

### 6. A11's text is false against the code in two places
- "A `pdf` or `image` layer is selectable" — code:
  `isSelectable == (recognizedKind == .image)` (LayerEnvelope.swift:297).
  A pdf layer is not selectable, so A11's own rationale ("selection is how
  'replace the worksheet' has a UI path") fails for exactly the worksheet
  case. Contract.proposed.md flags a different narrowing, not this one.
- "a drag beginning anywhere else deselects and falls through" — the
  recognizer fails without deselecting (LayerSelectionRuntime.swift:602-607);
  only a tap deselects. Selection chrome rides through scrolls.
Adopt A11 only after rewriting it to the code's actual behavior (the code
is the better side today).

## Medium — real defects, not adoption blockers

### 7. The scale handle diverges from the finger on every non-square image
The scale factor is measured in **unit-square space**
(LayerSelectionRuntime.swift:392-405), which is anisotropic with respect to
page space — the short axis is weighted more. Worked example (1000×500
image fit on the canonical page): drag the corner 61 pt right → the corner
lands ~31 pt from the finger and moves *down*. Exact arithmetic, verified.
Fix shape: measure the ratio in page space
(`|finger − placedAnchor| / |placedCorner − placedAnchor|`); uniform
in-layer-frame scaling is preserved.

### 8. The EXIF orientation hole (two halves, two reviewers)
- `importImage` trusts caller-supplied `sourceWidth/Height`
  (EditorSession.swift:1208-1247) while the renderer decodes with
  orientation applied (StaticLayerRenderer.swift:471). Pass a camera JPEG's
  raw pixel dims (the natural mistake) and the **saved transform is wrong**
  — the image renders stretched, durably. No caller exists yet; the API
  hole does.
- Zero tests feed any asset with EXIF orientation ≠ 1. Delete the
  orientation-transform option from `downsample` and the suite stays green.

### 9. The zoom cap off 2× hardware: a crash, not a refusal
At displayScale 1 (trait collection unattached at first layout, or a 1×
external screen) the required ceiling (20) exceeds PencilKit's silent
clamp (10) and the read-back **precondition traps**
(PageCanvasController.swift:366-399). `minimumSupportedDisplayScale = 2`
validates only the durable cap; nothing enforces the assumption at
runtime. Relatedly, the cap tests bake in displayScale 2 — the property
holds only on the pinned simulator; 2.0 is also exactly the clamp
boundary, the most fragile possible value.

### 10. Switching selection A→B blanks A for one composite round-trip
`showLift(B)` replaces the single lift layer **before** the minus-B
composite (which re-includes A) is even requested
(PageCanvasController.swift:513-546) — A is in neither the composite nor
the lift until the async render lands. Violates PageBackdrop's own stated
invariant (PageBackdrop.swift:67). Pure code order; no race needed.

### 11. Cache tests assert counters, not identity
The byte-bound eviction test's two composites have **equal byteCounts**, so
evicting the *new* entry instead of the old passes identically
(StaticLayerRenderTests.swift:199-218). The retain-window test would pass
with the disjointness condition **inverted** (:254-274). No test straddles
a bound between one and two composites, so `trimToByteBound`'s
loop-and-LRU behavior is unpinned. Fix: `===` identity re-requests after
eviction, and a bound ≈ 1.5 composites.

### 12. The minus-one wiring is unproven
The pixel test hand-builds the exclusion list;
`PageCanvasController.layersToComposite` is exercised by **no test** — if
selection stopped feeding the composite request, the suite stays green
(LayerSelectionTests.swift:644-695).

### 13. No cancellation in the composite pipeline
A fast flick across image-heavy pages queues N decode+composite jobs that
run to completion; results are correctly dropped, but peak memory =
cache bound + all in-flight contexts (~24 MB each) + decoded thumbnails —
bounded by request frequency, not by the stated 96 MB
(StaticLayerRenderer.swift:157, 245). Also: composite decode serializes
behind saves on the `DocumentStore` actor — a page turn during a large
autosave delays the backdrop by the save's full duration. And retain()
tasks are unordered across quick page turns (rare, self-correcting).

### 14. `deleteLayer` on an evicted page traps
`layerListChanged` preconditions on `.loading` ink; `deleteLayer` checks
neither ink state nor window membership (EditorSession.swift:304-312,
1532). No UI caller today — a landmine for the layers-sidebar UI.

## Amendment-text drift (fix wording during the morning pass)

- **A10**: registers the prior *transform*, not "the prior envelope value";
  registration is in the controller, not "through the session"; a layer
  locked between commit and undo makes Cmd-Z silently no-op; the
  no-manager path is unstated. Also its AHEAD label violates the status
  key (code exists → FORCED by the key's own definition).
- **A3**: the second table row's "nothing decodes tiles / owned by
  PageBackdrop, not cached" doesn't describe `StaticLayerRenderer`, which
  is exactly a bounded cache of decoded images owned by `EditorSession`.
- **A4**: the `loading | refused | ready(assetRef)` state machine exists
  nowhere in code (the editability aggregation it implies does hold).
- **A9**: the coarser-than-1-page-point-per-pixel refusal
  (DocumentIndex.swift:275-280) is enforced but stated nowhere.
- **A15**: `ImageIO` is not on the widened banned list, so the widening's
  own rationale is only half-enforced.

## Silent drift — rules the code follows that neither contract states

- Imports and layer deletion save **immediately**, bypassing the ink
  debounce (EditorSession.swift:1271, 1367, 1549).
- The composite LOD policy (fit-width detail, 2,800 px cap, soft past
  fit-width) is user-visible and lives only in comments.
- `recognizedFormat` refuses pdf-format *image* layers — a kind/format
  cross-check no rule states.
- importPDF appends at the end without navigating there.
- `RootCanvasView.@State shapeKind` holds a copy of the tool whose owner
  is `PagedCanvasController` — the exact copy `EditorSession.setShapeTool`
  refuses to hold, held one level up instead.

## Documentation defects

- `ImplementationStatus.md`'s "Decisions taken without Phillip" is frozen
  at phase 1 — ~80% of decisions live only in OvernightLog; add a pointer.
- "One allowlist entry" for CoreGraphics is stale in OvernightLog and
  Contract.proposed's open question 7 — there are two (A15 has it right).
- OvernightLog's decision/discovery numbering restarts twice; "decision 7"
  names two different decisions.
- `Unproven.md` says the CI workflows are uncommitted; they are committed
  and never-run (Queue.md has it right). Inherited, but left standing
  through heavy overnight edits.
- Phase 4's evidence row lists "layer-edit undo" as asserted; only the
  inverse-commit path is — say so.
- Phase 2's "orientation asserted" covers zero EXIF orientations; the
  decode bound is asserted as arithmetic, never observed inside `render`.

## What survived attack (verified clean, for the record)

Durable write order (layers → pages → index, index unconditionally last);
the v2→v3 migration and version-4 refusal; the refusal guard (both save
entry points converge on it, reads disk, unbypassable); the overnight
dirty-tracking fix (complete — every mutation funnels through
`layerListChanged` synchronously); envelope round-trips (six exact Doubles,
unknown kinds decode refusable); interrupted PDF import (orphans only,
document reopens clean); all transform algebra (concatenation, inversion,
rotation conventions, both y-flips, no per-tick drift, flip refusal);
mixed-geometry paging; shape-tool corner coincidence, spline handling,
degenerate drags; frame paths genuinely one-transform-per-tick with no
allocation/await/dispatch; Swift 6 isolation throughout; one-writer holds
everywhere checked; all 28 cited commit hashes accurate; the phase 3b
un-adoption byte-exact; the pixel-helper false alarm confirmed false by a
second independent check; no undocumented file changes on the branch.
