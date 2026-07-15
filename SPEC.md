# TuberNotes - Build Week Spec

TuberNotes is a spatial AI notebook for iPad.

Circle anything on the canvas with Apple Pencil. An agent sees exactly what you selected, gathers whatever additional context it needs, and places answers back onto the page as spatially anchored **Pins**.

The core interaction is:

> **Point -> Investigate -> Point Back**

## 1. Product thesis

Most AI note-taking tools move the user out of their work and into a chat box. TuberNotes keeps the interaction on the page.

The user can circle:

- Handwritten work
- Equations
- Textbook content
- Diagrams
- Mixed ink and document content
- An entire worked solution

The selected region is sent directly to a multimodal model as an image. The agent can additionally inspect the surrounding page, search a preprocessed textbook, search notebook context, or use the web.

The result is not merely a chat response. The agent returns one or more Pins attached to precise points in the selected content.

Examples:

- “This is the key substitution.”
- “The sign error begins here.”
- “This definition comes from Chapter 7.”
- “You used this same idea three pages ago.”
- “These two lines contradict each other.”

The canvas is both the agent's input surface and its output surface.

## 2. Hero interaction

### Magic Lasso

The user circles anything on the page. The selected region glows and lifts visually from the canvas. A compact action strip appears immediately:

> **Explain · Check · Ask**

### Explain

Understand the selected content and annotate the important parts.

Possible output:

- One Pin with a concise explanation
- Multiple Pins explaining different components
- A connection between related regions

### Check

Critique the selected work.

Possible output:

- Correctness confirmation
- The first incorrect step
- Multiple localized issues
- Confidence or uncertainty
- A concise correction

### Ask

The action strip immediately exposes a keyboard field and voice input. The question and selected image are sent together.

Examples:

- “Why does this term disappear?”
- “Explain this like I know calculus but not linear algebra.”
- “Does this contradict what I wrote above?”
- “Where did I first go wrong?”

No additional mode-selection screen is required.

## 3. The signature primitive: Pins

A Pin is a persistent AI annotation attached to a precise point or region on the page.

- **Collapsed:** ✦ Sign error starts here
- **Tap:** expands the explanation inline, streams additional content if still generating, and shows citations or source links.
- **Long-press:** opens the full conversation Thread behind the Pin.

A single lasso may produce multiple Pins.

~~~text
  x² - 4 = 0          ✦ Correct factorization
  (x - 2)(x + 2)
  x = 2               ✦ You dropped the second solution
~~~

The model reasons about the image and returns normalized coordinates relative to the selected crop. The app owns coordinate transforms and rendering. The model owns semantic targeting.

## 4. Core loop

~~~text
Apple Pencil lasso
        ↓
capture exact visible selection
(background + handwriting + diagrams)
        ↓
optional contextual envelope
(document identity, page number, nearby text)
        ↓
multimodal agent
        ↓
agent optionally calls tools
        ↓
place_pins(...)
        ↓
crop coordinates → page coordinates
        ↓
Pins appear directly on the canvas
~~~

The live interaction is explicitly vision-first, not OCR-first. The selected pixels are the primary source of truth. Structured context may supplement the image when useful but never replaces it.

## 5. Context envelope

The model receives the exact selected image plus lightweight metadata when available.

~~~swift
struct LassoSelection: Identifiable {
    let id: UUID
    let pageID: UUID
    var path: [CGPoint]        // normalized page coordinates
    var regionRect: CGRect     // normalized page coordinates
    var image: CGImage         // background + PDF/textbook + ink + diagrams
    var context: SelectionContext
}

struct SelectionContext {
    var documentID: UUID?
    var documentTitle: String?
    var pageNumber: Int?
    var nearbyText: String?
}
~~~

The context envelope exists to provide information the crop itself may not contain:

- Which textbook this is
- Which page
- Relevant text just outside the lasso
- Notebook identity
- Retrieval routing information

**Principle:** Never replace available pixels with extracted structure. Attach useful structure to the pixels.

## 6. Pin output contract

~~~swift
struct PinPlacement: Codable, Identifiable {
    let id: UUID
    let threadID: UUID
    var target: NormalizedPoint       // normalized 0...1 inside lasso crop
    var targetRegion: NormalizedRect? // optional highlight/connection area
    var teaser: String
    var body: String
    var citations: [Citation]
}
~~~

The model calls place_pins.

Example:

~~~json
{
  "pins": [
    {
      "x": 0.71,
      "y": 0.43,
      "teaser": "The sign error starts here",
      "body": "When moving this term across the equality..."
    }
  ]
}
~~~

The app transforms selection-image coordinates to page-normalized coordinates and then to canvas/view coordinates. Nothing persistent is stored in screen coordinates.

## 7. Agent harness

The harness is responsible for:

- ChatGPT/Codex OAuth authentication
- Multimodal model requests
- Tool calling
- Context gathering
- Streaming
- Structured Pin creation

Tools:

- inspect_selection
- read_page_context
- search_textbook
- search_notebook
- web_search
- place_pins

The agent chooses how much investigation is required.

~~~text
User selects equation
        ↓
Agent inspects image
        ↓
Needs definition from chapter?
    ├── no → answer
    └── yes
         ↓
    search_textbook
         ↓
    synthesize
         ↓
    place_pins
~~~

The user may see lightweight progress states:

- Looking at your work…
- Checking the textbook…
- Comparing earlier notes…
- Searching the web…

The internal tool loop should feel visible enough to demonstrate agency without becoming a developer console.

## 8. Knowledge architecture

There are two intentionally different paths.

### Live understanding

~~~text
Magic Lasso → rendered image crop → frontier multimodal model
~~~

No OCR prerequisite. The model directly sees handwriting, equations, diagrams, spatial layout, printed material, and mixtures of all of the above.

### Important-document preprocessing

~~~text
PDF / textbook
    → DeepSeek-OCR offline preprocessing
    → structured searchable index
    → bundled or imported knowledge source
~~~

The goal is not to OCR every lasso. The goal is to turn important long-form documents into high-quality agent tools.

The index should preserve document identity, page numbers, section/chapter information, text, and useful layout structure where practical.

Initial retrieval can remain simple. The impressive behavior is: the agent sees something on the canvas, realizes it needs outside information, searches the correct textbook, and returns the answer to the exact place where it matters.

## 9. Canvas and document scope

The canvas exists to support the spatial AI interaction.

### Build

- Apple Pencil ink
- Pan and zoom
- PDF/textbook background
- Multiple pages if straightforward
- Persistence sufficient for the demo
- Reliable coordinate transforms
- Pin overlays

### Deprioritize

- Exhaustive GoodNotes feature parity
- Sophisticated document management
- Advanced notebook organization
- Broad import compatibility
- Production-grade migration
- Elaborate pen-tool customization

The test is: does this feature make the spatial agent interaction more impressive or more reliable? If not, it is not on the critical path.

## 10. Build architecture

### Thread 1 - Spatial Canvas

Owns PencilKit canvas, page rendering, PDF background, lasso geometry, crop rendering, and page/crop/view transforms.

**Demoable-alone bar:** Draw and lasso arbitrary mixed content. A fake Pin lands at a specified coordinate and remains attached during pan and zoom.

### Thread 2 - Pins and Threads

Owns Pin visual design, Pin placement, expansion, streamed body, citations, long-press Thread UI, and multi-Pin collision handling.

**Demoable-alone bar:** Feed canned Pin placements into the canvas and produce a polished spatial annotation experience.

### Thread 3 - Agent Harness

Owns ChatGPT/Codex OAuth, multimodal request, tool loop, structured place_pins, and token/event streaming.

**Demoable-alone bar:** Give the harness a screenshot and intent. Receive one or more correctly structured Pins from a real model.

### Thread 4 - Knowledge

Owns DeepSeek-OCR textbook preprocessing, static index, textbook search, notebook search, and web search adapter.

**Demoable-alone bar:** Query a known textbook concept and return the correct page and supporting content.

### Thread 5 - Integration and Adversarial QA

Owns the end-to-end hero slice, shared contracts, regression scenarios, demo reliability, and latency tuning.

The QA role actively attempts to disprove milestone claims:

- Does the Pin drift after zooming?
- Does the model point outside the crop?
- Does the lasso correctly capture mixed background and ink?
- Can multiple Pins overlap catastrophically?
- Does the agent still succeed when textbook retrieval fails?
- Can the hero scenario be reproduced repeatedly?

## 11. Milestones

### M0 - Spatial illusion

~~~text
draw → lasso → fake Pin
~~~

The Pin lands exactly where requested and survives zoom/pan. This milestone proves the fundamental interaction before any intelligence exists.

### M1 - The canvas points back

~~~text
lasso → real multimodal model → place_pins → real Pin
~~~

No retrieval required. This is the first true product milestone.

### M2 - Multi-Pin intelligence

~~~text
lasso complex region
    → model analyzes multiple subregions
    → several Pins appear at meaningful points
~~~

This proves the product is more than a spatially positioned chat bubble.

### M3 - Agent investigation

~~~text
lasso
    → agent decides more context is needed
    → searches textbook/notebook/web
    → grounded Pins with citations
~~~

This proves the harness matters.

### M4 - Reach goals

Once the hero path is reliable, implement the highest-impact reach capabilities available within the remaining time. Reach goals are explicitly allowed to displace conventional note-app polish.

## 12. Primary demo

Open a STEM textbook or notebook page. The user has written a multi-step solution with a subtle mistake. Circle the entire derivation and tap **Check**.

The selection glows. Status briefly shows:

- Looking at your work…
- Checking the textbook…

Multiple Pins appear:

- A subtle confirmation beside a correct step
- A prominent Pin beside the first mistake
- Optionally, a downstream Pin noting that later steps inherit the error

Tap the mistake Pin. The explanation expands directly beside the work.

Ask by voice:

> “Why can't I do that here?”

The Thread continues with the selected work and prior agent context already attached.

Closing line:

> You point at your work. The agent investigates it. Then it points back.

## 13. Reach goals / nice-to-haves

These features are not required for the core hero slice. They exist to make the project feel surprising, visually memorable, and clearly beyond a conventional notes app with an attached chatbot.

Priority should be based on:

1. Demo impact
2. Implementation leverage from systems already built
3. Reliability on the actual demo device

### Reach A - Multi-Pin teacher markup

Highest-priority reach goal. The user circles an entire page, derivation, proof, essay, or diagram. Instead of returning one generic answer, the agent performs a spatial review and places multiple localized Pins.

~~~text
Step 1        ✦ Correct setup
Step 2        ✦ Nice substitution
Step 3        ✦ First error occurs here
Step 4        ✦ This result inherits the earlier error
~~~

Possible Pin types: positive confirmation, issue, explanation, source, uncertainty, and suggestion.

**Why it demos well:** It proves that the system understands the whole selection, distinct subregions, relationships between steps, and spatially targeted output. This should feel like an intelligent teacher marking up the actual work.

### Reach B - Agent-drawn connectors

Allow the agent to point to relationships between two or more locations.

Examples:

- “These expressions are equivalent.”
- “This variable refers to the quantity defined here.”
- “These two statements contradict one another.”
- “This step follows from this theorem.”

~~~swift
struct ConnectionPlacement {
    var source: NormalizedPoint
    var destination: NormalizedPoint
    var label: String?
}
~~~

The app renders an animated curved connector or arrow.

~~~text
[ earlier equation ] ─────────────→ [ later substitution ]
                         same term
~~~

**Why it demos well:** It gives the agent a visual vocabulary beyond chat bubbles. The AI can express relationships spatially.

### Reach C - Connect to my notes

The agent can search earlier notebook pages.

The user circles a concept and asks, “Where have I seen this before?” The agent searches notebook context and creates a Pin:

> You used the same idea on page 4 →

Tapping the Pin jumps to the earlier location.

Possible uses include connecting repeated concepts, finding earlier definitions, recalling prior mistakes, connecting lecture notes to homework, and connecting a textbook concept to the user's own explanation.

**Why it demos well:** The notebook begins to feel like an external memory system rather than a collection of pages.

### Reach D - Visual web research dropped onto the canvas

The agent may use web search when notebook and textbook context are insufficient.

Examples:

- “Find a better explanation.”
- “What does the current documentation say?”
- “Find a diagram of this.”
- “Is there a more recent result?”

Possible output:

- A source Pin
- An explanation Pin
- A citation card
- A visual reference placed beside the notes

Web results should return to the spatial canvas rather than forcing the user into a separate browser or chat experience.

**Why it demos well:** It shows the canvas acting as a destination for external research.

### Reach E - Live professor mode

Use harness events to turn latency into visible activity.

Possible transient states:

- Looking at your work…
- Checking the textbook…
- Comparing earlier notes…
- Searching the web…
- Found the first issue…

For a multi-step Check operation, progress may appear spatially or in a lightweight floating status indicator.

These states must describe observable tool activity or high-level progress. They should not expose private model reasoning or raw chain-of-thought.

**Why it demos well:** The user can see that the agent is actively investigating rather than merely waiting for a chatbot response.

### Reach F - Handwritten follow-up on the canvas

A user should eventually be able to continue a Thread without opening chat UI.

Example:

1. The user receives a Pin beside an equation.
2. The user writes why? beside the Pin.
3. TuberNotes recognizes the new nearby handwriting as a follow-up.
4. The same agent Thread continues.
5. Another Pin or expanded explanation appears.

Other examples: show me, why not?, prove it, simpler, and source?.

**Why it demos well:** This makes the notebook feel truly conversational without becoming a chat application. The canvas itself becomes the conversation.

### Reach G - Semantic zoom and Pin clustering

Pins adapt to the user's zoom level.

At close zoom, individual Pins are visible and precise targets are obvious. At distant zoom, related Pins collapse into clusters such as 3 issues, 5 explanations, and 2 sources. Zooming back in separates them again.

**Why it demos well:** It makes a heavily annotated page remain usable and gives the interface a polished spatial feel.

### Reach H - Visual correction overlay

For corrections, the agent can optionally show the proposed change directly beside or over the user's work.

~~~text
your result:       x = -4
suggested result:  x =  4
~~~

Possible implementations include ghosted replacement text, strikethrough plus correction, a lightweight inline diff, or a temporary overlay accepted or dismissed by the user.

No handwriting synthesis is required for the first version.

**Why it demos well:** The AI does not merely describe a correction. It visually demonstrates it.

### Reach I - “Find my first mistake”

This is both a potential hero feature and a reach-quality specialization of Check.

The user circles a multi-step derivation. The agent evaluates the work in order, identifies the earliest incorrect transformation, places the primary Pin at that exact step, and optionally marks later consequences separately.

~~~text
Step 1      ✓
Step 2      ✓
Step 3      ✦ First mistake
Step 4      ↳ depends on Step 3
~~~

**Why it demos well:** It combines multimodal understanding, reasoning, spatial targeting, multi-Pin output, and potentially textbook retrieval. This may be the strongest single demo behavior in the project.

## 14. Reach-goal priority order

Recommended implementation order after the hero path:

### Tier 1 - Maximum demo impact

- Multi-Pin teacher markup
- Find my first mistake
- Agent-drawn connectors

### Tier 2 - Makes the product feel new

- Handwritten follow-up on the canvas
- Connect to my notes
- Live professor mode

### Tier 3 - Polish and spectacle

- Visual correction overlay
- Visual web research
- Semantic zoom and Pin clustering

This ordering is not strict. A partially implemented Tier 1 feature that is unreliable should not displace a polished, reliable Tier 2 feature.

## 15. Product principles

1. **Vision-native:** The model sees the same visual content the user sees.
2. **Spatial output:** The answer belongs on the work, not in a detached chatbot.
3. **Multiple insights, multiple Pins:** One selection may contain many meaningful targets.
4. **The agent can express relationships:** Pins are not the only possible visual output. Connections and overlays may communicate information better.
5. **Agentic only when useful:** The harness investigates when necessary rather than blindly calling every tool.
6. **Hackathon-first:** Prefer spectacular interaction quality over broad application completeness.
7. **Robust enough to demo:** The hero path must work repeatedly on the actual iPad.

## 16. Explicitly out of scope for the critical path

- GoodNotes migration
- Production-grade document library
- Rich folder organization
- Exhaustive pen tools
- Multi-device sync
- Generalized textbook ingestion UX
- Broad file compatibility
- Production hardening beyond demo reliability

These may be added only after the spatial agent experience is compelling.

## 17. Scope rule

Nothing is allowed onto the critical path unless it makes this interaction more impressive or more reliable:

~~~text
circle work
    → agent understands it
    → agent investigates when necessary
    → intelligence appears at the correct place
~~~

Conventional note-taking features may be sacrificed to improve:

- Pin placement
- Pin animation
- Multi-Pin reasoning
- Spatial relationships
- Agent visibility
- Demo reliability

## 18. Success criterion

A judge should understand the product without explanation after watching one interaction:

> A person circles something on an iPad. The AI understands the visual work, investigates additional sources when necessary, and places useful responses back at the exact locations they refer to.

The ideal reaction is not:

> “That is a nice AI note-taking app.”

It is:

> “Wait - the agent can actually see and inhabit the page with you.”
