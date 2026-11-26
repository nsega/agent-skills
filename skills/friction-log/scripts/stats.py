#!/usr/bin/env python3
"""stats.py: print the weekly-review stats block for a friction log.

Usage: stats.py LOG.md [--today YYYY-MM-DD]

Reads the log in the shape SKILL.md describes (## Open, ## Shipped -> agent,
## Dropped (not agent-shaped), one "- YYYY-MM-DD ..." line per entry) and
prints:

    Open: <N>   (aged >2w: <K>)
    This week: +<captured> captured, <shipped> shipped, <dropped> dropped
    Lifetime: <total_shipped> shipped, <total_dropped> dropped

then, when K > 0, the aged Open lines under "Aged (>2w):", at most 5, in file
order, with a note saying how many more there are.

"This week" is the 7 days ending today (today and the 6 days before it).
"Aged" is an Open entry captured more than 14 days before today. An entry
whose leading date does not parse still counts toward N and the lifetime
totals, but never toward this week or aged; it is named on stderr.

Read-only: it never writes any file. Standard library only.
"""
import argparse
import re
import sys
from datetime import date, timedelta

WEEK_DAYS = 7
AGED_DAYS = 14
AGED_LIMIT = 5
SECTIONS = (("## Open", "open"), ("## Shipped", "shipped"), ("## Dropped", "dropped"))
DATE = re.compile(r"(\d{4}-\d{2}-\d{2})\b")


def parse_date(text):
    try:
        return date.fromisoformat(text)
    except ValueError:
        return None


def read_entries(path):
    """Return {section: [(date or None, line)]} for the three sections."""
    entries = {key: [] for _, key in SECTIONS}
    current = None
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n").rstrip()
            if line.startswith("## "):
                current = next((key for head, key in SECTIONS if line.startswith(head)), None)
                continue
            if current is None or not line.startswith("- "):
                continue
            m = DATE.match(line[2:])
            entries[current].append((parse_date(m.group(1)) if m else None, line))
    return entries


def stats_block(entries, today):
    week_start = today - timedelta(days=WEEK_DAYS - 1)

    def this_week(section):
        return sum(1 for d, _ in entries[section] if d and week_start <= d <= today)

    aged = [line for d, line in entries["open"] if d and (today - d).days > AGED_DAYS]
    out = [
        f"Open: {len(entries['open'])}   (aged >2w: {len(aged)})",
        f"This week: +{this_week('open')} captured, "
        f"{this_week('shipped')} shipped, {this_week('dropped')} dropped",
        f"Lifetime: {len(entries['shipped'])} shipped, {len(entries['dropped'])} dropped",
    ]
    if aged:
        out += ["", "Aged (>2w):"] + aged[:AGED_LIMIT]
        if len(aged) > AGED_LIMIT:
            out.append(f"(+{len(aged) - AGED_LIMIT} more aged, not shown)")
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Print the friction log's weekly stats block.")
    ap.add_argument("log", help="path to friction-log.md")
    ap.add_argument("--today", help="YYYY-MM-DD (default: the system date)")
    args = ap.parse_args(argv)

    today = date.today()
    if args.today:
        today = parse_date(args.today) if DATE.fullmatch(args.today) else None
        if today is None:
            ap.error(f"--today: not a YYYY-MM-DD date: {args.today}")
    try:
        entries = read_entries(args.log)
    except OSError as e:
        print(f"stats.py: cannot read {args.log}: {e.strerror}", file=sys.stderr)
        return 2

    for key in entries:
        for d, line in entries[key]:
            if d is None:
                print(f"stats.py: no leading date, not counted by date: {line}", file=sys.stderr)

    print(stats_block(entries, today))
    return 0


if __name__ == "__main__":
    sys.exit(main())
