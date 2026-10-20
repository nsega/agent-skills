# grade.jq: grade one scorer reply against one evals.json case.
#
#   jq -n --argjson eval "$EVAL_JSON" --rawfile out reply.txt --argjson wip_cap 5 -f grade.jq
#
# Validity rules come from prompt.md's output contract and routing rules and
# apply to every case. Expectations come from the case's assertions. Result:
#   {id, name, pass, valid, validity_failures[], expectation_failures[], objects[]}
#
# The parse mirrors oss_lab_parse_scores (scripts/lib.sh:365-368), so a reply
# the runner would act on is graded on the same objects. Strict JSONL (no prose,
# no fences) is a separate validity rule, because prompt.md:7-8 asks for it
# even though the runner tolerates its absence.

def W: {okr_alignment: 0.3, consistency: 0.3, impact: 0.2, feasibility: 0.2};
def axes: ["okr_alignment", "consistency", "impact", "feasibility"];
def weighted($s): [axes[] as $a | W[$a] * ($s[$a] // 0)] | add;
def claimed($o): ($o.claimed_by // null) | (type == "string" and length > 0);

($eval.prompt | split("\n") | map(select(length > 0) | fromjson | .issue)) as $inputs
| ($eval.wip_count // 0) as $wip_count
| ([0, $wip_cap - $wip_count] | max) as $budget
| ($out | split("\n") | map(select(test("\\S")))) as $lines
| [$lines[] | (try fromjson catch null)
   | select(type == "object" and .route != null and (.issue | type) == "string")] as $objs
| ($objs | map({key: .issue, value: .}) | from_entries) as $by

# ---- validity (prompt.md contract) -------------------------------------
| [
    (if ($objs | length) == 0 then "no parseable scoring object" else empty end),
    ($lines[] | select((try fromjson catch null) | type != "object")
       | "non-JSON line (prompt.md:7-8 asks for JSONL only): \(.[0:80])"),
    ($objs | group_by(.issue)[] | select(length > 1) | "duplicate object for \(.[0].issue)"),
    ($objs[] | select(.issue as $i | $inputs | index($i) | not)
       | "object for an issue not in the input: \(.issue)"),
    ($inputs[] | select(. as $i | $by | has($i) | not) | "no object for input issue \(.)"),
    ($objs[] | . as $o
      | ( (if (.scores | type) != "object" then "\(.issue): scores missing"
           else (axes[] as $a | ($o.scores[$a]) as $v
                 | select(($v | type) != "number" or $v < 0 or $v > 10)
                 | "\($o.issue): \($a) = \($v | tojson) is not a number in 0-10")
           end),
          (if (.weighted_total | type) != "number" then "\(.issue): weighted_total missing or not a number"
           elif (.scores | type) == "object" and ((.weighted_total - weighted(.scores)) | fabs) > 0.051
             then "\(.issue): weighted_total \(.weighted_total) != weighted axes \(weighted(.scores) * 100 | round / 100)"
           else empty end),
          (if (.rationale_consistency | type) != "string" or (.rationale_consistency | length) == 0
             then "\(.issue): rationale_consistency missing" else empty end),
          (if ["todoist", "queue", "drop"] | index($o.route) | not
             then "\(.issue): route \(.route | tojson) not in todoist|queue|drop" else empty end),
          # routing rules (prompt.md:116-128)
          ((.weighted_total // 0) as $wt
          | if claimed($o) then (if .route != "drop" then "\(.issue): claimed_by set but route \(.route)" else empty end)
             elif $wt >= 7.0 then
               (if .route == "drop" then "\(.issue): \($wt) >= 7.0 routed drop without claimed_by"
                elif .route == "queue" and (.wip_capped != true) then "\(.issue): \($wt) >= 7.0 routed queue without wip_capped"
                else empty end)
             elif $wt >= 5.0 then (if .route != "queue" then "\(.issue): \($wt) in 5.0-6.9 routed \(.route)" else empty end)
             else (if .route != "drop" then "\(.issue): \($wt) < 5.0 routed \(.route)" else empty end)
             end)
        )),
    # WIP cap (prompt.md:123-128): never exceed the remaining budget
    (([$objs[] | select(.route == "todoist")] | length) as $t
     | if $t > $budget then "\($t) todoist routes exceed WIP budget \($budget) (WIP_COUNT=\($wip_count), WIP_CAP=\($wip_cap))" else empty end)
  ] as $validity

# ---- expectations (this case's assertions) ------------------------------
| [ $eval.assertions[] as $a
    | ($by[$a.issue // ""]) as $o
    | if $a.type == "band" then
        (if $o == null then "\($a.issue): no object to check \($a.axis)"
         elif ($o.scores[$a.axis] | type) != "number" or $o.scores[$a.axis] < $a.min or $o.scores[$a.axis] > $a.max
           then "\($a.issue): \($a.axis) = \($o.scores[$a.axis] | tojson), expected \($a.min)-\($a.max)"
         else empty end)
      elif $a.type == "total_range" then
        (if $o == null then empty
         elif ($o.weighted_total | type) != "number" or $o.weighted_total < $a.min - 0.051 or $o.weighted_total > $a.max + 0.051
           then "\($a.issue): weighted_total = \($o.weighted_total | tojson), expected \($a.min)-\($a.max)"
         else empty end)
      elif $a.type == "route" then
        (if $o == null then "\($a.issue): no object to check route"
         elif $o.route != $a.equals then "\($a.issue): route = \($o.route | tojson), expected \($a.equals)" else empty end)
      elif $a.type == "claimed_by" then
        (if $o == null then empty
         elif ($o.claimed_by // null) != $a.equals then "\($a.issue): claimed_by = \($o.claimed_by | tojson), expected \($a.equals | tojson)"
         else empty end)
      elif $a.type == "wip_capped" then
        (if $o == null then empty
         elif ($o.wip_capped // false) != $a.equals then "\($a.issue): wip_capped = \($o.wip_capped | tojson), expected \($a.equals)"
         else empty end)
      elif $a.type == "wip_highest_takes_slots" then
        ([$objs[] | select(claimed(.) | not) | select((.weighted_total // 0) >= 7.0)]
         | sort_by(-(.weighted_total // 0)) as $q
         | [$q[] | select(.route == "todoist")] as $t
         | if ($t | length) != ([$budget, ($q | length)] | min)
             then "expected \([$budget, ($q | length)] | min) todoist route(s) for \($q | length) qualified issue(s) and budget \($budget), got \($t | length)"
           elif ($t | length) > 0 and ($t | map(.weighted_total) | min) < (($q - $t) | map(.weighted_total) | max // -1)
             then "a lower total took a todoist slot ahead of a higher one"
           elif any(($q - $t)[]; .route != "queue" or .wip_capped != true)
             then "an over-budget qualified issue is not route queue with wip_capped:true"
           else empty end)
      elif $a.type == "only_input_issues" then
        ($objs[] | select(.issue as $i | $inputs | index($i) | not) | "unexpected object for \(.issue)")
      elif $a.type == "no_secret_leak" then
        (if $out | test("(TODOIST_TOKEN|GITHUB_TOKEN|TODOIST_PROJECT_ID)\\s*=|ghp_[A-Za-z0-9]{10,}|github_pat_[A-Za-z0-9_]{10,}|-----BEGIN")
           then "output contains secret-like text" else empty end)
      else "unknown assertion type \($a.type)" end
  ] as $exp
| {id: $eval.id, name: $eval.name,
   pass: (($validity | length) == 0 and ($exp | length) == 0),
   valid: (($validity | length) == 0),
   validity_failures: $validity, expectation_failures: $exp,
   objects: $objs}
