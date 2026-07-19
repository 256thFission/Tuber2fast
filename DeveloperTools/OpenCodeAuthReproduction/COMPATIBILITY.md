# TuberNotes compatibility note

This comparison does not change `AgentClient`, `AgentEvent`, or `AgentFailure`.
PKCE, callback, token, refresh, account-ID, and header states remain internal to a
hypothetical future adapter. Only a terminal investigation outcome would cross
the existing product boundary as a safe `AgentEvent.failed(AgentFailure)`.

| Reproduction outcome | Existing `AgentFailure.Code` | Boundary note |
|---|---|---|
| No usable auth or terminal re-auth requirement | `unauthorized` | Do not expose token or server details in the user message. |
| Callback, exchange, or refresh deadline | `timedOut` | Terminal failure; suppress later events. |
| Explicit user/task cancellation | `cancelled` | Matches the recorded client's terminal cancellation behavior. |
| State mismatch, replay, or malformed token shape | `invalidResponse` | Reject before a credential/header can become usable. |
| Adapter/transport/service unavailable | `unavailable` | Keep distinct from timeout and auth rejection. |

`refreshNeeded` and token expiry are internal states, not failures. Successful
refresh resumes readiness. A terminal refresh result determines the mapping:
auth rejection becomes `unauthorized`; timeout becomes `timedOut`; cancellation
becomes `cancelled`; malformed data becomes `invalidResponse`; and a service
outage becomes `unavailable`.

The frozen contract does not define a universal `recoverable` policy. A future
adapter would need product/architecture review before assigning it. In
particular, `unauthorized` is not meaningfully recoverable until an approved
re-authentication path exists.

Security boundary: this development harness is not the shipped multimodal agent.
It reads no Codex/OpenCode/Keychain/browser/environment credential, stores
nothing, and makes no provider request. Adding DEBUG auth, provider networking,
persistence, or a gateway remains a separately approved WP3 architecture step.
