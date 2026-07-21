# PC-11 — OpenAI-backed drawing refinement

Status: **stopped — private Codex route rejected image generation; retired as the Release hero path**

Target branch: `main`

Owners: `AgentHarness` owns model access, request transport, output decoding,
and auth invalidation. `SpatialCanvas` keeps lasso capture and preview/apply UI.
`Notebook` keeps document mutation and spatial placement.

## Objective and user-visible outcome

In the normal Release app, **Refine with AI** must no longer fail because
`TuberRefinementEndpoint` is absent. When the user has a temporary OpenAI
session, refinement sends the selected PNG as a Responses image input, requests
one edited image, previews the returned raster, and applies it only after the
existing explicit **Apply** action. Without a current login, the error must ask
the user to sign in rather than mention a backend endpoint.

This is a hackathon experiment over the same temporary ChatGPT/Codex-compatible
transport as PC-10. Official OpenAI documentation establishes image inputs and
the Responses `image_generation` tool, but does not guarantee that the private
ChatGPT Codex route accepts that tool. Phillip will perform the live verdict.

## Scope

- `TuberNotes/AgentHarness/DrawingRefinementClient.swift`
- `TuberNotes/Notebook/NotebookView.swift` only if composition needs wiring
- `TuberNotes/Notebook/AgentSidebarView.swift` for now-accurate service copy
- this child plan and the PC-11 parent entry

Explicit non-goals:

- no changes to lasso capture, containment, normalized rect/path, PencilKit,
  zoom/pan transforms, stroke deletion, image placement, persistence, or Apply;
- no API-key discovery, refresh token, persistent OAuth state, or silent fallback
  to Debug preview/recorded output;
- no public OpenAI API-key endpoint assumption for the ChatGPT OAuth token;
- no stale Debug/scenario/test/visual/human verification harness.

## Bounded implementation

1. Keep the existing configured backend behavior where one genuinely exists.
2. Otherwise, in Release, use an AgentHarness client that mints a fresh
   `OpenAICodexAccess` snapshot inside each `refine` call.
3. POST the selected PNG as a base64 data URL to the existing Codex Responses
   route with the same ephemeral networking, bearer/account headers,
   originator, request/session IDs, and no-cache policy as notebook analysis.
4. Request `image_generation` with edit intent. Use a bounded complete-JSON
   response and decode only the first `image_generation_call.result` base64
   value; require strict base64 and a decodable raster.
5. On expiry or HTTP 401/403, invalidate only the matching session generation
   and require relog. Map tool rejection, unavailable service, oversized output,
   and invalid images to redacted user messages while preserving the selection.
6. Keep the existing preview-first and explicit Apply behavior unchanged.

## Delivery evidence and stop conditions

Allowed delivery evidence is exact-device preflight followed by a fresh signed
Release build, install, and normal no-scenario launch. Phillip manually checks
sign-in, one lasso refinement, preview, Apply, and failure recovery. No provider
call will be automated.

Stop and report rather than widening scope if the Codex route rejects the
`image_generation` tool, returns no raster result, requires a public API secret,
or would require changing spatial/document contracts.

## Session log

- 2026-07-21 — Phillip's live manual attempt established that the private Codex
  route rejects `image_generation`. Per the plan stop condition, the temporary
  Release image-edit fallback is not the product hero path. The normal
  sparkle-lasso is being redirected to crop vision plus structured guidance
  Pins; it must not preview/apply a raster or delete ink. A separately
  configured dedicated refinement backend remains an independent future seam.

- 2026-07-20 — Phillip reported the normal Release error “AI refinement needs a
  backend endpoint.” Traced it to `DrawingRefinementClientFactory`: Release
  always creates `BackendDrawingRefinementClient`, while the app has no
  `TuberRefinementEndpoint`. Authorized the smallest experimental bridge to the
  temporary OpenAI session. OpenAI's current official image/Responses guides
  were consulted for input-image and image-generation output shape. No product
  code, account request, or device state changed during planning.
- 2026-07-20 — Added the Release fallback
  `OpenAICodexDrawingRefinementClient`. It captures fresh memory-only access per
  request, uses bounded ephemeral transport, asks the Responses image tool to
  edit the selected PNG, accepts only one decodable raster, invalidates only a
  matching session generation on 401/403, and replaces backend-configuration
  copy with actionable/redacted user errors. The existing configured backend,
  Debug preview, lasso geometry, document mutation, and explicit Apply path are
  unchanged.
- 2026-07-20 — Exact iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117` passed preflight. A fresh signed
  Release build succeeded, installed, and normally launched from
  `tmp/build/pc11-openai-refinement/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug build, scenario/test harness, automated provider request, or visual
  verifier ran. Reinstalling cleared the intentionally memory-only login;
  Phillip owns the fresh-login and live refinement verdict.
