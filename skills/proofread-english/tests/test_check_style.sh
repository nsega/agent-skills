#!/usr/bin/env bash
set -euo pipefail
# Zero-token checks for proofread-english: the docs follow the rules they
# teach, and check_style.py flags each rule and skips code and quotes.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
CHECK="$SKILL_DIR/scripts/check_style.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

EM=$'—'
EN=$'–'

# run TEXT: check TEXT on stdin, keep the output in $TMP/out and the exit code in $rc.
run() { rc=0; printf '%s\n' "$1" | python3 "$CHECK" > "$TMP/out" || rc=$?; }

# 1: the skill's files exist and SKILL.md names each of them.
grep -q "^name: proofread-english$" "$SKILL_DIR/SKILL.md" && ok || bad "frontmatter name wrong"
for f in references/registers.md scripts/check_style.py; do
  [ -f "$SKILL_DIR/$f" ] && ok || bad "$f missing"
  grep -q "$f" "$SKILL_DIR/SKILL.md" && ok || bad "SKILL.md does not mention $f"
done
python3 -m json.tool "$SKILL_DIR/evals/evals.json" > /dev/null && ok || bad "evals.json is not valid JSON"

# 2: the docs pass their own checker, and hold no em dash even in code.
for f in SKILL.md references/registers.md; do
  python3 "$CHECK" "$SKILL_DIR/$f" > "$TMP/out" && ok || bad "$f fails check_style.py: $(cat "$TMP/out")"
  grep -q "0 errors, 0 warnings" "$TMP/out" && ok || bad "$f has warnings: $(cat "$TMP/out")"
  ! grep -q "$EM" "$SKILL_DIR/$f" && ok || bad "$f contains an em dash"
done

# 3: clean prose passes, and a CLI flag is not a dash.
run "We shipped the fix today. Run it with --help to see the flags."
[ "$rc" -eq 0 ] && grep -q "0 errors, 0 warnings" "$TMP/out" && ok || bad "clean text flagged: $(cat "$TMP/out")"

# 4: every dash stand-in is an error.
run "Wait ${EM} really?";       [ "$rc" -eq 1 ] && grep -q "em dash" "$TMP/out" && ok || bad "em dash not caught"
run "Wait ${EN} really?";       [ "$rc" -eq 1 ] && grep -q "spaced en dash" "$TMP/out" && ok || bad "spaced en dash not caught"
run "Wait -- really?";          [ "$rc" -eq 1 ] && grep -q "double hyphen" "$TMP/out" && ok || bad "spaced double hyphen not caught"
run "Wait--really?";            [ "$rc" -eq 1 ] && grep -q "double hyphen" "$TMP/out" && ok || bad "unspaced double hyphen not caught"
run $'Wait ― really?';     [ "$rc" -eq 1 ] && grep -q "horizontal bar" "$TMP/out" && ok || bad "horizontal bar not caught"

# 5: an en dash in a number range is fine.
run "Read pages 10${EN}20."
[ "$rc" -eq 0 ] && ok || bad "number range flagged: $(cat "$TMP/out")"

# 6: the contrast construction and its variants are errors.
for s in "It's not a bug, it's a feature." \
         "This isn't about speed. It's about trust." \
         "The cause is not the config, it is a race." \
         "It's not just a tool, it's a platform." \
         $'It’s not a bug, it’s a feature.'; do
  run "$s"
  [ "$rc" -eq 1 ] && grep -q "construction" "$TMP/out" && ok || bad "contrast not caught: $s"
done

# 7: the construction is caught across a line break.
run $'This is not about speed.\nIt is about trust.'
[ "$rc" -eq 1 ] && grep -q "construction" "$TMP/out" && ok || bad "contrast across lines not caught"

# 8: near misses of the construction pass.
for s in "The job isn't done, and it is still running." \
         "The cause is a race, not the config." \
         "It's not ready yet."; do
  run "$s"
  [ "$rc" -eq 0 ] && ok || bad "near miss flagged: $s: $(cat "$TMP/out")"
done

# 9: a semicolon and a spaced hyphen are warnings, not errors.
run "We ship today; QA signed off."
[ "$rc" -eq 0 ] && grep -q "warn:.*semicolon" "$TMP/out" && ok || bad "semicolon not warned"
run "It works - mostly."
[ "$rc" -eq 0 ] && grep -q "warn:.*spaced hyphen" "$TMP/out" && ok || bad "spaced hyphen not warned"

# 10: fenced code, inline code and quote lines are skipped.
run $'Run `a; b — c` now.\n> Quoted — text; kept.\n```sh\necho a; echo b —\n```\n~~~\nIt\'s not X, it\'s Y\n~~~\nDone.'
[ "$rc" -eq 0 ] && grep -q "0 errors, 0 warnings" "$TMP/out" && ok || bad "code or quote checked: $(cat "$TMP/out")"

# 11: a Markdown list, a table and a horizontal rule are not dashes.
run $'- one\n- two\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n'
[ "$rc" -eq 0 ] && grep -q "0 errors, 0 warnings" "$TMP/out" && ok || bad "Markdown structure flagged: $(cat "$TMP/out")"

# 12: errors point at the line and column, and a file path works.
printf 'Line one.\nLine two %s here.\n' "$EM" > "$TMP/draft.txt"
rc=0; python3 "$CHECK" "$TMP/draft.txt" > "$TMP/out" || rc=$?
[ "$rc" -eq 1 ] && grep -q "draft.txt:2:10: em dash" "$TMP/out" && ok || bad "location wrong: $(cat "$TMP/out")"

# 13: bad usage exits 2.
rc=0; python3 "$CHECK" a b > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "bad usage did not exit 2"

echo "proofread-english: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
