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

python3 - "$SCHEMA" "$FIX" <<'PY'
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

sys.exit(0 if all(results) else 1)
PY
if [ $? -eq 0 ]; then pass=$((pass+6)); else fail=$((fail+1)); fi

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

echo "== tier -> effort routing =="
# opencode accepts an unknown --variant silently, so the mapping is validated in
# glm_review.sh and pinned here. These run with a nonexistent bundle: argument
# validation must happen before any network call, so a bad tier never costs money.
tier_rc() { "$SKILL/scripts/glm_review.sh" /nonexistent-bundle "$SCHEMA" "$SCHEMA" /dev/null "$1" 2>&1; }

OUT="$(tier_rc typo)"; check "unknown tier is rejected" "$?" "2"
case "$OUT" in *"want lite|full"*) ok "unknown tier names the valid values";; *) bad "unknown tier names the valid values";; esac

OUT="$(ZEN_VARIANT=turbo tier_rc full)"; check "unknown ZEN_VARIANT is rejected" "$?" "2"

# A valid tier must get PAST tier validation and then fail on the missing bundle.
# Both exit 2, so distinguish on the message. This also pins that input checks
# happen before any network call: if they did not, these would hang on a live run.
for t in lite full; do
  OUT="$(tier_rc "$t")"
  case "$OUT" in
    *"no such file"*) ok "valid tier '$t' passes validation, then fails on the bundle";;
    *"want lite|full"*) bad "valid tier '$t' was rejected as a bad tier";;
    *) bad "valid tier '$t': unexpected output '$OUT'";;
  esac
done

OUT="$("$SKILL/scripts/glm_review.sh" /dev/null "$SCHEMA" "$SCHEMA" /dev/null full 2>&1)"
check "empty bundle is refused before spending" "$?" "2"

grep -q 'lite) TIER_VARIANT="high"' "$SKILL/scripts/glm_review.sh" && ok "lite maps to high" || bad "lite maps to high"
grep -q 'full) TIER_VARIANT="max"'  "$SKILL/scripts/glm_review.sh" && ok "full maps to max"  || bad "full maps to max"
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

echo "== scripts parse =="
for s in "$SKILL"/scripts/*.sh "$DIR"/run_tests.sh; do
  bash -n "$s" && ok "bash -n $(basename "$s")" || bad "bash -n $(basename "$s")"
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
