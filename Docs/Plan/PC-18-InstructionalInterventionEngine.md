# PC-18 — Reasoning Pins: Calculus Check + Ochem Explain

Status: **implementation complete and Release-delivered — actual normal-app golden interactions and Phillip verdict pending**

Target branch: `main`

Owners: `App` owns integration and the in-product intervention policy,
transport, and validation; `Notebook` owns the selected user action, request
lifecycle, and persistence; `SpatialCanvas` owns selection/crop and
page-coordinate conversion; `Pins` owns presentation. No model may mutate ink,
PDF content, images, or persisted coordinates.

## Product claim

TuberNotes places one useful explanation exactly where reasoning becomes
non-obvious.

The hackathon does not attempt a general notebook agent. It proves the same hero
interaction across two visually and conceptually different learning materials:

1. **handwritten Calc I work** — Check catches a missing substitution factor;
2. **a printed organic chemistry PDF** — Explain makes electron movement in a
   simple reaction intelligible.

Everything in PC-18 is reverse-derived from making those two moments excellent.
If a proposed feature does not materially improve either golden problem, it is
outside the critical path.

## Golden problem A — Calc I Check

### Prepared page

The student has handwritten:

```text
∫ x e^(x²) dx
u = x²       du = 2x dx
∫ e^u du
e^(x²) + C
```

The work has one authentic introductory-calculus mistake: converting
`x dx` to `du` requires a factor of `½`, so the correct result is
`½e^(x²) + C`.

### Interaction

1. The student circles the substitution/result region with the existing Magic
   Lasso.
2. The attached menu offers **Check**.
3. TuberNotes retains the halo while working.
4. Exactly one issue Pin appears beside the selected work:

> **Missing one-half**
> Since `du = 2x dx`, then `x dx = ½du`. The antiderivative is
> `½e^(x²) + C`.

5. The student corrects the line, circles it again, and taps **Check**.
6. TuberNotes briefly shows “Checks out — differentiating this result returns
   `x e^(x²)`.” It persists no second Pin.

### Observable success

- It identifies the mathematical issue, not merely the visible symbols.
- It explains why the factor appears and gives the corrected result.
- It places one Pin beside the selected derivation.
- It does not clutter the corrected work.
- The Pin remains attached while the page pans or zooms.

### Honest limits

This proves a basic single-variable substitution pattern. It does not claim a
general computer algebra system, arbitrary handwritten integral solver, proof
checker, or support for multivariable calculus.

## Golden problem B — Intro Ochem Explain

### Prepared PDF

Use a clean, high-resolution PDF problem showing a simple SN2 reaction:

```text
HO⁻ + CH₃CH₂—Br  →  CH₃CH₂—OH + Br⁻
```

The diagram includes the standard curved-arrow movement from the hydroxide lone
pair toward the carbon bearing bromine and from the C—Br bond toward bromine.
Avoid stereochemical wedges/dashes, resonance, rearrangements, competing
mechanisms, or tiny scanned text in the hero fixture.

### Interaction

1. The student circles the reactants and curved arrows on the PDF.
2. The attached menu offers **Explain**.
3. Exactly one explanation Pin appears beside the selected reaction:

> **One concerted step**
> Hydroxide donates a lone pair to the carbon as the C—Br bond breaks. Carbon
> forms one bond while losing one, and bromide leaves with the bonding pair.

4. Expanding the Pin reveals one study cue:

> Follow curved arrows from the electron source to the electron destination.

### Observable success

- It identifies nucleophile, electrophilic carbon, leaving group, and the two
  coupled electron movements.
- It explains causality rather than transcribing the equation.
- It uses the PDF selection as context without modifying the source document.
- It returns one readable spatial annotation, not a mechanism-sized wall of
  prose.
- If the selection omits a reactant, product, or arrow endpoint, it asks for a
  wider selection rather than guessing.

### Honest limits

This proves explanation of a clean, canonical SN2 mechanism. It does not claim
mechanism prediction, stereochemical verification, molecule recognition across
arbitrary scans, nomenclature, synthesis planning, or safety guidance.

## Ninety-second demo

### 0–8 seconds — establish the promise

Show the notebook with the handwritten integral and the adjacent imported Ochem
PDF page.

> “TuberNotes doesn’t describe pages. It explains the step you select.”

### 8–32 seconds — Calc reasoning

Circle the incorrect substitution work and tap **Check**. One Pin identifies
the missing `½`, explains `x dx = ½du`, and supplies the corrected
antiderivative.

### 32–48 seconds — prove restraint

Correct the expression, re-check it, and receive a transient derivative-based
confirmation with no extra Pin.

### 48–73 seconds — Ochem reasoning

Open the prepared PDF page, circle the SN2 arrows, and tap **Explain**. One Pin
explains simultaneous bond formation and bond breaking, then exposes the study
cue when expanded.

### 73–84 seconds — prove notebook coherence

Pan or zoom both pages. The two useful Pins remain attached to their original
page regions; transient Calc confirmation is gone.

### 84–90 seconds — close

> “One notebook, two subjects, and only the explanation that earns its place.”

No live follow-up provider call belongs in the hero.

## Reverse-derived feature contract

The following features exist because one or both golden problems require them.

| Required feature | Calc reason | Ochem reason | Smallest implementation |
|---|---|---|---|
| Typed **Check** and **Explain** intents | Checking a derivation is not describing it | Explaining electron flow is not grading a mechanism | Reuse `InvestigationIntent`; do not interpolate generic “user focus” prose |
| First-class non-Pin outcomes | Correct work should stay clean | Incomplete reaction context should request a wider selection | `spatialGuidance`, `transientConfirmation`, `needsInput`, `noAction` |
| High-fidelity selection image | Preserve superscripts, minus signs, and the `½` relationship | Preserve charges, bonds, arrowheads, and subscripts | Source-aware lossless or high-quality crop at a sufficient pixel budget |
| Context outside the lasso | Read the original integrand and substitution together | See nucleophile, substrate, product, and arrows together | Tight selection plus one padded context crop; whole-page overview only if needed |
| Domain-specific evidence | Establish `du = 2x dx` and expected factor | Establish nucleophile, electrophile, leaving group, and bond changes | One strict response with a typed Calc or Ochem basis |
| One Pin by default | Highlight the first meaningful error | Explain the selected mechanism as one causal event | `maxItems = 1` for both golden paths |
| Honest uncertainty | Do not verify unreadable handwriting | Do not invent missing charges or arrow endpoints | `needsInput(reason, message)` is a valid success |
| Spatial persistence | Keep the correction beside the derivation | Keep the explanation beside the reaction | Preserve existing crop-to-page validation and page identity |
| Compact/expanded copy | Immediate correction plus short reasoning | Immediate mechanism plus one study cue | Teaser + two-sentence body + optional study cue |
| Retained-selection recovery | Retry without redrawing | Widen or retry the same PDF selection | Preserve lasso on failure or needs-input |
| Two-domain reference set | Document intended semantic boundaries | Document chemistry-specific failure modes | Six Calc cases + six Ochem cases retained as non-acceptance development material |

Features intentionally not implied by the golden problems:

- OCR indexing of entire PDFs;
- notebook-wide retrieval or search;
- autonomous subject classification across arbitrary material;
- a general symbolic-math engine;
- chemical structure parsing or cheminformatics database integration;
- multiple agents, open-ended tools, or a separate model critic;
- atom-level or glyph-level anchors;
- generated drawings, rewritten mechanisms, or modified ink.

## Outcome model

Reuse the existing `InvestigationIntent` cases for `.check` and `.explain`.
Keep `.ask(question:)` compatible but outside the PC-18 hero.

```swift
enum InterventionOutcome: Sendable, Equatable {
    case spatialGuidance(GroundedIntervention)
    case transientConfirmation(TransientConfirmation)
    case needsInput(NeedsInput)
    case noAction(NoActionReason)
}

enum NeedsInputReason: String, Sendable {
    case unreadableSelection
    case missingMathStep
    case missingReactionContext
    case unsupportedContent
}
```

Only `spatialGuidance` persists a Pin or creates a Pin conversation root.
Confirmation, missing-input, and no-action messages attach temporarily to the
selection and leave the document unchanged.

## One-call evidence contract

Each user action makes one bounded multimodal request. Separate interpretation,
generation, and model-critic calls are excluded unless a frozen holdout later
proves one indispensable.

The response exposes inspectable product evidence rather than private reasoning:

```swift
enum InterventionBasis: Sendable {
    case calculus(CalculusBasis)
    case organicChemistry(OrganicChemistryBasis)
}

struct CalculusBasis: Sendable {
    let integrand: String
    let observedSubstitution: String?
    let observedStudentResult: String?
    let expectedRelationship: String
    let expectedResult: String?
    let verificationMethod: String
    let blockingAmbiguity: String?
}

struct OrganicChemistryBasis: Sendable {
    let reactionFamily: String?
    let nucleophile: String?
    let electrophilicCenter: String?
    let leavingGroup: String?
    let bondsFormed: [String]
    let bondsBroken: [String]
    let observedArrowFlow: [String]
    let blockingAmbiguity: String?
}

struct GroundedIntervention: Sendable {
    let kind: AnnotationKind
    let teaser: String
    let body: String
    let studyCue: String?
    let target: CropNormalizedPoint
    let basisClaimIDs: [String]
}
```

The provider still returns one validated crop coordinate during the hackathon.
The app constrains it to the selected region and never claims atom-level or
symbol-level precision. An app-owned anchor system is not required for these
two selection-level Pins.

## Deterministic acceptance rules

### Shared

- exactly one outcome;
- zero or one intervention, never filler to satisfy a count;
- valid bounded geometry inside the frozen selection;
- no unknown basis references, extra schema fields, oversized copy, or stale
  login/page/layer/selection revision;
- literal transcription alone cannot satisfy `spatialGuidance`;
- non-Pin outcomes cannot persist a Pin or create a chat root.

### Calc Check

An issue Pin is invalid unless the basis contains the observed integrand,
student substitution/result, expected relationship, and corrected result. A
confirmation is invalid unless the basis states how the result was checked,
such as differentiating the proposed antiderivative.

Unreadable superscripts, missing steps, or unsupported integrals produce
`needsInput` or `noAction`, never a correctness claim.

### Ochem Explain

An explanation Pin is invalid unless the basis identifies the relevant electron
source, electron destination/electrophilic center, leaving group, and bond
changes supported by the selected image.

Missing charges, reagent/product context, or arrow endpoints produce
`needsInput(.missingReactionContext)`. The model may not infer stereochemistry,
reaction competition, or safety advice in the PC-18 path.

## Image and spatial requirements

The current scale-1 JPEG crop is not sufficient as an assumed contract for
superscripts, charges, arrowheads, and lone-pair marks.

PC-18 requires:

1. render the selected PDF or handwritten page region at a pixel budget that
   keeps the smallest required mark legible;
2. prefer lossless encoding for ink/line art when request limits permit;
3. include padding around the lasso so relationships crossing its boundary
   survive;
4. label the tight crop and context crop roles explicitly;
5. never draw a selection marker over source content;
6. retain the existing frozen crop-to-page transform and page revision;
7. reject a returned target outside the selected or padded evidence region.

The hero promises selection-level attachment: beside the derivation and beside
the reaction. Exact attachment to a minus sign, atom, or arrowhead is deferred.

## Twelve-case reference set (not acceptance evidence)

These cases were frozen before prompt tuning, with four—two per subject—held
out from tuning. They remain useful design records for the strict validator,
but their runner and synthetic inputs do not represent the actual app and are
disabled for behavioral acceptance.

### Calc cases

1. Golden missing-`½` substitution error.
2. Corrected golden result → transient confirmation.
3. Same problem with omitted `+ C`.
4. Correct elementary power-rule integral.
5. Unreadable exponent → needs input. **Holdout.**
6. Unsupported integration-by-parts example → honest no action/needs input.
   **Holdout.**

### Ochem cases

1. Golden complete SN2 curved-arrow diagram.
2. Same reaction without arrowheads → request context.
3. Same reaction cropped without the leaving group.
4. A label/title near the reaction → no annotation.
5. Clean proton-transfer arrow explanation. **Holdout.**
6. Wedge/dash stereochemistry request → unsupported/needs input. **Holdout.**

The historical evaluator measured:

- outcome confusion matrix;
- required-guidance recall and accepted-Pin precision;
- catastrophic academic-error count;
- transcription-only failure count;
- geometry-in-selection pass/fail;
- P50/P90 latency;
- five repeated runs of each golden problem.

The following targets now apply only when they are measured from the prepared
inputs in the normal Release app. Offline case scores cannot satisfy them:

- zero critical factual, intent, or spatial failures across all ten golden runs;
- zero transcription-only accepted Pins;
- 100% of missing-context cases avoid fabricated claims;
- P90 below eight seconds on the demo network, targeting five seconds;
- every failure retains the selection and offers the correct next action.

## Coordinator execution brief

### Explicit goal

The coordinator's goal is:

> Deliver a normal Release TuberNotes build on Phillip's explicitly pinned iPad
> in which the prepared Calc I selection reliably produces the missing-`½`
> Check Pin, the corrected work produces transient confirmation without a Pin,
> and the prepared SN2 PDF selection reliably produces one causal Explain Pin;
> prove both golden problems five consecutive times without factual, intent,
> spatial, persistence, crash, or credential-boundary failure.

The goal is complete only when the normal-app acceptance evidence in this
document exists and Phillip gives the final usefulness/clarity verdict.
Completing subagent tasks, merging code, compiling, or passing offline
reference cases alone does not complete the goal.

### Coordinator-only authority

The coordinator retains and does not delegate:

- the objective, scope, cut line, and decision to advance between folds;
- architecture and subsystem ownership decisions;
- final shared-contract shape and any `CONTRACT:` flag/log requirement;
- edits to `SPEC.md`, `Docs/Plan/PLAN.md`, this child plan, and final project
  membership reconciliation;
- resolution of overlapping edits and integration into shared call sites;
- physical-iPad preflight, device lock ownership, Release build/install/launch,
  and live temporary-account/provider actions;
- selection of the fixed model/route and any prompt-tuning decision;
- acceptance of mathematical and chemical claims;
- the one bounded correction/polish pass and final stop decision;
- the evidence packet and presentation to Phillip.

Subagents may propose shared-contract changes, but only the coordinator accepts
and integrates them. Subagents do not commit, push, switch branches, touch the
physical device, use live account access, or broaden scope unless the
coordinator explicitly changes their task.

### Coordination rules

- Use at most three subagents in a fold so the coordinator remains active.
- Every subagent receives one bounded objective, explicit files, non-goals,
  prerequisites, expected checks, and a return contract.
- Parallel editing assignments must have non-overlapping owned files. A file is
  leased to only one participant for the duration of a fold.
- Read-only reviewers never repair their own findings. They return ranked
  evidence to the coordinator.
- The coordinator folds results in only after inspecting every returned diff
  and rejecting speculative abstractions or unrelated churn.
- A later fold does not start until the current fold's exit gate is recorded in
  the PC-18 session log.
- Any subagent that finds an architecture, security, permission, secret, or
  physical-device dependency stops and reports it instead of working around it.

### Dependency map

```text
Coordinator Gate 0: fixed provider + exact prepared inputs
        |
        v
Fold 1: three independent read-only design attacks
        |
        v
Coordinator Freeze 1: response contract + image budget + reference-case truth
        |
        v
Fold 2: three non-overlapping implementation packages
        |
        v
Coordinator Fold-in 2: shared call sites + UI + project/spec integration
        |
        v
Fold 3: three independent adversarial audits of the integrated result
        |
        v
Coordinator Fix Gate: one bounded correction pass
        |
        v
Coordinator Fold 4: Release device delivery -> repeated normal-app journeys
        |
        v
Phillip verdict
```

### Coordinator board

| Stage | Current status | Evidence boundary / remaining gate |
|---|---|---|
| Gate 0 | **Partially complete** | Inputs, route, branch, and exact iPad were fixed. A provider response to both prepared selections in the actual app is still unproven. |
| Fold 1 | **Complete as design work** | Contract, image budget, semantic predicates, and reference cases were frozen; this does not prove runtime behavior. |
| Fold 2A | **Implemented** | Strict four-outcome decoding, typed evidence, bounded request construction, and validation are in product code. |
| Fold 2B | **Implemented** | Tight/context lossless evidence capture and coordinate metadata are in product code. |
| Fold 2C | **Retired as acceptance evidence** | Deterministic cases/evaluator remain development artifacts only and must not establish product success. |
| Fold-in 2 | **Implemented and host-checked** | Notebook/App integration, persistence split, transient presentation, lifecycle guards, SPEC, and project membership are complete. Actual normal-app traversal remains unverified. |
| Fold 3 | **Complete as code review** | Three adversarial reviews informed one bounded correction pass; their fixture-derived judgments do not count as behavioral acceptance. |
| Fix gate | **Complete** | Exact semantic predicates, app-owned copy, transport bounds, lifecycle repairs, retained-crop Ask, and timed confirmation were integrated. |
| Fold 4 | **Delivery complete; behavior pending** | Signed Release built, installed, and normally launched on the named iPad. Five Calc and five Ochem journeys, live latency, spatial/visual/crash inspection, and Phillip's verdict remain. |

### Completed implementation inventory

| Product area | Status | Source of truth |
|---|---|---|
| Shared intervention outcome and typed Calc/Ochem basis | **Complete** | `TuberNotes/AgentHarness/InterventionOutcome.swift`, `SPEC.md` §10.6 |
| Strict semantic and geometry validation | **Complete** | `TuberNotes/AgentHarness/InterventionValidator.swift` |
| Intent-specific bounded provider request/decoder | **Complete** | `TuberNotes/AgentHarness/OpenAICodexPinClient.swift` |
| Lossless tight/context evidence rendering | **Complete** | `TuberNotes/Notebook/SelectionEvidenceRenderer.swift` |
| Notebook lifecycle, stale-result, retry, cancellation, and persistence split | **Complete** | `TuberNotes/Notebook/NotebookViewModel.swift` |
| Normal-app transient and persistent presentation | **Complete** | `TuberNotes/Notebook/NotebookView.swift`, `AgentSidebarView.swift` |
| Project membership and shared-contract documentation | **Complete** | `TuberNotes.xcodeproj/project.pbxproj`, `SPEC.md` |
| Signed Release build, install, ordinary launch | **Complete delivery evidence** | `tmp/build/pc18-release-device/` and the 2026-07-21 session log |
| Synthetic cases, evaluator, and fixture assets | **Retired for acceptance** | Retained in `DeveloperTools/` only as historical design/check material |
| Actual Calc/Ochem behavior, latency, spatial/visual/crash quality | **Pending normal-app evidence** | Requires the prepared journeys in Release on Phillip's pinned iPad |

## Gate 0 — Coordinator baseline (two hours, no subagent)

The coordinator:

1. freezes the exact handwritten Calc page and exact SN2 PDF page;
2. records their page IDs, selection regions, expected visible outputs, and
   unsupported boundaries;
3. pins Phillip's named iPad through the canonical preflight;
4. freezes one model, route, and demo network;
5. manually proves in the normal Release app that the current transport accepts
   the actual Calc and Ochem selections and returns a bounded structured response;
6. records baseline latency and failure shape without logging selected page
   content, provider bodies, or secrets.

Current gate status: steps 1–4 are complete; steps 5–6 remain part of the live
normal-app delivery gate. Historical fixture or recorded-route responses do not
satisfy them.

## Fold 1 — Parallel design attacks

These subagents are read-only. Their purpose is to force precise decisions
before parallel code exists.

### Subagent 1A — Contract and decoder adversary

Objective: derive the smallest strict response contract that represents all
four outcomes and makes the golden Calc/Ochem claims mechanically rejectable.

Inspect:

- `TuberNotes/AgentHarness/OpenAICodexPinClient.swift`
- `TuberNotes/AgentHarness/AgentClient.swift`
- `TuberNotes/App/Contracts/InteractionContracts.swift`
- `TuberNotes/Notebook/NotebookViewModel.swift`
- relevant `SPEC.md` contracts

Non-goals: no edits, prompts, provider calls, UI design, or new general agent
architecture.

Return contract:

1. exact proposed Swift types and strict JSON shape;
2. validation matrix for Calc issue, Calc confirmation, Ochem explanation,
   needs input, no action, malformed response, and stale result;
3. list of existing types to reuse or retire;
4. shared-contract changes requiring coordinator review;
5. top three ways the schema could still accept fluent nonsense.

### Subagent 1B — Image-evidence and spatial adversary

Objective: establish the smallest render/crop contract that preserves the
golden superscript/factor and SN2 charges/bonds/arrowheads while retaining the
existing page-normalized projection.

Inspect:

- `TuberNotes/Notebook/NotebookViewModel.swift` selection rendering
- `TuberNotes/SpatialCanvas/`
- PDF/image rendering paths reached by the normal Notebook
- the frozen golden fixtures

Non-goals: no source edits, OCR system, semantic anchors, provider call, or
visual redesign.

Return contract:

1. measured source/crop dimensions and smallest legible feature;
2. recommended encoding, scale, padding, and request-size bound;
3. exact tight/context image roles;
4. crop-to-page invariants and rejection conditions;
5. artifact paths for local render comparisons;
6. a go/no-go verdict on using the current scale-1 JPEG path.

### Subagent 1C — Golden-case and evaluator adversary

Objective: turn the two golden problems and ten neighboring cases into an
unambiguous expected-outcome manifest that cannot be gamed by abstaining.

Inspect:

- this PC-18 proposal;
- existing DeveloperSupport scenario/fixture patterns;
- existing Pin and agent recorded scenarios;
- the frozen golden Calc/Ochem inputs.

Non-goals: no source edits, generated curriculum, broad-domain expansion, or
live provider evaluation.

Return contract:

1. twelve case records with subject, intent, expected outcome, required claims,
   forbidden claims, allowed region, and human rationale;
2. explicit four-case holdout designation;
3. scoring definitions for recall, precision, catastrophic error, shallow
   narration, geometry, and latency;
4. five-run golden stability rule;
5. any case whose ground truth requires Phillip's judgment.

### Coordinator Freeze 1

The coordinator reconciles the three reports and freezes:

- one versioned outcome/evidence contract;
- exact Calc and Ochem acceptance predicates;
- image scale, encoding, padding, roles, and size bounds;
- the twelve-case manifest and holdouts;
- file ownership for Fold 2.

The coordinator records rejected alternatives and shared-contract implications
before any implementation subagent starts.

## Fold 2 — Parallel implementation packages

Fold 2 uses three non-overlapping file leases. Each agent implements only its
package and returns an unstaged working-tree diff. The coordinator later owns
all shared seam edits.

### Subagent 2A — Agent decision package

Prerequisite: Coordinator Freeze 1 response contract.

Objective: implement strict decoding, intent-specific request construction,
Calc/Ochem evidence bases, four outcomes, and deterministic semantic validation.

Owned files:

- `TuberNotes/AgentHarness/OpenAICodexPinClient.swift`
- new AgentHarness-only intervention contract/validator files approved by the
  coordinator

Forbidden files:

- Notebook views/view model;
- SpatialCanvas and Pins;
- project file, `SPEC.md`, and plan documents;
- auth/session/transport unless Gate 0 proved a named defect.

Required checks:

- valid issue, confirmation, explanation, needs-input, and no-action decode;
- empty Pin success;
- malformed, extra-key, invalid-basis, invalid-geometry, oversized, and
  unsupported-content rejection;
- one Pin maximum;
- no raw response or secret logging.

Return contract:

1. changed files and concise diff summary;
2. check commands/results;
3. exact integration API the coordinator must call;
4. unresolved contract or transport assumption;
5. confirmation that no forbidden file changed.

### Subagent 2B — Selection evidence package

Prerequisite: Coordinator Freeze 1 image contract.

Objective: implement a pure, bounded renderer that produces the frozen tight
and padded-context evidence images plus their existing coordinate metadata for
handwritten and PDF-backed pages.

Owned files:

- one new Notebook or SpatialCanvas evidence-rendering helper chosen by the
  coordinator;
- focused helper checks in an isolated new development-check file, if needed.

Forbidden files:

- `NotebookViewModel.swift` and `NotebookView.swift` integration seams;
- AgentHarness, Pins, auth/transport;
- project file, `SPEC.md`, and plan documents.

Required checks:

- deterministic pixel dimensions and byte bounds;
- lossless/high-quality preservation of the frozen smallest Calc/Ochem marks;
- padding clamped to page bounds;
- tight/context role metadata;
- unchanged crop/page-normalized transform;
- no source-page mutation.

Return contract:

1. changed files and diff summary;
2. render artifact paths for both golden inputs;
3. size/dimension results;
4. coordinator integration call signature;
5. any PDF-versus-ink divergence;
6. confirmation that no forbidden file changed.

### Subagent 2C — Reference-case and evaluator package (retired for acceptance)

Prerequisite: Coordinator Freeze 1 manifest and scoring rules.

Historical objective: materialize twelve deterministic development cases and
narrow scoring/reporting support without changing the normal product runtime.
These artifacts may document intended semantics but are disabled for product
acceptance because they do not represent the normal app.

Owned files:

- new or narrowly extended files under `TuberNotes/DeveloperSupport/`;
- new or narrowly extended files under `DeveloperTools/` for fixture-only
  evaluation/reporting;
- approved synthetic or explicitly provided fixture assets.

Forbidden files:

- normal Notebook, AgentHarness, SpatialCanvas, Pins, auth, or persistence;
- project file, `SPEC.md`, and plan documents;
- physical device, live provider, or user account state.

Required checks:

- all twelve manifest entries load deterministically;
- holdouts are marked but not tuned separately;
- scores cannot reward universal abstention;
- fixture results distinguish Pin persistence from transient outcomes;
- outputs contain no secrets or unapproved notebook content.

Return contract:

1. changed files/assets and diff summary;
2. fixture manifest path and case count;
3. host-safe check commands/results;
4. scenarios/evidence the coordinator must run later;
5. human-only ground-truth gaps;
6. confirmation that no forbidden file changed.

### Coordinator Fold-in 2

The coordinator inspects all three diffs, rejects unrelated churn, then alone:

1. resolves contract differences and adds project membership;
2. integrates evidence rendering and decision output into
   `NotebookViewModel.swift`;
3. integrates transient confirmation/needs-input/no-action presentation into
   `NotebookView.swift` and the retained halo/menu;
4. preserves cancellation, retry, login generation, layer existence,
   page-content revision, selection retention, and spatial projection;
5. ensures only `spatialGuidance` persists a Pin/chat root;
6. updates `SPEC.md` and plan logs for any accepted shared contract;
7. builds host-safe seams before Fold 3.

Fold-in implementation gate: source integration, shared contracts, compilation,
and diff hygiene pass. Persistent/transient behavior must be confirmed through
the prepared selections in the normal Release app.

## Fold 3 — Independent adversarial audits

These agents are read-only and run in parallel against the same integrated
commit/worktree snapshot. They do not repair findings.

### Subagent 3A — Calculus correctness reviewer

Objective: falsify the Calc golden result and every Calc fixture.

Return: per-case verdict, independently derived antiderivative/derivative
check, any ambiguous visual reading, any accepted unsupported claim, severity,
and the smallest correction. Reject an issue/confirmation whose basis does not
actually support it.

### Subagent 3B — Organic chemistry correctness reviewer

Objective: falsify the SN2 explanation and every Ochem fixture.

Return: per-case verdict for nucleophile, electrophilic center, leaving group,
bond formation/breaking, arrow direction, unsupported stereochemical/mechanism
claim, severity, and smallest correction. Reject explanations that merely name
visible objects without causal electron-flow value.

### Subagent 3C — Product, state, and spatial reviewer

Objective: attack the hero as a notebook interaction rather than as model text.

Return: ranked findings for intent mismatch, forced output, wrong persistence,
selection loss, retry/cancel/stale behavior, clipping/overlap, Pin drift,
latency story, demo choreography, and accessibility. Identify which facts are
mechanical and which still require Phillip.

### Coordinator Fix Gate

The coordinator deduplicates findings, accepts only evidence-backed issues, and
spends one bounded correction/polish pass. New feature requests are deferred.
Any repeated critical factual failure triggers the PC-18 stop condition rather
than another architecture expansion.

## Fold 4 — Coordinator verification and delivery

Fold 4 is sequential because the physical iPad and live account are shared,
stateful resources.

The coordinator:

1. performs exact-device preflight;
2. builds, installs, and normally launches Release on Phillip's iPad;
3. prepares the exact Calc and Ochem notebook/PDF inputs in the normal app;
4. has Phillip run the Calc golden problem five consecutive times;
5. has Phillip run the Ochem golden problem five consecutive times;
6. records actual-app outcome counts and live P50/P90 without retaining private
   page content, raw provider bodies, or credentials;
7. inspects the actual app for persistence, clipping, overlap, Pin drift,
   console errors, and crashes;
8. records Phillip's mathematical/chemical usefulness and clarity verdict;
9. writes the final evidence packet and stops.

Current result: steps 1–2 are complete. Steps 3–8 remain. No Debug scenario,
recorded route, fixture-driven UI, or offline evaluator can satisfy these gates.

Target duration remains three focused implementation days plus Phillip's
verdict: Gate/Fold 1 and Freeze on Day 1; Fold 2 and integration on Day 2;
Folds 3–4 plus one correction pass on Day 3.

## Non-goals and cut line

Cut first:

- expanded Pin study cue;
- secondary context overview when the padded crop is sufficient;
- support for the non-golden fixture variations beyond honest rejection;
- Ask integration in this work line.

Never cut:

- the exact two golden problems;
- distinct Check and Explain semantics;
- zero-Pin outcomes;
- Calc verification basis and Ochem electron-flow basis;
- high-fidelity image capture;
- one Pin by default;
- retained-selection recovery;
- repeated golden runs in the normal Release app;
- existing credential, cancellation, stale-result, and coordinate boundaries.

If the non-negotiable set does not fit, narrow the prepared examples further.
Do not restore mandatory Pin generation or hide uncertainty with prose.

## Stop conditions

- the fixed route cannot read both actual golden crops reliably;
- either golden problem produces a critical factual error twice after one
  focused correction;
- P90 remains above eight seconds after one bounded optimization;
- any golden run fabricates missing context or produces transcription-only
  guidance;
- implementation requires a new provider/auth architecture, general OCR/CAS,
  chemical database, or ownership expansion;
- the remaining work would require cutting a non-negotiable feature.

## Acceptance evidence

- final changed files and in-scope diff summary;
- versioned outcome, Calc basis, Ochem basis, and validation contracts;
- exact prepared golden inputs and expected visible results;
- fixed route/model and P50/P90 latency;
- exact physical-iPad Release build/install/normal launch;
- five successful live runs of each golden problem;
- spatial persistence, clipping, overlap, cancel, retry, stale-result,
  console, and crash evidence;
- Phillip's verdict on mathematical/chemical usefulness and visual clarity;
- explicit unsupported-content boundary and stop reason.

Reference-case manifests and offline evaluator output may accompany the code
history, but they are not acceptance evidence and cannot advance this status.

## Prior adversarial constraints retained

The previous PC-18 draft was independently reviewed for product value,
multimodal correctness, and one-week delivery. All three reviewers required
revision. This rewrite retains their accepted constraints:

- show useful intelligence before restraint;
- one structured call rather than a correlated multi-call pipeline;
- explicit non-Pin outcomes;
- evidence and verification before correctness claims;
- one Pin by default;
- no false atom/symbol-level placement precision;
- a frozen holdout and recall-aware evaluation;
- P90 latency and repeated live hero runs;
- one bounded tuning/polish pass;
- no broad-domain promise during the hackathon.

## Session log

- 2026-07-21 — Phillip defined immediate regional Pin disposal: `CONTRACT:` a
  newly closed Magic Lasso now cancels any in-flight analysis and removes every
  existing current-page Pin anchored inside the exact polygon on the selected
  Agentic Layer before showing the new action menu. Removal cascades through
  conversation descendants and persists immediately; Pins outside the polygon
  and on other layers remain intact. The signed Release build under
  `tmp/build/pc18-regional-disposal/` succeeded, installed, and normally
  launched on only iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`.
- 2026-07-21 — Phillip's post-redeploy screenshot proved the structured-Pin
  correction still failed on the live ChatGPT/Codex route and that accumulated
  generic Pins made the experience look instructionally empty. `CONTRACT:` the
  normal Release Check/Explain path now uses the authenticated image-capable
  insight response rather than provider structured output. It requests an
  answer/key point plus reasoning and a next step, bounds and screens the
  returned Markdown, derives a compact plain-text teaser, and anchors exactly
  one accepted response to the selection center through the existing crop-to-
  page transform. `[NO_ACTION]`, generic labels, context requests, and
  observational prose produce no Pin and no toast. Typed intervention contracts
  remain available for future gateway/tool integration. The signed Release
  build succeeded under `tmp/build/pc18-teaching-route/`, installed, and
  normally launched on only iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Phillip's repeat of the visible
  `2 + 2` selection is the required live account/model and teaching verdict.
- 2026-07-21 — Phillip's first normal-app test exposed a live structured-output
  rejection and instructionally poor fallback language. The correction keeps
  the existing typed evidence and geometry contracts but replaces the provider-
  rejected root `oneOf` schema with one closed object whose variant payloads
  are required-nullable and locally discriminated. Needs-input/no-action now
  complete silently with the lasso retained; the normal insight prompt forbids
  incomplete-question/context requests, generic follow-up labels, and
  observational narration, requiring a reasoning explanation and usable next
  step. A signed Release build succeeded from
  `tmp/build/pc18-live-correction/`, then installed and ordinarily launched on
  only iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Phillip's repeat of the
  failing live selection remains the required account/model and teaching-value
  verdict.
- 2026-07-21 — Phillip paused PC-18 and rejected the Debug/fixture verification
  surface as non-representative of the actual implementation. All prior results
  from that surface are invalidated as acceptance evidence. The app now always
  enters its normal Library flow, and the scenario, structured-review, and
  Pencil fixture tool entry points fail closed. Future verification is limited
  to the normal Release app on Phillip's explicitly pinned iPad; none ran in
  this paused session.
- 2026-07-21 — `CONTRACT:` accepted optional orientation-only
  `SelectionArtifact.contextCrop` and the versioned typed intervention outcome
  contract. Coordinates remain tight-crop-relative; only spatial guidance may
  persist one Pin/chat root. SPEC section 10.6 records the evidence and stale-
  state requirements.
- 2026-07-21 — Fold 2 packages were diff-inspected and integrated. Check and
  Explain now use typed intents and a strict four-outcome decoder; only spatial
  guidance persists. Notebook rechecks login generation, selection, page
  content, layer existence/visibility, cancellation, and geometry. Selection
  evidence is lossless 2x PNG with tight/context roles. The twelve deterministic
  assets, manifest, anti-abstention evaluator, and focused contract runner are
  materialized. Generic Debug build succeeded; focused intervention checks and
  evaluator self-test pass. Fold 3 begins against this integrated snapshot.
- 2026-07-21 — Fold 3 independently found coefficient-substring acceptance,
  incomplete chemistry visible-copy predicates, prompt/case contradiction, and
  stale selection/retry/deferred-sign-in paths. The single bounded correction
  replaced free-form accepted prose with app-owned copy derived from exact
  validated facts, tightened exact math and chemistry requirements, aligned the
  narrow prompt, enforced image budgets/roles at transport, repaired selection
  lifecycle and Ask/retry freshness, and made confirmation expire after three
  seconds. Focused contract checks, evaluator self-test, generic Debug build,
  and diff hygiene pass. Fold 4 started.
- 2026-07-21 — Fold 4 host gates pass: focused decoder/semantic checks,
  deterministic twelve-case manifest/evaluator self-test (12/12 oracle,
  anti-abstention 1/12), asset regeneration, Python compilation, secret scan,
  generic Debug build, and diff hygiene. Exact-device `pin-drift` and
  `edge-pins` pass under `tmp/verify/20260721-014436-pin-drift/` and
  `tmp/verify/20260721-014442-edge-pins/`. Legacy `hero-recorded` and
  `agent-recorded-failure` built/installed/launched but failed their existing
  runtime/crop artifact requirement under `tmp/verify/20260721-014247-hero-recorded/`
  and `tmp/verify/20260721-014403-agent-recorded-failure/`; no product-success
  claim is made from them. Signed Release built successfully under
  `tmp/build/pc18-release-device/`, installed, and ordinarily launched on only
  iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`. The remaining five-run Calc and
  Ochem live streaks, live P50/P90, visible clipping/overlap/console/crash
  inspection, and educational-value verdict require Phillip to operate the
  prepared selections in the normal signed-in app; host tooling cannot perform
  those Pencil/account actions or infer the verdict.
- 2026-07-21 — Phillip authorized the overnight PC-18 objective in
  implementation-first go mode. Gate 0 confirmed `main` at `e79abb4`, preserved
  the existing PC-18 plan edits and unrelated `.claude/` content, and pinned
  only Phillip's physical iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117` by the
  canonical preflight. The normal structured-Pin route is present. Live
  transport proof remains deferred to the delivery gate because account access
  is device-owned and may not be copied or inferred from the host; all host-safe
  Fold 1 work continues under the explicit overnight override.
- 2026-07-21 — Fold 1 freeze accepted a version-1 closed discriminated outcome
  schema, typed Calculus/Organic Chemistry evidence, exactly one coordinate-
  bearing Pin only for `spatialGuidance`, and Notebook-private stale-state
  capture. It rejected model-generated claim IDs and the phrase blacklist as
  correctness evidence. Image evidence is frozen as a 2x opaque PNG tight crop
  (2048-pixel longest-side cap, 24-point padding, 4 MiB) plus a non-coordinate
  context PNG (1536-pixel cap; 6 MiB aggregate); the current scale-1 JPEG path
  is no-go. The twelve cases and C5/C6/O5/O6 holdouts are frozen with exact
  outcome, required/forbidden claim, geometry, recall/precision/error, and
  five-run stability rules. Existing Calc/SN2 assets were absent, so Fold 2C
  owns their bounded deterministic materialization.
- 2026-07-21 — Created PC-18 after mandatory Pin generation repeatedly produced
  shallow narration despite prompt bans and phrase filters.
- 2026-07-21 — Product, AI-systems, and delivery reviews narrowed the original
  multi-pass design to a one-call, evidence-bearing intervention decision.
- 2026-07-21 — Rewrote the proposal backward from two golden demonstrations:
  checking the missing factor in a basic substitution integral and explaining
  electron flow in a clean SN2 PDF problem. Derived the minimum shared and
  domain-specific feature set, twelve-case gate, three-day critical path, and
  explicit unsupported boundaries. No product code or runtime action occurred.
- 2026-07-21 — Recast the critical path as a higher-level coordinator brief
  with one explicit delivery goal, coordinator-only authority, four dependency
  folds, nine bounded subagent task packets, file leases, return contracts,
  fold-in gates, and coordinator-owned device/final-verdict work. No product
  code, build, device action, or provider call occurred.
