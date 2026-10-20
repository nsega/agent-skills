#!/usr/bin/env python3
"""Generate the oss-lab regression fixtures ({fetch,route,reeval}/*.json here).

All data is synthetic: issue numbers are in the 900000 range, titles, bodies
and comment authors ("fixture-user-*") are invented. The only real handle is
"nsega", the scout's own login, which the skill's own tests already use.

Every case states, next to its inputs:
  covers      ids of the behaviours the case covers
  contract    the SKILL.md / prompt.md statement that defines the behaviour
  code        the implementing branch (path:line at f80c96d)
  expected    the expected outcome in prose
  expect      the same outcome as machine-checked assertions (../test_fixtures.sh)
  divergence  (optional) finding id when the documented contract and the code
              disagree; the expectation follows the documentation.

Run:  python3 generate_fixtures.py   (rewrites the case files)
"""
import itertools
import json
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
K = "kubernetes/kubernetes"
Q = "kubernetes-sigs/kueue"
G = "kubernetes-sigs/gateway-api-inference-extension"
CASES = {"fetch": [], "route": [], "reeval": []}


def iid(repo, n):
    return f"{repo}#{n}"


def raw(repo, n, title=None, labels=(), assignees=(), comments=0, body=None,
        pr=False, state="open"):
    """A raw GitHub REST issue object, shaped as the issues API returns it."""
    o = {
        "number": n,
        "title": title or f"Synthetic issue {n}",
        "state": state,
        "user": {"login": "fixture-user-reporter"},
        "assignees": [{"login": a} for a in assignees],
        "labels": [{"name": l} for l in labels],
        "comments": comments,
        "created_at": "2026-09-14T08:00:00Z",
        "updated_at": "2026-09-15T08:00:00Z",
        "html_url": f"https://github.com/{repo}/issues/{n}",
        "body": body if body is not None else "Synthetic fixture issue body.",
    }
    if pr:
        o["pull_request"] = {"url": f"https://api.github.com/repos/{repo}/pulls/{n}"}
    return o


def comment(author, body):
    return {"user": {"login": author}, "body": body}


_AXES = list(itertools.product(range(11), repeat=4))


def axes_for(wt):
    """Integer axis scores whose weighted sum is closest to wt (plausible output)."""
    best = min(_AXES, key=lambda a: (abs(0.3 * a[0] + 0.3 * a[1] + 0.2 * a[2] + 0.2 * a[3] - wt),
                                     -min(a)))
    return dict(zip(["okr_alignment", "consistency", "impact", "feasibility"], best))


def score(issue, wt, route, **extra):
    o = {"issue": issue}
    if wt is not None:
        o["scores"] = axes_for(wt)
        o["weighted_total"] = wt
    o["rationale_consistency"] = extra.pop("rationale", f"synthetic rationale for {issue}")
    o["route"] = route
    o.update(extra)
    return o


def case(kind, cid, **kw):
    d = {"id": f"{kind}/{cid}"}
    d.update(kw)
    CASES[kind].append(d)


# =========================================================================
# FETCH (fetch-issues.sh run directly; stdout is the scorer input JSONL)
# =========================================================================
FETCH_CONTRACT_FILTERS = ("SKILL.md:25-28 'gh api pulls new open issues from the target repos, filters out "
                          "assigned / stale / excluded-label issues and any issue that already has a linked "
                          "pull request, and deduplicates against seen.json'; SKILL.md:60-61")

case("fetch", "01-assignee-filtered",
     covers=["F1"], run="fetch",
     contract=FETCH_CONTRACT_FILTERS + " 'Issues with an assignee ... are hard-filtered before scoring'",
     code="skills/oss-lab/scripts/fetch-issues.sh:67",
     why="An assigned issue is someone's claimed work. Assignment to the scout's own login is still an assignee.",
     expected="Only the unassigned issue survives; the issues assigned to another user and to nsega are filtered.",
     upstream={"list": {Q: [raw(Q, 900101, "Clean unassigned issue"),
                            raw(Q, 900102, "Assigned to someone else", assignees=["fixture-user-a"]),
                            raw(Q, 900103, "Assigned to the scout owner", assignees=["nsega"])]}},
     expect={"rc": 0, "stdout_issues": [iid(Q, 900101)], "last_run_pending": "present"})

case("fetch", "02-excluded-labels",
     covers=["F2"], run="fetch",
     contract=FETCH_CONTRACT_FILTERS,
     code="skills/oss-lab/scripts/fetch-issues.sh:24-28,68",
     why="lifecycle/stale, lifecycle/rotten and triage/unresolved disqualify an issue; other labels, "
         "including other lifecycle/* labels, do not.",
     expected="900204 (lifecycle/frozen + kind/flake) and 900205 (no labels) survive; 900201-900203 are filtered.",
     upstream={"list": {Q: [raw(Q, 900201, labels=["lifecycle/stale"]),
                            raw(Q, 900202, labels=["kind/bug", "lifecycle/rotten"]),
                            raw(Q, 900203, labels=["triage/unresolved"]),
                            raw(Q, 900204, labels=["lifecycle/frozen", "kind/flake"]),
                            raw(Q, 900205)]}},
     expect={"rc": 0, "stdout_issues": [iid(Q, 900204), iid(Q, 900205)]})

case("fetch", "03-linked-pr-per-repo",
     covers=["F3"], run="fetch",
     contract=FETCH_CONTRACT_FILTERS + "; SKILL.md:197-200 (claim detection via the search API, linked:pr)",
     code="skills/oss-lab/scripts/fetch-issues.sh:52,69; skills/oss-lab/scripts/lib.sh:170-190",
     why="An issue with a linked PR is taken. The linked set is per repository: kueue#900301 having a PR "
         "must not filter kubernetes#900301.",
     expected="kueue#900301 is filtered; kubernetes#900301 and kueue#900302 survive. One linked:pr search per repo.",
     upstream={"list": {K: [raw(K, 900301)], Q: [raw(Q, 900301), raw(Q, 900302)]},
               "linked": {Q: [900301, 900999]}},
     expect={"rc": 0, "stdout_issues": [iid(K, 900301), iid(Q, 900302)],
             "gh_call_counts": {"search/issues": 3, "linked:pr": 3}})

case("fetch", "04-seen-dedup",
     covers=["F4"], run="fetch",
     contract=FETCH_CONTRACT_FILTERS,
     code="skills/oss-lab/scripts/fetch-issues.sh:70",
     why="An issue already scored once (in seen.json) is never re-scored by the hourly loop.",
     expected="kueue#900401 (in seen.json) is filtered; kueue#900402 survives; seen.json is not modified by the fetch.",
     state={"seen": [iid(Q, 900401), iid(K, 900499)]},
     upstream={"list": {Q: [raw(Q, 900401), raw(Q, 900402)]}},
     expect={"rc": 0, "stdout_issues": [iid(Q, 900402)], "seen": [iid(Q, 900401), iid(K, 900499)]})

case("fetch", "05-pull-requests-excluded",
     covers=["F5"], run="fetch",
     contract="SKILL.md:25 'pulls new open issues' (the issues endpoint also lists PRs; only issues are candidates)",
     code="skills/oss-lab/scripts/fetch-issues.sh:55",
     why="GitHub's issues list includes pull requests; they are not contribution candidates.",
     expected="The PR entry kueue#900501 is dropped; the issue kueue#900502 survives.",
     upstream={"list": {Q: [raw(Q, 900501, "A pull request", pr=True), raw(Q, 900502)]}},
     expect={"rc": 0, "stdout_issues": [iid(Q, 900502)]})

case("fetch", "06-all-repos-combined",
     covers=["F1", "F2", "F3", "F4", "F5", "F11", "F12"], run="fetch",
     contract=FETCH_CONTRACT_FILTERS + "; prompt.md:20-22 (the three target repos); SKILL.md:57-59 'Read-only upstream'",
     code="skills/oss-lab/scripts/fetch-issues.sh:17-21,47-75",
     why="All three target repos are scanned in order, every filter applies, and every GitHub call is a read.",
     expected="Survivors, in repo order: kubernetes#900601, kueue#900611, gaie#900621. "
              "No gh call is a write (checked for every case).",
     state={"seen": [iid(G, 900622)]},
     upstream={"list": {
         K: [raw(K, 900601, labels=["sig/scheduling", "kind/flake"]), raw(K, 900602, assignees=["fixture-user-b"])],
         Q: [raw(Q, 900611, labels=["area/testing"]), raw(Q, 900612, labels=["lifecycle/stale"]),
             raw(Q, 900613, pr=True)],
         G: [raw(G, 900621), raw(G, 900622), raw(G, 900623)]},
         "linked": {G: [900623]}},
     expect={"rc": 0, "stdout_issues": [iid(K, 900601), iid(Q, 900611), iid(G, 900621)],
             "gh_call_counts": {"search/issues": 3, f"repos/{K}/issues": 1, f"repos/{Q}/issues": 1,
                                f"repos/{G}/issues": 1}})

LONG_BODY = ("Synthetic body paragraph. " * 80)[:2000]
case("fetch", "07-scorer-input-shape",
     covers=["F9"], run="fetch",
     contract="prompt.md:4-6 'one issue per line, each carrying an `issue` identifier plus its title, labels, and body'; "
              "SKILL.md:101-104 (re-score input is shaped exactly as fetch-issues.sh shapes a new issue)",
     code="skills/oss-lab/scripts/lib.sh:314-330,341-343",
     why="The scorer sees issue/title/labels/body (plus comments count, created_at, url); body is capped at 1500 "
         "characters; internal plumbing (number, repo) is stripped.",
     expected="One line: {issue, title, labels:[names], comments:0, created_at, url, body[0:1500]} with no number/repo "
              "and no recent_comments (no comments).",
     upstream={"list": {Q: [raw(Q, 900701, "Shape check", labels=["area/testing", "kind/flake"], body=LONG_BODY)]}},
     expect={"rc": 0, "stdout_objects": [{
         "issue": iid(Q, 900701), "title": "Shape check", "labels": ["area/testing", "kind/flake"],
         "comments": 0, "created_at": "2026-09-14T08:00:00Z", "url": f"https://github.com/{Q}/issues/900701",
         "body": LONG_BODY[:1500], "number": "<absent>", "repo": "<absent>", "recent_comments": "<absent>"}]})

case("fetch", "08-comments-ride-along",
     covers=["F7"], run="fetch",
     contract="SKILL.md:28-29 'Comment threads ride along so the scorer can see a claim that left no assignee and no PR'; "
              "prompt.md:102-103 'a recent_comments array (author plus the tail of each comment)'",
     code="skills/oss-lab/scripts/lib.sh:336-358",
     why="Only issues with comments cost a comments call; the newest three comments are attached as {author, body} "
         "with whitespace collapsed.",
     expected="kueue#900801 carries recent_comments = the last 3 of its 5 comments (whitespace collapsed); "
              "kueue#900802 (0 comments) has no recent_comments; exactly one comments call.",
     upstream={"list": {Q: [raw(Q, 900801, comments=5), raw(Q, 900802)]},
               "comments": {iid(Q, 900801): [
                   comment("fixture-user-a", "first comment"),
                   comment("fixture-user-b", "second comment"),
                   comment("fixture-user-c", "Is this\nstill reproducible\ton main?"),
                   comment("fixture-user-d", "Yes,   it fails about\n\n1 in 20 runs."),
                   comment("fixture-user-e", "/triage accepted")]}},
     expect={"rc": 0, "stdout_issues": [iid(Q, 900801), iid(Q, 900802)],
             "stdout_objects": [
                 {"issue": iid(Q, 900801), "recent_comments": [
                     {"author": "fixture-user-c", "body": "Is this still reproducible on main?"},
                     {"author": "fixture-user-d", "body": "Yes, it fails about 1 in 20 runs."},
                     {"author": "fixture-user-e", "body": "/triage accepted"}]},
                 {"issue": iid(Q, 900802), "recent_comments": "<absent>"}],
             "gh_call_counts": {"/comments": 1}})

case("fetch", "09-comments-garbage-response",
     covers=["F8"], run="fetch",
     contract="SKILL.md:28-29 (comment threads ride along); code comment lib.sh:351-354 'One odd comment thread must not cost the window'",
     code="skills/oss-lab/scripts/lib.sh:347-356",
     why="A comments call that answers 0 with non-JSON must degrade to an empty thread, not kill the batch.",
     expected="Both issues are emitted; kueue#900901 has recent_comments [] .",
     upstream={"list": {Q: [raw(Q, 900901, comments=2), raw(Q, 900902)]},
               "comments": {iid(Q, 900901): "garbage"}},
     expect={"rc": 0, "stdout_issues": [iid(Q, 900901), iid(Q, 900902)],
             "stdout_objects": [{"issue": iid(Q, 900901), "recent_comments": []},
                                {"issue": iid(Q, 900902)}]})

CLAIM_TAIL = ("Some background on the failure first. " * 8) + "Anyway, I'll take this one and open a PR on Friday."
case("fetch", "10-comment-tail-keeps-late-claim",
     covers=["F7"], run="fetch",
     contract="prompt.md Claimed work 'A body over 240 characters keeps its start and end with \" … \" between them'",
     code="F6 at f80c96d: lib.sh:349 (`.[0:240]`, the HEAD of each comment). Fixed in nsega/agent-skills#21 "
          "(first and last 120 characters)",
     why="A soft claim at the end of a long comment is exactly what recent_comments exists to surface; at f80c96d the "
         "code kept only the first 240 characters, so the claim never reached the scorer.",
     expected="The attached body keeps the first and last 120 characters, so it ends with the claim sentence.",
     upstream={"list": {Q: [raw(Q, 901001, comments=1)]},
               "comments": {iid(Q, 901001): [comment("fixture-user-f", CLAIM_TAIL)]}},
     expect={"rc": 0, "stdout_objects": [{"issue": iid(Q, 901001), "recent_comments": [
         {"author": "fixture-user-f", "body": CLAIM_TAIL[:120] + " … " + CLAIM_TAIL[-120:]}]}]})

case("fetch", "11-linked-search-fails-soft",
     covers=["F6"], run="fetch",
     contract="SKILL.md:197-202 (claim detection through the search API); fail-soft is stated in the code comment "
              "fetch-issues.sh:48-51 ('a degraded search must not cost the whole window')",
     code="skills/oss-lab/scripts/lib.sh:179-187",
     why="A failed linked:pr search degrades the claim filter with a warning; the fetch still emits its window.",
     expected="Warning 'linked-PR search failed for kubernetes-sigs/kueue, claim filter degraded'; both kueue issues "
              "are emitted (the scorer still sees comments); exit 0.",
     upstream={"list": {Q: [raw(Q, 901101), raw(Q, 901102)]}, "search_fail": [Q], "linked": {Q: [901101]}},
     expect={"rc": 0, "stdout_issues": [iid(Q, 901101), iid(Q, 901102)],
             "output_contains": ["warn: linked-PR search failed for kubernetes-sigs/kueue, claim filter degraded"]})

case("fetch", "12-window-resumes-from-last-run",
     covers=["F10"], run="fetch",
     contract="SKILL.md:41-42 'seen.json and last_run advance so the next window resumes cleanly'",
     code="skills/oss-lab/scripts/fetch-issues.sh:36-42,77",
     why="The fetch window starts at the stored last_run. The fetch itself only writes last_run.pending (the runner "
         "commits it), and it initialises missing state files.",
     expected="Every issues-list call uses since=2026-09-15T09:00:00Z; last_run is unchanged; last_run.pending holds "
              "a fresh ISO timestamp; seen.json and queue.json are created as [].",
     state={"last_run": "2026-09-15T09:00:00Z"},
     upstream={"list": {Q: [raw(Q, 901201)]}},
     expect={"rc": 0, "since_param": "<last_run>", "last_run": "unchanged", "last_run_pending": "advanced",
             "seen": [], "queue": []})

case("fetch", "13-first-run-24h-lookback",
     covers=["F10"], run="fetch",
     contract="SKILL.md:41-42; first-run default stated in fetch-issues.sh:34 ('Default lookback: 24h on first run')",
     code="skills/oss-lab/scripts/fetch-issues.sh:36-38",
     why="With no last_run the window starts 24 hours ago.",
     expected="since is within 15 minutes of now-24h on every issues-list call.",
     upstream={"list": {}},
     expect={"rc": 0, "since_param": "<24h_ago>", "stdout_issues": []})

# =========================================================================
# GUARD + ROUTE (run-scout.sh end to end, weekly pass kept out via a fresh stamp)
# =========================================================================
def two_ids(*nums, repo=Q):
    return [iid(repo, n) for n in nums]


case("route", "01-guard-nothing-survives",
     covers=["G1"], run="scout",
     contract="SKILL.md:30 'Guard: if nothing survives, exit before Claude starts'",
     code="skills/oss-lab/scripts/run-scout.sh:54-59",
     why="All upstream issues are filtered, so the paid step must not run; the window still advances.",
     expected="'no new issues, claude not invoked'; claude never called; last_run advanced; seen/queue unchanged; exit 0.",
     upstream={"list": {Q: [raw(Q, 902001, assignees=["fixture-user-a"]), raw(Q, 902002, labels=["lifecycle/rotten"])]},
               "linked": {K: [902003]}},
     state={"last_run": "2026-09-15T09:00:00Z"},
     expect={"rc": 0, "output_contains": ["no new issues, claude not invoked"], "claude_called": False,
             "last_run": "advanced", "last_run_pending": "absent", "seen": [], "queue": []})

case("route", "02-guard-all-seen",
     covers=["G1", "F4"], run="scout",
     contract="SKILL.md:27-30",
     code="skills/oss-lab/scripts/fetch-issues.sh:70; skills/oss-lab/scripts/run-scout.sh:54-59",
     why="Issues updated upstream after being scored come back in the window but are deduplicated, so nothing is paid for.",
     expected="claude not called; seen unchanged; last_run advanced.",
     state={"seen": two_ids(902011, 902012)},
     upstream={"list_ids": two_ids(902011, 902012)},
     expect={"rc": 0, "claude_called": False, "seen": two_ids(902011, 902012), "last_run": "advanced"})

B = two_ids(902101, 902102, 902103, 902104)
case("route", "10-threshold-boundaries",
     covers=["R1", "R2", "R3", "R5", "S1", "T1"], run="scout",
     contract="SKILL.md:88 'Routing: weighted ≥ 7.0 → task manager · 5.0–6.9 → queue · < 5.0 → drop.'; prompt.md:118-120; "
              "SKILL.md:31-36 (scorer runs with --tools \"\"); SKILL.md:92-93 ($WIP_CAP passed to the scorer); "
              "SKILL.md:41-42 (seen.json and last_run advance)",
     code="skills/oss-lab/scripts/run-scout.sh:80-87,114-143,145-154",
     why="Boundary scores 7.0 / 6.9 / 5.0 / 4.9, routed consistently by the scorer. Also pins the exact claude argv "
         "(prompt.md + WIP_COUNT/WIP_CAP, --tools \"\") and that every scored issue becomes seen.",
     expected="7.0 -> task; 6.9 and 5.0 -> queue (highest first); 4.9 -> recorded in seen only. seen = prior entry + all 4. "
              "'iteration complete: 4 scored, 1 tasked, 2 queued, WIP=0'.",
     state={"seen": [iid(K, 902199)]},
     upstream={"list_ids": B},
     todoist={"wip": 0},
     claude={"out": [score(B[0], 6.9, "queue"), score(B[1], 4.9, "drop"), score(B[2], 7.0, "todoist"),
                     score(B[3], 5.0, "queue")]},
     expect={"rc": 0, "claude_prompt": {"wip_count": 0, "wip_cap": 5}, "claude_stdin_issues": B,
             "tasks_created": [B[2]], "queue_issues": [B[0], B[3]],
             "seen": [iid(K, 902199)] + B, "last_run": "advanced",
             "output_contains": ["iteration complete: 4 scored, 1 tasked, 2 queued, WIP=0"]})

case("route", "11-task-format",
     covers=["R10"], run="scout",
     contract="SKILL.md:37-38 (high scores become tasks); SKILL.md:75-77 (routing to the task manager is where automation stops)",
     code="skills/oss-lab/scripts/lib.sh:122-135",
     why="Pins the Todoist payload: markdown-link title with the score, rationale as description, project and oss-lab label "
         "(the label is what the WIP count and revalidation key on).",
     expected="One POST /tasks with content 'Contribute: [kubernetes-sigs/kueue#902111](https://github.com/kubernetes-sigs/kueue/issues/902111) (score 8.2)'.",
     upstream={"list_ids": [iid(Q, 902111)]},
     todoist={"wip": 1},
     claude={"out": [score(iid(Q, 902111), 8.2, "todoist", rationale="Extends the LWS e2e line.")]},
     expect={"rc": 0, "task_objects": [{
         "content": f"Contribute: [{iid(Q, 902111)}](https://github.com/{Q}/issues/902111) (score 8.2)",
         "description": "Extends the LWS e2e line.", "project_id": "fixture-project", "labels": ["oss-lab"]}]})

W = two_ids(902121, 902122, 902123, 902124)
case("route", "12-wip-cap-overflow-order",
     covers=["W1", "W2"], run="scout",
     contract="SKILL.md:39-40 'The runner enforces the WIP budget itself ... spending it on the highest scores first'; "
              "SKILL.md:91 'overflow demotes to queue'; prompt.md:123-128",
     code="skills/oss-lab/scripts/run-scout.sh:107-122,143",
     why="WIP 3 of 5 leaves a budget of 2. The scorer (wrongly) routes four issues to todoist, in an order that is not "
         "score order; the runner must spend the budget on the two highest and demote the rest with wip_capped.",
     expected="Tasks for 9.1 then 8.4; 7.2 and 7.0 queued (in that order) with wip_capped=true.",
     upstream={"list_ids": W},
     todoist={"wip": 3},
     claude={"out": [score(W[0], 7.2, "todoist"), score(W[1], 9.1, "todoist"), score(W[2], 7.0, "todoist"),
                     score(W[3], 8.4, "todoist")]},
     expect={"rc": 0, "claude_prompt": {"wip_count": 3, "wip_cap": 5}, "tasks_created": [W[1], W[3]],
             "queue": [{"issue": W[0], "weighted_total": 7.2, "wip_capped": True},
                       {"issue": W[2], "weighted_total": 7.0, "wip_capped": True}],
             "seen": W})

for cid, wip in (("13-wip-at-cap", 5), ("14-wip-above-cap", 7)):
    ids = two_ids(902130 + wip, 902140 + wip)
    case("route", cid,
         covers=["W3"], run="scout",
         contract="SKILL.md:91 'at most 5 active tasks'; prompt.md:127-128 'If WIP_COUNT is at or above WIP_CAP, demote them all. Never exceed the cap.'",
         code="skills/oss-lab/scripts/run-scout.sh:107-108,119-122",
         why=f"WIP_COUNT={wip} with cap 5: the budget is zero (never negative), so no task may be created.",
         expected="No task; both todoist-routed issues queued with wip_capped=true.",
         upstream={"list_ids": ids}, todoist={"wip": wip},
         claude={"out": [score(ids[0], 8.0, "todoist"), score(ids[1], 7.5, "todoist")]},
         expect={"rc": 0, "tasks_created": [], "claude_prompt": {"wip_count": wip, "wip_cap": 5},
                 "queue": [{"issue": ids[0], "wip_capped": True}, {"issue": ids[1], "wip_capped": True}]})

O = two_ids(902151, 902152)
case("route", "15-wip-cap-override",
     covers=["W4"], run="scout",
     contract="SKILL.md:91-94 'The cap lives in one place, OSS_LAB_WIP_CAP ... passed to the scorer as $WIP_CAP ... Override per run with the same variable.'",
     code="skills/oss-lab/scripts/lib.sh:14; skills/oss-lab/scripts/run-scout.sh:83-84,107",
     why="OSS_LAB_WIP_CAP=2 with WIP 1: budget 1, and the scorer is told WIP_CAP=2.",
     expected="claude argv ends 'WIP_COUNT=1\\nWIP_CAP=2'; one task (8.8); 7.7 queued with wip_capped.",
     env={"OSS_LAB_WIP_CAP": "2"},
     upstream={"list_ids": O}, todoist={"wip": 1},
     claude={"out": [score(O[0], 7.7, "todoist"), score(O[1], 8.8, "todoist")]},
     expect={"rc": 0, "claude_prompt": {"wip_count": 1, "wip_cap": 2}, "tasks_created": [O[1]],
             "queue": [{"issue": O[0], "wip_capped": True}]})

FB_TASKS = [{"id": f"fb{i}", "content": f"Contribute: [{iid(Q, 902160 + i)}](https://github.com/{Q}/issues/{902160 + i}) (score 7.4)",
             "labels": ["oss-lab"]} for i in range(4)] + \
           [{"id": "other1", "content": "Renew passport", "labels": []},
            {"id": "other2", "content": "Contribute: [kubernetes/kubernetes#902169](x) (score 9)", "labels": ["personal"]}]
F2 = two_ids(902171, 902172)
case("route", "16-wip-count-fallback",
     covers=["W5"], run="scout",
     contract="SKILL.md:91 (WIP cap counts active oss-lab tasks); fallback stated in lib.sh:101-105",
     code="skills/oss-lab/scripts/lib.sh:106-118",
     why="When the Todoist filter endpoint rejects the query, the count falls back to the project listing, counting only "
         "oss-lab-labelled tasks (the project also holds unrelated tasks).",
     expected="WIP=4 (not 6): budget 1, one task for the 8.0 issue, the 7.6 issue queued with wip_capped.",
     upstream={"list_ids": F2},
     todoist={"filter_fail": True, "tasks": FB_TASKS},
     claude={"out": [score(F2[0], 8.0, "todoist"), score(F2[1], 7.6, "todoist")]},
     expect={"rc": 0, "tasks_created": [F2[0]], "queue": [{"issue": F2[1], "wip_capped": True}],
             "output_contains": ["WIP=4"], "tasks_closed": []})

case("route", "17-todoist-down-aborts-before-claude",
     covers=["W6"], run="scout",
     contract="SKILL.md:39-40 (the runner enforces the WIP budget itself); never fail open to 0: lib.sh:101-105",
     code="skills/oss-lab/scripts/run-scout.sh:62-65",
     why="With the WIP count unknown the cap cannot be enforced, so the run aborts before the paid call and keeps the window.",
     expected="Exit 1, 'todoist unreachable, WIP count unknown (window not advanced)'; claude not called; last_run unchanged; seen unchanged.",
     state={"last_run": "2026-09-15T09:00:00Z"},
     upstream={"list_ids": [iid(Q, 902181)]}, todoist={"down": True},
     expect={"rc": 1, "claude_called": False, "last_run": "unchanged", "seen": [],
             "output_contains": ["abort: todoist unreachable, WIP count unknown (window not advanced)"]})

P = two_ids(902191, 902192)
case("route", "18-task-create-fails",
     covers=["W7"], run="scout",
     contract="SKILL.md:39-40 (budget spent on the highest scores first); failure handling in run-scout.sh:129-131 "
              "('A failed POST must not discard the paid score: queue it')",
     code="skills/oss-lab/scripts/run-scout.sh:126-134",
     why="A failed POST queues the issue and does not consume the budget, so the next candidate gets the slot.",
     expected="8.0 issue: POST fails, warned, queued. 7.5 issue: task created (budget 1 still free). Both seen.",
     upstream={"list_ids": P}, todoist={"wip": 4, "post_fail": [P[0]]},
     claude={"out": [score(P[0], 8.0, "todoist"), score(P[1], 7.5, "todoist")]},
     expect={"rc": 0, "tasks_created": [P[1]], "queue_issues": [P[0]], "seen": P,
             "output_contains": [f"warn: todoist create failed for {P[0]}, routing to queue instead"]})

CL = two_ids(902201, 902202)
case("route", "20-claim-routes-drop",
     covers=["C1"], run="scout",
     contract="SKILL.md:61-63 'a comment thread showing someone else taking the work routes the issue to drop whatever it scored'; prompt.md:108-111",
     code="skills/oss-lab/scripts/run-scout.sh:114-143 (route drop: recorded in seen only)",
     why="The scorer saw a soft claim in recent_comments and routed drop with claimed_by despite a high score.",
     expected="Claimed issue: no task, not queued, but seen. The other (queue) issue is queued.",
     upstream={"list": {Q: [raw(Q, 902201, comments=1), raw(Q, 902202)]},
               "comments": {iid(Q, 902201): [comment("fixture-user-g", "I'm working on this, PR coming soon.")]}},
     todoist={"wip": 0},
     claude={"out": [score(CL[0], 8.3, "drop", claimed_by="fixture-user-g"), score(CL[1], 6.0, "queue")]},
     expect={"rc": 0, "claude_stdin_objects": [
         {"issue": CL[0], "recent_comments": [{"author": "fixture-user-g", "body": "I'm working on this, PR coming soon."}]},
         {"issue": CL[1]}],
         "tasks_created": [], "queue_issues": [CL[1]], "seen": CL})

case("route", "21-claimed-but-routed-todoist",
     covers=["C2"], run="scout",
     contract="SKILL.md:61-63 'routes the issue to drop whatever it scored'; SKILL.md:186-189 (runner validates every scored object); "
              "the weekly pass enforces this in the runner (SKILL.md:105-106, run-reeval.sh:180-181)",
     code="F1 at f80c96d: run-scout.sh:116-127 (route taken from the model; claimed_by never read). Fixed in nsega/agent-skills#21 "
          "(oss_lab_route_scored)",
     why="A scorer that reports claimed_by but still writes route todoist. The weekly pass drops such an issue in the runner; "
         "the hourly pass trusts the route.",
     expected="Per SKILL.md: no task (claimed work is dropped whatever it scored); the issue is seen, not queued.",
     upstream={"list_ids": [iid(Q, 902211)]}, todoist={"wip": 0},
     claude={"out": [score(iid(Q, 902211), 8.5, "todoist", claimed_by="fixture-user-h")]},
     expect={"rc": 0, "tasks_created": [], "queue_issues": [], "seen": [iid(Q, 902211)]})

case("route", "22-low-score-routed-todoist",
     covers=["R4"], run="scout",
     contract="SKILL.md:37-38 'Route (bash): high scores become tasks, mid scores go to a re-evaluation queue, low scores are "
              "recorded and dropped'; SKILL.md:88; SKILL.md:186-189",
     code="F2 at f80c96d: run-scout.sh:116,124-140 (route taken from the model, score not consulted). Fixed in nsega/agent-skills#21 "
          "(oss_lab_route_scored routes by weighted_total)",
     why="The scorer writes route todoist on a 4.2. The documented routing is by score and the runner validates scored objects.",
     expected="Per SKILL.md: no task, not queued (score < 5.0), recorded in seen.",
     upstream={"list_ids": [iid(K, 902221)]}, todoist={"wip": 0},
     claude={"out": [score(iid(K, 902221), 4.2, "todoist")]},
     expect={"rc": 0, "tasks_created": [], "queue_issues": [], "seen": [iid(K, 902221)]})

V = two_ids(902231, 902232, 902233)
case("route", "23-tolerant-parse",
     covers=["V1", "V2"], run="scout",
     contract="SKILL.md:186-189 'The runner also validates every scored object before acting on it, so a malformed ... "
              "result cannot become a task or a seen.json entry'",
     code="skills/oss-lab/scripts/lib.sh:365-368",
     why="Prose and code fences around the JSONL are skipped; an object without route, an object whose issue is not a "
         "string, and a non-object line are rejected.",
     expected="Only kueue#902231 (queue) is acted on and seen; kueue#902232 (no route) and kueue#902233 (issue is a number) "
              "are not seen, queued or tasked.",
     upstream={"list_ids": V}, todoist={"wip": 0},
     claude={"out": ["Here are the scores:", "```json", score(V[0], 6.1, "queue"),
                     {"issue": V[1], "weighted_total": 7.9, "rationale_consistency": "x"},
                     {"issue": 902233, "weighted_total": 7.9, "route": "todoist"},
                     '["not", "an", "object"]', "```"]},
     expect={"rc": 0, "queue_issues": [V[0]], "tasks_created": [], "seen": [V[0]],
             "output_contains": ["iteration complete: 1 scored, 0 tasked, 1 queued"]})

H = iid(Q, 902249)
case("route", "24-hallucinated-issue",
     covers=["V3"], run="scout",
     contract="SKILL.md:186-189 '... so a malformed or hallucinated result cannot become a task or a seen.json entry'",
     code="F3 at f80c96d: lib.sh:365-368 (no check that .issue was in the batch); run-scout.sh:126,142. "
          "Fixed in nsega/agent-skills#20 (run-scout.sh keeps only ids in the fetched batch)",
     why="The scorer returns an object for an issue that was never in its input (here: an id an injected body could plant).",
     expected="Per SKILL.md: the hallucinated kueue#902249 becomes neither a task nor a seen entry; the real issue is queued.",
     upstream={"list_ids": [iid(Q, 902241)]}, todoist={"wip": 0},
     claude={"out": [score(iid(Q, 902241), 6.2, "queue"), score(H, 9.4, "todoist")]},
     expect={"rc": 0, "tasks_created": [], "queue_issues": [iid(Q, 902241)], "seen": [iid(Q, 902241)]})

case("route", "25-route-not-in-contract",
     covers=["V4"], run="scout",
     contract="prompt.md:96 '\"route\": \"todoist | queue | drop\"'; SKILL.md:186-189 (malformed result cannot become a seen.json entry); "
              "run-scout.sh:94-95 'If NOTHING parses, abort without advancing the window so the batch is retried'",
     code="F3 at f80c96d: lib.sh:366-367 (only .route != null); run-scout.sh:124-142 (unknown route falls through, id still seen). "
          "Fixed in nsega/agent-skills#20 (oss_lab_parse_scores enforces the route enum)",
     why="route 'maybe' is outside the contract. Marking it seen means it is never scored again. It is the only object, so "
         "nothing usable came back.",
     expected="kueue#902251 is not a task, not queued, and not a seen entry; with no usable object the run aborts without "
              "advancing the window, so the batch is retried next hour.",
     state={"last_run": "2026-09-15T09:00:00Z"},
     upstream={"list_ids": [iid(Q, 902251)]}, todoist={"wip": 0},
     claude={"out": [score(iid(Q, 902251), 6.5, "maybe")]},
     expect={"rc": 1, "last_run": "unchanged", "tasks_created": [], "queue_issues": [], "seen": []})

case("route", "26-missing-total-routed-todoist",
     covers=["V5"], run="scout",
     contract="prompt.md:83-98 (output contract requires weighted_total); SKILL.md:186-189; "
              "run-scout.sh:94-95 'If NOTHING parses, abort without advancing the window so the batch is retried'",
     code="F3 at f80c96d: lib.sh:366-367; lib.sh:127-128 (title renders '(score null)'). "
          "Fixed in nsega/agent-skills#20 (oss_lab_parse_scores requires a numeric weighted_total)",
     why="An object with no weighted_total cannot be routed by score; at f80c96d it became 'Contribute: ... (score null)'. "
         "It is the only object, so nothing usable came back.",
     expected="No task, not a seen entry; with no usable object the run aborts without advancing the window.",
     state={"last_run": "2026-09-15T09:00:00Z"},
     upstream={"list_ids": [iid(Q, 902261)]}, todoist={"wip": 0},
     claude={"out": [score(iid(Q, 902261), None, "todoist")]},
     expect={"rc": 1, "last_run": "unchanged", "tasks_created": [], "seen": []})

S = two_ids(902271, 902272)
case("route", "27-one-bad-field-loses-batch",
     covers=["V6"], run="scout",
     contract="SKILL.md:186-189 (runner validates every scored object); SKILL.md:41-42 (window advances so the next run resumes cleanly); "
              "run-scout.sh:94-95 'If NOTHING parses, abort without advancing the window so the batch is retried'",
     code="F4 at f80c96d: run-scout.sh:143 (`sort_by(-(.weighted_total // 0))` errors on a string; the process "
          "substitution's failure is not seen by set -e). Fixed in nsega/agent-skills#20 (oss_lab_parse_scores rejects "
          "a non-numeric weighted_total before the sort)",
     why="One object carries weighted_total as a string. jq's sort fails, the routing loop reads nothing, and the run "
         "still advances last_run and reports success: the valid object and the window are both lost.",
     expected="Per SKILL.md: the malformed object is rejected; the valid 6.3 object is queued and seen (or, at minimum, "
              "the window is not advanced).",
     upstream={"list_ids": S}, todoist={"wip": 0},
     claude={"out": [dict(score(S[0], 7.5, "todoist"), weighted_total="7.5"), score(S[1], 6.3, "queue")]},
     expect={"rc": 0, "queue_issues": [S[1]], "seen": [S[1]]})

case("route", "30-claude-fails-loudly",
     covers=["E1"], run="scout",
     contract="#18 (f80c96d) commit message: 'Take the exit code explicitly at both paid call sites and report it alongside a "
              "bounded excerpt'; 'the same runs still abort, and the window ... left uncommitted'. SKILL.md is silent on diagnostics.",
     code="skills/oss-lab/scripts/run-scout.sh:80-92; skills/oss-lab/scripts/lib.sh:30-41",
     why="The outage shape: claude exits 7 and explains itself on stdout, which the command substitution captures.",
     expected="Nonzero exit; log names 'claude exited 7 (window not advanced)' and shows 'Invalid API key'; last_run, seen, queue unchanged; no task.",
     state={"last_run": "2026-09-15T09:00:00Z"},
     upstream={"list_ids": [iid(Q, 902301)]}, todoist={"wip": 0},
     claude={"out": ["Invalid API key - please run /login"], "rc": 7},
     expect={"rc": "nonzero", "claude_called": True, "last_run": "unchanged", "seen": [], "queue": [],
             "tasks_created": [],
             "output_contains": ["claude exited 7 (window not advanced)", "Invalid API key - please run /login"]})

case("route", "31-unparseable-output",
     covers=["E2"], run="scout",
     contract="run-scout.sh:94-95 (abort without advancing the window); #18 commit message (excerpt of what came back)",
     code="skills/oss-lab/scripts/run-scout.sh:96-101",
     why="claude exits 0 with prose. The run aborts, keeps the window, and (since #18) shows the body.",
     expected="Exit 1; 'no parseable scores in claude output (window not advanced)'; the prose appears in the log; last_run unchanged.",
     state={"last_run": "2026-09-15T09:00:00Z"},
     upstream={"list_ids": [iid(Q, 902311)]}, todoist={"wip": 0},
     claude={"out": ["I could not score these issues right now."]},
     expect={"rc": 1, "last_run": "unchanged", "seen": [],
             "output_contains": ["no parseable scores in claude output (window not advanced)",
                                 "I could not score these issues right now."]})

case("route", "32-empty-output",
     covers=["E2"], run="scout",
     contract="as 31; #18 adds 'claude produced no output' so an empty reply is distinguishable",
     code="skills/oss-lab/scripts/run-scout.sh:96-101; skills/oss-lab/scripts/lib.sh:32-35",
     why="claude exits 0 and prints nothing.",
     expected="Exit 1; 'no parseable scores'; 'claude produced no output'; last_run unchanged.",
     state={"last_run": "2026-09-15T09:00:00Z"},
     upstream={"list_ids": [iid(Q, 902321)]}, todoist={"wip": 0},
     claude={"out": []},
     expect={"rc": 1, "last_run": "unchanged",
             "output_contains": ["no parseable scores in claude output", "claude produced no output"]})

case("route", "33-account-guard",
     covers=["E3"], run="scout",
     contract="SKILL.md:232-234 'Verify CLAUDE_CONFIG_DIR resolves to the intended personal account before first run (the runner enforces this)'",
     code="skills/oss-lab/scripts/lib.sh:45-51; run-scout.sh:19",
     why="A non-personal CLAUDE_CONFIG_DIR aborts before any upstream call or paid call.",
     expected="Exit 1; 'CLAUDE_CONFIG_DIR points to'; claude not called; no issues-list call.",
     claude_config_dir=".claude-work",
     upstream={"list_ids": [iid(Q, 902331)]},
     expect={"rc": 1, "claude_called": False, "output_contains": ["abort: CLAUDE_CONFIG_DIR points to"],
             "gh_call_counts": {f"repos/{Q}/issues": 0}})

case("route", "34-env-missing-token",
     covers=["E4"], run="scout",
     contract="SKILL.md:206-211 (secrets live in $OSS_LAB_STATE_DIR/env)",
     code="skills/oss-lab/scripts/lib.sh:55-65; run-scout.sh:18",
     why="Without TODOIST_TOKEN the run aborts before doing anything.",
     expected="Exit 1; 'TODOIST_TOKEN / TODOIST_PROJECT_ID not set'; claude not called.",
     state={"env": "missing_token"},
     upstream={"list_ids": [iid(Q, 902341)]},
     expect={"rc": 1, "claude_called": False, "output_contains": ["TODOIST_TOKEN / TODOIST_PROJECT_ID not set"]})


def task(tid, issue, plain=False, labels=("oss-lab",)):
    repo, n = issue.split("#")
    content = f"Contribute: {issue} (score 7.3)" if plain else \
        f"Contribute: [{issue}](https://github.com/{repo}/issues/{n}) (score 7.3)"
    return {"id": tid, "content": content, "labels": list(labels)}


case("route", "40-task-revalidation",
     covers=["C3", "C4"], run="scout",
     contract="SKILL.md:18-24 'every open task is re-checked upstream ... closed, assigned to someone else, or picked up in a pull "
              "request is closed, freeing its WIP slot'; SKILL.md:63-64 'Claims are re-checked continuously'",
     code="skills/oss-lab/scripts/lib.sh:83-92,201-225,231-254; run-scout.sh:37",
     why="Seven tasks: closed, assigned to another user, linked PR, assigned to us (claimed-but-undelivered, stays), live, "
         "renamed by the human (no issue id, left alone), plain pre-link title on a closed issue; plus a non-oss-lab task on a closed issue.",
     expected="Closed: t-closed, t-other, t-linked, t-plain. Kept: t-ours, t-live, t-renamed, t-unrelated. Quiet hour: 'no new issues'.",
     upstream={"list": {}, "linked": {Q: [902403]},
               "issues": {iid(Q, 902401): {"state": "closed"},
                          iid(Q, 902402): {"assignees": [{"login": "fixture-user-i"}]},
                          iid(Q, 902404): {"assignees": [{"login": "nsega"}]},
                          iid(K, 902407): {"state": "closed"},
                          iid(K, 902408): {"state": "closed"}}},
     todoist={"tasks": [task("t-closed", iid(Q, 902401)), task("t-other", iid(Q, 902402)),
                        task("t-linked", iid(Q, 902403)), task("t-ours", iid(Q, 902404)),
                        task("t-live", iid(Q, 902405)),
                        {"id": "t-renamed", "content": "Look into the LWS flake myself", "labels": ["oss-lab"]},
                        task("t-plain", iid(K, 902407), plain=True),
                        task("t-unrelated", iid(K, 902408), labels=("personal",))]},
     expect={"rc": 0, "tasks_closed": ["t-closed", "t-other", "t-linked", "t-plain"],
             "output_contains": ["revalidate: closed kubernetes-sigs/kueue#902401 (closed)",
                                 "revalidate: closed kubernetes-sigs/kueue#902402 (assigned to fixture-user-i)",
                                 "revalidate: closed kubernetes-sigs/kueue#902403 (has a linked PR)",
                                 "no new issues, claude not invoked"]})

SY = two_ids(902501, 902502, 902503)
case("route", "41-state-commit-and-push",
     covers=["T2"], run="scout",
     contract="SKILL.md:217-222 'the runner commits them (scout: <date> <n> scored, <t> tasked, <m> queued ...) and pushes'",
     code="skills/oss-lab/scripts/run-scout.sh:158-160; skills/oss-lab/scripts/lib.sh:389-404",
     why="State repo with a local bare remote; one task, one queue, one drop.",
     expected="Commit subject 'scout: YYYY-MM-DD 3 scored, 1 tasked, 1 queued', pushed to the remote.",
     state={"git": True}, upstream={"list_ids": SY}, todoist={"wip": 0},
     claude={"out": [score(SY[0], 7.4, "todoist"), score(SY[1], 5.5, "queue"), score(SY[2], 2.0, "drop")]},
     expect={"rc": 0, "git_subject": r"^scout: [0-9]{4}-[0-9]{2}-[0-9]{2} 3 scored, 1 tasked, 1 queued$", "git_pushed": True})

case("route", "42-push-failure-not-fatal",
     covers=["T3"], run="scout",
     contract="SKILL.md:222-223 'A failed push never fails the iteration'",
     code="skills/oss-lab/scripts/run-scout.sh:158-160; skills/oss-lab/scripts/lib.sh:399-403",
     why="State repo with no remote: the push fails.",
     expected="Exit 0; 'warn: state sync incomplete'; state still committed locally; last_run advanced.",
     state={"git": "no_remote"}, upstream={"list_ids": [iid(Q, 902511)]}, todoist={"wip": 0},
     claude={"out": [score(iid(Q, 902511), 5.5, "queue")]},
     expect={"rc": 0, "output_contains": ["warn: state sync incomplete"], "last_run": "advanced",
             "git_subject": r"^scout: .* 1 scored, 0 tasked, 1 queued$"})

# --- weekly gate, through run-scout.sh -----------------------------------
GQ = [{"issue": iid(Q, 902601), "weighted_total": 5.6, "rationale_consistency": "r", "route": "queue"}]
GATE_OUT = [score(iid(Q, 902601), 6.0, "queue")]
for cid, ago, runs in (("50-gate-stamp-exactly-6-days", 6 * 86400, True),
                       ("51-gate-stamp-just-under-6-days", 6 * 86400 - 600, False),
                       ("52-gate-stamp-garbage", "garbage", True),
                       ("53-gate-no-stamp", None, True)):
    lre = {"ago": ago} if isinstance(ago, int) else ago
    case("route", cid,
         covers=["Q1"], run="scout",
         contract="SKILL.md:123-125 'The hourly runner triggers run-reeval.sh once the last_reeval stamp is 6+ days old'",
         code="skills/oss-lab/scripts/run-scout.sh:44-51",
         why={True: "Stamp due (>= 6 days, missing, or unreadable): the weekly pass runs before the hourly fetch.",
              False: "Stamp 6 days minus 10 minutes old: not due."}[runs],
         expected=("Weekly pass runs (claude called with the queued issue), stamp advanced; scout still exits 0 via 'no new issues'."
                   if runs else "Weekly pass skipped: claude not called, stamp unchanged."),
         state={"queue": GQ, "last_reeval": lre}, upstream={"list": {}}, todoist={"wip": 0},
         claude={"out": GATE_OUT},
         expect=({"rc": 0, "claude_called": True, "last_reeval": "advanced", "claude_stdin_issues": [iid(Q, 902601)],
                  "output_contains": ["no new issues, claude not invoked"]} if runs else
                 {"rc": 0, "claude_called": False, "last_reeval": "unchanged"}))

case("route", "54-gate-reeval-failure-best-effort",
     covers=["Q2", "E1"], run="scout",
     contract="SKILL.md:125-127 'The pass is best-effort (a failure never costs the scout iteration) and retries hourly until it succeeds'; "
              "#18 commit message ('carries its child's exit code into the warn line')",
     code="skills/oss-lab/scripts/run-scout.sh:46-51; run-reeval.sh:127-140",
     why="The weekly pass's claude call fails (exit 7).",
     expected="Scout exits 0; log has 'claude exited 7 (stamp not advanced)' and 'reeval pass failed (exit 1)'; stamp unchanged; "
              "the hourly iteration still completes ('no new issues').",
     state={"queue": GQ, "last_reeval": None}, upstream={"list": {}}, todoist={"wip": 0},
     claude={"out": ["Credit balance exhausted"], "rc": 7},
     expect={"rc": 0, "last_reeval": "absent",
             "output_contains": ["claude exited 7 (stamp not advanced)", "warn: reeval pass failed (exit 1), continuing",
                                 "no new issues, claude not invoked"]})

case("route", "55-gate-revalidate-tasks-first",
     covers=["Q3", "C3"], run="scout",
     contract="SKILL.md:18-24 (revalidation is step 1); run-scout.sh:28-36 (runs before the weekly pass, which sizes its promotion budget from WIP)",
     code="skills/oss-lab/scripts/run-scout.sh:37,44-51",
     why="A dead task (closed issue) holds a slot. It must be closed before the weekly pass reads WIP.",
     expected="Task t-dead closed before claude runs; the queued 7.8 issue is promoted because the freed slot makes the budget 1.",
     state={"queue": [{"issue": iid(Q, 902611), "weighted_total": 6.6, "route": "queue"}], "last_reeval": None},
     upstream={"list": {}, "issues": {iid(K, 902619): {"state": "closed"}}},
     todoist={"tasks": [task(f"t{i}", iid(Q, 902620 + i)) for i in range(4)] + [task("t-dead", iid(K, 902619))]},
     claude={"out": [score(iid(Q, 902611), 7.8, "todoist")]},
     expect={"rc": 0, "tasks_closed": ["t-dead"], "sequence_before": [["close", "claude"]],
             "tasks_created": [iid(Q, 902611)], "queue_issues": []})

# =========================================================================
# REEVAL (run-reeval.sh run directly)
# =========================================================================
def q(issue, wt, **kw):
    o = {"issue": issue, "scores": axes_for(wt) if wt is not None else None, "weighted_total": wt,
         "rationale_consistency": kw.pop("rationale", "prior rationale"), "route": "queue"}
    if wt is None:
        del o["scores"], o["weighted_total"]
    o.update(kw)
    return o


case("reeval", "01-empty-queue",
     covers=["Q4"], run="reeval",
     contract="run-reeval.sh:29 'Guard R1: an empty queue never starts Claude'; SKILL.md:128 'a successful manual pass counts toward the weekly cadence'",
     code="skills/oss-lab/scripts/run-reeval.sh:30-42",
     why="Nothing queued: no paid call, and the pass counts as done.",
     expected="'queue empty, claude not invoked'; claude not called; stamp advanced; exit 0.",
     state={"queue": []},
     expect={"rc": 0, "claude_called": False, "last_reeval": "advanced", "output_contains": ["queue empty, claude not invoked"]})

case("reeval", "02-corrupt-queue",
     covers=["Q5"], run="reeval",
     contract="SKILL.md:116-118 (abort without advancing the stamp rather than a blind pass); run-reeval.sh:32-33",
     code="skills/oss-lab/scripts/run-reeval.sh:34-37",
     why="A corrupt queue.json must not read as 'length 0' and silently skip a week.",
     expected="Exit 1; 'is missing or not a JSON array (stamp not advanced)'; queue file untouched; no claude call.",
     state={"queue_raw": '{"issue": "kubernetes-sigs/kueue#902701"'},
     expect={"rc": 1, "claude_called": False, "last_reeval": "absent", "queue_unchanged": True,
             "output_contains": ["not a JSON array (stamp not advanced)"]})

RV = {"closed": iid(Q, 902711), "other": iid(Q, 902712), "linked": iid(K, 902713),
      "ours": iid(Q, 902714), "live": iid(G, 902715)}
case("reeval", "03-revalidation-drops-settled",
     covers=["Q6", "Q7"], run="reeval",
     contract="SKILL.md:98-101 'the weekly pass first revalidates every queued issue upstream ... and drops the ones that closed, were "
              "assigned, or grew a linked PR; only the survivors are re-scored'; SKILL.md:44-46",
     code="skills/oss-lab/scripts/run-reeval.sh:58-61; skills/oss-lab/scripts/lib.sh:201-225,277-305",
     why="Five queued issues: closed, assigned to another user, linked PR, assigned to us, live. Assignment to the scout's own "
         "login is not someone else's claim.",
     expected="Dequeued with reasons: closed, assigned to fixture-user-j, has a linked PR. Only 'ours' and 'live' reach claude; "
              "both stay queued with reeval_count 1; stamp advanced; 'reeval complete: 2 rescored, 0 promoted, 3 stale-pruned, 0 dropped'.",
     state={"queue": [q(v, 6.0) for v in RV.values()]},
     upstream={"linked": {K: [902713]},
               "issues": {RV["closed"]: {"state": "closed"}, RV["other"]: {"assignees": [{"login": "fixture-user-j"}]},
                          RV["ours"]: {"assignees": [{"login": "nsega"}]}}},
     todoist={"wip": 0},
     claude={"out": [score(RV["ours"], 6.2, "queue"), score(RV["live"], 5.8, "queue")]},
     expect={"rc": 0, "claude_stdin_issues": [RV["ours"], RV["live"]], "queue_issues": [RV["ours"], RV["live"]],
             "queue": [{"issue": RV["ours"], "weighted_total": 6.2, "reeval_count": 1},
                       {"issue": RV["live"], "weighted_total": 5.8, "reeval_count": 1}],
             "last_reeval": "advanced",
             "output_contains": [f"revalidate: dequeued {RV['closed']} (closed)",
                                 f"revalidate: dequeued {RV['other']} (assigned to fixture-user-j)",
                                 f"revalidate: dequeued {RV['linked']} (has a linked PR)",
                                 "reeval complete: 2 rescored, 0 promoted, 3 stale-pruned, 0 dropped, 2 still queued"]})

case("reeval", "04-all-settled-no-claude",
     covers=["Q6"], run="reeval",
     contract="SKILL.md:98-101; revalidating first means a fully settled queue is never paid for (SKILL.md:119-122)",
     code="skills/oss-lab/scripts/run-reeval.sh:63-71",
     why="Every queued issue is settled.",
     expected="Queue emptied; claude not called; stamp advanced; 'queue empty after revalidation (2 stale pruned)'.",
     state={"queue": [q(iid(Q, 902721), 6.0), q(iid(Q, 902722), 5.5)]},
     upstream={"issues": {iid(Q, 902721): {"state": "closed"}, iid(Q, 902722): {"state": "closed"}}},
     todoist={"wip": 0},
     expect={"rc": 0, "claude_called": False, "queue": [], "last_reeval": "advanced",
             "output_contains": ["queue empty after revalidation (2 stale pruned), claude not invoked"]})

UK = [q(iid(Q, 902731), 6.1, reeval_count=1), q(iid(Q, 902732), 5.9)]
case("reeval", "05-unknown-kept-untouched",
     covers=["Q8", "Q9"], run="reeval",
     contract="SKILL.md:114-116 'An issue whose fetch failed is left out of the paid call and stays queued untouched for next week'; "
              "SKILL.md:122-123 'A status of unknown keeps the issue'",
     code="skills/oss-lab/scripts/lib.sh:205; run-reeval.sh:95-105,177",
     why="One issue's fetch fails (5xx); the other is live.",
     expected="Only kueue#902732 reaches claude; kueue#902731 stays byte-identical in content (same total, reeval_count 1); stamp advanced.",
     state={"queue": UK},
     upstream={"issues": {iid(Q, 902731): "unreachable"}}, todoist={"wip": 0},
     claude={"out": [score(iid(Q, 902732), 6.4, "queue")]},
     expect={"rc": 0, "claude_stdin_issues": [iid(Q, 902732)], "last_reeval": "advanced",
             "queue": [UK[0], {"issue": iid(Q, 902732), "weighted_total": 6.4, "reeval_count": 1}],
             "output_contains": [f"no fresh upstream copy of {iid(Q, 902731)}, leaving it queued for next week"]})

case("reeval", "06-github-down-aborts",
     covers=["Q8", "Q10"], run="reeval",
     contract="SKILL.md:116-118 'if none could be fetched the pass aborts without advancing the stamp'; SKILL.md:122-123 "
              "'an unreachable GitHub cannot empty the queue'",
     code="skills/oss-lab/scripts/run-reeval.sh:107-113",
     why="GitHub unreachable: every status is unknown, nothing is pruned, nothing is fetched.",
     expected="Exit 1; claude not called; stamp not advanced; both entries still queued with prior totals.",
     state={"queue": [q(iid(Q, 902741), 6.0), q(iid(K, 902742), 5.2)]},
     upstream={"gh_down": True}, todoist={"wip": 0},
     expect={"rc": 1, "claude_called": False, "last_reeval": "absent",
             "queue": [{"issue": iid(Q, 902741), "weighted_total": 6.0}, {"issue": iid(K, 902742), "weighted_total": 5.2}],
             "output_contains": ["no fresh upstream copy of any queued issue, nothing to score (stamp not advanced)"]})

EV = iid(Q, 902751)
case("reeval", "07-rescore-reads-upstream-not-prior",
     covers=["Q11"], run="reeval",
     contract="SKILL.md:46-48 'the paid step reads each issue as it stands today (title, labels, body, recent comments), never its own "
              "prior score'; SKILL.md:101-104 'shaped exactly as fetch-issues.sh shapes a new issue and with nothing from the prior pass attached'",
     code="skills/oss-lab/scripts/run-reeval.sh:94-105; skills/oss-lab/scripts/lib.sh:314-358",
     why="The queued entry carries a prior rationale and scores; upstream has a new title, labels, body and comments.",
     expected="claude stdin is one line with exactly the fetch-shaped keys plus recent_comments, carrying the upstream title; "
              "no prior rationale, scores, weighted_total or reeval_count.",
     state={"queue": [q(EV, 6.4, rationale="PRIOR-RATIONALE-MARKER", reeval_count=2)]},
     upstream={"issues": {EV: {"title": "Updated: LWS e2e times out on restart", "labels": [{"name": "kind/flake"}],
                               "body": "Updated body with repro steps.", "comments": 2}},
               "comments": {EV: [comment("fixture-user-k", "Still flaking on main."),
                                 comment("fixture-user-l", "Repro attached.")]}},
     todoist={"wip": 0},
     claude={"out": [score(EV, 6.6, "queue")]},
     expect={"rc": 0,
             "claude_stdin_keys": [["body", "comments", "created_at", "issue", "labels", "recent_comments", "title", "url"]],
             "claude_stdin_objects": [{"issue": EV, "title": "Updated: LWS e2e times out on restart", "labels": ["kind/flake"],
                                       "body": "Updated body with repro steps.",
                                       "recent_comments": [{"author": "fixture-user-k", "body": "Still flaking on main."},
                                                           {"author": "fixture-user-l", "body": "Repro attached."}]}],
             "claude_prompt": {"wip_count": 0, "wip_cap": 5},
             "queue": [{"issue": EV, "weighted_total": 6.6, "reeval_count": 3}]})

PR = {"a": iid(Q, 902761), "b": iid(Q, 902762), "c": iid(K, 902763), "d": iid(G, 902764)}
case("reeval", "08-promotion-by-score-within-budget",
     covers=["Q12", "Q13"], run="reeval",
     contract="SKILL.md:105-110 'a score at or above the promote threshold is a promotion candidate regardless of the route the model "
              "wrote (so a 7.1 the model capped last week takes the next free slot)'; SKILL.md:49-50 'within the same WIP budget'",
     code="skills/oss-lab/scripts/run-reeval.sh:214-253",
     why="WIP 3 of 5: budget 2. Rescored: a=7.4 (model wrote queue + wip_capped), b=8.1 todoist, c=7.0 exactly (queue), d=6.9.",
     expected="Promoted in score order: b, a. c (7.0) stays queued flagged wip_capped=true; d stays without the flag. "
              "All four are re-checked upstream; 'reeval complete: 4 rescored, 2 promoted, 0 stale-pruned, 0 dropped'.",
     state={"queue": [q(v, 6.0) for v in PR.values()]},
     todoist={"wip": 3},
     claude={"out": [score(PR["a"], 7.4, "queue", wip_capped=True), score(PR["b"], 8.1, "todoist"),
                     score(PR["c"], 7.0, "queue"), score(PR["d"], 6.9, "queue")]},
     expect={"rc": 0, "tasks_created": [PR["b"], PR["a"]],
             "queue": [{"issue": PR["c"], "weighted_total": 7.0, "wip_capped": True, "route": "queue", "reeval_count": 1},
                       {"issue": PR["d"], "weighted_total": 6.9, "wip_capped": "<absent>", "reeval_count": 1}],
             "output_contains": [f"promote: {PR['b']} now a task", f"promote: {PR['a']} now a task",
                                 "reeval complete: 4 rescored, 2 promoted, 0 stale-pruned, 0 dropped, 2 still queued"]})

BD = {"at": iid(Q, 902771), "under": iid(Q, 902772)}
case("reeval", "09-promote-threshold-boundary",
     covers=["Q12"], run="reeval",
     contract="SKILL.md:107 'a score at or above the promote threshold'; SKILL.md:88 (>= 7.0); lib.sh:20 OSS_LAB_PROMOTE_AT=7.0",
     code="skills/oss-lab/scripts/run-reeval.sh:241",
     why="Exactly 7.0 promotes; 6.9, the next total down on the runner's 0.1 grid, does not. Budget is ample (WIP 0).",
     expected="Task for kueue#902771 (7.0); kueue#902772 (6.9) stays queued, not flagged.",
     state={"queue": [q(BD["at"], 6.0), q(BD["under"], 6.0)]}, todoist={"wip": 0},
     claude={"out": [score(BD["at"], 7.0, "todoist"), score(BD["under"], 6.9, "queue")]},
     expect={"rc": 0, "tasks_created": [BD["at"]],
             "queue": [{"issue": BD["under"], "weighted_total": 6.9, "wip_capped": "<absent>"}]})

TS = {"twice": iid(Q, 902781), "prior_at_bar": iid(Q, 902782), "recovers": iid(Q, 902783),
      "edge_twice": iid(K, 902784), "no_prior": iid(G, 902785)}
case("reeval", "10-two-strike-drop",
     covers=["Q14"], run="reeval",
     contract="SKILL.md:110 'two consecutive sub-threshold scores drop it; anything else stays with its new score and reeval_count "
              "advanced'; SKILL.md:88 (< 5.0 is sub-threshold); lib.sh:21 OSS_LAB_DROP_BELOW=5.0",
     code="skills/oss-lab/scripts/run-reeval.sh:185-192",
     why="Prior/new pairs: 4.4->4.2 (drop), 5.0->4.9 (prior not sub-threshold: keep), 4.9->5.0 (recovers: keep), "
         "4.99->4.9 (drop; a two-decimal prior is an entry queued before the runner recomputed totals), "
         "no prior total->3.0 (first strike: keep).",
     expected="Dropped: 902781, 902784 with 'sub-threshold twice'. Kept with new totals and reeval_count+1: 902782, 902783, 902785.",
     state={"queue": [q(TS["twice"], 4.4, reeval_count=1), q(TS["prior_at_bar"], 5.0), q(TS["recovers"], 4.9, reeval_count=2),
                      q(TS["edge_twice"], 4.99), q(TS["no_prior"], None)]},
     todoist={"wip": 0},
     claude={"out": [score(TS["twice"], 4.2, "drop"), score(TS["prior_at_bar"], 4.9, "drop"),
                     score(TS["recovers"], 5.0, "queue"), score(TS["edge_twice"], 4.9, "drop"),
                     score(TS["no_prior"], 3.0, "drop")]},
     expect={"rc": 0, "tasks_created": [],
             "queue": [{"issue": TS["prior_at_bar"], "weighted_total": 4.9, "route": "queue", "reeval_count": 1},
                       {"issue": TS["recovers"], "weighted_total": 5.0, "reeval_count": 3},
                       {"issue": TS["no_prior"], "weighted_total": 3.0, "route": "queue", "reeval_count": 1}],
             "output_contains": [f"reeval: dropping {TS['twice']} (sub-threshold twice: 4.4 then 4.2)",
                                 f"reeval: dropping {TS['edge_twice']} (sub-threshold twice: 4.99 then 4.9)",
                                 "2 dropped"]})

CB = {"claimed": iid(Q, 902791), "keep": iid(Q, 902792)}
case("reeval", "11-claim-drops-whatever-score",
     covers=["C5"], run="reeval",
     contract="SKILL.md:105-106 'a claim drops the issue whatever it scored'",
     code="skills/oss-lab/scripts/run-reeval.sh:180-181",
     why="The scorer saw a claim in the refreshed comments and returned claimed_by on an 8.6. Budget is free.",
     expected="kueue#902791 dropped ('claimed by fixture-user-m'), never promoted; kueue#902792 kept.",
     state={"queue": [q(CB["claimed"], 6.5), q(CB["keep"], 6.0)]},
     upstream={"issues": {CB["claimed"]: {"comments": 1}},
               "comments": {CB["claimed"]: [comment("fixture-user-m", "I have a branch for this, will open the PR today.")]}},
     todoist={"wip": 0},
     claude={"out": [score(CB["claimed"], 8.6, "drop", claimed_by="fixture-user-m"), score(CB["keep"], 6.1, "queue")]},
     expect={"rc": 0, "tasks_created": [], "queue_issues": [CB["keep"]],
             "output_contains": [f"reeval: dropping {CB['claimed']} (claimed by fixture-user-m)"]})

case("reeval", "12-drop-route-first-strike-kept",
     covers=["Q14", "Q15"], run="reeval",
     contract="SKILL.md:105-111 (the runner decides: one sub-threshold score is not a drop; 'anything else stays with its new score')",
     code="skills/oss-lab/scripts/run-reeval.sh:182-192",
     why="The scorer routes drop on a 4.0 (no claim) for an issue whose prior total was 6.0: first strike only.",
     expected="Kept with weighted_total 4.0, route rewritten to 'queue', reeval_count 1.",
     state={"queue": [q(iid(Q, 902801), 6.0)]}, todoist={"wip": 0},
     claude={"out": [score(iid(Q, 902801), 4.0, "drop")]},
     expect={"rc": 0, "queue": [{"issue": iid(Q, 902801), "weighted_total": 4.0, "route": "queue", "reeval_count": 1}]})

DR = {"high": iid(Q, 902811), "mid": iid(Q, 902812)}
case("reeval", "13-drop-route-without-claim",
     covers=["Q13", "Q15"], run="reeval",
     contract="SKILL.md Queue decay 'a scorer \"drop\" with no claimed_by on a score at or above the drop bar counts as a claim' "
              "(documented in nsega/agent-skills#21; F5 was this rule living only in "
              "the code comment at run-reeval.sh:156-159)",
     code="skills/oss-lab/scripts/run-reeval.sh:182-184 (route 'drop' with no claimed_by at >= 5.0 is treated as a claim)",
     why="The scorer writes route drop with no claimed_by on a 7.6 and on a 5.5. Both are at or above the drop bar, so the "
         "only reason left to drop them is a claim, and the loop would rather lose a candidate than take announced work.",
     expected="Both are dropped as claims: no task, and neither stays queued.",
     state={"queue": [q(DR["high"], 6.0), q(DR["mid"], 6.0)]}, todoist={"wip": 0},
     claude={"out": [score(DR["high"], 7.6, "drop"), score(DR["mid"], 5.5, "drop")]},
     expect={"rc": 0, "tasks_created": [], "queue": [],
             "output_contains": ["dropped by the scorer at 7.6 with no claimed_by, treated as a claim"]})

RC = iid(Q, 902821)
case("reeval", "14-reeval-count-owned-by-runner",
     covers=["Q16"], run="reeval",
     contract="SKILL.md:110-111 'reeval_count advanced from the queue's own record'; SKILL.md:114 'queue.json itself still holds only the scoring object'",
     code="skills/oss-lab/scripts/run-reeval.sh:189-192",
     why="The scorer emits its own reeval_count (9), wip_capped and claimed_by: null, and route todoist on a 6.5.",
     expected="Stored: weighted_total 6.5, route 'queue', reeval_count 3 (prior 2 + 1), no wip_capped, no claimed_by.",
     state={"queue": [q(RC, 5.9, reeval_count=2)]}, todoist={"wip": 0},
     claude={"out": [score(RC, 6.5, "todoist", reeval_count=9, wip_capped=True, claimed_by=None)]},
     expect={"rc": 0, "tasks_created": [],
             "queue": [{"issue": RC, "weighted_total": 6.5, "route": "queue", "reeval_count": 3,
                        "wip_capped": "<absent>", "claimed_by": "<absent>"}]})

HS = {"a": iid(Q, 902831), "skipped": iid(Q, 902832), "ghost": iid(Q, 902839)}
case("reeval", "15-hallucinated-and-skipped",
     covers=["Q17", "V3"], run="reeval",
     contract="SKILL.md:186-189 (a hallucinated result cannot become a task); run-reeval.sh:163-164 'An issue the model skipped stays untouched ... "
              "a hallucinated issue never enters'",
     code="skills/oss-lab/scripts/run-reeval.sh:171-197,240-243",
     why="Output covers kueue#902831, invents kueue#902839 at 9.0, and skips kueue#902832.",
     expected="No task (the ghost is never promoted though budget is free); queue = [902831 rescored, 902832 untouched].",
     state={"queue": [q(HS["a"], 6.0), q(HS["skipped"], 5.7, reeval_count=1)]}, todoist={"wip": 0},
     claude={"out": [score(HS["a"], 6.2, "queue"), score(HS["ghost"], 9.0, "todoist")]},
     expect={"rc": 0, "tasks_created": [],
             "queue": [{"issue": HS["a"], "weighted_total": 6.2, "reeval_count": 1},
                       {"issue": HS["skipped"], "weighted_total": 5.7, "reeval_count": 1}]})

case("reeval", "16-todoist-down-before-anything",
     covers=["Q10"], run="reeval",
     contract="SKILL.md:116-118 (abort without advancing the stamp); run-reeval.sh:45-46 'Read before anything is written, so every abort "
              "path leaves the state exactly as it found it'",
     code="skills/oss-lab/scripts/run-reeval.sh:47-50",
     why="Todoist unreachable: the promotion budget is unknown, so the pass aborts before the prune and before the paid call.",
     expected="Exit 1; queue.json byte-identical (the closed issue is NOT pruned); no claude; stamp absent; no issue-status call.",
     state={"queue": [q(iid(Q, 902841), 6.0), q(iid(Q, 902842), 6.0)]},
     upstream={"issues": {iid(Q, 902841): {"state": "closed"}}}, todoist={"down": True},
     expect={"rc": 1, "claude_called": False, "last_reeval": "absent", "queue_unchanged": True,
             "gh_call_counts": {"repos/kubernetes-sigs/kueue/issues/": 0},
             "output_contains": ["todoist unreachable, WIP count unknown (stamp not advanced)"]})

FQ = [q(iid(Q, 902851), 5.6), q(iid(Q, 902852), 6.0)]
case("reeval", "17-claude-fails-loudly",
     covers=["E1", "Q10"], run="reeval",
     contract="SKILL.md:125-127 (retries hourly until it succeeds); #18 commit message (exit code and excerpt reported)",
     code="skills/oss-lab/scripts/run-reeval.sh:127-140",
     why="The re-score call exits 7 with an error on stdout. kueue#902852 closed upstream, so the free prune still applies.",
     expected="Nonzero exit; 'claude exited 7 (stamp not advanced)' plus the error text; stamp absent; queue holds only "
              "kueue#902851 with its prior total and no reeval_count (no re-scored field applied).",
     state={"queue": FQ}, upstream={"issues": {iid(Q, 902852): {"state": "closed"}}}, todoist={"wip": 0},
     claude={"out": ["API Error: 401 authentication_error"], "rc": 7},
     expect={"rc": "nonzero", "last_reeval": "absent",
             "queue": [{"issue": iid(Q, 902851), "weighted_total": 5.6, "reeval_count": "<absent>"}],
             "output_contains": ["claude exited 7 (stamp not advanced)", "API Error: 401 authentication_error"]})

case("reeval", "18-unparseable-output",
     covers=["E2", "Q10"], run="reeval",
     contract="run-reeval.sh:142-143 (abort without advancing the stamp); #18 commit message (excerpt)",
     code="skills/oss-lab/scripts/run-reeval.sh:144-149",
     why="claude exits 0 with prose only.",
     expected="Exit 1; 'no parseable scores in claude output (stamp not advanced)' plus the prose; stamp absent; queue totals unchanged.",
     state={"queue": [q(iid(Q, 902861), 5.6)]}, todoist={"wip": 0},
     claude={"out": ["Sorry, I can't help with scoring today."]},
     expect={"rc": 1, "last_reeval": "absent",
             "queue": [{"issue": iid(Q, 902861), "weighted_total": 5.6, "reeval_count": "<absent>"}],
             "output_contains": ["no parseable scores in claude output (stamp not advanced)", "Sorry, I can't help with scoring today."]})

RA = {"taken": iid(Q, 902871), "free": iid(Q, 902872)}
case("reeval", "19-promotion-recheck-race",
     covers=["C6"], run="reeval",
     contract="SKILL.md:63-64 'Claims are re-checked continuously, not only at fetch time'",
     code="skills/oss-lab/scripts/run-reeval.sh:228-232",
     why="kueue#902871 is closed upstream while the paid call runs (after the prune). It must not become a task.",
     expected="'promote: skipping kueue#902871 (closed)'; only kueue#902872 becomes a task.",
     state={"queue": [q(RA["taken"], 6.0), q(RA["free"], 6.0)]}, todoist={"wip": 0},
     race_upstream={"issues": {RA["taken"]: {"state": "closed"}}},
     claude={"out": [score(RA["taken"], 8.4, "todoist"), score(RA["free"], 7.2, "todoist")]},
     expect={"rc": 0, "tasks_created": [RA["free"]], "output_contains": [f"promote: skipping {RA['taken']} (closed)"]})

case("reeval", "20-promotion-post-fails",
     covers=["Q13"], run="reeval",
     contract="SKILL.md:49-50 (promotion is the queue's exit); failure handling in run-reeval.sh:237-238",
     code="skills/oss-lab/scripts/run-reeval.sh:233-239,246-253",
     why="The Todoist POST fails for the promotion candidate.",
     expected="'todoist create failed ... leaving it queued'; the issue stays queued, flagged wip_capped, with its new score.",
     state={"queue": [q(iid(Q, 902881), 6.0)]}, todoist={"wip": 0, "post_fail": True},
     claude={"out": [score(iid(Q, 902881), 7.7, "todoist")]},
     expect={"rc": 0, "tasks_created": [],
             "queue": [{"issue": iid(Q, 902881), "weighted_total": 7.7, "wip_capped": True, "reeval_count": 1}],
             "output_contains": [f"warn: todoist create failed for {iid(Q, 902881)}, leaving it queued"]})

CM = {"closed": iid(Q, 902891), "promote": iid(Q, 902892), "drop": iid(Q, 902893), "keep": iid(Q, 902894)}
case("reeval", "21-commit-message",
     covers=["T2", "Q12", "Q14", "Q6"], run="reeval",
     contract="SKILL.md:221 'reeval: <date> <n> rescored, <p> promoted, <s> stale-pruned, <d> dropped'",
     code="skills/oss-lab/scripts/run-reeval.sh:258-266",
     why="One of each outcome: pruned (closed), promoted, two-strike dropped, kept.",
     expected="Commit 'reeval: YYYY-MM-DD 3 rescored, 1 promoted, 1 stale-pruned, 1 dropped', pushed.",
     state={"git": True, "queue": [q(CM["closed"], 6.0), q(CM["promote"], 6.0), q(CM["drop"], 4.5), q(CM["keep"], 6.0)]},
     upstream={"issues": {CM["closed"]: {"state": "closed"}}}, todoist={"wip": 0},
     claude={"out": [score(CM["promote"], 7.3, "todoist"), score(CM["drop"], 4.1, "drop"), score(CM["keep"], 6.0, "queue")]},
     expect={"rc": 0, "git_subject": r"^reeval: [0-9]{4}-[0-9]{2}-[0-9]{2} 3 rescored, 1 promoted, 1 stale-pruned, 1 dropped$",
             "git_pushed": True, "queue_issues": [CM["keep"]], "tasks_created": [CM["promote"]]})

case("reeval", "22-wip-full-no-promotion",
     covers=["Q13", "W3"], run="reeval",
     contract="SKILL.md:49-50 'promoted into a task (within the same WIP budget)'",
     code="skills/oss-lab/scripts/run-reeval.sh:214-218,249-253",
     why="WIP 5 of 5: an 8.0 rescore cannot be promoted.",
     expected="No task; the issue stays queued with wip_capped=true and reeval_count 1.",
     state={"queue": [q(iid(Q, 902901), 6.0)]}, todoist={"wip": 5},
     claude={"out": [score(iid(Q, 902901), 8.0, "queue", wip_capped=True)]},
     expect={"rc": 0, "tasks_created": [],
             "queue": [{"issue": iid(Q, 902901), "weighted_total": 8.0, "wip_capped": True, "reeval_count": 1}]})


def main():
    for kind, cases in CASES.items():
        d = os.path.join(HERE, kind)
        if os.path.isdir(d):
            for f in os.listdir(d):
                if f.endswith(".json"):
                    os.remove(os.path.join(d, f))
        os.makedirs(d, exist_ok=True)
        for c in cases:
            name = c["id"].split("/", 1)[1] + ".json"
            with open(os.path.join(d, name), "w") as fh:
                json.dump(c, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
    print({k: len(v) for k, v in CASES.items()})


if __name__ == "__main__":
    main()
