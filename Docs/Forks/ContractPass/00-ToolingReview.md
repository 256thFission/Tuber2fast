# `tooling-review` — what is now proven, and what still waits on Phillip

**This decides nothing.** It is the parallel track of
[`CanvasCompleteTodo.md`](../CanvasCompleteTodo.md) reporting back: what CI
actually did when it was finally run, what that run proves about `Tools/`, and
the four questions that are Phillip's to answer rather than an agent's to
guess. Queue.md remains the map; this file exists because two of its items now
have evidence and two of them now have a blocker with a name.

Verified against `28b7656`, on 2026-08-08.

---

## `prove-ci` — the verdict runs, and it can go red

`ci.yml` had never been executed. It has now been run four times against the
real tip, and both halves of the queue entry's demand are answered.

**Green.** [`run 31236563458`](https://github.com/256thFission/Tuber2fast/actions/runs/31236563458)
— `macos-26`, `xcodegen generate`, build, test, logs uploaded. Every step the
entry names did what it says. The pinned-simulator guard resolved
`iPad Pro 11-inch (M5)` from `Tools/pinned-simulator` and found it on the
runner; nothing was hardcoded and nothing was defaulted.

**Red.** [`run 31236586688`](https://github.com/256thFission/Tuber2fast/actions/runs/31236586688)
— one planted `XCTAssertEqual(1, 2)` on a throwaway branch, since deleted. The
red run is the one that mattered, and it is worth recording exactly what a
contributor sees, because that is the entry's actual exit condition:

> `TuberNotesTests/RedProbeTests.swift:9` — *failure* —
> `-[TuberNotesTests.RedProbeTests testCIActuallyFailsWhenATestFails] :
> XCTAssertEqual failed: ("1") is not equal to ("2")`

That is a GitHub annotation, rendered on the run page and on the pull request
diff, in a browser, with no Mac and no `gh` and no downloaded zip. The
`Explain the failure on the run page` step ran, parsed the log, and anchored
the annotation to the right file and the right line. The design premise of
that step — that two of six contributors have no Mac and must read the verdict
in a browser — is no longer an argument. It is an observation.

Three further things the runs settle:

- **The step order is honest.** In the red run `Build` succeeded and `Test`
  failed, so `Refuse a run with no executed tests` correctly *skipped* rather
  than firing on a log it had no business judging.
- **`ci.yml` references no secrets.** Checked, not assumed: the only
  occurrence of the string in the file is the comment claiming it. `device.yml`
  holds all eight. The separation the queue entry asks to verify holds.
- **A second check exists that nobody wrote.** GitHub's
  `copilot-pull-request-reviewer` runs on every pull request here. It is not
  required by branch protection and does not decide anything, but it will
  appear alongside `build-and-test` and someone will eventually ask.

**What this does not close.** The entry's exit says *a PR from a fork*, and
justifies the no-secrets design with "the repository can stay public".
`Tuber2fast` is **private today**. That is question 1 below.

## `branch-protection` — applied

`main` is protected. The exit condition — "a PR whose CI run is red, or that
has no approving review, cannot be merged to `main`" — is in force:

| Setting | Value |
|---|---|
| Required status check | `build-and-test` (github-actions, app 15368) |
| Require branch up to date | yes |
| Required approving reviews | 1 |
| Dismiss stale reviews | yes |
| Enforce for administrators | **yes** |
| Force pushes / deletions | forbidden |

`enforce_admins` is on because the entry says *cannot be merged*, and a
protection the owner clicks past is the same kind of decoration as a verdict
that cannot go red. It is also the one setting Phillip may want off: with one
required approval and admin enforcement, **he cannot merge his own pull
request while he is the only contributor** — GitHub does not count a
self-approval. One command relaxes it, and one restores it:

```bash
gh api -X DELETE repos/256thFission/Tuber2fast/branches/main/protection/enforce_admins
gh api -X POST   repos/256thFission/Tuber2fast/branches/main/protection/enforce_admins
```

**A caveat that matters more than the settings.** `main` is at `306ab29`, some
sixty commits behind `canvas-feature-complete`. Protection is now guarding a
branch nobody is working on, and `build-and-test` has never run on `main` at
all. Whoever lands `canvas-feature-complete` into `main` will be the first to
meet these rules, on the largest merge in the repository's history. Worth
doing deliberately rather than discovering.

## `tooling-review` — one real defect, found by reading, fixed here

The queue entry's premise is that `Tools/` has only ever been exercised by its
author on one Mac. That premise produced a defect on the first outside read,
and it is exactly the class the entry predicts.

**`Tools/machines` never created `Artifacts/` before writing into it.**
`Artifacts/` is gitignored, so it is absent from every clean clone — which is
the only kind of machine this script exists to diagnose. Three probes redirect
into it: the device compile, the simulator test run, and `devicectl`'s
`--json-output`. Bash fails a redirect into a missing directory *before the
command runs*, so each probe reported its own subject as broken — "compile
failed", "the test run failed", "none paired" — and the suggested role came out
`nothing yet` on a perfectly healthy Mac. `Tools/device` does the `mkdir -p`;
`machines` never did. Fixed in this branch.

The failure is worth naming as a shape and not just a bug: **a diagnostic whose
first run on an unproven machine blames the machine** teaches its reader to
stop trusting it, and there is no second chance at a first run. Three
co-contributors are about to run this script, once each, on the machines it was
written for.

### Exercised here

- **`Tools/device-tests`** — 35 expectations, 0 failed, from a clean worktree.
  The digest's crash fixtures hold: a Swift trap is reported as
  `THE PROCESS CRASHED` and never as `NO TRACE CAPTURED`, which is the
  `loud-by-default` finding closed and pinned.
- **`ci.yml`** — green and red, above.

### Still unproven, unchanged from the entry

- `Tools/device` has never completed a full session; the iPad was locked.
- The untrusted-profile BLOCKED path has never fired.
- `Tools/setup` has never run on a machine without `Local.xcconfig`.
- **And the one the entry is really about: none of this has been run by
  someone who is not Phillip.** Everything above was run on his Mac, from his
  clone. That is a better state than yesterday and it is not the exit.

### Two smaller observations, not fixed

Recorded rather than changed, because neither has been observed to fire and
the smallest change that proves the item is the rule:

- `Tools/machines` calls `/usr/bin/jq` with no presence check, where
  `Tools/device` checks for it and prints a remedy. If it were ever missing,
  `IPADS` becomes empty and the probe says "none paired" — blaming the iPad
  for a missing parser, the same misdirection as the `Artifacts/` bug. macOS
  ships `jq` at that path, so this is theory, not a sighting.
- `Tools/setup` does not verify `Local.xcconfig.example` exists before
  `sed`-ing it into place. If it were deleted, setup writes an empty
  `Local.xcconfig` and reports `wrote Local.xcconfig for team XXXXXXXXXX`. The
  file is tracked, so this needs someone to have deleted it first.

---

## Four questions that are Phillip's

**1. Is `Tuber2fast` staying private?** `prove-ci`'s exit says "a PR from a
fork", and `ci.yml`'s central design claim is that referencing no secrets
"keeps fork pull requests working and lets the repository stay public". The
repository is private, so the fork half of that exit cannot be met as written.
Either the repository goes public and the exit stands, or the exit should be
rewritten to what a private repository can actually produce: a pull request
from a collaborator's branch, which is what both runs above were. The
no-secrets property is worth keeping either way.

**2. Should `ci.yml` pin an Xcode version?** It pins the runner image
(`macos-26`) and the simulator (`Tools/pinned-simulator`) and nothing else, so
it takes whatever Xcode that image defaults to — 26.6 today, carrying iOS
26.2, 26.4, and 26.5, all three of which have `iPad Pro 11-inch (M5)`. The
image rolls forward. The existing guard catches a vanished simulator loudly
and by name, which is the failure mode `CONTRIBUTING.md` describes — but it
catches it *after* the toolchain has already changed underneath a green
history, which is the thing pinning the simulator was meant to prevent. The
argument against is real too: a pinned Xcode is a second value needing a
second home, against the deliberate shape of `Tools/` as one data file and
some scripts, and it will need bumping by hand. Left alone; it is a judgment
about how much determinism is worth, not a defect.

**3. `enforce_admins`, given he is currently alone.** See above. Applied as
the queue entry words it; one command off.

**4. Node 20 deprecation.** Both runs warn that `actions/checkout@v4` and
`actions/upload-artifact@v4` target Node 20 and are being forced onto Node 24.
Harmless today, a hard failure when GitHub finishes the removal. `@v5` of each
is the fix, and it is a one-line change to two workflows that nobody should
make while proving something else.

---

## What is left of the parallel track

`device-branch-builds` is untouched here and unchanged: the workflow is
written, and every one of its six secrets is still absent. Nothing in it is
code — it is the one-time Apple and Firebase setup in
[`DeviceBuilds.md`](../../DeviceBuilds.md), which needs the Developer account
holder. The pin-the-Firebase-action-to-a-SHA note in its queue entry still
stands and should happen before its first real run, because that action
receives the service account credentials.
