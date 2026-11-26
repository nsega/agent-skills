#!/usr/bin/env python3
"""check_report.py: check a dual-model review report before it is handed over.

Usage: check_report.py REPORT.md [R2_FINDINGS.json]

Fails (exit 1, one line per problem) when:
- a heading from SKILL.md's output template is missing, or
- a reviewer #2 id (R2-###) appears in neither a merged finding (the
  "Escalated", "Consensus findings" or "Single-reviewer findings" section) nor
  the "Not adopted" section. A mention anywhere else (Disposition, Residual
  risk) does not count: the finding was still not merged or dropped with a
  reason.

The ids to account for come from R2_FINDINGS.json (second_review.sh's output)
when it is given. Without it, only the R2 ids the report itself mentions are
checked, which cannot catch a finding the report never names.

Exit 0 when the report passes, 2 on a usage error or unreadable input.
Standard library only, so it runs anywhere python3 does.
"""
import json
import re
import sys

# (level, text the heading must contain, how to name it in a problem line),
# in template order. Matching is by substring, case-insensitive, so the emoji
# and the parenthetical in the template are optional.
TITLE = (1, "dual-model review", "# Dual-model review: <target>")
SECTIONS = [
    (2, "escalated to human", "## ⚠️ Escalated to human"),
    (2, "consensus findings", "## Consensus findings"),
    (2, "single-reviewer findings", "## Single-reviewer findings"),
    (2, "disposition", "## Disposition"),
    (2, "not adopted", "## Not adopted"),
    (2, "residual risk", "## Residual risk / for the human"),
]
MERGED = ("escalated to human", "consensus findings", "single-reviewer findings")
NOT_ADOPTED = "not adopted"

HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")
R2_ID = re.compile(r"\bR2-\d+\b")


def parse(text):
    """Return (headings, sections): every (level, text) heading outside code
    fences, and a map from each level-2 heading key in SECTIONS to the body
    under it (up to the next heading of level 1 or 2)."""
    headings, sections = [], {}
    current, in_fence = None, False
    for line in text.splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
        m = None if in_fence else HEADING.match(line)
        if m:
            level, title = len(m.group(1)), m.group(2)
            headings.append((level, title))
            if level <= 2:
                current = None
                if level == 2:
                    for _, key, _ in SECTIONS:
                        if key in title.lower():
                            current = key
                            sections.setdefault(key, [])
                            break
                continue
        if current is not None:
            sections[current].append(line)
    return headings, {k: "\n".join(v) for k, v in sections.items()}


def r2_ids_from(path):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    findings = doc.get("findings") if isinstance(doc, dict) else None
    if not isinstance(findings, list):
        raise ValueError("no findings array")
    ids = []
    for f in findings:
        fid = f.get("id") if isinstance(f, dict) else None
        if isinstance(fid, str) and R2_ID.fullmatch(fid) and fid not in ids:
            ids.append(fid)
    return ids


def check(report_path, findings_path=None):
    try:
        with open(report_path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        print(f"check_report.py: cannot read {report_path}: {e.strerror}", file=sys.stderr)
        return 2
    ids = None
    if findings_path:
        try:
            ids = r2_ids_from(findings_path)
        except (OSError, ValueError) as e:
            print(f"check_report.py: cannot read reviewer #2 findings from {findings_path}: {e}",
                  file=sys.stderr)
            return 2

    headings, sections = parse(text)
    problems = []
    for level, key, name in [TITLE] + SECTIONS:
        if not any(lv == level and key in t.lower() for lv, t in headings):
            problems.append(f"{report_path}: missing heading: {name}")

    if ids is None:                       # no findings file: what the report names
        ids = list(dict.fromkeys(R2_ID.findall(text)))
    accounted = set()
    for key in MERGED + (NOT_ADOPTED,):
        accounted.update(R2_ID.findall(sections.get(key, "")))
    for fid in ids:
        if fid not in accounted:
            problems.append(f'{report_path}: {fid} is in neither a merged finding nor "Not adopted"')

    for p in problems:
        print(p)
    if problems:
        return 1
    print(f"{report_path}: ok, all headings present, {len(ids)} reviewer #2 ids accounted for")
    return 0


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        print("usage: check_report.py REPORT.md [R2_FINDINGS.json]", file=sys.stderr)
        sys.exit(2)
    sys.exit(check(*sys.argv[1:]))
