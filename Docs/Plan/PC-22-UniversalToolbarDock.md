# PC-22 — Universal draggable toolbar dock

Status: **follow-up Release-delivered — awaiting Phillip's verdict**

Target branch: `main`

Owner: App/Notebook toolbar presentation. `SpatialCanvas` retains Pencil,
page-coordinate, zoom, and content-gesture ownership.

## Objective and user-visible outcome

Move image import from the notebook navigation bar into the main tool bar. Let
the user drag that bar by a dedicated grip and snap it to the top, bottom, left,
or right edge of the iPad. Keep one app-wide dock choice across every page and
notebook, including later app launches.

## Scope

- `TuberNotes/Notebook/NotebookToolbar.swift`
- `TuberNotes/Notebook/NotebookView.swift`
- one focused source contract check if needed
- this child line and the parent status board

## Non-goals and dependencies

- no image import, image arrangement, Pencil, canvas-coordinate, page, or
  notebook persistence changes;
- no per-page or per-notebook toolbar placement;
- no redesign of existing tool actions or settings visibility;
- normal Release delivery uses the explicitly pinned physical iPad; Phillip
  alone judges final drag feel and visual placement.

## Work and verification

1. Put the existing `PhotosPicker` action in `NotebookToolbar` and remove its
   duplicate navigation-bar action.
2. Add a dedicated toolbar grip, live drag offset, nearest-edge resolution, and
   horizontal/vertical toolbar layout appropriate to the resolved edge.
3. Persist the four-way dock as an app-wide `AppStorage` value and sanitize
   unknown stored values back to the bottom dock.
4. Run focused host checks, inspect the final diff, then build/install/launch
   the normal Release app on the pinned iPad without using scenario tooling.

## Acceptance evidence and stop conditions

- image import remains reachable from the main toolbar and no longer appears
  in top navigation;
- the grip drags and snaps to all four edges without stealing existing tool
  gestures; side docks lay controls out vertically;
- one persisted dock value is reused by all `NotebookView` instances;
- stop after Release delivery evidence, after two bounded delivery failures, or
  before any human-only interaction judgment.

## Session log

- 2026-07-21 — Traced image import to the top-bar `PhotosPicker` and the main
  toolbar overlay to `NotebookView`. Started the smallest toolbar-owned change;
  unrelated PC-20/PC-21 worktree edits remain outside this line.
- 2026-07-21 — Implemented a toolbar-owned image picker, dedicated drag grip,
  four-way nearest-edge snap, horizontal top/bottom and vertical side layouts,
  and one app-wide `tuber.notebookToolbarDock` preference. The focused PC-22
  contract passes 3/3 and diff hygiene passes. A nearby legacy bundle is 24/29;
  all five failures assert concurrent Magic Lasso/provider source shapes and
  are outside PC-22. Signed Release build, install, normal launch, and live-
  process query pass on exact iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`.
  Evidence is under `tmp/verify/pc22-universal-toolbar-dock/`. Phillip's normal-
  app verdict is still required for drag feel, edge placement, scrolling, and
  image-import interaction. No canvas, page, notebook, or image model changed.
- 2026-07-21 — Phillip requested a compact fixed tool sequence and removal of
  page navigation and Pencil from this toolbar. Reopened PC-22 for the smallest
  presentation-only follow-up. The existing marker/highlighter is the current
  line-making tool; no new straight-line drawing mode or PencilKit contract is
  being introduced.
- 2026-07-21 — Delivered the requested compact sequence: Pen, existing marker/
  highlighter line tool, Eraser, Lasso, Magic Lasso, Image, Undo, Redo, Layers.
  Removed Pencil, the page-navigation group, its callback, and its toolbar-
  settings toggle. Image and undo/redo remain available when the optional
  writing-tools group is hidden. Focused PC-22 checks pass 4/4; diff hygiene,
  signed Release build, install, normal launch, and live-process query pass on
  exact iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Follow-up logs are in the
  existing PC-22 evidence directory. Phillip's visual/order verdict remains.
