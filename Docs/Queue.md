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

## loud-by-default — the loud path has still never run on an iPad

The mechanical half is done. `CanvasLog`'s stderr mirror carries no
configuration check: `TN_TRACE` is the sole gate, read once per process into a
`static let`, so a launch that does not set it pays a branch per event and never
materializes the environment. `Tools/device` grows `--release`, forwards
`TN_TRACE` (and, since the spikes were deleted, nothing else), and its digest
looks for a trap
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

*This paragraph named spike 1 variant B as the vehicle — it was expected to
trap, so the trap and the trace arrived on one capture. The spikes are
deleted, and "for free" was already false: variant B needed eight `#if` sites
reinstalled in `PageCanvasController` before it would install anything. Any
deliberate trap on device produces the same evidence for one line. The item is
otherwise unchanged, and this edit is a correction of a reference, not a
re-plan — revert it if you would rather keep the spike than the paragraph.*

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
