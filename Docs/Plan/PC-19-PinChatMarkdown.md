# PC-19 — coherent Pin Chat and safe Markdown

Status: **in progress — Fold 1 contracts frozen**

Target branch: `main`

Owner: coordinator-owned Notebook/App integration. `Pins` retains spatial
interaction ownership; AgentHarness/provider/auth routing remains unchanged.

## Objective and user-visible outcome

Make the current normal Release conversation path read as one coherent Pin
Chat: the narrow Agentic Layer sidebar navigates persisted conversations, while
the full-width Pin Chat presents the selected lineage, page/Pin context,
branches, send state, and a keyboard-safe composer. Preserve complete assistant
responses as ordinary bounded text and render assistant content as safe,
readable Markdown without leaking Markdown syntax into compact previews or
accessibility labels.

## Frozen contracts

- `PageAnnotation.body` remains the persisted source string. The additive
  optional `userPrompt` records only literal user-authored text; existing
  notebook and SPUD payloads decode its absence as context-only with no
  migration.
- `threadID`, optional `parentThreadID`, annotation/page identity, Pin targets,
  target regions, retry/cancel semantics, and provider routing remain unchanged.
- Provider response parsing preserves the complete bounded assistant text. It
  may derive compatibility fields, but must not discard later paragraphs or
  block structure.
- Only assistant bodies are interpreted as Markdown. User-entered prompts use
  literal text, and synthetic legacy teasers are not asserted to be verbatim
  user speech.
- A reusable bounded block renderer supports paragraphs, headings, emphasis,
  strong emphasis, ordered/unordered lists, blockquotes, inline code, fenced
  code, and user-initiated `http`/`https` links. HTML, images, scripts,
  `javascript`, `file`, `data`, and custom schemes are inert and never loaded.
- Rendering bounds are deterministic: bounded input, block count, nesting, and
  per-block content; malformed input remains readable plain text. The original
  persisted source is never rewritten by rendering.
- One shared plain-text projection supplies navigation previews and
  accessibility. It removes Markdown punctuation/destinations while retaining
  readable labels and code content.
- Narrow sidebar: layer identity, selection/page summary, new-conversation
  entry, concise root/node navigation, selected state, page number, and truthful
  descendant count. It does not duplicate the transcript.
- Full Pin Chat: explicit notebook exit, selected page/Pin context, untruncated
  root-to-focused chronology with distinct user/assistant roles, visible
  sibling/child alternatives, tail status, and a bottom safe-area composer.
  Sidebar and full chat cannot diverge because both use the same selected
  thread binding.

## Scope and implementation leases

- Renderer package: new isolated Markdown view/projection/parser files and
  focused host-safe checks only.
- Content preservation package: `TuberNotes/Notebook/AgentInsight.swift` and
  narrowly related isolated checks only.
- Conversation component package: isolated new full-chat/sidebar components;
  no direct integration or ViewModel/provider/persistence changes.
- Coordinator fold-in: `AgentSidebarView.swift`, `NotebookView.swift`, and the
  narrowest required `NotebookViewModel.swift` state/content integration;
  project membership; focused current-product checks; this plan and parent.

## Non-goals

- No persistence or archive migration, parallel conversation store, provider,
  credential/session, endpoint, model-routing, or response-transport change.
- No Pin coordinate, target, gesture, label-placement, page-navigation, Pencil,
  or SpatialCanvas ownership change.
- No executable HTML, web view, remote image, automatic navigation, file URL,
  custom plugin, math renderer, syntax-highlighting package, or third-party
  Markdown dependency.
- No deprecated DeveloperSupport feedback/review UI, historical review
  artifacts, scenario conversation UI, PencilFixtureMCP, review MCP, or
  human-device-loop use or modification.

## Work and verification

1. Fold 1: trace normal current-product data flow and independently attack
   architecture, Markdown safety, and iPad hierarchy; freeze the contracts.
2. Fold 2: implement the three non-overlapping packages, then coordinator-fold
   every diff into the active `NotebookView → AgentSidebarView` path.
3. Run focused parser/projection/tree/content/persistence/source checks and a
   canonical generic Release build where useful.
4. Fold 3: independently attack lineage, Markdown abuse/regressions, and the
   current-product iPad mechanics; perform one bounded correction pass.
5. Pin only iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`, build signed Release,
   install, and normally launch without any Debug/review/scenario route.
6. Inspect the final diff and record mechanically obtainable evidence. Phillip
   alone supplies the current normal-app visual/interaction verdict.

## Acceptance evidence and stop conditions

- Complete assistant source survives provider parsing → persistence → reload;
  existing plain-text bodies remain correct.
- Required Markdown blocks/inlines render safely; hostile links/HTML/images are
  inert; projection/accessibility contain no raw markup destinations.
- Sidebar and full chat have distinct roles; selected focus, chronology,
  page/Pin context, alternatives, status, and composer are truthful.
- Lineage remains cycle-safe and stable across roots, children, siblings,
  missing parents/pages, page changes, retry/cancel, and reload.
- Focused host checks, diff hygiene, and exact-device signed Release
  build/install/normal launch succeed. Mechanically unavailable UI actions are
  labeled unverified rather than inferred.
- Stop only after those facts are recorded and Phillip's taste verdict is the
  sole remaining gate, or after an unavoidable security/credential/permission/
  architecture/device blocker remains after safe alternatives are exhausted.

## Session log

- 2026-07-21 — Started on `main` at `15f27ea`; worktree contained only the
  pre-existing untracked `.claude/`, which remains untouched. Read the required
  product, plan, development/device, current Notebook, PageAnnotation/Pin, and
  repository-skill contracts completely. Three independent read-only reviewers
  traced current normal architecture, Markdown safety, and iPad hierarchy.
  Frozen result: remove the lossy response transform; preserve body source;
  use a bounded assistant-only block renderer plus shared plain-text projection;
  make the sidebar navigation-only and full chat transcript/composer-focused;
  preserve existing schema, lineage, coordinates, credentials, and provider
  routing. No deprecated review/human-device surface was used or touched.
- 2026-07-21 — `CONTRACT:` add optional `PageAnnotation.userPrompt` because the
  existing `teaser` cannot distinguish a provider-authored Pin label from a
  literal user question after reload. Missing values remain readable as
  context-only; annotation/body/lineage/page/coordinate/archive identities and
  provider behavior are unchanged.
