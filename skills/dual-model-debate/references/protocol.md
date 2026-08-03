# Debate protocol

Shared by both debaters and the chair. The debaters argue; the chair (the main
Claude context) never argues, it decides.

## Turn format

Every debater turn is these four fields, in this order, and nothing else. The
harness adds the `### <role> (round N)` heading; do not write your own heading.

```markdown
**Position:** <one line: your recommended answer to the Question>
**Argument:** <your case; prose, may be several paragraphs; cite the packet>
**Concedes:** <points from the other debater you grant this turn, or "nothing yet">
**Still unresolved:** <the specific disagreements this turn does not settle>
```

## Roles

### Honest opening (round 0)
Give your genuine recommended answer to the Question, argued from the packet
only. You have not seen the other debater. Take a real position; do not hedge to
a safe middle. If the packet is genuinely underspecified, say exactly what is
missing and answer under your stated assumption.

### Rebuttal (rounds 1-2)
Respond to the other debater's latest Position and Argument specifically. Grant
what is correct under Concedes. Advance the disagreement: add a new argument,
counter a specific claim, or narrow what is left. Do not restate a prior turn
without adding something. If you have nothing new, say so in one line under
Argument so the chair can stop.

### Forced opposition
Both debaters reached the same answer. Now argue, in good faith, the strongest
case AGAINST that consensus, even though you may believe it. Surface the best
reasons it could be wrong: the failure mode, the missed alternative, the
assumption that may not hold.

## Debate discipline

- Argue only from the packet and the transcript. Do not run tools or read files.
- Cite specifics from the Question, Framing, or Context, not vibes.
- Concede honestly; a debate that never concedes is not converging on truth.
- No fence-sitting unless the packet truly cannot support a call.

## Chair: synthesis and escalation

The chair reads the whole transcript fresh, having argued nothing.

1. **Stall check.** Stop rebuttals when a round adds no new substantive argument:
   no new claim, no new counter, no narrowing of what is unresolved. Two turns
   that only restate prior positions are a stall.
2. **Decide.** Pick the answer best supported by the debate, not the one argued
   most loudly. State the deciding rationale.
3. **Escalate, do not self-rule.** Send the decision to the human instead of
   deciding when ALL of these hold: the conflict is unresolved, it is a
   subjective / which-approach call, and the only remaining tiebreak is your own
   preference. Also escalate any unresolved conflict on an irreversible or
   high-stakes axis (security, data loss, migration, public API), regardless of
   subjectivity.
4. **Agreement is not verification.** When both debaters simply agreed without
   independently grounding the claim, label it "agreement, not verification" and
   do not treat it as proof.
