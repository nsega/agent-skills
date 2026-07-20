#!/usr/bin/env python3
"""Aggregate N reviewer-#2 passes into one findings document.

Union of all findings, clustered by normalized location. A finding is NEVER
dropped for appearing in only one pass; recurrence becomes a `pass_count` score
and the sort order. Motivated by the measured zero-overlap variance between
passes. See docs/superpowers/specs/2026-07-20-glm-multipass-review-design.md.

Usage: aggregate_passes.py <passes_dir> <schema> <out_json>
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _findings_lib import norm, load_findings  # noqa: E402

SEV_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3}
OVERALL_ORDER = ["approve", "approve_with_nits", "request_changes", "block"]


def valid_passes(passes_dir, schema):
    import jsonschema
    docs = []
    for name in sorted(os.listdir(passes_dir)):
        if not (name.startswith("pass-") and name.endswith(".json")):
            continue
        path = os.path.join(passes_dir, name)
        try:
            doc = load_findings(path)
            jsonschema.validate(doc, schema)
        except Exception as ex:  # unreadable, bad JSON, or schema-invalid
            sys.stderr.write(f"aggregate: skipping {name}: {ex}\n")
            continue
        docs.append(doc)
    return docs


def worst_overall(docs):
    worst = 0
    for d in docs:
        worst = max(worst, OVERALL_ORDER.index(d.get("overall", "approve")))
    return OVERALL_ORDER[worst]


def aggregate(docs):
    clusters, order = {}, []
    for doc in docs:
        for f in doc.get("findings", []):
            key = norm(f.get("location"))
            if key not in clusters:
                clusters[key] = []
                order.append(key)
            clusters[key].append(f)
    merged = []
    for key in order:
        group = clusters[key]
        # highest severity wins; tie -> longest evidence
        best = min(group, key=lambda f: (SEV_ORDER.get(f.get("severity"), 9),
                                         -len(f.get("evidence") or "")))
        out = dict(best)
        out["pass_count"] = len(group)
        merged.append(out)
    merged.sort(key=lambda f: (-f["pass_count"], SEV_ORDER.get(f.get("severity"), 9)))
    return merged


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: aggregate_passes.py <passes_dir> <schema> <out_json>")
    passes_dir, schema_path, out_json = sys.argv[1], sys.argv[2], sys.argv[3]
    schema = load_findings(schema_path)
    docs = valid_passes(passes_dir, schema)
    if not docs:
        sys.exit("aggregate: no valid pass files to aggregate")
    findings = aggregate(docs)
    result = {
        "reviewer": docs[0].get("reviewer", "glm-5.2"),
        "summary": (f"Aggregated {len(docs)} reviewer-#2 pass(es); "
                    f"{len(findings)} unique finding(s) by location. "
                    f"pass_count is agreement across passes, not a filter."),
        "overall": worst_overall(docs),
        "passes_total": len(docs),
        "findings": findings,
    }
    import jsonschema
    jsonschema.validate(result, schema)
    with open(out_json, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2, ensure_ascii=False)
    print(out_json)


if __name__ == "__main__":
    main()
