#!/usr/bin/env python3
"""Unit tests for aggregate_passes.py. Standalone: python3 tests/test_aggregate.py"""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.join(HERE, "..")
AGG = os.path.join(SKILL, "scripts", "aggregate_passes.py")
SCHEMA = os.path.join(SKILL, "references", "findings.schema.json")
FIX = os.path.join(HERE, "fixtures")

def run(passes_dir):
    out = os.path.join(passes_dir, "agg.json")
    r = subprocess.run([sys.executable, AGG, passes_dir, SCHEMA, out],
                       capture_output=True, text=True)
    return r, out

def _stage(*names):
    d = tempfile.mkdtemp()
    for i, n in enumerate(names, 1):
        shutil.copy(os.path.join(FIX, n), os.path.join(d, f"pass-{i}.json"))
    return d

def test_union_scores_and_never_drops_singletons():
    d = _stage("pass-1.json", "pass-2.json", "pass-3.json")
    try:
        r, out = run(d)
        assert r.returncode == 0, r.stderr
        doc = json.load(open(out, encoding="utf-8"))
        assert doc["passes_total"] == 3
        by_loc = {}
        for f in doc["findings"]:
            key = f["location"].split(":")[0]
            by_loc[key] = f["pass_count"]
        assert by_loc["src/a.py"] == 3
        assert by_loc["src/b.py"] == 2
        assert by_loc["src/c.py"] == 1
        assert by_loc["src/d.py"] == 1
        assert len(doc["findings"]) == 4
    finally:
        shutil.rmtree(d)

def test_highest_severity_instance_wins_cluster():
    d = _stage("pass-1.json", "pass-2.json", "pass-3.json")
    try:
        _, out = run(d)
        doc = json.load(open(out, encoding="utf-8"))
        a = next(f for f in doc["findings"] if f["location"].startswith("src/a.py"))
        assert a["severity"] == "critical"  # pass-2 raised it critical
    finally:
        shutil.rmtree(d)

def test_sorted_by_pass_count_then_severity():
    d = _stage("pass-1.json", "pass-2.json", "pass-3.json")
    try:
        _, out = run(d)
        doc = json.load(open(out, encoding="utf-8"))
        counts = [f["pass_count"] for f in doc["findings"]]
        assert counts == sorted(counts, reverse=True)
        assert doc["findings"][0]["location"].startswith("src/a.py")  # 3/3 first
    finally:
        shutil.rmtree(d)

def test_degraded_two_of_three():
    d = _stage("pass-1.json", "pass-2.json")  # only two passes present
    try:
        r, out = run(d)
        assert r.returncode == 0, r.stderr
        doc = json.load(open(out, encoding="utf-8"))
        assert doc["passes_total"] == 2
        a = next(f for f in doc["findings"] if f["location"].startswith("src/a.py"))
        assert a["pass_count"] == 2
    finally:
        shutil.rmtree(d)

def test_no_valid_passes_fails():
    d = tempfile.mkdtemp()
    try:
        r, _ = run(d)
        assert r.returncode != 0
    finally:
        shutil.rmtree(d)

def test_evidence_length_breaks_severity_tie():
    d = _stage("pass-1.json", "pass-2.json", "pass-3.json")
    try:
        _, out = run(d)
        doc = json.load(open(out, encoding="utf-8"))
        b = next(f for f in doc["findings"] if f["location"].startswith("src/b.py"))
        # Both pass-1 and pass-2 findings for src/b.py are medium severity.
        # pass-2 has longer evidence, so it should win the cluster.
        assert b["evidence"] == "this is the much longer evidence string that should win the tie"
    finally:
        shutil.rmtree(d)

def test_singletons_sort_by_severity():
    d = _stage("pass-1.json", "pass-2.json", "pass-3.json")
    try:
        _, out = run(d)
        doc = json.load(open(out, encoding="utf-8"))
        # Find singletons (pass_count == 1)
        singletons = [f for f in doc["findings"] if f["pass_count"] == 1]
        assert len(singletons) == 2
        # src/d.py is medium, src/c.py is low; medium should sort first
        assert singletons[0]["location"].startswith("src/d.py")
        assert singletons[1]["location"].startswith("src/c.py")
    finally:
        shutil.rmtree(d)

def test_distinct_same_file_findings_both_survive():
    d = tempfile.mkdtemp()
    try:
        shutil.copy(os.path.join(FIX, "pass-samefile.json"), os.path.join(d, "pass-1.json"))
        r, out = run(d)
        assert r.returncode == 0, r.stderr
        doc = json.load(open(out, encoding="utf-8"))
        assert doc["passes_total"] == 1
        locs = sorted(f["location"] for f in doc["findings"])
        assert locs == ["src/e.py:10", "src/e.py:200"], locs  # neither dropped
    finally:
        shutil.rmtree(d)

def test_pass_count_never_exceeds_passes_total():
    d = _stage("pass-1.json", "pass-2.json", "pass-3.json")
    try:
        _, out = run(d)
        doc = json.load(open(out, encoding="utf-8"))
        for f in doc["findings"]:
            assert f["pass_count"] <= doc["passes_total"], f
    finally:
        shutil.rmtree(d)

def test_distinct_findings_at_same_location_both_survive():
    # Two different issues one pass raises at the exact same location (they only
    # differ by a parenthetical loc_key strips) must NOT collapse into one.
    d = tempfile.mkdtemp()
    try:
        shutil.copy(os.path.join(FIX, "pass-samelocation.json"), os.path.join(d, "pass-1.json"))
        r, out = run(d)
        assert r.returncode == 0, r.stderr
        doc = json.load(open(out, encoding="utf-8"))
        assert len(doc["findings"]) == 2, doc["findings"]  # neither dropped
        issues = sorted(f["issue"] for f in doc["findings"])
        assert issues == ["the read path mishandles empty input",
                          "the write path double-frees on error"], issues
        for f in doc["findings"]:
            assert f["pass_count"] == 1
    finally:
        shutil.rmtree(d)

def test_ids_are_unique_and_renumbered():
    d = _stage("pass-1.json", "pass-2.json", "pass-3.json")
    try:
        _, out = run(d)
        doc = json.load(open(out, encoding="utf-8"))
        ids = [f["id"] for f in doc["findings"]]
        assert len(ids) == len(set(ids)), ids           # no duplicate ids
        assert ids == [f"G-{n:03d}" for n in range(1, len(ids) + 1)], ids  # sequential in output order
    finally:
        shutil.rmtree(d)

def test_same_id_across_passes_does_not_collide():
    # Each pass numbers from G-001; two singletons that both arrive as G-001 from
    # different passes must end up with distinct ids in the aggregate.
    d = tempfile.mkdtemp()
    try:
        with open(os.path.join(d, "pass-1.json"), "w", encoding="utf-8") as fh:
            json.dump({"reviewer": "glm-5.2", "summary": "p1", "overall": "approve",
                       "findings": [{"id": "G-001", "severity": "high", "category": "correctness",
                                     "location": "src/a.py:5", "issue": "A", "evidence": "e",
                                     "failure_case": "f", "suggestion": "s", "confidence": "high",
                                     "recommendation": "must_fix"}]}, fh)
        with open(os.path.join(d, "pass-2.json"), "w", encoding="utf-8") as fh:
            json.dump({"reviewer": "glm-5.2", "summary": "p2", "overall": "approve",
                       "findings": [{"id": "G-001", "severity": "high", "category": "correctness",
                                     "location": "src/b.py:9", "issue": "B", "evidence": "e",
                                     "failure_case": "f", "suggestion": "s", "confidence": "high",
                                     "recommendation": "must_fix"}]}, fh)
        _, out = run(d)
        doc = json.load(open(out, encoding="utf-8"))
        ids = [f["id"] for f in doc["findings"]]
        assert len(ids) == len(set(ids)) == 2, ids
    finally:
        shutil.rmtree(d)

def _pass(*findings, overall="approve"):
    return {"reviewer": "glm-5.2", "summary": "p", "overall": overall, "findings": list(findings)}

def _f(loc, issue, sev="high", rec="must_fix", ev="e"):
    return {"id": "G-001", "severity": sev, "category": "correctness", "location": loc,
            "issue": issue, "evidence": ev, "failure_case": "f", "suggestion": "s",
            "confidence": "high", "recommendation": rec}

def test_swapped_order_across_passes_never_drops():
    # Two passes each report the SAME two distinct issues at one location, in
    # opposite order. Content keying must keep both (the occurrence-index scheme
    # dropped one by pairing on position).
    d = tempfile.mkdtemp()
    try:
        a = _f("src/f.py:5", "missing null check on read", ev="longer-evidence-a")
        b = _f("src/f.py:5", "resource leak on write", ev="short")
        json.dump(_pass(a, b), open(os.path.join(d, "pass-1.json"), "w", encoding="utf-8"))
        json.dump(_pass(b, a), open(os.path.join(d, "pass-2.json"), "w", encoding="utf-8"))  # swapped
        _, out = run(d)
        doc = json.load(open(out, encoding="utf-8"))
        issues = sorted(f["issue"] for f in doc["findings"])
        assert issues == ["missing null check on read", "resource leak on write"], issues
        for f in doc["findings"]:
            assert f["pass_count"] == 2, f  # both raised by both passes
    finally:
        shutil.rmtree(d)

def test_merge_takes_strongest_recommendation():
    # Same finding across two passes with different recommendations: the merged
    # finding must carry the STRONGEST (must_fix), never a weaker call hidden
    # behind a wordier instance.
    d = tempfile.mkdtemp()
    try:
        strong = _f("src/y.py:7", "race condition", rec="must_fix", ev="short")
        weak = _f("src/y.py:7", "race condition", rec="nit", ev="a much longer evidence string")
        json.dump(_pass(strong), open(os.path.join(d, "pass-1.json"), "w", encoding="utf-8"))
        json.dump(_pass(weak), open(os.path.join(d, "pass-2.json"), "w", encoding="utf-8"))
        _, out = run(d)
        doc = json.load(open(out, encoding="utf-8"))
        assert len(doc["findings"]) == 1, doc["findings"]
        assert doc["findings"][0]["recommendation"] == "must_fix"
        assert doc["findings"][0]["pass_count"] == 2
    finally:
        shutil.rmtree(d)

if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn(); print(f"  ok   {fn.__name__}")
    print(f"{len(fns)} passed")
