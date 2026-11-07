#!/usr/bin/env python3
"""
kmi_check.py — Gate Layer 1: KMI ABI / Modversions CRC & Provenance Verifier.

Compares a kernel build's vmlinux.symvers against a harvested KMI reference
directory (<kmi_ref>/{required.tsv,exports.tsv,summary.txt}).

Checks enforced:
  1. Non-empty reference baseline (vacuous-pass guard: ko_count >= 1,
     required symbols >= 1, checked vmlinux symbols >= min_checked).
  2. Reference provenance (if --expect-vermagic is given, summary.txt must
     contain that vermagic string).
  3. Exact module_layout CRC match against --expect-module-layout (if given)
     and against the reference's required.tsv.
  4. Every symbol in required.tsv that is NOT exported by a sibling .ko in
     exports.tsv (or --extra-exports) must be present in vmlinux.symvers with
     the exact same 32-bit CRC.
  5. Every symbol resolved via exports.tsv or --extra-exports must have the
     exact same 32-bit CRC between exporter and importer.
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
            if len(parts) < 4:
                parts = s.split()
            if len(parts) < 4:
                continue
            crc_s, sym, mod = parts[0], parts[1], parts[2]
            try:
                crc = int(crc_s, 16)
            except ValueError:
                continue
            # Prefer vmlinux if duplicate exists
            if sym not in syms or mod == "vmlinux":
                syms[sym] = (crc, mod)
    return syms


def load_required(path):
    req = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            parts = s.split("\t")
            crc = int(parts[0], 16)
            sym = parts[1]
            cnt = int(parts[2]) if len(parts) > 2 else 1
            ex_ko = parts[3] if len(parts) > 3 else "?"
            req[sym] = (crc, cnt, ex_ko)
    return req


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


def load_summary(path):
    info = {"vermagics": []}
    if not os.path.isfile(path):
        return info
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if ":" not in s:
                continue
            k, v = [x.strip() for x in s.split(":", 1)]
            if k.startswith("vermagic["):
                info["vermagics"].append(v)
            else:
                info[k] = v
    return info


def main():
    ap = argparse.ArgumentParser(description="Gate Layer 1: KMI ABI verifier")
    ap.add_argument("symvers", help="Path to vmlinux.symvers or Module.symvers")
    ap.add_argument("kmi_ref", help="Path to harvested KMI reference dir")
    ap.add_argument(
        "--extra-exports",
        action="append",
        default=[],
        help="Additional sibling exports.tsv (e.g. system_dlkm/exports.tsv)",
    )
    ap.add_argument(
        "--expect-vermagic",
        default="",
        help="Substring required in summary.txt vermagic",
    )
    ap.add_argument(
        "--expect-module-layout",
        default="",
        help="Expected module_layout CRC hex (e.g. 0xea759d7f)",
    )
    ap.add_argument(
        "--min-checked",
        type=int,
        default=100,
        help="Minimum vmlinux symbols that must be checked (vacuous-pass guard)",
    )
    args = ap.parse_args()

    req_path = os.path.join(args.kmi_ref, "required.tsv")
    exp_path = os.path.join(args.kmi_ref, "exports.tsv")
    sum_path = os.path.join(args.kmi_ref, "summary.txt")

    for p in (args.symvers, req_path, exp_path, sum_path):
        if not os.path.isfile(p):
            sys.stderr.write(f"FAIL [kmi_check]: missing required file: {p}\n")
            return 2

    summary = load_summary(sum_path)
    ko_count = int(summary.get("ko_count", "0"))
    if ko_count < 1:
        sys.stderr.write(
            f"FAIL [kmi_check]: vacuous reference (ko_count={ko_count})\n"
        )
        return 2

    if args.expect_vermagic:
        vms = summary.get("vermagics", [])
        if not any(args.expect_vermagic in vm for vm in vms):
            sys.stderr.write(
                f"FAIL [kmi_check]: provenance mismatch: expected vermagic containing "
                f"'{args.expect_vermagic}', got {vms}\n"
            )
            return 1

    symvers = load_symvers(args.symvers)
    if not symvers:
        sys.stderr.write(
            f"FAIL [kmi_check]: symvers file is empty: {args.symvers}\n"
        )
        return 2

    required = load_required(req_path)
    if not required:
        sys.stderr.write(
            f"FAIL [kmi_check]: required.tsv is empty: {req_path}\n"
        )
        return 2

    sibling_exports = load_exports(exp_path)
    for extra in args.extra_exports:
        for sym, val in load_exports(extra).items():
            sibling_exports.setdefault(sym, val)

    if args.expect_module_layout:
        exp_ml = int(args.expect_module_layout, 16)
        if "module_layout" not in symvers:
            sys.stderr.write(
                "FAIL [kmi_check]: module_layout missing from symvers\n"
            )
            return 1
        got_ml = symvers["module_layout"][0]
        if got_ml != exp_ml:
            sys.stderr.write(
                f"FAIL [kmi_check]: module_layout CRC mismatch: "
                f"built=0x{got_ml:08x} expected=0x{exp_ml:08x}\n"
            )
            return 1

    checked_vmlinux = 0
    checked_sibling = 0
    missing = []
    mismatched = []

    for sym, (req_crc, cnt, ex_ko) in sorted(required.items()):
        if sym in symvers:
            built_crc, _ = symvers[sym]
            if built_crc != req_crc:
                mismatched.append((sym, req_crc, built_crc, cnt, ex_ko, "vmlinux"))
            else:
                checked_vmlinux += 1
        elif sym in sibling_exports:
            sib_crc, sib_ko = sibling_exports[sym]
            if sib_crc != req_crc:
                mismatched.append((sym, req_crc, sib_crc, cnt, ex_ko, sib_ko))
            else:
                checked_sibling += 1
        else:
            missing.append((sym, req_crc, cnt, ex_ko))

    if checked_vmlinux < args.min_checked:
        sys.stderr.write(
            f"FAIL [kmi_check]: vacuous check guard triggered: only {checked_vmlinux} "
            f"vmlinux symbols checked (min_checked={args.min_checked})\n"
        )
        return 2

    if missing or mismatched:
        sys.stderr.write(
            f"FAIL [kmi_check]: ref={args.kmi_ref} checked_vmlinux={checked_vmlinux} "
            f"checked_sibling={checked_sibling} missing={len(missing)} "
            f"mismatched={len(mismatched)}\n"
        )
        for sym, req_crc, cnt, ex_ko in missing[:25]:
            sys.stderr.write(
                f"  MISSING  {sym} (want 0x{req_crc:08x}, used by {cnt} ko, e.g. {ex_ko})\n"
            )
        for sym, req_crc, got_crc, cnt, ex_ko, src in mismatched[:25]:
            sys.stderr.write(
                f"  MISMATCH {sym}: ko wants 0x{req_crc:08x}, {src} has 0x{got_crc:08x} "
                f"(used by {cnt} ko, e.g. {ex_ko})\n"
            )
        return 1

    ml_crc = symvers.get("module_layout", (0, ""))[0]
    print(
        f"PASS [kmi_check]: ref={os.path.basename(args.kmi_ref)} "
        f"kos={ko_count} vmlinux_matched={checked_vmlinux} "
        f"sibling_matched={checked_sibling} module_layout=0x{ml_crc:08x} "
        f"missing=0 mismatched=0"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
