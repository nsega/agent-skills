---
name: illustrate-with-html
description: >-
  Illustrate, explain, or visualize anything as a single self-contained .html
  file instead of a wall of markdown — following "The unreasonable effectiveness
  of HTML." Use this whenever the user wants to SEE a workflow, pipeline, plan,
  diff, architecture/module map, concept, timeline, or report rather than read
  about it: phrasings like "illustrate the current workflow", "show me how X
  works", "draw the deploy pipeline", "flowchart this process", "diagram this
  diff/architecture", "explain consistent hashing visually", "make me a status
  report / incident timeline", or any time spatial layout, annotations, or
  clickable interactivity would communicate better than prose. Trigger even when
  the user doesn't say the word "HTML" or "diagram" — if the intent is to make
  something legible at a glance, reach for this. Prefer it over frontend/app/
  dashboard builders whenever the goal is understanding rather than a shipped
  product. Produces one polished, openable .html in the Anthropic visual style
  (annotated, interactive, no build step). NOT for: real web apps or React
  dashboards, CSS/UI fixes, writing feature code, prose-only PR/code reviews,
  slide decks (.pptx), spreadsheet charts, or animated GIFs.
---

# Illustrate with HTML

## Why this exists

Markdown flattens everything into a column of text you skim. A lot of what we
explain isn't shaped like a column — a deploy pipeline has branches, a diff has
two sides, a plan has a timeline, an architecture has boxes and arrows. When you
force that into prose, the reader rebuilds the spatial picture in their head.
HTML lets you hand them the picture directly: **a document they'd actually read,
not one they'd skim.**

So when someone asks you to illustrate / explain / show / diagram something,
default to producing a single `.html` file they can open in a browser, built on
three ideas from the essay:

1. **Spatial** — preserve the real shape of the information (branches, two-sided
   diffs, timelines, box-and-arrow maps) instead of linearizing it.
2. **Annotated** — margin notes, severity tags, callouts, legends. The picture
   *and* the explanation of the picture live in the same view.
3. **Interactive** — click a step to see detail, collapse sections, toggle
   states, hover for context. Motion and clicks say things prose can't.

This is not "make a generic webpage." It's a focused illustration of one thing,
done well.

## The non-negotiables

- **One self-contained file.** Inline all CSS, JS, and SVG. No build step, no
  `npm`, no external `<script src>` to a CDN, no image files to ship alongside.
  The whole value is that the user double-clicks the `.html` and it just works,
  offline, forever. Inline SVG for diagrams — never a screenshot or PNG.
- **Vanilla everything.** Plain HTML + CSS + a little vanilla JS. No React, no
  D3, no Tailwind, no Mermaid runtime. If a diagram needs nodes and arrows, hand-
  author the SVG (see the flowchart reference) — it's more controllable and has
  zero dependencies.
- **Ground it in the real source.** When illustrating something that exists in
  the repo (a pipeline, a module graph, a diff), read the actual files first and
  put real names, real timings, real paths into the illustration. A flowchart
  drawn from `.github/workflows/` is worth ten generic ones.
- **Keep it to what illuminates.** Annotations should resolve confusion, not
  decorate. If a node, label, or panel isn't earning its place, cut it.

## Pick the format that fits the content

Don't default to a flowchart for everything. Match the shape of the thing:

| The user wants to show…              | Use this pattern                              |
|--------------------------------------|-----------------------------------------------|
| A process / pipeline / workflow / state machine | **Annotated flowchart** — clickable SVG nodes + detail panel |
| Two implementations / before-after / trade-offs | **Side-by-side columns** with inline trade-off notes |
| A code change being reviewed         | **Annotated diff** — diff lines + margin notes, severity tags, jump links |
| A plan / roadmap / rollout           | **Timeline** with milestones, risks, mockups |
| System structure / packages / call flow | **Module map** — box-and-arrow SVG, critical path highlighted |
| How a feature/algorithm works        | **Concept explainer** — collapsible sections, tabbed code, a small live demo |
| What happened over time (post-mortem)| **Incident timeline** — minute-by-minute rows, logs, follow-ups |
| Status / weekly update               | **Report** — shipped vs slipped, small inline charts |

When in doubt, the **annotated flowchart** is the flagship — it's worked out in
full in `references/flowchart-example.html`. Read it before drawing one.

For the structure and key technique of every other pattern above, read
`references/patterns.md` — pull in only the section you need.

## The visual style is fixed (Anthropic look)

Every output uses the same design system so they feel like one family. The full
skeleton — palette, typography, header, card, sticky detail panel, legend,
responsive grid — lives in `assets/base-template.html`. **Start from that file**,
keep the `:root` tokens exactly, and fill in the body for the specific
illustration. The tokens:

```css
--ivory:#FAF9F5;  --slate:#141413;  --clay:#D97757;  --oat:#E3DACC;
--olive:#788C5D;  --rust:#B04A3F;
--gray-150:#F0EEE6; --gray-300:#D1CFC5; --gray-500:#87867F; --gray-700:#3D3D3A;
--serif: ui-serif, Georgia, "Times New Roman", serif;   /* h1, panel titles */
--sans:  system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; /* body */
--mono:  ui-monospace, "SF Mono", Menlo, Consolas, monospace; /* eyebrow, labels, code */
```

Conventions that make outputs cohere:
- **ivory** page, **white** cards with a `1.5px --gray-300` border and `14px`
  radius. Generous padding (`28px` inside cards, `56px` top of page).
- **serif** headline + a **mono uppercase eyebrow** above it naming the category
  (e.g. `Illustrations & Diagrams · Flowchart`), then a short `--lead` sentence
  that says what this illustrates and where the data came from.
- Semantic color: **olive** = success/healthy path, **rust** = failure/error
  path, **clay** = the active/selected/highlighted element. Use them only with
  that meaning.
- A two-column grid (`minmax(0,1fr) 300px`) with the diagram left and a sticky
  detail/legend panel right collapses to one column under ~920px.

## How to build one (the loop)

1. **Clarify the subject and the source.** What exactly are we illustrating, and
   what's the ground truth — repo files, a diff, the user's description? Read it.
2. **Choose the pattern** from the table above. Open `references/patterns.md`
   (or the flowchart example) for that pattern's structure.
3. **Copy `assets/base-template.html`** to the output path and rename it to
   something descriptive (`deploy-pipeline.html`, `auth-refactor-diff.html`).
4. **Fill it in** with real content, keeping the tokens and layout conventions.
   For interactive detail (clickable nodes, tabs, collapse), follow the small
   vanilla-JS pattern in the flowchart example — a `data-*` key on each element
   and a `DETAIL` map keyed by it.
5. **Sanity-check it renders — actually look at it.** A standalone file with no
   network, yes, but also *visually correct*: overlap and collisions are
   invisible in the source and glaring on screen. For any hand-authored SVG
   diagram, render it before handing it over — serve the folder
   (`python3 -m http.server`) and screenshot it with a headless browser, or just
   open it — and confirm no edges cross nodes, no labels collide, nothing is
   clipped. Then tell the user the path and one line on what to click.

If the user is in a repo, write the file there (a sensible spot like `docs/` or
the cwd). Otherwise the Desktop or cwd is fine. Always report the absolute path.
