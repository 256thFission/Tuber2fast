# The library run — handover

Branch: `library-overnight`, cut from `canvas-feature-complete`. Written at
the end of the overnight run, ~03:15. Everything below distinguishes what was
*seen* from what was *tested* from what was *neither* — per the standard for
the whole run.

**Run it:**

```bash
xcodegen generate
xcodebuild test -project TuberNotes.xcodeproj -scheme TuberNotes \
  -destination "platform=iOS Simulator,name=$(< Tools/pinned-simulator)"
open -a Simulator && xcodebuild build ... # or just run the TuberNotes scheme in Xcode and tap
```

Last full suite on this branch: **410 tests in 42 suites, 0 failures**, on
the pinned simulator. Two launch checks were performed by the managing agent
(screenshots in the session scratchpad): the app boots into the browser and
shows the adopted "Just a Canvas" document.

---

## What works — and how each claim was exercised

- **The durable form** (`Modules/TuberStore/LibraryStore.swift`): tree-as-
  truth, no index; folders = directories; sidecars orphan-class with
  `.corrupt` set-aside; trash with origin sidecars; favorites with prefix
  rewrite; `.staging` duplication; adoption of the pre-library document;
  derived modified dates covering all four save shapes including index-only.
  *Exercised by:* 24 store tests, each written to fail against a violation
  (the lane verified the date test against every save shape separately).
- **`EditorSession.close()` and `OpenIntent`**: close awaits the protected
  start task, drains saves, refuses edits after; a failing final save leaves
  the session alive and dirty and the retry machinery draining;
  `.openExisting` refuses a nil load byte-identically. *Exercised by:* 9
  tests over gated seam stores (held save, held load, counting store).
- **The browser**: grid and list, one interleaved comparator; folder push
  inside the content pane (sidebar outside the NavigationStack); create
  notebook/folder in the observed modal shell (26 swatches + wheel, icon
  tab); chevron popover with inline rename, folder Color/Icon editing,
  Duplicate (documents only), Move (drill-down picker with subtree
  exclusion), Move to Trash; Trash screen (Recover to origin, Delete
  Permanently and Empty with confirmations); view-options menu (Select
  Items / Grid–List / four sort keys, direction chevron on the active key);
  All/Documents/Folders filter; title search of the current folder;
  favorites toggle + flat cross-parent Favorites collection (no + New
  there); ink-only page-1 thumbnails behind paper placeholders with
  negative-cached refusals; multi-select with Select All / Done, check
  overlays, batch Duplicate/Move/Trash; Import (PDF and image) creating and
  opening a new document. *Exercised by:* 43 browser/model tests over real
  stores on temp roots, plus two launch-and-screenshot checks.
  **No flow has been tapped by a human hand. That is the morning's first
  job — the walk below.**
- **Dirty-close protection end to end**: a session that cannot save is
  retained off-screen, the browser banners it, opens are blocked, Retry
  drains. *Exercised by:* coordinator tests with a healing store. Never seen
  against a real failing disk.

## What does not work / unfinished frontier

- **Imported documents keep a blank first page** (the `.createIfAbsent`
  page), with the PDF after it. Removing it needs a page-delete entry point,
  which is exactly the index-keyed-runtime boundary the proposal kept out of
  scope. Honest state: visible, annoying, safe.
- **Not built at all** (declared, not discovered): drag & drop;
  static-composite thumbnails (PDF/image pages render as paper unless inked);
  swipe-across-to-select; Export anywhere; recursive search; the expandable-
  tree move picker (drill-down stands in); Language/Cover rows and the
  template catalog in New Notebook; Shared/Marketplace/bell/avatar/cloud
  chrome; fresh-`documentID` duplicate (same-ID copy has a `KNOWN DEFECT:`
  at the copy site); page-bookmarks in Favorites; keyboard/pointer polish.
- **Favorites listing drops its own degradations** (store builds them,
  collection view doesn't surface them — folder listings do). Minor, noted
  by its lane.
- **Success banners wear the warning triangle** (one shared banner surface).
  Polish pass material.
- **The editor Back button can overlap the in-editor save-error banner**
  (both top-leading). Restructuring `RootCanvasView` was deliberately out of
  scope.
- **A mutation inside a pushed subfolder can leave the parent's listing
  stale** until a transition re-lists. Real but cosmetic; the store is never
  stale, only the parent's cached rows.

## Design decisions — each with the alternative and why it lost

Flagged ⚑ = most worth overruling.

1. **The file system is the library's single truth — no library index.**
   Alternative: a `library.plist` naming members (one fast read, GoodNotes-
   style central metadata). Lost because an index is duplicated truth plus a
   new fatal-dangling-ref class; the tree cannot disagree with itself.
   Consequence accepted: per-item stats at listing time.
2. ⚑ **Display name = directory name.** Alternative: name inside
   `document.plist` (frees names from FS constraints, survives weird
   characters). Lost because enumeration would read every package at open.
   Cost: sanitization gate, byte budget, and the case-sensitivity divergence
   (simulator cannot witness the device's case-sensitive volume — in
   `Unproven.md`). Overrule this if names-with-slashes matter more than
   open-without-reading.
3. ⚑ **Favorites are path-keyed, prefix-rewritten on move/rename.**
   Alternative: `documentID`-keyed (survives moves free). Lost for asymmetry
   — folders have no ID. Cost: a crash between move and rewrite prunes
   favorites (licensed, stated). Overrule if lost stars ever bite.
4. **Modified date derived from four interior stats** (licensed exception in
   L1). Alternative: a durable `modifiedAt` in the index — rejected as a
   second copy and an index rewrite per save. Cost: layout knowledge leaks
   one level up behind one named constant.
5. ⚑ **Retain-if-dirty close** (never release a dirty session; block opens).
   Alternative: block the Back transition until saved (simpler mental model,
   but a full disk imprisons the user in the editor). Overrule only with a
   design that keeps both properties; releasing dirty ink is not on the
   table.
6. **Duplicate keeps the source `documentID` tonight** (`KNOWN DEFECT:` at
   the copy site). Alternative: rewrite through a second store — correct but
   a two-store choreography built at 3 a.m. Nothing library-level keys on
   the ID today.
7. **Trash lives behind the toolbar ellipsis menu** — the knock-on of
   cutting the avatar/gear; nearest honest home to iPad GoodNotes' gear→Trash.
8. **Move preserves the modified date; folders sort by their own mtime** —
   deliberate deviations from GoodNotes behaviors its own users report as
   bugs (both in the proposal's §6).
9. **Thumbnails are in-memory only, ink-only, re-rendered per launch.** The
   disk cache GoodNotes surely has is banned by *Forbidden patterns*, and
   the review killed the loophole; the cost is a per-launch decode masked by
   placeholders. If a measured device cost ever hurts, that measurement is
   the argument the next amendment needs.
10. **A starred folder opens inside Favorites' own stack** (sidebar stays on
    Favorites). Spec silent; smaller machine. GoodNotes' real behavior
    unobserved — flip it if a device session shows otherwise.

## Blockers

None that stopped work. Two near-misses worth knowing:

- Two lanes were each green alone and broke the build together (a popover
  gained a parameter while a new call site was written without it). Caught
  at the integration choke; fixed in `fb81099`. Same class again at F+G
  (star moved while the cover changed) — resolved in the merge commit.
- Worktrees cut for lanes did not always start at the branch tip; every lane
  was instructed to verify and fast-forward first, and all did. Watch for it
  in any follow-up lane.

## Contract deviations and disagreements — the map to `Contract.proposed.md`

The amendment text lives in the **L-series** at the end of
`Docs/Contract.proposed.md` (all five now FORCED); dispositions in
`03-review.md`. What the morning reader needs:

- **L1** (Owners rows; two-store boundary; the stat exception; the adoption
  license) — the stat exception is the seam most worth your eye: it is
  layout knowledge leaking upward, accepted out loud.
- **L2** (file-I/O confinement stated in the contract) — note it is an
  *addition*; the sentence it generalizes never existed in `Contract.md`,
  only in CONTRIBUTING and the test's prose, both updated in the same diff.
- **L3** (the library durable form) — carries the two licensed adaptations:
  sidecar defaults (enumerated inline) and collision auto-suffixing.
  **This is the amendment that partially repeals "nothing is replaced with
  a default" at the library level.** If you reject the license, the code to
  change is the name gate and the sidecar readers, not the tree design.
- **L4** (close) — written to match what the code now does, including the
  failure branch. Adopt only alongside its device evidence.
- **L5** (the browser; the licensed thumbnail reader) — the read-only
  per-package `DocumentStore` used outside any editor session is the one
  place a *Lifecycle* sentence is being scoped rather than obeyed literally.
- **Where I think a rule in force is now wrong rather than incomplete:**
  the *Lifecycle* sentence "the document index loads once, when the editor
  session is created" was written as a performance rule for one document,
  but reads as an exclusivity rule the moment anything else has a legitimate
  reason to read an index. L5 scopes it; the cleaner fix is rewording the
  original sentence to say what it always meant: *the editor session loads
  its index once and never re-reads it while live*. That is Phillip's
  edit to make, not mine.
- **A15 note**: this run neither needed nor touched the CoreGraphics
  question; the thumbnail renderer deliberately sits in the app target so
  `TuberRender`'s policy stayed closed.

## What a human must check by hand (the ten-minute walk)

In the pinned simulator (or better, the iPad — `EditorSession.swift` changed,
so device evidence is *required* for the close path):

1. Launch. You should see "Just a Canvas" in the grid — your pre-library
   document, adopted. Open it; your ink is there; draw a stroke; tap the
   circular Back. Reopen: the stroke survived. Its thumbnail now shows ink.
2. + New → Notebook → name it → check. It opens; Back; its cell is in the
   grid, dated now.
3. + New → Folder → pick a color and icon → check. Enter it: the sidebar
   must NOT move; centered small title; back chevron; the designed empty
   state with no button. Create a notebook inside; back out; the folder cell
   shows.
4. Chevron on any document: rename inline (try an illegal name — `a/b` — it
   must refuse in place); Duplicate (suffix appears); Move into the folder
   (drill-down, Move Here).
5. Chevron → Move to Trash. Ellipsis menu → Trash: the item is there;
   Recover it (it returns where it was); trash it again; Delete Permanently
   (confirms); + Empty on another item (confirms).
6. Star two items; sidebar → Favorites: both there, mixed kinds, no + New.
   Un-star one from Favorites.
7. Four-squares: switch List (rows with disclosure chevrons on folders
   only); sort by Name; re-tap Name (direction flips); relaunch the app —
   sort and view survived.
8. All chip → Folders (documents vanish); search magnifier → type a
   fragment (current folder only).
9. Four-squares → Select Items: Select All, batch Move to the folder, Done.
10. + New → Import → pick a PDF: it opens with a blank first page and the
    PDF after it (the known wart); Back; its cell shows.

Feel — popover sizes, tap targets, push animation, thumbnail pop-in — is
your verdict, not this document's.
