#!/usr/bin/env bash
# Regression tests for the findings contract and the disagreement checker.
#
# The behavior this skill exists to produce — a reviewer disagreement reaching a
# human — is otherwise only ever exercised by a live paid model run, and only
# when the two reviewers happen to disagree. These tests pin it with fixtures so
# an edit to the schema, the prompt, or the checker cannot silently re-break it.
#
# Usage: tests/run_tests.sh      (no network, no API key, no cost)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$DIR/.." && pwd)"
FIX="$DIR/fixtures"
SCHEMA="$SKILL/references/findings.schema.json"
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

echo "== schema =="
python3 - "$SCHEMA" <<'PY' && ok "schema is valid draft-07" || bad "schema is valid draft-07"
import json,sys,jsonschema
jsonschema.Draft7Validator.check_schema(json.load(open(sys.argv[1])))
PY

SCHEMA_OUT="$(python3 - "$SCHEMA" "$FIX" <<'PY'
import json, sys, jsonschema
schema = json.load(open(sys.argv[1]))
v = jsonschema.Draft7Validator(schema)
base = json.load(open(sys.argv[2] + "/claude-disagree.json"))

def expect(name, doc, want_valid):
    got = v.is_valid(doc)
    print(f"  {'ok  ' if got == want_valid else 'FAIL'} {name}")
    return got == want_valid

results = []
results.append(expect("fixtures validate", base, True))

d = json.loads(json.dumps(base)); del d["findings"][0]["recommendation"]
results.append(expect("missing recommendation is rejected", d, False))

d = json.loads(json.dumps(base)); d["findings"][0]["recommendation"] = "reject"
results.append(expect("recommendation=reject is rejected", d, False))

d = json.loads(json.dumps(base)); del d["findings"][0]["evidence"]
results.append(expect("high finding without evidence is rejected", d, False))

d = json.loads(json.dumps(base)); del d["findings"][0]["failure_case"]
results.append(expect("high finding without failure_case is rejected", d, False))

d = json.loads(json.dumps(base)); d["findings"] = []
results.append(expect("empty findings array is valid", d, True))

d = json.loads(json.dumps(base)); d["passes_total"] = 3; d["findings"][0]["pass_count"] = 2
results.append(expect("pass_count + passes_total validate", d, True))

d = json.loads(json.dumps(base)); d["findings"][0]["pass_count"] = 0
results.append(expect("pass_count below 1 is rejected", d, False))

print(f"SCHEMA_COUNTS {sum(1 for r in results if r)} {sum(1 for r in results if not r)}")
PY
)"
printf '%s\n' "$SCHEMA_OUT" | grep -v '^SCHEMA_COUNTS '
sp=$(printf '%s\n' "$SCHEMA_OUT" | sed -n 's/^SCHEMA_COUNTS \([0-9]*\) .*/\1/p')
sf=$(printf '%s\n' "$SCHEMA_OUT" | sed -n 's/^SCHEMA_COUNTS [0-9]* \([0-9]*\)/\1/p')
pass=$((pass + ${sp:-0})); fail=$((fail + ${sf:-0}))
[ -n "$sp" ] || { echo "  FAIL schema block did not run to completion" >&2; fail=$((fail + 1)); }

echo "== disagreement checker =="
OUT="$("$SKILL/scripts/check_disagreements.sh" "$FIX/claude-disagree.json" "$FIX/glm-disagree.json" 2>&1)"; RC=$?
check "planted disagreement exits 1" "$RC" "1"
case "$OUT" in *"C-001"*) ok "planted pair is reported";; *) bad "planted pair is reported";; esac
case "$OUT" in *"either-reviewer-high+"*) ok "fires on either-reviewer high+ (C high, G medium)";; *) bad "fires on either-reviewer high+";; esac
case "$OUT" in *"must_fix-vs-defer/nit"*) ok "fires on must_fix vs defer";; *) bad "fires on must_fix vs defer";; esac
case "$OUT" in *"C-002"*) bad "control pair must NOT be reported";; *) ok "control pair is not reported";; esac
case "$OUT" in *"location-matched"*|*"do the Step 4.1 scan"*) ok "output states its matching limit";; *) bad "output states its matching limit";; esac

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 -c "
import json,sys
d=json.load(open('$FIX/glm-disagree.json'))
del d['findings'][0]['recommendation']
json.dump(d,open('$TMP/no-rec.json','w'))
"
OUT2="$("$SKILL/scripts/check_disagreements.sh" "$FIX/claude-disagree.json" "$TMP/no-rec.json" 2>&1)"; RC2=$?
check "missing recommendation still escalates" "$RC2" "1"
case "$OUT2" in *missing-recommendation*) ok "missing recommendation is named as the reason";; *) bad "missing recommendation is named as the reason";; esac

python3 -c "
import json
a=json.load(open('$FIX/claude-disagree.json'))
a['findings']=[f for f in a['findings'] if f['id']=='C-002']
json.dump(a,open('$TMP/agree.json','w'))
"
OUT3="$("$SKILL/scripts/check_disagreements.sh" "$TMP/agree.json" "$FIX/glm-disagree.json" 2>&1)"; RC3=$?
check "full agreement exits 0" "$RC3" "0"

echo "== effort / input validation =="
# Effort is always max (the lite/full tier no longer routes it). opencode accepts
# an unknown --variant silently, so ZEN_VARIANT is validated in-script. Input
# checks must precede any network call, so a bad invocation never costs money.
gr() { "$SKILL/scripts/glm_review.sh" "$@" 2>&1; }

OUT="$(ZEN_VARIANT=turbo gr /nonexistent-bundle "$SCHEMA" "$SCHEMA" /dev/null)"
check "unknown ZEN_VARIANT is rejected" "$?" "2"
case "$OUT" in *"want minimal|low|high|max"*) ok "bad ZEN_VARIANT names the valid values";; *) bad "bad ZEN_VARIANT names the valid values";; esac

# A missing bundle must fail on the input check (exit 2, "no such file"), proving
# validation runs before opencode; if it did not, this would hang on a live call.
OUT="$(gr /nonexistent-bundle "$SCHEMA" "$SCHEMA" /dev/null)"
case "$OUT" in
  *"no such file"*) ok "missing bundle fails on the input check, before any spend";;
  *) bad "missing bundle: unexpected output '$OUT'";;
esac

# Empty bundle: use a real empty file so the -s check is actually the one reached
# (a char device like /dev/null would trip the earlier -f check instead).
EMPTY="$TMP/empty.md"; : > "$EMPTY"
OUT="$(gr "$EMPTY" "$SCHEMA" "$SCHEMA" /dev/null)"; check "empty bundle exits 2" "$?" "2"
case "$OUT" in *"bundle is empty"*) ok "empty bundle is refused by the -s check";; *) bad "empty bundle is refused by the -s check (got '$OUT')";; esac

grep -q 'ZEN_VARIANT:-max' "$SKILL/scripts/glm_review.sh" && ok "effort defaults to max" || bad "effort defaults to max"
grep -q 'TIER_VARIANT\|bad tier' "$SKILL/scripts/glm_review.sh" && bad "tier->effort routing is fully removed" || ok "tier->effort routing is fully removed"
grep -q -- '--variant' "$SKILL/scripts/glm_review.sh" && ok "effort is passed per-run via --variant" || bad "effort is passed per-run via --variant"
# Check the PARSED config, not the raw text: the file explains in a comment why
# the key is absent, and a plain grep would match that explanation.
python3 - "$SKILL/config/opencode.zen.json" <<'PY' && ok "config does not pin effort (two sources of truth)" || bad "config does not pin effort (two sources of truth)"
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
cfg = json.loads(re.sub(r"^\s*//.*$", "", raw, flags=re.M))   # strip JSONC comments
def walk(node):
    if isinstance(node, dict):
        return any(k == "reasoningEffort" or walk(v) for k, v in node.items())
    if isinstance(node, list):
        return any(walk(v) for v in node)
    return False
sys.exit(1 if walk(cfg) else 0)
PY

echo "== reviewer is blind and tool-less =="
# The sub-reviewer must answer from the piped bundle only. If file/exec tools are
# enabled it reads the working tree (breaking blindness) and burns its run
# exploring instead of emitting findings JSON (observed: a paid call that produced
# only narration). Pin that the hardened config disables every such tool.
python3 - "$SKILL/config/opencode.zen.json" <<'PY' && ok "hardened config disables file/exec tools" || bad "hardened config disables file/exec tools"
import json, re, sys
cfg = json.loads(re.sub(r"^\s*//.*$", "", open(sys.argv[1], encoding="utf-8").read(), flags=re.M))
must_be_off = {"read","grep","glob","list","write","edit","patch","bash","webfetch","task"}
tools = cfg.get("tools", {})
missing = [t for t in must_be_off if tools.get(t) is not False]
sys.exit(1 if missing else 0)
PY

echo "== JSON extraction from reviewer output =="
# Regression: reviewers narrate before emitting JSON, and that prose contains
# braces. A first-"{"-to-last-"}" slice parsed the prose instead and the whole
# review died after the model had already been paid for.
EXTRACT="$TMP/extract.py"
python3 - "$SKILL/scripts/glm_review.sh" "$EXTRACT" <<'PYX'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"python3 - \"\$RAW\" \"\$OUT\" \"\$SCHEMA\" <<'PY'\n(.*?)\nPY\n", src, re.S)
if not m:
    sys.exit("could not lift the extractor out of glm_review.sh")
open(sys.argv[2], "w", encoding="utf-8").write(m.group(1))
PYX
if [ -s "$EXTRACT" ]; then ok "extractor lifted from glm_review.sh"; else bad "extractor lifted from glm_review.sh"; fi

mk_raw() { printf '%s' "$1" > "$TMP/raw.txt"; }
run_extract() { python3 "$EXTRACT" "$TMP/raw.txt" "$TMP/out.json" "$SCHEMA" >/dev/null 2>&1; }

GOOD='{"reviewer":"glm-5.2","summary":"s","overall":"approve","findings":[]}'

mk_raw "$GOOD"; run_extract && ok "bare JSON object is extracted" || bad "bare JSON object is extracted"

# The exact shape that broke in production.
mk_raw "I checked provider.{p}.models.{m} first.
$GOOD"
if run_extract; then ok "prose containing braces before the JSON"; else bad "prose containing braces before the JSON"; fi

mk_raw "prose {p} before
\`\`\`json
$GOOD
\`\`\`
trailing prose with a stray } brace"
if run_extract; then ok "fenced JSON with braces in surrounding prose"; else bad "fenced JSON with braces in surrounding prose"; fi

mk_raw "here is a decoy {\"a\":1} and the real one:
$GOOD"
if run_extract && python3 -c "
import json,sys; d=json.load(open('$TMP/out.json')); sys.exit(0 if d.get('reviewer')=='glm-5.2' else 1)"; then
  ok "decoy object is not mistaken for the findings"
else bad "decoy object is not mistaken for the findings"; fi

mk_raw "no json here at all {oops}"
if run_extract; then bad "output with no findings object fails loudly"; else ok "output with no findings object fails loudly"; fi

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

# Bad GLM_PASS_RETRIES -> exit 2.
STUB_FAIL="" GLM_PASS_RETRIES=abc wrap "$TMP/agg-badR.json" 3; check "bad GLM_PASS_RETRIES: exit 2" "$?" "2"

# Summary line reports the success ratio.
STUB_FAIL="2" wrap "$TMP/agg-sum.json" 3
case "$(cat "$TMP/wrap.err")" in *"2/3 passes succeeded"*) ok "wrapper reports M/N passes";; *) bad "wrapper reports M/N passes";; esac

echo "== python unit tests =="
for t in "$DIR"/test_*.py; do
  [ -f "$t" ] || continue
  if python3 "$t" >/dev/null 2>&1; then ok "$(basename "$t")"; else bad "$(basename "$t") (run: python3 $t)"; fi
done

echo "== scripts parse =="
for s in "$SKILL"/scripts/*.sh "$DIR"/run_tests.sh; do
  bash -n "$s" && ok "bash -n $(basename "$s")" || bad "bash -n $(basename "$s")"
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
