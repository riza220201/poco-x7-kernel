#!/usr/bin/env python3
"""
harvest-kmi-ref.py — Harvest KMI reference baseline from a directory of .ko modules.

Walks every *.ko under the given directory and writes to <out_dir>:
  required.tsv   <crc_hex>\t<symbol>\t<ko_count>\t<example_ko>
  per-module.tsv <ko_basename>\t<symbol>\t<crc_hex>
  exports.tsv    <crc_hex>\t<symbol>\t<exporting_ko>
  summary.txt    human-readable summary (including module_layout CRC and vermagic)
"""
import collections
import glob
import os
import struct
import sys

SHN_UNDEF = 0
SHT_SYMTAB = 2


def parse_ko(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError(f"{path}: not 64-bit little-endian ELF")

    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 58)

    shdrs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        shdrs.append(struct.unpack_from("<IIQQQQIIQQ", data, off))

    shstr_off, shstr_sz = shdrs[e_shstrndx][4], shdrs[e_shstrndx][5]
    shstr = data[shstr_off : shstr_off + shstr_sz]

    def sname(idx):
        end = shstr.find(b"\x00", idx)
        return shstr[idx:end].decode("ascii", "replace")

    sec_by_name = {}
    symtab_idx = None
    for i, sh in enumerate(shdrs):
        nm = sname(sh[0])
        sec_by_name[nm] = (i, sh)
        if sh[1] == SHT_SYMTAB:
            symtab_idx = i

    # Imports: __versions section (64-byte modversion_info records: u64 crc + char name[56])
    imports = {}
    if "__versions" in sec_by_name:
        _, sh = sec_by_name["__versions"]
        vdata = data[sh[4] : sh[4] + sh[5]]
        for off in range(0, len(vdata), 64):
            if off + 64 > len(vdata):
                break
            crc = struct.unpack_from("<Q", vdata, off)[0]
            raw = vdata[off + 8 : off + 64]
            end = raw.find(b"\x00")
            sym = raw[:end].decode("ascii", "replace") if end >= 0 else ""
            if sym:
                imports[sym] = crc

    # Exports: __crc_<sym> symbols in .symtab
    exports = {}
    if symtab_idx is not None:
        sh = shdrs[symtab_idx]
        str_sh = shdrs[sh[6]]
        strtab = data[str_sh[4] : str_sh[4] + str_sh[5]]
        symdata = data[sh[4] : sh[4] + sh[5]]
        entsize = sh[9] or 24
        for off in range(0, len(symdata), entsize):
            st_name, st_info, st_other, st_shndx, st_value, st_size = (
                struct.unpack_from("<IBBHQQ", symdata, off)
            )
            end = strtab.find(b"\x00", st_name)
            nm = strtab[st_name:end].decode("ascii", "replace")
            if nm.startswith("__crc_") and st_shndx != SHN_UNDEF:
                sym = nm[6:]
                if 0 < st_shndx < len(shdrs):
                    sec_sh = shdrs[st_shndx]
                    file_off = sec_sh[4] + st_value
                    if file_off + 4 <= len(data):
                        crc = struct.unpack_from("<I", data, file_off)[0]
                    else:
                        crc = st_value & 0xFFFFFFFF
                else:
                    crc = st_value & 0xFFFFFFFF
                exports[sym] = crc

    # Modinfo: vermagic, name, depends
    modinfo = {}
    if ".modinfo" in sec_by_name:
        _, sh = sec_by_name[".modinfo"]
        mdata = data[sh[4] : sh[4] + sh[5]]
        for entry in mdata.split(b"\x00"):
            if b"=" in entry:
                k, v = entry.split(b"=", 1)
                modinfo[k.decode("ascii", "replace")] = v.decode(
                    "ascii", "replace"
                )

    return imports, exports, modinfo


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(f"usage: {sys.argv[0]} <ko_dir> <out_dir>\n")
        return 2

    ko_dir, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    kos = sorted(
        glob.glob(os.path.join(ko_dir, "**", "*.ko"), recursive=True)
    )
    if not kos:
        sys.stderr.write(f"ERROR: no .ko files under {ko_dir}\n")
        return 1

    req_by_sym = collections.defaultdict(list)
    per_mod = []
    exports_list = []
    vermagics = collections.Counter()
    mod_layout_crcs = collections.Counter()
    crc_conflicts = {}

    for p in kos:
        base = os.path.basename(p)
        imports, exports, modinfo = parse_ko(p)
        if "vermagic" in modinfo:
            vermagics[modinfo["vermagic"]] += 1
        if "module_layout" in imports:
            mod_layout_crcs[imports["module_layout"]] += 1
        for sym, crc in sorted(imports.items()):
            req_by_sym[sym].append((crc, base))
            per_mod.append((base, sym, crc))
        for sym, crc in sorted(exports.items()):
            exports_list.append((crc, sym, base))

    req_path = os.path.join(out_dir, "required.tsv")
    with open(req_path, "w") as f:
        for sym in sorted(req_by_sym):
            entries = req_by_sym[sym]
            crcs = {c for c, _ in entries}
            if len(crcs) > 1:
                crc_conflicts[sym] = entries
            crc0, ex_ko = entries[0]
            f.write(f"0x{crc0:08x}\t{sym}\t{len(entries)}\t{ex_ko}\n")

    pm_path = os.path.join(out_dir, "per-module.tsv")
    with open(pm_path, "w") as f:
        for base, sym, crc in per_mod:
            f.write(f"{base}\t{sym}\t0x{crc:08x}\n")

    ex_path = os.path.join(out_dir, "exports.tsv")
    with open(ex_path, "w") as f:
        for crc, sym, base in sorted(exports_list, key=lambda x: (x[1], x[2])):
            f.write(f"0x{crc:08x}\t{sym}\t{base}\n")

    exported_set = {sym for _, sym, _ in exports_list}
    vmlinux_needed = {s for s in req_by_sym if s not in exported_set}

    sum_path = os.path.join(out_dir, "summary.txt")
    with open(sum_path, "w") as f:
        f.write(f"ko_count: {len(kos)}\n")
        f.write(f"unique_imported_symbols: {len(req_by_sym)}\n")
        f.write(f"unique_exported_by_kos: {len(exported_set)}\n")
        f.write(f"imported_from_vmlinux: {len(vmlinux_needed)}\n")
        f.write(f"total_import_edges: {len(per_mod)}\n")
        f.write(f"internal_crc_conflicts: {len(crc_conflicts)}\n")
        for vm, cnt in vermagics.most_common():
            f.write(f"vermagic[{cnt}]: {vm}\n")
        for crc, cnt in mod_layout_crcs.most_common():
            f.write(f"module_layout_crc[{cnt}]: 0x{crc:08x}\n")

    print(open(sum_path).read().rstrip())
    if crc_conflicts:
        sys.stderr.write(
            f"WARNING: {len(crc_conflicts)} symbols have conflicting CRCs across .ko files\n"
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
