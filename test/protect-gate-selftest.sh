#!/usr/bin/env bash
# protect-gate-selftest.sh — Prove Gate Layer 2 (lib/protect_check.py) passes
# when protected_symbol_exports is empty and fails when stock module exports
# (e.g. rfkill_alloc, arc4_crypt) are listed as protected.
set -uo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
B="$PROJ/.build"
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

echo "=== Gate Layer 2 Self-Test (lib/protect_check.py) ==="
: > "$TMP/empty_protected.txt"
run_case "POS-1: empty protected_symbol_exports passes" 0 \
  python3 "$PROJ/lib/protect_check.py" - "$REF_V" \
    --extra-exports "$REF_S/exports.tsv" \
    --protected-list "$TMP/empty_protected.txt"

printf "rfkill_alloc\narc4_crypt\n" > "$TMP/wifi_break.txt"
run_case "NEG-1: protected rfkill_alloc + arc4_crypt fails (-EACCES)" 1 \
  python3 "$PROJ/lib/protect_check.py" - "$REF_V" \
    --extra-exports "$REF_S/exports.tsv" \
    --protected-list "$TMP/wifi_break.txt"

mkdir -p "$TMP/empty_ref"
run_case "NEG-2: missing exports.tsv fails vacuously" 2 \
  python3 "$PROJ/lib/protect_check.py" - "$TMP/empty_ref" \
    --protected-list "$TMP/empty_protected.txt"

echo "Gate Layer 2 Self-Test: passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
