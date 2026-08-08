# Queue

Phillip's own notebook of open problems and where they stand — read this to
understand the state of the project, not to receive an assignment. Nothing
here blocks anyone from fixing what actually needs fixing. Pick up whatever
the codebase needs; if that happens to be described here, good, you have
context for free.

An item is removed or rewritten whenever Phillip's understanding of it
changes — fixed, no longer relevant, turned out to be wrong, or superseded by
something better understood. There's no required ceremony for that: edit it
in whatever pull request touches it, or edit it directly. The evidence that
something is actually done still lives in CI and the pull request, per
`CONTRIBUTING.md` — this file is a map of that reality, not the authority
over it.

*Blocked by* on an item is a note about risk and sequencing as Phillip
currently sees it — worth reading before you dive in, not a mechanical gate.
If you think the ordering no longer holds, say so and proceed.

### What a finished item leaves behind

In the commit message, not in a document:

- the CI run and what it actually proved;
- device and build identity, if device evidence was collected;
- what was **not** proven — every human-only check not performed; and
- anything found and not fixed — a defect goes to the code as a
  `KNOWN DEFECT:` block at its own site; a missing piece of evidence goes to
  [`Unproven.md`](Unproven.md).

An item whose exit includes a human-only judgment is not finished by an agent.
Record the evidence, hand it over, leave the verdict alone.

---

## contract-checker-is-blind — exit met; subdirectories are safe to create

The blindness is gone. `ContractStructureTests` no longer lists the source
directory: `ContractChecker.swiftFileURLs(under:)` walks it, at any depth,
skipping hidden entries, build products, and symbolic links. The rules became
pure functions over a directory URL, which is what made them testable — the
suite plants sources violating each of the three rules in a *new subdirectory*
of a temp tree and asserts each is caught, hermetically, so a failing run never
leaves the repository dirty. Reverting the recursion fails four of those tests.

The `names.isEmpty` guard is replaced by two: a floor on the plausible source
count, and a cross-check against a second, independent enumeration. The floor
alone would not have caught the original bug, whose top level was full.

Also landed while the walk exposed them: the import rule now reads
`@preconcurrency`, `@_exported`, `import struct UIKit.X`, `import UIKit.UIView`,
and post-semicolon imports, all of which a `trimmed == "import UIKit"`
comparison missed; the file-I/O rule reads `String(contentsOf:)`,
`OutputStream`, `fopen`, `.write(toFile:)`, and `UserDefaults`; the
`PKCanvasView` rule reads `.init(` and a space before the paren; and an
allowlist entry naming a file that no longer exists is now a failure, so the
throwaway spike's entry dies with its file rather than outliving it.

**Still review-only.** The forbidden-pattern list is untouched — see
[`Unproven.md`](Unproven.md). Two of its entries are decidable rather than
aesthetic, and neither is checked: a durable derived artifact reaching disk, and
a cache that states no bound. That is a separate item whenever it is worth one.
The token scan's own blind spots are recorded as `KNOWN DEFECT:` blocks beside
the rules they limit.

## loud-by-default — the loud path has still never run on an iPad

The mechanical half is done. `CanvasLog`'s stderr mirror carries no
configuration check: `TN_TRACE` is the sole gate, read once per process into a
`static let`, so a launch that does not set it pays a branch per event and never
materializes the environment. `Tools/device` grows `--release`, forwards
`TN_SPIKE_MIRROR_VARIANT` alongside `TN_TRACE`, and its digest looks for a trap
(`Fatal error:`, `Assertion failed:`, `EXC_BAD_ACCESS`, `SIGABRT`,
`Trace/BPT trap`, and the rest) **before** deciding a stream is empty — a crash
now reads as a crash. `Tools/device-tests` holds that digest against a fixture
per outcome and fails against the old one. `CONTRIBUTING.md` no longer claims a
Release build emits nothing, and now lists `CanvasLog` as *requiring* device
evidence, which is the honest consequence of shipping the loud path.

What is left is the part no build machine can do:

- **Nobody has watched a Release build talk.** `xcodebuild build -configuration
  Release` compiles; that is not the same as an iPad emitting through the mirror.
- **No planted trap has been seen through the fixed digest on real hardware.**
  The fixtures are hand-written consoles, not a console an iPad produced.

Spike 1 variant B answers both at once for free: it is expected to trap, and
that trap arrives on the same capture as the trace.

**Exit:** a Release build on a registered iPad, launched with `TN_TRACE` set,
produces a readable trace, and a real trap on that hardware is reported by the
digest rather than read as silence.



## failure-has-a-taxonomy — decide what loud means before writing more of it

*Invalid states fail loud* is the contract's strongest rule and the only one with
no mechanism. Today the same codebase answers a failure with
`preconditionFailure` for an unreachable Application Support directory, a thrown
error for a corrupt index, and `try?` inside dead code. Nothing says which is
right, so each new failure is classified by whoever happens to write it. (The
save path's former silent omission — a dirty page with no bytes — is now a trap,
and an unloadable page now surfaces as a refusing placeholder; both were fixed
by the Handovers rework, which chose their classifications case by case. The
classifier that would have decided them is still what this item is.)

The taxonomy is one ordered question set, first answer wins. Could correct code
produce this? No — trap. Is ink unsaved, unreadable, or about to be overwritten?
— alarm the person holding the iPad, then continue safely. Would a caller act
differently knowing? — throw a typed error and let the caller re-ask. Otherwise
it is an event, not a failure. There is deliberately no bucket for a failure that
is logged and continued from.

Three consequences, all violated today:

- `try?` has no legitimate use here. Two occurrences are inside
  `DocumentStore.deleteOrphanedPages`,
  which has no caller at all — delete it rather than fix it, since an orphan is
  inert by *Durable form* and nothing has ever needed pruning. Ban `try?` with an
  empty-allowlist structural test. The `Task.sleep` cancellations are already
  gone: one became the two-line `do`/`catch` when the debounce moved onto an
  injected clock, and the other went with the test-only save delay it guarded.
  What is left for the ban is `deleteOrphanedPages` and the lens image path's
  stacked `try?`.
- ~~`fetchPageData` throws out of its loop~~ — fixed: one unreadable page marks
  itself unreadable, is surfaced at the session boundary, renders as a refusing
  placeholder, and stalls neither its neighbours nor the launch. What remains
  for this item is the taxonomy itself and the typed error the placeholder
  message should carry.
- `EditorSession` produces `String(describing: error)` at three sites — session
  start, page load, save failure — and `RootCanvasView` renders those strings
  into the UI. Carry a typed value and render it with one exhaustive `switch` —
  the exhaustive switch is the mechanism that forces a human sentence per case.
  (One class already has that shape and can be copied: a refused layer carries a
  typed `RefusedLayer.Reason` and `EditorSession.refusalMessage` is the
  exhaustive switch over it. Its four sentences are provisional and are yours to
  write.)

There should be no divergence between the developer build and the shipping one.
A loud path that only DEBUG exercises has never run in the build that ships. That
makes one mechanical detail load-bearing rather than stylistic: traps are
`precondition`, never `assert`, because `assert` is removed under `-O` and every
distributed build is `-configuration Release`. `-Ounchecked`, which removes
`precondition` too, is forbidden.

This needs a `## Failure` section in [`Contract.md`](Contract.md) carrying the
classifier and the `try?` ban. Propose it as an exact edit; Phillip authors it.

**Exit:** a hand-corrupted page file produces a page that says so and refuses
ink. The user-visible half needs no Pencil and is provable in the simulator.

*Blocked by:* `loud-by-default`, which is how a trap would be observed at all.

## handovers-landed — the structural save-path rework awaits device evidence

The Handovers proposal's S1–S7 are in the code: retirement hands over a
drawing value synchronously; per-page ink state is one `Page` value with
named transitions (`dirtyPageIDs`, `pageData`, `retiredInk`, and
`unloadedPages` are gone); the save captures totally and acknowledges only
after the store returns; an unloaded or unreadable page is a placeholder,
never a canvas; `saveInFlight` and both waiter arrays are task handles; and
a turn commits only at rest, on the settle callbacks. Each closed finding
has a test that fails against the pre-change code.

What no test can prove, and what this item now is:

- **Turn feel after settling** is Phillip's verdict. The window refresh now
  happens at rest, so a fast multi-page flick may briefly show a loading
  placeholder where the old runtime built canvases mid-drag.
- **The placeholder itself** has never been seen on a device.

The contract amendments are done: Phillip approved and the `CONTRACT:` commit
landed the per-page ink state in *Owners*, the synchronous handover in
*Navigation*, capture-then-acknowledge in *Saving*, and the unreadable-page
refusal in *Lifecycle*.

**Exit:** Phillip accepts the settle feel and the placeholder on the iPad, or
returns bounded findings.

## turn-feel — Phillip's verdict on page turning

Nothing about paging has been exercised by hand. The unit tests drive turns by
setting `contentOffset`, which proves the bookkeeping and proves nothing about
the gesture.

Hand-exercise on the named iPad and record, before asking for a verdict:

- a swipe turns exactly one page and snaps; no resting position between pages;
- ink written on page N is on page N after turning away and back;
- swiping past the last page yields a blank writable page that survives a
  force-quit once written on;
- at fit-width a horizontal swipe turns the page; zoomed in and away from an
  edge it pans instead;
- turning continuously for a few minutes does not grow memory without bound,
  and the save trace names only changed pages;
- **mixed geometry**, since phase 3b: import a landscape PDF, swipe past its
  last page to append a blank canonical portrait one, and turn back and forth
  across the seam. A slot stayed one viewport wide and the page varies inside
  it, so the *scale* changes at the seam. Whether that reads as correct or as a
  glitch, and whether the grey either side of a narrower page is comfortable,
  is the part no simulator can answer;
- the zoom ceiling — now twenty device pixels per page point on every device
  rather than fit-width × 8 — is deep enough to write small at.

**Exit:** Phillip accepts the turn feel, or returns bounded findings.

*Was blocked by* loading marking pages dirty; that is fixed and pinned by
`turningAwayAndBackDoesNotRewriteThePage`, so the save-trace check can now
fail only for reasons that are about turn feel.

## image-format-is-heic — code landed; awaits the contract amendment

Phillip overruled the phase-2 mixed-format design (2026-08-07): image assets
consolidate onto **HEIC** — one format, hardware-decoded, with transparency.
The closed set in `AssetFormat` keeps `pdf` (a PDF is not an image, and the
small-export story stays whole for it) and loses `png` and `jpeg` as
image-usable formats.

Evidence behind the pick, checked against the APIs this code actually uses:

- HEIC carries alpha as an auxiliary image (`urn:mpeg:hevc:2015:auxid:1`);
  `CIContext.heifRepresentation` writes it and current ImageIO reads it back.
  The premultiplied-alpha decode bugs were iOS 12–14.
- Decode on Apple silicon is hardware-accelerated — at parity with JPEG and
  far past PNG, which is software zlib and 5–10× the bytes at photo sizes.
- The accepted loss: HEIC is lossy in practice (RGB→YCbCr means a PNG
  screenshot softens slightly on transcode), and the small-export story dies
  for images — the user gets back a HEIC, not the file they imported.

What it closes by construction: the alpha-flattening defect in the current
transcode-to-JPEG path — a TIFF or GIF with transparency imported through the
Files picker gets its transparent regions baked into the stored JPEG,
durably, because assets are write-once. One alpha-carrying format removes
the class.

Implementation surface, when picked up: `AssetFormat` narrows and
`ImageLayerRef.recognizedFormat` follows (the closed-set refusal stays — an
unknown format string on disk is still how a future format lands safely);
`ImageImportPreparation.prepare` keeps bytes only for HEIC sources and
transcodes everything else with orientation baked; the fixtures in
`ImageLayerTests`, `ImportPreparationTests`, `StaticLayerRenderTests`, and
`LensTests` move to HEIC. Existing documents are wiped — nothing in prod, no
migration, no refuse-shim.

Pin this first, before the import path moves: a test that encodes a CGImage
carrying real alpha to HEIC, reads it back through the renderer's
`downsample`, and asserts a transparent pixel is still transparent. If
`CGImageDestinationAddImage` does not embed the auxiliary image on this OS,
the encode goes through `CIContext.heifRepresentation` instead — this is
checkable in the simulator; do not discover it on a device. The compression
quality for HEIC is a fresh choice; 0.9 was JPEG's.

Contract amendment: the closed-set line in *Durable form* and the
small-export comments in `AssetRef.swift` change meaning. Exact edits
proposed in the PR; Phillip authors them.

**Landed** (`14d5666` pin, `d1ec58b` narrowing). The pin came back green:
`CGImageDestinationAddImage` does embed the alpha auxiliary image on this OS,
so the `CIContext.heifRepresentation` fallback is unused. The quality is 0.9,
reasoned afresh at its declaration rather than inherited. `png` and `jpeg`
now take the closed-set refusal, tested rather than assumed. The comment that
stood TIFF in for HEIC — "the simulator has no HEIC hardware encoder" — was a
hardware fact wrongly generalized to the framework, and is gone.

Proposed amendment text: `Docs/Forks/ContractPass/06-HEIC-amendment.md`.

**Exit:** the amendment is in `Contract.md` — the only part still open — and
a device session confirms the hardware encoder keeps alpha too, which no
simulator run can say. The rest is met: import transcodes PNG, JPEG, and
TIFF sources to `.heic` and passes HEIC through, and a transparent source
round-trips its alpha through import → store → downsample → composite.




## prove-ci — the verdict runs; only the fork half is left

`ci.yml` has run. Green on the real tip
([31236563458](https://github.com/256thFission/Tuber2fast/actions/runs/31236563458))
and red on a throwaway branch carrying one planted assertion
([31236586688](https://github.com/256thFission/Tuber2fast/actions/runs/31236586688),
branch since deleted). The red run is the one that mattered, and it produced
what the failure-reporting step was designed for: an annotation on
`RedProbeTests.swift:9` reading the actual `XCTAssertEqual` message, on the run
page, in a browser, with no Mac and no zip. The pinned-simulator guard resolved
the name out of `Tools/pinned-simulator` and found it on `macos-26`; nothing
was hardcoded. `ci.yml` references no secrets — checked, not assumed.

`device.yml` remains unrun; see `device-branch-builds`.

**What is left of the exit:** it says *a PR from a fork*, and `ci.yml`'s design
note says the no-secrets property "lets the repository stay public".
`Tuber2fast` is private, so that half cannot be met as written. Either the
repository goes public, or this exit should be reworded to what a private
repository can produce — a collaborator's branch, which is what both runs
above were. Phillip's call; see
[`Forks/ContractPass/00-ToolingReview.md`](Forks/ContractPass/00-ToolingReview.md).

Also open there: whether to pin an Xcode version alongside the image, and the
Node 20 deprecation warning both runs emit for `actions/checkout@v4` and
`actions/upload-artifact@v4`.

## tooling-review — the tooling has never been used by anyone else

`Tools/` is five files — `pinned-simulator`, `setup`, `device`,
`device-tests`, and `machines`. Everything mechanical about it has been
exercised on exactly one
Mac and one iPad: the device diagnosis to READY, BLOCKED, and
MISCONFIGURED; the digest against the fixtures now kept in `Tools/device-tests`;
the structural tests against a planted violation; the CI log parser against
compile, assertion, zero-test, and linker fixtures.

None of that is the same as someone else running it. Specifically unproven:

- **`Tools/device` has never completed a full session.** Build, install, launch,
  and the trace digest have not run end to end, because the iPad was locked
  throughout. Only the diagnosis phases have been exercised.
- **The untrusted-profile path has never fired.** It classifies an untrusted
  developer profile as BLOCKED rather than failure; nobody has seen it fire.
- **`Tools/setup` has never run on a machine without `Local.xcconfig`.** The
  branch that derives a team from the keychain, and the branch that refuses when
  there are zero or several, are both unexercised here.
- **`device.yml` has never run** — `ci.yml` now has; see `prove-ci`.

The premise held on the first outside read. `Tools/machines` never created
`Artifacts/` before writing into it, and `Artifacts/` is gitignored, so on the
clean clone this script exists for, three probes redirected into a directory
that was not there — bash kills the redirect before the command runs — and
each reported its own subject as broken: "compile failed", "the test run
failed", "none paired". A healthy Mac was told it could do `nothing yet`.
Fixed. The shape is the lesson: **a diagnostic whose first run on an unproven
machine blames the machine** gets disbelieved, and there is no second first
run. Two smaller unfired observations are recorded in
[`Forks/ContractPass/00-ToolingReview.md`](Forks/ContractPass/00-ToolingReview.md).

**Exit:** a second contributor reaches a working Xcode from a clean clone with
`Tools/setup`, and someone completes one `Tools/device` session and pastes its
identity block into a pull request. Nothing yet run here was run by anyone but
Phillip, which is the whole of what this item is.

## branch-protection — applied; one setting is a judgment call

`main` requires the `build-and-test` check, one approving review, and an
up-to-date branch; stale reviews are dismissed; force pushes and deletions are
refused; administrators are included.

Administrator enforcement is the setting to revisit: with one required approval
and no self-approval on GitHub, **Phillip cannot merge his own pull request
while he is the only contributor.** It is on because the exit says *cannot be
merged*, and a protection the owner clicks past is decoration for the same
reason a verdict that cannot go red is. The two commands that toggle it are in
[`Forks/ContractPass/00-ToolingReview.md`](Forks/ContractPass/00-ToolingReview.md).

Sharper than the settings: `main` is sixty-odd commits behind
`canvas-feature-complete`, and `build-and-test` has never run on `main`.
Whoever lands that branch meets these rules for the first time, on the largest
merge here so far.


## device-branch-builds — complete the one-time signing setup

`.github/workflows/device.yml` and [`DeviceBuilds.md`](DeviceBuilds.md) are
**written but have never run**. The workflow is complete — build, test, ad hoc
signing in a throwaway keychain, Firebase App Distribution — and every one of
its secrets is still absent, so it has never been contradicted either.

What remains is not code. It is the one-time setup in `DeviceBuilds.md`: a
Firebase project, an Apple Distribution certificate, an ad hoc profile listing
every contributor's iPad, and six GitHub secrets. Parts 1–4 need the Apple
Developer account holder; Part 5 needs each contributor to register their iPad.

Before the first real run, pin the Firebase action to a commit SHA rather than
`@v1`. It is third-party code that receives the service account credentials,
and a tag can be moved to point at different code.

**Exit:** a contributor pushes a branch and installs that build on their own
iPad within roughly five minutes, before it is merged.

Do this **before** `testflight-release`. For a canvas application, where CI
deliberately proves nothing about feel, merging on a green verdict and
discovering the problem afterward is backwards.

## testflight-release — the same `main` build on all six iPads

`push` to `main` (or a tag) → archive → export → upload. This workflow holds
the App Store Connect API key and distribution certificate as repository
secrets, so it lives in a **separate file** from `prove-ci` and is never
triggered by `pull_request`. GitHub withholds secrets from fork PRs, but the
file separation is what makes that guarantee verifiable by reading.

The paid membership is on an account none of this repository's contributors
administer. The holder must create an API key with the **App Manager** role —
Developer returns 401 on upload — and supply the Key ID, Issuer ID, and `.p8`.
That key is real, revocable access to their account; they should agree to it
knowingly rather than be handed a paste target.

**Exit:** all six contributors install the same `main` build from TestFlight on
their own iPad.

*Blocked by:* `device-branch-builds`, and an API key from outside the team.

---

## contract-cites-a-section-that-is-gone — *Empty trailing pages*

`Contract.md` — Navigation ends "Whether that page becomes durable is decided
by *Empty trailing pages*", and no such section exists: it was lost in the docs
restructure (`1559d2a`). Its last written form, yours, in
`f9cdbf3:Docs/Architecture/DataContract.md`:

> A page appended by swiping past the end is durable only once it takes ink. At
> most one never-written trailing page may exist in memory, and it is dropped at
> save time. This is the only permitted divergence between the pages on screen
> and the pages in the document.

The code now implements the first and third sentences: an appended page is
withheld from the index and from the page files until it takes ink, and the
divergence is exactly the trailing run. It does **not** implement "at most
one" — nothing stops a thumb from flicking past the end four times, and
`EditorSession.durableIndex` withholds all four rather than refusing the second.
Restoring the section is a rule, so it is yours to write; whether the cap is
part of it is the decision.

## Known risks

**macOS runner concurrency.** Free tiers cap concurrent macOS jobs well below
six; expect queueing. Every job needs macOS, so no verdict skips the queue.
`cancel-in-progress` keeps superseded runs from piling up. If queues still hurt,
restrict `ci.yml` to pull requests and `main` rather than every push.

First measurements, from the `prove-ci` runs: a full green pass is about three
and a half minutes, and two concurrent runs queued briefly rather than
serializing. With one contributor that is nothing. The number to watch is the
`build` step being run twice — `xcodebuild build` then `xcodebuild test` — which
buys separate logs for compile and assertion failures at the cost of most of the
wall clock. Worth revisiting only if six people actually make the queue hurt.
