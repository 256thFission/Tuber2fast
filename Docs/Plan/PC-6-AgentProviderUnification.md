# PC-6 — Agent provider unification

Status: **implemented — host-checked; Apple/device verification blocked**

Target branch: `sive/dev`

Source logic: `origin/workspace/shaftatron-torture-DONT-MERGE-THIS-SHIT`
at `ac4fa5e` (`feat: add external AI gateway support`)

Owner: `AgentHarness` owns provider access and streamed agent behavior;
Notebook and App integrate the shared configuration into the normal Agentic
Layer sidebar and deterministic Pin/conversation surfaces.

## Objective and user-visible outcome

Adapt the source branch's provider/model selection and Responses-gateway logic
without merging its history or replacing newer agent contracts. The normal
Agentic Layer sidebar and the streamed Pin/conversation client must derive
access from one provider configuration instead of independently hard-coding
OpenAI chat access and the Debug Codex transport.

This first milestone exposes provider and model choice through the existing
assistant-settings popup in local Debug builds, preserves the existing OpenAI-
compatible path, adds the named external Responses gateway, and makes both
`AgentInsightClient` and `AgentClient` factories consume the same AgentHarness-
owned access type.
Recorded scenarios and no-credential demo behavior remain the defaults.

## Scope

- `TuberNotes/AgentHarness/` provider configuration, request authorization,
  Responses transport, and client factories
- `TuberNotes/Notebook/AgentInsight.swift`
- `TuberNotes/Notebook/AgentSidebarView.swift`
- `TuberNotes/Notebook/NotebookViewModel.swift`
- `TuberNotes/App/RootView.swift` only where the existing deterministic/live
  agent selection needs the shared factory
- `DeveloperTools/CodexAdapterTests/` focused synthetic provider checks
- Xcode project membership only if a narrow new source file is required
- this child plan and the PC-6 parent status entry

## Non-goals and dependencies

- No Git merge, branch checkout, signing-team change, upstream source import,
  or wholesale replacement from the named source branch.
- No credential discovery, migration from other applications, hard-coded
  secret, browser login, or live provider call. All tests use synthetic values.
- No Release-bundled credential and no change to the recorded default.
- No `DrawingRefinementClient` wire change: its image-output backend is a
  separate product contract and neither source provider defines that API.
- No Pin coordinate, page identity, archive, or persistence representation
  change. Provider selection is local app configuration, not document data.
- Physical build and user-visible verification depend on an explicitly named,
  pinned iPad and a host with Xcode.

## Work and verification

1. Extract the source branch's provider/model choices into an
   AgentHarness-owned value with one authorization/request-policy seam.
2. Route both the sidebar insight factory and streamed Pin/conversation factory
   through that value; reuse the bounded SSE decoder and strict `place_pins`
   validation for Responses providers.
3. Adapt the existing assistant settings popup to edit one provider credential
   and model while retaining the current OpenAI key storage as a compatibility
   fallback.
4. Add focused synthetic checks for provider defaults, endpoint/header/body
   selection, continuation IDs, strict Pin validation, and redacted failures.
5. Run host-safe checks and inspect the final diff for secrets, unrelated branch
   content, provider-specific UI leakage, and subsystem ownership violations.
6. On the explicitly pinned iPad, run `agent-recorded-success`,
   `agent-recorded-failure`, `hero-recorded`, and `pin-conversation`; then inspect
   the normal notebook sidebar/settings and Pin composition for clipping,
   overlap, missing state, crashes, and recoverable errors.

## Acceptance evidence and stop conditions

- Both relevant agent-client factories accept the same provider-access value;
  neither user-visible surface owns an endpoint or authorization header.
- OpenAI-compatible and external Responses providers have provider-correct
  models and wire formats; invalid coordinates remain rejected before UI use.
- Empty credentials preserve deterministic/demo operation. Provider failures
  remain recoverable and do not expose response bodies, credentials, or user
  image/prompt content in diagnostics.
- Existing recorded cases remain deterministic and credential-free.
- Stop after the scoped evidence is collected, after two verification failures
  without a narrower diagnosis, at an architecture/security boundary, or when
  the exact-device prerequisite is unavailable.

## Session log

- 2026-07-20 — Started from dirty `sive/dev` at `69efea9`, preserving unrelated
  PC-5 notebook/Pencil work. The named source is remote branch tip `ac4fa5e`;
  its useful bounded delta is provider/model selection plus a Responses-gateway
  parser in `AgentInsight.swift`. Current `sive/dev` already has a stricter SSE
  decoder and `place_pins` validator in `AgentHarness`, so this line will adapt
  behavior into those newer seams instead of transplanting the branch file.
- 2026-07-20 — Implemented AgentHarness-owned `AgentProviderAccess` with OpenAI
  and right.codes routes, provider-correct defaults/options, shared ephemeral
  authorization policy, and compatibility with the existing local credential
  storage key. The normal Agentic Layer sidebar now selects provider/model and
  creates `AgentInsightClient` through that access value; the streamed
  `AgentClient` factory consumes the same value for Pin placement and follow-up
  conversations. Responses text uses the bounded SSE decoder, strict
  `place_pins` validation remains unchanged, provider response IDs now flow
  through `AgentEvent.completed` and back as `previous_response_id`, and missing
  live configuration produces a recoverable failure instead of a recording.
  Direct provider clients and credential editing are Debug-only; Release stays
  credential-free/demo pending a distributable gateway. Switching provider
  clears the prior provider's credential before the new endpoint can be used.
  Raw failure bodies are no longer surfaced.
- 2026-07-20 — Host evidence: `SECRET_SCAN: PASS` across every PC-6 source/doc
  file; `PROVIDER_CONTRACT_CHECK: PASS` for shared factories, endpoint/header
  ownership, continuation wiring, and the Debug/Release boundary; and
  `git diff --check` passes. The focused Swift adapter executable, Xcode build,
  device preflight, `agent-recorded-success`, `agent-recorded-failure`,
  `hero-recorded`, `pin-conversation`, normal sidebar inspection, screenshots,
  console/crash collection, and live smoke remain uncollected because this host
  has no `xcrun`, `xcodebuild`, or `swiftc` and therefore cannot pin or run the
  required physical iPad. No live provider call was attempted and no runtime
  success is claimed. Final scope review preserved all unrelated PC-5 notebook,
  Pencil, template, project-membership, and plan work; the only shared-file
  overlap is the narrow provider-factory handoff in `NotebookViewModel` and the
  separate parent-plan entry.
- 2026-07-20 — Final redundancy/visual-artifact pass: consolidated both insight
  clients onto one request/send/status/text-decoding function; removed the
  unused `noKey` error, stale API-key/OpenAI component names and accessibility
  copy, and repeated storage-key literals. Provider/model/credential edits now
  remain draft-only until Save, so Cancel is side-effect free and changing
  provider cannot send the prior provider's credential to a new endpoint. The
  expanded provider card is a height-bounded, content-sized ScrollView and its
  longest model label is width-bounded, preventing keyboard/compact-height
  clipping pressure. Release settings truthfully remain in demo mode. Both
  focused notebook contract suites pass (4/4 each), the repeated source secret
  scan and `git diff --check` pass, and `CLEANUP_VISUAL_CONTRACT_CHECK: PASS`
  confirms the layout guards plus provider-ownership invariants. Physical-frame
  inspection is still uncollected because the Apple/device prerequisite remains
  unavailable; no visual-runtime claim is inferred from the source check.
