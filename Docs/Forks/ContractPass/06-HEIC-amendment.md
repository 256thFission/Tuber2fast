# One image format — proposed wording

**This is not the contract.** `Contract.md` is. No agent authors a rule; this
file is proposed wording for Phillip to edit, cut, or adopt. Adopting it means
moving the text into `Contract.md` in a commit tagged `CONTRACT:`.

Stage 1 item 6 of `Docs/Forks/CanvasCompleteTodo.md`, the decided
`image-format-is-heic` item in `Docs/Queue.md`. The decision is Phillip's, of
2026-08-07, and is not relitigated here — what follows is only the text that
makes `Contract.md` state it.

The code is landed and green (`d1ec58b`, pinned by `14d5666`). Until this
amendment is adopted, the contract is silent on a rule the code enforces,
which is the condition stage 1 exists to clear.

---

## The evidence this rests on, first

The decision's premise was that HEIC carries transparency through this
project's own encode and decode path. That is now checked rather than cited:
`TuberNotesTests/HEICAlphaTests.swift` encodes an alpha-carrying `CGImage`
through `ImageImportPreparation.heicEncoded`, reads it back through
`StaticLayerRenderer.downsample` — the renderer's own decode, at full size and
downsampled — and asserts a transparent pixel is still transparent and lets a
backdrop through. It passes on the pinned simulator.

Two findings from running it, because both bear on the wording:

1. `CGImageDestination` **does** embed the alpha auxiliary image on this OS.
   The `CIContext.heifRepresentation` fallback Queue.md held in reserve is not
   needed, so there is no `CIContext` on the import path.
2. The comment in `ImportPreparationTests` that stood TIFF in for HEIC
   "because the simulator has no HEIC hardware encoder" generalized a hardware
   fact into a framework one. The software encode path works. The hardware
   fact itself remains true, and remains device evidence nobody has yet.

## A. *Durable form* — the assets line

The directory diagram (as it stands in `Contract.proposed.md` A6, since the
assets line is not yet in `Contract.md`):

```text
  assets/<assetID>.<ext>  imported originals, byte for byte: .png, .jpeg
```

becomes:

```text
  assets/<assetID>.<ext>  imported sources: .heic for images, .pdf byte for byte
```

*Why the phrase "imported originals, byte for byte" cannot survive.* It is now
false of every image. An imported PNG is stored as a HEIC transcode, so the
bytes under `assets/` are not the bytes the user picked. It stays exactly true
of `pdf`, and the diagram now says which is which rather than implying one
rule for both.

## B. *Durable form* — the closed-set bullet

Replace the format sentence in the `image`-payload bullet:

> A format outside the closed set refuses the layer, exactly as an unknown
> kind does.

with:

> - **There is one image encoding, and it is HEIC.** An `image` layer's asset
>   is a HEIC file; `pdf` is the only other member of the closed set and is
>   not an image encoding. A format outside the set — including `png` and
>   `jpeg`, which an older build wrote — refuses the layer, exactly as an
>   unknown kind does. The ref still stores its format as a string, because
>   that is what makes an unreadable format a layer-scoped refusal rather than
>   a decode failure, and what makes a second image encoding one amendment
>   rather than a payload migration.

*Why one format, in the contract's own terms:* two image encodings, one of
which cannot carry alpha, made the import path choose — and the format
everything unfamiliar was transcoded into was the one that flattens
transparency. Assets are write-once, so that flattening was permanent. This is
a durability rule, not a performance one, which is why it belongs in *Durable
form* rather than in *Performance*: it removes a class of durable data loss by
construction. HEIC's hardware decode and its size at photo scale are why the
one format is HEIC and not PNG.

## C. *Durable form* — what import guarantees

After the write-once bullet ("Assets are sources: write-once and immutable"),
insert:

> - **An image asset is normalized on the way in; a `pdf` asset never is.**
>   Import transcodes any source that is not already HEIC, with EXIF
>   orientation baked into the pixels, so a stored image is upright HEIC and
>   nothing downstream re-derives orientation. The consequence is stated
>   rather than discovered: **the bytes a user gets back for an image are not
>   the bytes they imported.** A PNG comes back as a HEIC, slightly softened.
>   A `pdf` asset is the exception and stays byte for byte — a PDF is not an
>   image, and re-encoding one is rewriting someone else's document rather
>   than transcoding a picture.

## D. Nothing about migration

No wording is proposed for previously stored `png` and `jpeg` assets, and that
is deliberate. Queue.md decides it: nothing is in production, existing
documents are wiped, there is no migration and no refuse-shim. The behaviour
such an asset gets is not a new rule — it is the closed-set refusal in B,
which already says what happens to a format this build cannot open, and which
`ImageLayerTests.anUnknownAssetFormatRefusesTheLayer` now exercises with
`"png"` as its fixture precisely so the decision rests on tested behaviour.

## What is still owed, and is not in the contract's gift

The pin is a simulator result. The physical iPad's hardware HEVC encoder is a
different implementation of the same API, and `AGENTS.md` is explicit that
green CI is silent about anything a device decides. Importing a transparent
PNG on hardware and seeing the transparency survive is a device-evidence
obligation against this change, not a formality.
