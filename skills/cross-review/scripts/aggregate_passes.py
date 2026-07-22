#!/usr/bin/env python3
"""Aggregate N reviewer-#2 passes into one findings document.

Union of all findings, clustered by (exact location, normalized issue text). Two
findings merge only when BOTH signals match, so distinct issues at one location
never collapse and are never paired by position; a finding is NEVER dropped.
Recurrence becomes a `pass_count` score and the sort order. Reworded restatements
under-count agreement rather than risk a wrong merge. Motivated by the measured
zero-overlap variance between passes. See the design spec under docs/superpowers/.

Usage: aggregate_passes.py <passes_dir> <schema> <out_json>
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _findings_lib import loc_key, issue_norm, load_findings  # noqa: E402

try:
    import jsonschema
except ImportError:
    sys.exit("aggregate: jsonschema not installed; the findings contract cannot "
             "be enforced. Run: pip install jsonschema")

SEV_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3}
REC_ORDER = {"must_fix": 0, "should_fix": 1, "defer": 2, "nit": 3}
OVERALL_ORDER = ["approve", "approve_with_nits", "request_changes", "block"]


def _pass_num(name):
    """Numeric index of a pass file name, or -1 if it is not one. Used to sort
    numerically (pass-2 before pass-10), not lexically."""
    m = re.match(r"pass-(\d+)\.json$", name)
    return int(m.group(1)) if m else -1


def valid_passes(passes_dir, schema):
    if not os.path.isdir(passes_dir):
        sys.exit(f"aggregate: not a directory: {passes_dir}")
    docs = []
    for name in sorted(os.listdir(passes_dir), key=_pass_num):
        if _pass_num(name) < 0:
            continue
        path = os.path.join(passes_dir, name)
        try:
            doc = load_findings(path)
        except (OSError, json.JSONDecodeError) as ex:
            sys.stderr.write(f"aggregate: skipping {name}: {ex}\n")
            continue
        try:
            jsonschema.validate(doc, schema)
        except jsonschema.ValidationError as ex:
            where = "/".join(str(p) for p in ex.absolute_path) or "<root>"
            sys.stderr.write(f"aggregate: skipping {name}: schema violation at {where}: {ex.message}\n")
            continue
        docs.append(doc)
    return docs


def overall_tally(docs):
    """Worst overall across passes, and how many passes voted for it."""
    idx = max(OVERALL_ORDER.index(d.get("overall", "approve")) for d in docs)
    worst = OVERALL_ORDER[idx]
    votes = sum(1 for d in docs if d.get("overall", "approve") == worst)
    return worst, votes


def aggregate(docs):
    clusters, order = {}, []
    for i, doc in enumerate(docs):
        for f in doc.get("findings", []):
            key = (loc_key(f.get("location")), issue_norm(f.get("issue")))
            if key not in clusters:
                clusters[key] = []
                order.append(key)
            clusters[key].append((i, f))
    merged = []
    for key in order:
        group = clusters[key]
        findings = [f for _, f in group]
        # Highest severity wins the surfaced text; tie -> longest evidence.
        best = min(findings, key=lambda f: (SEV_ORDER.get(f.get("severity"), 9),
                                            -len(f.get("evidence") or "")))
        out = dict(best)
        # Recommendation drives Step 4 escalation, so take the STRONGEST call in
        # the cluster, not the wordiest instance's, so a must_fix is never hidden.
        out["recommendation"] = min((f.get("recommendation") for f in findings),
                                    key=lambda r: REC_ORDER.get(r, 9))
        out["pass_count"] = len({i for i, _ in group})   # DISTINCT passes, never > passes_total
        merged.append(out)
    merged.sort(key=lambda f: (-f["pass_count"], SEV_ORDER.get(f.get("severity"), 9)))
    # Each pass numbers findings from G-001 independently, so cluster winners can
    # collide; renumber to keep ids unique and stable within this review.
    for n, f in enumerate(merged, 1):
        f["id"] = f"G-{n:03d}"
    return merged


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: aggregate_passes.py <passes_dir> <schema> <out_json>")
    passes_dir, schema_path, out_json = sys.argv[1], sys.argv[2], sys.argv[3]
    schema = load_findings(schema_path)
    try:
        jsonschema.Draft7Validator.check_schema(schema)
    except jsonschema.SchemaError as ex:
        sys.exit(f"aggregate: the schema file itself is invalid: {ex.message}")
    docs = valid_passes(passes_dir, schema)
    if not docs:
        sys.exit("aggregate: no valid pass files to aggregate")
    findings = aggregate(docs)
    worst, votes = overall_tally(docs)
    result = {
        "reviewer": docs[0].get("reviewer", "glm-5.2"),
        "summary": (f"Aggregated {len(docs)} reviewer-#2 pass(es); "
                    f"{len(findings)} finding(s) by (location, issue). "
                    f"pass_count is agreement across passes, not a filter. "
                    f"overall {worst} from {votes}/{len(docs)} pass(es)."),
        "overall": worst,
        "passes_total": len(docs),
        "findings": findings,
    }
    try:
        jsonschema.validate(result, schema)
    except jsonschema.ValidationError as ex:
        where = "/".join(str(p) for p in ex.absolute_path) or "<root>"
        sys.exit(f"aggregate: assembled result violates the schema at {where}: {ex.message}")
    with open(out_json, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2, ensure_ascii=False)
    print(out_json)


if __name__ == "__main__":
    main()
