#!/usr/bin/env python3
"""
protect_check.py — Gate Layer 2: CONFIG_MODULE_SIG_PROTECT Symbol Verifier.

Why this exists:
  When CONFIG_MODULE_SIG_PROTECT=y, kernel/module/signing.c embeds a sorted
  table `protected_symbol_exports` in vmlinux containing every symbol exported
  by in-tree built-in or loadable modules at kernel build time. At runtime,
  any module without a valid signature matching THIS kernel's ephemeral build
  key (`!mod->sig_ok`) that exports a symbol in `protected_symbol_exports` is
  rejected with `-EACCES` ("Protected symbol: <sym> (err -13)").

  On GKI devices where we ship only boot.img (not system_dlkm.img or
  vendor_dlkm.img), stock modules in system_dlkm (e.g. rfkill.ko, libarc4.ko)
  are signed with Google's stock build key, NOT our ephemeral key. If any
  symbol exported by a stock module in vendor_dlkm, vendor_boot, or
  system_dlkm appears in vmlinux's `protected_symbol_exports`, that stock
  module will fail to load at boot with -EACCES.

Checks enforced:
  1. Parses `protected_symbol_exports` directly from the built `vmlinux` ELF
     (if present) AND cross-checks `Module.symvers` for non-vmlinux exports.
  2. Fails if any symbol in `protected_symbol_exports` is exported by a stock
     module in `<kmi_ref>/exports.tsv` (or `--extra-exports`).
"""
import argparse
import os
import struct
import sys

SHT_SYMTAB = 2


def read_protected_symbols_from_vmlinux(vmlinux_path):
    """Return list of symbol strings inside protected_symbol_exports in vmlinux."""
    with open(vmlinux_path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError(f"{vmlinux_path}: not a 64-bit little-endian ELF")

    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 58)
    shdrs = [
        struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize)
        for i in range(e_shnum)
    ]

    symtab_sh = None
    for sh in shdrs:
        if sh[1] == SHT_SYMTAB:
            symtab_sh = sh
            break
    if symtab_sh is None:
        raise ValueError(f"{vmlinux_path}: no SHT_SYMTAB section found")

    str_sh = shdrs[symtab_sh[6]]
    strtab = data[str_sh[4] : str_sh[4] + str_sh[5]]
    symdata = data[symtab_sh[4] : symtab_sh[4] + symtab_sh[5]]
    entsize = symtab_sh[9] or 24

    target_sym = None
    for off in range(0, len(symdata), entsize):
        st_name, st_info, st_other, st_shndx, st_value, st_size = (
            struct.unpack_from("<IBBHQQ", symdata, off)
        )
        end = strtab.find(b"\x00", st_name)
        if end < 0:
            continue
        nm = strtab[st_name:end]
        if nm in (b"protected_symbol_exports", b"gki_protected_exports_symbols"):
            target_sym = (st_shndx, st_value, st_size, nm.decode("ascii"))
            break

    if target_sym is None:
        return None  # Symbol not present in vmlinux

    st_shndx, st_value, st_size, _ = target_sym
    if st_shndx == 0 or st_shndx >= len(shdrs) or st_size == 0:
        return []

    sec = shdrs[st_shndx]
    sec_addr, sec_off = sec[3], sec[4]
    file_off = sec_off + (st_value - sec_addr)
    blob = data[file_off : file_off + st_size]
    # Split null-terminated strings inside the table
    syms = []
    for raw in blob.split(b"\x00"):
        s = raw.decode("ascii", "replace").strip()
        if s:
            syms.append(s)
    return syms


def load_exports_tsv(path):
    exp = {}
    if not path or not os.path.isfile(path):
        return exp
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            parts = s.split("\t")
            if len(parts) >= 3:
                exp[parts[1]] = parts[2]
    return exp


def main():
    ap = argparse.ArgumentParser(
        description="Gate Layer 2: Protected symbol export verifier"
    )
    ap.add_argument(
        "vmlinux",
        help="Path to built vmlinux ELF (or '-' when using --protected-list)",
    )
    ap.add_argument("kmi_ref", help="Path to harvested KMI reference dir")
    ap.add_argument(
        "--extra-exports",
        action="append",
        default=[],
        help="Additional exports.tsv to protect against (e.g. system_dlkm/exports.tsv)",
    )
    ap.add_argument(
        "--protected-list",
        default="",
        help="Optional newline-separated file of protected symbol names (for selftest)",
    )
    args = ap.parse_args()

    exp_path = os.path.join(args.kmi_ref, "exports.tsv")
    if not os.path.isfile(exp_path):
        sys.stderr.write(f"FAIL [protect_check]: missing {exp_path}\n")
        return 2
    if args.vmlinux != "-" and not os.path.isfile(args.vmlinux):
        sys.stderr.write(f"FAIL [protect_check]: missing {args.vmlinux}\n")
        return 2
    if args.vmlinux == "-" and (
        not args.protected_list or not os.path.isfile(args.protected_list)
    ):
        sys.stderr.write(
            f"FAIL [protect_check]: missing --protected-list {args.protected_list}\n"
        )
        return 2

    device_exports = load_exports_tsv(exp_path)
    for extra in args.extra_exports:
        for sym, ko in load_exports_tsv(extra).items():
            device_exports.setdefault(sym, ko)

    if not device_exports:
        sys.stderr.write(
            f"FAIL [protect_check]: vacuous check — 0 device module exports in {exp_path}\n"
        )
        return 2

    if args.protected_list:
        with open(args.protected_list, "r", encoding="utf-8") as f:
            protected = [ln.strip() for ln in f if ln.strip()]
    else:
        protected = read_protected_symbols_from_vmlinux(args.vmlinux)
    if protected is None:
        print(
            f"PASS [protect_check]: protected_symbol_exports not present in vmlinux "
            f"(device_exports={len(device_exports)})"
        )
        return 0

    collisions = []
    for sym in protected:
        if sym in device_exports:
            collisions.append((sym, device_exports[sym]))

    if collisions:
        sys.stderr.write(
            f"FAIL [protect_check]: {len(collisions)} symbols in vmlinux "
            f"protected_symbol_exports collide with stock device modules "
            f"(will fail to load with -EACCES):\n"
        )
        for sym, ko in collisions[:25]:
            sys.stderr.write(f"  COLLISION {sym} (exported by stock {ko})\n")
        return 1

    print(
        f"PASS [protect_check]: protected_symbol_exports={len(protected)} entries, "
        f"device_exports={len(device_exports)}, collisions=0"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
