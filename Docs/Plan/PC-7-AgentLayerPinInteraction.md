# PC-7 — Agentic Layer, conversation-tree, and movable-Pin interaction cleanup

Status: **follow-up implemented — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Owner subsystems: `Notebook` integration and `Pins` spatial UI. `AgentHarness`
runtime behavior and `SpatialCanvas` coordinate ownership remain unchanged.

## Objective and user-visible outcome

Make Agentic Layer interaction direct and truthful in the normal notebook:

- a layer is presented as hidden or active, with unmistakably different
  toolbar and layer-chip treatments;
- the notebook's drifting background gradients share the colored glow while
  an Agentic Layer is active and return to neutral when it is hidden;
- merely opening the layer picker does not masquerade as activating a layer;
- dragging a conversation Pin moves it on the logical page and persists its
  new page-normalized anchor;
- the Agent sidebar presents each layer's durable Pins as conversation history,
  and a follow-up can continue from any existing response while reusing that
  lineage's page region and bounded answer context;
- expanded Pins explain that they can be dragged, show a direct conversation
  action only on surfaces that actually support follow-up, open the matching
  tree node in the normal Agent sidebar, and never advertise a dead hold
  gesture.

## Scope

- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/Notebook/AmbientBackground.swift`
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
  parent-thread link required by durable lineage topology
- `DeveloperTools/tests/test_agent_layer_interaction_contract.py` for narrow
  host checks of the new state, tree, and normalized-move seams
- this child plan and the parent status board/session log

## Non-goals and dependencies

- No agent-provider, prompt, response, streaming, retrieval, or credential
  changes.
- No detached chat surface, transcript/message persistence, provider-side
  divergence protocol, Pin visual redesign, or new coordinate system.
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
5. Replace the Agent sidebar's transient duplicate answer list with durable
   conversation history. Selecting any response continues from that point; the
   next answer becomes a child Pin and then selects that child so ordinary
   follow-ups remain in the active lineage.
6. Inspect the final diff and run focused host-safe checks.
7. On the explicitly pinned iPad, build once; run `fake-pin`,
   `pin-conversation`, and `pin-drift` as applicable with build reuse; then
   inspect the normal notebook for layer-state contrast, Pin drag, persistence,
   zoom/pan attachment, clipping, overlap, and crashes.

## Acceptance evidence and stop conditions

- The layer-picker button is visually inactive while the layer is hidden even
  when its popover is open, and clearly active only while Pins are rendered.
- The existing ambient gradients and Pencil ripples use the agentic glow
  palette only while a layer is active and return to neutral when it is hidden.
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
  cycle-safe history; roots and indented descendants remain understandable, a
  selected continuation point is visually explicit, and clearing it starts a
  new conversation.
- A continuation uses the prior Pin's current page/selection region and bounded
  cycle-safe lineage context, persists a new child Pin with a fresh thread ID
  and the prior thread ID, and never rewrites its ancestor.
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
- 2026-07-20 — User follow-up identified two coherence defects in the same
  work line: ordinary parent-linked replies are labeled as branches even when
  they continue the active conversation lineage, and Pin movement feels
  unstable. The bounded repair keeps the persisted parent topology, makes
  continuation the default agentic-conversation language (reserving divergence
  as a structural possibility rather than labeling every reply), and stabilizes
  drag geometry in the overlay's coordinate space while keeping the card's
  anchor-relative placement fixed for the duration of a drag.
- 2026-07-20 — Follow-up implementation complete. User-facing sidebar copy now
  presents the selected response as a continuation point and calls descendants
  replies. The newest reply remains selected, so the ordinary next turn stays
  in the same lineage; selecting an earlier response can still intentionally
  diverge without labeling every follow-up as branching. The agent receives up
  to six cycle-safe ancestor turns within a 4,000-character total budget,
  escaped as quoted context with explicit recency/evidence, non-repetition,
  uncertainty, and prompt-boundary guidance. Pin drag uses the stable overlay
  coordinate space and freezes the card's initial anchor-relative offset while
  clamping it inside page edges, preventing local-coordinate feedback and
  per-frame side flipping.
- 2026-07-20 — Follow-up host checks PASS: the focused PC-7 plus nearby
  archive/export and notebook navigation modules are 13/13; `git diff --check`
  and the stale user-facing branching-copy scan pass. The full host suite is
  35/36 with the same pre-existing scenario-verifier argument mismatch (19
  expected, 13 supplied), outside this diff. Logs:
  `tmp/verify/pc-7-conversation-pin-followup/focused-tests.log` and
  `tmp/verify/pc-7-conversation-pin-followup/full-host-suite.log`. Final diff
  inspection found only Notebook, Pins, focused contract-test, README, and plan
  changes. No shared contract, provider transport, archive schema, page
  identity, or SpatialCanvas ownership changed. Apple/Xcode and the explicitly
  pinned physical iPad remain unavailable, so device build/scenario evidence
  could not be collected and no simulator was substituted.
- 2026-07-20 — User requested that the active Agentic Layer treatment extend
  into the existing drifting background gradients. Started a bounded visual
  follow-up: tint only the established ambient blobs and Pencil ripples with
  the page-edge cyan/blue/indigo/purple/pink family while the layer is active;
  preserve neutral background behavior, interaction, and spatial contracts.
- 2026-07-20 — Ambient-glow follow-up implemented. `NotebookView` passes the
  truthful active-layer state into `AmbientBackground`; the five existing
  breathing gradients each take one page-edge palette hue and Pencil ripples
  take cyan while active, with the prior neutral colors retained while hidden.
  Focused PC-7, archive/export, and nearby notebook checks pass 13/13 and
  `git diff --check` passes; log:
  `tmp/verify/pc-7-agentic-ambient-glow/focused-tests.log`. No interaction,
  persistence, coordinate, provider, or shared contract changed. Canonical
  build and visual inspection remain blocked because this Linux host has no
  Xcode tools or explicitly pinned physical-iPad session.

## Evidence packet — 2026-07-20

### Objective and changed files

- Deliver coherent hidden/active Agentic Layer behavior, persisted movable
  conversation Pins, and Pin-backed conversation history in the
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
  direct Pin continuation selects the matching prior response.
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
- Intended device scenarios from the current change map: `fake-pin`,
  `multi-pin`, `edge-pins`, `pin-drift`, `agent-recorded-success`,
  `agent-recorded-failure`, `hero-recorded`, and `pin-conversation`.
- Expected state: visible hidden/active contrast; cycle-safe history with
  selectable prior/child responses; direct Pin Continue; drag commits an in-bounds
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

## Follow-up evidence packet — 2026-07-20

- Objective: correct continuation semantics and stabilize Pin movement.
- Changed product files: `AgentSidebarView.swift`, `NotebookViewModel.swift`,
  `README-notebooks.md`, and `PinOverlayView.swift`; focused contract test and
  PC-7/parent plan logs changed alongside them. Final diff stayed in scope.
- Build/device: not run; this host has no Apple/Swift toolchain, `xcrun`, pinned
  device-session file, or explicitly named physical iPad.
- Host evidence: 13/13 focused PASS; full suite 35/36 with the unchanged
  out-of-scope scenario-verifier mismatch; `git diff --check` PASS. Logs are in
  `tmp/verify/pc-7-conversation-pin-followup/`.
- Expected device state: follow-ups read as continuation, lineage context stays
  bounded/cycle-safe, and a dragged Pin/card tracks smoothly without side
  flipping while the committed anchor remains page-normalized and in bounds.
- Device-mechanical checks still required: build/launch; the Pin layout,
  coordinate, and conversation scenarios named above; persistence after reopen;
  zoom/pan anchoring; clipping/overlap; console/crash state; and direct
  touch-gesture behavior.
- Human-only check still required: Pin drag feel and conversation-history
  clarity on iPad. Stop reason: exact Apple host/device prerequisite absent.

## Ambient-glow follow-up evidence packet — 2026-07-20

- Objective: give the existing notebook background gradients the same colored
  glow language as an active Agentic Layer.
- Changed files for this follow-up: `AmbientBackground.swift`,
  `NotebookView.swift`, `README-notebooks.md`, the focused PC-7 contract test,
  and the PC-7/parent plan logs. Final diff inspection found no out-of-scope
  changes from this follow-up and preserved the earlier uncommitted PC-7 work.
- Host evidence: focused PC-7 plus archive/export and notebook checks pass
  13/13; `git diff --check` passes. Log:
  `tmp/verify/pc-7-agentic-ambient-glow/focused-tests.log`.
- Expected device state: neutral animated background when Agentic Layers are
  hidden; cyan/blue/indigo/purple/pink breathing gradients and a cyan Pencil
  ripple when active; page content remains dominant with no clipping or input
  interception.
- Build/device, screenshot, console/crash, and mechanical visual evidence were
  not collected: this host exposes no `xcodebuild`/`xcrun` and has no pinned
  physical-iPad session. Human-only color balance and visual-taste review remain
  open. Stop reason: exact Apple host/device prerequisite absent.
