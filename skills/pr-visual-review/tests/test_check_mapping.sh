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

echo "pr-visual-review: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
