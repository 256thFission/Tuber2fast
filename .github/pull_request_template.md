<!--
Does this relate to something written in Docs/Queue.md? Name it if so, and
update or remove that entry in this PR — otherwise leave this blank. Say what
evidence you have — and what you don't.

Anything found and not fixed gets recorded before you stop: a defect goes to
the code as a KNOWN DEFECT: block at its own site; a claim you could not prove
goes to Docs/Unproven.md.
-->

**Queue item (if any):**

**What this changes:**

**What is NOT proven by this PR:**

---

### Device evidence

Green CI means it compiles and the tests pass. It says nothing about how the
app feels, and the simulator has no Apple Pencil at all.

**Required** when this PR touches any of:

- `Modules/TuberCanvas/PageCanvasController.swift`
- `Modules/TuberCanvas/PagedCanvasController.swift`
- `TuberNotesApp/EditorSession.swift`
- `TuberNotesApp/EditorLifecycle.swift`

**Not required** for `DocumentStore`, `DocumentIndex`,
`PageGeometry`, `CanvasLog`, tests, docs, or tooling — correctness there is
settled by a test.

- [ ] Not required — this PR touches none of the files above
- [ ] Exercised on a physical iPad, described below
- [ ] Required but **not** done — say so here, and add it to `Docs/Unproven.md`

<!--
If you exercised it: which iPad, which iPadOS, and what you actually did.
"Wrote on three pages, turned back and forth, force-quit, ink survived" beats
"tested on device".

Pencil feel, stroke fidelity, palm rejection, and pan/zoom quality remain a
maintainer's verdict. Record what you saw; leave the verdict alone.
-->
