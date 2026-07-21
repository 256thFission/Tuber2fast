# PC-28 — Cross-notebook navigation from a citation

Status: **implementation complete — awaiting Phillip's manual verdict**

Target branch: `main`

Owner: App coordination (routing between library, notebooks, and the sidebar).

Parent: `Docs/Plan/PLAN.md` § Textbook citation demo (PC-24 … PC-29)

## Objective

Tapping a citation chip opens the cited textbook notebook at the cited page, and
one tap returns to the worksheet with its ink and Pins intact. This is the
payoff beat of the recorded demo.

User-visible outcome: the chat leaves the current document and lands on the exact
textbook page, then comes back.

## Files and subsystems in scope

- `TuberNotes/App/Contracts/AgentContracts.swift` — App-owned typed navigation
  request carrying `(notebookID, pageIndex)` — **`CONTRACT:` prefix required**
- `TuberNotes/Notebook/NotebookStore.swift` — read-only resolution via the
  existing `notebook(id:)`
- `TuberNotes/Notebook/LibraryView.swift`,
  `TuberNotes/Notebook/NotebookView.swift` — routing and return affordance

## Design decision

Cross-notebook opening is a **separate** case from `switch_page`, which remains
same-notebook and remains gated on explicit user navigation requests per PC-23.
Conflating them would let a model that merely finds another page relevant yank
the user out of their document.

This route is user-initiated by construction: it fires from a chip tap, never
from a model tool call.

Return is a single explicit affordance back to the originating notebook and page,
not a general back-stack.

## Non-goals and dependencies

Non-goals: split view or side-by-side notebooks, multi-hop history, deep links
from outside the app, opening a notebook that no longer exists (degrade to a
disabled chip), animation polish beyond the existing page presentation.

Dependencies: none blocking. **Buildable in parallel with PC-25 through PC-27**
against a hardcoded `(notebookID, pageIndex)`; wire to real citations once PC-27
lands. This is the only thread in the demo that parallelizes cleanly.

## Ordered work

1. `CONTRACT:` add the cross-notebook navigation case, with a PLAN.md log entry.
2. Route it through `NotebookStore.notebook(id:)` into the notebook view at the
   target page index; handle a missing notebook or out-of-range page by
   disabling rather than crashing.
3. Add the return affordance to the originating notebook and page.
4. Attach the chip tap once PC-27 has landed.
5. Device preflight, signed Release build, install, normal launch; run the full
   worksheet → chip → textbook → back journey.

## Acceptance evidence and stop conditions

- On iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`, a chip tap opens the correct
  textbook page in the normal Release app.
- One tap returns to the worksheet; ink, Pins, and sidebar thread are intact.
- A citation pointing at a deleted notebook renders disabled and does not crash.
- Artifacts under `tmp/verify/pc28-cross-notebook-navigation/`.

Stop after evidence collection and request Phillip's verdict on the transition's
feel — the return especially, since it is on camera.

## Session log

- 2026-07-21 — Wired PC-27's typed `GroundedCitation` chip to the existing
  PC-28 route shell under Phillip's implementation-only go-mode override; no
  Release/device/human-review tooling was run. The callback chain is
  `PinChatTurnView` explicit chip tap → `AgentSidebarView` revalidation →
  `NotebookView` forwarding → existing `LibraryView.open` route validation →
  `AgentNavigationRequest.openNotebook`. `NotebookViewModel` resolves the
  citation's `documentID` through `NotebookStore`, rejects same-notebook,
  missing/deleted, non-positive, and out-of-range destinations, and maps the
  1-based `pageNumber` to `pageIndex = pageNumber - 1`. The callback is optional
  end-to-end: only the originating library notebook supplies it, while the
  pushed textbook omits it, so multi-hop citation chips remain disabled rather
  than presenting a no-op affordance. The chip revalidates again at tap time to
  suppress a route if the target changed after rendering. Changed files:
  `TuberNotes/Notebook/AgentSidebarView.swift`,
  `TuberNotes/Notebook/NotebookView.swift`,
  `TuberNotes/Notebook/NotebookViewModel.swift`, and
  `DeveloperTools/AgentKnowledgeTests/PC28CitationNavigationMain.swift`.
  Focused checks passed for exact 1-based/zero-based mapping, same-notebook,
  missing/deleted, non-positive, out-of-range, origin-handler enabled, and
  pushed-target/no-handler disabled cases. Swift parse, whole-source iOS
  Simulator typecheck (pre-existing warnings only), and `git diff --check`
  passed. Artifacts: `tmp/verify/pc28-cross-notebook-navigation/focused-check-run.log`,
  `focused-check-build.log`, and `swift-typecheck.log`. Scope audit: no model
  tool change, prose parsing, citation construction, general history, shared
  contract edit, or `switch_page` change. Existing origin `StateObject` and
  one-tap route pop remain unchanged. Stopped at implementation evidence;
  behavioral success remains unclaimed pending Phillip's later manual verdict.
- 2026-07-21 — Implementation-only go-mode override applied before delivery:
  no Release build, device, visual-verification, or human-review tooling will
  run in this session. PC-28 stops on its passing code/static audit; integrated
  behavior and Phillip's verdict remain pending after PC-27 wiring.
- 2026-07-21 — `CONTRACT:` Implemented the Wave 1 route shell with the fixed
  App-owned `AgentNavigationRequest.openNotebook(notebookID:pageIndex:)`
  boundary. `LibraryView` validates the target notebook and zero-based page
  index before pushing it above the live originating `NotebookView`; the
  destination's explicit return affordance pops only that route, and the target
  cannot push a second cross-notebook route. Missing, same-notebook, and
  out-of-range requests are rejected without navigation.
  No citation UI or fake product trigger was added. `git diff --check` and the
  static invariant audit passed. The serialized signed Release/device gate
  remains pending coordinator access; PC-27 must still emit the request from a
  grounded citation tap.
- 2026-07-21 — `CONTRACT:` Wave 1 route-shell implementation started on
  `main`. The coordinating thread chose an App-owned typed
  `AgentNavigationRequest.openNotebook(notebookID:pageIndex:)` boundary. It is
  emitted only by a user citation tap and remains separate from the model's
  same-notebook `switch_page` tool. Device delivery is serialized; citation
  wiring and the full behavioral gate remain pending PC-27.
- 2026-07-21 — Created for the recorded textbook-citation demo. Not started.
