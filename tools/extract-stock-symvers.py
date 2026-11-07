#!/usr/bin/env python3
"""
extract-stock-symvers.py — Extract Module.symvers directly from an uncompressed
ARM64 GKI kernel Image (__ksymtab + __ksymtab_gpl + __kcrctab + __kcrctab_gpl).

On ARM64 GKI (CONFIG_HAVE_ARCH_PREL32_RELOCATIONS=y, !CONFIG_MODULE_REL_CRCS):
  - __ksymtab and __ksymtab_gpl are contiguous arrays of 12-byte
    `struct kernel_symbol { s32 value_offset; s32 name_offset; s32 namespace_offset; }`
  - Immediately following __ksymtab_gpl is __kcrctab and __kcrctab_gpl: a
    contiguous array of u32 CRCs with the exact same length and indexing.

Usage:
  python3 tools/extract-stock-symvers.py <uncompressed_kernel_image> <out_symvers>
"""
import struct
import sys


def valid_ident(b: bytes) -> bool:
    if not b or len(b) > 128:
        return False
    return all(
        (48 <= c <= 57) or (65 <= c <= 90) or (97 <= c <= 122) or c in (95, 46)
        for c in b
    )


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write(
            f"usage: {sys.argv[0]} <uncompressed_kernel_image> <out_symvers>\n"
        )
        return 2

    img_path, out_path = sys.argv[1], sys.argv[2]
    with open(img_path, "rb") as f:
        data = f.read()

    def get_sym(off: int):
        if off < 0 or off + 12 > len(data):
            return None
        v_off, n_off, ns_off = struct.unpack_from("<iii", data, off)
        if (
            abs(v_off) > 0x3000000
            or abs(n_off) > 0x200000
            or abs(ns_off) > 0x200000
        ):
            return None
        n_pos = off + 4 + n_off
        ns_pos = off + 8 + ns_off
        if not (0 <= n_pos < len(data) and 0 <= ns_pos < len(data)):
            return None
        n_end = data.find(b"\x00", n_pos, n_pos + 129)
        ns_end = data.find(b"\x00", ns_pos, ns_pos + 129)
        if n_end < 0 or ns_end < 0:
            return None
        name = data[n_pos:n_end]
        ns = data[ns_pos:ns_end]
        if not valid_ident(name) or (ns and not valid_ident(ns)):
            return None
        return (name.decode("ascii"), ns.decode("ascii"), off + v_off)

    # Locate the `module_layout` entry inside __ksymtab
    seed = None
    pos = 0
    while True:
        idx = data.find(b"module_layout\x00", pos)
        if idx < 0:
            break
        if idx == 0 or data[idx - 1] == 0:
            lo = max(0, idx - 0x200000) & ~3
            hi = min(len(data) - 12, idx + 0x200000)
            for off in range(lo, hi, 4):
                val = struct.unpack_from("<i", data, off)[0]
                if off + val == idx:
                    cand = off - 4
                    if get_sym(cand) and get_sym(cand - 12) and get_sym(cand + 12):
                        seed = cand
                        break
        if seed is not None:
            break
        pos = idx + 1

    if seed is None:
        sys.stderr.write(f"ERROR: could not locate __ksymtab in {img_path}\n")
        return 1

    start = seed
    while get_sym(start - 12):
        start -= 12
    end = seed
    while get_sym(end):
        end += 12

    count = (end - start) // 12
    if end + count * 4 > len(data):
        sys.stderr.write(f"ERROR: __kcrctab truncated in {img_path}\n")
        return 1

    # Find boundary between __ksymtab (EXPORT_SYMBOL) and __ksymtab_gpl (EXPORT_SYMBOL_GPL)
    # Both sections are sorted alphabetically by symbol name.
    rows = []
    gpl_split = None
    prev_name = ""
    for i in range(count):
        sym_off = start + i * 12
        name, ns, _ = get_sym(sym_off)
        if i > 0 and name < prev_name and gpl_split is None:
            gpl_split = i
        prev_name = name
        crc = struct.unpack_from("<I", data, end + i * 4)[0]
        export_type = (
            "EXPORT_SYMBOL"
            if (gpl_split is None or i < gpl_split)
            else "EXPORT_SYMBOL_GPL"
        )
        rows.append((crc, name, export_type, ns))

    with open(out_path, "w", encoding="utf-8") as out:
        for crc, name, export_type, ns in rows:
            if ns:
                out.write(f"0x{crc:08x}\t{name}\tvmlinux\t{export_type}\t{ns}\n")
            else:
                out.write(f"0x{crc:08x}\t{name}\tvmlinux\t{export_type}\n")

    ml_crc = next((c for c, n, _, _ in rows if n == "module_layout"), None)
    print(
        f"stock.symvers: extracted {count} symbols "
        f"(split at {gpl_split}, module_layout=0x{ml_crc:08x}) -> {out_path}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
