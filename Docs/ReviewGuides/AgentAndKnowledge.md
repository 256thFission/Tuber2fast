# Agent and Knowledge review guide

## Purpose and current status

Use this guide for the recorded product Agent boundary, offline textbook search,
and the current recorded hero demonstrator.

| Capability | Status |
|---|---|
| Paced recorded Agent events | **IMPLEMENTED + FOCUSED-TEST VERIFIED** |
| Request-scoped cancellation and late-event suppression | **IMPLEMENTED + FOCUSED-TEST VERIFIED** |
| Retrieval, typed failure, and invalid-coordinate recordings | **IMPLEMENTED + FOCUSED-TEST VERIFIED** |
| Offline lexical textbook search | **IMPLEMENTED + FOCUSED-TEST VERIFIED** |
| Agent/Knowledge integration in a complete product workflow | **NOT APP-INTEGRATED** |
| `hero-recorded` Agent-to-Pin demonstrator | **PARTIAL / STUB** |
| Genuine lasso capture and PNG crop | **DEFERRED / NOT IMPLEMENTED** |
| Full Explain / Check / Ask and retry UI | **DEFERRED / NOT IMPLEMENTED** |
| Live provider networking/authentication | **DEFERRED / NOT IMPLEMENTED** |

Relevant implementation:

- `TuberNotes/AgentHarness/AgentClient.swift`
- `TuberNotes/Knowledge/KnowledgeSearching.swift`
- `TuberNotes/App/RootView.swift`
- `DeveloperTools/AgentKnowledgeTests/main.swift`

## Mechanical preflight

Compile and run the focused executable with strict concurrency enabled, then run
the stub scenario:

```sh
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  TuberNotes/App/Contracts/SpatialContracts.swift \
  TuberNotes/App/Contracts/DocumentContracts.swift \
  TuberNotes/App/Contracts/PinContracts.swift \
  TuberNotes/App/Contracts/KnowledgeContracts.swift \
  TuberNotes/App/Contracts/InteractionContracts.swift \
  TuberNotes/App/Contracts/AgentContracts.swift \
  TuberNotes/AgentHarness/AgentClient.swift \
  TuberNotes/Knowledge/KnowledgeSearching.swift \
  DeveloperTools/AgentKnowledgeTests/main.swift \
  -o /tmp/tubernotes-agent-knowledge-checks
/tmp/tubernotes-agent-knowledge-checks

DeveloperTools/device-preflight.sh --device <device-id>
DeveloperTools/verify-scenario.sh hero-recorded
```

Require `AGENT_KNOWLEDGE_CHECKS: PASS`. Privately confirm ordered events,
cancellation, invalid-coordinate rejection, stable search results, and the stub's
fresh runtime surface `recorded-hero-stub`.

## Correct review-packet boundary

Do not create a human acceptance packet for the pure Agent or Knowledge logic;
those are mechanically reviewed. A device packet may review only the visible
composition of `hero-recorded`, and must label it **PARTIAL / STUB** in both the
chat preflight and final evidence.

Recommended packet:

| Review label | Scenario | Mode | Human-only checks |
|---|---|---|---|
| Recorded hero stub composition | `hero-recorded` | Asynchronous Review Run | Status clarity, Pin readability, obstruction, overall visual hierarchy |

Safe visible questions include:

- “After the recorded response finishes, is the proposed Pin easy to understand?”
- “Does the expanded Pin obscure work you still need to read?”
- “Is the changing status understandable without explanation?”

Never ask the human to draw a lasso, judge crop accuracy, evaluate live AI quality,
or accept the end-to-end hero workflow; those behaviors do not exist. A PASS means
only that the recorded stub's composition is acceptable.

## Evidence and stop conditions

Keep focused-test output, stub scenario artifacts, explicitly collected or
uncollected screenshot/console/crash state, and human layout verdict. Stop on a missing completion state, missing proposed Pin,
invalid spatial output, unreadable/obscuring Pin, or any attempt to expand the
packet into acceptance of deferred behavior.
