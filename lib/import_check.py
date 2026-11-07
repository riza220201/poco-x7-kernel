#!/usr/bin/env python3
"""
import_check.py — Gate Layer 3: Full Module Import Accounting & Trim Whitelist Gate.

Why this exists:
  1. Every symbol imported by every stock .ko in <kmi_ref>/per-module.tsv must
     be accounted for:
       from_vmlinux + from_sibling + unresolved == total_imports
     and unresolved MUST be 0.
  2. When CONFIG_TRIM_UNUSED_KSYMS=y, vmlinux only exports symbols listed in
     `raw_symbollist` / `abi_symbollist.raw`. If a raw symbol list is provided
     (--raw-symbollist), every symbol resolved from vmlinux must also be
     present in that whitelist.
"""
import argparse
import os
import sys


def load_vmlinux_symvers(path):
    syms = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            parts = s.split("\t")
            if len(parts) < 4:
                parts = s.split()
            if len(parts) >= 4 and parts[2] == "vmlinux":
                syms[parts[1]] = int(parts[0], 16)
    return syms


def load_exports(path):
    exp = {}
    if path and os.path.isdir(path):
        path = os.path.join(path, "exports.tsv")
    if not path or not os.path.isfile(path):
        return exp
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            parts = s.split("\t")
            if len(parts) >= 3:
                exp[parts[1]] = (int(parts[0], 16), parts[2])
    return exp


def load_raw_symbollist(path):
    if not path or not os.path.isfile(path):
        return None
    allowed = set()
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip()
            if s and not s.startswith("#") and not s.startswith("["):
                allowed.add(s)
    return allowed


def main():
    ap = argparse.ArgumentParser(
        description="Gate Layer 3: Full import accounting & trim whitelist verifier"
    )
    ap.add_argument("vmlinux_symvers", help="Path to vmlinux.symvers")
    ap.add_argument("kmi_ref", help="Path to harvested KMI reference dir")
    ap.add_argument(
        "--extra-exports",
        action="append",
        default=[],
        help="Additional sibling exports.tsv (e.g. system_dlkm/exports.tsv)",
    )
    ap.add_argument(
        "--raw-symbollist",
        default="",
        help="Optional path to raw_symbollist / abi_symbollist.raw",
    )
    args = ap.parse_args()

    pm_path = os.path.join(args.kmi_ref, "per-module.tsv")
    exp_path = os.path.join(args.kmi_ref, "exports.tsv")
    for p in (args.vmlinux_symvers, pm_path, exp_path):
        if not os.path.isfile(p):
            sys.stderr.write(f"FAIL [import_check]: missing {p}\n")
            return 2

    vmlinux = load_vmlinux_symvers(args.vmlinux_symvers)
    if not vmlinux:
        sys.stderr.write(
            f"FAIL [import_check]: 0 vmlinux symbols in {args.vmlinux_symvers}\n"
        )
        return 2

    sibling = load_exports(exp_path)
    for extra in args.extra_exports:
        for sym, val in load_exports(extra).items():
            sibling.setdefault(sym, val)

    whitelist = load_raw_symbollist(args.raw_symbollist)

    total_edges = 0
    from_vmlinux = 0
    from_sibling = 0
    unresolved = []
    crc_bad = []
    unwhitelisted = []

    with open(pm_path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            ko, sym, crc_s = s.split("\t")
            crc = int(crc_s, 16)
            total_edges += 1
            if sym in vmlinux:
                from_vmlinux += 1
                if vmlinux[sym] != crc:
                    crc_bad.append((ko, sym, crc, vmlinux[sym], "vmlinux"))
                if (
                    whitelist is not None
                    and sym != "module_layout"
                    and sym not in whitelist
                ):
                    unwhitelisted.append((ko, sym))
            elif sym in sibling:
                from_sibling += 1
                sib_crc, sib_ko = sibling[sym]
                if sib_crc != crc:
                    crc_bad.append((ko, sym, crc, sib_crc, sib_ko))
            else:
                unresolved.append((ko, sym, crc))

    if total_edges == 0:
        sys.stderr.write(
            f"FAIL [import_check]: vacuous check — 0 edges in {pm_path}\n"
        )
        return 2

    assert from_vmlinux + from_sibling + len(unresolved) == total_edges

    if unresolved or crc_bad or unwhitelisted:
        sys.stderr.write(
            f"FAIL [import_check]: ref={args.kmi_ref} total_edges={total_edges} "
            f"from_vmlinux={from_vmlinux} from_sibling={from_sibling} "
            f"unresolved={len(unresolved)} crc_bad={len(crc_bad)} "
            f"unwhitelisted={len(unwhitelisted)}\n"
        )
        for ko, sym, crc in unresolved[:20]:
            sys.stderr.write(
                f"  UNRESOLVED {ko} -> {sym} (0x{crc:08x})\n"
            )
        for ko, sym, want, got, src in crc_bad[:20]:
            sys.stderr.write(
                f"  CRC_BAD    {ko} -> {sym}: wants 0x{want:08x}, {src} has 0x{got:08x}\n"
            )
        for ko, sym in unwhitelisted[:20]:
            sys.stderr.write(
                f"  NOT_IN_RAW_SYMBOLLIST {ko} -> {sym}\n"
            )
        return 1

    print(
        f"PASS [import_check]: ref={os.path.basename(args.kmi_ref)} "
        f"total_edges={total_edges} from_vmlinux={from_vmlinux} "
        f"from_sibling={from_sibling} unresolved=0 crc_bad=0 "
        f"unwhitelisted=0"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
