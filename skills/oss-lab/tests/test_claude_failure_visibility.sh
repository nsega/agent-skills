#!/usr/bin/env bash
# A failing `claude` must say so in the log. Every paid call in this skill
# is wrapped in a command substitution, which captures the child's stdout:
# when an expired credential made `claude` exit nonzero in September 2026,
# errexit aborted each run with a bare exit 1 and nothing in the log, and
# the scout sat dead for five days looking merely idle. These cases pin the
# diagnostics, not the failure: the run is still expected to abort, but it
# must name the exit code, show what came back, and leave the window
# uncommitted so the batch is retried rather than lost.
# shellcheck disable=SC2015,SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
RS="$HERE/../scripts/run-scout.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; build_mockbin "$MOCKBIN"

ISSUE='{"number":10,"title":"t","pull_request":null,"assignees":[],"labels":[],"comments":0,"created_at":"2026-09-01T10:00:00Z","html_url":"u","body":"b"}'

new_case() {  # $1: name; sets STATE, MOCK_LOG, MOCK_CLAUDE_OUT, FETCH
  CASE="$WORK/$1"; STATE="$CASE/state"; MOCK_LOG="$CASE/log"
  mkdir -p "$MOCK_LOG"; build_state "$STATE"
  MOCK_CLAUDE_OUT="$CASE/claude_out"; FETCH="$CASE/raw.jsonl"
  : > "$MOCK_CLAUDE_OUT"; : > "$FETCH"
}

run_scout() {
  env PATH="$MOCKBIN:$PATH" \
      OSS_LAB_STATE_DIR="$STATE" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" \
      MOCK_LOG="$MOCK_LOG" \
      MOCK_CLAUDE_OUT="$MOCK_CLAUDE_OUT" \
      MOCK_CLAUDE_RC="${MOCK_CLAUDE_RC:-0}" \
      MOCK_FETCH="$FETCH" \
      MOCK_WIP="${MOCK_WIP:-2}" \
      MOCK_GH_LOGIN=nsega \
      "$RS"
}

# 1: the outage shape. claude exits nonzero and explains itself on stdout,
#    which the substitution swallows. The run must still name both.
new_case rc_nonzero
printf '%s\n' "$ISSUE" > "$FETCH"
echo "Invalid API key - please run /login" > "$MOCK_CLAUDE_OUT"
date +%s > "$STATE/last_reeval"   # keep the weekly pass out of this case
rc=0; out="$(MOCK_CLAUDE_RC=7 run_scout 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && ok || bad "rc_nonzero: scout must abort when claude fails"
grep -q "claude exited 7" <<<"$out" && ok || bad "rc_nonzero: log must name the exit code, got: $out"
grep -q "Invalid API key" <<<"$out" && ok || bad "rc_nonzero: log must show what claude returned, got: $out"
[ ! -e "$STATE/last_run" ] && ok || bad "rc_nonzero: window must not advance on a failed paid call"

# 2: claude exits 0 but returns prose instead of scores. Distinguishable
#    from case 1 only if the runner prints the body.
new_case unparseable
printf '%s\n' "$ISSUE" > "$FETCH"
echo "I cannot score these issues right now." > "$MOCK_CLAUDE_OUT"
date +%s > "$STATE/last_reeval"
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && ok || bad "unparseable: scout must abort"
grep -q "no parseable scores" <<<"$out" && ok || bad "unparseable: should name the parse failure"
grep -q "I cannot score these issues" <<<"$out" && ok || bad "unparseable: should show the body, got: $out"
[ ! -e "$STATE/last_run" ] && ok || bad "unparseable: window must not advance"

# 3: a failing weekly pass must stay best-effort AND carry its exit code.
#    Empty fetch, so the scout takes its no-new-issues exit after the gate.
new_case reeval_rc
printf '[%s]\n' '{"issue":"kubernetes/kubernetes#111","weighted_total":5.6,"route":"queue"}' > "$STATE/queue.json"
rm -f "$STATE/last_reeval"        # no stamp: gate is open
rc=0; out="$(MOCK_CLAUDE_RC=7 run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "reeval_rc: a failed weekly pass must not cost the iteration (rc=$rc)"
# run-reeval.sh translates the paid call's exit 7 into its own abort (1),
# so the scout reports 1. Both halves must reach the log: without the
# child's own line, "reeval pass failed" says nothing about why.
grep -q "reeval pass failed (exit 1)" <<<"$out" && ok || bad "reeval_rc: warn must name the child's exit code, got: $out"
grep -q "claude exited 7 (stamp not advanced)" <<<"$out" && ok || bad "reeval_rc: the child's own reason must reach the log, got: $out"
grep -qE '^[0-9]+$' "$STATE/last_reeval" 2>/dev/null && bad "reeval_rc: stamp must not advance on failure" || ok

summary "claude failure visibility"
