#!/usr/bin/env python3
"""
stock_symvers_check.py — Gate Layer 4: Direct Stock vmlinux Symvers Parity Gate.

Compares our built `vmlinux.symvers` directly against `.build/stock/stock.symvers`
(extracted from the stock boot.img's uncompressed kernel `__ksymtab`/`__kcrctab`).

Checks enforced:
  1. Every symbol in stock.symvers that is required by any device module (or, if
     --strict-all-stock is passed, every single symbol in stock.symvers) must be
     exported by our built vmlinux.symvers with the exact same 32-bit CRC.
  2. Reports full parity statistics across all ~7,996 stock GKI exports.
"""
import argparse
import os
import sys


def load_symvers(path):
    syms = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            parts = s.split("\t")
            if len(parts) < 2:
                parts = s.split()
            if len(parts) >= 2:
                syms[parts[1]] = int(parts[0], 16)
    return syms


def main():
    ap = argparse.ArgumentParser(
        description="Gate Layer 4: Direct stock boot.img vmlinux symvers parity check"
    )
    ap.add_argument("built_vmlinux_symvers", help="Path to built vmlinux.symvers")
    ap.add_argument("stock_symvers", help="Path to .build/stock/stock.symvers")
    ap.add_argument(
        "--required-tsv",
        action="append",
        default=[],
        help="Path(s) to required.tsv files whose vmlinux symbols must 100%% match",
    )
    ap.add_argument(
        "--strict-all-stock",
        action="store_true",
        help="Fail on ANY missing or CRC-mismatched symbol across all stock exports",
    )
    args = ap.parse_args()

    for p in [args.built_vmlinux_symvers, args.stock_symvers] + args.required_tsv:
        if not os.path.isfile(p):
            sys.stderr.write(f"FAIL [stock_symvers_check]: missing {p}\n")
            return 2

    built = load_symvers(args.built_vmlinux_symvers)
    stock = load_symvers(args.stock_symvers)

    if len(built) < 1000 or len(stock) < 1000:
        sys.stderr.write(
            f"FAIL [stock_symvers_check]: vacuous symvers (built={len(built)}, stock={len(stock)})\n"
        )
        return 2

    req_syms = set()
    for rpath in args.required_tsv:
        with open(rpath, "r", encoding="utf-8") as f:
            for line in f:
                p = line.strip().split("\t")
                if len(p) >= 2 and p[1] in stock:
                    req_syms.add(p[1])

    all_matched = 0
    all_mismatched = []
    all_missing = []
    req_mismatched = []
    req_missing = []

    for sym, s_crc in sorted(stock.items()):
        if sym not in built:
            all_missing.append((sym, s_crc))
            if sym in req_syms:
                req_missing.append((sym, s_crc))
        elif built[sym] != s_crc:
            all_mismatched.append((sym, s_crc, built[sym]))
            if sym in req_syms:
                req_mismatched.append((sym, s_crc, built[sym]))
        else:
            all_matched += 1

    fail_missing = all_missing if args.strict_all_stock else req_missing
    fail_mismatched = all_mismatched if args.strict_all_stock else req_mismatched

    if fail_missing or fail_mismatched:
        sys.stderr.write(
            f"FAIL [stock_symvers_check]: stock_total={len(stock)} "
            f"all_matched={all_matched} all_missing={len(all_missing)} "
            f"all_mismatched={len(all_mismatched)} "
            f"req_missing={len(req_missing)} req_mismatched={len(req_mismatched)}\n"
        )
        for sym, s_crc in fail_missing[:25]:
            sys.stderr.write(f"  MISSING  {sym} (stock=0x{s_crc:08x})\n")
        for sym, s_crc, b_crc in fail_mismatched[:25]:
            sys.stderr.write(
                f"  MISMATCH {sym}: stock=0x{s_crc:08x} built=0x{b_crc:08x}\n"
            )
        return 1

    print(
        f"PASS [stock_symvers_check]: stock_total={len(stock)} "
        f"built_total={len(built)} all_matched={all_matched}/{len(stock)} "
        f"all_missing={len(all_missing)} all_mismatched={len(all_mismatched)} "
        f"req_checked={len(req_syms)} req_missing=0 req_mismatched=0"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
