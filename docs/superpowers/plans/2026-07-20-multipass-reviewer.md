# Multi-pass Reviewer #2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run reviewer #2 (GLM) as N independent passes and union their findings, scoring each finding by how many passes raised it, so a single failed or unlucky pass no longer sinks the review.

**Architecture:** A wrapper `glm_review_passes.sh` calls the existing, unchanged `glm_review.sh` N times into a private temp dir, retrying a pass that produces no JSON, then calls `aggregate_passes.py` to union the passes into one `glm-findings.json` with a `pass_count` per finding and a `passes_total` denominator. Singletons are never dropped; recurrence only ranks. Location clustering reuses a shared `norm()` helper so it cannot drift from `check_disagreements.sh`.

**Tech Stack:** bash, python3 with `jsonschema` (already a hard dependency), the existing offline `tests/run_tests.sh` harness.

## Global Constraints

- Skill root: `skills/cross-review/`. All paths below are relative to it unless absolute.
- No em-dashes in prose or comments (user rule). En-dashes in numeric ranges and `→` are fine.
- Commit messages follow Conventional Commits; end each with the two trailers used across this repo's history:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and the `Claude-Session:` line.
- `glm_review.sh` MUST NOT be modified. It is the hardened single-pass unit; this feature wraps it.
- Reviewer #2 only. Do not touch Claude's review path.
- Never drop a finding for low `pass_count`. Recurrence ranks, it never filters.
- Every task ends by running `bash tests/run_tests.sh` and showing it green before committing.
- `norm()` normalization must stay byte-identical between `check_disagreements.sh` and the aggregator (that is the point of the shared helper).

---

### Task 1: Shared findings library + refactor the checker onto it

**Files:**
- Create: `scripts/_findings_lib.py`
- Create: `tests/test_findings_lib.py`
- Modify: `scripts/check_disagreements.sh` (replace the inline `norm`/`load` with an import)
- Modify: `tests/run_tests.sh` (add a python-unit-test runner section)

**Interfaces:**
- Produces: `_findings_lib.norm(location: str|None) -> str` and `_findings_lib.load_findings(path: str) -> dict`. Later tasks (`aggregate_passes.py`) import both.

- [ ] **Step 1: Write the failing test**

Create `tests/test_findings_lib.py`:

```python
#!/usr/bin/env python3
"""Unit tests for _findings_lib. Runnable standalone: python3 tests/test_findings_lib.py"""
import json, os, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
from _findings_lib import norm, load_findings  # noqa: E402

def test_norm_strips_line_numbers_and_parens():
    assert norm("SKILL.md:106-109") == "skill.md"
    assert norm("scripts/glm_review.sh:119 (the echo)") == "scripts/glm_review.sh"
    assert norm("References/Rubric.md") == "references/rubric.md"

def test_norm_same_location_different_lines_matches():
    assert norm("scripts/glm_review.sh:119-120") == norm("scripts/glm_review.sh:120")

def test_norm_handles_none():
    assert norm(None) == ""

def test_load_findings_roundtrip():
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump({"findings": []}, fh); p = fh.name
    try:
        assert load_findings(p) == {"findings": []}
    finally:
        os.unlink(p)

if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn(); print(f"  ok   {fn.__name__}")
    print(f"{len(fns)} passed")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd skills/cross-review && python3 tests/test_findings_lib.py`
Expected: FAIL with `ModuleNotFoundError: No module named '_findings_lib'`

- [ ] **Step 3: Create the shared library**

Create `scripts/_findings_lib.py`:

```python
"""Shared helpers for cross-review finding tools.

Kept in one place so the location-normalization used by the disagreement checker
(check_disagreements.sh) and the multi-pass aggregator (aggregate_passes.py)
cannot drift apart. See the design spec under docs/superpowers/specs/.
"""
import json
import re


def norm(loc):
    """Normalize a location for matching: lowercase, drop line numbers and
    parenthetical asides, keep the file/section stem."""
    loc = (loc or "").lower().strip()
    loc = re.sub(r"\(.*?\)", "", loc)
    loc = re.sub(r"[:#]\s*l?\d+(\s*[-–]\s*\d+)?", "", loc)
    return re.sub(r"\s+", " ", loc).strip(" .,:;-")


def load_findings(path):
    """Load a findings document. Raises OSError / json.JSONDecodeError on failure."""
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd skills/cross-review && python3 tests/test_findings_lib.py`
Expected: PASS, `4 passed`

- [ ] **Step 5: Refactor check_disagreements.sh to import the shared norm/load**

In `scripts/check_disagreements.sh`, the inline python heredoc currently defines its own `load` and `norm`. Replace the top of that heredoc so it imports them instead. Change the invocation line from:

```bash
python3 - "$A" "$B" <<'PY'
import json, sys, re

def load(p):
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)

def norm(loc):
    """Normalize a location for matching: lowercase, drop line numbers and
    parenthetical asides, keep the file/section stem."""
    loc = (loc or "").lower().strip()
    loc = re.sub(r"\(.*?\)", "", loc)
    loc = re.sub(r"[:#]\s*l?\d+(\s*[-–]\s*\d+)?", "", loc)
    return re.sub(r"\s+", " ", loc).strip(" .,:;-")

try:
    a, b = load(sys.argv[1]), load(sys.argv[2])
```

to:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONPATH="$SCRIPT_DIR:${PYTHONPATH:-}" python3 - "$A" "$B" <<'PY'
import json, sys, re
from _findings_lib import norm, load_findings as load

try:
    a, b = load(sys.argv[1]), load(sys.argv[2])
```

(Leave the rest of the heredoc unchanged. `re` and `json` stay imported; the checker still uses `re` nowhere else, but keeping the import is harmless and avoids touching more lines. If a linter objects, drop `re`.)

- [ ] **Step 6: Wire python unit tests into the harness**

In `tests/run_tests.sh`, immediately before the line `echo "== scripts parse =="`, insert:

```bash
echo "== python unit tests =="
for t in "$DIR"/test_*.py; do
  [ -f "$t" ] || continue
  if python3 "$t" >/dev/null 2>&1; then ok "$(basename "$t")"; else bad "$(basename "$t") (run: python3 $t)"; fi
done
```

- [ ] **Step 7: Run the full suite**

Run: `cd skills/cross-review && bash tests/run_tests.sh`
Expected: PASS, all assertions ok including the new `test_findings_lib.py` line and the unchanged disagreement-checker tests (proving the refactor preserved behavior).

- [ ] **Step 8: Commit**

```bash
git add skills/cross-review/scripts/_findings_lib.py skills/cross-review/tests/test_findings_lib.py \
        skills/cross-review/scripts/check_disagreements.sh skills/cross-review/tests/run_tests.sh
git commit -m "refactor(cross-review): extract shared norm/load into _findings_lib

Prep for the multi-pass aggregator, which must cluster findings by the same
normalized location the disagreement checker uses. Extract norm() and the
loader into scripts/_findings_lib.py and import them from check_disagreements.sh
so the two cannot drift. Behavior is unchanged; the existing checker tests stay
green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XErHevPA1KaGGVDDYJNqTj"
```

---

### Task 2: Add optional `pass_count` and `passes_total` to the schema

**Files:**
- Modify: `references/findings.schema.json`
- Modify: `tests/run_tests.sh` (add two assertions in the `== schema ==` python block)

**Interfaces:**
- Produces: findings may carry optional `pass_count` (integer ≥ 1); the document may carry optional `passes_total` (integer ≥ 1). Task 3's aggregator writes both.

- [ ] **Step 1: Add the failing assertions**

In `tests/run_tests.sh`, inside the first python block (the one that ends `sys.exit(0 if all(results) else 1)`), add these two lines just before that `sys.exit`:

```python
d = json.loads(json.dumps(base)); d["passes_total"] = 3; d["findings"][0]["pass_count"] = 2
results.append(expect("pass_count + passes_total validate", d, True))

d = json.loads(json.dumps(base)); d["findings"][0]["pass_count"] = 0
results.append(expect("pass_count below 1 is rejected", d, False))
```

Then bump the pass counter for that block: change `if [ $? -eq 0 ]; then pass=$((pass+6)); else fail=$((fail+1)); fi` to `pass=$((pass+8))`.

- [ ] **Step 2: Run to verify it fails**

Run: `cd skills/cross-review && bash tests/run_tests.sh`
Expected: FAIL on the `pass_count + passes_total validate` assertion. The finding item and the document both have `additionalProperties: false`, so before the schema change these unknown fields are rejected and the "should validate → True" assertion fails. (The `pass_count below 1 is rejected` assertion passes even now, vacuously, since the unknown field is rejected for being unknown; it becomes meaningful once the field is declared with `minimum: 1`.) Confirm the run reports the failure before proceeding.

- [ ] **Step 3: Add the fields to the schema**

In `references/findings.schema.json`, the finding item has `"additionalProperties": false`, so `pass_count` must be declared. Add it right after the `recommendation` property block (after its closing `},`) and before `"speculative"`:

```json
          "pass_count": {
            "type": "integer",
            "minimum": 1,
            "description": "Multi-pass only: how many reviewer-#2 passes raised this finding (out of passes_total). Written by aggregate_passes.py, never by a single pass. A ranking/confidence signal, never a filter: a pass_count of 1 is still a real finding."
          },
```

The document object also has `"additionalProperties": false`, so add `passes_total` to the top-level `properties` (e.g. after the `overall` property block):

```json
    "passes_total": {
      "type": "integer",
      "minimum": 1,
      "description": "Multi-pass only: how many reviewer-#2 passes produced valid output and were aggregated. The honest denominator for pass_count. Absent on single-pass output."
    },
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd skills/cross-review && bash tests/run_tests.sh`
Expected: PASS. The two new assertions pass; every existing fixture still validates (they have no `pass_count`/`passes_total`, which is fine because both are optional).

- [ ] **Step 5: Commit**

```bash
git add skills/cross-review/references/findings.schema.json skills/cross-review/tests/run_tests.sh
git commit -m "feat(cross-review): add optional pass_count/passes_total to findings schema

Multi-pass aggregation needs to record how many passes raised each finding
(pass_count) and how many passes were aggregated (passes_total). Both are
optional and aggregator-written, so single-pass output and all existing
fixtures stay valid.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XErHevPA1KaGGVDDYJNqTj"
```

---

### Task 3: The aggregator

**Files:**
- Create: `scripts/aggregate_passes.py`
- Create: `tests/fixtures/pass-1.json`, `tests/fixtures/pass-2.json`, `tests/fixtures/pass-3.json`
- Create: `tests/test_aggregate.py`

**Interfaces:**
- Consumes: `_findings_lib.norm`, `_findings_lib.load_findings` (Task 1); optional schema fields (Task 2).
- Produces: CLI `aggregate_passes.py <passes_dir> <schema> <out_json>`. Reads `pass-*.json` in `passes_dir`, writes an aggregated findings doc to `out_json`, prints `out_json` on success, exits non-zero if no valid pass files. Task 4's wrapper calls it.

- [ ] **Step 1: Write the fixtures**

The three fixtures encode: one finding in all three passes (`src/a.py`), one in two (`src/b.py`), and two distinct singletons (`src/c.py`, `src/d.py`). Locations vary in line number to prove `norm()` clustering.

Create `tests/fixtures/pass-1.json`:

```json
{
  "reviewer": "glm-5.2",
  "summary": "pass 1",
  "overall": "request_changes",
  "findings": [
    {"id": "G-001", "severity": "high", "category": "correctness", "location": "src/a.py:10",
     "issue": "shared A", "evidence": "line 10", "failure_case": "x", "suggestion": "fix a",
     "confidence": "high", "recommendation": "must_fix"},
    {"id": "G-002", "severity": "medium", "category": "design", "location": "src/b.py:20",
     "issue": "shared B", "suggestion": "fix b", "confidence": "medium", "recommendation": "should_fix"},
    {"id": "G-003", "severity": "low", "category": "maintainability", "location": "src/c.py:30",
     "issue": "singleton C", "suggestion": "fix c", "confidence": "low", "recommendation": "nit"}
  ]
}
```

Create `tests/fixtures/pass-2.json`:

```json
{
  "reviewer": "glm-5.2",
  "summary": "pass 2",
  "overall": "approve_with_nits",
  "findings": [
    {"id": "G-001", "severity": "critical", "category": "correctness", "location": "src/a.py:10-12 (loop)",
     "issue": "shared A, seen as critical here", "evidence": "the whole loop at 10-12 is the proof and this is the longer evidence string",
     "failure_case": "x", "suggestion": "fix a harder", "confidence": "high", "recommendation": "must_fix"},
    {"id": "G-002", "severity": "medium", "category": "design", "location": "src/b.py:21",
     "issue": "shared B", "suggestion": "fix b", "confidence": "medium", "recommendation": "should_fix"},
    {"id": "G-004", "severity": "medium", "category": "testing", "location": "src/d.py:40",
     "issue": "singleton D", "suggestion": "fix d", "confidence": "medium", "recommendation": "should_fix"}
  ]
}
```

Create `tests/fixtures/pass-3.json`:

```json
{
  "reviewer": "glm-5.2",
  "summary": "pass 3",
  "overall": "approve",
  "findings": [
    {"id": "G-001", "severity": "high", "category": "correctness", "location": "src/a.py:11",
     "issue": "shared A again", "evidence": "line 11", "failure_case": "x", "suggestion": "fix a",
     "confidence": "high", "recommendation": "must_fix"}
  ]
}
```

- [ ] **Step 2: Write the failing test**

Create `tests/test_aggregate.py`:

```python
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
        doc = json.load(open(out))
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
        doc = json.load(open(out))
        a = next(f for f in doc["findings"] if f["location"].startswith("src/a.py"))
        assert a["severity"] == "critical"  # pass-2 raised it critical
    finally:
        shutil.rmtree(d)

def test_sorted_by_pass_count_then_severity():
    d = _stage("pass-1.json", "pass-2.json", "pass-3.json")
    try:
        _, out = run(d)
        doc = json.load(open(out))
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
        doc = json.load(open(out))
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

if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn(); print(f"  ok   {fn.__name__}")
    print(f"{len(fns)} passed")
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd skills/cross-review && python3 tests/test_aggregate.py`
Expected: FAIL, non-zero exit because `scripts/aggregate_passes.py` does not exist yet (the subprocess returns non-zero and the first assertion trips).

- [ ] **Step 4: Write the aggregator**

Create `scripts/aggregate_passes.py`:

```python
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
```

- [ ] **Step 5: Run the aggregator test to verify it passes**

Run: `cd skills/cross-review && python3 tests/test_aggregate.py`
Expected: PASS, `5 passed`.

- [ ] **Step 6: Run the full suite**

Run: `cd skills/cross-review && bash tests/run_tests.sh`
Expected: PASS. `test_aggregate.py` is picked up by the python-unit-test loop added in Task 1.

- [ ] **Step 7: Commit**

```bash
git add skills/cross-review/scripts/aggregate_passes.py skills/cross-review/tests/test_aggregate.py \
        skills/cross-review/tests/fixtures/pass-1.json skills/cross-review/tests/fixtures/pass-2.json \
        skills/cross-review/tests/fixtures/pass-3.json
git commit -m "feat(cross-review): add multi-pass aggregator

aggregate_passes.py unions reviewer-#2 passes clustered by normalized location,
scores each finding by pass_count, and never drops a singleton. Highest-severity
instance wins a cluster; output sorts by agreement then severity. Fixtures cover
the 3/2/1/1 case, highest-severity-wins, ordering, the degraded 2-of-3 case, and
the no-valid-passes failure.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XErHevPA1KaGGVDDYJNqTj"
```

---

### Task 4: The multi-pass wrapper

**Files:**
- Create: `scripts/glm_review_passes.sh`
- Modify: `tests/run_tests.sh` (add a `== multi-pass wrapper ==` section using a stub reviewer)

**Interfaces:**
- Consumes: `scripts/glm_review.sh` (overridable via `GLM_REVIEW_BIN` for tests), `scripts/aggregate_passes.py` (Task 3).
- Produces: CLI `glm_review_passes.sh <bundle> <rubric> <schema> <out_json> [N]`. Same first four args as `glm_review.sh`. Env: `GLM_PASSES` (default 3), `GLM_PASS_RETRIES` (default 1), `GLM_REVIEW_BIN`. Exits 2 on bad N, 3 if all passes fail.

- [ ] **Step 1: Write the failing tests (with a stub reviewer)**

In `tests/run_tests.sh`, immediately before `echo "== python unit tests =="` (added in Task 1), insert:

```bash
echo "== multi-pass wrapper =="
# A stub standing in for glm_review.sh, so the wrapper is testable with no network.
# It keys success/failure on the pass index parsed from the output path, so a
# retried pass keeps failing (a per-pass, not per-invocation, decision).
STUB="$TMP/stub_review.sh"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
b="$(basename "$4")"; i="${b#pass-}"; i="${i%.json}"
case " ${STUB_FAIL:-} " in *" $i "*) exit 1 ;; esac
cat > "$4" <<JSON
{"reviewer":"glm-5.2","summary":"stub pass $i","overall":"approve_with_nits",
 "findings":[{"id":"G-001","severity":"high","category":"correctness",
 "location":"src/x.py:1","issue":"stub","evidence":"e","failure_case":"f",
 "suggestion":"s","confidence":"high","recommendation":"must_fix"}]}
JSON
echo "$4"
SH
chmod +x "$STUB"
wrap() { GLM_REVIEW_BIN="$STUB" "$SKILL/scripts/glm_review_passes.sh" \
           "$EMPTY_OK" "$SCHEMA" "$SCHEMA" "$1" "${2:-}" 2>"$TMP/wrap.err"; }
# A non-empty bundle so glm_review_passes.sh input checks (if any) pass; the stub
# ignores its content.
EMPTY_OK="$TMP/bundle.md"; printf 'x' > "$EMPTY_OK"

# All passes succeed -> passes_total = 3, one clustered finding pass_count 3.
OUT="$TMP/agg-all.json"; STUB_FAIL="" wrap "$OUT" 3; check "3 passes: exit 0" "$?" "0"
python3 -c "
import json,sys;d=json.load(open('$OUT'))
sys.exit(0 if d.get('passes_total')==3 and d['findings'][0]['pass_count']==3 else 1)" \
  && ok "3 passes aggregate to passes_total=3, pass_count=3" || bad "3 passes aggregate to passes_total=3, pass_count=3"

# One pass fails all attempts -> skipped -> passes_total = 2, still exit 0.
OUT="$TMP/agg-degraded.json"; STUB_FAIL="2" wrap "$OUT" 3; check "one pass fails: exit 0" "$?" "0"
python3 -c "
import json,sys;d=json.load(open('$OUT'))
sys.exit(0 if d.get('passes_total')==2 else 1)" \
  && ok "failed pass drops passes_total to 2" || bad "failed pass drops passes_total to 2"

# All passes fail -> exit 3, no output file.
OUT="$TMP/agg-none.json"; rm -f "$OUT"; STUB_FAIL="1 2 3" wrap "$OUT" 3; check "all passes fail: exit 3" "$?" "3"
[ ! -f "$OUT" ] && ok "no output written when all passes fail" || bad "no output written when all passes fail"

# Bad N -> exit 2.
STUB_FAIL="" wrap "$TMP/agg-badN.json" "notanumber"; check "bad N: exit 2" "$?" "2"

# Summary line reports the success ratio.
STUB_FAIL="2" wrap "$TMP/agg-sum.json" 3
case "$(cat "$TMP/wrap.err")" in *"2/3 passes succeeded"*) ok "wrapper reports M/N passes";; *) bad "wrapper reports M/N passes";; esac
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd skills/cross-review && bash tests/run_tests.sh`
Expected: FAIL. The wrapper script does not exist, so `wrap` invocations return 127 and the `check` assertions report the wrong exit codes.

- [ ] **Step 3: Write the wrapper**

Create `scripts/glm_review_passes.sh`:

```bash
#!/usr/bin/env bash
# Reviewer #2 as N independent passes, unioned into one findings file.
#
# Drop-in for glm_review.sh: same first four args, plus an optional pass count.
# Each pass is a fresh glm_review.sh call (its own opencode session) into a
# private temp dir; a pass with no valid JSON is retried, then skipped. The
# passes are unioned by aggregate_passes.py, which scores each finding by how
# many passes raised it. A single flaky or unlucky pass no longer sinks a review.
#
# Usage:
#   glm_review_passes.sh <BUNDLE> <RUBRIC> <SCHEMA> <OUT_JSON> [N]
#
# Env:
#   GLM_PASSES        default pass count if [N] omitted   (default: 3)
#   GLM_PASS_RETRIES  extra attempts per failed pass       (default: 1)
#   GLM_REVIEW_BIN    single-pass reviewer to invoke       (default: <skill>/scripts/glm_review.sh)
#
# Passes run SERIALLY: concurrent opencode runs contend on a shared session DB
# (observed as "database is locked").
set -euo pipefail

BUNDLE="${1:?need bundle path}"
RUBRIC="${2:?need rubric path}"
SCHEMA="${3:?need schema path}"
OUT="${4:?need output json path}"
N="${5:-${GLM_PASSES:-3}}"
RETRIES="${GLM_PASS_RETRIES:-1}"

case "$N" in ''|*[!0-9]*) echo "bad N: '$N' (want a positive integer)" >&2; exit 2 ;; esac
[ "$N" -ge 1 ] || { echo "bad N: '$N' (must be >= 1)" >&2; exit 2; }

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLM_REVIEW_BIN="${GLM_REVIEW_BIN:-$SKILL_DIR/scripts/glm_review.sh}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
succeeded=0
for i in $(seq 1 "$N"); do
  attempt=0
  while :; do
    if "$GLM_REVIEW_BIN" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$WORK/pass-$i.json" \
         > "$WORK/pass-$i.out" 2> "$WORK/pass-$i.err"; then
      succeeded=$((succeeded + 1)); break
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$RETRIES" ]; then
      echo "pass $i failed after $((RETRIES + 1)) attempt(s); skipping" >&2
      rm -f "$WORK/pass-$i.json"   # ensure a partial file is not aggregated
      break
    fi
  done
done

echo "reviewer #2: $succeeded/$N passes succeeded" >&2
[ "$succeeded" -ge 1 ] || { echo "all $N passes failed; no review produced" >&2; exit 3; }

python3 "$SKILL_DIR/scripts/aggregate_passes.py" "$WORK" "$SCHEMA" "$OUT"
```

- [ ] **Step 4: Make it executable and run the tests**

Run:
```bash
cd skills/cross-review && chmod +x scripts/glm_review_passes.sh && bash tests/run_tests.sh
```
Expected: PASS, including every `== multi-pass wrapper ==` assertion.

- [ ] **Step 5: Commit**

```bash
git add skills/cross-review/scripts/glm_review_passes.sh skills/cross-review/tests/run_tests.sh
git commit -m "feat(cross-review): multi-pass wrapper for reviewer #2

glm_review_passes.sh runs glm_review.sh N times (default 3) into a private temp
dir, retries a pass that yields no JSON, skips one that never does, and hard-fails
only if all passes fail. It then calls aggregate_passes.py to union the passes.
Serial by design (concurrent opencode runs contend on a shared session DB), with
per-pass err logs. Tested offline via a GLM_REVIEW_BIN stub: full-success,
degraded 2-of-3, all-fail, and bad-N paths.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XErHevPA1KaGGVDDYJNqTj"
```

---

### Task 5: Wire multi-pass into the skill docs

**Files:**
- Modify: `SKILL.md` (Step 3 invocation, Step 4 pass_count guidance, Files list)
- Modify: `cross-review-playbook.md` (reviewer-#2 note)
- Modify: `README.md` (direct-drive example + Files list if present)

**Interfaces:**
- Consumes: the wrapper CLI from Task 4. No new code; documentation must match the shipped behavior.

- [ ] **Step 1: Update SKILL.md Step 3 invocation**

In `SKILL.md`, replace the Step 3 code block:

```bash
scripts/glm_review.sh <packet> references/rubric.md \
  references/findings.schema.json /tmp/glm-findings.json
```

with:

```bash
scripts/glm_review_passes.sh <packet> references/rubric.md \
  references/findings.schema.json /tmp/glm-findings.json 3
```

and replace the sentence that follows it (`GLM runs at max effort; the script echoes it to stderr. ...`) with:

```markdown
Reviewer #2 runs **3 independent passes** (override with a trailing count or
`GLM_PASSES`), unioned into one `glm-findings.json`. Each finding carries
`pass_count` out of `passes_total`. GLM runs at max effort; the wrapper echoes
`<M>/<N> passes succeeded` to stderr. To re-run the effort experiment set
`ZEN_VARIANT=high`.
```

- [ ] **Step 2: Update SKILL.md Step 4 to use pass_count**

In `SKILL.md` Step 4, in the ordered list, change item 3 (`**Order** by ...`) to append a sentence:

```markdown
3. **Order** by `severity × confidence` (`high × high` first). Never filter on
   confidence — a `low confidence × high severity` item still reaches a human.
   For GLM findings also weigh `pass_count / passes_total`: high agreement raises
   priority, but a `1/3` finding is **not** filtered — it escalates on its own
   merits exactly as a single-pass finding would.
```

- [ ] **Step 3: Update the report template annotation**

In `SKILL.md`, in the output template, change the single-reviewer GLM finding line so a GLM finding shows its agreement. Find the `## Single-reviewer findings` example line and add ` (GLM <pass_count>/<passes_total>)` guidance right under that heading:

```markdown
## Single-reviewer findings
<!-- For a GLM finding, append its agreement, e.g. "(GLM 1/3)". -->
```

- [ ] **Step 4: Update SKILL.md Files list**

In `SKILL.md`, under the `## Files` section, after the `scripts/glm_review.sh` line, add:

```markdown
- `scripts/glm_review_passes.sh` — reviewer #2 as N passes, unioned (wraps `glm_review.sh`).
- `scripts/aggregate_passes.py` — union passes by location, score by `pass_count`.
- `scripts/_findings_lib.py` — shared `norm()`/`load_findings` for the checker + aggregator.
```

- [ ] **Step 5: Update the playbook**

In `cross-review-playbook.md`, in section B item 3 (the GLM-5.2 role bullet), append one sentence:

```markdown
Reviewer #2 runs as N independent passes (default 3) unioned by location; a finding's `pass_count` is agreement across passes, a ranking signal only, never a gate (real findings rarely recur, so singletons are kept).
```

- [ ] **Step 6: Update README direct-drive example**

In `README.md`, in the "Or drive the sub-reviewer directly" block, replace the `glm_review.sh` line with the multi-pass wrapper:

```bash
B=$(scripts/gather_artifact.sh pr origin/main)
scripts/glm_review_passes.sh "$B" references/rubric.md references/findings.schema.json /tmp/glm.json 3
scripts/check_disagreements.sh /tmp/claude.json /tmp/glm.json   # exits 1 if any pair escalates
```

- [ ] **Step 7: Verify docs are consistent and tests still pass**

Run:
```bash
cd skills/cross-review
grep -rn "glm_review_passes\|pass_count\|passes_total" SKILL.md cross-review-playbook.md README.md
bash tests/run_tests.sh
```
Expected: the grep shows the new references present in all three docs; the suite is fully green.

- [ ] **Step 8: Commit**

```bash
git add skills/cross-review/SKILL.md skills/cross-review/cross-review-playbook.md skills/cross-review/README.md
git commit -m "docs(cross-review): wire multi-pass reviewer #2 into the skill

Step 3 now calls glm_review_passes.sh (3 passes -> one aggregated
glm-findings.json). Step 4 uses pass_count/passes_total as a ranking signal
while stating plainly it is not a gate: a 1/3 finding escalates on its own
merits. Playbook, README, and the Files list updated to match.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XErHevPA1KaGGVDDYJNqTj"
```

---

## Self-Review

**Spec coverage:**
- Recall-then-adjudicate (union, never drop, score) → Task 3 aggregator + Task 5 Step 2/3.
- Reviewer #2 only → no task touches Claude's path.
- `glm_review.sh` unchanged → Global Constraints + Task 4 wraps it via `GLM_REVIEW_BIN`.
- N passes, default 3, override → Task 4 (`N`, `GLM_PASSES`).
- Retry / skip / exit-3 on all-fail → Task 4 wrapper + wrapper tests.
- Cluster by shared `norm()` → Task 1 (shared lib + checker refactor) consumed in Task 3.
- Schema `pass_count` + `passes_total`, optional → Task 2.
- Serial passes + per-pass err logs → Task 4 wrapper.
- Offline tests incl. degraded 2-of-3 → Task 3 `test_aggregate.py` + Task 4 wrapper tests.
- Docs (SKILL Step 3/4, playbook, README) → Task 5.

**Placeholder scan:** No TBD/TODO. Every code and test step shows complete content. Every command has an expected result.

**Type consistency:** `norm()` and `load_findings` defined in Task 1, imported unchanged in Task 3. Aggregator CLI `aggregate_passes.py <passes_dir> <schema> <out_json>` defined in Task 3 and called with those exact args in Task 4. Wrapper CLI and env (`GLM_PASSES`, `GLM_PASS_RETRIES`, `GLM_REVIEW_BIN`) defined in Task 4 and matched in Task 5's docs. Schema fields `pass_count`/`passes_total` named identically across Tasks 2, 3, and 5.
