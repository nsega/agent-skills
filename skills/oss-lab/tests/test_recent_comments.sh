#!/usr/bin/env bash
# The scorer can only catch a claim made in a comment if the claim reaches it.
# oss_lab_attach_comments gives it the last three comments of each thread.
# These cases pin two things that used to hide a late claim:
#   - a long body is cut in the middle, not at the end, so a claim at either
#     end ("I'll take this. ..." or "... Anyway, I'll take this one.") survives;
#   - "the last three" means the newest three even past GitHub's default page
#     of 30, where the first page alone would have shown comments 28-30.
# shellcheck disable=SC2015,SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
source "$HERE/../scripts/lib.sh"   # only defines functions and defaults

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; build_mockbin "$MOCKBIN"
mkdir -p "$WORK/log"

# attach <comments-array-json>: run oss_lab_attach_comments on one shaped
# issue whose thread is that array, and print its recent_comments.
attach() {
  local n; n="$(jq length <<<"$1")"
  jq -n --argjson c "$1" '{"kubernetes-sigs/kueue#10": $c}' > "$WORK/comments.json"
  (
    export PATH="$MOCKBIN:$PATH" MOCK_COMMENTS_JSON="$WORK/comments.json" MOCK_LOG="$WORK/log"
    jq -nc --argjson n "$n" \
      '{issue: "kubernetes-sigs/kueue#10", repo: "kubernetes-sigs/kueue", number: 10, comments: $n}' \
      | oss_lab_attach_comments
  ) | jq -c '.recent_comments'
}

thread() {  # thread <count>: comments whose bodies are c1..c<count>
  jq -nc --argjson n "$1" '[range(1; $n + 1) | {user: {login: "u\(.)"}, body: "c\(.)"}]'
}

FILLER="$(printf 'x%.0s' $(seq 1 300))"

# 1: a claim at the END of a long comment survives.
rc="$(attach "$(jq -nc --arg b "Some context. $FILLER Anyway, I'll take this one." '[{user: {login: "a"}, body: $b}]')")"
body="$(jq -r '.[0].body' <<<"$rc")"
grep -q "I'll take this one" <<<"$body" && ok || bad "tail claim: a claim at the end of a long comment must reach the scorer, got: $body"
grep -q '^Some context' <<<"$body" && ok || bad "tail claim: the start of the comment must be kept too, got: $body"
[ "${#body}" -le 250 ] && ok || bad "tail claim: a long body must stay bounded (got ${#body} chars)"

# 2: a claim at the START of a long comment survives.
rc="$(attach "$(jq -nc --arg b "I'll take this one. $FILLER trailing detail" '[{user: {login: "a"}, body: $b}]')")"
body="$(jq -r '.[0].body' <<<"$rc")"
grep -q "^I'll take this one" <<<"$body" && ok || bad "head claim: a claim at the start must reach the scorer, got: $body"
grep -q 'trailing detail$' <<<"$body" && ok || bad "head claim: the end of the comment must be kept too, got: $body"

# 3: a short comment is passed through whole.
rc="$(attach '[{"user":{"login":"a"},"body":"working on it"}]')"
[ "$(jq -r '.[0].body' <<<"$rc")" = "working on it" ] && ok || bad "short: a short body must be unchanged, got: $rc"
[ "$(jq -r '.[0].author' <<<"$rc")" = "a" ] && ok || bad "short: the author must be kept, got: $rc"

# 4: 35 comments, past GitHub's default page of 30: the newest three.
rc="$(attach "$(thread 35)")"
[ "$(jq -c 'map(.body)' <<<"$rc")" = '["c33","c34","c35"]' ] && ok \
  || bad "35 comments: must show the newest three, got: $(jq -c 'map(.body)' <<<"$rc")"

# 5: 101 comments: the last page holds one, so the page before supplies the rest.
rc="$(attach "$(thread 101)")"
[ "$(jq -c 'map(.body)' <<<"$rc")" = '["c99","c100","c101"]' ] && ok \
  || bad "101 comments: must show the newest three across a page break, got: $(jq -c 'map(.body)' <<<"$rc")"

# 6: exactly 100 comments: one full page.
rc="$(attach "$(thread 100)")"
[ "$(jq -c 'map(.body)' <<<"$rc")" = '["c98","c99","c100"]' ] && ok \
  || bad "100 comments: must show the newest three, got: $(jq -c 'map(.body)' <<<"$rc")"

summary "recent comments"
