#!/usr/bin/env bash
# Mechanically list the reviewer pairs that trip the Step 4 escalation triggers.
#
# Usage:
#   check_disagreements.sh <CLAUDE_JSON> <GLM_JSON>
#
# The synthesizer is one of the two disputants, so "did anyone disagree with me"
# is the last question it should be answering from memory. This prints the pairs
# that the triggers key on, before any synthesis reasoning happens.
#
# Exit status:
#   0  no escalation-worthy pair found
#   1  at least one pair found (informational, not an error)
#   2  bad usage / unreadable input
#
# LIMIT: pairs are matched on normalized `location`. Two reviewers describing the
# same issue at different locations, or with different framing, will NOT pair up
# here. That case is SKILL.md Step 4.1's job and cannot be automated away.
set -euo pipefail

A="${1:?need claude findings json}"
B="${2:?need glm findings json}"
[ -f "$A" ] || { echo "no such file: $A" >&2; exit 2; }
[ -f "$B" ] || { echo "no such file: $B" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONPATH="$SCRIPT_DIR:${PYTHONPATH:-}" python3 - "$A" "$B" <<'PY'
import json, sys, re
from _findings_lib import norm, load_findings as load

try:
    a, b = load(sys.argv[1]), load(sys.argv[2])
except (OSError, json.JSONDecodeError) as ex:
    sys.exit(f"could not read findings: {ex}")

HIGH = {"critical", "high"}
hits = []

# A missing recommendation is itself escalation-worthy: the schema requires it,
# but enforcement is skippable, and silence must not read as agreement.
for src, doc in (("claude", a), ("glm", b)):
    for f in doc.get("findings", []):
        if not f.get("recommendation"):
            hits.append(f"[missing-recommendation] {src}:{f.get('id','?')} "
                        f"{f.get('location','?')} — no recommendation field; "
                        f"counts as differing, escalate")

bf = {}
for f in b.get("findings", []):
    bf.setdefault(norm(f.get("location")), []).append(f)

for fa in a.get("findings", []):
    for fb in bf.get(norm(fa.get("location")), []):
        ra, rb = fa.get("recommendation"), fb.get("recommendation")
        if ra and rb and ra == rb:
            continue
        sa, sb = fa.get("severity"), fb.get("severity")
        why = []
        if sa in HIGH or sb in HIGH:
            why.append("either-reviewer-high+")
        if "must_fix" in (ra, rb) and {ra, rb} & {"defer", "nit"}:
            why.append("must_fix-vs-defer/nit")
        if not why:
            continue
        hits.append(
            f"[{'+'.join(why)}] {fa.get('id','?')}({sa}/{ra}) vs "
            f"{fb.get('id','?')}({sb}/{rb}) @ {fa.get('location','?')}")

LIMIT = ("this is location-matched only: differently-framed findings do not pair "
         "up here, so do the Step 4.1 scan either way.")

if hits:
    print("ESCALATION CANDIDATES (Step 4.4) — confirm each, do not auto-file:")
    for h in hits:
        print("  " + h)
    print(f"\nNot necessarily the full set — {LIMIT}")
    sys.exit(1)

print("no location-matched escalation candidates.")
print(f"NOT proof of agreement — {LIMIT}")
PY
