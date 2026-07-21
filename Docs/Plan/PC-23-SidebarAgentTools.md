# PC-23 — Contextual sidebar agent tools

Status: **implemented — awaiting build delivery and Phillip's verdict**

Target branch: `main`

Owner: App/Notebook coordination and AgentHarness request/response boundary.
SpatialCanvas retains Pencil and coordinate ownership; Pins retains spatial UI.

## Objective

Make a fresh Pin Chat truthful and useful without interrupting note-taking:
show new-chat copy until a parent exists, send bounded images of the current and
immediately adjacent pages, expose model selection in the sidebar, and allow the
model to request locally validated Pin placement or explicit page navigation.

## Scope and acceptance

- Fresh composer says `Ask about these pages…`; only an actual continuation says
  `Ask a follow-up…`.
- Each normal Release chat turn snapshots previous/current/next pages when those
  pages exist. Missing edge neighbors are omitted.
- The Responses request advertises strict `place_pins` and `switch_page` tools.
  Coordinates, counts, text bounds, page numbers, and stale request state are
  validated locally before mutation.
- `switch_page` is described and executed only as explicit requested navigation;
  a turn cannot move the page after the user has navigated during the request.
- Sidebar model selection uses the route-approved model list and is frozen while
  a response is in flight.
- No provider secret, Pencil, lasso geometry, archive, or coordinate conversion
  boundary changes.

## Session log

- 2026-07-21 — Removed the purple focused-turn glow, border, badge, and selected
  container after Phillip's critique. Simplified transcript composition toward
  conventional chat UI: neutral right-aligned user bubbles and plain full-width
  assistant responses with a quiet glyph; Pin/model context remains subordinate.
- 2026-07-21 — Simplified Phillip's requested fresh-chat copy to `Ask a
  question…`. Adjacent page images remain silent request context only; no image,
  attachment, or page-context preview is presented in the sidebar.
- 2026-07-21 — `CONTRACT:` extended `ProductToolName` with `switch_page` and the
  notebook insight boundary with bounded adjacent-page images and typed tool
  results. This lets App-owned coordination validate and execute model-requested
  navigation/Pin actions without giving AgentHarness direct notebook mutation.
- 2026-07-21 — Implemented fresh-versus-follow-up composer copy, previous/current/
  next full-page snapshots, strict normal-Release `place_pins` and `switch_page`
  declarations/decoding, locally bounded application, and an inline sidebar model
  selector. Focused checks pass 12/12; signed Release build, install, normal
  launch, and process presence pass on exact iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Evidence is under
  `tmp/verify/pc23-sidebar-agent-tools/`; Phillip's live model/tool and UI verdict
  remains.
