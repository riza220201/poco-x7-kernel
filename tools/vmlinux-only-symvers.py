#!/usr/bin/env python3
"""
vmlinux-only-symvers.py — Filter a Module.symvers file down to vmlinux rows only.

Why this exists:
  In-tree loadable modules (.ko) built from the kernel tree also get rows in
  Module.symvers with their module path in column 3. Gate Layer 1 must verify
  what vmlinux itself exports so an in-tree .ko we do not ship cannot mask a
  missing vmlinux export.

Usage:
  python3 tools/vmlinux-only-symvers.py <in_Module.symvers> <out_vmlinux.symvers>
"""
import sys


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(
            f"usage: {sys.argv[0]} <in_Module.symvers> <out_vmlinux.symvers>\n"
        )
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    kept = 0
    total = 0
    with open(src, "r", encoding="utf-8", errors="replace") as fin, open(
        dst, "w", encoding="utf-8"
    ) as fout:
        for line in fin:
            s = line.strip()
            if not s:
                continue
            parts = s.split("\t")
            if len(parts) < 4:
                parts = s.split()
            if len(parts) < 4:
                continue
            total += 1
            if parts[2] == "vmlinux":
                fout.write(line)
                kept += 1
    if kept == 0:
        sys.stderr.write(
            f"ERROR: 0 vmlinux rows found in {src} (out of {total} total rows)\n"
        )
        return 1
    print(f"vmlinux.symvers: kept {kept}/{total} vmlinux rows -> {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
