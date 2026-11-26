#!/usr/bin/env bash
set -euo pipefail
# Zero-token checks for check_report.py: its verdicts on fixture reports
# (complete, missing a reviewer #2 id, missing a heading), and that its heading
# list still matches the output template in SKILL.md.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
CHECK="$SKILL_DIR/scripts/check_report.py"
FX="$HERE/fixtures"
R2="$FX/r2-findings.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

# 1: SKILL.md points at the checker.
grep -q "scripts/check_report.py" "$SKILL_DIR/SKILL.md" && ok || bad "SKILL.md does not mention scripts/check_report.py"

# 2: a complete report passes, with and without the findings file.
out="$(python3 "$CHECK" "$FX/report-complete.md" "$R2")" && ok || bad "complete report failed: $out"
echo "$out" | grep -q "3 reviewer #2 ids accounted for" && ok || bad "complete report should account for 3 ids: $out"
out="$(python3 "$CHECK" "$FX/report-complete.md")" && ok || bad "complete report failed without findings: $out"

# 3: an R2 id that is not in a merged finding or "Not adopted" fails, one line
# per id. R2-002 is only in Disposition, which does not count; R2-003 is not in
# the report at all, which only the findings file can reveal.
rc=0; python3 "$CHECK" "$FX/report-missing-id.md" "$R2" > "$TMP/out" || rc=$?
[ "$rc" -eq 1 ] && ok || bad "missing id should exit 1 (got $rc)"
grep -q 'R2-002 is in neither a merged finding nor "Not adopted"' "$TMP/out" && ok || bad "R2-002 not reported: $(cat "$TMP/out")"
grep -q 'R2-003 is in neither' "$TMP/out" && ok || bad "R2-003 not reported: $(cat "$TMP/out")"
! grep -q 'R2-001' "$TMP/out" && ok || bad "R2-001 is merged and must not be reported"
[ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 2 ] && ok || bad "expected exactly 2 problem lines: $(cat "$TMP/out")"
rc=0; python3 "$CHECK" "$FX/report-missing-id.md" > "$TMP/out" || rc=$?
[ "$rc" -eq 1 ] && ok || bad "missing id without findings should still catch R2-002 (got $rc)"
grep -q 'R2-002 is in neither' "$TMP/out" && ok || bad "R2-002 not reported without findings"
! grep -q 'R2-003' "$TMP/out" && ok || bad "R2-003 cannot be known without the findings file"

# 4: a missing heading fails, naming the heading, and nothing else.
rc=0; python3 "$CHECK" "$FX/report-missing-heading.md" "$R2" > "$TMP/out" || rc=$?
[ "$rc" -eq 1 ] && ok || bad "missing heading should exit 1 (got $rc)"
grep -q 'missing heading: ## Residual risk' "$TMP/out" && ok || bad "missing heading not named: $(cat "$TMP/out")"
[ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 1 ] && ok || bad "expected exactly 1 problem line: $(cat "$TMP/out")"

# 5: a heading that appears only inside a code fence does not count.
grep -v '^## Disposition' "$FX/report-complete.md" > "$TMP/fenced.md"
printf '\n```\n## Disposition\n```\n' >> "$TMP/fenced.md"
rc=0; python3 "$CHECK" "$TMP/fenced.md" "$R2" > "$TMP/out" || rc=$?
[ "$rc" -eq 1 ] && grep -q 'missing heading: ## Disposition' "$TMP/out" && ok || bad "a fenced heading was counted: $(cat "$TMP/out")"

# 6: SKILL.md's own output template has every heading the checker requires, so
# the two cannot drift apart. Its placeholder ids (R2-00x) are not real ids.
sed -n '/^```markdown$/,/^```$/{/^```/d;p;}' "$SKILL_DIR/SKILL.md" > "$TMP/template.md"
[ -s "$TMP/template.md" ] && ok || bad "could not extract the output template from SKILL.md"
out="$(python3 "$CHECK" "$TMP/template.md")" && ok || bad "SKILL.md template fails the checker: $out"

# 7: usage errors and unreadable input exit 2, not 1.
rc=0; python3 "$CHECK" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "no arguments should exit 2 (got $rc)"
rc=0; python3 "$CHECK" "$TMP/no-such.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "a missing report should exit 2 (got $rc)"
printf 'not json\n' > "$TMP/bad.json"
rc=0; python3 "$CHECK" "$FX/report-complete.md" "$TMP/bad.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "an unreadable findings file should exit 2 (got $rc)"

echo "check_report: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
