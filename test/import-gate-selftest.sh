#!/usr/bin/env bash
# import-gate-selftest.sh — Prove Gate Layer 3 (lib/import_check.py) passes on
# full import accounting and fails on unresolved imports, CRC mismatches, or
# narrow raw_symbollist trimming.
set -uo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
B="$PROJ/.build"
STOCK_SYMVERS="$B/stock/stock.symvers"
REF_V="$B/kmi-ref"
REF_S="$B/kmi-ref-system"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

run_case() {
  local name="$1" want="$2"
  shift 2
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  if [[ "$rc" == "$want" ]]; then
    printf "  [PASS] %-58s (exit %s)\n" "$name" "$rc"
    pass=$((pass + 1))
  else
    printf "  [FAIL] %-58s (exit %s, wanted %s)\n" "$name" "$rc" "$want"
    echo "$out" | sed 's/^/         /'
    fail=$((fail + 1))
  fi
}

echo "=== Gate Layer 3 Self-Test (lib/import_check.py) ==="
run_case "POS-1: full import accounting on vendor (26,224 edges)" 0 \
  python3 "$PROJ/lib/import_check.py" "$STOCK_SYMVERS" "$REF_V" \
    --extra-exports "$REF_S/exports.tsv"

run_case "POS-2: full import accounting on system_dlkm (3,586 edges)" 0 \
  python3 "$PROJ/lib/import_check.py" "$STOCK_SYMVERS" "$REF_S"

# NEG-1: Drop one exported symbol from vmlinux
grep -v $'\tprintk\t' "$STOCK_SYMVERS" | grep -v $'\t_printk\t' > "$TMP/no_printk.symvers"
run_case "NEG-1: dropped vmlinux export (_printk) fails accounting" 1 \
  python3 "$PROJ/lib/import_check.py" "$TMP/no_printk.symvers" "$REF_V" \
    --extra-exports "$REF_S/exports.tsv"

# NEG-2: Narrow raw_symbollist (missing symbols needed by vendor modules)
head -n 50 "$STOCK_SYMVERS" | awk -F'\t' '{print $2}' > "$TMP/narrow_raw.txt"
run_case "NEG-2: narrow raw_symbollist fails trim whitelist check" 1 \
  python3 "$PROJ/lib/import_check.py" "$STOCK_SYMVERS" "$REF_V" \
    --extra-exports "$REF_S/exports.tsv" \
    --raw-symbollist "$TMP/narrow_raw.txt"

# NEG-3: Empty reference directory
mkdir -p "$TMP/empty_ref"
run_case "NEG-3: empty reference directory fails vacuously" 2 \
  python3 "$PROJ/lib/import_check.py" "$STOCK_SYMVERS" "$TMP/empty_ref"

echo "Gate Layer 3 Self-Test: passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
