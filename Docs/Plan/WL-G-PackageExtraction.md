# WL-G — PointBackKit package extraction + CanvasHost adapter API

Status: not-started
Owner: coordinator (this is THE architecture move; subagents only for
mechanical file moves after the API is settled)
Depends on: WL-F correction branch merged to `main`. Blocks everything else.

> **MANDATE (Phillip, July 20, 2026): reshape freely.** For this line, the
> AGENTS.md smallest-change/no-rewrite rules and the step boundaries below are
> ADVISORY, not binding. The session has full authority over structure, file
> layout, contracts, scenario definitions, verifier expectations, tooling, and
> docs — anything that serves the PointBackKit vision and the reframed DoD.
> The only hard rails: no secrets in source/fixtures/logs; report reality
> (failing tests are failing tests); commit in coherent reviewable increments
> so Phillip can roll back any of them; push when done. The steps and API
> sketch below are a starting shape, not a cage.

## Objective

Create the standalone SPM package and move the intelligence layer into it,
leaving the app as a thin reference host.

```text
PointBackKit/                        (new SPM package)
  Sources/PointBackKit/
    Contracts/        ← moved from TuberNotes/App/Contracts/ (public API now)
    AgentHarness/     ← moved (RecordedAgentClient, DebugCodex* spike, SSE)
    Knowledge/        ← moved (KnowledgeSearching)
    Pins/             ← moved (PinOverlayView, Pin)
    Investigation/    ← extracted from App: LassoState machine, action strip,
                        progress UI, PinDraft→PageAnnotation conversion
    Conversation/     ← extracted from App: Pin-tethered sidebar, thread state
    Host/             ← NEW: CanvasHost protocol + PointBackOverlay entry point
  Tests/PointBackKitTests/  ← AgentKnowledgeTests content moves here as real
                              XCTest; conversation continuation tests join it
TuberNotes/           (reference host app)
  App/                ← RootView shrinks to: scenario plumbing + CanvasHost
                        conformance + package overlay mounting
  SpatialCanvas/      ← stays app-side (it is A host, not THE layer)
  DeveloperSupport/   ← stays app-side (scenario fixtures drive the host)
```

## The adapter API (design target — refine while implementing, CONTRACT-flag it)

```swift
public struct PageRef: Hashable, Sendable { public let id: UUID; public let index: Int }

@MainActor public protocol CanvasHost: AnyObject {
    var pages: [PageRef] { get }
    var currentPageID: UUID { get }

    /// Page-normalized → current view coordinates; nil when off-screen/other page.
    func project(_ point: PageNormalizedPoint, on page: UUID) -> CGPoint?
    /// View → page-normalized on the hit page; nil outside any page.
    func unproject(_ point: CGPoint) -> (page: UUID, point: PageNormalizedPoint)?

    /// Render the VISIBLE composed content (background + ink) of the rect.
    /// This is the one hard requirement that makes any-canvas crops possible.
    func snapshot(_ rect: PageNormalizedRect, on page: UUID) async -> SelectionCrop?

    /// Change stream so overlays track page turns / viewport changes.
    var events: AsyncStream<CanvasHostEvent> { get }
}
```

Package entry point: a SwiftUI modifier (`.pointBack(host:agent:)` or an
overlay container) that mounts lasso capture (WL-H), the action strip, Pins
projection, and the conversation sidebar over any host view. Hosts with
native capture (reference host's SpatialCanvas) may inject a ready
`SelectionArtifact` instead of using the overlay gesture.

## Steps (bounded)

1. **Skeleton + contracts move.** Package manifest, move `Contracts/` with
   `public` access control, app depends on the package, everything still
   builds. Single `CONTRACT:` commit.
2. **Move the engine.** AgentHarness, Knowledge, Pins, conversation state +
   sidebar, investigation UI. App imports the package; behavior identical.
3. **Introduce `CanvasHost`.** Conform the reference host; route projection,
   snapshots, and page events through it; delete direct App↔SpatialCanvas
   couplings from the moved code.
4. **Conformance guide.** `PointBackKit/README.md`: the protocol, the worked
   reference-host example, what a host must persist (annotations, threads),
   and what the package guarantees. Written for the friend to adopt alone.

## Non-goals

- New features, visual changes, gesture changes (WL-F follow-up is separate)
- Portable lasso gesture (WL-H)
- Touching the friend's branch
- Renaming debates — `PointBackKit` is provisional

## Acceptance evidence

- `swift build` / `swift test` pass for the package standalone (macOS or iOS
  sim toolchain — no device needed for the package itself).
- Reference host: `hero-recorded`, `pin-conversation`, `agent-recorded-*`
  pass UNCHANGED on the pinned iPad (merge-gate tier + `blank-canvas` smoke).
- No `import` from the package back into app targets; dependency points one
  way.
- Conformance guide exists and names every host obligation.
- Evidence Packet.

## Stop conditions

- Step 4 done → stop; WL-H and WL-F follow-up unblock.
- The move forces a semantic contract change (not just access control) →
  CONTRACT-flag it, log it, continue; ownership questions → Phillip.
- Two reference-host verification failures without a narrower fix → stop.

## Session log

- (none yet)
