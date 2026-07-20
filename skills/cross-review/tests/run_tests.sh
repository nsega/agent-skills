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

echo "== scripts parse =="
for s in "$SKILL"/scripts/*.sh "$DIR"/run_tests.sh; do
  bash -n "$s" && ok "bash -n $(basename "$s")" || bad "bash -n $(basename "$s")"
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
