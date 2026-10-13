# Working here

`AGENTS.md` says what the rules are. This file says how to actually work here
without producing confident nonsense. Read both before touching code. It
applies to humans and agents alike.

New to the repo? `README.md` gets you from a clone to a running app in two
commands. Start there, then come back.

## The loop

`Docs/Queue.md` is Phillip's notebook for tracking state, not a work
assignment system. Skim it to see what's known and what's already being
tracked, but decide what to work on from what the codebase actually needs —
not by claiming a numbered slot.

1. Read `Docs/Contract.md`. If `Docs/Queue.md` already describes the problem
   you're about to touch, read that entry too — it likely has context
   (why it's hard, what blocks it, what's been ruled out).
2. Before editing, state: acceptance evidence, files in scope, non-goals,
   stopping condition.
3. Edit.
4. Build and test locally, with the commands CI runs.
5. Commit. Say in the message what evidence you actually have — and what you
   don't. Anything found and not fixed is recorded before you stop — see
   "Where a fact goes" below. If your change resolves or changes the state of
   something written in `Docs/Queue.md`, update or remove that entry in the
   same commit so Phillip's notes stay true — a courtesy update, not a gate.
6. Phillip pushes to `main`, and CI runs on the push. There are no pull
   requests.

You are not done when the code compiles. You are done when Phillip has pushed
it, CI is green on that commit, and the item's human-only checks have been
handed to Phillip.

**Do not write a progress document.** There is no status board, no session log,
and no milestone file, deliberately — the same fact in two places is the same
fact that will disagree with itself. Commit messages carry the narrative, CI
carries the evidence, and `Docs/Queue.md` shrinks. If you
catch yourself wanting to record that something is complete, delete it instead.

If a rule itself changed, rewrite `Docs/Contract.md` in place — present tense,
no "superseded", no history — and tag the commit `CONTRACT:`. Cite contract
sections by name; there are no numbers.

## Where a fact goes

Every fact has exactly one home, chosen so it cannot drift from what it
describes. There is no decisions log and no defect list.

| Fact | Home | Why there |
|---|---|---|
| A rule that is in force | `Docs/Contract.md` | normative, present tense |
| **Why** that rule exists, where a reader would otherwise get it wrong | next to the rule — in `Contract.md` or at the code site | cannot drift from what it explains |
| Why we chose something, as history | the commit message | `git log -p` has dates and authorship |
| A defect we are not fixing now | a `KNOWN DEFECT:` block **at the code site** | moves with the code, dies when fixed |
| A claim we have not earned | `Docs/Unproven.md` | belongs to no single line of code |
| Phillip's read on what's open, risky, or blocked | `Docs/Queue.md` | his notebook, not a queue an agent must drain in order |

The test for whether a "why" is worth writing down: **would a new contributor
make a mistake without it?** If yes, it is a live constraint — put it next to
the rule. If no, it is archaeology, and `git` already has it.

An append-only decisions log keeps reversed entries readable as if still in
force; a defect list pinned to line numbers must be re-verified against source
on a schedule. Both structures rot by design, not through neglect — which is
why neither exists.

## CI is the arbiter

The generate/build/test commands live in `AGENTS.md`, under **Build** — their
one home. `.github/workflows/ci.yml` runs exactly those on pushes to `main`,
after building the app in Release, and keeps the build and test logs of every
run as a downloadable artifact.

The default gate never runs the benchmarks in `HistoryEntryCostTests`; it
reports them as skipped. They read the wall clock and process-wide memory, so
a simulator starved by other work fails them, and a gate that fails under load
teaches people to rerun it. They run only when `TN_BENCHMARKS` is set, which
the `TuberNotesBenchmarks` scheme does. Run them alone, on an idle machine:

```bash
xcodebuild test -project TuberNotes.xcodeproj -scheme TuberNotesBenchmarks \
  -only-testing:TuberNotesTests/HistoryEntryCostTests \
  -destination "platform=iOS Simulator,name=$(< Tools/pinned-simulator)"
```

`-only-testing` keeps the other hosted suites out of the measurement. The
scheme cannot select the suite itself; its comment in `project.yml` says why.

**CI calls no script in `Tools/`, deliberately.** What "green" means has to stay
readable without running anything we would factor into it, so the workflow
spells out `xcodebuild` and its few guard lines rather than calling a program.
`Tools/` is a convenience; it never decides whether work is done.

The simulator is pinned on purpose. A moving destination makes results
incomparable between runs, and runner images have shipped an Xcode whose
matching iOS runtime was absent — which surfaces from `xcodebuild` as an opaque
destination error.

`Tools/pinned-simulator` holds that name and is the only place it is written —
`ci.yml` and the commands in `AGENTS.md` read it. It is a bare value with no
`KEY=`, because the device name contains spaces and parentheses and so is not
valid shell to `source`. There is no fallback anywhere: a missing pin fails the
run naming the file, per the contract's rule that nothing is silently
defaulted.

**Green CI means it compiled and the tests passed. That is all it means.** It
is not evidence about ink, and saying otherwise in a commit message is lying
about the state of the project.

## Device evidence

The simulator has no Apple Pencil. Drawing, erasing, palm rejection, and
pressure cannot be proven off-device at all, so some changes are not finishable
by CI no matter how green it is. Which changes need evidence from a physical
iPad is stated once, in `AGENTS.md` under **Definition of done**.

When a change needs it and it was not done, say so in the commit message and
add it to `Docs/Unproven.md`. That is a legitimate answer; quietly skipping it
is not.

## Device work

```bash
Tools/device --check      # every precondition, then stop
Tools/device --install    # ...then build and install, but no capture session
Tools/device              # ...then build, install, launch, and capture
Tools/device --release    # any of the above, built -configuration Release
```

One command, every precondition: toolchain, signing, and the iPad itself. It
distinguishes two kinds of not-ready, and so does its exit code:

| Verdict | Exit | Meaning |
|---|---|---|
| READY | 0 | you can build and run on the iPad |
| BLOCKED | 2 | something physical must change — plug in, unlock, trust |
| MISCONFIGURED | 1 | something in this repo or toolchain is wrong |

BLOCKED is not a failure; MISCONFIGURED is. Confusing the two is how someone
ends up "fixing" a signing config to work around an unplugged cable.

Every check prints a remedy line. Notable ones: Developer Mode status, pairing
state, DDI availability, whether iPadOS is newer than the installed SDK (that
Xcode simply cannot install to it), and whether the bundle identifier has
drifted onto `com.tubernotes.app` — which would overwrite the behavioral
reference app on the iPad the next time anyone installs.

Diagnose with this before touching `project.yml`. Most device failures are a
locked screen.

There is no separate preflight command, on purpose: nobody runs preflight for
pleasure, they run it after a device build already failed, and a two-command
dance is what gets skipped under pressure.

### What the capture gives you

A plain run builds for that specific iPad, installs, and launches with
`devicectl --console` and `TN_TRACE=1`, streaming the app's own trace to
`Artifacts/device/<utc>-<sha>/console.log`. Ctrl-C ends the session and prints
the build and device identity plus what the app actually reported: whether the
session came up, whether a touch reached the canvas, how many saves happened and
**how many page files each one wrote out of how many exist** — which is how
"the save trace names only changed pages" becomes checkable rather than
asserted.

Re-read any past capture with `Tools/device --digest <console.log>`.

Two things it will not do. It renders **no verdict about your branch** — the
last line it prints says so, because ink is a maintainer's judgment and a tool
that scored it would be usurping one. And it is **never consumed by CI**:
everything it writes comes from an untrusted machine and is trivially forgeable,
so a human cites it and nothing verifies it.

`TNLog`'s stderr mirror is present in **every** configuration, Release
included, and is gated on `TN_TRACE` alone. That is deliberate: a build for
friends (below) is an archive, and an archive is Release, so a mirror only Debug
carried would be compiled out of the one build they hold. `Tools/device
--release` builds and captures that configuration on your own iPad.

If the capture says `NO TRACE CAPTURED`, believe it, and look for a launch that
did not set `TN_TRACE` or an attach to an already-running process — a summary of
an empty stream would otherwise read as "nothing went wrong."

A crash is reported as a crash. A Swift trap writes `Fatal error:` and raises no
NSException, so it prints no `TN[fatal]` and can happen before the app logs
anything at all; the digest looks for a trap **before** it decides a stream is
empty, because the alternative is the most alarming outcome wearing the words of
the most boring one. `Tools/device-tests` holds the digest against a fixture per
outcome — crash with no trace, crash after a trace, native crash, uncaught
exception, empty, no-trace, and clean. Run it when you touch the digest; CI does
not, per the rule above.

## A build for friends

A friend's iPad runs an archive, signed by the Apple Developer Program team and
distributed ad hoc. Signing, the team, and the bundle id are Phillip's to
change. Settle the bundle id before the first friend installs: their notebooks
live in that app's container, and a build with another id cannot see them.

1. Raise `CURRENT_PROJECT_VERSION` in `project.yml` and run `xcodegen
   generate`. Each build gets its own number, which is how a crash report
   finds its archive.
2. In Xcode, pick **Any iOS Device (arm64)** and choose **Product → Archive**.
   The scheme archives Release.
3. Keep the `.xcarchive` the Organizer lists. It holds that build's dSYM, and
   Release drops a `TNPrecondition` trap's message, so a friend's crash report
   reads only against that dSYM.
4. **Distribute App → Release Testing** (or **Ad Hoc**). `TN_DEVELOPMENT_TEAM`
   in `Local.xcconfig` must name the program team: a personal team cannot
   export ad hoc, and its profiles expire after seven days. The build installs
   only on iPads whose UDIDs are registered with the team.
5. Install the `.ipa` on each iPad from **Window → Devices and Simulators**.

## Rules for any check you add

These rules apply to tests and CI steps just as well.

**A check that has never failed is decoration.** Before trusting a new one,
deliberately break the thing it guards, confirm it fails, then revert. A check
can be dead without looking it — a `|` inside a regex collides with a `|`
field separator and silently truncates the pattern — and only a planted
violation exposes it.

**Fail closed, not open.** Express a rule as an *allowlist of what may do the
forbidden thing*, not a blocklist of known-bad names, so a new file breaks the
check without anyone remembering to update anything. A blocklist only catches
violations someone already thought of.

**A green run with zero tests is a false pass.** `xcodebuild` exits 0 when a
scheme runs nothing, so `ci.yml` greps the log for evidence tests actually
executed. Apply the same suspicion anywhere a tool can succeed by doing
nothing.

**Watch for false positives too.** A check that cries wolf gets disabled by the
next person, which is worse than not having it.

## Free checks — use them

- **Swift 6 language mode.** Compiler-enforced actor isolation turns "no work on
  the Pencil path" from a code-review opinion into a build error.
- **Warnings as errors** (`SWIFT_TREAT_WARNINGS_AS_ERRORS`). A deprecated call
  becomes a build error the moment it is written, not a review comment.
- **Runtime ownership.** Each `EditorBinding` constructs and retains its
  canvas runtime once. There is one `PKCanvasView` construction site, but no
  process-global singleton: every open tab owns its own runtime.

## Cancellation

Background work nobody will use must **stop**, not merely be ignored. A
five-page flick used to run every superseded decode to completion, competing
with the Pencil for the same CPU — which loses against this project's own
priority order before anything is measured.

One idiom, in two halves that are used together:

- **Structured cancellation where the work is droppable.** Hold the `Task`,
  cancel it the moment its result stops being wanted, and check
  `Task.isCancelled` at honest checkpoints inside the work — before a decode,
  between layers, after an `await` that could have taken a while, before a
  page-sized allocation. Checkpoints go where the expense is; a check that
  guards nothing is decoration.
- **A currency check at the moment a result is installed, and only there.**
  Cancellation is asynchronous, so a decode that finished microseconds before
  the cancel landed is still a completed result looking for somewhere to go.
  The install site compares — a generation counter, a request equality — and
  that comparison, not the cancel, is what makes a wrong picture impossible.

So: cancel so the work stops, compare so what already finished cannot install
stale. **A generation counter with no cancellation is wasted work; a cancel
with no comparison is a race.** Sites that only compare, with no droppable
work behind them, say at the declaration why comparison is the whole answer.

**Dedup is not staleness.** `Notebook.loads` answers "is someone already
loading this page?" — not "is this still wanted?". It is not a cancellation
mechanism and must not become one. Each such structure says which question
it answers where it is declared.

**Some work may never be cancelled**, because cancelling it loses ink or
strands it. Nothing joins this list without a reason of the same kind:

| Task | Why it is protected |
|---|---|
| `Notebook.currentSave` | it holds the captured values of a pass; cancelled, the pages stay dirty with no pass to clear them, and the retry buffer is never filled |
| `Workspace.leaseFlush` | the last write the process gets, holding the execution lease that buys the time to finish it |
| the serialize hop in `Notebook.performSave` | the bytes of a save in progress; `Task.detached` makes it uncancellable by construction rather than by anyone remembering |
| the final ink report | synchronous by contract (`Contract.md` — Navigation and the window) and not a task at all; it must never become one |

A cancelled `Task.sleep` is the ordinary outcome, not a failure, and is caught
by name in a two-line `do`/`catch` — never `try?`, which answers a genuine
failure with the same silence.

## Getting off the main actor

Three idioms exist. Each has one situation, chosen by what the work owns:

| Situation | Idiom | Why |
|---|---|---|
| off-main work over shared mutable state | `actor` | serialized access is the type's job rather than a convention — `PackageStore`, `LibraryStore`, `Renderer` |
| heavy work over values, owning no state | `nonisolated` (usually `static`) `async func` | runs on the generic executor, so it never occupies an actor's queue behind another page's request — and it runs *in the caller's task*, so it inherits the cancellation the checkpoints above depend on |
| a *synchronous* call that must leave the main actor, or work that must outlive its caller | `Task.detached` | the only two honest reasons, and the site names which one it is |

The middle row is the default for anything expensive. Reach for the third
sparingly: detaching also detaches cancellation, which is a feature exactly
once — for protected work — and a silent leak of effort everywhere else.

## When a test fails, find out who is wrong

The assertion is wrong at least as often as the code. `UIScrollView` reports
`contentSize` already multiplied by `zoomScale`: an assertion expecting the
unzoomed page width sees `612 × 1.3399 = 819.99` and reads as PencilKit
ignoring page space — but the implementation is right and the assertion is
wrong. "Fixing" that in the code silently corrupts page space to view space,
the precise failure the data contract exists to prevent.

Diagnose before you edit. Compute the number the framework gave you and see
whether it means something.

## Do not test what the environment cannot express

Some properties are simply not observable here, and pretending otherwise
produces a green run that proves nothing:

- `undoManager` walks the responder chain, so an unhosted controller always
  reports `nil`. Undo/redo is device evidence, not a unit test.
- The simulator has no Apple Pencil. Drawing, erasing, palm rejection, and
  pressure cannot be proven off-device at all.

When you hit one of these, do not weaken the assertion until it passes. Delete it
and record the gap explicitly in `Docs/Unproven.md` as outstanding device evidence.

## Project structure

- **`project.yml` is the only project source** — stated in `AGENTS.md`, under
  **Build**, so agents see it every session. Never edit the project in Xcode
  and expect it to survive.
- **Anything that differs per developer lives in `Local.xcconfig`**, which is
  gitignored and written by `Tools/setup`. Signing team, bundle prefix, and
  which iPad is yours are there. Putting a team ID in `project.yml` makes every
  peer's checkout permanently dirty, so a signing fix belongs in
  `Local.xcconfig` every time. `Local.xcconfig.example` carries a deliberately
  invalid placeholder team rather than a real one — a real ID there would be one
  person's, and anyone who copied the file instead of running `Tools/setup`
  would sign against it and get an error naming the wrong cause.
- Bundle ID defaults to `com.tubernotes.greenfield`, deliberately different from
  the reference app's `com.tubernotes.app` so installing this never replaces it
  on the iPad. Change the prefix if two people share one iPad.
- `Artifacts/` holds build and test logs and captured device sessions. It is
  regenerated and gitignored — cite paths from it as evidence, never commit it.
- **`Tools/` is four files and no shared library.** `pinned-simulator` is one
  line of data; `setup` gets a clone to an Xcode window; `device` runs the iPad
  loop; `device-tests` holds `device`'s digest against fixtures. There is
  deliberately no shared library: a library that does work at *source* time
  hands its caller values cached before the caller's world exists. Two
  scripts sharing a few lines of `sed` should duplicate them. Nothing in
  `Tools/` decides whether work is done.

## Scope discipline

The contract's hardest rule to follow is *smallest change that proves the
queue item*. The pressure to add the next abstraction is constant and it always
feels justified. Concretely:

- No `import UIKit` outside `TNCanvas`, `TNEditor`, and the app.
- The live canvas count is bounded by a small constant and must not grow with
  page count.

The first is machine-checked by `TuberNotesTests/ContractStructureTests.swift`,
along with the single `PKCanvasView` construction site and file I/O confined to
`PosixFileSystem`, `LibraryStore`, and `ImportReader`. The second is not, and
neither is the forbidden-pattern list — those hold only as far as review holds
them.

Those checks are tests rather than a script on purpose. They run inside the
thing that already decides, they fail like any other test so no second verdict
vocabulary exists, and **the checker has its own tests**: a structural check
can go silently dead, or fail on a *comment* that merely names the API it
polices, and each failure mode stays caught only by a permanent
planted-violation test. If you add a rule there, add the planted-violation
test with it.

## Ask instead of guessing

Some decisions cannot be derived from the documents, and guessing at them
silently wastes the work: which iPad to trust when the Mac is paired with
several, how far to go in one session, whether a rule covers developer tooling
as well as application code. Guessing produces work that gets thrown away. Ask,
then proceed.

Never make the human-only judgments. Pencil feel, stroke fidelity, palm
rejection, and pan/zoom quality are judged by a maintainer on the device.
Record the journey, produce the artifacts, and leave the verdict alone.
