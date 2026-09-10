# Morning review guide: the v2 rewrite, night of 2026-09-10

Branch `v2-rewrite`, off `pdf-templates` at `4035bf7`. Nothing pushed.
Nothing in `Docs/Contract.md` changed; no agent wrote a rule.

## What happened, in one screen

1. You said: decide, lock, review adversarially, simplify, build, leave a
   guide. Subagents on Opus.
2. I closed the six open questions and wrote them plus the build spec into
   `Docs/Forks/fundamental-rewrite.md` (Parts 5 to 10).
3. Three Opus reviewers attacked it (durability, custody/runtime,
   simplicity). They found real holes: the fsync barrier sat on the wrong
   side of the renames, a refused new page could brick a notebook, an
   absent ink file was indistinguishable from a lost one, the open sweep
   would have deleted every layer and asset, prefix-sum paging re-opened
   a recorded rejection, undo suppression was unverifiable.
4. I rewrote the spec with every blocking finding closed, and a fourth
   reviewer verified the closures and found the residue: three deletion
   authorities that disagreed. Collapsed to one.
5. Built stages 0, 1, 2, 3. Full suite green (471 old tests + 42 new).
6. Ran a four-angle simplification pass on the new code (see the last
   section for what changed and what I skipped). Full suite green after
   it: 471 + 35.

## Review in 30 minutes, in this order

1. **5 min.** This file to the end.
2. **10 min.** `Docs/Forks/fundamental-rewrite.md`, Part 5 (D1 to D14)
   and Part 2 (the format). These are the one-way doors. Everything else
   is code you can change later.
3. **5 min.** `Modules/TNFormat/PackageStore.swift`, the `save` method
   only: plan, stage, publish 1, publish 2, publish 3. Read it against
   Part 2's "One save" block. If they disagree, the spec wins and the
   code is a bug.
4. **5 min.** `TNTests/FormatTests.swift`, suite "the write order survives
   every fault". This is the proof the format is owed. It injects a fault
   at every stage, publish, and directory sync in three modes (fail,
   truncate, discard-after-rename) and asserts the index never reaches a
   file that is not there.
5. **5 min.** `Modules/TNNotebook/Notebook.swift`, `inkChanged`, `undo`,
   `beginSave`, `performSave`. Custody by value; dirty is `editSeq >
   savedSeq`.

Run everything:

```bash
xcodegen generate
xcodebuild test -project TuberNotes.xcodeproj -scheme TuberNotes \
  -destination "platform=iOS Simulator,name=$(< Tools/pinned-simulator)"
```

Only the new bundle (about 20 s):

```bash
xcodebuild test -project TuberNotes.xcodeproj -scheme TuberNotes \
  -destination "platform=iOS Simulator,name=$(< Tools/pinned-simulator)" \
  -only-testing:TNTests
```

## Decisions I took that are yours to overturn

Each is cheap to reverse today and a migration tomorrow.

| Decision | Where to change it |
|---|---|
| D3 ink is not a layer; `inkIndex` names where ink sits in the stack; an import inserts *below* the ink | `PageFile`, `Notebook.addLayer` |
| D8 JSON for structured files; binary container for ink (64-byte header with both identities, length, CRC32) | `InkContainer.swift`, `Codecs.swift` |
| D9 one package version; an added key is a version bump plus a migrator; zero migrators ship | `NotebookIndex.currentFormatVersion` |
| D10 `F_BARRIERFSYNC` per staged file; three publish phases; no per-page atomicity across phases | `PosixFileSystem.stage`, `PackageStore.save` |
| D11 nothing deletes but `compact()`, and it leaves files younger than 24 h alone | `PackageStore.compact` |
| D12 the zoom cap is a code constant, not a durable field | `ZoomCap` |
| D13 `currentPageID` lives in disposable `view.json`, so a page turn never rewrites the index | `ViewState`, `Notebook.pageBecameCurrent` |
| Trash containers are named by the notebook or folder identity; recovery falls back to the root when the origin folder is gone | `LibraryStore.trash`, `recover` |
| A colliding notebook identity found by the scan is re-minted in place, in the second package found | `LibraryStore.scanIdentities` |
| D2 `maxPageEdge = 4096 pt`; `minPageEdge = 137.6` derived | `PageBounds` |
| D4 vocabulary: Notebook, Paper (with `none` for PDF pages), branded IDs | `TNModel` |
| D1 undo is the notebook's, history dies when a page leaves the decoded window | `InkHistory`, `Notebook.prune` |
| Paper unknown to this build refuses the page, not the notebook | `NotebookIndex.pageFaults` |
| `hasInk` never returns to false; an empty drawing still writes a container | `Notebook.beginSave` |

## What is built and what is not

| Stage | State | Evidence |
|---|---|---|
| 0 modules policed, hostless test bundle | done, committed | `ContractStructureTests` passes with `TN*` in `moduleDirectories` |
| 1 `TNCore`, `TNModel`, `TNFormat` | done, committed | 26 tests: key-set pins, delete-each-key, container tampering, the fault sweep, compact conservatism |
| 2 `TNNotebook` | done, committed | 9 tests: draw-during-held-save, close waits for the write, undo without echo, stale load dropped, refused new page, prune |
| 3 `TNLibrary` | done, committed | 7 tests: exclusive checkout with `.alreadyOpen`, ancestor locks, mutations refuse on an open notebook, trash restores the original name and suffixes only on collision, duplicate re-mints and keeps page IDs, identity index resolves live/trashed/missing, a collision is re-minted |
| 4 `TNCanvas` | not started | needs the device spikes below first |
| 5 `TNRender` | not started | |
| 6 app swap, tabs, delete `Tuber*`, links | not started | |

The old app builds and passes exactly as before; the `TN*` targets sit
beside it and nothing in the app names them yet.

## Device spikes only you can run

None of stages 1 to 3 depend on these, but stages 4 to 6 do.

1. **Spike zero.** Read `canvasView.drawing` inside
   `canvasViewDrawingDidChange` at 20k strokes. If it hitches, the
   fallback is a short coalescing timer that still carries the value.
2. **D1.** Vend a filtering `UndoManager` from the page controller; check
   that PencilKit's registrations are dropped and that three-finger
   swipe, shake, and Cmd-Z still reach it.
3. **D7.** Push a sharper composite on zoom at 120 Hz on a 4096 pt page.

## Known gaps, stated

- `InkHistory` is bounded by entries (50), not bytes; the byte bound waits
  on spike zero's measurement. Marked `KNOWN DEFECT` in the code.
- `PageSnapshot` carries no composite yet; `TNRender` is stage 5.
- `Notebook` has no background-lease handling; that is `Workspace`,
  stage 6.
- `TNLibrary` has no favorites or library-prefs sidecars yet; both are
  ports of existing v1 features and land with the app swap (6a).
- The spec's Part 9 migration table maps every `Contract.md` rule to its
  v2 fate. Nothing is deleted from `Contract.md` by this branch.

## Your morning verdicts, applied

You answered the proposal's six open questions before reading this.
Applied in commit `1982553`:

- Undo is GoodNotes-shaped: one notebook-wide stack surviving page turns;
  an undo on a page outside the window brings it back and restores on
  arrival. `Notebook.undo()` and `redo()` return the page they touched.
- `text` is a layer kind in the format: page-space rect, our own rich-text
  runs, alignment. Key set pinned, round trip and refusals tested.
- Page bounds stay as built, marked empirical; `maxPageEdge` is a constant,
  not a version bump.
- Recognition derived, Notebooks and paper: confirmed. Composites as
  values: D7 stands.

## Commits

```
git log --oneline 4035bf7..v2-rewrite
```

One commit per stage, each green. The spec is committed with stage 1.

## The simplification pass

Four Opus reviewers (reuse, simplification, efficiency, altitude) over
the new code. Applied, in commit `27528b6`:

- one key-set checker (`Codecs.checkKeys`) and one JSON encoder for every
  durable file; the layer file no longer round-trips through
  `JSONSerialization` and is parsed once, not three times
- `LayerFault` carries its own layer ID, so `RefusedLayer` and a
  twelve-arm switch in the store are gone; `PageBytes` states each
  refusal once
- the store caches only the notebook identity, never the index;
  `rewriteNotebookID` patches container headers instead of replaying the
  save protocol
- ink is a non-optional value once a page is ready, with its own
  `inkSeq`, so a layer nudge no longer rewrites the container
- `retired()` compares drawings with `==` instead of serializing both on
  the main actor; one detached hop serializes every drawing in a pass
- `lastSaveError` is a typed `SaveFailure`; `CloseOutcome.dirty` says
  whether the index is unsaved too
- `PageSnapshot` has two factories (`editable`, `placeholder`) and a
  private memberwise init; `PageDescriptor` carries `PaperKind` so a
  placeholder can name unknown paper
- the test doubles share one forwarding base; "no space" is a
  `FaultingFileSystem` fault; the untested intentions (`deletePage`,
  `movePage`, `setPaper`, `deleteLayer`) now have tests

Skipped, deliberately:

- a `LayerStack` value type maintaining `inkIndex` by construction:
  right idea, larger than a night; the invariant is checked at save
- `PageSpaceTransform` via `CGAffineTransform`: keeps TNModel free of a
  drawing vocabulary for now
- caching the presence set and the last page-file bytes in the store:
  the stats are per structural save, not per stroke
- a `Validated<T>` wrapper: the re-validation on save is cheap
- incremental dirty counting: a dictionary walk per stroke is microseconds
