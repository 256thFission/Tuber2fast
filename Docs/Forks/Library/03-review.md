# The library proposal — adversarial review and dispositions

One full review cycle, per the brief. Five fresh reviewers, none of whom
authored the spec, the proposal, or the amendments, each with a distinct
lens and instructions to refute. Every finding below carries a disposition:
**FIXED** (the proposal / L-series was edited; the location is named) or
**REJECTED** (with the reasoning, kept in the record). Nothing was dropped
silently. The revised `02-proposal.md` and the revised L-series in
`Contract.proposed.md` are the post-review versions; this file is the diff's
"why".

Panel: contract compliance · durable form and failure design · UX fidelity
against the Phase 1 spec · buildability in the remaining hours · the L1–L5
amendments alone.

---

## Blockers (all fixed before any code)

### B1 — `close()` ignored the protected `startTask`; a "closed" package could take writes
Found by: contract (F1); independently by buildability (F2) and amendments (L4).
A Back during `.loading` would let the never-cancelled start task save into a
package the browser was free to rename, move, or trash — two writers under
one directory, the retirement-handover defect one level up.
**FIXED** — proposal §4 and L4: `close()` first awaits `startTask` (awaiting
protected work is legal; cancelling is not), then cancels the debounce,
awaits any save in flight, runs one final pass; the root releases the session
and the library may mutate the package only after `close()` returns.

### B2 — `load() == nil` on a library-enumerated package fabricated an empty document over user data
Found by: contract (F2); independently by durable-form (blocker 2).
"nil means first launch" was written when one hardcoded directory existed. A
package that enumerates in the browser but lacks `document.plist` (torn copy,
damaged restore) would silently get `newDocument` + save — the blank-page sin
promoted to whole documents.
**FIXED** — proposal §4: the browser's open path never takes the create
branch; a library-enumerated package whose `load()` returns nil is a refusal
(`.failed`, "this document has no index"), byte-identical afterward. Create-
on-nil remains only on the explicit New Notebook path, which creates the
directory itself. Test required: enumerable package sans index → tap →
`.failed`, directory unchanged.

### B3 — L4's Back guarantee had no branch for a failing final save
Found by: contract (F7), amendments (L4 blocker), buildability (F2).
Backgrounding survives a failed flush because the session lives to retry;
close() destroys the retrier, so "no ink newer than the last completed save
is released" was unkeepable as written.
**FIXED** — proposal §4 and L4: **a session is released only when nothing is
dirty.** If the final pass fails, `close()` does not return success: the
browser is shown but the lifecycle is retained off-screen, its existing
backoff/retry machinery keeps draining, a banner (the `save.error` pattern)
surfaces it, and opening another document is blocked until the dirty session
drains. No new save machinery; the policy is retain-if-dirty.

### B4 — L2 instructed replacing a sentence `Contract.md` does not contain
Found by: amendments (L2 blocker); contract (F8).
The confinement sentence lives in CONTRIBUTING.md and the test's doc comment,
not in `Contract.md`; and L2's normative text omitted the import-picker
allowlist entry, so it was false against the very allowlist it cited.
**FIXED** — L2 redrafted as an *addition* to *Owners*, with the import-picker
exception in the normative text, and its scope now includes the matching
CONTRIBUTING.md line and the structural test's name/doc comment.

### B5 — The thumbnail read path was an unlicensed contract violation
Found by: amendments (missing-amendment 1); contract (F4); durable-form (M7).
Rendering page 1 of a closed document reads the index, page, layers, and
possibly a 50 MB asset — outside any editor session, by an owner no rule
permitted, contradicting the proposal's own "never opens the package".
**FIXED** — proposal §3 and L5: the reader is named — **a read-only, per-
package `DocumentStore`**, constructed for the render and discarded; L5 now
licenses it explicitly and scopes *Lifecycle*'s load-once sentence to the
editor session. §1's claim is corrected to "never opens the package *to
build the cell's facts*". Refusals are negative-cached under the same bound
so a corrupt package is not re-decoded per scroll. The PDF-asset decode cost
is priced and is one reason thumbnails sit late in the build order
(paper-cover cells are the base case; ink-only renders are the frontier;
static-composite thumbnails are explicitly not tonight).

---

## Majors

### M-A — `LibraryStore` statting four interior paths contradicted L1's opaque-package rule
Contract (F3) + durable-form (blocker 1). **FIXED** — L1 now carves the
exception exactly: `LibraryStore` may **stat** the package's four well-known
interior paths for date derivation; it never opens, decodes, or writes any
file inside a package; the stat list is owned by one named constant that a
format change must update (the leak of layout knowledge is accepted and
stated, with A14 named as the dependency).

### M-B — Duplicate spanned both stores; its torn state twinned a `documentID` and its debris enumerated
Contract (F5) + durable-form (major 3) + buildability (F6). **FIXED** —
proposal §5: duplicate is a copy into `TuberLibrary/.staging/<uuid>/`
(enumeration ignores `.staging`; startup sweeps it), then one atomic
`moveItem` into place — debris can never enumerate. Tonight's duplicate
keeps the source `documentID` (nothing library-level keys on it; the map
confirms no cross-references), recorded as a `KNOWN DEFECT:` at the copy
site; the fresh-ID rewrite is a follow-up routed through `DocumentStore`.
L3's "no write order" claim is narrowed accordingly (see M-F).

### M-C — Auto-suffix on collision was the banned silent correction, unlicensed
Contract (F6) + durable-form (major 4) + amendments (missing 3). **FIXED** —
L3 gains the explicit license: suffix-on-collision (create, duplicate, move,
recover, adoption) is the one sanctioned adaptation at the library level,
alongside the sidecar-defaults license. The favorites rewrite on a colliding
move uses the **post-suffix** path (test named). Silent pruning of dangling
favorites is licensed in the same sentence.

### M-D — A folder named `*.tubernotes` swallowed its contents
Durable-form (major 5). **FIXED** — proposal §1: `.tubernotes`,
`.origin.plist`, and leading dots are reserved at the sanitization gate, with
a 255-byte budget check (suffix + collision headroom included) at the same
gate (also durable-form M3).

### M-E — Enumeration failure of a folder rendered as the empty state
Durable-form (major 6). **FIXED** — proposal §4: a listing is Result-shaped;
a thrown enumeration renders a distinct refused-folder state (message +
retry) and the designed empty state renders only on a successful empty
listing.

### M-F — L3 contradicted itself on write order; sidecar lifecycle under-specified
Durable-form (M1) + amendments (L3 major). **FIXED** — L3 now says the
*structural* step is one atomic directory operation and sidecars write after
it; Recover deletes its sidecar; Empty Trash sweeps sidecars; the origin
sidecar is named after the post-suffix trash name. The corrupt-sidecar path
sets the file aside as `.corrupt` rather than overwriting the evidence
(contract F10), and L3 names itself as the licensed exception to *Invalid
states fail loud*, enumerates the four defaults inline, defines
"orphan-class" as a definition, and drops the undefined "loudly" for
preference files in favor of a stated surface (log + non-modal banner)
(durable-form M5, amendments L3 edits).

### M-G — Ancestor rename/move silently dropped descendant favorites
Contract (F9) + durable-form (major 4b). **FIXED** — proposal §1: prefix
rewrite — on move/rename of a folder, every favorites entry with the old
path as a prefix is rewritten in the same favorites write.

### M-H — The adoption move was an unlicensed launch-time write outside the tree
Amendments (L1 major, missing 2) + durable-form (M8). **FIXED** — L1 gains
the one-sentence license (the one write outside a user action and outside
the tree, deletable when it stops mattering); adoption runs idempotently
inside `LibraryStore`'s first root listing, and a name collision at adoption
auto-suffixes under M-C's license.

### M-I — UX: the proposal specified organization, not pixels
UX findings 1–16. Sixteen findings; the pattern was one omission repeated:
observed facts never restated as commitments. **FIXED** — proposal §4/§5
gained a "Fidelity commitments" section stating: one array, one comparator,
folders and documents interleaved (Type sort alone groups folders first, per
spec §7.1) [UX-1]; the full cell anatomy — star top-right on the thumbnail
(grey outline / red filled), grey chevron-down right of the title as the
menu affordance, grey date line, two-line middle-truncated wrap with varying
row heights, refusal badge in the observed corner-fold position [UX-2];
absolute dates always, `MMM d, yyyy 'at' h:mm a`, relative forms not built
[UX-3]; the three-band + New popover layout (square tile / wide tile /
folder card) [UX-4]; the New Folder sheet verbatim — shell, live preview,
26 swatches + wheel in the 9×3 layout, Icon tab with a chosen glyph set
(contents unobserved, our decision) [UX-5]; the New Notebook sheet's
surviving skeleton — left paper preview, Name row, Size row with chevron —
with Language/Cover moved to *Deliberately not building* [UX-6]; the
NavigationStack scoped to the content column with the sidebar as a sibling
carrying its collapse toggle, and a hand-walk check that the sidebar does
not move on folder push [UX-7]; the search entry point as a top-right
magnifier, with the Trash-location knock-on moved to §6 Deviations [UX-8];
folder vs document chevron menus distinguished (Color/Icon tabs and dot row
in the folder popover; Duplicate absent on folders) [UX-9]; the select-mode
top bar (Select All / title / Done) and check-circle overlays [UX-10]; the
single four-squares menu in shot 08's order with the direction chevron on
the active key only [UX-11]; 4 columns landscape with metrics measured from
images/01 at build time [UX-12]; the empty-folder copy quoted with **no
button** [UX-13]; the Trash screen's Empty/Select/Done trio [UX-14]; the
Favorites filter's presence [UX-15]; and the chrome deviations (no cloud
icon, no Shared/Marketplace rows, no bell/avatar) added to §6 [UX-16].

### M-J — Scope honesty for the night
Buildability (F1, F3, F4, F5, F7, F8). **FIXED** — proposal §5 now carries
the reviewed build order (three parallel lanes, integration choke, ordered
frontier) and tonight's honest versions: move picker as drill-down sheet
(same semantics, quarter the code — the expandable tree is a follow-up);
search as a filter of the current folder's in-memory listing (recursive
search would walk the tree the design promises not to walk — a later
argument); drag & drop not tonight at all; multi-select and favorites and
ink-only thumbnails strictly ordered on the frontier. **REJECTED in part**:
the reviewer's framing that full breadth was "refuted" is accepted as
scheduling but not as descoping — the target remains the full spec; the
frontier order just determines what unfinished looks like, per the brief.

---

## Minors, fixed

- L1 lifetime cell reads "browser session"; the byte bound lives at the
  cache declaration (amendments L1). The open-document row now names the
  existing SwiftUI-root row as the governing row for the transition itself.
- L5 drops "unamended"; placement in *Navigation* accepted (amendments L5).
- Modified-date derivation: the index-only save shape gets its own test;
  missing `layers/`/`assets/` dirs tolerate ENOENT; the fails-loud claim is
  scoped to the save-shape property only — external transfers and clock
  changes degrade sort order quietly and that is accepted and stated
  (durable-form M2). Enumeration cost is measured with interior stats
  included before the number is quoted anywhere (M6).
- Case-sensitivity: collision detection asks the file system (fileExists /
  actual rename result), never string-compares listings; the sim/device
  divergence goes to `Docs/Unproven.md` and the device checklist (M4).
- `03-review.md` cited-but-absent (amendments preliminary): this file. The
  citation preceded the artifact by a few hours; recorded, not disputed.

## Rejections (kept with their reasoning)

- **UX-4's implicit invitation to render disabled GoodNotes tiles**
  (Whiteboard, Text Doc, …) — REJECTED, with the reviewer's own concurrence:
  a menu offering document types the app does not have is lying chrome;
  omission is the honest form. The menu offers Notebook, Import, Folder in
  the observed layout grammar.
- **Durable-form M6's suggestion to prefetch interior dates via
  `includingPropertiesForKeys`** — REJECTED as a mechanism (it cannot reach
  interior paths, as the reviewer noted); accepted as a cost-honesty
  requirement (measure before quoting).
- **Amendments reviewer's option to *strike* adoption** — REJECTED in favor
  of licensing it; the alternative (Phillip's existing document invisible to
  the first library build) fails the person tapping through in the morning.
- **Contract F3's option (b)** (package-root mtime instead of interior
  stats) — REJECTED: a rename into `pages/` does not update the package
  root's mtime, so the derivation would go stale on the most common save
  shape. Option (a), the licensed stat exception, was taken instead.

## What survived every lens, for the record

Tree-as-truth with no library index; the orphan-class sidecar taxonomy; the
sibling-actor-plus-allowlist-entry answer to file-I/O confinement; in-memory-
only thumbnails with A7 correctly not invoked; page deletion staying out of
scope with the boundary argued; one-document-open-at-a-time; and the
adoption of GoodNotes' no-retention Trash. No reviewer proposed replacing
the architecture; every blocker lived at the seam where the new layer meets
single-document-era code, which is where the build's tests are now aimed.
