# PC-22 — Magic Lasso interaction polish and direct-to-chat mode

Status: **implementation complete and Release-delivered — awaiting Phillip's verdict**

Target branch: `main`

Coordinator: Notebook integration and final device judgment. File leases are
non-overlapping: SpatialCanvas animation, NotebookToolbar entry UI, focused
checks, and coordinator-owned NotebookView integration.

## Objective and user-visible outcome

Keep regular Lasso and Magic Lasso separate while making Magic Lasso feel
deliberate and giving its bottom-toolbar bubble two explicit modes:

- `Guidance Pins` retains the current Magic Lasso selection → contextual
  Explain/Check/Ask workflow;
- `Send to Chat` arms the next Magic Lasso, submits that captured selection
  through the existing bounded analysis path, and opens full Pin Chat;
- drawing the Magic Lasso uses a restrained indigo/cyan living trace, and a valid
  closed loop receives a short seal animation and haptic before existing capture;
- invalid loops retain truthful warning feedback.

## Scope and file leases

- SpatialCanvas lease: `TuberNotes/SpatialCanvas/MagicLasso.swift` only.
- Toolbar lease: `TuberNotes/Notebook/NotebookToolbar.swift` only.
- Check lease: one new focused source-contract test only.
- Coordinator: `TuberNotes/Notebook/NotebookView.swift`, project integration if
  required, this plan, parent plan, final diff/build/install/launch.

## Non-goals and dependencies

- No regular Lasso changes; no coordinate/crop geometry, persistence/archive,
  provider/auth, prompt schema, Pin placement, or conversation-model changes.
- Reuse `analyzeCurrentPage(selection:)`, current pending/sign-in state, and full
  Pin Chat presentation. Do not add a parallel chat or selection store.
- Preserve PC-20/PC-21 work and unrelated `.claude/` content.

## Acceptance evidence and stop conditions

- Bottom Magic Lasso bubble exposes Guidance Pins and Send to Chat as distinct,
  accessible choices; choosing either arms the existing Magic Lasso overlay.
- Guidance Pins behaves exactly as today after capture.
- Send to Chat submits the captured selection once, opens full Pin Chat, and does
  not create a second geometry or merge with regular Lasso.
- Valid-loop animation is brief, restrained, Reduce Motion aware where possible,
  and does not delay/corrupt the normalized captured path. Invalid-loop warning
  remains visible and haptic.
- Focused checks, diff hygiene, signed Release build/install/normal launch on the
  exact pinned iPad pass; Phillip owns Pencil feel/animation/taste judgment.

## Session log

- 2026-07-21 — Phillip explicitly requested subagents for the previously proposed
  Magic Lasso UI sugar. Coordinator interpreted the approved direct-chat behavior
  as: arm the next Magic Lasso, analyze that selection through the existing path,
  and open full Pin Chat. Created three non-overlapping implementation/check leases.
- 2026-07-21 — Integrated all three leases. The bottom Magic Lasso strip now offers
  Guidance Pins and Send to Chat; only a selected mode arms the Magic Lasso overlay,
  and regular Lasso remains independent. Direct chat reuses the captured selection,
  existing sign-in gate, `analyzeCurrentPage(selection:)`, and full Pin Chat. The
  drawing trace has a restrained cyan dash drift, quiet selected boundary, brief
  valid-loop seal, and Reduce Motion handling while invalid-loop feedback remains.
  Focused source contracts pass 15/15 and `git diff --check` passes. A signed Release
  build succeeded, then installed and launched normally on Phillip's pinned iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`; process PID 2596 was observed. Build app:
  `tmp/build/pc22-magic-lasso-polish-device/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No automated Pencil drawing or taste judgment was performed; Phillip's verdict on
  menu placement, motion, feel, and the two end-to-end choices remains required.
