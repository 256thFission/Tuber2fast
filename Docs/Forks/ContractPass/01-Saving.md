# *Saving*, made true — proposed wording

**This is not the contract.** `Contract.md` is. No agent authors a rule; this
file is proposed wording for Phillip to edit, cut, or adopt. Adopting it means
moving the text into `Contract.md` in a commit tagged `CONTRACT:`.

Stage 1 item 3 of `Docs/Forks/CanvasCompleteTodo.md`. Two statements in
*Saving* are false against the code, and both are first-rank durability
semantics. Line references verified against `Contract.md` and the sources on
2026-08-07.

---

## Falsity 1 — a thrown save is not all-or-nothing

### What is there now

`Contract.md:139`, the second bullet of the *Durability is strict* list:

> - a save that throws is not acknowledged, and its pages stay dirty; and

### What the code does

`DocumentStore.save` plans every page before writing any page
(`DocumentStore.swift:620-643`), and a refusal is scoped to the page that
caused it, never the batch. Pages that plan cleanly are written first; the
refusal is thrown afterwards, carrying every refused page and whether the
index landed (`DocumentStore.swift:692-714`, `PageSaveRefusal` at `:725-740`).
`EditorSession` acknowledges accordingly: on `DocumentStore.PageSaveRefusal`,
every captured page the refusal does not name takes the same `saveSucceeded`
path a fully successful pass would give it, and only the named pages go back
to `held(.serialized(…))` (`EditorSession.swift:1209-1231`). The index returns
to dirty only if it was dirty at capture and did not land (`:1229`).

Every other thrown error keeps its all-or-nothing behaviour
(`EditorSession.swift:1232-1242`) — the current bullet is true of that path and
only that path.

Covered end to end, through the session and against real files:
`TuberNotesTests/ImageLayerTests.swift:562-625` (an unknown-kind layer poisons
one page; a neighbour's ink still becomes durable) and `:627-686` (two
missing-asset layers, refusal per page, deletion as the repair). Store-level
coverage of the refusal itself: `LayerEnvelopeTests.swift:314-352`,
`ImageLayerTests.swift:150`, `:183`, `:551`, `PDFLayerTests.swift:672`.

## Falsity 2 — dirty has two axes, the pseudocode models one

### What is there now

`Contract.md:113-128`, the `saveIfNeeded` block:

> ```text
> guard dirty is non-empty && no save is in progress
> capture every dirty page: a live page yields its drawing, a page that has
>   left the live window yields the value it handed over as it retired
> capture is total — a dirty page yielding neither is a violation, not an omission
> mark the captured pages saving — this replaces clearing the dirty set
> create drawingData outside the PencilKit callback
> record the serialize duration; it sets the next debounce interval
> await DocumentStore.save(page files, then the index if it changed)
> on success, mark clean only the pages not edited since their capture,
>   and clear the retry backoff
> on failure, the captured pages stay dirty holding the bytes already
>   serialized — the retry never encodes twice; report the error and
>   reschedule after the backoff
> if still dirty, arm a fresh debounce rather than serializing again immediately
> ```

### What the code does

`Page.isDirty` is two axes, not one (`EditorSession.swift:135-144`):
`layersUnsaved` — the page's layer list differs from the list the last
successful save wrote (`:94-97`) — or an `ink` state of `.live`/`.held`. A
page can carry either, both, or neither.

The capture honours both. A page whose ink is `.clean` but whose list is
unsaved is still captured, with its *durable* bytes as the ink, because a page
file is written whole (`EditorSession.swift:1045-1065`, and the matching
`precondition` in `beginSaving`, `:254-263`). Acknowledgement is also per axis:
ink becomes clean only if the page is still `.saving`, and the list only if it
still equals the list that was written (`:286-293`).

There is a third dirty axis at document scope that the pseudocode's `guard`
depends on and does not name: `indexDirty`, set by an append or a page turn.
Session `dirty` is `indexDirty || pageStates.contains(where: \.isDirty)`
(`EditorSession.swift:430-432`), so an index-only save is a real pass whose
page writes are all no-ops.

---

## Proposed replacement

Two edits to *Saving*. Nothing else in the section changes.

### Edit 1 — replace the pseudocode block (`Contract.md:111-128`) and add the paragraph that precedes it

> A page is dirty on either of two axes: its ink — `live` or `held` — and its
> layer list, which is unsaved while it differs from the list the last
> successful save wrote. A page carries either, both, or neither, and one pass
> writes both, because a page file is written whole. The document is dirty on a
> third: page order and the current page index, which live in the index rather
> than in any page.
>
> `saveIfNeeded` is serialized:
>
> ```text
> guard something is dirty && no save is in progress
> capture every dirty page's whole generation at one instant — its unsaved ink
>   and the layer list that ink belongs to:
>     ink live  -> its canvas's drawing
>     ink held  -> the value it handed over as it retired
>     ink clean, list unsaved -> the page's durable bytes, because the file is
>       written whole and the ink already on disk is the ink to write it with
> capture is total — a dirty page yielding nothing is a violation, not an omission
> mark the captured pages saving — this replaces clearing the dirty set
> create drawingData outside the PencilKit callback
> record the serialize duration; it sets the next debounce interval
> await DocumentStore.save(page files, then the index if it changed)
> on success, acknowledge per axis: a page's ink becomes clean only if nothing
>   edited it since its capture, and its list only if the list still equals the
>   one written; clear the retry backoff
> on a per-page refusal, acknowledge every page the refusal does not name
>   exactly as success would, and keep only the refused pages dirty holding the
>   bytes already serialized; the index goes back to dirty only if it was dirty
>   at capture and did not land
> on any other failure, every captured page stays dirty holding the bytes
>   already serialized — the retry never encodes twice; report the error and
>   reschedule after the backoff
> if still dirty, arm a fresh debounce rather than serializing again immediately
> ```

### Edit 2 — replace the second durability bullet (`Contract.md:139`)

> - a save that throws is acknowledged only for what it proves it wrote.
>   `DocumentStore.save` decides every page before writing any, and refuses per
>   page rather than per batch: the pages a refusal does not name were written
>   and are durable, and they are acknowledged clean exactly as a successful
>   pass would acknowledge them. Only the refused pages stay dirty, and the
>   refusal is surfaced. Any other throw acknowledges nothing and every captured
>   page stays dirty. A refused page is never named by an index that would leave
>   it dangling; the store withholds the index write instead and says so;

---

## Why the code's behaviour is the right side

Because the contract's version asks the save path to lie in the direction that
loses ink. One page a build cannot rewrite — an unknown layer kind from a newer
build, a dangling asset ref — is a permanent condition, not a transient one. If
its refusal condemns the batch, then for as long as that page exists no other
page's ink is ever acknowledged, every retry re-encodes the whole dirty set,
and the pages that did nothing wrong are held dirty against a write that
already succeeded. The user's next crash loses their real work to somebody
else's poisoned page.

Partial acknowledgement is the stricter reading of the same principle, not a
relaxation of it. *Acknowledgement follows evidence*: the evidence is per file,
because every individual write is atomic and there is no atomicity across files
(*Durable form*). A page whose bytes are on disk is clean, and calling it dirty
is as much a false statement about durability as calling an unwritten page
clean — it is merely the false statement that wastes work instead of losing it.
The refusal stays loud: it is thrown, it names its pages, and it is surfaced in
`lastSaveError`.

The two-axis correction is the same kind of fix. One axis in the text and two
in the code is exactly the gap a contributor closes in the wrong direction —
by "simplifying" the clean-ink-unsaved-list capture out of `beginSave`, which
silently drops an import.

---

## Residual questions — Phillip's

1. **The third axis.** The proposed paragraph names `indexDirty` as document
   scope without giving it a state name. Is that enough, or should the index's
   dirty bit get the same treatment page ink got in *Owners* ("each page has
   exactly one ink state…")?
2. **Refusal repair is unstated anywhere.** A refused page stays dirty and
   refuses forever until the offending layer is deleted; the tests treat
   deletion as *the repair* (`ImageLayerTests.swift:679-685`). Should *Saving*
   or *Durable form* say that a refused page has exactly one repair, or does
   that belong to the failure taxonomy (stage 1 item 5)?
3. **The retry against a permanent refusal.** A page-scoped refusal still
   increments `consecutiveSaveFailures` and arms the backed-off retry
   (`EditorSession.swift:1231`, `:1255-1257`), so a poisoned page keeps the
   editor re-saving at the five-second cap indefinitely, and the innocent pages
   are clean so each retry writes nothing. Correct, or should a refusal that
   cannot change without an edit stop retrying? This is behaviour, not wording —
   if it should change, it is stage 2 code and this text should not bless it.
4. **Overlap with the drift list.** Stage 1 item 4 carries "immediate saves
   bypassing the ink debounce" — `deleteLayer` awaits `saveIfNeeded` directly.
   The layer axis is now named in *Saving*, so its trigger wants a sentence
   somewhere. Kept out of this proposal deliberately to avoid two passes writing
   the same paragraph; say which pass owns it.
5. **Voice.** The pseudocode block gained an indented three-case list. If the
   flat imperative line is the register you want kept, the three cases collapse
   to one sentence at the cost of naming the clean-ink case explicitly — which
   is the case that was missing.
