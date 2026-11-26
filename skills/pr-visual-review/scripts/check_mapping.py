#!/usr/bin/env python3
"""check_mapping.py: confirm every `file:function` in a pr-visual-review
node-mapping table exists in the repo.

Usage: check_mapping.py REVIEW.md [--repo DIR]     (DIR defaults to ".")

A node-mapping table is a Markdown table under a "Node mapping" heading, or
any table with a "Maps to" column, as SKILL.md's output format defines:

    | Element in diagram | Maps to | Note |
    |---|---|---|
    | OrderService | `order/service.go:CreateOrder` | |

Each backticked `path:symbol` in the "Maps to" cell (or the second column
when no header says "Maps to") is checked against DIR. The path is split at
the first colon, so `a.rs:Foo::bar` keeps its `::`.

Prints one line per problem and exits 1 when there is any:
  - the file does not exist under DIR
  - the symbol does not appear in that file
  - a row maps to nothing that reads as `file:function`
  - the review has no node-mapping table at all
Exits 0 when every mapping resolves, 2 on bad usage or an unreadable input.
Tables inside fenced code blocks are ignored.

Standard library only, so it runs anywhere python3 does.
"""
import argparse
import os
import re
import sys

HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```+|~~~+)")
BACKTICK = re.compile(r"`([^`]+)`")
SEPARATOR_CELL = re.compile(r"^:?-+:?$")
CALL_SUFFIX = re.compile(r"\(.*\)$")
SYMBOL_SPLIT = re.compile(r"::|\.|#|->")


def split_row(line):
    """Split a Markdown table row into stripped cells, honouring \\| escapes."""
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", body)]


def tables(lines):
    """Yield (heading, [(line number, cells), ...]) for each table outside
    fenced code, where heading is the nearest heading above it."""
    heading, fence, rows = "", None, []
    for n, line in enumerate(lines, 1):
        m = FENCE.match(line)
        if m:
            marker = m.group(1)[0] * 3
            if fence is None:
                fence = marker
            elif m.group(1).startswith(fence):
                fence = None
        if fence is not None or m:
            if rows:
                yield heading, rows
                rows = []
            continue
        if line.lstrip().startswith("|"):
            rows.append((n, split_row(line)))
            continue
        if rows:
            yield heading, rows
            rows = []
        h = HEADING.match(line)
        if h:
            heading = h.group(1)
    if rows:
        yield heading, rows


def mapping_rows(lines):
    """Yield (line number, element, [cell text]) for each body row of each
    node-mapping table, the cell text being the "Maps to" column."""
    for heading, rows in tables(lines):
        if len(rows) < 2 or not all(SEPARATOR_CELL.match(c) for c in rows[1][1] if c):
            continue
        header = [c.lower() for c in rows[0][1]]
        if "maps to" in header:
            col = header.index("maps to")
        elif "node mapping" in heading.lower():
            col = 1
        else:
            continue
        for n, cells in rows[2:]:
            element = cells[0] if cells else ""
            cell = cells[col] if col < len(cells) else ""
            yield n, element, cell


def entries(cell):
    """Return the `file:symbol` strings in a Maps-to cell."""
    spans = BACKTICK.findall(cell)
    return spans if spans else ([cell] if cell else [])


def symbol_name(symbol):
    """Reduce `Class.method()` or `mod::Type::fn` to its last name."""
    symbol = CALL_SUFFIX.sub("", symbol.strip())
    parts = [p for p in SYMBOL_SPLIT.split(symbol) if p]
    return parts[-1].strip() if parts else ""


def check(lines, repo, label):
    problems, checked, found_table = [], 0, False
    for n, element, cell in mapping_rows(lines):
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
            full = os.path.join(repo, path)
            if not os.path.isfile(full):
                problems.append(f"{where}: {element}: missing file: {path}")
                continue
            with open(full, encoding="utf-8", errors="replace") as f:
                text = f.read()
            # A plain whole-word text search is enough here: it catches renamed
            # or invented names without parsing any language.
            if not re.search(r"(?<!\w)" + re.escape(name) + r"(?!\w)", text):
                problems.append(f"{where}: {element}: missing symbol: {name} not found in {path}")
    if not found_table:
        problems.append(f"{label}: no node-mapping table found (a table under a \"Node mapping\" heading or with a \"Maps to\" column)")
    return problems, checked


def main(argv):
    parser = argparse.ArgumentParser(
        prog="check_mapping.py",
        description="Check that every `file:function` in a node-mapping table exists in the repo.",
    )
    parser.add_argument("review", help="the review Markdown file")
    parser.add_argument("--repo", default=".", help="repo root the paths are relative to (default: .)")
    args = parser.parse_args(argv[1:])
    if not os.path.isdir(args.repo):
        print(f"check_mapping.py: --repo {args.repo} is not a directory", file=sys.stderr)
        return 2
    try:
        with open(args.review, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        print(f"check_mapping.py: cannot read {args.review}: {e.strerror}", file=sys.stderr)
        return 2
    problems, checked = check(lines, args.repo, args.review)
    for p in problems:
        print(p)
    print(f"{args.review}: {checked} mappings checked, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
