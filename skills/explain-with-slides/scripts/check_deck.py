#!/usr/bin/env python3
"""check_deck.py: lint a slides-with-notes deck built from deck-template.html.

Usage: check_deck.py DECK.html

Errors (exit 1) break the format: no slides, a slide without a claim title,
a figure or notes, or anything loaded from the network.
Warnings (exit 0) are the style rules from SKILL.md that a script can only
approximate: deck length, claim length, prose on the slide, label count,
notes length, notes that repeat the title, and figure markers the notes
never mention.

Standard library only, so it runs anywhere python3 does.
"""
import re
import sys
from html.parser import HTMLParser

MIN_SLIDES, MAX_SLIDES = 6, 12
MAX_CLAIM_WORDS = 14          # about 40 characters of Japanese
MAX_LABELS = 12               # SVG <text> runs that carry words
MAX_LABEL_CHARS = 40          # longer than this reads as prose
NOTES_MIN, NOTES_MAX = 150, 400

CJK = re.compile(r"[぀-ヿ㐀-鿿가-힯]")
LATIN_WORD = re.compile(r"[A-Za-z0-9][A-Za-z0-9'._-]*")
EXTERNAL = re.compile(
    r"""<script[^>]+\bsrc\s*=|<link[^>]+\bhref\s*=\s*["']?(?:https?:)?//"""
    r"""|<(?:img|iframe|video|audio|source)[^>]+\bsrc\s*=\s*["']?(?:https?:)?//"""
    r"""|@import|url\(\s*["']?(?:https?:)?//""",
    re.I,
)


def words(text):
    """Word count, with CJK text counted as one word per two characters."""
    cjk = len(CJK.findall(text))
    return len(LATIN_WORD.findall(CJK.sub(" ", text))) + cjk / 2


def has_letters(text):
    return len(re.findall(r"[A-Za-z]", text)) >= 2 or bool(CJK.search(text))


class Slide:
    def __init__(self, n):
        self.n = n
        self.claim = ""
        self.has_fig = False
        self.labels = []          # text of each SVG <text>
        self.markers = set()      # numbers on .mk groups in the figure
        self.stage_prose = 0      # <p>, <ul>, <ol> inside .stage
        self.notes = ""
        self.has_notes = False
        self.note_markers = set()


class DeckParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.slides = []
        self.stack = []           # (tag, classes) for open elements
        self.cur = None
        self.text_buf = None      # collecting an SVG <text>
        self.capture = None       # "claim" | "notes" | "note-mk"

    def _in(self, cls):
        return any(cls in c for _, c in self.stack)

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        classes = set((a.get("class") or "").split())
        void = tag in ("br", "hr", "img", "meta", "link", "input", "path",
                       "line", "circle", "rect", "polyline", "polygon", "ellipse",
                       "use", "stop")
        if tag == "section" and "slide" in classes:
            self.cur = Slide(len(self.slides) + 1)
            self.slides.append(self.cur)
        if self.cur is not None:
            if "claim" in classes:
                self.capture = "claim"
            if tag == "svg" and "fig" in classes and self._in("stage"):
                self.cur.has_fig = True
            if tag in ("p", "ul", "ol") and self._in("stage") and not self._in("notes"):
                self.cur.stage_prose += 1
            if "notes" in classes:
                self.cur.has_notes = True
            if tag == "text" and self._in("fig"):
                self.text_buf = ""
            if "mk" in classes and self._in("notes"):
                self.capture = "note-mk"
                self._mk = ""
        if not void:
            self.stack.append((tag, classes))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if self.text_buf is not None and tag == "text":
            t = self.text_buf.strip()
            if self._in("mk"):
                if t.isdigit():
                    self.cur.markers.add(t)
            elif t:
                self.cur.labels.append(t)
            self.text_buf = None
        if self.capture == "note-mk" and tag == "span":
            if self._mk.strip().isdigit():
                self.cur.note_markers.add(self._mk.strip())
            self.capture = None
        if self.capture == "claim" and tag in ("h1", "h2", "h3"):
            self.capture = None
        # pop to the matching open tag (tolerates sloppy nesting)
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                break
        if tag == "section" and self.cur is not None and not self._in("slide"):
            self.cur = None

    def handle_data(self, data):
        if self.cur is None:
            return
        if self.text_buf is not None:
            self.text_buf += data
        if self.capture == "claim":
            self.cur.claim += data
        elif self.capture == "note-mk":
            self._mk += data
        if self._in("notes-inner") and not self._in("notes-label"):
            self.cur.notes += data


def check(path):
    raw = open(path, encoding="utf-8").read()
    errors, warnings = [], []

    for m in EXTERNAL.finditer(raw):
        errors.append(f"loads an external resource: {m.group(0)[:60]!r} (inline everything)")

    p = DeckParser()
    p.feed(raw)
    slides = p.slides

    if not slides:
        errors.append('no <section class="slide"> found')
    elif not MIN_SLIDES <= len(slides) <= MAX_SLIDES:
        warnings.append(f"{len(slides)} slides: aim for {MIN_SLIDES} to {MAX_SLIDES}")

    for s in slides:
        tag = f"slide {s.n}"
        claim = " ".join(s.claim.split())
        notes = " ".join(s.notes.split())
        if not claim:
            errors.append(f'{tag}: no claim title (<h2 class="claim">)')
        elif words(claim) > MAX_CLAIM_WORDS:
            warnings.append(f"{tag}: claim is {words(claim):.0f} words, keep it to one short sentence")
        if not s.has_fig:
            errors.append(f'{tag}: no figure (<svg class="fig"> inside .stage)')
        if not s.has_notes or not notes:
            errors.append(f"{tag}: no notes")
        if s.stage_prose:
            warnings.append(f"{tag}: paragraphs or lists on the slide, move the prose to the notes")
        labels = [t for t in s.labels if has_letters(t)]
        if len(labels) > MAX_LABELS:
            warnings.append(f"{tag}: {len(labels)} text labels on the figure, split it or cut labels")
        for t in labels:
            if len(t) > MAX_LABEL_CHARS:
                warnings.append(f"{tag}: label reads as prose ({t[:40]!r}...)")
        if notes:
            n = words(notes)
            if n < NOTES_MIN or n > NOTES_MAX:
                warnings.append(f"{tag}: notes are about {n:.0f} words, aim for {NOTES_MIN} to {NOTES_MAX}")
            if claim and claim.lower() in notes.lower():
                warnings.append(f"{tag}: notes repeat the claim title word for word")
        for mk in sorted(s.markers - s.note_markers):
            warnings.append(f'{tag}: figure marker {mk} is never referenced in the notes (<span class="mk">{mk}</span>)')
        for mk in sorted(s.note_markers - s.markers):
            warnings.append(f"{tag}: notes reference marker {mk}, which is not on the figure")

    for w in warnings:
        print(f"warn:  {w}")
    for e in errors:
        print(f"error: {e}")
    print(f"{path}: {len(slides)} slides, {len(errors)} errors, {len(warnings)} warnings")
    return 1 if errors else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check_deck.py DECK.html", file=sys.stderr)
        sys.exit(2)
    sys.exit(check(sys.argv[1]))
