# Queue

Phillip's list of what is open. Read it to orient, not to be assigned. An
item is removed when it is done or no longer matters. Proof that something
is done lives in CI and the pull request. Defects live in the code:

```bash
grep -rn "KNOWN DEFECT" Modules/ TuberNotesApp/ TuberNotesTests/
```

## Sign the contract

`Docs/Contract.md` was drafted from the v2 code. It is in force once
Phillip has read it, kept or struck each rule, and committed it with a
`CONTRACT:` subject. The old contract is gone; nothing in it is an
argument.

## Three device checks

Feel is tested. Three mechanisms are still guesses, each marked in code:

- **Undo interception.** Draw, use the system undo gesture, and check that
  the stroke removed is the one the notebook removed.
  `FilteringUndoManager`.
- **Backdrop registration.** Pinch fast on a ruled page. Either the rules
  stay under the strokes or they do not. `PageCanvasController`.
- **Per-stroke cost at depth.** Twenty thousand strokes, reading the
  drawing on every stroke end. The result sets the byte limit
  `InkHistory` needs.

## Parity gaps

Everything here renders. What is missing is the gesture or sheet that
creates it. None of it changes the file format.

- Tool picker: widths, a colour well, eraser modes.
- Editing a text box. Inserting one gives placeholder text.
- Selecting and moving layers. `layerTransformed` has no caller.
- A page navigator with thumbnails. Where the cache lives is undecided.
- Choosing page size and paper when creating a page.
- Creating a link.

## Custom paper

Built in the format, renderer, and notebook: paper is drawn or an asset,
PDF import makes paper pages, `flatten` and `importImageAsPaper` exist.
Not built: the buttons. "Use photo as paper" and "Flatten this page as new
paper" have no place in the toolbar yet. A library-level paper collection,
if wanted, copies the asset into the notebook on use; no format change.

## Not wired

`Notebook.detailNeeded` and `rerenderComposite` exist and nothing calls
them. The composite is rendered once at 2x and not refreshed on zoom.
Decide whether the sharper backdrop is wanted, then add a caller or delete
both.

## Tab switch does not save

The spec said switching tabs runs a forced save. `Workspace` runs one on
backgrounding and close only. Decide, then make the contract and the code
agree.

## Open decisions

- Where recognition data would live, if built. Leaning outside the
  package.
- The first format version bump and its fixture test.
- Thumbnails: the system caches directory, or a sidecar we own.
