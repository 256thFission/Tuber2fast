# Notebook surface

The product-facing notebook flow opens on a local library, then enters a
zoomable PencilKit page with a compact floating toolbar.

## User flow

- Create a notebook by choosing a title, cover, and paper template.
- Tap a cover to open it; long-press the card to rename or delete it.
- Draw with pen, pencil, highlighter, or eraser; change color and stroke width
  from the toolbar.
- Use the lasso to select and move strokes.
- Use the adjacent sparkle-lasso to refine a region and apply the result directly
  to the page; refinement changes drawing/image state, never an Agentic Layer.
- Add images, pages, and drawing layers without leaving the page.
- Export the current page as PDF or the note data as a `.spud` archive. `.spud`
  preserves full Pin annotations and Agentic Layer visibility; compressed PDF
  export is drawing-only and contains no Pin, citation, or conversation markup.

## Agentic layers and Pins

Pins are persisted only inside `Notebook.agenticLayers` through
`ConversationLayer.conversations`. They are not stored on `NotebookPage` or
exposed as a separate global canvas tool.

Each Agentic Layer chip is an explicit hidden/active toggle. Activating one
shows only its Pins for the current page; tapping the active chip, selecting a
drawing tool, or selecting a drawing layer fully hides Agentic Layer content.
The toolbar's filled gradient and the animated page-edge glow appear only while
an Agentic Layer is active, not merely while the layer picker is open.

“Ask on this layer” opens the frosted question panel. Its answer is persisted as
a Pin at the selection center on the active Agentic Layer, so closing the panel
does not discard the visual result.

The question panel derives a cycle-safe conversation tree from those same
persisted Pins. Selecting a node makes it the parent of the next response; the
child reuses the parent's page region and bounded answer context and persists
an optional parent-thread link. This is Pin branching, not a second transcript
store. Expand a completed Pin to Continue from it directly. Drag the Pin dot to
move its page-normalized anchor; the original semantic selection region stays
unchanged.

## Visual character

The editor keeps the page legible on white paper while the surrounding chrome
uses a dark ambient field, frosted controls, touch ripples, tactile button
feedback, and a small cover-opening animation. Reduce Motion is respected where
the system exposes it.

## Persistence

`NotebookStore` writes one JSON file per notebook under
`Documents/Notebooks/<uuid>.json`. PencilKit drawings are stored as serialized
data per drawing layer. Older single-drawing pages decode into a first drawing
layer so existing local notebooks remain readable.
