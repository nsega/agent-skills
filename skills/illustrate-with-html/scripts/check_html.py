#!/usr/bin/env python3
"""check_html.py: check that an illustration is one self-contained .html file.

Usage: check_html.py FILE.html

Enforces the self-contained rules in SKILL.md ("The non-negotiables"):
nothing loaded from the network (scripts, stylesheets, fonts, images,
frames, media) and no Mermaid. Prints one line per problem and exits 1 if
there are any, 0 if the file is clean, 2 on a usage error.

Standard library only, so it runs anywhere python3 does.
"""
import re
import sys

# Copied from skills/explain-with-slides/scripts/check_deck.py (EXTERNAL).
EXTERNAL = re.compile(
    r"""<script[^>]+\bsrc\s*=|<link[^>]+\bhref\s*=\s*["']?(?:https?:)?//"""
    r"""|<(?:img|iframe|video|audio|source)[^>]+\bsrc\s*=\s*["']?(?:https?:)?//"""
    r"""|@import|url\(\s*["']?(?:https?:)?//""",
    re.I,
)

# Mermaid in any form: a diagram block for the runtime, a call into it, an
# import of it, or a Markdown fence that would show up as raw text.
MERMAID = re.compile(
    r"""\bclass\s*=\s*["'][^"']*\bmermaid\b"""
    r"""|\bmermaid\s*\.\s*(?:initialize|init|run|render|contentLoaded)\b"""
    r"""|\bimport\b[^;\n]*\bmermaid\b"""
    r"""|```\s*mermaid\b""",
    re.I,
)


def line_of(raw, pos):
    return raw.count("\n", 0, pos) + 1


def check(path):
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
    except OSError as e:
        print(f"check_html.py: {e}", file=sys.stderr)
        return 2

    problems = []
    for m in EXTERNAL.finditer(raw):
        problems.append((m.start(), f"loads an external resource: {m.group(0)[:60]!r} (inline it)"))
    for m in MERMAID.finditer(raw):
        problems.append((m.start(), f"uses Mermaid: {m.group(0)[:60]!r} (hand-author the SVG)"))

    for pos, msg in sorted(problems):
        print(f"{path}:{line_of(raw, pos)}: {msg}")
    return 1 if problems else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check_html.py FILE.html", file=sys.stderr)
        sys.exit(2)
    sys.exit(check(sys.argv[1]))
