#!/usr/bin/env bash
set -euo pipefail
# End-to-end wiring in fake mode: build a packet, seed a Claude opening block,
# run a GPT opening via the runner (CODEX_FAKE), assert the transcript carries
# both. No paid calls.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BP="$HERE/../scripts/build_packet.sh"
CT="$HERE/../scripts/codex_turn.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

pkt="$("$BP" "Should we use approach A or B?")"
[ -s "$pkt" ] && ok || bad "packet not built"

tr="$(mktemp)"
printf '### Claude (opus) (round 0)\n\n**Position:** B\n**Argument:** B_scales.\n**Concedes:** nothing yet\n**Still unresolved:** cost\n\n' > "$tr"

gpt_open="$(mktemp)"; printf '**Position:** A\n**Argument:** A_is_simpler.\n**Concedes:** nothing yet\n**Still unresolved:** scale\n' > "$gpt_open"
CODEX_FAKE="$gpt_open" "$CT" "GPT (gpt-5.6-sol)" 0 opening "$pkt" "$tr" >/dev/null

grep -q "B_scales" "$tr"     && ok || bad "transcript missing Claude opening"
grep -q "A_is_simpler" "$tr" && ok || bad "transcript missing GPT opening"
grep -q "### Claude (opus) (round 0)" "$tr"      && ok || bad "missing Claude header"
grep -q "### GPT (gpt-5.6-sol) (round 0)" "$tr"  && ok || bad "missing GPT header"

echo "integration: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
