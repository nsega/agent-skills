# Illustration patterns

A catalog of formats. Each entry gives the **shape** of the content it suits,
the **structure** to build, and the **one technique** that makes it work. All of
them start from `assets/base-template.html` and keep the design tokens. Pull in
only the section you need.

The flagship — the **annotated flowchart** — is worked out in full in
`flowchart-example.html` (a complete, real file). Read that one as code; the rest
are described here because they're variations on the same kit.

---

## 1. Annotated flowchart  ·  process / pipeline / state machine

**Shape:** a sequence with branches, gates, and success/failure paths.

**Structure:** an inline `<svg viewBox="0 0 W H">` in the left card; a sticky
detail `<aside>` on the right. Nodes are `<g class="node" data-k="…">` groups
containing a `<rect>` (process), a diamond `<path>` (decision), or a rounded
`rect` (terminal), plus `<text>`. Edges are `<path class="edge">` with arrowhead
`<marker>`s defined once in `<defs>`. A legend maps shapes/colors to meaning.

**Key technique:** lay out on a fixed grid in `viewBox` coordinates (e.g. a
vertical spine at x≈310, rows every ~84px) so edges are simple straight or
gently-curved paths. Color the happy path **olive**, failure path **rust**
(dashed), the selected node **clay**. Each node carries `data-k`; a `DETAIL` map
keyed by it drives the panel (title, mono `meta`, body with `<code>`, and a
`<pre>` snippet of the real config/code behind that step). See the example file.

**Avoid the overlap traps** — the thing that makes a hand-authored flow look
broken:
- **Branches get their own columns.** When the spine splits at a gate, send each
  outcome to its *own* x column (e.g. allow ≈ x185, reject ≈ x435) and keep its
  terminal directly below it. Never route a branch back across the other column —
  a 429 path that curves into the "200 → handler" box is both wrong and a visual
  tangle.
- **Edges never pass through a node.** Route around boxes, not over them. Side
  processes (a refiller, a notifier) belong in a clear margin with a single
  curved arrow up the empty side — not threaded between the main nodes.
- **Labels hug their arrow.** An edge label (`yes`, `no · empty`) should sit
  right alongside the path it describes — a few px off the line, near its
  midpoint or bend — not stranded out in the margin where the reader has to guess
  which arrow it belongs to. Close enough to read as one unit, not so close it
  overlaps the stroke. Then nudge so it doesn't collide with a node or another
  label.
- **Give rows real breathing room** (~60px between a box's bottom and the next
  one's top) so arrowheads and labels aren't crammed against borders.
- **Then actually look at it.** Overlap is invisible in the source and obvious on
  screen — render it (open it, or screenshot via a quick `python3 -m http.server`
  + headless browser) and confirm nothing collides before handing it over.

---

## 2. Side-by-side columns  ·  comparing approaches / before-after / trade-offs

**Shape:** two or three alternatives the reader should weigh against each other.

**Structure:** a `display:grid` of 2–3 equal columns, each a `.card` with a mono
eyebrow naming the approach, a short verdict line, the code/sketch, and a
trade-off list. Tag each trade-off with a small pill — olive for a pro, rust for
a con, gray for neutral.

**Key technique:** keep the columns *parallel* — same row order in each so the
eye compares like with like (same lines of code aligned, same headings). The
spatial alignment is the whole point; a markdown table can't hold code blocks
side by side the way this does.

---

## 3. Annotated diff  ·  reviewing a code change

**Shape:** a diff plus the reviewer's reasoning attached to specific lines.

**Structure:** render hunks as a mono block; `+` lines get an olive-tinted
background, `-` lines rust-tinted, context stays neutral. To the right of (or
inline under) a line, a margin note card explains *why* — with a severity tag
(`blocking` rust, `nit` gray, `praise` olive). A header strip lists the files
with jump links (`<a href="#file-2">`) and a one-line summary each.

**Key technique:** anchor notes to lines with id targets and a thin clay
connector or a `▸` marker, so a comment visibly belongs to its line. Lead with
author intent (what the change is for) before the line-level detail — reviewers
read top-down.

---

## 4. Timeline / plan  ·  roadmap, rollout, schedule

**Shape:** milestones along time, with risks and dependencies.

**Structure:** a vertical rail (a 2px gray line) with milestone rows hanging off
it — each a dot on the rail, a date in mono, a title, and a short body. Optional
right column for a risk register (severity-colored) or small mockups. Use
`clay` for the "we are here" marker.

**Key technique:** make *time* the spatial axis — spacing between rows should
roughly track duration so a long gap reads as a long gap. Group parallel
workstreams as side-by-side rails if several things run at once.

---

## 5. Module map  ·  architecture, package graph, call flow

**Shape:** boxes (modules/services) connected by arrows (deps/calls), with one
path that matters most.

**Structure:** inline SVG of labeled `<rect>` boxes and `<path>` edges, same
marker arrowheads as the flowchart. Cluster related boxes (a faint container
`rect` behind a group, labeled with a mono caption). Click a box → panel
describes that module (responsibility, key files, public surface).

**Key technique:** highlight the **critical path** (the request flow or the
risky dependency chain) in clay at full opacity while everything else sits at
~50% — the reader's eye goes straight to what matters instead of drowning in a
hairball. Don't draw every edge; draw the ones that explain the system.

---

## 6. Concept explainer  ·  how a feature or algorithm works

**Shape:** a teaching piece — layered from intuition to detail.

**Structure:** a single-column reading flow inside the sheet (no side panel
needed). Progressive disclosure with `<details>` for "go deeper" sections; a
small **live demo** built from a few inputs + vanilla JS that recomputes on
change (a slider, a couple of buttons); tabbed code samples (radio-input + label
CSS tabs, no JS framework); a short FAQ at the end.

**Key technique:** the live, manipulable model is what beats prose — let the
reader *poke* the idea (e.g. move a slider and watch keys redistribute for
consistent hashing). Build the smallest interactive thing that makes the
mechanism click, then annotate what they're seeing.

---

## 7. Incident timeline  ·  post-mortem

**Shape:** a minute-by-minute sequence of what happened, with evidence.

**Structure:** rows of `time · event`, color-coded by phase (detection,
mitigation rust→olive as it recovers). Inline `<pre>` log excerpts and metric
sparklines (tiny inline SVG `<polyline>`) at the moments they spiked. A
follow-ups section at the end with owners and checkboxes.

**Key technique:** anchor each claim to evidence — put the actual log line or
graph right at the timestamp it describes, so the narrative is auditable rather
than asserted.

---

## 8. Report  ·  weekly status, metrics update

**Shape:** what shipped, what slipped, the numbers.

**Structure:** a compact header with the period, then sections: **Shipped**
(olive checks), **Slipped/at-risk** (rust), and a few metrics as small inline
SVG bar/line charts. Keep it one screen if possible.

**Key technique:** lead with the delta, not the raw number — "p95 320ms (▼40ms)"
in mono, with the arrow colored by whether the move is good. Charts are inline
hand-authored SVG (`<rect>` bars, `<polyline>` lines) — no charting library.

---

## Small inline-chart recipe (reused by reports & timelines)

A bar chart is just rects on a baseline; a line chart is one polyline. Example
of a sparkline — scale your data into the `viewBox` height yourself:

```html
<svg viewBox="0 0 120 32" width="120" height="32">
  <polyline fill="none" stroke="#788C5D" stroke-width="2"
            points="0,28 20,22 40,24 60,12 80,16 100,6 120,9"/>
</svg>
```

Keep charts small and annotated (a label + the latest value in mono) rather than
big and bare. The point is to support a sentence, not to be a dashboard.
