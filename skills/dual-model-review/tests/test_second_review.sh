#!/usr/bin/env bash
set -euo pipefail
# Plain assertions; capture exit codes with `rc=0; cmd || rc=$?` under set -e.
#
# No real review is ever run here: every case either fails preflight, or points
# CODEX_BIN/OPENCODE_BIN at a fake CLI shim. Nothing reaches a paid API.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$HERE/../scripts/second_review.sh"
RUBRIC="$HERE/../references/rubric.md"
SCHEMA="$HERE/../references/findings.schema.json"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BUNDLE="$WORK/bundle.md"; printf '# Review packet\nBUNDLE_SENTINEL\n' > "$BUNDLE"
OUT="$WORK/out.json"

# A fake CLI that records what it was handed, then prints narration + a findings
# object. The narration includes a brace-y string to exercise the JSON extractor.
make_shim() {  # make_shim <shim-path> <payload-file>
  cat > "$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$1.args"
cat > "$1.stdin"
echo "I reviewed the packet at provider.{p}.models.{m} and found issues."
cat "$2"
EOF
  chmod +x "$1"
}

# --- preflight: argument validation (no CLI, no network, no spend) ---

# 1: wrong arity -> exit 2
rc=0; "$SR" "$BUNDLE" "$RUBRIC" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "3 args should exit 2 (got $rc)"

# 2: unknown backend -> exit 2
rc=0; "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" --backend bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "bad --backend should exit 2 (got $rc)"

# 3: --backend with no value -> exit 2, and must not hang
rc=0; timeout 10 "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" --backend >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "trailing --backend should exit 2, not hang (got $rc)"

# 4: bad effort per backend -> exit 2 (codex has medium/xhigh, opencode does not)
rc=0; CODEX_EFFORT=bogus "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "bad CODEX_EFFORT should exit 2 (got $rc)"
rc=0; ZEN_VARIANT=medium "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" --backend glm >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "ZEN_VARIANT=medium is not an opencode variant, should exit 2 (got $rc)"

# 5: missing / empty bundle -> exit 2 BEFORE any CLI call (the expensive typo)
rc=0; "$SR" "$WORK/nope.md" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "missing bundle should exit 2 (got $rc)"
: > "$WORK/empty.md"
rc=0; "$SR" "$WORK/empty.md" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "empty bundle should exit 2 (got $rc)"

# 6: CLI missing -> exit 127
rc=0; CODEX_BIN="$WORK/no-such-codex" "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 127 ] && ok || bad "absent codex should exit 127 (got $rc)"

# --- the extract + validate pipeline, against a fake CLI ---

VALID="$WORK/valid.json"
cat > "$VALID" <<'JSON'
{"reviewer":"gpt-5.6-sol","summary":"one finding.","overall":"request_changes",
 "findings":[{"id":"R2-001","severity":"high","category":"correctness",
   "location":"a.py:10","issue":"off by one","evidence":"for i in range(n-1)",
   "failure_case":"last row is skipped","suggestion":"use range(n)",
   "confidence":"high","recommendation":"must_fix"}]}
JSON

# A critical finding with no evidence/failure_case: the contract says reject.
BADFIND="$WORK/badfind.json"
cat > "$BADFIND" <<'JSON'
{"reviewer":"gpt-5.6-sol","summary":"ungrounded.","overall":"block",
 "findings":[{"id":"R2-001","severity":"critical","category":"security",
   "location":"a.py:10","issue":"unsafe","suggestion":"fix it",
   "confidence":"low","recommendation":"must_fix"}]}
JSON

SHIM="$WORK/codex"; make_shim "$SHIM" "$VALID"
if python3 -c 'import jsonschema' 2>/dev/null; then
  rm -f "$OUT"
  rc=0; CODEX_BIN="$SHIM" CODEX_API_KEY=test "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && ok || bad "valid findings should exit 0 (got $rc)"
  [ -f "$OUT" ] && grep -q '"R2-001"' "$OUT" && ok || bad "valid findings should be written to OUT_JSON"

  # The footgun: codex takes a positional prompt over stdin, so the artifact has
  # to travel in the SAME stdin stream as the prompt, with the `-` placeholder.
  # If this regresses, reviewer #2 reviews nothing and the call is billed anyway.
  grep -q "BUNDLE_SENTINEL" "$SHIM.stdin" && ok || bad "bundle never reached codex stdin"
  grep -q "You are an INDEPENDENT senior reviewer" "$SHIM.stdin" && ok || bad "prompt never reached codex stdin"
  grep -qx -- "-" "$SHIM.args" && ok || bad "codex must get the '-' stdin placeholder"
  grep -qx -- "read-only" "$SHIM.args" && ok || bad "codex must run --sandbox read-only"
  grep -qx -- "model_reasoning_effort=high" "$SHIM.args" && ok || bad "codex effort should default to high"
  grep -qx -- "gpt-5.6-sol" "$SHIM.args" && ok || bad "codex model should default to gpt-5.6-sol"

  # glm backend still works after the refactor (opencode takes the prompt as an
  # argument and the artifact on stdin - the opposite split from codex).
  GSHIM="$WORK/opencode"; make_shim "$GSHIM" "$VALID"
  rm -f "$OUT"
  rc=0; OPENCODE_BIN="$GSHIM" OPENCODE_API_KEY=test "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" --backend glm >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && ok || bad "glm backend should exit 0 (got $rc)"
  grep -q "BUNDLE_SENTINEL" "$GSHIM.stdin" && ok || bad "bundle never reached opencode stdin"
  grep -q "You are an INDEPENDENT senior reviewer" "$GSHIM.args" && ok || bad "prompt should be an opencode argument"
  grep -qx -- "max" "$GSHIM.args" && ok || bad "opencode variant should default to max"

  SHIM2="$WORK/codex-bad"; make_shim "$SHIM2" "$BADFIND"
  rm -f "$OUT"
  rc=0; CODEX_BIN="$SHIM2" CODEX_API_KEY=test "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && ok || bad "critical finding with no evidence must be rejected (got $rc)"
  [ ! -f "$OUT" ] && ok || bad "rejected findings must not be written to OUT_JSON"
else
  # Fail-closed check: with no validator installed the run must NOT pass. This is
  # the branch CI hits on a bare box; install jsonschema to exercise the rest.
  rm -f "$OUT"
  rc=0; CODEX_BIN="$SHIM" CODEX_API_KEY=test "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && ok || bad "missing jsonschema must fail the run, not pass it unchecked (got $rc)"
  [ ! -f "$OUT" ] && ok || bad "unvalidated findings must not be written to OUT_JSON"
  echo "note: jsonschema not installed - schema-enforcement cases skipped (fail-closed path checked instead)" >&2
fi

echo "second_review: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
