# PC-27 — Grounded citation chips in chat

Status: **implementation complete — awaiting Phillip's later manual verdict**

Target branch: `main`

Owner: App owns the message/citation boundary; Notebook owns the chat
presentation. Pins retains spatial UI and is unchanged.

Parent: `Docs/Plan/PLAN.md` § Textbook citation demo (PC-24 … PC-29)

## Objective

Render a tappable citation beneath an agent response that names the textbook,
page, and section it actually retrieved — and make an ungrounded citation
structurally impossible to produce.

User-visible outcome: after an Explain, the sidebar shows a chip such as
**Organic Chemistry Ch. 11 · p. 214 · §11.3 Stereochemistry of SN2**.

## Files and subsystems in scope

- `TuberNotes/App/Contracts/AgentContracts.swift` — typed citation on the
  message boundary — **`CONTRACT:` prefix required**
- `TuberNotes/Notebook/AgentInsight.swift` — attach citations from tool results
- `TuberNotes/Notebook/PinChatComponents.swift` — chip presentation
- `TuberNotes/Notebook/MarkdownMessageView.swift` — ensure the chip is a sibling
  of the rendered body, not markdown inside it

## Design decision — the load-bearing one

A citation is constructed **only** from a `KnowledgeHit` the tool actually
returned. `KnowledgeHit` already carries `id`, `documentID`, `documentTitle`,
`pageNumber`, and `sectionTitle`; the chip is built from those fields.

The model's prose is never parsed for citations. If the model writes "see p. 214"
and no hit backs it, no chip appears.

Rationale: this is a recorded demo, so most failures are absorbed by a retake. A
citation pointing at a page that does not exist is the exception — it is a
structural defect that reproduces on every take and discredits the feature it
exists to demonstrate. Grounding in tool output makes a dangling link
unrepresentable rather than unlikely.

## Non-goals and dependencies

Non-goals: inline text-anchored citations, multi-hit citation lists, hover or
long-press page previews, citation persistence across app relaunch, citations on
Pins (sidebar only).

Dependencies: **PC-26** must return typed hits. The chip's tap action is
PC-28; until that lands, the chip may render inert.

## Ordered work

1. `CONTRACT:` add the typed citation to the agent message boundary, with a
   `Docs/Plan/PLAN.md` log entry naming the changed type and why.
2. Populate citations in `AgentInsight` from returned hits only.
3. Render the chip below the response body, subordinate to it — the answer is
   the content, the citation is provenance.
4. Verify the chip reads legibly at final video capture size (coordinate with
   PC-29).

## Acceptance evidence and stop conditions

- In the normal Release app, an Explain that retrieves produces a chip whose
  title, page, and section match the hit.
- An Explain that retrieves nothing produces no chip.
- No code path constructs a citation from model text; confirmed by final diff
  inspection.
- Artifacts under `tmp/verify/pc27-citation-chips/`.

Stop after evidence collection and request Phillip's visual verdict on chip
weight and placement — that is a taste judgment, not a mechanical check.

## Session log

- 2026-07-21 — `CONTRACT:` Wave 4 started under Phillip's implementation-only
  go-mode override. Coordinator decision: add an App-owned `GroundedCitation`
  whose only product initializer takes a returned `KnowledgeHit`; carry it on
  both `PageAnnotation` root messages and `PinConversationMessage` follow-ups so
  sidebar provenance stays attached to the exact response. Keep the legacy
  generic `Citation` unchanged. Required shared-contract files therefore include
  `TuberNotes/App/Contracts/AgentContracts.swift` and
  `TuberNotes/App/Contracts/PinContracts.swift`. PC-27 renders the chip inert;
  PC-28 owns the later user-tap navigation wiring.
- 2026-07-21 — `CONTRACT:` Implemented `GroundedCitation` with exact
  `KnowledgeHit` provenance fields and the sole product initializer
  `init(hit:)`; added backward-compatible optional `groundedCitation` storage
  to `PageAnnotation` and `PinConversationMessage`. `NotebookViewModel` maps
  only `insight.knowledgeHits.first` for Magic-Lasso guidance roots, sidebar
  roots, and follow-ups. `PinMessageThreadBuilder` projects the citation and
  `PinChatTurnView` renders one chip as a sibling directly below Markdown. The
  PC-28 seam is `PinChatTurnView.onOpenCitation`; it is nil here, so the chip is
  disabled and has no navigation hint. Focused executable mapping/legacy-decode/
  round-trip checks passed; five source-contract checks passed; Swift parse and
  `git diff --check` passed. Evidence:
  `tmp/verify/pc27-citation-chips/{contract-check.txt,source-contract-tests.txt,swift-parse.txt,invariant-audit.txt,git-diff-check.txt}`.
  No Release/device/human-review tooling was run under Phillip's go-mode
  instruction, and no behavioral-success claim is made. Final diff inspection
  found PC-27 edits confined to its approved contracts, Notebook propagation/UI,
  focused checks, and this child plan; other dirty worktree changes belong to
  earlier PC threads.
- 2026-07-21 — Created for the recorded textbook-citation demo. Not started.
