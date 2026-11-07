#!/usr/bin/env bash
# extract-device-material.sh — Unpack stock images and harvest KMI reference baselines
# for Xiaomi Poco X7 / Redmi Note 14 Pro 5G (malachite, OS2.0.206.0.VOOMIXM).
#
# Inputs (expected in project root):
#   boot.img           GKI v4 boot image (6.1.115-android14-11-gfaa9b1b32a11)
#   vendor_dlkm.img    EROFS image with vendor kernel modules (.ko)
#   odm_dlkm.img       EROFS image (optional .ko modules)
#   vendor_boot.img    VNDRBOOT v4 image with first-stage ramdisk .ko modules + DTB
#   system_dlkm.img    EROFS image with GKI in-tree loadable modules (.ko)
#
# Outputs (written under .build/):
#   .build/stock/                 unpacked stock boot.img + stock.symvers (all vmlinux exports)
#   .build/ikconfig/stock.config  extracted IKCONFIG from stock kernel
#   .build/kmi-ref/               vendor_dlkm + vendor_boot (+ odm_dlkm) .ko files + TSV baselines
#   .build/kmi-ref-system/        system_dlkm .ko files + TSV baselines
#   .build/vendor_boot/           unpacked vendor_boot ramdisks, bootconfig, vendor_boot.dtb/.dts
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
B="$PROJ/.build"

for f in boot.img vendor_dlkm.img vendor_boot.img system_dlkm.img; do
  [[ -f "$PROJ/$f" ]] || { echo "ERROR: missing $PROJ/$f" >&2; exit 1; }
done

for tool in magiskboot fsck.erofs cpio lz4 python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not in PATH" >&2; exit 1; }
done

echo "=== [1/6] Unpacking stock boot.img & extracting IKCONFIG + stock.symvers ==="
mkdir -p "$B/stock" "$B/ikconfig"
(
  cd "$B/stock"
  rm -f kernel ramdisk.cpio
  magiskboot unpack "$PROJ/boot.img" >/dev/null 2>&1
)
python3 - "$B/stock/kernel" "$B/ikconfig/stock.config" <<'PY'
import gzip, io, sys
data = open(sys.argv[1], "rb").read()
s = data.find(b"IKCFG_ST")
e = data.find(b"IKCFG_ED", s)
if s < 0 or e < 0:
    sys.exit("ERROR: IKCFG_ST..IKCFG_ED markers not found in stock kernel")
cfg = gzip.GzipFile(fileobj=io.BytesIO(data[s + 8 : e])).read().decode()
open(sys.argv[2], "w").write(cfg)
print(f"stock.config: {len(cfg.splitlines())} lines -> {sys.argv[2]}")
PY
python3 "$PROJ/tools/extract-stock-symvers.py" "$B/stock/kernel" "$B/stock/stock.symvers"

echo "=== [2/6] Extracting vendor_dlkm.img (+ odm_dlkm.img) -> .build/kmi-ref/vendor_dlkm ==="
rm -rf "$B/kmi-ref"
mkdir -p "$B/kmi-ref/vendor_dlkm" "$B/tmp_vdlkm"
fsck.erofs --extract="$B/tmp_vdlkm" "$PROJ/vendor_dlkm.img" >/dev/null 2>&1
find "$B/tmp_vdlkm" -name '*.ko' -exec cp -f {} "$B/kmi-ref/vendor_dlkm/" \;
rm -rf "$B/tmp_vdlkm"
if [[ -f "$PROJ/odm_dlkm.img" ]]; then
  mkdir -p "$B/tmp_odlkm"
  fsck.erofs --extract="$B/tmp_odlkm" "$PROJ/odm_dlkm.img" >/dev/null 2>&1 || true
  find "$B/tmp_odlkm" -name '*.ko' -exec cp -f {} "$B/kmi-ref/vendor_dlkm/" \;
  rm -rf "$B/tmp_odlkm"
fi
echo "vendor_dlkm .ko count: $(find "$B/kmi-ref/vendor_dlkm" -name '*.ko' | wc -l)"

echo "=== [3/6] Unpacking vendor_boot.img -> .build/vendor_boot & .build/kmi-ref/vendor_boot ==="
rm -rf "$B/vendor_boot"
mkdir -p "$B/vendor_boot" "$B/kmi-ref/vendor_boot"
python3 - "$PROJ/vendor_boot.img" "$B/vendor_boot" <<'PY'
import os, struct, sys
vb_path, out_dir = sys.argv[1], sys.argv[2]
data = open(vb_path, "rb").read()
if data[:8] != b"VNDRBOOT":
    sys.exit("ERROR: vendor_boot.img missing VNDRBOOT magic")
hdr_ver, page_sz, k_addr, r_addr, v_ramdisk_sz = struct.unpack_from("<IIIII", data, 8)
cmdline = data[28:28+2048].rstrip(b"\x00").decode("ascii", "replace")
tags_addr = struct.unpack_from("<I", data, 28+2048)[0]
name = data[2080:2096].rstrip(b"\x00").decode("ascii", "replace")
hdr_sz, dtb_sz, dtb_addr = struct.unpack_from("<III", data, 2096)
vrt_sz, vrt_num, vrt_entsz, bootcfg_sz = struct.unpack_from("<IIII", data, 2112)

def align(x): return (x + page_sz - 1) // page_sz * page_sz
off = align(hdr_sz)
v_ramdisk = data[off : off + v_ramdisk_sz]; off += align(v_ramdisk_sz)
dtb = data[off : off + dtb_sz]; off += align(dtb_sz)
vrt = data[off : off + vrt_sz]; off += align(vrt_sz)
bootcfg = data[off : off + bootcfg_sz]

open(os.path.join(out_dir, "vendor_boot.dtb"), "wb").write(dtb)
open(os.path.join(out_dir, "bootconfig.txt"), "wb").write(bootcfg)
open(os.path.join(out_dir, "cmdline.txt"), "w").write(cmdline + "\n")

for i in range(vrt_num):
    e = vrt[i*vrt_entsz : (i+1)*vrt_entsz]
    r_sz, r_off, r_type = struct.unpack_from("<III", e, 0)
    r_name = e[12:44].rstrip(b"\x00").decode("ascii", "replace")
    blob = v_ramdisk[r_off : r_off + r_sz]
    open(os.path.join(out_dir, f"ramdisk_{i}.bin"), "wb").write(blob)
    print(f"vendor_boot ramdisk[{i}] ({r_name or 'default'}): {r_sz} bytes")
PY

for rbin in "$B/vendor_boot"/ramdisk_*.bin; do
  idx="$(basename "$rbin" .bin)"
  mkdir -p "$B/vendor_boot/$idx"
  magic="$(xxd -p -l 4 "$rbin")"
  if [[ "$magic" == 1f8b* ]]; then
    gzip -dc "$rbin" | (cd "$B/vendor_boot/$idx" && cpio -idm --quiet 2>/dev/null || true)
  elif [[ "$magic" == "04224d18" || "$magic" == "02214c18" ]]; then
    lz4 -dc "$rbin" | (cd "$B/vendor_boot/$idx" && cpio -idm --quiet 2>/dev/null || true)
  fi
  find "$B/vendor_boot/$idx" -name '*.ko' -exec cp -f {} "$B/kmi-ref/vendor_boot/" \;
done
echo "vendor_boot .ko count: $(find "$B/kmi-ref/vendor_boot" -name '*.ko' | wc -l)"

export PATH="/home/riza/itel-rs4-kernel/toolchain/build/build-tools/path/linux-x86:$PATH"
if command -v dtc >/dev/null 2>&1; then
  python3 - "$B/vendor_boot/vendor_boot.dtb" "$B/vendor_boot/dtb_0.dtb" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
idx = data.find(b"\xd0\x0d\xfe\xed")
if idx >= 0:
    ts = struct.unpack_from(">I", data, idx + 4)[0]
    open(sys.argv[2], "wb").write(data[idx : idx + ts])
PY
  if [[ -f "$B/vendor_boot/dtb_0.dtb" ]]; then
    dtc -I dtb -O dts -o "$B/vendor_boot/vendor_boot.dts" "$B/vendor_boot/dtb_0.dtb" 2>/dev/null || true
  fi
fi

echo "=== [4/6] Harvesting combined vendor KMI baseline (.build/kmi-ref) ==="
python3 "$PROJ/tools/harvest-kmi-ref.py" "$B/kmi-ref" "$B/kmi-ref"

echo "=== [5/6] Extracting system_dlkm.img & harvesting KMI baseline (.build/kmi-ref-system) ==="
rm -rf "$B/kmi-ref-system"
mkdir -p "$B/kmi-ref-system/system_dlkm" "$B/tmp_sdlkm"
fsck.erofs --extract="$B/tmp_sdlkm" "$PROJ/system_dlkm.img" >/dev/null 2>&1
find "$B/tmp_sdlkm" -name '*.ko' -exec cp -f {} "$B/kmi-ref-system/system_dlkm/" \;
rm -rf "$B/tmp_sdlkm"
python3 "$PROJ/tools/harvest-kmi-ref.py" "$B/kmi-ref-system" "$B/kmi-ref-system"

echo "=== [6/6] Cross-checking harvested module imports against stock.symvers ==="
python3 - "$B/stock/stock.symvers" "$B/kmi-ref/required.tsv" "$B/kmi-ref/exports.tsv" "$B/kmi-ref-system/required.tsv" "$B/kmi-ref-system/exports.tsv" <<'PY'
import sys
stock_path, v_req, v_exp, s_req, s_exp = sys.argv[1:6]
stock = {}
for line in open(stock_path):
    p = line.strip().split("\t")
    if len(p) >= 2:
        stock[p[1]] = int(p[0], 16)
sib = {}
for exp_path in (v_exp, s_exp):
    for line in open(exp_path):
        p = line.strip().split("\t")
        if len(p) >= 2:
            sib[p[1]] = int(p[0], 16)

for label, rpath in [("vendor", v_req), ("system_dlkm", s_req)]:
    matched_vmlinux = 0
    matched_sibling = 0
    mismatched = 0
    missing = 0
    for line in open(rpath):
        p = line.strip().split("\t")
        crc, sym = int(p[0], 16), p[1]
        if sym in stock:
            if stock[sym] == crc:
                matched_vmlinux += 1
            else:
                mismatched += 1
                print(f"  MISMATCH [{label} vs vmlinux] {sym}: stock=0x{stock[sym]:08x} ko=0x{crc:08x}")
        elif sym in sib:
            if sib[sym] == crc:
                matched_sibling += 1
            else:
                mismatched += 1
                print(f"  MISMATCH [{label} vs sibling] {sym}: sib=0x{sib[sym]:08x} ko=0x{crc:08x}")
        else:
            missing += 1
            print(f"  MISSING  [{label}] {sym}")
    print(f"stock.symvers vs {label}: vmlinux={matched_vmlinux} sibling={matched_sibling} mismatched={mismatched} missing={missing}")
    if mismatched or missing:
        sys.exit(1)
PY
