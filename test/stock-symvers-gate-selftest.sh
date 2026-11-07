#!/usr/bin/env bash
# stock-symvers-gate-selftest.sh — Prove Gate Layer 4 (lib/stock_symvers_check.py)
# passes when built vmlinux.symvers matches stock.symvers and fails on drift.
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

echo "=== Gate Layer 4 Self-Test (lib/stock_symvers_check.py) ==="
run_case "POS-1: stock.symvers self-parity (7,996 symbols)" 0 \
  python3 "$PROJ/lib/stock_symvers_check.py" "$STOCK_SYMVERS" "$STOCK_SYMVERS" \
    --required-tsv "$REF_V/required.tsv" \
    --required-tsv "$REF_S/required.tsv" \
    --strict-all-stock

awk -F'\t' 'BEGIN{OFS="\t"} $2=="module_layout"{$1="0x11111111"} {print}' "$STOCK_SYMVERS" > "$TMP/bad.symvers"
run_case "NEG-1: CRC drift in stock export fails" 1 \
  python3 "$PROJ/lib/stock_symvers_check.py" "$TMP/bad.symvers" "$STOCK_SYMVERS" \
    --required-tsv "$REF_V/required.tsv" \
    --required-tsv "$REF_S/required.tsv"

echo "Gate Layer 4 Self-Test: passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
