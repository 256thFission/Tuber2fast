# Proposed: `## Failure` — the classifier

Stage 1 item 5 of [`CanvasCompleteTodo.md`](../CanvasCompleteTodo.md);
`failure-has-a-taxonomy` in [`Queue.md`](../../Queue.md). An agent proposes
the exact wording; **Phillip authors the rule** — nothing here is in force
until it is in `Contract.md` under a `CONTRACT:` commit.

Neither `Docs/Contract.md` nor `Docs/Contract.proposed.md` was touched by
this pass. `Contract.proposed.md` stages nothing about failure, so this
section collides with no amendment.

**Where it goes.** After *Undo* and before *Performance*. *Failure* is a
cross-cutting rule about how code is written here, not a domain section, and
it is the mechanism the preamble's *Invalid states fail loud* has never had —
so it wants to sit with the other cross-cutting sections, ahead of *Forbidden
patterns*, which it partly explains.

---

## The proposed section

Everything between the markers is the paste. It is the contract's voice, not
this file's.

<!-- BEGIN PASTE -->

## Failure

Every failure gets exactly one answer, and the answer is not a matter of
taste. Ask these in order and take the first yes:

1. **Could correct code produce this?** If no — trap. `precondition` or
   `preconditionFailure`, at the site that can see it. The state is
   impossible, so the process is already wrong about itself and nothing it
   does next is supervised. A trap costs a launch; a survived invariant
   writes the corrupted document.
2. **Is ink unsaved, unreadable, or about to be overwritten?** — alarm the
   person holding the iPad, then continue safely. They are the only one who
   can act, and the actions are theirs alone: stop writing, wait, relaunch,
   copy the page out. The alarm is on screen. A log is not an alarm.
   *Continue safely* means the affected page refuses input rather than
   pretending; a page that takes ink it cannot keep is the failure, not the
   report of it.
3. **Would a caller act differently knowing?** — throw a typed error and let
   the caller re-ask. Typed, so the caller branches on the cause rather than
   on a string, and so adding a cause breaks every place that must decide
   about it.
4. **Otherwise it is an event, not a failure.** `CanvasLog.event` and
   continue. An outcome nobody would act on is an ordinary outcome, and it
   is written as one.

**There is deliberately no bucket for a failure that is logged and continued
from.** Anything logged and continued from has answered question 4 — it is
an ordinary outcome, and the sentence beside it says which ordinary outcome
it is. If it is not one, one of the first three answers applies. Log-and-
continue is how a wrong classification stops being visible: the record is
written and the program then behaves exactly as it would have without it,
so the defect ships with a receipt nobody reads.

**A failure is never answered by substituting a value.** Not a default, not
an empty collection, not a permissive `true`, not a blank page. A
substituted value is question 1 answered wrongly and silently: it turns an
impossible state into a plausible one and hands it downstream.

**Traps are `precondition`, never `assert`.** `assert` is removed under
`-O`, and every distributed build is `-configuration Release`, so a check
only `assert` performs has never run in the build anyone holds. There is no
loud path for the developer and a quiet one for the user.
**`-Ounchecked`, which removes `precondition` too, is forbidden.**

**`try?` is banned.** It answers every failure with the same nothing, which
discards the only thing a typed error carries — which failure it was — and
then substitutes a value, which the rule above forbids. Where a call
genuinely cannot fail meaningfully, `do`/`catch` says so in two lines and
survives the next edit. The ban is machine-checked with an empty allowlist.

**A failure that reaches a person carries a typed value and is rendered by
one exhaustive `switch`.** `String(describing:)` on an error is a
developer's sentence shown to a user. The exhaustive switch is the mechanism
that forces a human sentence per case and refuses to compile when a case
arrives without one.

<!-- END PASTE -->

---

## The four categories against the code we have

Each category with sites that already exemplify it, then the sites the
classifier reclassifies. Line references are against `f8a06df` and drift.

### 1. Trap — correct code could not produce this

- **`EditorSession.Page.beginSaving`** (EditorSession.swift:265-271). A page
  captured while already `.saving` traps, quoting the invariant it violates:
  "there is never more than one capture/save operation in flight." The whole
  `Page` transition set (EditorSession.swift:171, :198, :208, :220, :241,
  :267) is the model — every impossible transition traps, and the message
  names the rule rather than the symptom.
- **`PageSpaceTransform.containsUnitSquarePoint`** (LayerEnvelope.swift:129).
  Its own comment already argues question 1 in prose: it traps on a singular
  transform "rather than answering `false`, because a layer on a page has
  already been validated as invertible and a `false` here would read as *the
  user missed it*." A substituted value would be indistinguishable from a
  real answer. That is the reasoning the classifier generalizes.
- Also correct, and worth naming so nobody re-litigates them: the
  `init(coder:)` `fatalError`s (PagedCanvasController.swift:178,
  PageCanvasController.swift:225) are Swift's required unreachable
  initializer, and `EditorSession.alignedWithIndex` (EditorSession.swift:583)
  checks an invariant after every mutation so drift traps at its cause.

### 2. Alarm — ink is unsaved, unreadable, or about to be overwritten

- **The refusing page placeholder** (EditorSession.swift:609, with
  `refusalMessage` at :733-752). A page whose bytes or layers cannot be read
  is shown, refuses input, and says why. The alternative — render it blank —
  is the overwrite question 2 exists for: the first save replaces a page that
  merely could not be read with one that is genuinely empty (*Lifecycle*).
- **The save-failure banner** (`lastSaveError`, EditorSession.swift:1240,
  rendered at RootCanvasView.swift:198). Ink is on screen and not on disk;
  the retry backoff is running; only the person can decide to stop writing.

### 3. Typed error — a caller would act differently knowing

- **`DocumentStore.PageSaveRefusal`** (DocumentStore.swift:730-741) is the
  reference case. The caller acts on it in a way no untyped error permits:
  every page the refusal does not name was written and is acknowledged
  clean, and only the named pages stay dirty holding their already-serialized
  bytes (EditorSession.swift:1209-1230). `indexWritten` is a second field the
  caller branches on.
- **`LayerError.refusedLayerOnSave` / `.refusedLayerWouldBeLost`**
  (LayerEnvelope.swift:426, thrown from the planner at
  DocumentStore.swift:765 and from `refuseIfUnrewritable` at :889). The
  caller re-asks by not saving that page, which is exactly
  *Durable form*'s "a save of a page carrying one is refused."
- **`RefusedLayer.Reason` plus the exhaustive `refusalMessage` switch**
  (EditorSession.swift:733) is the shape the last rule of the section asks
  every other user-facing failure to copy. Its four sentences are marked
  PROVISIONAL in the code and are Phillip's to write.

### 4. Event — nothing failed

- **`DrawingSnapshot.serialized`** (DrawingSnapshot.swift:47) logs bytes,
  duration, and `mainThread=`. Nothing failed; it is evidence for a rule.
- **Reclamation skipped while a layer list is unsaved**
  (EditorSession.swift:1676). This is the discriminating example, because it
  reads like log-and-continue and is not: an unreclaimed file is an orphan,
  and by *Durable form* "a dangling page ref is fatal; an orphan is not."
  Nothing was lost, so nobody acts, so it is an event — and the log line says
  precisely that ("its files stay as inert orphans"). Contrast the sites
  below, where the log line describes a loss and the program shrugs.

---

## What the taxonomy reclassifies — stage-2 work

### R1. The ten fail-open optional closures at the session/runtime seam

Stage 2 item 10. Eight on `PagedCanvasController`
(PagedCanvasController.swift:59, :88, :102, :106, :116, :121, :124, :128),
two on `PageCanvasController` (PageCanvasController.swift:31, :128). They
fail open two ways, and the taxonomy answers both the same:

- **Five substitute a value** — `staticLayersForPage ?? []`
  (PagedCanvasController.swift:297, :545), `projectionForPage ?? .canonical`
  (:332, :501), `contentForPage ?? .blank` (:465), `onLayerTransformed ?? true`
  (:533, PageCanvasController.swift:1062). Directly against *A failure is
  never answered by substituting a value*. `contentForPage ?? .blank` is the
  emblem and is worse than a taste violation: an editable blank canvas is the
  exact state *Lifecycle* forbids, wired in as the nil default.
- **Five silently drop the call** — the `?.()` sites, of which
  `onPageRetiring?(index, page.drawingSnapshot())`
  (PagedCanvasController.swift:434) is the dangerous one: an unwired handover
  loses a page's ink with no trace, against *Navigation*'s synchronous
  handover. A dropped call is a substituted value whose value is "nothing."

Classification: an unwired seam in a hosted runtime is **question 1** —
correct code cannot construct a runtime with no session. So the answer is
not a `precondition` at each of the ten sites; it is removing the state, per
stage 2 item 10: a required protocol the runtime cannot be constructed
without, making the seam's failure a compile error. The nil defaults exist
only so tests can host the runtime without a session, and the taxonomy
answers that too — the test host implements the protocol explicitly rather
than production failing open on its behalf.

### R2. The lens image path's three stacked `try?`

`StaticLayerRenderer.swift:313-315` collapses three distinguishable causes —
the payload will not decode, the format is unrecognized, the asset is missing
from disk — into one `.refused("could not decode for the lens")`. Banned
outright by the `try?` rule, and the collapse is the reason the rule exists:
`RefusedLayer.Reason` already has `missingAsset` and `unsupportedAssetFormat`
as separate cases with separate sentences (EditorSession.swift:733-752), so
the information is thrown away one layer below the code that wants it.
Reclassify to **question 3**: a typed error carrying the cause, rendered by
the existing exhaustive switch.

### R3. `DocumentStore.deleteOrphanedPages`

`DocumentStore.swift:894-903`, two `try?` and no caller anywhere. Queue.md's
disposition stands and the taxonomy confirms it: an orphan is inert by
*Durable form* and nothing has ever needed pruning, so **delete the method
rather than fix it**. It is also what would otherwise make the `try?`
allowlist non-empty on day one, and an allowlist with an entry is a rule with
an exception.

### R4. `String(describing: error)` reaching the screen

EditorSession.swift:563 (session start), :784 (page load), :1240 (save
failure); RootCanvasView.swift:74, :135, :152 (import). These are correctly
classified as **alarms** — the category is right and the payload is wrong.
Each carries a developer's description to a user's eyes, and the last rule of
the section reclassifies the payload: a typed value plus one exhaustive
`switch`, copying `RefusedLayer.Reason` / `refusalMessage`.

One decision rides along: `DocumentStore.PageRefusal.reason` is a `String`
by choice, and its doc comment (DocumentStore.swift:717-723) argues "the
caller's use is reporting, and the repair is a later edit, not a branch on
the cause." That argument holds for the *store's caller* and stops holding
the moment the string reaches a person at EditorSession.swift:1240. Decide it
when R4 lands; the two ends can differ, but not by accident.

### R5. The sub-83-point trap in `establishZoomIfNeeded`

`PageCanvasController.swift:480-485`, and stage 0 item 1 already. The
taxonomy is what makes the disagreement legible: question 1 asks whether
correct code could produce this, and today it can — import takes the source
box verbatim and persists it before first layout, so a receipt reaches the
trap through an ordinary path and bricks the document on every subsequent
open. The right answer is a **typed refusal at import** (question 3), after
which the `precondition` at :480 is a true invariant and stays. The comment
at :474-479 currently says "a page this build refuses rather than rounds"
one line above the crash that is not a refusal; the taxonomy makes that
sentence checkable rather than aspirational.

---

## Enforcement

Two halves of this section are machine-checkable and belong in
`ContractStructureTests` alongside the file-I/O and `PKCanvasView` rules,
which is where the todo's stage 2 item 8 already expects the `try?` ban to
survive the module split:

- **`try?`** — token scan, empty allowlist. R3 clears the two occurrences
  that would need one; the remaining two (EditorSession.swift:937, :1169) are
  `try? await Task.sleep`, which the section's own sentence sends to a
  two-line `do`/`catch`. The existing checker already strips comments and
  strings, so prose naming the token does not trip it.
- **`assert(` / `assertionFailure(`** — same shape, empty allowlist; and
  `-Ounchecked` absent from `project.yml` and `Local.xcconfig` is a
  build-settings assertion, not a token scan.

The other three rules — the ordered questions, the missing log-and-continue
bucket, the typed user-facing value — are review-and-taste rules. Say so;
the project's habit is to name what is checked and what is merely believed
([`Unproven.md`](../../Unproven.md)).

---

## Scope, honestly

**This is the authoring half only.** The classifier and its contract section
need no device, which is why stage 1 item 5 knowingly overrides Queue.md's
"*Blocked by:* `loud-by-default`" — Queue.md invites that when the ordering
no longer holds, and for authoring it no longer holds.

What still waits on hardware, and stays in stage 4's device backlog:

- `failure-has-a-taxonomy`'s stated exit — a hand-corrupted page file
  producing a page that says so and refuses ink. Its user-visible half needs
  no Pencil and is provable in the simulator; the trap-observation half is
  not.
- **Trap observation**: nobody has yet watched a real trap on a real iPad
  arrive through `Tools/device`'s fixed digest. That is `loud-by-default`'s
  own exit, and until it is met, "trap" is a category this document can
  define and this project cannot yet prove it will hear. Adopting the
  section does not close it.

Nothing above records a verdict on Pencil feel, and nothing above claims
device evidence it does not have.
