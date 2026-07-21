# PC-26 — Live `search_textbook` in the normal agent path

Status: **implementation complete — awaiting Phillip's manual verdict**

Target branch: `main`

Owner: App — the in-product AI boundary (`AgentInsight`). Knowledge owns the
search itself and is called, not modified.

Parent: `Docs/Plan/PLAN.md` § Textbook citation demo (PC-24 … PC-29)

## Objective

Let the shipping sidebar agent search an imported textbook and answer from what
it retrieved. Today `search_textbook` exists as a product tool name and a working
searcher, but the live path in `AgentInsight.swift` advertises only `place_pins`
and `switch_page`; the tool is only ever replayed by the scripted `AgentClient`
fixture.

User-visible outcome: asking **Explain** on a worksheet problem produces a
truthful "Searching …" tool chip and an answer containing chapter content the
model was not otherwise given.

## Files and subsystems in scope

- `TuberNotes/Notebook/AgentInsight.swift` — tool declaration (~line 373),
  decode (~line 401), instruction text (~line 342), and the turn loop
- `TuberNotes/Notebook/NotebookViewModel.swift` — tool-call routing (~line 1154)
- `TuberNotes/Knowledge/KnowledgeSearching.swift` — called only

`ProductToolName.searchTextbook` already exists in
`App/Contracts/AgentContracts.swift`, so **no `CONTRACT:` prefix is required**
unless the typed tool-result boundary must change to carry hits.

## Design decision and known risk

The current turn structure appears single-shot. `search_textbook` requires a
genuine multi-turn loop: declare → model calls → execute → return results → model
answers from them. **This loop, not the tool declaration, is the substance of this
thread.** Budget accordingly; it is the largest of the six.

Hits are returned to the model as typed tool results retaining `documentID` and
`pageNumber`, because PC-27 builds citations from those fields and must never
recover them from prose.

Search is scoped to imported textbook notebooks, never to the active worksheet.

## Non-goals and dependencies

Non-goals: `search_notebook`, parallel or nested tool calls, retrieval scoping
UI, model-visible corpus management, changes to `place_pins` or `switch_page`
validation.

Dependencies: **PC-25**. A stubbed corpus may be used for early loop development,
but acceptance requires the real one.

## Known noise

`Docs/Plan/PLAN.md` records the host suite at 87/94 with seven stale assertions,
one of which is the **tool-selection contract** this thread touches. Decide at
the start of the session whether that assertion is being repaired or explicitly
left stale, and record the decision in this log — otherwise a failure here is
ambiguous.

## Ordered work

1. Declare `search_textbook` beside the existing tools with a strict schema.
2. Implement the multi-turn tool loop with a bounded call count.
3. Route the call through the Knowledge searcher; return typed hits.
4. Surface `ToolInvocationSummary.userVisibleStatus` in the sidebar as a
   truthful, non-fabricated progress chip.
5. Device preflight, signed Release build, install, normal launch; run a real
   Explain against the imported chapter.

## Acceptance evidence and stop conditions

- In the normal Release app on iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`,
  an Explain on the demo worksheet triggers a visible search chip and returns
  chapter-specific content.
- The chip text reflects an actual invocation; no chip appears without one.
- Tool-call count is bounded; a search returning zero hits degrades to a plain
  answer rather than a stall or a fabricated citation.
- Artifacts under `tmp/verify/pc26-live-textbook-search/`.

Stop after evidence collection and request Phillip's verdict. Citation UI is
PC-27 and does not belong in this session.

## Session log

- 2026-07-21 — Implemented the normal-app `search_textbook` loop under Phillip's
  implementation-only go-mode override; no Release/device/human-review tooling
  was run. The request shape is bounded to three provider responses and two
  serial local searches. Each strict `{query, limit}` call is linked by
  `call_id`; because requests retain `store: false`, follow-ups explicitly replay
  validated prior output items and append a `function_call_output` rather than
  relying on `previous_response_id`. The output is a JSON encoding of the exact
  local `[KnowledgeHit]` values, which are retained on local `AgentInsight`
  alongside truthful invocation summaries; provider prose is never parsed for
  source fields. Parallel calls, model-supplied page/document scope, malformed
  arguments, nested retry after zero hits, a third search, and a fourth response
  are rejected or safely terminated. Zero hits are sent as `[]` and resolve to a
  plain provider answer or the local no-source message without hits. The normal
  factory receives one `KnowledgeSearching` resolved in `NotebookViewModel` from
  the first imported corpus sidecar excluding the active worksheet; absence uses
  the bundled fallback and malformed data fails visibly. A live invocation stays
  active through local search plus its provider follow-up and is cleared on every
  terminal path; the pending turn renders a chip only when that value is non-nil.
  Changed files: `TuberNotes/Notebook/AgentInsight.swift`,
  `TuberNotes/Notebook/NotebookViewModel.swift`,
  `TuberNotes/Notebook/PinChatComponents.swift`,
  `TuberNotes/Notebook/AgentSidebarView.swift`, and
  `DeveloperTools/AgentKnowledgeTests/PC26LiveSearchMain.swift`. Focused scripted
  checks cover typed result linkage/final answer, zero-hit termination, malformed
  and page-target arguments, parallel-call rejection, the 2/3 bounds, and no
  invocation without search: PASS. Whole-source iOS Simulator typecheck and
  strict-concurrency typecheck completed with pre-existing warnings only; Swift
  parse and `git diff --check` passed. Artifacts:
  `tmp/verify/pc26-live-textbook-search/scripted-check-run.log`,
  `scripted-check-build.log`, `swift-typecheck.log`,
  `swift-strict-typecheck.log`, and `swift-parse.log`. Scope audit: no shared
  contract, Knowledge implementation, citation UI, cross-notebook navigation,
  `switch_page`, Debug scenario/adapter, or parent-plan edit. PC-27's remaining
  seam is to derive citations only from `AgentInsight.knowledgeHits`. Stopped at
  implementation evidence; behavioral success remains unclaimed pending
  Phillip's later manual verdict.
- 2026-07-21 — Pre-start host-noise decision: explicitly defer
  `NotebookToolSelectionContractTests.test_refinement_lasso_bubble_is_anchored_to_magic_lasso_button`.
  The failing assertion is about a moved Magic-Lasso toolbar anchor and does not
  exercise the live AgentInsight tool surface or multi-turn loop. Baseline run:
  86/94 (`tmp/pc24-29-host-suite.log`), with the previously recorded stale
  failures plus a PC-24-exposed brittle SPUD-import source assertion. PC-26 will
  add/repair focused checks for the `search_textbook` declaration, bounded
  execute/result/final-answer turns, typed `KnowledgeHit` retention, and
  zero-hit termination. Thread remains not started pending PC-25.
- 2026-07-21 — Created for the recorded textbook-citation demo. Not started.
