---
name: explain-with-slides
description: >-
  Explain a new technology, tool, protocol, or concept as a diagram-first slide
  deck with detailed speaker notes beside every slide, in one self-contained
  .html file: the slide (one claim title plus one diagram) on the left, the
  full explanation on the right, arrow keys to move. Use when the user wants
  to LEARN or get up to speed on something: "explain X as slides", "teach me
  how Raft works", "slides with notes on Kueue", "I'm new to X, walk me
  through it", "make a study deck for X". Trigger too when they ask to
  understand a topic end to end and a long report would be the default, even
  if they never say "slides". Falls back to Markdown with Mermaid when they ask
  for Markdown or a note vault. Routing: one standalone illustration of one
  thing (a pipeline, a diff, a timeline, a status report) is
  illustrate-with-html, a whole-repo architecture wiki is repo-deepwiki, and a
  PR review is pr-review. NOT for: .pptx files, talks to present to an
  audience, shipped web apps, or animated GIFs.
---

# Explain with slides

## Why this exists

A long report and a slide deck can carry the same diagrams and the same facts,
yet the deck is far easier to absorb when each slide is paired with notes. The
format does three things a report does not:

1. **One idea per screen.** Each slide answers one question and states its
   answer as the title. The reader always knows what this screen is for.
2. **Picture first, words second.** The eye takes in the diagram, then the
   notes explain exactly that diagram. The reader never has to hold a figure
   from three paragraphs ago in their head.
3. **A built-in pace.** Moving slide by slide forces small, ordered chunks,
   and the claim titles read in sequence form a summary of the whole topic.

So the split is strict: **the slide shows, the notes explain.** The slide holds
almost no prose. The notes hold all of it.

## Relationship to illustrate-with-html

This skill is a sibling of `illustrate-with-html`, not a replacement:

| | `illustrate-with-html` | `explain-with-slides` |
|---|---|---|
| Output | one focused illustration | a sequence of 6 to 12 slides |
| Text lives in | a detail panel that changes on click | a notes pane beside every slide |
| Shape | the shape of the thing (flow, diff, timeline) | a teaching arc (what, why, how, when) |
| Best for | "show me this pipeline / diff / plan" | "help me understand this technology" |

It shares that skill's design system on purpose. `assets/deck-template.html`
uses the same `:root` tokens, the same semantic colors, and the same SVG node
and edge vocabulary, so a deck and a single illustration look like one family.
When one slide needs a richer diagram pattern (annotated flowchart, module
map, side-by-side columns), read the matching section of
`../illustrate-with-html/references/patterns.md` if that skill is installed,
and draw it at slide scale. Its render-then-read discipline applies here too.

## The non-negotiables

- **One self-contained file.** Inline all CSS, JS, and SVG. No CDN, no build
  step, no image files beside it. It must open offline from a double-click.
  `scripts/check_deck.py` fails the deck if anything loads from the network.
- **A slide is a claim plus a diagram.** The title is one sentence that states
  the slide's conclusion ("Kueue admits whole workloads, not pods"), never a
  topic label ("Admission"). The body is one inline SVG with at most about
  seven boxes and at most three short labels or callouts. No paragraphs and
  no bullet lists on the slide.
- **Notes carry the explanation.** Roughly 150 to 400 words per slide (300 to
  800 characters in Japanese). They read the diagram and go beyond it. They
  never restate the title or retell what the picture already shows.
- **Ground it in real sources.** Read the repo, the official docs, the spec,
  or the paper before drafting. Put real names, real commands, and real
  numbers in. If the topic may have changed since your training data, look it
  up first. Do not invent flags, APIs, versions, or benchmarks. Cite what you
  used on the last slide, and say in the notes when a claim is your inference.
- **Explain by contrast.** Anchor each new idea on something the reader
  already knows ("like a Kubernetes Job, but admitted as a unit"). Use the
  user's background when the conversation, memory, or repo reveals it.
- **Write in the user's language.** These instructions are English, but the
  deck follows the language the user asked in. Keep code, commands, and
  identifiers as they are.

## The arc: 6 to 12 slides

Default order. Merge or drop slides when the topic is small, and give "how it
works" more slides when the mechanism is the hard part. Depth beats coverage.

| # | The slide answers | Typical diagram |
|---|---|---|
| 1 | What is it, in terms of something I know? | contrast pair: the familiar thing vs the new thing |
| 2 | Why does it exist? | before / after, the pain point in rust |
| 3 | What are its parts? | module map, 4 to 7 boxes, the core one in clay |
| 4 to 6 | How does it work? | sequence or state flow, built up across slides |
| 7 | How does it compare? | side-by-side columns or a 2 x 2 |
| 8 | When should I use it, and when not? | decision flow or quadrant |
| 9 | How do I start? | 3 to 5 numbered steps (commands go in the notes) |
| 10 | What should I remember? | the architecture again, annotated, plus sources |

Before drawing anything, **write the claim titles alone** and read them top to
bottom. If they do not teach the gist as a list, fix the titles first. They
are the deck's skeleton and its summary.

## Drawing the slide

`references/slide-patterns.md` has a figure recipe per arc slot. The rules:

- **Seven elements, three labels.** More than that means the slide holds two
  ideas: split it, or build it up across slides.
- **Verbs on arrows.** "admits", "watches", "writes to", never a bare line.
- **Color means something.** clay = the focus of this slide, olive = healthy or
  happy path, rust = the problem or failure path, gray = context. An element
  keeps its color and position from slide to slide.
- **Build up complex pictures.** Repeat the previous figure, add class `dim` to
  what the reader has seen, and draw the new part at full strength. Three
  slides that each add one layer beat one slide with everything.
- **Numbered markers tie the two panes together.** Put a clay marker
  (`<g class="mk">`) on the part of the figure a sentence explains, and
  reference it in the notes as `<span class="mk">1</span>`. The checker warns
  when a marker on the figure is never mentioned in the notes.
- **Readable at slide scale.** The figure's viewBox is 960 x 440. Keep text at
  14 viewBox units or more, which is what the template's kit uses.

## Writing the notes

In this order, as plain paragraphs (no headings inside a note):

1. **How to read the figure.** One or two sentences: where to start, what the
   colors or markers mean.
2. **The point and why it holds.** The mechanism or the reason, not a restated
   title.
3. **Something concrete.** A command, a config snippet, a code fragment, a
   real number, a named system that uses it. Use `<pre><code>` for code.
4. **A misconception or gotcha** in `<p class="gotcha">`: the thing people
   reliably get wrong.

Notes may reference other slides by number ("the two-hash trick on slide 2").
The last slide's notes list the sources.

## Output format

**HTML (default).** Copy `assets/deck-template.html` to a descriptive name
(`kueue-admission-slides.html`) and add one `<section class="slide">` per
slide. The template gives you:

- 16:9 slide on the left, notes on the right, notes scrolling inside the slide's
  height so the slide never jumps
- Left / Right and PageUp / PageDown to move, Home / End to jump, N to hide the
  notes, and `#3` in the URL to deep-link a slide
- notes stacking under the slide on narrow screens (under 980px)
- a print stylesheet with one slide plus its notes per page, so the browser's
  "Save as PDF" makes a handout

`references/example-bloom-filter.html` is a complete 8-slide deck built from
the template. Read it before writing your first deck: it shows the claim
titles, the build-up across slides 2 to 4, markers, and notes at the right
length.

**Markdown with Mermaid (fallback).** Use it when the user asks for Markdown,
wants the deck in a note vault such as Obsidian, or the target renders
Markdown but not HTML. The format is in `references/slide-patterns.md`. Same
rules: one claim heading and one diagram per slide, the notes as prose under
it.

## The loop

1. **Pin down the topic, the reader, and the depth.** Infer the reader's
   baseline from the conversation, memory, or repo. Ask at most one question,
   and only when the answer changes the deck.
2. **Read the sources.** Repo files, official docs, specs. Keep a short list
   of what each claim rests on.
3. **Write the claim titles** for the whole arc and read them as a list.
4. **Copy the template and fill the slides**, figure first, then notes.
5. **Run the checker** and fix every error and every warning you agree with:
   `python3 scripts/check_deck.py path/to/deck.html`
   (path relative to this skill's folder).
6. **Render it, then read the render.** Screenshot a few slides through the
   hash, for example
   `npx playwright screenshot --viewport-size=1400,900 "file:///abs/path/deck.html#3" /tmp/s3.png`,
   then **read the PNG back and look at it**. Confirm that nothing overlaps,
   no arrowhead stops inside a box, no label sits on a line, and the notes
   pane is readable beside the slide. If no browser is available, say so
   rather than claiming the layout was checked.
7. **Report** the absolute path, the slide count, and one line on the keys.

If the user is in a repo, write the deck there (`docs/` or the cwd). Otherwise
the Desktop or cwd is fine.
