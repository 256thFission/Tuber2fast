# PC-10 — Ephemeral OpenAI account login

Status: **implemented and installed — awaiting Phillip's live token-exchange
verdict**

Target branch: `main` (planned from `05d4af3`; reconfirm branch and HEAD before editing)

Owner: `AgentHarness` owns authentication state, credentials, provider routing,
and request authorization. `Notebook` only presents login controls and selects
the resulting runtime access for the normal Agentic Layer.

## Authorization and constraints

Phillip explicitly requested an OpenCode-style "Log in with OpenAI" plan and
accepted a hacky implementation that may require relogin. This authorizes a
bounded normal-Release implementation using memory-only access tokens and a
device-only Keychain refresh grant returned directly to TuberNotes. It does not
authorize credentials copied from another app, identity/access-token
persistence, or an unattended live-account smoke test.

The existing app/scenario test harness is currently out of sync with expected
behavior and must not be used for PC-10. Do not edit, launch, or cite `RootView`
scenarios, recorded-agent scenarios, `DeveloperTools/CodexAdapterTests`, or
other harness output as acceptance evidence. Phillip will manually verify the
normal app.

## Objective and user-visible outcome

In the normal Release app on iPad, OpenAI provider settings expose temporary
ChatGPT sign-in. Local Debug builds may additionally retain the existing API-key
and right.codes developer choices.

1. **ChatGPT sign-in (temporary)** — show a device code, open OpenAI's device
   sign-in page in an in-app Safari sheet, and become ready after the user
   authorizes it.
2. **API key** — preserve the current manually pasted OpenAI API-key path.

After temporary sign-in, the normal Agentic Layer can analyze the current page
or selection through the ChatGPT Codex Responses route. OAuth credentials live
only in process memory. Relaunch, expiry, HTTP 401/403, or explicit sign-out
returns the UI to **Sign in required**. Reauthentication is accepted.

This is a developer/demo convenience, not the production gateway in `SPEC.md`
section 10.1 and not a claim of officially supported third-party OpenAI login.

## Architecture decision

### Device authorization instead of a browser callback

Base the behavior on the public OpenCode v1.18.3 implementation at commit
`127bdb30784d508cc556c71a0f32b508a3061517`, specifically
`packages/opencode/src/plugin/openai/codex.ts`. Write a small original Swift
state machine; do not copy upstream source.

Use its headless/device-code branch:

1. Request a short-lived user code from OpenAI's device-authorization endpoint.
2. Display it in TuberNotes and open `https://auth.openai.com/codex/device` in
   an in-app `SFSafariViewController` sheet.
3. Poll at the server interval plus a conservative safety margin.
4. Exchange the returned authorization code and verifier at the OAuth token
   endpoint.
5. Extract the optional ChatGPT account ID, retain only access token, account
   ID, model, and expiry in memory, and discard ID and refresh tokens.

This avoids a loopback HTTP server, custom URL scheme, universal link, and
`ASWebAuthenticationSession` callback registration on iPad.

### Fail closed and require relog

- Never place OAuth values in `UserDefaults`, `@AppStorage`, Keychain, files,
  fixtures, environment variables, diagnostics, screenshots, or artifacts.
- Leave the existing API-key storage unchanged; never reinterpret it as a
  ChatGPT credential.
- Do not refresh. On expiry or 401/403, clear the matching in-memory session and
  require sign-in again.
- Never silently fall back from ChatGPT sign-in to a saved API key, right.codes,
  recorded output, or demo output.
- Sign-out clears TuberNotes memory only; say explicitly that it does not revoke
  a server-side grant.

Add a non-secret stored OpenAI access-method preference
(`chatGPTTemporary`/`apiKey`). It may survive relaunch; OAuth state may not.
Thus relaunch with temporary sign-in selected truthfully shows **Sign in
required**.

Introduce one AgentHarness-owned runtime value:

```text
AgentRuntimeAccess
├── provider(AgentProviderAccess)       existing API-key/right.codes route
└── openAICodex(OpenAICodexAccess)     temporary ChatGPT route
```

`OpenAICodexAccess` is an immutable, short-lived snapshot minted only while the
session is signed in and unexpired. It includes a session generation so a late
failure from an old request cannot invalidate a newer login. The normal
Notebook action requests a fresh snapshot immediately before analysis and
never stores it in document or persisted view-model state.

## Login state model

Published UI state must never contain bearer/refresh/ID tokens, account ID,
authorization code, or verifier.

| State | UI | Transitions |
|---|---|---|
| `signedOut` | Sign in with OpenAI | start |
| `requestingCode` | Preparing sign-in; Cancel | awaiting, failure, cancel |
| `awaitingUser` | Code; Open sign-in; Check status; Cancel | polling, expiry, failure, cancel |
| `polling` | Waiting for OpenAI; Cancel | awaiting, exchanging, expiry, failure, cancel |
| `exchanging` | Finishing sign-in | signed in, failure |
| `signedIn` | Signed in for this app run; Sign out | expiry, unauthorized, sign out |
| `failed` | Redacted error; Retry | start, signed out |

Rules:

- One attempt at a time. Restart cancels and invalidates the prior attempt.
- Use a five-minute monotonic deadline; background suspension does not extend it.
- A **Check status** action may resume polling after Safari, but must not create
  parallel polling loops.
- Classify cancellation, expiry, offline/unavailable, malformed response,
  exchange rejection, and provider rejection without showing raw bodies.
- The short user code may appear in live UI but never in logs or retained
  screenshots; visual artifacts use synthetic codes only.

## Normal-app request path

The first milestone wires temporary login only into:

```text
AgentSidebarView
  → NotebookViewModel.analyzeCurrentPage
  → AgentInsightClient
  → existing AgentInsight/Pin persistence
```

Add a normal-app Codex vision insight client that:

- sends the selection image and existing concise prompt using the Responses
  wire format to `https://chatgpt.com/backend-api/codex/responses`;
- replaces caller authorization with the temporary bearer token;
- sends optional `ChatGPT-Account-Id`, a fresh session/request ID, the required
  originator value, and a truthful TuberNotes user agent;
- uses an ephemeral `URLSession` without cookies, cache, or credential storage;
- parses bounded SSE or a complete Responses object through the existing
  `ResponsesSSEDecoder` and `ResponsesTextExtractor`;
- maps 401/403 to relog and invalidates only the matching session generation;
- returns existing `AgentInsight`, leaving Pin creation, conversation trees,
  spatial placement, and persistence unchanged.

Keep a separate Codex-compatible model list/default for temporary login. Start
with `DebugCodexConfiguration.defaultModel` and the models accepted by the
pinned OpenCode implementation. Centralize version-sensitive auth, route, and
model constants in the shared login source.

## Files in scope

Expected changes:

- `TuberNotes/AgentHarness/OpenAICodexLoginSession.swift` — new normal-app
  device auth, private tokens, expiry, cancellation, and access snapshots.
- `TuberNotes/AgentHarness/AgentClient.swift` — access-method preference and
  `AgentRuntimeAccess`; preserve existing provider access.
- `TuberNotes/Notebook/AgentInsight.swift` — temporary Codex Responses client
  and factory selection.
- `TuberNotes/Notebook/NotebookViewModel.swift` — accept runtime access and
  invalidate matching temporary access on authorization rejection.
- `TuberNotes/Notebook/NotebookView.swift` — make the normal toolbar-settings
  provider-status indicator reflect temporary sign-in rather than only API-key
  presence.
- `TuberNotes/Notebook/AgentSidebarView.swift` — access-method, login, device
  code, browser, retry/cancel/sign-out, model, and relog UI.
- `TuberNotes.xcodeproj/project.pbxproj` — new source membership only if needed.
- this child plan and the PC-10 entry in `Docs/Plan/PLAN.md`.

Explicitly out of scope:

- `TuberNotes/App/RootView.swift`, `TuberNotes/DeveloperSupport/`, all scenario
  fixtures/scripts, and `DeveloperTools/CodexAdapterTests/`;
- changes to `DeveloperTools/OpenCodeAuthReproduction/` (read-only provenance);
- refresh-token persistence, reusable provider secrets, Release entitlements,
  and production gateway implementation;
- persisted document, Pin, coordinate, page identity, archive, drawing, or
  refinement contracts;
- credential discovery/import from Codex, OpenCode, browsers, Keychain, or
  environment files.

`AgentRuntimeAccess` changes the shared Notebook/AgentHarness signature. The
eventual implementation commit must therefore use the repository's `CONTRACT:`
prefix and add a parent-plan log naming this type and why. It does not alter a
persisted contract. The later shared-contract log explicitly promotes temporary
account access to normal Release.

## Ordered implementation

### 1. Freeze baseline and upstream compatibility pin

- Confirm branch, HEAD, dirty files, build settings, and normal-app provider UI.
- Preserve unrelated `.claude/` and collaborator work.
- Record exact device-flow request/response fields from the pinned public source
  and centralize all version-sensitive constants.
- Confirm no existing normal-app code owns an OAuth session.

Exit: scoped inventory; no product mutation beyond planning.

### 2. Implement the in-memory session

- Add state, generation, deadline, cancellation, ephemeral network requests,
  strict response validation, and redacted errors.
- Decode account-routing claims in pinned priority: ID token before access
  token; root account claim, namespaced claim, then first organization ID.
  Treat it as optional routing metadata, not verified identity.
- Discard ID/refresh tokens after exchange and vend access only while unexpired.
- Clear on sign-out, expiry, matching 401/403, or process exit.

Exit: source inspection finds no persistence or diagnostic path for OAuth data.

### 3. Add explicit access selection

- Add the non-secret method preference and `AgentRuntimeAccess`.
- Preserve API-key/right.codes behavior and prevent automatic fallback.
- Make model choices route-aware. Reset an incompatible draft model on method
  change without deleting the saved API key.

Exit: one runtime value determines authorization, endpoint, model, and wire API.

### 4. Wire only the normal Agentic Layer

- Add the Codex vision client and reuse the bounded parser.
- Capture temporary access immediately before starting analysis.
- Preserve selection rendering, prompts, insight parsing, Pin creation,
  parent-thread behavior, normalized placement, and persistence.
- Clear matching login state on auth rejection and expose a concise relog action.

Exit: one real login-to-analysis path exists without any harness dependency.

### 5. Build the settings experience

- Present **ChatGPT sign-in (temporary)** in Release; Debug may additionally
  present the existing **API key** and right.codes developer choices.
- Explain that login is temporary, browser-authorized, and requires relog on
  launch/expiry.
- Make the device code readable/selectable and provide **Open OpenAI sign-in**,
  **Check status**, and **Cancel**.
- Keep progress alive if the popup closes/reopens during the same app run; never
  duplicate attempts.
- Show **Signed in for this app run** and **Sign out**, but no identity fields.
- On relaunch with temporary mode selected, block analysis with **Sign in
  required** instead of presenting demo output as live.

Exit: UI is accurate, recoverable, accessible, and does not claim official or
production support.

### 6. Non-harness mechanical checks

- Build Release with `TuberNotes.xcodeproj`, scheme `TuberNotes`, on
  the explicitly named physical iPad using the canonical device workflow.
- Confirm Release exposes only temporary account login, contains no reusable
  provider secret, and does not expose API-key/right.codes controls.
- Run `git diff --check`, project-membership inspection, and a credential-pattern
  scan over changed files and build artifacts.
- Inspect console output from no-account/synthetic failures for codes, tokens,
  account IDs, auth fields, request/response bodies, and user content.
- Do not launch or cite any scenario/test harness.

Exit: both configurations build and the diff remains inside PC-10 ownership.

### 7. Phillip's normal-app manual verification

After fresh confirmation to use the OpenAI account at that time, use the
installed normal Release app on the named iPad. Phillip manually verifies:

1. Open a real notebook and provider settings from the normal UI.
2. Choose temporary ChatGPT sign-in; confirm code readability and browser open.
3. Authorize, return, and confirm **Signed in for this app run**.
4. Analyze a real page/selection; confirm one relevant Pin in the normal tree.
5. Ask one follow-up; confirm it attaches to the expected branch.
6. Sign out; confirm the next request requires login without API/demo fallback.
7. Sign in again, force-close/relaunch, and confirm relog is required.
8. Cancel during code entry and polling; confirm no stuck/duplicate/late success.
9. Check portrait/landscape, keyboard, clipping, overlap, disabled actions,
   crash status, and understandable failure recovery.

Record Phillip's verdict and sanitized artifact paths only. Never retain a
screenshot containing a real device code.

## Acceptance evidence

- Normal Release exposes temporary ChatGPT sign-in; Debug additionally retains
  the existing API-key/right.codes developer methods without conflating them.
- OAuth data remains memory-only; relaunch/expiry requires relog.
- Temporary login authorizes one normal-app analysis and produces a relevant,
  persisted Pin after explicit live-use confirmation.
- 401/403, cancellation, timeout, malformed response, offline, and provider
  failure produce recoverable redacted states.
- API-key/right.codes behavior remains unchanged when explicitly selected;
  ChatGPT failure never silently falls back.
- Release builds, installs, and normally launches with the temporary login path.
- Credential scan and final scope/diff inspection pass.
- Phillip completes the normal-app checklist and supplies a verdict. No stale
  test-harness evidence is cited.

## Stop conditions

Stop and report rather than widening scope when:

- device endpoints/client registration reject TuberNotes or change shape;
- login succeeds but the Codex Responses route still returns 401/403;
- usable vision/text output requires a materially different agent contract;
- progress would require credential import, OAuth persistence, weaker iOS
  security, a reusable secret, or refresh-token persistence;
- two normal-app manual checks fail without a narrower diagnosis;
- a change crosses ownership beyond the authorized AgentHarness/Notebook seam.

Fallback is the existing explicitly selected API-key path or credential-free
demo. Never invent another unofficial login or copy credentials from another app.

## Demo gate and rollback

- Do not make temporary ChatGPT login the default method.
- Do not use it in a judged demo until Phillip completes three consecutive
  normal-app login-and-analysis runs on the pinned demo iPad.
- Rollback removes the temporary login UI/session/Codex client/runtime-access
  case from Release and Debug.
  No document migration or credential cleanup is needed because nothing is
  persisted.

## Session log

- 2026-07-21 — Phillip explicitly superseded the original no-refresh decision
  because repeated 2FA sign-in harms demo reliability. `CONTRACT:` persist only
  the returned refresh token in this iPad's device-only Keychain; keep access
  tokens and account routing in memory; silently refresh on launch, expiry, and
  matching authorization rejection; delete the Keychain item on rejected
  refresh or explicit sign-out. Passwords, 2FA values, ID tokens, authorization
  codes, verifiers, copied app credentials, and automated live-account checks
  remain forbidden.
- 2026-07-21 — Implemented the Keychain refresh grant and silent restoration
  path. Fresh sign-in deletes any older grant before account selection;
  successful exchange stores only a returned refresh token with
  `AfterFirstUnlockThisDeviceOnly`; rotated tokens replace it; sign-out and
  rejected refresh delete it. Generic unsigned Release build succeeded at
  `tmp/build/pc10-keychain-refresh/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No scenario/test harness, device action, automated login, or provider request
  ran; Phillip owns the live refresh verdict.
- 2026-07-20 — Planned an ephemeral Debug-only device-code login from current
  `main` at `05d4af3`. Chose relog on launch/expiry and no refresh persistence.
  Scoped the milestone to the normal Agentic Layer insight path. At Phillip's
  direction, excluded the stale app/scenario test harness and assigned final
  interaction verification to Phillip in the normal app. No product source,
  account login, browser action, or live provider request was performed.
- 2026-07-20 — Phillip authorized implementation and requested extensive
  subagent use. Added the PC-10 go-mode override to `AGENTS.md`: no behavioral,
  scenario, adapter, reproduction, visual, device, or human-review verification
  during implementation; only a post-implementation compile/build-readiness
  check is permitted before Phillip's normal-app verdict.
- 2026-07-20 — Implemented with three bounded subagent work packets and a
  coordinating integration pass. Added the Debug-only, memory-only device-code
  session; explicit API-key versus temporary-ChatGPT access selection; bounded,
  redirect-denying Codex Responses vision transport; generation-scoped relog;
  route-aware models; complete login/status/cancel/sign-out UI; and truthful
  normal toolbar configuration state. `AgentRuntimeAccess` is the shared
  Notebook/AgentHarness seam; no persisted notebook or spatial contract changed.
  Preserved unrelated `.claude/` content and all stale harness surfaces.
- 2026-07-20 — Post-implementation build readiness: unsigned generic-iOS Debug
  and Release builds both succeeded. Logs:
  `tmp/build/pc10-openai-login/debug/build.log` and
  `tmp/build/pc10-openai-login/release/build.log`. The Release binary contains
  none of the OAuth issuer, direct Codex route, temporary-login symbol/copy, or
  pinned public client identifier checked. No device preflight, install,
  launch, scenario, adapter/reproduction test, behavioral verification, human
  review session, browser login, or live provider request was performed.
  Implementation stops for Phillip's normal-app verification.
- 2026-07-20 — Phillip clarified that the target is the normal Release app, not
  Debug, and asked why the iPad had not been rebuilt. Revised `SPEC.md` section
  10.1 and the PC-10 override, promoted only the temporary memory-only account
  route to Release, kept API-key/right.codes UI Debug-only, and rebuilt the
  signed Release app for exact physical iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117` (Phillip's iPad, iOS 26.5.2). Build,
  install, and normal no-scenario launch succeeded. Logs:
  `tmp/build/pc10-release-device/build.log`,
  `tmp/build/pc10-release-device/install.log`, and
  `tmp/build/pc10-release-device/launch.log`. No scenario/test harness,
  automated behavioral verification, browser login, or provider request ran;
  Phillip's normal-app verdict remains outstanding.
- 2026-07-20 — Phillip requested an embedded browser immediately. Reopened
  PC-10 for the smallest UI-only change: retain device authorization and
  memory-only tokens, replace the external browser link with an in-app
  `SFSafariViewController` sheet, keep the one-time code visible above it, and
  dismiss the sheet when authorization completes. No runtime protocol or
  credential boundary change.
- 2026-07-20 — Implemented the embedded Safari sheet in
  `AgentSidebarView.swift`. Its identity is independent of polling state;
  closing/reopening it does not cancel or restart the one active login attempt,
  the code remains selectable above the browser, and token exchange or a
  terminal login state dismisses it. Exact physical iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117` passed preflight. A fresh signed
  Release build succeeded, installed, and normally launched with no scenario,
  Debug, visual verifier, login automation, or provider request. Installed app
  artifact: `tmp/build/pc10-embedded-browser/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  Phillip's live sign-in and behavior verdict remains intentionally manual.
- 2026-07-20 — At Phillip's request, repeated delivery from a second fresh
  DerivedData directory. Exact-device preflight passed, the clean signed
  Release build succeeded, and that newly produced artifact was installed and
  launched on Phillip's iPad at 21:00 local time. Artifact:
  `tmp/build/pc10-embedded-browser-rebuild2/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug, scenario, verifier, or login automation ran.
- 2026-07-20 — Reopened after the persistent in-app Safari session continued
  the wrong OpenAI account with no account chooser. The bounded repair keeps
  normal shared-browser SSO and adds an explicit ephemeral system-auth route
  for a different account. It reuses the same device code and independent
  poller, copies the visible one-time code only on explicit tap, and cannot
  reuse normal browser cookies. Release rebuild/install is pending.
- 2026-07-20 — Completed wrong-account recovery. The normal in-app Safari path
  remains available for shared-browser SSO; **Copy code & use a different
  account** presents the same verification URL in a retained ephemeral
  `ASWebAuthenticationSession`, preserving the active poller and dismissing on
  exchange/terminal state. Exact-device preflight, fresh signed Release build,
  install, and normal launch succeeded on Phillip's iPad at 21:11 local time.
  Artifact: `tmp/build/pc10-account-switch/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug, scenario, verifier, automated login, or provider request ran.
- 2026-07-20 — Reopened at Phillip's direction so every primary **Sign in with
  OpenAI** action defaults to a cookie-isolated session. Shared Safari SSO will
  remain only as an explicit secondary reuse-existing-session action. Release
  rebuild/install is pending.
- 2026-07-20 — Phillip's live browser authorization completed, but token
  establishment failed as an unexpected response. The strict Swift decoder
  required `id_token` and `refresh_token`, even though the pinned implementation
  only uses an optional ID token at runtime and TuberNotes deliberately never
  refreshes. Relaxed only those unused fields, retained nonempty
  `access_token`, and made numeric expiry accept a finite positive value. No
  response body, token, code, or account identifier is logged or persisted.
- 2026-07-20 — Completed and delivered both repairs. Primary sign-in/retry now
  automatically copies the new one-time code and opens a cookie-isolated system
  authentication session; reuse of an existing browser session is explicitly
  secondary. The token decoder accepts optional unused ID/refresh material,
  requires the access token, and keeps optional claim extraction and finite
  positive expiry validation. Exact-device preflight, fresh signed Release
  build, install, and normal launch succeeded on Phillip's iPad at 21:22 local
  time. Artifact: `tmp/build/pc10-token-decoder/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug, scenario, verifier, automated login, or provider request ran.
