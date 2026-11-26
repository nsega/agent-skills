#!/usr/bin/env bash
set -euo pipefail
# Zero-token checks for friction-log: stats.py's weekly stats block on fixture
# logs, and SKILL.md pointing at it. Never touches the user's real vault log.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
STATS="$SKILL_DIR/scripts/stats.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/friction-stats.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }
# $1 = what, $2 = expected file, $3 = actual file
same() { diff -u "$2" "$3" > "$TMP/diff" && ok || bad "$1: $(cat "$TMP/diff")"; }

# 1: SKILL.md runs the script for the stats block and keeps the write rule.
[ -f "$STATS" ] && ok || bad "scripts/stats.py missing"
grep -q "Use Read + Edit, not Bash" "$SKILL_DIR/SKILL.md" && ok || bad "SKILL.md lost the Read + Edit rule"

# 2: an empty log (the bootstrap template) prints zeros and no Aged list.
cat > "$TMP/empty.md" <<'MD'
---
tags: [agents, friction]
updated: 2026-03-20
---

# Friction log

Things >15 min that I'd happily delegate. Append freely. Review weekly.

## Open

## Shipped → agent

## Dropped (not agent-shaped)
MD
cat > "$TMP/zero.want" <<'TXT'
Open: 0   (aged >2w: 0)
This week: +0 captured, 0 shipped, 0 dropped
Lifetime: 0 shipped, 0 dropped
TXT
python3 "$STATS" "$TMP/empty.md" --today 2026-03-20 > "$TMP/out" && ok || bad "empty log failed"
same "empty log" "$TMP/zero.want" "$TMP/out"
: > "$TMP/blank.md"
python3 "$STATS" "$TMP/blank.md" --today 2026-03-20 > "$TMP/out" && ok || bad "0-byte log failed"
same "0-byte log" "$TMP/zero.want" "$TMP/out"

# 3: a full log with a fixed --today of 2026-03-20. This week is 03-14..03-20,
# aged means captured before 03-06. Six aged items: the cap shows five, in file
# order. 03-13 is just outside the week, 03-06 is exactly 14 days (not aged).
cat > "$TMP/log.md" <<'MD'
---
tags: [agents, friction]
updated: 2026-03-20
---

# Friction log

Things >15 min that I'd happily delegate. Append freely. Review weekly.

## Open
- 2026-03-20 — captured today
- 2026-03-14 — first day of the week
- 2026-03-13 — one day before the week
- 2026-03-06 — exactly fourteen days old
- 2026-03-05 — fifteen days old
- 2026-01-10 — aged two
- 2026-02-01 — aged three
- 2026-02-15 — aged four
- 2026-02-20 — aged five
- 2026-02-25 — aged six, over the cap
- someday — an entry with no date

## Shipped → agent
- 2026-03-18 — shipped this week → nsega/agent-skills
- 2026-03-13 — shipped last week → nsega/agent-skills
- 2025-12-01 — shipped long ago → nsega/agent-skills

## Dropped (not agent-shaped)
- 2026-03-15 — dropped this week. needs a human call
- 2026-01-02 — dropped long ago. one-off
MD
cat > "$TMP/log.want" <<'TXT'
Open: 11   (aged >2w: 6)
This week: +2 captured, 1 shipped, 1 dropped
Lifetime: 3 shipped, 2 dropped

Aged (>2w):
- 2026-03-05 — fifteen days old
- 2026-01-10 — aged two
- 2026-02-01 — aged three
- 2026-02-15 — aged four
- 2026-02-20 — aged five
(+1 more aged, not shown)
TXT
cksum "$TMP/log.md" > "$TMP/before"
python3 "$STATS" "$TMP/log.md" --today 2026-03-20 > "$TMP/out" 2> "$TMP/err" && ok || bad "full log failed"
same "full log" "$TMP/log.want" "$TMP/out"
grep -q "no leading date.*someday" "$TMP/err" && ok || bad "undated entry not named on stderr"
cksum "$TMP/log.md" | cmp -s - "$TMP/before" && ok || bad "stats.py changed the log"

# 4: at exactly five aged items there is no "more" line.
grep -v "aged six" "$TMP/log.md" > "$TMP/five.md"
python3 "$STATS" "$TMP/five.md" --today 2026-03-20 > "$TMP/out" 2>/dev/null && ok || bad "five-aged log failed"
grep -q "^Open: 10   (aged >2w: 5)$" "$TMP/out" && ok || bad "five-aged count wrong: $(cat "$TMP/out")"
! grep -q "more aged" "$TMP/out" && ok || bad "cap note printed at exactly five"

# 5: a later --today moves entries out of the week and into aged.
python3 "$STATS" "$TMP/log.md" --today 2026-04-10 > "$TMP/out" 2>/dev/null && ok || bad "later --today failed"
grep -q "^Open: 11   (aged >2w: 10)$" "$TMP/out" && ok || bad "later --today aged count wrong: $(cat "$TMP/out")"
grep -q "^This week: +0 captured, 0 shipped, 0 dropped$" "$TMP/out" && ok || bad "later --today week wrong: $(cat "$TMP/out")"

# 6: bad input fails loudly and writes nothing.
if python3 "$STATS" "$TMP/missing.md" --today 2026-03-20 > /dev/null 2>&1; then bad "missing log passed"; else ok; fi
if python3 "$STATS" "$TMP/log.md" --today 2026-3-2 > /dev/null 2>&1; then bad "bad --today passed"; else ok; fi
[ ! -e "$TMP/missing.md" ] && ok || bad "stats.py created the missing log"

echo "friction-log: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
