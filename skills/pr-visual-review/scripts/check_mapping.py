#!/usr/bin/env python3
"""check_mapping.py: confirm every `file:function` in a pr-visual-review
node-mapping table exists in the repo.

Usage: check_mapping.py REVIEW.md [--repo DIR] [--base REF]

DIR is the repo at the PR head (default "."). A node-mapping table is a
Markdown table under a "Node mapping" heading, or any table with a "Maps to"
column, as SKILL.md's output format defines:

    | Element in diagram | Maps to | Note |
    |---|---|---|
    | OrderService | `order/service.go:CreateOrder` | |

Each backticked `path:symbol` in the "Maps to" cell (or the second column
when no header says "Maps to") is checked. The path is split at the first
colon, so `a.rs:Foo::bar` keeps its `::`.

Before/after reviews: with --base REF (the PR's base, read with
`git show REF:path`, no checkout), a node on the "before" side is checked
against REF and a node on the "after" side against DIR. The side comes from
the row (a "Side" column, or "(before)" / "(after)" in a cell), else from the
nearest heading above the table that names one side only ("#### Before",
"### Node mapping (after)"). A node whose side cannot be told passes when it
exists at either the head or REF. Without --base every node is checked
against DIR.

Prints one line per problem and exits 1 when there is any:
  - the file does not exist
  - the symbol does not appear in that file
  - a row maps to nothing that reads as `file:function`
  - the review has no node-mapping table at all
A table that looks like a mapping table (has a `file:` style cell) but cannot
be parsed gets a "warn:" line and is skipped; warnings do not fail the run.
Exits 0 when every mapping resolves, 2 on bad usage, an unreadable input or
a REF git cannot resolve. Tables inside fenced code blocks are ignored.

Standard library only, so it runs anywhere python3 and git do.
"""
import argparse
import os
import re
import subprocess
import sys

HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```+|~~~+)")
BACKTICK = re.compile(r"`([^`]+)`")
SEPARATOR_CELL = re.compile(r"^:?-+:?$")
CALL_SUFFIX = re.compile(r"\(.*\)$")
SYMBOL_SPLIT = re.compile(r"::|\.|#|->")
FILE_LIKE = re.compile(r"[\w./-]+\.\w+:[A-Za-z_]")
BEFORE = re.compile(r"\bbefore\b", re.I)
AFTER = re.compile(r"\bafter\b", re.I)
ROW_MARK = re.compile(r"\((before|after)\)", re.I)
SIDE_COLUMNS = ("side", "before/after", "before / after")

HEAD, BASE = "head", "base"


def split_row(line):
    """Split a Markdown table row into stripped cells, honouring \\| escapes."""
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", body)]


def blocks(lines):
    """Yield (headings, [(line number, line), ...]) for each run of lines
    holding a pipe outside fenced code; headings is the (level, text) chain
    of headings above the run, outermost first. Lines that start with a pipe
    and lines that only contain one form separate runs, so a stray pipe in
    prose next to a table does not swallow the table."""
    chain, fence, run = [], None, []
    for n, line in enumerate(lines, 1):
        m = FENCE.match(line)
        if m:
            if fence is None:
                fence = m.group(1)[0] * 3
            elif m.group(1).startswith(fence):
                fence = None
        if fence is None and not m and "|" in line:
            lead = line.lstrip().startswith("|")
            if run and run[-1][1].lstrip().startswith("|") != lead:
                yield list(chain), run
                run = []
            run.append((n, line))
            continue
        if run:
            yield list(chain), run
            run = []
        if fence is not None or m:
            continue
        h = HEADING.match(line)
        if h:
            level = len(h.group(1))
            chain = [c for c in chain if c[0] < level] + [(level, h.group(2))]
    if run:
        yield list(chain), run


def section_side(chain):
    """The side named by the nearest heading that names exactly one side,
    stopping at the review's own title, or None."""
    for _, text in reversed(chain):
        if text.lower().lstrip("🔍 ").startswith("structural review"):
            return None
        b, a = BEFORE.search(text), AFTER.search(text)
        if b and a:
            return None
        if b:
            return BASE
        if a:
            return HEAD
    return None


def mapping_tables(lines, label, warn):
    """Yield (line number, element, cell, side) for each body row of each
    node-mapping table; side is HEAD, BASE or None (cannot tell)."""
    for chain, run in blocks(lines):
        file_like = any(FILE_LIKE.search(line) for _, line in run)
        under_mapping = any("node mapping" in t.lower() for _, t in chain)

        def skip(reason):
            if file_like:
                warn(f"{label}:{run[0][0]}: table looks like a node mapping but was not parsed ({reason}); skipped")

        if not all(line.lstrip().startswith("|") for _, line in run):
            skip("every row must start with |")
            continue
        rows = [(n, split_row(line)) for n, line in run]
        if len(rows) < 2 or not all(SEPARATOR_CELL.match(c) for c in rows[1][1] if c):
            skip("no |---| row under the header")
            continue
        header = [c.lower() for c in rows[0][1]]
        if "maps to" in header:
            col = header.index("maps to")
        elif under_mapping:
            col = 1
        else:
            skip('no "Maps to" column and not under a "Node mapping" heading')
            continue
        side_col = next((header.index(s) for s in SIDE_COLUMNS if s in header), None)
        table_side = section_side(chain)
        for n, cells in rows[2:]:
            element = cells[0] if cells else ""
            cell = cells[col] if col < len(cells) else ""
            side = table_side
            if side_col is not None and side_col < len(cells):
                v = cells[side_col].lower()
                side = BASE if v == "before" else HEAD if v == "after" else side
            marks = {m.lower() for c in cells for m in ROW_MARK.findall(c)}
            if len(marks) == 1:
                side = BASE if marks == {"before"} else HEAD
            yield n, element, cell, side


def entries(cell):
    """Return the `file:symbol` strings in a Maps-to cell."""
    spans = BACKTICK.findall(cell)
    return spans if spans else ([cell] if cell else [])


def symbol_name(symbol):
    """Reduce `Class.method()` or `mod::Type::fn` to its last name."""
    symbol = CALL_SUFFIX.sub("", symbol.strip())
    parts = [p for p in SYMBOL_SPLIT.split(symbol) if p]
    return parts[-1].strip() if parts else ""


class Sources:
    """File text at the head (the working tree) and at the base ref."""

    def __init__(self, repo, base):
        self.repo, self.base, self.cache = repo, base, {}

    def text(self, side, path):
        key = (side, path)
        if key not in self.cache:
            self.cache[key] = self._read(side, path)
        return self.cache[key]

    def _read(self, side, path):
        if side == HEAD:
            full = os.path.join(self.repo, path)
            if not os.path.isfile(full):
                return None
            with open(full, encoding="utf-8", errors="replace") as f:
                return f.read()
        r = subprocess.run(["git", "-C", self.repo, "show", f"{self.base}:./{path}"],
                           capture_output=True)
        return r.stdout.decode("utf-8", errors="replace") if r.returncode == 0 else None


def has_symbol(text, name):
    # A plain whole-word text search is enough here: it catches renamed or
    # invented names without parsing any language.
    return re.search(r"(?<!\w)" + re.escape(name) + r"(?!\w)", text) is not None


def problem_for(sources, side, path, name):
    """Return None when the mapping resolves on its side, else the problem."""
    if sources.base is None:
        sides = [HEAD]
    elif side is None:
        sides = [HEAD, BASE]
    else:
        sides = [side]
    texts = [sources.text(s, path) for s in sides]
    if any(t is not None and has_symbol(t, name) for t in texts):
        return None
    where = {HEAD: "", BASE: f" at {sources.base}"}
    at = where[sides[0]] if len(sides) == 1 else f" at head or {sources.base}"
    if all(t is None for t in texts):
        return f"missing file{at}: {path}"
    return f"missing symbol: {name} not found in {path}{at}"


def check(lines, sources, label, warn):
    problems, checked, found_table = [], 0, False
    for n, element, cell, side in mapping_tables(lines, label, warn):
        found_table = True
        where = f"{label}:{n}"
        items = entries(cell)
        if not items:
            problems.append(f"{where}: {element or 'row'}: no `file:function` in the Maps to cell")
            continue
        for item in items:
            path, sep, symbol = item.partition(":")
            path, name = path.strip(), symbol_name(symbol)
            if not sep or not path or not name:
                problems.append(f"{where}: {element}: `{item}` is not `file:function`")
                continue
            checked += 1
            p = problem_for(sources, side, path, name)
            if p:
                problems.append(f"{where}: {element}: {p}")
    if not found_table:
        problems.append(f"{label}: no node-mapping table found (a table under a \"Node mapping\" heading or with a \"Maps to\" column)")
    return problems, checked


def main(argv):
    parser = argparse.ArgumentParser(
        prog="check_mapping.py",
        description="Check that every `file:function` in a node-mapping table exists in the repo.",
    )
    parser.add_argument("review", help="the review Markdown file")
    parser.add_argument("--repo", default=".", help="repo root at the PR head (default: .)")
    parser.add_argument("--base", help="the PR's base ref; before-side nodes are checked against it")
    args = parser.parse_args(argv[1:])
    if not os.path.isdir(args.repo):
        print(f"check_mapping.py: --repo {args.repo} is not a directory", file=sys.stderr)
        return 2
    if args.base is not None:
        r = subprocess.run(["git", "-C", args.repo, "rev-parse", "--verify", "--quiet", f"{args.base}^{{commit}}"],
                           capture_output=True)
        if r.returncode != 0:
            print(f"check_mapping.py: --base {args.base} is not a commit in {args.repo}", file=sys.stderr)
            return 2
    try:
        with open(args.review, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        print(f"check_mapping.py: cannot read {args.review}: {e.strerror}", file=sys.stderr)
        return 2
    warnings = []
    problems, checked = check(lines, Sources(args.repo, args.base), args.review, warnings.append)
    for w in warnings:
        print(f"warn: {w}")
    for p in problems:
        print(p)
    print(f"{args.review}: {checked} mappings checked, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
