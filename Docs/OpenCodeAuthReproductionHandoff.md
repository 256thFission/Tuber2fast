# Handoff — OpenCode OpenAI/Codex auth reproduction spike

Model-independent handoff for the phase after the accepted M0 document, spatial,
recorded-Agent, Knowledge, and verification work.

## Objective and status

- Objective: reproduce the behavior of OpenCode's built-in OpenAI/Codex
  ChatGPT Pro/Plus authentication adapter in a hermetic, no-secret development
  harness, then determine whether any of that behavior is appropriate for a
  TuberNotes DEBUG direct-provider adapter.
- Status: ready to start as a discovery/reproduction spike. No OpenCode auth code
  or live provider adapter exists in this repository.
- Working assumption: “OpenCode auth reproduction” means the built-in OpenAI/Codex
  OAuth path, not generic API-key storage, Snowflake auth, MCP OAuth, or OpenCode
  server Basic Auth. Confirm with the human before broadening the target.
- Stop reason for this handoff: the prior self-contained M0 tracks are committed;
  provider networking/authentication remains explicitly deferred.

This is a sensible isolated next phase, but it is not the complete next product
milestone. Genuine SpatialCanvas lasso capture/crop and the full investigation UI
remain separate missing product work.

## Authority and security boundary

- `SPEC.md` §10.1 is authoritative: no distributable app may contain a reusable
  provider secret. A hackathon credential may be supplied locally only to a DEBUG
  direct adapter and must never be committed, logged, placed in fixtures, or
  compiled into Release.
- `SPEC.md` explicitly says ChatGPT/Codex OAuth is **not** an implementation
  assumption. Reproduction is research evidence, not approval of the production
  auth architecture or provider.
- Do not inspect, copy, transform, or reuse credentials from
  `~/.codex/auth.json`, `~/.local/share/opencode/auth.json`, Keychain, browser
  storage, environment dumps, or another application.
- Do not commit tokens, authorization codes, refresh tokens, PKCE verifiers,
  cookies, account identifiers, callback query strings, raw auth responses, or
  request headers. Synthetic fixtures must be unmistakably fake.
- Do not automate an interactive browser login or start a real provider smoke test
  without explicit user authorization at the point that account access is needed.
- Do not log selected page content or credentials. Diagnostic output must redact
  authorization values and user content by construction, not by convention.
- Do not add auth behavior to Release, App assets, Info.plist, frozen contracts, or
  the recorded hero stub during this spike.
- Importing or adapting upstream source requires a separate license/attribution and
  architecture review. Prefer a behavior-level reproduction with small original
  code until that decision is made.

## Upstream target to pin before implementation

OpenCode is changing quickly. Before writing the reproduction, record the exact
OpenCode release and Git commit being studied; do not implement against an
unversioned `dev` branch.

Primary starting points, checked on July 17, 2026:

- OpenCode auth CLI documentation:
  <https://opencode.ai/docs/cli/#auth>
- OpenCode provider documentation:
  <https://opencode.ai/docs/providers/>
- Current built-in Codex auth plugin source:
  <https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/plugin/codex.ts>
- TuberNotes security boundary: `SPEC.md` §10.1.
- TuberNotes AgentHarness work package: `SPEC.md` WP3.

The upstream source currently exposes browser and headless ChatGPT subscription
methods, PKCE/state handling, access/refresh token lifecycle, optional account-ID
extraction, and authenticated request adaptation. Treat those as behavior to
study, not a stable or approved TuberNotes contract.

OpenCode was not installed on this Mac when this handoff was written. Do not install
or execute a newly downloaded binary merely to begin; source inspection and the
hermetic reproduction are sufficient for the first bounded step.

## Current TuberNotes state

- Branch: `codex-tenative-m0`.
- Base HEAD before this handoff: `eed9459 Add review packet guides for M0 feature groups`.
- Current implementation commits:
  - `5766ef6` — recorded Agent client and offline Knowledge search.
  - `23878e0` — M0 document/spatial scenarios and recorded hero stub.
  - `9347406` — runtime-truthful scenario verification.
  - `eed9459` — major-group review-packet guides.
- Tracked worktree was clean before creating this handoff.
- Existing unrelated untracked state to preserve:
  - `.cursor/`
  - generated Python `__pycache__/` directories
  - `Docs/M0V2NextStepsHandoff.md`

Implemented Agent-side foundation:

- `AgentClient` already defines the product runtime stream boundary.
- `RecordedAgentClient` provides paced success, retrieval, typed failure,
  cancellation, and invalid-coordinate cases without credentials or network.
- `AgentFailure.Code` already includes `unauthorized`, `timedOut`,
  `invalidResponse`, `unavailable`, and `cancelled`.
- Offline Knowledge search is implemented and focused-test verified.
- `hero-recorded` is deliberately classified **PARTIAL / STUB**. It does not prove
  real selection capture, crop generation, live auth, provider calls, or live AI.

No live provider client, token store, callback listener, refresh coordinator,
request signer, gateway client, auth UI, or product retry flow exists.

## Verification inherited from the completed phase

- Canonical build passed for `TuberNotes.xcodeproj`, scheme `TuberNotes`, on
  `iPad Pro 13-inch (M5)` simulator.
- 52 Python tests passed.
- Strict-concurrency Agent/Knowledge executable passed with
  `AGENT_KNOWLEDGE_CHECKS: PASS`.
- App-wired document/spatial scenarios passed fresh runtime-evidence checks.
- `pin-drift` passed page-scoped zoom/pan, page turn/return, and simulator rotation.
- `hero-recorded` passed only as `partial-stub`.
- Sol's final adversarial review had no open P0/P1/P2 findings.

Review sources for the next conversation:

- `Docs/ReviewGuides/AgentAndKnowledge.md`
- `Docs/ReviewGuides/VerificationTooling.md`
- `Docs/templates/EvidencePacket.md`

## First bounded reproduction step

Create a development-only, hermetic reproduction under a new isolated directory
such as `DeveloperTools/OpenCodeAuthReproduction/`. Keep it outside the iOS target.
Do not modify product code during this step.

The reproduction should model only:

1. PKCE verifier/challenge creation using secure randomness.
2. Per-attempt state creation and exact callback-state validation.
3. Single-use callback completion and rejection of mismatch/replay.
4. Synthetic token response decoding and expiry calculation.
5. Refresh-needed state transitions using synthetic responses.
6. Optional account-ID extraction from a synthetic JWT payload.
7. Redacted authenticated-header construction without performing a network call.
8. Mapping auth-needed, timeout, cancellation, malformed response, and unavailable
   states to the existing TuberNotes failure vocabulary in a comparison document;
   do not change the frozen contract in this step.

Use a loopback fake authorization/token server or in-memory transport controlled by
the tests. It must make no request to OpenAI, ChatGPT, OpenCode services, or any
third-party endpoint.

## Acceptance evidence for the reproduction

- Exact upstream OpenCode release and commit are recorded in the reproduction README.
- Focused tests cover success, callback-state mismatch, replay, timeout,
  cancellation, malformed synthetic token data, expiry, refresh-needed behavior,
  and redaction.
- Test output and fixtures contain no real-looking reusable credential.
- A secret scan covers changed files, test artifacts, and logs.
- The harness runs without OpenCode installed and without network access.
- A short compatibility note maps reproduced behavior to `AgentClient` and
  `AgentFailure` without changing either contract.
- Final diff remains under `DeveloperTools/OpenCodeAuthReproduction/` plus the
  smallest necessary documentation update.
- No Xcode/iPad review packet is created for this non-UI step. Use harness
  conformance and finish with `Docs/templates/EvidencePacket.md`.

## Non-goals for the reproduction

- Real OpenAI/ChatGPT sign-in.
- Reading or migrating OpenCode/Codex credentials.
- Choosing the production provider, model, gateway, or auth architecture.
- Calling undocumented provider endpoints.
- Shipping OpenCode code inside TuberNotes.
- Adding a credential persistence layer or Keychain schema.
- Integrating with `RootView`, the recorded hero stub, lasso/crop, Pins, or Knowledge.
- Proving subscription terms, App Store acceptability, or production security.
- Live multimodal request construction or streaming response decoding.

## Separately gated follow-up: live smoke

Do not begin this from the handoff alone. A live smoke requires all of:

1. Human confirmation of the provider/auth method being evaluated.
2. Architecture approval for the DEBUG-only adapter seam.
3. Explicit user participation in any interactive login.
4. A local runtime configuration path that cannot enter source, fixtures, logs,
   screenshots, artifacts, or Release.
5. Redacted logging and a pre-run secret scan.
6. A stop plan that removes temporary auth state without touching other apps'
   credentials.

The first live acceptance target, if authorized later, is one separately labeled
smoke request that maps an auth failure truthfully or yields one valid, relevant
`PinDraft`. It is not acceptance of the end-to-end hero flow.

## Unresolved questions and risks

- Does the human intend browser auth, headless/device auth, or only protocol-shape
  reproduction? Do not implement both by assumption.
- Is reproducing OpenCode behavior for comparison sufficient, or is upstream code
  reuse intended? Code reuse needs license and architecture review first.
- The upstream auth path and backend behavior are version-sensitive and may rely on
  service behavior that TuberNotes should not adopt.
- A working local subscription login does not establish a distributable iPad auth
  design, gateway security, App Store suitability, or provider permission.
- Auth reproduction does not unblock the missing genuine lasso/crop pipeline by
  itself.
- A live-provider decision may require an external gateway/auth decision; `SPEC.md`
  says to stop and report at that boundary.

## Next bounded action

- Single next step: pin an upstream OpenCode release/commit, write a one-page
  behavior map from its Codex auth plugin, and implement the hermetic no-network
  reproduction tests described above.
- Files to inspect first: `SPEC.md` §10.1 and WP3,
  `TuberNotes/App/Contracts/AgentContracts.swift`,
  `TuberNotes/AgentHarness/AgentClient.swift`, and the two Agent/Verification review
  guides.
- Acceptance evidence: focused hermetic tests, secret scan, redaction proof,
  compatibility note, and a scoped evidence packet.
- Stop and report when the reproduction passes; when upstream behavior cannot be
  reproduced without a real credential/network call; when a shared contract,
  architecture, licensing, or provider decision is required; or on any risk of
  exposing user credentials.
- Human input is not required to begin the hermetic step. It is required before
  any real login, credential access, provider call, or live smoke test.
