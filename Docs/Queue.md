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

## contract-checker-is-blind — enforcement goes quiet exactly when it matters

`ContractStructureTests.appSources()` lists sources with
`contentsOfDirectory(atPath:)`, which does not recurse. The first `.swift` file
placed in a subdirectory of `TuberNotesApp/` drops out of all three
machine-checked rules — the single `PKCanvasView` construction site, the
UIKit/PencilKit import allowlist, and file I/O confined to `DocumentStore` — and
every test still passes. The `names.isEmpty` guard fires only if the top level is
emptied entirely.

This is the real reason there are no directories today, and it is the wrong
reason to have none. A checker that goes silent as the codebase grows is worse
than no checker, because its green run is read as evidence.

[`Unproven.md`](Unproven.md) records that the forbidden-pattern list is held by
code review alone. Two entries are now decidable rather than aesthetic: a durable
derived artifact reaching disk, and a cache that states no bound.

**Exit:** a `.swift` file planted in a new subdirectory, violating each of the
three rules, fails the suite. The recursion is covered by the checker's own
tests, because an untested checker can go dead and keep passing.

## loud-by-default — the build five people hold emits nothing

`CanvasLog`'s stderr mirror is wrapped in `#if DEBUG`. `device.yml` archives
`-configuration Release` and distributes that build to every registered iPad, so
the only sink a person can read without a Mac is compiled out of the only build
most contributors will ever run. The loud path has never been exercised by the
build that ships.

`TN_TRACE` is already the real gate, costs nothing on a home-screen launch, and
`devicectl --environment-variables` reaches an ad hoc build. Deleting the
`#if DEBUG` turns five iPads into evidence sources for every item below this one.

Two defects travel with it:

- `CanvasLog.event(logger, category, message)` passes a `Logger` and its own
  category name as separate arguments that must agree by hand at every call site.
  One value owning both removes the class of mistake.
- `Tools/device`'s `digest_trace` returns early unless the stream contains `TN[`,
  and counts fatals by grepping `TN[fatal]`. A Swift trap writes `Fatal error:`
  and neither. A crash during launch is therefore reported as
  `NO TRACE CAPTURED`, whose own text explains it as nothing having been
  observed — the tool's most alarming case reads as its most boring one. Grep for
  a trap before the no-trace gate, and correct `CONTRIBUTING.md`'s claim that a
  Release build emits nothing.

`CONTRIBUTING.md` lists `CanvasLog` as needing no device evidence.

**Exit:** a Release build on a registered iPad, launched with `TN_TRACE` set,
produces a readable trace, and a deliberately planted trap is reported by the
digest rather than read as silence.



## failure-has-a-taxonomy — decide what loud means before writing more of it

*Invalid states fail loud* is the contract's strongest rule and the only one with
no mechanism. Today the same codebase answers a failure with
`preconditionFailure` for an unreachable Application Support directory, a thrown
error for a corrupt index, `try?` for a page that will not load, and a silent
omission for a dirty page with no bytes. Nothing says which is right, so each new
failure is classified by whoever happens to write it.

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
  empty-allowlist structural test; the one real use, `Task.sleep` cancellation,
  is a two-line `do`/`catch`.
- ~~`fetchPageData` throws out of its loop~~ — fixed: one unreadable page marks
  itself unreadable, is surfaced at the session boundary, renders as a refusing
  placeholder, and stalls neither its neighbours nor the launch. What remains
  for this item is the taxonomy itself and the typed error the placeholder
  message should carry.
- `RootCanvasView` renders `String(describing: error)` into the UI. Carry a typed
  value and render it with one exhaustive `switch` — the exhaustive switch is the
  mechanism that forces a human sentence per case.

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
- The *Owners* wording still names the old fields; the amendment is drafted
  and awaits Phillip's authorship — no agent writes contract text.

**Exit:** Phillip accepts the settle feel and the placeholder on the iPad, or
returns bounded findings; the contract amendment is authored or refused.

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
  and the save trace names only changed pages.

**Exit:** Phillip accepts the turn feel, or returns bounded findings.

*Was blocked by* loading marking pages dirty; that is fixed and pinned by
`turningAwayAndBackDoesNotRewriteThePage`, so the save-trace check can now
fail only for reasons that are about turn feel.




## prove-ci — prove the shared verdict actually runs

`.github/workflows/ci.yml` is **written but has never run**. It is untracked,
uncommitted, and no push has exercised it. An unrun workflow is not CI; it is a
YAML file that has never been contradicted. The same is true of `device.yml`.

One job on `macos-26`: generate, build, test, and upload the logs on success
and failure. There is no separate Linux job: every check that decides runs on
macOS.

It references no secrets, so fork pull requests work unchanged and the
repository can stay public. Verify that stays true before merging it.

Run it to **green and to red**. The red run is the more valuable of the two: it
is the first evidence that the failure-reporting step produces a readable
answer, and no script in `Tools/` is in the path to confuse the diagnosis.

**Exit:** committed, and a PR from a fork produces a verdict a contributor has
actually read *on the run page* — not by downloading a zip.

*Blocked by:* the `origin` remote is `Tuber2fast`, and this branch has not been
pushed to it. Settle where this repository lives before wiring CI to it.

## tooling-review — the tooling has never been used by anyone else

`Tools/` is four files — `pinned-simulator`, `setup`, `device`, and
`machines`. Everything mechanical about it has been exercised on exactly one
Mac and one iPad: the device diagnosis to READY, BLOCKED, and
MISCONFIGURED; the digest against captured, empty, release, and crash fixtures;
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
- **Neither workflow has run at all** — see `prove-ci`.

**Exit:** a second contributor reaches a working Xcode from a clean clone with
`Tools/setup`, and someone completes one `Tools/device` session and pastes its
identity block into a pull request.

## branch-protection — make CI load-bearing

**Exit:** a PR whose CI run is red, or that has no approving review, cannot be
merged to `main`.

*Blocked by:* `prove-ci`. Without this, a red `main` is discovered by whoever
pulls next.


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

*Blocked by:* `testflight-prereqs`, and an API key from outside the team.

---

## Known risks

**macOS runner concurrency.** Free tiers cap concurrent macOS jobs well below
six; expect queueing. Every job needs macOS, so no verdict skips the queue.
`cancel-in-progress` keeps superseded runs from piling up. If queues still hurt,
restrict `ci.yml` to pull requests and `main` rather than every push.
