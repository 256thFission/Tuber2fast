# PC-7 — Agentic Layer, conversation-tree, and movable-Pin interaction cleanup

Status: **implementation complete — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Owner subsystems: `Notebook` integration and `Pins` spatial UI. `AgentHarness`
runtime behavior and `SpatialCanvas` coordinate ownership remain unchanged.

## Objective and user-visible outcome

Make Agentic Layer interaction direct and truthful in the normal notebook:

- a layer is presented as hidden or active, with unmistakably different
  toolbar and layer-chip treatments;
- merely opening the layer picker does not masquerade as activating a layer;
- dragging a conversation Pin moves it on the logical page and persists its
  new page-normalized anchor;
- the Agent sidebar presents each layer's durable Pins as a conversation tree,
  and a follow-up can branch from any existing node while reusing that node's
  page region and bounded answer context;
- expanded Pins explain that they can be dragged, show a direct conversation
  action only on surfaces that actually support follow-up, open the matching
  tree node in the normal Agent sidebar, and never advertise a dead hold
  gesture.

## Scope

- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/Notebook/NotebookViewModel.swift`
- `TuberNotes/Notebook/NotebookToolbar.swift`
- `TuberNotes/Notebook/AgentSidebarView.swift`
- `TuberNotes/Notebook/README-notebooks.md`
- `TuberNotes/Pins/Pin.swift`
- `TuberNotes/Pins/PinOverlayView.swift`
- `TuberNotes/Pins/ConversationLayerOverlayView.swift` only if needed to keep
  the Pins-owned adapter truthful
- `TuberNotes/App/RootView.swift` only to preserve the Debug conversation
  regression surface across the additive Pin event
- `TuberNotes/App/Contracts/PinContracts.swift` for the additive optional
  parent-thread link required by durable branch topology
- `DeveloperTools/tests/test_agent_layer_interaction_contract.py` for narrow
  host checks of the new state, tree, and normalized-move seams
- this child plan and the parent status board/session log

## Non-goals and dependencies

- No agent-provider, prompt, response, streaming, retrieval, or credential
  changes.
- No detached chat surface, transcript/message persistence, provider-side
  branch protocol, Pin visual redesign, or new coordinate system.
- No changes to `ConversationLayer`, document/archive, or page identity
  representations beyond `PageAnnotation`'s optional parent-thread link,
  which naturally round-trips inside the existing annotation payload.
- The semantic `targetRegion` remains the original analyzed selection; moving
  a Pin changes only its page-normalized visual anchor.
- Canonical build and visual acceptance depend on the explicitly pinned
  physical iPad and Apple/Xcode host required by the repo workflow.

## Work and verification

1. Trace layer activation, visibility, sidebar, Pin events, gesture ownership,
   normalized projection, and persistence; record concrete findings before
   editing.
2. Present each normal-notebook Agentic Layer as an active/hidden toggle and
   reserve vivid toolbar treatment for an actually active layer.
3. Convert the Pin anchor's currently discarded drag into a Pins-owned move
   gesture. In the normalized-fit adapter, clamp the final view point to the
   page bounds, invert it to `PageNormalizedPoint`, and emit it to the
   coordinator for persistence.
4. Add an honest expanded-Pin move hint and a direct follow-up action only when
   a conversation handler is present; retain hold as an optional shortcut.
5. Replace the Agent sidebar's transient duplicate answer list with a durable
   flattened conversation tree. Selecting any node creates an explicit branch
   context; the next answer becomes a child Pin and then selects that child for
   natural continuation.
6. Inspect the final diff and run focused host-safe checks.
7. On the explicitly pinned iPad, build once; run `fake-pin`,
   `pin-conversation`, and `pin-drift` as applicable with build reuse; then
   inspect the normal notebook for layer-state contrast, Pin drag, persistence,
   zoom/pan attachment, clipping, overlap, and crashes.

## Acceptance evidence and stop conditions

- The layer-picker button is visually inactive while the layer is hidden even
  when its popover is open, and clearly active only while Pins are rendered.
- Normal-product layer controls expose active and hidden—not a misleading
  selected/visible/active combination—and accessibility reports the same
  state.
- A drag starting on a Pin moves its anchor and label together, commits one
  finite in-bounds `PageNormalizedPoint`, persists it, and does not toggle the
  card or launch follow-up.
- The moved Pin stays attached to the same logical page location through
  supported zoom/pan/layout changes and after save/reopen.
- Pins without a conversation handler do not advertise follow-up; supported
  completed Pins expose a visible direct action as well as the hold shortcut.
- The normal Agent sidebar renders every active-layer Pin exactly once in a
  cycle-safe tree; roots and indented descendants remain understandable, a
  selected branch is visually explicit, and clearing it returns to a new root.
- A branch uses the parent Pin's current page/selection region and bounded
  answer context, persists a new child Pin with a fresh thread ID and the
  parent's thread ID, and never rewrites its ancestor.
- Existing Pin expansion, citation, recorded-conversation, and page gestures
  remain intact with no clipping, unintended overlap, crash, or immediate
  exit.
- Stop after evidence is collected, after two failed verification attempts
  without a narrower repair, if the required pinned iPad is unavailable, or
  if the repair pressures architecture ownership.

## Session log

- 2026-07-20 — Started from clean `sive/dev` at `1e75dfe`. Audit found that
  the toolbar gives `showLayers` the same gradient as an active Agentic Layer;
  layer chips separately expose persisted visibility, selection, and global
  activation even though only one selected active layer renders; normal
  notebook Pins advertise a follow-up hold through accessibility but provide
  no handler; and `PinAnchor` already recognizes movement over 12 points but
  cancels and discards it. The existing normalized-fit overlay and mutable
  `PageAnnotation.target` provide the smallest correct move path without a new
  persisted coordinate or ownership change.
- 2026-07-20 — User expanded the same interaction cleanup to conversation
  trees. `SPEC.md` defers a full persisted transcript UI but already retains
  `threadID` for forward compatibility. The bounded implementation therefore
  models the existing persisted Pins as nodes, adds only an optional parent
  thread link, and uses the normal Agent insight path with inherited page
  region and bounded parent context. It does not add message storage, a
  detached chat surface, or a new provider/runtime protocol.
- 2026-07-20 — Bounded implementation complete. Agentic Layer chips now expose
  only hidden/active states; opening the picker no longer paints the toolbar as
  active. Normal Pins drag within the fitted logical-page overlay, convert the
  final view point once to a marker-safe page-normalized anchor, and persist
  through `NotebookViewModel`; the semantic target region is unchanged.
  Expanded completed Pins expose an honest move hint and Continue action, while
  unsupported surfaces no longer advertise follow-up. Continue opens the
  matching normal-product tree node. The sidebar now derives a cycle-safe tree
  from persisted Pins, creates child nodes with fresh thread IDs and optional
  parent-thread links, reuses a parent's page region plus at most 2,000
  characters of answer context, offsets sibling anchors deterministically, and
  safely resolves the destination layer after asynchronous work.
- 2026-07-20 — Focused host checks PASS: 13/13 across the new Agentic Layer
  interaction contract, archive/export compatibility, and notebook branch
  logic; `git diff --check` PASS. The broader existing Python suite is 34/35:
  its sole failure is the untouched scenario-verifier truthfulness test calling
  an existing assertion helper with 13 arguments while it unpacks 19. No
  verifier/tooling file implicated by that failure is in this diff. Final diff
  inspection found no unrelated churn, ownership violation, credential,
  provider-runtime change, SpatialCanvas edit, page-identity change, or archive
  format-version change. This Linux host has no `xcodebuild`, `swiftc`, `swift`,
  `xcrun`, or pinned-device session file, so canonical build and physical-iPad
  verification could not start. Stopped at the exact-device/toolchain
  prerequisite rather than substituting a simulator.

## Evidence packet — 2026-07-20

### Objective and changed files

- Deliver coherent hidden/active Agentic Layer behavior, persisted movable
  conversation Pins, and a branchable Pin-backed conversation tree in the
  normal Agent sidebar.
- Product changes: `TuberNotes/App/Contracts/PinContracts.swift`,
  `TuberNotes/App/RootView.swift`, `TuberNotes/Notebook/AgentSidebarView.swift`,
  `NotebookToolbar.swift`, `NotebookView.swift`, `NotebookViewModel.swift`,
  `README-notebooks.md`, `TuberNotes/Pins/ConversationLayerOverlayView.swift`,
  `Pin.swift`, and `PinOverlayView.swift`.
- Verification/coordination: `DeveloperTools/tests/test_agent_layer_interaction_contract.py`,
  this child plan, and the parent plan status/log.

### Diff summary / scope check

- Layer presentation is binary and truthful; durable Pin annotations are the
  sole tree store; Pin movement is normalized/clamped and coordinator-persisted;
  direct Pin continuation selects the matching branch parent.
- Final diff stayed in requested scope: yes.
- Ownership violations or unrelated churn: none found.
- Shared contracts: additive `PinOverlayEvent.moved` and optional
  `PageAnnotation.parentThreadID`, both parent-plan logged under `CONTRACT:`.

### Build

- Result: not run — blocked by unavailable Apple/Swift toolchain.
- Device preflight: not run; there is no explicitly named/pinned target or
  `.tubernotes-device-session.json`, and the Linux host has no `xcrun`.
- Pinned physical-device ID: none.
- Log/artifact path: none.

### Verification

- Host command: `python3 -m unittest` for the focused PC-7, archive/export, and
  notebook branch-logic modules — 13/13 PASS.
- Hygiene: `git diff --check` PASS; secret-pattern and stale-symbol scans PASS.
- Intended device scenarios: `fake-pin`, `pin-conversation`, and `pin-drift`.
- Expected state: visible hidden/active contrast; cycle-safe tree with selectable
  ancestor/child branches; direct Pin Continue; drag commits an in-bounds
  page-normalized target and survives zoom/pan/save/reopen.
- Physical-iPad inspection, screenshots, attached console, crash diagnostics,
  and artifact directory: not collected; exact-device prerequisite absent.

### Mechanical checks

- Host-mechanical: finite/in-bounds normalization guard, marker edge padding,
  one final move event, one persistence call, cycle guard, bounded parent
  context, stable destination-layer lookup, additive archive payload, and
  hidden/active accessibility values checked.
- Device-mechanical still required: intended content, clipping, overlap,
  tap/hold/drag exclusivity, crashes, persistence after reopen, and Pin drift
  through viewport changes.

### Human-only checks still required

- Visual taste and readability of deep/sibling trees.
- Drag, hold, Continue, and layer-toggle interaction/animation feel on iPad.
- Shared-contract after-the-fact review of `PinOverlayEvent.moved` and
  `PageAnnotation.parentThreadID`.

### Stop reason / unresolved issues

- Stopped with implementation and host evidence complete because the canonical
  Apple host and explicitly pinned physical iPad are unavailable. The existing
  unrelated 34/35 full-host-suite verifier mismatch remains outside PC-7.
