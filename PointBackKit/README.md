# PointBackKit

PointBackKit is the page-aware intelligence layer for a Swift canvas. The host keeps its canvas,
documents, navigation, ink, and persistence. The kit mounts Magic Lasso selection, the
Explain / Check / Ask loop, recorded and live agent clients, spatial Pins, and a Pin-tethered
conversation sidebar.

The package has no dependency on the TuberNotes app:

```sh
cd PointBackKit
swift build
swift test
```

## Host contract

Conform one main-actor object to `CanvasHost` and mount the modifier over the canvas view:

```swift
import PointBackKit
import SwiftUI

struct MyCanvasScreen: View {
    @StateObject private var host = MyCanvasAdapter()

    var body: some View {
        MyCanvas(document: host.document)
            .pointBack(
                host: host,
                agent: RecordedAgentClient(),
                configuration: PointBackConfiguration(
                    restoredArchive: host.pointBackArchive
                )
            ) { event in
                if case let .stateChanged(snapshot) = event {
                    host.save(snapshot.archive)
                }
            }
    }
}
```

`CanvasHost` has six obligations:

1. `documentID`, `pages`, and `currentPageID` identify stable logical pages. A single-canvas app
   supplies one page with index zero.
2. `projectToWindow(_:on:)` converts a page-normalized point to the host window's top-left
   coordinate system. Return `nil` for an off-screen page.
3. `unprojectFromWindow(_:)` performs the inverse hit test. Return `nil` outside a visible page.
4. `snapshot(_:on:)` renders the requested page-normalized rectangle into a crop containing the
   composed visible content—background plus ink—not PointBack overlays. Return `nil` if the page
   cannot be rendered truthfully.
5. `selectionContext(on:)` supplies optional document/page metadata sent to the agent.
6. `changes` emits after page-list, current-page, viewport, or composed-content changes. Emitting
   the correct case is what keeps selection glow and Pins tethered during page turns, pan, zoom,
   rotation, layout, and ink edits.

The package persists only page-normalized and crop-normalized coordinates. Window points are
transient. A Pin target must therefore survive viewport changes without being rewritten.

## Minimal adapter

```swift
@MainActor
final class MyCanvasAdapter: CanvasHost, ObservableObject {
    let documentID: UUID
    private(set) var pages: [PageDescriptor]
    private(set) var currentPageID: UUID?
    let changes: AsyncStream<CanvasHostChange>
    private let continuation: AsyncStream<CanvasHostChange>.Continuation

    init(documentID: UUID, pageID: UUID) {
        self.documentID = documentID
        pages = [PageDescriptor(id: pageID, index: 0)]
        currentPageID = pageID
        let stream = AsyncStream<CanvasHostChange>.makeStream()
        changes = stream.stream
        continuation = stream.continuation
    }

    func projectToWindow(_ point: PagePoint, on pageID: UUID) -> CGPoint? {
        // Apply the canvas's current page-to-window transform.
    }

    func unprojectFromWindow(_ point: CGPoint) -> (pageID: UUID, point: PagePoint)? {
        // Hit-test a page, then apply the inverse transform.
    }

    func snapshot(_ rect: PageRect, on pageID: UUID) async -> SelectionCrop? {
        // Render background + ink for rect and return encoded bytes plus exact pixel dimensions.
    }

    func selectionContext(on pageID: UUID) -> SelectionContext { .init() }
}
```

When a viewport changes, update the adapter's transform first and then emit:

```swift
continuation.yield(.viewport(pageID: pageID))
```

The inverse pair should round-trip the normalized corners, center, and a non-symmetric point such
as `(0.69, 0.49)` within `1e-6`. Test the same Pins before and after pan, zoom, and rotation.

## Snapshot rules

The input rect and `SelectionCrop.pageBounds` must match exactly. `pixelWidth` and `pixelHeight`
describe the encoded image, not UIKit points. PNG and JPEG are supported when `mediaType` is
truthful. Cap very large output, preserve aspect ratio, and never include credentials or private
diagnostics in image metadata.

The portable lasso path always calls this method. A host does not implement a lasso gesture and
does not hand PointBackKit a native selection artifact.

## Agent clients and credentials

`RecordedAgentClient` is deterministic, offline, paced, and cancellable. `LiveAgentClient` accepts
an explicit `LiveAgentConfiguration`; the host injects its endpoint, model, bearer token, and any
required headers at runtime. PointBackKit never reads a secret from source or stores a credential.
The current live adapter supports first-turn Responses-compatible `place_pins`; recorded mode is
the conformance and demo baseline, including conversation continuation. Ordinary thread replies
use transcript-only message events. A client adds another canvas Pin only by explicitly emitting
`pinStarted` / `pinCompleted` during that turn.

## Persistence boundary

On every `.stateChanged`, persist `snapshot.archive` in the host's document namespace. It contains
Pins and conversation records with stable page IDs and normalized coordinates, but no crop image
bytes or credentials. Pass it back as `PointBackConfiguration(restoredArchive:)`. When a restored
thread is reopened, the kit asks the host to snapshot the retained page bounds before sending a
new follow-up. Hosts may deliberately choose session-only storage, but must not silently persist
window coordinates.

## Reference host

The worked implementation is
`TuberNotes/App/ReferenceCanvasHost.swift`. `PointBackReferenceExperience.swift` mounts the modifier
over `SpatialCanvasView`, disables SpatialCanvas's native lasso path, forwards drawing and viewport
changes, composes dot-grid/PDF plus PencilKit ink in `snapshot`, and records verifier evidence.

Before integrating another canvas, verify:

- standalone `swift build` and `swift test` pass;
- a real lasso produces a non-empty background+ink crop;
- Explain, Check, and typed Ask reach the chosen `AgentClient`;
- Pins retain their logical anchors through pan, zoom, rotation, and page turns;
- the visible Follow Up affordance and a Pin hold both open the tethered sidebar;
- a recorded follow-up reuses its conversation ID and retained selection;
- restored archives render on the correct pages; and
- failure, cancellation, invalid coordinates, and missing snapshots leave host content untouched.
