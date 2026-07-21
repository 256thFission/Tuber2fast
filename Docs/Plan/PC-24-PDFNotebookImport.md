# PC-24 — PDF import as a notebook

Status: **implementation complete — static checks passed; device delivery prohibited by override**

Target branch: `main`

Owner: Notebook document model and library import. App integrates; SpatialCanvas
retains Pencil and coordinate ownership.

Parent: `Docs/Plan/PLAN.md` § Textbook citation demo (PC-24 … PC-29)

## Objective

Let a user import a PDF from the system picker and receive an ordinary notebook
whose pages carry the PDF page as their visible background. This is the setup
beat of the recorded demo: the textbook must enter the product as a notebook
like any other, not as a special document type.

User-visible outcome: `Import PDF` in the library produces a notebook that turns
page to page, renders the chapter, and accepts ink on top.

## Files and subsystems in scope

- `TuberNotes/Notebook/NotebookStore.swift` — a PDF branch beside `importSPUD`
- `TuberNotes/Notebook/LibraryView.swift` — second import affordance and error path
- `TuberNotes/Notebook/Notebook.swift` — read-only use of `PlacedImage` / `NotebookPage`

## Design decision

Each PDF page becomes a `.plain` `NotebookPage` carrying one full-bleed
`PlacedImage`, with the notebook's page lock enabled via the existing
`NotebookSettings.showsPageLock`.

Rationale: this is the smallest change that proves the milestone (`AGENTS.md`
§ Rules) and leaves `DocumentContracts.PageBackground` untouched, so no
`CONTRACT:` prefix is required. The accepted tradeoff is that an unlocked
textbook page can be dragged like any placed image; page lock covers it.

Rejected alternative: a new `PageTemplate` or page-background case. Correct
long-term, but it touches a shared contract and the document render path for no
demo-visible gain.

## Non-goals and dependencies

Non-goals: text reflow, on-page text selection, mixing PDF and blank pages in one
notebook, page reordering inside an imported PDF (`SPEC.md` § 1 decision 6),
import progress UI, thumbnail regeneration performance work.

Dependencies: none. This thread starts the chain.

## Ordered work

1. Add a PDFKit-backed import to `NotebookStore` producing one page per
   `PDFPage`, rasterized at a resolution legible at final video capture size.
2. Enable page lock on notebooks created by this path.
3. Add the library affordance and a distinct failure message for an unreadable
   or empty PDF.
4. Device preflight, signed Release build, install, normal launch on the pinned
   iPad; import the demo chapter and page through it.

## Acceptance evidence and stop conditions

- A chapter PDF imports in the normal Release app on iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`.
- Pages turn in both directions; page count matches the source PDF.
- Ink lands on top of the page background and stays on its originating page
  across a page turn and return.
- Evidence packet per `Docs/templates/EvidencePacket.md`; artifacts under
  `tmp/verify/pc24-pdf-notebook-import/`.

Stop when the above is collected and Phillip's normal-app verdict is requested.
Do not proceed into corpus extraction (PC-25) in the same session.

## Session log

- 2026-07-21 — Implemented the smallest PDFKit-backed notebook import on
  `main`: one `.plain` `NotebookPage` per readable PDF page, one normalized
  full-page `PlacedImage` per page, an explicit visible page-lock control, a
  separate library PDF picker, and distinct empty/unreadable PDF messages. No
  shared contract changed; corpus extraction, OCR, Debug scenarios, and test
  tooling remained out of scope. `git diff --check` passed. A named-device
  preflight had passed and a signed Release build had started, but the
  coordinator then applied an immediate implementation-only go-mode override:
  never use Release, device, or human-review tooling. The build was cancelled
  before install or launch and is recorded as `BUILD INTERRUPTED`, not as a
  pass or failure. Artifacts are under
  `tmp/verify/pc24-pdf-notebook-import/`. Normal-app import, page-turn, page
  count, ink persistence, layout, crash, and Phillip-verdict evidence remain
  uncollected by instruction.
- 2026-07-21 — Wave 1 implementation started on `main`. Device delivery is
  serialized by the coordinating thread; no Debug scenario or fixture route
  will be used as acceptance evidence.
- 2026-07-21 — Created for the recorded textbook-citation demo. Not started.
