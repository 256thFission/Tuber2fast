# OpenCode Codex auth reproduction

This development-only harness is an original, behavior-level reproduction of a
bounded subset of OpenCode's built-in OpenAI/Codex browser authentication path.
It uses only the Python standard library, an in-memory scripted transport, and
unmistakably synthetic values. It does not install or execute OpenCode, open a
browser, bind a socket, read credentials, persist tokens, or make a network call.

## Immutable upstream pin

- Release: [OpenCode v1.18.3](https://github.com/anomalyco/opencode/releases/tag/v1.18.3), published 2026-07-16
- Tag commit: [`127bdb30784d508cc556c71a0f32b508a3061517`](https://github.com/anomalyco/opencode/commit/127bdb30784d508cc556c71a0f32b508a3061517)
- Studied source: [`packages/opencode/src/plugin/openai/codex.ts`](https://github.com/anomalyco/opencode/blob/127bdb30784d508cc556c71a0f32b508a3061517/packages/opencode/src/plugin/openai/codex.ts)
- Upstream tests: [`packages/opencode/test/plugin/codex.test.ts`](https://github.com/anomalyco/opencode/blob/127bdb30784d508cc556c71a0f32b508a3061517/packages/opencode/test/plugin/codex.test.ts)

The tag commit is the pin. The release API's `target_commitish` currently names
its parent, so it is not used here. The plugin moved from the handoff's earlier
`src/plugin/codex.ts` path to `src/plugin/openai/codex.ts` in this release.

OpenCode is [MIT licensed](https://github.com/anomalyco/opencode/blob/127bdb30784d508cc556c71a0f32b508a3061517/LICENSE).
No upstream source was copied or substantially adapted into this harness.

## One-page behavior map

The pinned browser method creates a 43-character verifier from secure random
bytes, derives an unpadded base64url SHA-256 challenge, and creates a separate
32-byte base64url state value. Its loopback callback requires exact state, has a
five-minute deadline, and clears the single pending attempt on success, mismatch,
provider error, missing code, or cancellation. Clearing before token exchange
makes the callback single-use.

Synthetic response decoding here models access/refresh values, the default
3,600-second lifetime, and `now + expires_in`. The pinned request adapter refreshes
only after expiry (not at the exact boundary), rotates the token set, and retains
the prior account ID when a refresh omits one. The upstream implementation also
deduplicates concurrent refreshes; concurrency is recorded as observed behavior
but is outside this single-attempt state-machine spike.

Account ID extraction decodes, but does not verify, a JWT payload. It checks the
ID token before the access token, then prefers a root `chatgpt_account_id`, the
namespaced OpenAI auth claim, and finally the first organization ID. The value is
optional. This is reproduced only with synthetic JWT-shaped values assembled in
memory by tests.

The pinned adapter removes caller authorization, adds its current bearer value
and optional account ID, rewrites selected request paths, adds OpenCode/session
headers, and adjusts a request parameter. This harness reproduces only header
replacement and redacted diagnostics; it creates no request and exposes no
endpoint. All diagnostic header values are redacted, including possible user
content, and the in-memory transport records counts rather than auth inputs.

## Scope and caveats

This is research evidence, not an approved TuberNotes auth design. OpenCode's
singleton callback is not safe for concurrent attempts, JWT claims are not
signature-verified by this behavior, and its endpoints/constants are
version-sensitive rather than a stable provider API. OpenCode documentation's
Plus/Pro recommendation does not establish terms or approval for a distributable
third-party iPad integration.

Observed but not reproduced: headless/device authorization, manual API-key
storage, a real loopback listener, refresh single-flight coordination, provider
request routing, model filtering, WebSockets, OpenCode installation, and any live
login or provider call. No product code, frozen contract, Xcode target, Release
behavior, credential store, or recorded hero path is changed.

## Run

From the repository root:

```sh
DeveloperTools/OpenCodeAuthReproduction/run-checks.sh
```

The runner executes focused tests with bytecode generation disabled, applies a
network-denial guard to the complete success/refresh flow, scans the entire
harness plus generated logs for credential-shaped content, and prints its
retained artifact directory under `tmp/verify/`.
