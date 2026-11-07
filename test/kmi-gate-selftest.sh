#!/usr/bin/env bash
# kmi-gate-selftest.sh — Prove Gate Layer 1 (lib/kmi_check.py) passes on
# positive controls and fails on every negative control (CRC mismatch, missing
# symbol, wrong module_layout, wrong vermagic provenance, vacuous reference).
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

echo "=== Gate Layer 1 Self-Test (lib/kmi_check.py) ==="
run_case "POS-1: stock.symvers vs vendor (kmi-ref + system_dlkm)" 0 \
  python3 "$PROJ/lib/kmi_check.py" "$STOCK_SYMVERS" "$REF_V" \
    --extra-exports "$REF_S/exports.tsv" \
    --expect-vermagic "6.1.115-android14-11-g15551c4b2ca8" \
    --expect-module-layout "0xea759d7f"

run_case "POS-2: stock.symvers vs system_dlkm (kmi-ref-system)" 0 \
  python3 "$PROJ/lib/kmi_check.py" "$STOCK_SYMVERS" "$REF_S" \
    --expect-vermagic "6.1.115-android14-11-gfaa9b1b32a11-ab13269000" \
    --expect-module-layout "0xea759d7f"

# NEG-1: Perturb module_layout CRC
sed 's/^0xea759d7f\tmodule_layout/0xdeadbeef\tmodule_layout/' "$STOCK_SYMVERS" > "$TMP/bad_ml.symvers"
run_case "NEG-1: perturbed module_layout CRC must fail" 1 \
  python3 "$PROJ/lib/kmi_check.py" "$TMP/bad_ml.symvers" "$REF_V" \
    --extra-exports "$REF_S/exports.tsv" \
    --expect-module-layout "0xea759d7f"

# NEG-2: Perturb a single normal symbol CRC (__kmalloc)
sed 's/\t__kmalloc\t/\t__kmalloc_gone\t/' "$STOCK_SYMVERS" > "$TMP/missing_sym.symvers"
run_case "NEG-2: missing vmlinux symbol (__kmalloc) must fail" 1 \
  python3 "$PROJ/lib/kmi_check.py" "$TMP/missing_sym.symvers" "$REF_V" \
    --extra-exports "$REF_S/exports.tsv"

# NEG-3: Perturb CRC of a symbol without removing it
awk -F'\t' 'BEGIN{OFS="\t"} $2=="schedule"{$1="0x12345678"} {print}' "$STOCK_SYMVERS" > "$TMP/bad_crc.symvers"
run_case "NEG-3: single symbol CRC mismatch (schedule) must fail" 1 \
  python3 "$PROJ/lib/kmi_check.py" "$TMP/bad_crc.symvers" "$REF_V" \
    --extra-exports "$REF_S/exports.tsv"

# NEG-4: Wrong provenance vermagic
run_case "NEG-4: wrong provenance vermagic must fail" 1 \
  python3 "$PROJ/lib/kmi_check.py" "$STOCK_SYMVERS" "$REF_V" \
    --extra-exports "$REF_S/exports.tsv" \
    --expect-vermagic "6.12.23-android15"

# NEG-5: Empty / vacuous reference directory
mkdir -p "$TMP/empty"
run_case "NEG-5: vacuous empty reference directory must fail" 2 \
  python3 "$PROJ/lib/kmi_check.py" "$STOCK_SYMVERS" "$TMP/empty"

echo "Gate Layer 1 Self-Test: passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
