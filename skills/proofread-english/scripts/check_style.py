#!/usr/bin/env python3
"""check_style.py: check English prose against the proofread-english style rules.

Usage: check_style.py [FILE]      (reads stdin when FILE is omitted or "-")

Errors (exit 1) break a rule that has no exception:
  - an em dash, or a stand-in for one: a horizontal bar, a spaced en dash,
    or a double hyphen between words
  - the "It's not X, it's Y" contrast construction and its close variants
Warnings (exit 0) need judgment:
  - a semicolon, which stays only when strictly necessary
  - a spaced single hyphen between words, which usually stands in for a dash

Fenced code blocks, inline code and Markdown quote lines (starting with ">")
are skipped, since they are code or someone else's words.

Standard library only, so it runs anywhere python3 does.
"""
import re
import sys

EM_DASH = "—"
HORIZONTAL_BAR = "―"
EN_DASH = "–"

FENCE = re.compile(r"^\s*(```+|~~~+)")
INLINE_CODE = re.compile(r"(`+)(?:(?!\1).)+?\1")
SPACED_EN_DASH = re.compile(r"(?:^|\s)" + EN_DASH + r"(?:\s|$)")
DOUBLE_HYPHEN = re.compile(r"(?<=[\w)\"'’])--(?=[\w(\"'])|\s--\s|\s--$|^--\s")
SPACED_HYPHEN = re.compile(r"(?<=\w)\s-\s(?=\w)")

# "It's not X, it's Y", "This isn't about X. It's about Y.",
# "X is not A, it is B", "It's not just X, it's Y".
_SUBJ = r"(?:it|this|that|which)"
_APOS = r"['’]"
_BE = rf"(?:{_APOS}s|\s+is|\s+was)"
_NEG = rf"(?:\b{_SUBJ}{_BE}\s+not\b|\b{_SUBJ}\s+(?:isn|wasn){_APOS}t\b|\b(?:is|was)\s+not\b|\b(?:isn|wasn){_APOS}t\b)"
_BREAK = rf"(?:[,:–—]|--|\.|;)"
CONTRAST = re.compile(
    rf"{_NEG}[^.!?\n]{{1,90}}?{_BREAK}\s*(?:but\s+|rather\s+)?\b{_SUBJ}{_BE}\b",
    re.I,
)

SEMICOLON = re.compile(r";")


def prose_lines(text):
    """Yield (line number, line) for lines outside fences and quotes, with
    inline code blanked out so columns still line up."""
    fence = None
    for n, line in enumerate(text.splitlines(), 1):
        m = FENCE.match(line)
        if m:
            marker = m.group(1)[0] * 3
            if fence is None:
                fence = marker
            elif m.group(1).startswith(fence):
                fence = None
            continue
        if fence is not None or line.lstrip().startswith(">"):
            continue
        yield n, INLINE_CODE.sub(lambda c: " " * len(c.group(0)), line)


def check_text(text):
    errors, warnings = [], []
    lines = list(prose_lines(text))
    for n, line in lines:
        for ch, name in ((EM_DASH, "em dash"), (HORIZONTAL_BAR, "horizontal bar used as a dash")):
            col = line.find(ch)
            while col != -1:
                errors.append((n, col + 1, f"{name}: rewrite with a comma, colon, parentheses or a new sentence"))
                col = line.find(ch, col + 1)
        for m in SPACED_EN_DASH.finditer(line):
            errors.append((n, m.start() + 1, "spaced en dash used as a dash: rewrite without a dash"))
        for m in DOUBLE_HYPHEN.finditer(line):
            errors.append((n, m.start() + 1, "double hyphen used as a dash: rewrite without a dash"))
        for m in SPACED_HYPHEN.finditer(line):
            warnings.append((n, m.start() + 1, "spaced hyphen reads as a dash: rewrite unless it is a list or a range"))
        for m in SEMICOLON.finditer(line):
            warnings.append((n, m.start() + 1, "semicolon: keep only if strictly necessary, otherwise split the sentence"))
    # The contrast construction can span a line break, so search sentence text
    # joined across consecutive prose lines.
    joined = "\n".join(line for _, line in lines)
    starts = []
    pos = 0
    for n, line in lines:
        starts.append((pos, n))
        pos += len(line) + 1
    for m in CONTRAST.finditer(joined.replace("\n", " ")):
        n = max((s for s in starts if s[0] <= m.start()), default=(0, 1))[1]
        snippet = m.group(0)
        if len(snippet) > 60:
            snippet = snippet[:57] + "..."
        errors.append((n, None, f'"It\'s not X, it\'s Y" construction: "{snippet}": state the positive claim directly'))
    return errors, warnings


def main(argv):
    if len(argv) > 2 or (len(argv) == 2 and argv[1] in ("-h", "--help")):
        print("usage: check_style.py [FILE]", file=sys.stderr)
        return 2
    path = argv[1] if len(argv) == 2 else "-"
    if path == "-":
        text, label = sys.stdin.read(), "<stdin>"
    else:
        with open(path, encoding="utf-8") as f:
            text, label = f.read(), path
    errors, warnings = check_text(text)
    for n, col, msg in sorted(warnings, key=lambda w: (w[0], w[1] or 0)):
        print(f"warn:  {label}:{n}:{col}: {msg}")
    for n, col, msg in sorted(errors, key=lambda e: (e[0], e[1] or 0)):
        where = f"{n}:{col}" if col else f"{n}"
        print(f"error: {label}:{where}: {msg}")
    print(f"{label}: {len(errors)} errors, {len(warnings)} warnings")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
