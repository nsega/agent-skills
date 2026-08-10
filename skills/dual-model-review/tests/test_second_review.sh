#!/usr/bin/env bash
set -euo pipefail
# Plain assertions; capture exit codes with `rc=0; cmd || rc=$?` under set -e.
#
# No real review is ever run here: every case either fails preflight, or points
# CODEX_BIN/OPENCODE_BIN at a fake CLI shim. Nothing reaches a paid API.
#
# That invariant only holds if the suite ignores the developer's environment.
# REVIEW2_BACKEND is a documented env var, so an exported REVIEW2_BACKEND=glm
# would silently redirect every "codex" case to the glm path, where OPENCODE_BIN
# is unset, falling through to the REAL opencode on PATH (which auto-loads a Zen
# key from auth.json) and billing real calls. The model/effort/config vars leak
# into the `grep -qx` assertions the same way.
export REVIEW2_BACKEND=codex
unset CODEX_MODEL CODEX_EFFORT CODEX_BIN ZEN_MODEL ZEN_VARIANT OPENCODE_BIN OPENCODE_CONFIG

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$HERE/../scripts/second_review.sh"
RUBRIC="$HERE/../references/rubric.md"
SCHEMA="$HERE/../references/findings.schema.json"
pass=0; fail=0; skip=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }
# A skipped assertion is NOT a pass: count it separately and print it, so a
# missing dependency shows up as a hole in coverage instead of a green run.
skipped() { skip=$((skip+1)); echo "SKIP: $1" >&2; }

# GNU coreutils, absent from a stock macOS under either name.
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

WORK="$(mktemp -d)"
# The validation-failure cases deliberately leave their raw output in /tmp for
# inspection, which is correct for a real run but would make the suite litter a
# file per run. Clean up only what this run created (files newer than a marker),
# never a concurrent real review's output.
MARKER="$WORK/.started"; : > "$MARKER"
TMPREAL="$(cd /tmp && pwd -P)"
trap 'find "$TMPREAL" -maxdepth 1 -name "r2-review-raw.*" -newer "$MARKER" -delete 2>/dev/null; rm -rf "$WORK"' EXIT
BUNDLE="$WORK/bundle.md"; printf '# Review packet\nBUNDLE_SENTINEL\n' > "$BUNDLE"
OUT="$WORK/out.json"

# A fake CLI that records what it was handed, then emits narration + a findings
# object. The narration includes a brace-y string to exercise the JSON extractor.
# With a third argument the shim honours `-o FILE` (what real codex does); without
# it, the shim only writes stdout, which exercises the fallback path.
make_shim() {  # make_shim <shim-path> <payload-file> [honour_dash_o]
  cat > "$1" <<EOF
#!/usr/bin/env bash
echo "SHIM_STDERR_NOISE" >&2
printf '%s\n' "\$@" > "$1.args"
cat > "$1.stdin"
dest=""
if [ -n "${3:-}" ]; then
  prev=""
  for a in "\$@"; do
    [ "\$prev" = "-o" ] && dest="\$a"
    prev="\$a"
  done
fi
{
  echo "I reviewed the packet at provider.{p}.models.{m} and found issues."
  cat "$2"
} > "\${dest:-/dev/stdout}"
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

# 3: --backend with no value -> exit 2, and must not hang.
# `timeout` is GNU coreutils: macOS ships neither it nor `gtimeout` until you
# `brew install coreutils`, so hardcoding it made this assertion exit 127 and
# report a spurious failure on a stock Mac -- the platform this suite targets.
# The bound is load-bearing here (the regression being guarded against is a HANG,
# which would otherwise wedge the suite forever), so skip loudly rather than
# quietly dropping the check when neither name is available.
if [ -n "$TIMEOUT_BIN" ]; then
  rc=0; "$TIMEOUT_BIN" 10 "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" --backend >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && ok || bad "trailing --backend should exit 2, not hang (got $rc)"
else
  skipped "no timeout/gtimeout on PATH (brew install coreutils): skipped the no-hang assertion"
fi

# 4: bad effort per backend -> exit 2 (codex has medium/xhigh, opencode does not)
rc=0; CODEX_EFFORT=bogus "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "bad CODEX_EFFORT should exit 2 (got $rc)"
rc=0; ZEN_VARIANT=medium "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" --backend glm >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "ZEN_VARIANT=medium is not an opencode variant, should exit 2 (got $rc)"

# 4b: the codex allowlist must match the real catalog (`codex debug models`):
# no model accepts "minimal" (the API 400s on it), and gpt-5.6-sol does accept
# "max". Getting either end wrong is a silent downgrade or a bogus rejection.
rc=0; CODEX_EFFORT=minimal "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "CODEX_EFFORT=minimal is not a codex effort, should exit 2 (got $rc)"
# 127 means it passed effort validation and reached the CLI-presence check.
rc=0; CODEX_EFFORT=max CODEX_BIN="$WORK/no-such-codex" "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 127 ] && ok || bad "CODEX_EFFORT=max must be accepted (expected 127 at the CLI check, got $rc)"

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

SHIM="$WORK/codex"; make_shim "$SHIM" "$VALID" honour-o
if python3 -c 'import jsonschema' 2>/dev/null; then
  rm -f "$OUT"
  # `find`, not `ls glob`: an unmatched glob makes ls exit 1, and under
  # `set -o pipefail` that would kill the suite here. $TMPREAL, not /tmp: on
  # macOS /tmp is a symlink to private/tmp and `find /tmp` does NOT descend a
  # symlinked start point, so the unresolved form silently counts 0 every time
  # and turns this assertion into one that can never fail.
  count_raw() { find "$TMPREAL" -maxdepth 1 -name 'r2-review-raw.*' 2>/dev/null | wc -l | tr -d ' '; }
  rawbefore=$(count_raw)
  ERR="$WORK/err.txt"
  rc=0; CODEX_BIN="$SHIM" CODEX_API_KEY=test "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] && ok || bad "valid findings should exit 0 (got $rc)"
  [ -f "$OUT" ] && grep -q '"R2-001"' "$OUT" && ok || bad "valid findings should be written to OUT_JSON"

  # The raw dump is reviewer #2's full output for a sensitive packet: keep it on
  # a parse/validate failure (the error points at it), delete it on success.
  rawafter=$(count_raw)
  [ "$rawafter" -le "$rawbefore" ] && ok || bad "a successful run must not leave its raw output in /tmp"

  # codex echoes the whole prompt+bundle on stderr; that must not reach ours.
  grep -q "SHIM_STDERR_NOISE" "$ERR" && bad "the backend's stderr must not be relayed on success (it contains the packet)" || ok

  # The footgun: codex takes a positional prompt over stdin, so the artifact has
  # to travel in the SAME stdin stream as the prompt, with the `-` placeholder.
  # If this regresses, reviewer #2 reviews nothing and the call is billed anyway.
  grep -q "BUNDLE_SENTINEL" "$SHIM.stdin" && ok || bad "bundle never reached codex stdin"
  grep -q "You are an INDEPENDENT senior reviewer" "$SHIM.stdin" && ok || bad "prompt never reached codex stdin"
  grep -qx -- "-" "$SHIM.args" && ok || bad "codex must get the '-' stdin placeholder"
  grep -qx -- "read-only" "$SHIM.args" && ok || bad "codex must run --sandbox read-only"
  grep -qx -- "model_reasoning_effort=high" "$SHIM.args" && ok || bad "codex effort should default to high"
  grep -qx -- "gpt-5.6-sol" "$SHIM.args" && ok || bad "codex model should default to gpt-5.6-sol"
  # Blindness + reproducibility flags, matching dual-model-debate's codex_turn.sh.
  grep -qx -- "--ignore-user-config" "$SHIM.args" && ok || bad "codex must run --ignore-user-config"
  grep -qx -- "--ephemeral" "$SHIM.args" && ok || bad "codex must run --ephemeral"
  grep -qx -- "features.shell_tool=false" "$SHIM.args" && ok || bad "codex must disable the shell tool"
  grep -qx -- "-C" "$SHIM.args" && ok || bad "codex must be pointed at a scratch working root"

  # The -o path above was the preferred one; stdout is the fallback when a codex
  # build writes nothing to the -o file.
  SHIM3="$WORK/codex-stdout"; make_shim "$SHIM3" "$VALID"
  rm -f "$OUT"
  rc=0; CODEX_BIN="$SHIM3" CODEX_API_KEY=test "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && ok || bad "stdout fallback should exit 0 when -o writes nothing (got $rc)"
  [ -f "$OUT" ] && grep -q '"R2-001"' "$OUT" && ok || bad "stdout fallback should still produce OUT_JSON"

  # glm backend. The artifact travels in the SAME argv message as the prompt, the
  # way the codex arm puts both in one stdin stream.
  #
  # It must NOT be piped on stdin. `opencode run --help` documents no stdin at all
  # (positional `message` is the whole input), and relying on the undocumented
  # merge is what produced two 0-byte /tmp/r2-review-raw.* files. Worse, it merges
  # WITHOUT a delimiter, so a prompt that said the artifact "follows on stdin"
  # left the model looking for a channel it cannot name: verified against real
  # opencode 1.18.11, GLM-5.2 at --variant minimal quoted the piped sentinel back
  # and in the same breath answered "there's no artifact on stdin from my
  # perspective". The bytes arrive; the framing is what breaks. So the artifact
  # gets an explicit header, and the word stdin never appears in the prompt.
  # Every opencode-family backend behaves identically apart from its default
  # model, so assert the whole contract for each name rather than trusting that
  # `glm|kimi)` kept them on one path.
  for be in glm kimi; do
    case "$be" in
      glm)  want_model="opencode/glm-5.2" ;;
      kimi) want_model="opencode/kimi-k3" ;;
    esac
    GSHIM="$WORK/opencode-$be"; make_shim "$GSHIM" "$VALID"
    rm -f "$OUT"
    rc=0; OPENCODE_BIN="$GSHIM" OPENCODE_API_KEY=test "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" --backend "$be" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && ok || bad "$be backend should exit 0 (got $rc)"
    grep -q "BUNDLE_SENTINEL" "$GSHIM.args" && ok || bad "$be: bundle never reached opencode argv"
    grep -q "You are an INDEPENDENT senior reviewer" "$GSHIM.args" && ok || bad "$be: prompt should be an opencode argument"
    grep -q "ARTIFACT TO REVIEW" "$GSHIM.args" && ok || bad "$be: the artifact needs an explicit header, not a bare append"
    grep -qi "stdin" "$GSHIM.args" && bad "$be: the prompt must never mention stdin" || ok
    grep -qx -- "max" "$GSHIM.args" && ok || bad "$be: opencode variant should default to max"
    grep -qx -- "$want_model" "$GSHIM.args" && ok || bad "$be should default to $want_model"
    # The prompt tells the model to stamp reviewer = the model basename, so a
    # wrong default also mislabels every finding the backend produces.
    grep -q "reviewer = \"${want_model##*/}\"" "$GSHIM.args" && ok || bad "$be: prompt should pin reviewer id to ${want_model##*/}"

    # The packet travels in argv, and opencode merges any stdin it is given into
    # the message WITHOUT a delimiter, so the call must pin stdin to /dev/null.
    # Otherwise a piped invocation appends stray bytes to the artifact and the
    # run returns schema-valid findings over a corrupted packet, exit 0. Feed
    # the script a sentinel on stdin and assert the CLI saw none of it.
    rm -f "$OUT" "$GSHIM.stdin"
    rc=0; printf 'STOWAWAY_SENTINEL\n' | OPENCODE_BIN="$GSHIM" OPENCODE_API_KEY=test \
      "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" --backend "$be" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && ok || bad "$be: piped invocation should still exit 0 (got $rc)"
    grep -q "STOWAWAY_SENTINEL" "$GSHIM.stdin" && bad "$be: caller stdin leaked into the opencode call" || ok

    # ZEN_MODEL still wins over the backend's default (the documented escape
    # hatch, and how a third Zen model gets tried without touching the script).
    rm -f "$OUT"
    rc=0; OPENCODE_BIN="$GSHIM" OPENCODE_API_KEY=test ZEN_MODEL=opencode/deepseek-v4-flash \
      "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" --backend "$be" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && ok || bad "$be: ZEN_MODEL override should exit 0 (got $rc)"
    grep -qx -- "opencode/deepseek-v4-flash" "$GSHIM.args" && ok || bad "$be: ZEN_MODEL should override the default model"
  done

  # An empty answer must fail HERE, loudly, naming the backend. opencode exits 0
  # with empty stdout on a large packet at max effort (seen in the wild), and
  # without this guard the run fell through to the JSON extractor and blamed the
  # model's formatting: "could not locate a findings JSON object".
  for be in codex glm kimi; do
    ESHIM="$WORK/empty-$be"
    printf '#!/usr/bin/env bash\ncat > /dev/null\nexit 0\n' > "$ESHIM"; chmod +x "$ESHIM"
    rm -f "$OUT"; EERR="$WORK/eerr-$be.txt"
    rc=0; CODEX_BIN="$ESHIM" OPENCODE_BIN="$ESHIM" CODEX_API_KEY=test OPENCODE_API_KEY=test \
      "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" --backend "$be" >/dev/null 2>"$EERR" || rc=$?
    [ "$rc" -ne 0 ] && ok || bad "$be: empty backend output must fail the run (got $rc)"
    grep -qi "empty" "$EERR" && ok || bad "$be: the error must say the output was empty, not blame JSON extraction"
    grep -q "could not locate a findings JSON object" "$EERR" && bad "$be: empty output must not surface as a JSON-extraction error" || ok
    [ ! -f "$OUT" ] && ok || bad "$be: no OUT_JSON should be written for an empty answer"
  done

  # When the backend itself fails, the run must fail AND surface the tail of its
  # stderr (suppressed on success) so the operator can see why.
  FSHIM="$WORK/codex-fail"
  printf '#!/usr/bin/env bash\necho "SHIM_STDERR_NOISE: boom" >&2\nexit 1\n' > "$FSHIM"
  chmod +x "$FSHIM"
  rm -f "$OUT"; ERR2="$WORK/err2.txt"
  rc=0; CODEX_BIN="$FSHIM" CODEX_API_KEY=test "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>"$ERR2" || rc=$?
  [ "$rc" -ne 0 ] && ok || bad "a failing backend must fail the run (got $rc)"
  grep -q "SHIM_STDERR_NOISE" "$ERR2" && ok || bad "on failure the tail of the backend's stderr must be surfaced"

  # The decoy case: the reviewer quotes the JSON schema it was handed (whose
  # `properties` object has keys reviewer/summary/overall/findings) and then
  # emits a short, valid "approve, no findings" document. Presence-only matching
  # plus largest-wins would pick the ~1.5KB schema fragment over the ~80-byte
  # real answer and fail the run AFTER the paid call.
  DECOY="$WORK/codex-decoy"
  cat > "$DECOY" <<EOF
#!/usr/bin/env bash
cat > /dev/null
echo "Here is the schema I was asked to satisfy:"
cat "$SCHEMA"
echo '{"reviewer":"gpt-5.6-sol","summary":"Clean.","overall":"approve","findings":[]}'
EOF
  chmod +x "$DECOY"
  rm -f "$OUT"
  rc=0; CODEX_BIN="$DECOY" CODEX_API_KEY=test "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && ok || bad "a quoted schema must not beat the real findings doc (got $rc)"
  [ -f "$OUT" ] && grep -q '"approve"' "$OUT" && ok || bad "the real approve document should be the one written"

  # An empty findings array is a valid result and must survive extraction.
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["findings"]==[] and d["reviewer"]=="gpt-5.6-sol" else 1)' "$OUT" 2>/dev/null \
    && ok || bad "the extracted document should be the reviewer's approve result, not a schema fragment"

  # Interrupt cleanup is asserted structurally, not by signalling a live run.
  # Faithfully reproducing a Ctrl-C needs the signal to reach the whole
  # foreground process group (bash cannot run a trap while a foreground child is
  # running, so signalling only the script leaves it blocked behind the backend
  # and proves nothing). That needs job control or a pty, which is not portable
  # inside this suite, and a test that fails for harness reasons is worse than no
  # test. The behaviour itself was verified by hand against the real script: the
  # raw file is present mid-call and gone after SIGINT. What is checked here is
  # that the guards which make that work are still installed.
  grep -q "trap cleanup EXIT" "$SR" && ok || bad "the EXIT cleanup trap must stay installed"
  grep -qE "^trap .* INT\$" "$SR" && ok || bad "an INT trap is required (EXIT alone does not fire on signal death)"
  grep -qE "^trap .* TERM\$" "$SR" && ok || bad "a TERM trap is required (EXIT alone does not fire on signal death)"

  # A bad OUT_JSON directory must be caught in preflight, not after the call.
  rc=0; CODEX_BIN="$SHIM" CODEX_API_KEY=test "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$WORK/no-such-dir/out.json" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && ok || bad "a missing output directory should exit 2 before spending (got $rc)"
  [ ! -f "$SHIM.stdin" ] || [ "$(find "$WORK" -name 'no-such-dir' | wc -l)" -eq 0 ] && ok || bad "no directory should be created for a bad OUT path"

  SHIM2="$WORK/codex-bad"; make_shim "$SHIM2" "$BADFIND"
  # Seed a PREVIOUS run's findings: a failed run must not leave them behind, or
  # SKILL.md's "re-run on just the fix diff" step merges stale full-artifact
  # findings as if they were the fix review.
  printf '{"reviewer":"stale","summary":"previous run","overall":"approve","findings":[]}\n' > "$OUT"
  rc=0; CODEX_BIN="$SHIM2" CODEX_API_KEY=test "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && ok || bad "critical finding with no evidence must be rejected (got $rc)"
  [ ! -f "$OUT" ] && ok || bad "a failed run must not leave a stale OUT_JSON behind"
else
  # Fail-closed check: with no validator installed the run must NOT pass. This is
  # the branch CI hits on a bare box; install jsonschema to exercise the rest.
  rm -f "$OUT"
  rc=0; CODEX_BIN="$SHIM" CODEX_API_KEY=test "$SR" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$OUT" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && ok || bad "missing jsonschema must fail the run, not pass it unchecked (got $rc)"
  [ ! -f "$OUT" ] && ok || bad "unvalidated findings must not be written to OUT_JSON"
  echo "note: jsonschema not installed - schema-enforcement cases skipped (fail-closed path checked instead)" >&2
fi

# Not `${skip:+...}`: "0" is a non-empty string, so that prints ", 0 skipped" on
# every clean run.
#
# And not `[ .. ] && skipmsg=..` either. What kills that form HERE is `set -u`,
# not `set -e`: when the test is false skipmsg is never assigned and the echo
# below dies "unbound variable". Verified on bash 3.2.57.
#
# Do not generalize the `set -e` half. At THIS top level the failed test is
# exempt as a non-final command in an AND-OR list, so the script continues. But
# the list's status still becomes its enclosing command's status, and that
# command is not exempt: as the last line of a function body, in a subshell, or
# in a command substitution, the same idiom exits 1. This file defines ok(),
# bad(), skipped() and make_shim(), so copying the pattern into one of them
# would abort the suite mid-run.
if [ "$skip" -gt 0 ]; then skipmsg=", $skip skipped"; else skipmsg=""; fi
echo "second_review: $pass passed, $fail failed$skipmsg"
[ "$fail" -eq 0 ]
