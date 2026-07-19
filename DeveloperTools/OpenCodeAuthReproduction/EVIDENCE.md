# Evidence packet — OpenCode auth reproduction

## Objective

Reproduce the pinned OpenCode browser-auth behavior in a development-only,
no-secret, no-network harness and compare terminal states with TuberNotes'
existing Agent failure vocabulary without changing product contracts.

## Changed files

- `DeveloperTools/OpenCodeAuthReproduction/opencode_auth_reproduction.py`
- `DeveloperTools/OpenCodeAuthReproduction/tests/test_auth_reproduction.py`
- `DeveloperTools/OpenCodeAuthReproduction/scan_secrets.py`
- `DeveloperTools/OpenCodeAuthReproduction/run-checks.sh`
- `DeveloperTools/OpenCodeAuthReproduction/README.md`
- `DeveloperTools/OpenCodeAuthReproduction/COMPATIBILITY.md`
- `DeveloperTools/OpenCodeAuthReproduction/EVIDENCE.md`

## Diff summary / scope check

- Added an original standard-library state machine for PKCE/state, single-use
  callbacks, synthetic token/expiry/refresh state, optional synthetic JWT account
  ID extraction, and redacted in-memory header construction.
- Added focused tests, a source/artifact credential-shape scanner, an offline
  runner, the immutable upstream pin/behavior map, and the contract comparison.
- Final diff stayed in requested scope: yes.
- Ownership violations or unrelated churn: none; no product, Xcode target,
  contract, app asset, Release, recorded-agent, or existing untracked file changed.

## Build

- Result: not applicable. The bounded reproduction is Python development tooling
  outside `TuberNotes.xcodeproj`; the handoff explicitly requires harness
  conformance rather than an Xcode/iPad review packet.
- Destination: not applicable.

## Verification

- Command: `DeveloperTools/OpenCodeAuthReproduction/run-checks.sh`
- Result: 16 focused tests passed; both source/artifact secret scans passed.
- Expected state: success, exact-state mismatch, replay, timeout, cancellation,
  malformed synthetic token data, expiry/default expiry, refresh-needed behavior,
  optional account ID, failure mapping, header replacement/redaction, scanner
  positive/negative cases, and a network-denied end-to-end synthetic flow pass.
- Artifact directory:
  `tmp/verify/opencode-auth-reproduction.VGLn59/`
- Test log: `tmp/verify/opencode-auth-reproduction.VGLn59/tests.log`
- Secret-scan log:
  `tmp/verify/opencode-auth-reproduction.VGLn59/secret-scan.log`
- Screenshot / scenario / console / crash status: not applicable; no app or UI ran.

## Mechanical checks

- [x] Secure default randomness with deterministic injection only in tests.
- [x] Exact callback state, terminal mismatch, and callback replay rejection.
- [x] No network-client import; success/refresh pass with socket connection denied.
- [x] No credential persistence, real credential reads, browser login, or endpoint.
- [x] Diagnostic header values and possible user-content headers redact by construction.
- [x] Changed source plus generated test/scan logs pass the credential-shape scan.
- [x] Harness runs with the system Python standard library; OpenCode is not required.

## Separately authorized live smoke

The human later explicitly authorized one browser-login smoke against OpenCode's
undocumented provider route. A temporary, process-isolated runner reproduced the
pinned v1.18.3 request shape, accepted the OAuth callback only after exact state
validation, kept credentials in process memory, and allowed one provider request
with no retry. The temporary runner and its focused tests were removed after the
run.

- OAuth callback and token exchange: succeeded.
- Provider route: `POST /backend-api/codex/responses` on `chatgpt.com`.
- Provider HTTP status: `200`.
- Expected pinned behavior: attempt SSE parsing for every 2xx response body,
  regardless of the response's declared media type.
- Observed behavior: the temporary runner received HTTP 200 but incorrectly
  rejected the response based on its media type before reading or parsing its body.
- Compatibility result: **inconclusive**. The runner diverged from OpenCode's
  pinned response handler, so this run cannot be classified as either a successful
  stream or `invalidResponse`. HTTP 200 proves the route was reached without a
  direct 401/403 rejection, but not semantic acceptance or generated output.
- Sanitized artifact:
  `tmp/verify/opencode-live-smoke.ycrD69/evidence.json`.
- Post-run source/artifact secret scan: passed.
- Cleanup: callback server and network connections closed, the credential-holding
  process exited, browser tabs were finalized, and the temporary live source was
  deleted.

Known evidence limitation: the artifact's `providerRequestCount` is `0` because
the temporary counter was copied into the evidence object only after successful
response parsing. The request was sent exactly once before the HTTP 200 was
received; no retry occurred. This instrumentation defect does not change the
protocol result, but the counter must not be interpreted as "no request sent."

## Human-only checks still required

None for the hermetic reproduction. Human participation was collected for the
separately authorized live login. A DEBUG product adapter still requires a shared
architecture/provider decision.

## Stop reason / unresolved issues

The bounded reproduction acceptance evidence and the separately authorized
one-request smoke evidence are collected. Work stops after the inconclusive HTTP
200; the one-request constraint forbids a diagnostic retry. This spike does not approve
ChatGPT/Codex OAuth, provider terms, a distributable iPad auth design, or upstream
source reuse.
