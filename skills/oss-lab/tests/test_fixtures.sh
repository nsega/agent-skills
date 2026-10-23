#!/usr/bin/env bash
# test_fixtures.sh: zero-token, no-network regression harness for oss-lab.
#
#   bash test_fixtures.sh [<agent-skills-dir>] [--allow-known] [--only REGEX] [--keep] [--verbose]
#
# Runs every case in fixtures/{fetch,route,reeval}/*.json against the REAL
# scripts of a checkout (default: the one this file is in; pass another to
# compare before and after a change) (skills/oss-lab/scripts/*), with mock `gh`,
# `curl`, and `claude` (fixtures/mocks/) first on PATH, a scrubbed environment
# (env -i: no token variables can leak in), a throwaway HOME and state dir,
# and an isolated git config. OSS_LAB_RETRY_SLEEP=0 removes the backoff
# between retried GitHub calls, so a failing-search case runs in seconds.
# The checkout itself is never written to: the
# skill directory is copied into a temp dir and run from there.
#
# Prints one line per case (PASS / FAIL) and a summary. Exit status:
#   0  every case matched its documented expected outcome
#   1  at least one mismatch. With --allow-known, mismatches on cases tagged
#      with a "divergence" (a documented code-vs-doc finding) are reported but
#      do not fail the run; any other mismatch still does.
#   2  usage or prerequisite error
#
# Requirements: bash >= 4, jq >= 1.6, git, coreutils/findutils (GNU or BSD).
set -uo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AS="$HERE/../../.." ALLOW_KNOWN=0 ONLY="" KEEP=0 VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-known) ALLOW_KNOWN=1 ;;
    --only) ONLY="$2"; shift ;;
    --keep) KEEP=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help) usage ;;
    *) AS="$1" ;;
  esac
  shift
done

FIX="$HERE/fixtures"
SRC_SKILL="$(cd "$AS" 2>/dev/null && pwd)/skills/oss-lab"
for f in scripts/run-scout.sh scripts/run-reeval.sh scripts/fetch-issues.sh scripts/lib.sh prompt.md; do
  [ -f "$SRC_SKILL/$f" ] || { echo "error: $SRC_SKILL/$f not found (pass the agent-skills checkout root)" >&2; exit 2; }
done
for t in jq git; do command -v "$t" >/dev/null || { echo "error: $t is required" >&2; exit 2; }; done
(( BASH_VERSINFO[0] >= 4 )) || { echo "error: bash >= 4 required" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/oss-lab-fixtures.XXXXXX")"
if (( KEEP )); then echo "work dir kept: $WORK"; else trap 'rm -rf "$WORK"' EXIT; fi

# Mocks: copied and made executable here, since the fixture dir may sit on a
# filesystem that forbids exec.
mkdir -p "$WORK/bin"
for m in gh curl claude; do cp "$FIX/mocks/$m" "$WORK/bin/$m"; chmod +x "$WORK/bin/$m"; done
# Run a private copy of the skill so the checkout is never written to.
cp -R "$SRC_SKILL" "$WORK/skill"
chmod +x "$WORK/skill/scripts/"*.sh
# Isolated git config: no signing hooks, no credential helpers, no global
# settings that a mock on PATH could break.
printf '[user]\n\tname = fixture\n\temail = fixture@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$WORK/gitconfig"

COMMIT="$(git -C "$AS" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "oss-lab fixtures against $AS ($COMMIT)"

# --- jq helpers ----------------------------------------------------------
# subset(expected; actual): every key in expected is present in actual with a
# matching value (recursively); arrays match element-wise and by length.
# Sentinels: "<absent>" (key must not exist), "<any>" (key must exist).
# shellcheck disable=SC2016  # jq program: $a/$b are jq variables
JQ_DEFS='
def subset($a; $b):
  if $a == "<any>" then true
  elif ($a | type) == "object" then
    (($b | type) == "object") and
    all($a | to_entries[];
        .key as $k | .value as $v
        | if $v == "<absent>" then ($b | has($k) | not)
          else ($b | has($k)) and subset($v; $b[$k]) end)
  elif ($a | type) == "array" then
    (($b | type) == "array") and (($a | length) == ($b | length)) and
    all(range(0; $a | length) as $i | subset($a[$i]; $b[$i]); .)
  else $a == $b end;
'
jsonl_to_array() { jq -cR 'fromjson? // empty' "$1" 2>/dev/null | jq -cs . ; }

# --- per-case runner -------------------------------------------------------
PASS=0 FAIL=0 KNOWN=0 XPASS=0
declare -a FAILED_UNKNOWN=()

run_case() {
  local cf="$1" id kind C S L H rc=0 script now t0 msgs=() e
  id="$(jq -r '.id' "$cf")"; kind="$(jq -r '.run' "$cf")"
  C="$WORK/cases/$id"; S="$C/state"; L="$C/log"; H="$C/home"
  mkdir -p "$S" "$L" "$H/.claude" "$C/tmp"
  E() { jq -c "$@" "$cf"; }   # read from the case file

  # -- state --
  if [ "$(E '.state.env // "ok"')" = '"ok"' ]; then
    printf 'TODOIST_TOKEN=fixture-placeholder\nTODOIST_PROJECT_ID=fixture-project\n' > "$S/env"
  elif [ "$(E '.state.env')" = '"missing_token"' ]; then
    printf 'TODOIST_PROJECT_ID=fixture-project\n' > "$S/env"
  fi
  local defq='[]'; [ "$kind" = fetch ] && defq='null'
  for f in seen queue; do
    if [ "$(E "(.state // {}) | has(\"${f}_raw\")")" = true ]; then
      jq -r ".state.${f}_raw" "$cf" > "$S/$f.json"      # verbatim text, e.g. a corrupt file
    else
      local v; v="$(jq -c --argjson d "$defq" "if (.state // {}) | has(\"$f\") then .state.$f else \$d end" "$cf")"
      [ "$v" = null ] || jq '.' <<<"$v" > "$S/$f.json"
    fi
  done
  [ "$(E '.state.last_run // null')" != null ] && jq -r '.state.last_run' "$cf" > "$S/last_run"
  now="$(date +%s)"
  local lre; lre="$(E 'if (.state // {}) | has("last_reeval") then .state.last_reeval elif .run == "scout" then "fresh" else null end')"
  case "$lre" in
    null) ;;
    '"fresh"') echo "$now" > "$S/last_reeval" ;;
    '"garbage"') echo "not-a-number" > "$S/last_reeval" ;;
    *) echo $(( now - $(jq -r '.ago' <<<"$lre") )) > "$S/last_reeval" ;;
  esac
  # Pre-seeded per-run cache files (e.g. a linked-PR cache from an earlier run).
  if [ "$(E '.state.cache // null')" != null ]; then
    mkdir -p "$S/.cache"
    while IFS=$'\t' read -r name content; do printf '%s' "$content" > "$S/.cache/$name"; done \
      < <(jq -r '.state.cache | to_entries[] | "\(.key)\t\(.value | tojson)"' "$cf")
    # cache_stale: age the seeded files past the per-run freshness window.
    [ "$(E '.state.cache_stale // false')" = true ] && touch -t 202601010000 "$S/.cache/"*
  fi
  # Snapshot after seeding (the git commit below ages nothing).
  for f in seen.json queue.json last_run last_reeval; do
    [ -e "$S/$f" ] && cp "$S/$f" "$C/initial.$f"
  done
  local gitmode; gitmode="$(E '.state.git // false')"
  if [ "$gitmode" != false ]; then
    (
      export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
      cd "$S" && git init --quiet . && printf 'env\n.cache/\nlast_run*\nlast_reeval\n' > .gitignore &&
      git add .gitignore seen.json queue.json && git commit --quiet -m seed
      if [ "$gitmode" = true ]; then
        git init --bare --quiet "$C/remote.git" && git remote add origin "$C/remote.git" &&
        git push --quiet -u origin HEAD 2>/dev/null
      fi
    ) || msgs+=("harness: could not seed git state")
  fi

  # -- mocks --
  jq '.upstream // {}
      | if has("list_ids") then
          .list = (reduce .list_ids[] as $i (.list // {};
            ($i | split("#")) as [$r, $n]
            | .[$r] += [{number: ($n | tonumber), title: "Synthetic issue \($n)",
                         state: "open", assignees: [], labels: [], comments: 0,
                         created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z",
                         html_url: "https://github.com/\($r)/issues/\($n)",
                         body: "Synthetic fixture issue."}]))
          | del(.list_ids)
        else . end' "$cf" > "$C/upstream.json"
  jq '.todoist // {}' "$cf" > "$C/todoist.json"
  jq -r '.claude.out[]? | if type == "string" then . else tojson end' "$cf" > "$C/claude_out"
  local race=""
  if [ "$(E '.race_upstream // null')" != null ]; then
    jq -s '.[0] * .[1]' "$C/upstream.json" <(jq '.race_upstream' "$cf") > "$C/race.json"; race="$C/race.json"
  fi

  # -- run --
  case "$kind" in
    fetch)  script="$WORK/skill/scripts/fetch-issues.sh" ;;
    scout)  script="$WORK/skill/scripts/run-scout.sh" ;;
    reeval) script="$WORK/skill/scripts/run-reeval.sh" ;;
    *) echo "FAIL  $id: unknown run kind $kind"; FAIL=$((FAIL+1)); return ;;
  esac
  local -a extra_env=()
  while IFS= read -r kv; do [ -n "$kv" ] && extra_env+=("$kv"); done \
    < <(jq -r '(.env // {}) | to_entries[] | "\(.key)=\(.value)"' "$cf")
  local cfg_dir="$H/.claude"
  [ "$(E '.claude_config_dir // null')" != null ] && cfg_dir="$H/$(jq -r '.claude_config_dir' "$cf")"
  t0="$(date +%s)"
  env -i \
    PATH="$WORK/bin:$PATH" HOME="$H" LANG=C TMPDIR="$C/tmp" \
    OSS_LAB_STATE_DIR="$S" CLAUDE_CONFIG_DIR="$cfg_dir" OSS_LAB_RETRY_SLEEP=0 \
    GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    MOCK_LOG="$L" MOCK_UPSTREAM="$C/upstream.json" MOCK_TODOIST="$C/todoist.json" \
    MOCK_CLAUDE_OUT="$C/claude_out" MOCK_CLAUDE_RC="$(jq -r '.claude.rc // 0' "$cf")" \
    MOCK_RACE="$race" \
    "${extra_env[@]}" \
    "$script" > "$C/stdout" 2> "$C/stderr" || rc=$?
  cat "$C/stdout" "$C/stderr" > "$C/output"; echo "$rc" > "$C/rc"

  # -- assertions --
  local X; X="$(jq -c '.expect' "$cf")"
  has() { jq -e --arg k "$1" 'has($k)' <<<"$X" >/dev/null; }
  ex()  { jq -c --arg k "$1" '.[$k]' <<<"$X"; }

  if has rc; then
    e="$(ex rc)"
    if [ "$e" = '"nonzero"' ]; then [ "$rc" -ne 0 ] || msgs+=("rc: expected nonzero, got 0")
    else [ "$rc" -eq "$e" ] || msgs+=("rc: expected $e, got $rc"); fi
  fi
  # Always: nothing written upstream, nothing sent to an unmocked host.
  [ -s "$L/gh_writes" ] && msgs+=("gh write attempted: $(head -1 "$L/gh_writes")")
  [ -s "$L/unexpected_network" ] && msgs+=("unmocked network call: $(head -1 "$L/unexpected_network")")
  [ -s "$L/unexpected" ] && msgs+=("unexpected gh usage: $(head -1 "$L/unexpected")")

  if has stdout_issues; then
    local got; got="$(jsonl_to_array "$C/stdout" | jq -c '[.[] | .issue]')"
    [ "$got" = "$(ex stdout_issues)" ] || msgs+=("stdout issues: expected $(ex stdout_issues), got $got")
  fi
  if has stdout_objects; then
    jq -en --argjson a "$(ex stdout_objects)" --argjson b "$(jsonl_to_array "$C/stdout")" "$JQ_DEFS subset(\$a; \$b)" >/dev/null \
      || msgs+=("stdout objects do not match expected shape (got $(jsonl_to_array "$C/stdout" | head -c 600))")
  fi
  if has output_contains; then
    while IFS= read -r s; do grep -qF -- "$s" "$C/output" || msgs+=("log lacks: $s"); done < <(jq -r '.output_contains[]' <<<"$X")
  fi
  if has output_not_contains; then
    while IFS= read -r s; do grep -qF -- "$s" "$C/output" && msgs+=("log should not contain: $s"); done < <(jq -r '.output_not_contains[]' <<<"$X")
  fi
  if has claude_called; then
    local called=false; [ -e "$L/claude_args.json" ] && called=true
    [ "$called" = "$(ex claude_called)" ] || msgs+=("claude called: expected $(ex claude_called), got $called")
  fi
  if has claude_prompt && [ -e "$L/claude_args.json" ]; then
    local wc cap login want
    wc="$(jq -r '.claude_prompt.wip_count' <<<"$X")"; cap="$(jq -r '.claude_prompt.wip_cap' <<<"$X")"
    login="$(jq -r '.claude_prompt.scout_login // "nsega"' <<<"$X")"   # the mock gh login
    want="$(jq -nc --arg p "$(cat "$WORK/skill/prompt.md")

WIP_COUNT=$wc
WIP_CAP=$cap
SCOUT_LOGIN=$login" '["-p", $p, "--tools", "", "--max-turns", "15", "--output-format", "text"]')"
    [ "$want" = "$(cat "$L/claude_args.json")" ] \
      || msgs+=("claude argv differs from prompt.md + WIP_COUNT=$wc/WIP_CAP=$cap/SCOUT_LOGIN=$login + --tools \"\" (got tail: $(jq -c '.[2:]' "$L/claude_args.json"), prompt tail: $(jq -r '.[1][-60:]' "$L/claude_args.json" | tr '\n' '|'))")
  fi
  if has claude_stdin_issues; then
    local got='[]'; [ -e "$L/claude_stdin" ] && got="$(jsonl_to_array "$L/claude_stdin" | jq -c '[.[] | .issue]')"
    [ "$got" = "$(ex claude_stdin_issues)" ] || msgs+=("claude stdin issues: expected $(ex claude_stdin_issues), got $got")
  fi
  if has claude_stdin_objects; then
    local got='[]'; [ -e "$L/claude_stdin" ] && got="$(jsonl_to_array "$L/claude_stdin")"
    jq -en --argjson a "$(ex claude_stdin_objects)" --argjson b "$got" "$JQ_DEFS subset(\$a; \$b)" >/dev/null \
      || msgs+=("claude stdin objects differ from expected (got $(head -c 600 <<<"$got"))")
  fi
  if has claude_stdin_keys; then
    local got='[]'; [ -e "$L/claude_stdin" ] && got="$(jsonl_to_array "$L/claude_stdin" | jq -c 'map(keys)')"
    [ "$got" = "$(ex claude_stdin_keys)" ] || msgs+=("claude stdin keys: expected $(ex claude_stdin_keys), got $got")
  fi
  if has queue_issues; then
    local got; got="$(jq -c '[.[] | .issue]' "$S/queue.json" 2>/dev/null || echo '"unreadable"')"
    [ "$got" = "$(ex queue_issues)" ] || msgs+=("queue: expected $(ex queue_issues), got $got")
  fi
  if has queue; then
    jq -en --argjson a "$(ex queue)" --slurpfile b "$S/queue.json" "$JQ_DEFS subset(\$a; \$b[0])" >/dev/null 2>&1 \
      || msgs+=("queue contents differ (got $(jq -c . "$S/queue.json" 2>/dev/null | head -c 700))")
  fi
  if has queue_unchanged; then
    cmp -s "$S/queue.json" "$C/initial.queue.json" || msgs+=("queue.json should be byte-for-byte unchanged")
  fi
  if has seen; then
    local got; got="$(jq -c 'sort' "$S/seen.json" 2>/dev/null || echo '"missing"')"
    [ "$got" = "$(ex seen | jq -c 'sort')" ] || msgs+=("seen: expected $(ex seen | jq -c sort), got $got")
  fi
  if has tasks_created; then
    local got='[]'
    [ -s "$L/todoist_posts.jsonl" ] && got="$(jq -sc '[.[] | .content | capture("Contribute: \\[(?<i>[^\\]]+)\\]").i]' "$L/todoist_posts.jsonl")"
    [ "$got" = "$(ex tasks_created)" ] || msgs+=("tasks created: expected $(ex tasks_created), got $got")
  fi
  if has task_objects; then
    local got='[]'; [ -s "$L/todoist_posts.jsonl" ] && got="$(jq -sc . "$L/todoist_posts.jsonl")"
    jq -en --argjson a "$(ex task_objects)" --argjson b "$got" "$JQ_DEFS subset(\$a; \$b)" >/dev/null \
      || msgs+=("task bodies differ (got $(head -c 500 <<<"$got"))")
  fi
  if has tasks_closed; then
    local got='[]'; [ -s "$L/todoist_closed" ] && got="$(jq -Rsc 'split("\n") | map(select(length > 0)) | sort' "$L/todoist_closed")"
    [ "$got" = "$(ex tasks_closed | jq -c sort)" ] || msgs+=("tasks closed: expected $(ex tasks_closed), got $got")
  fi
  stamp_check() {  # $1 file, $2 expectation
    local f="$S/$1" init="$C/initial.$1"
    case "$2" in
      '"absent"') [ ! -e "$f" ] || msgs+=("$1: expected absent, found $(cat "$f")") ;;
      '"unchanged"')
        if [ -e "$init" ]; then cmp -s "$f" "$init" || msgs+=("$1: expected unchanged, was $(cat "$init"), now $(cat "$f" 2>/dev/null)")
        else [ ! -e "$f" ] || msgs+=("$1: expected unchanged (absent), now $(cat "$f")"); fi ;;
      '"advanced"')
        if [ ! -e "$f" ]; then msgs+=("$1: expected advanced, file absent")
        elif [ -e "$init" ] && cmp -s "$f" "$init"; then msgs+=("$1: expected advanced, unchanged")
        elif [ "$1" = last_reeval ]; then
          local v; v="$(cat "$f")"; [[ "$v" =~ ^[0-9]+$ ]] && (( v >= t0 )) || msgs+=("last_reeval: not a fresh epoch stamp ($v)")
        else grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$f" || msgs+=("$1: not an ISO stamp ($(cat "$f"))"); fi ;;
      '"present"') [ -e "$f" ] || msgs+=("$1: expected present") ;;
    esac
  }
  has last_run && stamp_check last_run "$(ex last_run)"
  has last_run_pending && stamp_check last_run.pending "$(ex last_run_pending)"
  has last_reeval && stamp_check last_reeval "$(ex last_reeval)"
  if has since_param; then
    # Every issues-LIST call must use the expected `since` (the stored window).
    local want; want="$(jq -r '.since_param' <<<"$X")"
    [ "$want" = "<last_run>" ] && want="$(cat "$C/initial.last_run")"
    if [ ! -s "$L/since" ]; then msgs+=("since: no issues-list call recorded")
    elif [ "$want" = "<24h_ago>" ]; then
      # First run: the window opens 24h before the run (allow 15 minutes of slack).
      cut -f2 "$L/since" | jq -Rse --argjson t "$t0" 'split("\n") | map(select(length > 0))
          | length > 0 and all(.[]; (fromdateiso8601 - ($t - 86400)) | fabs < 900)' >/dev/null \
        || msgs+=("since: expected ~24h before the run, got $(cut -f2 "$L/since" | sort -u | tr '\n' ' ')")
    else awk -F'\t' -v w="$want" '$2 != w {bad=1} END {exit bad}' "$L/since" || msgs+=("since: expected $want, got $(cut -f2 "$L/since" | sort -u | tr '\n' ' ')"); fi
  fi
  if has gh_call_counts; then
    while IFS=$'\t' read -r pat want; do
      local got; got="$(jq -r 'join(" ")' "$L/gh_calls.jsonl" 2>/dev/null | grep -cF -- "$pat")"
      [ "$got" = "$want" ] || msgs+=("gh calls matching '$pat': expected $want, got $got")
    done < <(jq -r '.gh_call_counts | to_entries[] | "\(.key)\t\(.value)"' <<<"$X")
  fi
  if has sequence_before; then
    while IFS=$'\t' read -r a b; do
      local ia ib; ia="$(grep -n -m1 -x "$a" "$L/sequence" 2>/dev/null | cut -d: -f1)"; ib="$(grep -n -m1 -x "$b" "$L/sequence" 2>/dev/null | cut -d: -f1)"
      [ -n "$ia" ] && [ -n "$ib" ] && (( ia < ib )) || msgs+=("sequence: $a should precede $b (got $(tr '\n' ' ' < "$L/sequence" 2>/dev/null))")
    done < <(jq -r '.sequence_before[] | "\(.[0])\t\(.[1])"' <<<"$X")
  fi
  if has git_subject; then
    local subj; subj="$(GIT_CONFIG_GLOBAL="$WORK/gitconfig" git -C "$S" log -1 --pretty=%s 2>/dev/null)"
    grep -qE -- "$(jq -r '.git_subject' <<<"$X")" <<<"$subj" || msgs+=("state commit subject: got '$subj'")
  fi
  if has git_pushed && [ "$(ex git_pushed)" = true ]; then
    [ "$(git -C "$C/remote.git" log -1 --pretty=%s 2>/dev/null)" = "$(git -C "$S" log -1 --pretty=%s)" ] || msgs+=("state commit not pushed")
  fi
  if has files_absent; then
    while IFS= read -r f; do [ ! -e "$S/$f" ] || msgs+=("state file should not exist: $f"); done < <(jq -r '.files_absent[]' <<<"$X")
  fi

  local div; div="$(jq -r '.divergence // empty' "$cf")"
  if [ ${#msgs[@]} -eq 0 ]; then
    PASS=$((PASS+1))
    if [ -n "$div" ]; then XPASS=$((XPASS+1)); echo "PASS  $id  [tagged divergence $div now matches the doc]"
    else echo "PASS  $id"; fi
  else
    FAIL=$((FAIL+1))
    local joined; joined="$(printf '%s; ' "${msgs[@]}")"; joined="${joined%; }"
    if [ -n "$div" ]; then KNOWN=$((KNOWN+1)); echo "FAIL  $id  [known divergence $div]  ${joined}"
    else FAILED_UNKNOWN+=("$id"); echo "FAIL  $id  ${joined}"; fi
    if (( VERBOSE )); then sed 's/^/      | /' "$C/output" | head -40; fi
  fi
}

for cf in "$FIX"/fetch/*.json "$FIX"/route/*.json "$FIX"/reeval/*.json; do
  [ -f "$cf" ] || continue
  if [ -n "$ONLY" ]; then jq -r '.id' "$cf" | grep -qE -- "$ONLY" || continue; fi
  run_case "$cf"
done

TOTAL=$((PASS+FAIL))
echo "summary: $TOTAL cases, $PASS passed, $FAIL failed ($KNOWN known divergences, ${#FAILED_UNKNOWN[@]} other)"
if (( FAIL == 0 )); then exit 0; fi
if (( ALLOW_KNOWN )) && (( ${#FAILED_UNKNOWN[@]} == 0 )); then
  echo "note: only known divergences failed (--allow-known), exiting 0"; exit 0
fi
exit 1
