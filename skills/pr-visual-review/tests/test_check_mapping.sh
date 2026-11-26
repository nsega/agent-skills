#!/usr/bin/env bash
set -euo pipefail
# Zero-token checks for pr-visual-review's check_mapping.py: a fixture repo and
# reviews in a temp dir, covering all present, missing file, missing function
# and no table.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
CHECK="$SKILL_DIR/scripts/check_mapping.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/check_mapping.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

REPO="$TMP/repo"
mkdir -p "$REPO/order" "$REPO/payment"
cat > "$REPO/order/service.go" <<'EOF'
package order

type OrderService struct{}

func (s *OrderService) CreateOrder(req Request) (*Order, error) { return nil, nil }
EOF
cat > "$REPO/payment/client.go" <<'EOF'
package payment

type PaymentClient struct{}

func (c *PaymentClient) ChargeAll() error { return nil }
func (c *PaymentClient) Charge(amount int) (string, error) { return "", nil }
EOF

# review NAME ROWS: write a review whose node-mapping table holds ROWS.
review() {
  printf '## Structural review: demo\n\n### Node mapping (for verification)\n| Element in diagram | Maps to | Note |\n|---|---|---|\n%s\n\n### Review focus\nNone.\n' "$2" > "$TMP/$1.md"
}
# run NAME [ARGS]: check $TMP/NAME.md against the fixture repo; output in $TMP/out, exit code in $rc.
run() { local name="$1"; shift; rc=0; python3 "$CHECK" "$TMP/$name.md" --repo "$REPO" "$@" > "$TMP/out" 2>&1 || rc=$?; }
problems() { grep -cv "mappings checked" "$TMP/out" || true; }

# 1: SKILL.md points at the script.
grep -q "scripts/check_mapping.py" "$SKILL_DIR/SKILL.md" && ok || bad "SKILL.md does not mention scripts/check_mapping.py"
grep -q "check_mapping.py.*--base" "$SKILL_DIR/SKILL.md" && ok || bad "SKILL.md does not pass --base"

# 2: all present passes, including Type.method, a call suffix and an inferred note.
review present '| OrderService | `order/service.go:CreateOrder` | |
| PaymentClient | `payment/client.go:PaymentClient.Charge()` | call order inferred |'
run present
[ "$rc" -eq 0 ] && grep -q "2 mappings checked, 0 problems" "$TMP/out" && ok || bad "all present failed: $(cat "$TMP/out")"

# 3: a missing file fails with one line naming it.
review nofile '| OrderService | `order/service.go:CreateOrder` | |
| Ledger | `ledger/book.go:Post` | |'
run nofile
[ "$rc" -eq 1 ] && ok || bad "missing file exit $rc, want 1"
grep -q "nofile.md:7: Ledger: missing file: ledger/book.go" "$TMP/out" && ok || bad "missing file line wrong: $(cat "$TMP/out")"
[ "$(problems)" -eq 1 ] && ok || bad "missing file: want exactly one problem line: $(cat "$TMP/out")"

# 4: a missing function fails, and a longer name containing it does not count.
review nofunc '| PaymentClient | `payment/client.go:Refund` | |
| PaymentClient | `payment/client.go:ChargeA` | |'
run nofunc
[ "$rc" -eq 1 ] && ok || bad "missing function exit $rc, want 1"
grep -q "missing symbol: Refund not found in payment/client.go" "$TMP/out" && ok || bad "Refund not reported: $(cat "$TMP/out")"
grep -q "missing symbol: ChargeA not found" "$TMP/out" && ok || bad "prefix of ChargeAll counted as present: $(cat "$TMP/out")"
[ "$(problems)" -eq 2 ] && ok || bad "missing function: want two problem lines: $(cat "$TMP/out")"

# 5: no table fails, and a table inside a code fence does not count.
printf '## Structural review: demo\n\nNo structural change; diagram omitted.\n\n```markdown\n| Element in diagram | Maps to | Note |\n|---|---|---|\n| X | `nope.go:X` | |\n```\n' > "$TMP/notable.md"
run notable
[ "$rc" -eq 1 ] && grep -q "no node-mapping table found" "$TMP/out" && ok || bad "absent table not reported: rc=$rc $(cat "$TMP/out")"
grep -q "nope.go" "$TMP/out" && bad "fenced table was checked" || ok

# 6: a row with no file:function is a problem.
review bare '| OrderService | | |
| PaymentClient | `Charge` | |'
run bare
[ "$rc" -eq 1 ] && [ "$(problems)" -eq 2 ] && ok || bad "unmappable rows not reported: $(cat "$TMP/out")"

# 7: --repo defaults to the current directory.
rc=0; (cd "$REPO" && python3 "$CHECK" "$TMP/present.md") > "$TMP/out" 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "default --repo failed: $(cat "$TMP/out")"

# 8: bad usage and an unreadable review exit 2.
rc=0; python3 "$CHECK" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "no args exit $rc, want 2"
rc=0; python3 "$CHECK" "$TMP/absent.md" --repo "$REPO" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "unreadable review exit $rc, want 2"

# --- Before/after reviews and --base ---
# Fixture commits must not depend on the user's git config (it signs commits
# through a credential helper tests cannot reach).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G="$TMP/git"
mkdir -p "$G/order" "$G/payment"
g() { git -C "$G" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
g init -q
printf 'package order\n\nfunc CreateOrder() {}\nfunc validateLegacy() {}\n' > "$G/order/service.go"
printf 'package payment\n\nfunc ChargeOld() {}\n' > "$G/payment/legacy.go"
g add -A; g commit -q -m base; g tag base
printf 'package order\n\nfunc CreateOrder() {}\nfunc validate() {}\n' > "$G/order/service.go"
printf 'package payment\n\nfunc Charge() {}\n' > "$G/payment/client.go"
g rm -q payment/legacy.go
g add -A; g commit -q -m head
# runb NAME [ARGS]: check $TMP/NAME.md against the git fixture's head.
runb() { local name="$1"; shift; rc=0; python3 "$CHECK" "$TMP/$name.md" --repo "$G" "$@" > "$TMP/out" 2>&1 || rc=$?; }

cat > "$TMP/ba.md" <<'EOF'
## Structural review: retry after charge failure

### Node mapping (for verification)

#### Before
| Element in diagram | Maps to | Note |
|---|---|---|
| Validate | `order/service.go:validateLegacy` | renamed by this PR |
| LegacyCharge | `payment/legacy.go:ChargeOld` | removed by this PR |

#### After
| Element in diagram | Maps to | Note |
|---|---|---|
| Validate | `order/service.go:validate` | |
| PaymentClient | `payment/client.go:Charge` | |
EOF

# 9: a before/after review passes with --base, and fails without it on the removed nodes only.
runb ba --base base
[ "$rc" -eq 0 ] && grep -q "4 mappings checked, 0 problems" "$TMP/out" && ok || bad "before/after with --base failed: $(cat "$TMP/out")"
runb ba
[ "$rc" -eq 1 ] && [ "$(problems)" -eq 2 ] && ok || bad "before/after without --base: want 2 problems: $(cat "$TMP/out")"
grep -q "ba.md:8: Validate: missing symbol: validateLegacy not found in order/service.go$" "$TMP/out" && ok || bad "removed function not reported without --base: $(cat "$TMP/out")"
grep -q "missing file: payment/legacy.go$" "$TMP/out" && ok || bad "removed file not reported without --base: $(cat "$TMP/out")"

# 10: the side is enforced: a before-only name under After fails, and so does
# an after-only name marked "(before)" in its row.
cat > "$TMP/wrongside.md" <<'EOF'
### Node mapping (after)
| Element in diagram | Maps to | Note |
|---|---|---|
| Validate | `order/service.go:validateLegacy` | |
| PaymentClient | `payment/client.go:Charge` | (before) |
EOF
runb wrongside --base base
[ "$rc" -eq 1 ] && [ "$(problems)" -eq 2 ] && ok || bad "wrong side: want 2 problems: $(cat "$TMP/out")"
grep -q "missing symbol: validateLegacy not found in order/service.go$" "$TMP/out" && ok || bad "after-side node checked at base: $(cat "$TMP/out")"
grep -q "missing file at base: payment/client.go$" "$TMP/out" && ok || bad "(before) row not checked at base: $(cat "$TMP/out")"

# 11: a node with no side passes at either the head or the base, and one
# missing from both still fails.
review either '| Validate | `order/service.go:validateLegacy` | |
| PaymentClient | `payment/client.go:Charge` | |
| Ghost | `payment/ghost.go:Haunt` | |
| Nope | `order/service.go:Nope` | |'
runb either --base base
[ "$rc" -eq 1 ] && [ "$(problems)" -eq 2 ] && ok || bad "either side: want 2 problems: $(cat "$TMP/out")"
grep -q "Ghost: missing file at head or base: payment/ghost.go$" "$TMP/out" && ok || bad "file missing on both sides not reported: $(cat "$TMP/out")"
grep -q "Nope: missing symbol: Nope not found in order/service.go at head or base$" "$TMP/out" && ok || bad "symbol missing on both sides not reported: $(cat "$TMP/out")"
runb either
[ "$rc" -eq 1 ] && [ "$(problems)" -eq 3 ] && ok || bad "either side without --base: want 3 problems: $(cat "$TMP/out")"

# 12: a before-side node missing at the base too fails.
printf '#### Before\n| Element in diagram | Maps to | Note |\n|---|---|---|\n| Gone | `order/service.go:neverThere` | |\n' > "$TMP/beforemiss.md"
runb beforemiss --base base
[ "$rc" -eq 1 ] && grep -q "missing symbol: neverThere not found in order/service.go at base$" "$TMP/out" && ok || bad "before-side miss not reported: $(cat "$TMP/out")"

# 13: a --base git cannot resolve exits 2.
runb ba --base no-such-ref
[ "$rc" -eq 2 ] && ok || bad "bad --base exit $rc, want 2"

# --- Unparseable mapping-like tables ---

# 14: a table with `file:` cells that cannot be parsed warns and is skipped
# without failing; a plain table with no `file:` cells stays silent.
cat > "$TMP/warn.md" <<'EOF'
### Node mapping (for verification)
| Element in diagram | Maps to | Note |
|---|---|---|
| OrderService | `order/service.go:CreateOrder` | |

### Also touched
| Element | Location |
|---|---|
| PaymentClient | `payment/client.go:Charge` |

### Node mapping, second diagram
| OrderService | `order/service.go:CreateOrder` |
| PaymentClient | `payment/client.go:Charge` |

### Risk
| Area | Level |
|---|---|
| payments | high |
EOF
run warn
[ "$rc" -eq 0 ] && grep -q "1 mappings checked, 0 problems" "$TMP/out" && ok || bad "warning failed the run: rc=$rc $(cat "$TMP/out")"
[ "$(grep -c '^warn:' "$TMP/out")" -eq 2 ] && ok || bad "want 2 warnings: $(cat "$TMP/out")"
grep -q '^warn: .*warn.md:7: .*no "Maps to" column' "$TMP/out" && ok || bad "no-Maps-to table not named: $(cat "$TMP/out")"
grep -q '^warn: .*warn.md:12: .*no |---| row' "$TMP/out" && ok || bad "separator-less table not named: $(cat "$TMP/out")"

echo "pr-visual-review: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
