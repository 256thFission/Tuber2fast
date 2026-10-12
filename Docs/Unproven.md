# Unproven

Things this project claims that nobody has checked. Not defects; missing
evidence. No line numbers and no dates, because a document that has to be
re-checked on a schedule rots.

## Never run on an iPad

- **A Release build.** `-configuration Release` compiles. No iPad has
  printed a `TNLog` trace, and no deliberate trap has been seen reported
  on hardware.
- **Undo through the system gesture.** The simulator has no Pencil, and a
  controller with no window has no responder chain. See the queue.
- **A save failing on a real disk.** Refusals, backoff, the retry buffer,
  and the dirty close are tested through a fake file system, never a full
  volume.
- **The background lease.** One forced save per open notebook under
  `beginBackgroundTask`, then a compact of every open package, has run on
  the simulator only. Whether the compact fits inside the lease beside the
  saves, on a notebook of a few hundred pages, is device evidence: it reads
  every page file and every layer file to decide what nothing reaches.
- **The `gesture` log category** (`Modules/TNCore/TNLog.swift`). A new
  stream in `TNLog`, which is on the required-evidence table
  (`CONTRIBUTING.md`), and no iPad has printed a gesture line. The Release
  capture in the Pencil-gestures plan's step 4 pays it.
- **The bindings pass-through** (`Modules/TNEditor/EditorBinding.swift`).
  The editor binding is on the required-evidence table
  (`CONTRIBUTING.md`), and no Pencil stroke has yet carried a gesture
  binding down to the notebook. The same step 4 device run pays it.
- **Two open tabs with a link between them**, tapped by a hand.
- **An object locked.** Tests drive the lock request and the composite
  that answers it. Whether a finger on a locked frame falls through to the
  canvas pan, whether Unlock is reachable in the frame's menu at fit zoom
  and at 4x, and whether the grey border and badge read as locked rather
  than broken are device evidence.
- **Scribble into a text box.** The simulator has no Pencil and Scribble
  does not run there. The hosted test proves only the configuration.
  That handwriting becomes typed runs, that Scribble's own scratch-out
  leaves page ink alone, that a stroke starting just outside the box is
  never a word, and that autocorrection reads as prose are device evidence.
- **The sticker sheet.** Tests prove the catalogue and the insert: every
  symbol renders with a transparent ground and lands as an image layer a
  quarter of the page wide. Whether the grid reads as stickers, whether a
  tap dismisses cleanly, whether the lasso picks one up like a photo, and
  whether a quarter page is the right size are device evidence.

## Measured on the wrong machine

- **Serialize time per save**, which drives the save delay, was measured
  on a Mac. The clamp limits the damage either way.
- **Composite render time** at `maximumLongEdgePixels` on an iPad.

## Not exercised

- The library's touch surfaces. Rename, move, trash, recover, and
  duplicate are tested through the model and never tapped.
- `ImportReader` with a security-scoped URL from Files rather than
  Photos.
- Resizing in Split View during a stroke.
