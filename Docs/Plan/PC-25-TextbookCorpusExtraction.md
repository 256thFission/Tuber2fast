# PC-25 — Textbook corpus extraction and persistence

Status: **implementation complete — focused host checks pass; Phillip feedback deferred**

Target branch: `main`

Owner: Knowledge (retrieval). Notebook exposes the import pass; Knowledge owns
corpus shape and search.

Parent: `Docs/Plan/PLAN.md` § Textbook citation demo (PC-24 … PC-29)

## Objective

Turn an imported PDF's embedded text into a searchable corpus stored alongside
the notebook, so the product's existing textbook searcher can answer against a
book the user actually imported rather than a bundled fixture.

User-visible outcome: none directly. This thread exists to make PC-26 truthful.

## Files and subsystems in scope

- `TuberNotes/Knowledge/KnowledgeSearching.swift` — corpus loading and lookup
- `TuberNotes/Notebook/NotebookStore.swift` — emit the corpus during PC-24's import pass
- `TuberNotes/App/Contracts/KnowledgeContracts.swift` — read-only

## Design decision

Extract `PDFPage.string` during the same import traversal as PC-24 and persist
`[OfflineKnowledgePage]` as JSON beside the notebook file, with
`documentID` = the notebook's UUID, `pageNumber` = the 1-based PDF page index, and
`documentTitle` = the notebook title.

`OfflineTextbookKnowledgeSearcher(corpusData:)` already decodes this shape. Its
internal validation now permits a present empty array so an image-only imported
book truthfully produces zero hits; malformed and invalid non-empty corpora are
still rejected. This is not a shared-contract change and needs no `CONTRACT:`
prefix.

`sectionTitle` is best-effort: derive from a running-header heuristic where one
is available, otherwise nil. A nil section degrades the citation chip's subtitle
and nothing else.

## Non-goals and dependencies

Non-goals: embeddings or semantic search, OCR for scanned pages, cross-notebook
corpus merging, incremental re-indexing, corpus migration for pre-existing
notebooks.

Dependencies: **PC-24 must land first** — this reuses its import traversal.

Constraint: the demo chapter PDF must carry a real text layer. Verify before
committing to a book (PC-29 owns that check).

## Ordered work

1. Extract per-page text during import; skip pages with no text layer rather
   than emitting empty excerpts.
2. Persist the corpus beside the notebook; load it lazily on notebook open.
3. Resolve a searcher for an explicitly selected imported textbook, falling
   back to the bundled fixture only when its corpus sidecar does not exist.
4. Add a focused host check: a known ochem phrase returns the expected page
   number from the real imported corpus.

## Acceptance evidence and stop conditions

- Focused host check passes against a corpus produced by the real import path,
  not a hand-written fixture.
- Importing a text-layer PDF on the pinned iPad produces a corpus file whose
  page count matches the notebook's page count.
- Importing an image-only PDF degrades to zero hits without crashing or
  producing empty-excerpt entries.
- Artifacts under `tmp/verify/pc25-textbook-corpus/`.

Stop when the checks pass. Do not wire the tool into the live agent path here.

## Session log

- 2026-07-21 — Implemented the PC-25 corpus path in go mode. The PC-24 PDF
  traversal now passes each `PDFPage.string` through the Knowledge-owned
  extraction helper, skips nil/blank text-layer pages, preserves 1-based PDF
  page numbers, and writes `<notebook UUID>.knowledge.json` beside the notebook.
  `NotebookStore` exposes an explicit, lazy load seam keyed by the selected
  imported textbook UUID; Knowledge resolves a missing sidecar to the bundled
  fixture, rejects malformed data, and treats a present empty corpus as a valid
  zero-hit corpus so scanned imports cannot leak fixture results. The focused
  sidecar write is atomic and precedes exposing the saved notebook, so a
  throwing corpus write cannot leave an imported notebook that later falls
  through to fixture retrieval. The focused strict-concurrency host check
  passed (`PC25_CORPUS_CHECKS: PASS`) and
  `git diff --check` passed; artifacts are in
  `tmp/verify/pc25-textbook-corpus/`. No Release/device, Debug-scenario, or
  human-review tooling was run under Phillip's override. Behavioral acceptance
  remains unclaimed pending Phillip's later manual feedback.
- 2026-07-21 — Phillip explicitly started Wave 2 against PC-24's implemented
  import traversal in the shared `main` worktree while PC-24's separate
  Release/human gate remained open. Scope remains corpus emission,
  persistence/loading, and focused real-import checks only; no live agent tool
  wiring.
- 2026-07-21 — Created for the recorded textbook-citation demo. Not started.
