#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# package.sh — Package a 4-layer-gated build into AnyKernel3 .zip + stock boot.img
#
#   ./package.sh <vanilla|ksunext|all>
#
# Deliverables (written to out/<variant>/ and copied to dist/):
#   PocoX7-<variant>-<date>.zip       AnyKernel3 flashable installer (ROM-agnostic)
#   PocoX7-boot-<variant>-<date>.img  Pre-repacked stock boot.img (fastboot flash boot)
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJ"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "== $*"; }

VARIANT="${1:-}"
[[ "$VARIANT" == "vanilla" || "$VARIANT" == "ksunext" || "$VARIANT" == "all" ]] || \
  die "usage: ./package.sh <vanilla|ksunext|all>"

if [[ "$VARIANT" == "all" ]]; then
  "$0" vanilla
  "$0" ksunext
  exit 0
fi

# shellcheck disable=SC1091
source "$PROJ/device.conf"
# shellcheck disable=SC1091
[[ -f "$PROJ/sources.lock" ]] && source "$PROJ/sources.lock"

OUT="$PROJ/out/$VARIANT"
DIST="$PROJ/dist"
DATE="$(date +%Y%m%d)"
DEVSLUG="$(echo "$DEVICE_LABEL" | tr -cd '[:alnum:]')"

# ── Verify all 4 Gate Layers passed (7 log files) ───────────────────────────
REQUIRED_LOGS=(
  "$OUT/kmi-check.log"
  "$OUT/protect-check.log"
  "$OUT/import-check.log"
  "$OUT/kmi-check-system.log"
  "$OUT/protect-check-system.log"
  "$OUT/import-check-system.log"
  "$OUT/stock-symvers-check.log"
)
for f in "${REQUIRED_LOGS[@]}"; do
  [[ -f "$f" ]] || die "missing gate log $f — run ./build.sh $VARIANT first"
  grep -qE "^PASS \[" "$f" || die "gate $(basename "$f") did NOT pass for $VARIANT:
$(tail -5 "$f")"
done
say "All 7 gate logs (Layers 1, 2, 3 vendor + system_dlkm, and Layer 4 strict stock symvers) confirm CLEAN for $VARIANT"

# ── Locate and verify staged kernel Image ───────────────────────────────────
KSRC_VER="$(awk -F' = ' '/^VERSION/{v=$2} /^PATCHLEVEL/{p=$2} /^SUBLEVEL/{s=$2}
                         END{print v"."p"."s}' "$KERNEL_SRC/Makefile")"
EXPECT_REL="${KSRC_VER}-${BRAND}-${VARIANT}"

case "$KERNEL_FMT" in
  lz4)  KIMG_NAME="Image.lz4" ;;
  gzip) KIMG_NAME="Image.gz"  ;;
  raw)  KIMG_NAME="Image"     ;;
  *)    die "device.conf KERNEL_FMT='$KERNEL_FMT' — expected lz4, gzip, or raw" ;;
esac

STAGED="$PROJ/.build/staged-$VARIANT"
[[ -f "$STAGED/Image" && -f "$STAGED/kernel.release" ]] || \
  die "no staged Image under $STAGED — run ./build.sh $VARIANT first"

RAWIMG="$STAGED/Image"
KIMG="$STAGED/$KIMG_NAME"
KREL="$(cat "$STAGED/kernel.release")"

[[ "$KREL" == "$EXPECT_REL" ]] || \
  die "staged kernel.release is '$KREL', expected '$EXPECT_REL'"
BANNER_REL="$(LC_ALL=C grep -aom1 'Linux version [^ ]*' "$RAWIMG" 2>/dev/null | awk '{print $3}' || true)"
[[ "$BANNER_REL" == "$EXPECT_REL" ]] || \
  die "Image banner release is '$BANNER_REL', expected '$EXPECT_REL'"
say "Verified staged Image banner: $KREL"

# ── Read dynamic compiler & KSU/SuSFS metadata ──────────────────────────────
COMPILER="$(LC_ALL=C grep -aom1 'Linux version [[:print:]]*' "$RAWIMG" 2>/dev/null \
            | sed -n 's/.*(\([^(]*\)\(([^)]*) \)\{0,1\}clang version \([^ )]*\).*/\1clang \3/p' \
            | head -1 || true)"
[[ -n "$COMPILER" ]] || COMPILER="Neutron clang 24"

KSUNVER="${WILDKSU_VER_EXPECT:-unknown}"
KSUN_TAG="$(git -C "$PROJ/.build/wildksu" describe --tags --abbrev=0 --match 'v[0-9]*' \
            --exclude '*-legacy' "${WILDKSU_VERBASE:-HEAD}" 2>/dev/null || true)"
[[ -n "$KSUN_TAG" ]] || KSUN_TAG="v?"
ksun_uapi() {
  git -C "$PROJ/.build/wildksu" show "$1:uapi/supercall.h" 2>/dev/null \
    | sed -n 's/.*KERNEL_SU_UAPI_VERSION[[:space:]]*[=[:space:]][[:space:]]*\([0-9]*\).*/\1/p' \
    | head -1 || true
}
KSUN_UAPI="$(ksun_uapi "${WILDKSU_VERBASE:-HEAD}")"
if [[ -n "$KSUN_UAPI" && "$KSUN_UAPI" == "$(ksun_uapi "$KSUN_TAG")" ]]; then
  KSUN_MGR="$KSUN_TAG manager"
else
  KSUN_DESC="$(git -C "$PROJ/.build/wildksu" describe --tags --match 'v[0-9]*' \
               --exclude '*-legacy' "${WILDKSU_VERBASE:-HEAD}" 2>/dev/null || echo '?')"
  KSUN_MGR="CI manager $KSUN_DESC, uapi ${KSUN_UAPI:-?}"
fi

SUSFS_VER="$(sed -n 's/.*#define SUSFS_VERSION[[:space:]]*"\(v[0-9.]*\)".*/\1/p' \
              "$PROJ/.build/susfs-61/kernel_patches/include/linux/susfs.h" 2>/dev/null \
             | head -1 || true)"
[[ -n "$SUSFS_VER" ]] || SUSFS_VER="unknown"

NKO_VENDOR="$(find "$KMI_REF_TREE" -name '*.ko' | wc -l)"
NKO_SYSTEM="$(find "$KMI_REF_SYSTEM_TREE" -name '*.ko' | wc -l)"

case "$VARIANT" in
  vanilla)
    LABEL="Vanilla"
    ROOTLINE='ui_print "   [+] root    : none (vanilla)";'
    ;;
  ksunext)
    LABEL="KernelSU-Next+SuSFS"
    ROOTLINE="ui_print \"   [+] root    : KernelSU-Next $KSUN_TAG ($KSUNVER) + SuSFS $SUSFS_VER ($KSUN_MGR)\";"
    ;;
esac

KSTRING="${DEVICE_LABEL} ${BRAND_FULL} (${VARIANT}) • ${KREL} • ${DATE}"
mkdir -p "$OUT" "$DIST"

# ── 1. AnyKernel3 Flashable Zip ─────────────────────────────────────────────
AK="$PROJ/.build/ak3-$VARIANT"
rm -rf "$AK"; cp -r "$PROJ/anykernel" "$AK"; rm -rf "$AK/.git"
rm -f "$AK"/Image* "$AK"/zImage* 2>/dev/null || true
cp "$RAWIMG" "$AK/Image"

NAMELINES=""; i=1
for n in $DEVICE_NAMES; do
  NAMELINES+="device.name${i}=${n}"$'\n'
  i=$((i+1))
done
DEVCHECK=0; [[ -n "$DEVICE_NAMES" ]] && DEVCHECK=1

cat > "$AK/anykernel.sh" <<AKEOF
### AnyKernel3 Ramdisk Mod Script
## $DEVICE_FULL_LABEL ($DEVICE_SOC) — $VARIANT

properties() { '
kernel.string=${KSTRING}
do.devicecheck=${DEVCHECK}
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
${NAMELINES}supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

# shell variables (MUST be uppercase for tools/ak3-core.sh)
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

ui_print " ";
ui_print "   ══════════════════════════════════════════════";
ui_print "     ${DEVICE_LABEL} — ${BRAND_FULL}";
ui_print "     ${DEVICE_SOC}";
ui_print "     Linux ${KREL} · KMI-clean GKI";
ui_print "   ══════════════════════════════════════════════";
ui_print " ";
ui_print "     variant : ${LABEL}";
ui_print "     version : ${KREL}";
ui_print "     compiler: ${COMPILER}";
ui_print " ";
ui_print "   ────────────────────────────────────────────";
ui_print "   [+] KMI ABI : module_layout ${MODULE_LAYOUT}";
ui_print "       (${NKO_VENDOR} vendor + ${NKO_SYSTEM} GKI modules + 7996 symvers CLEAN)";
ui_print "   [+] sched   : BORE 7.0.0 · Reflex 0.4.0 · malachite_balance";
ui_print "   [+] network : BBRv3 default · fq/cake · TCP suite";
ui_print "   [+] storage : ADIOS 3.3.0 · BFQ · mq-deadline";
ui_print "   [+] memory  : Kcompressd 0.5 · le9uo 1.14 · MGLRU · LZ4HC";
${ROOTLINE}
ui_print "   ────────────────────────────────────────────";
ui_print " ";

# 6.1 GKI sanity guard
kver=\$(cat /proc/version | awk '{print \$3}' | cut -d- -f1)
case "\$kver" in
  6.1.*) ui_print " -> ROM is on \$kver (6.1 GKI base OK) — installing ${KREL}" ;;
  *)     abort " -> Not a 6.1 GKI ROM (\$kver) — aborting to protect boot partition!" ;;
esac

split_boot;
if [ -f "\$SPLITIMG/ramdisk.cpio" ] || [ -d "\$SPLITIMG/vendor_ramdisk" ]; then
  unpack_ramdisk;
  write_boot;
else
  flash_boot;
fi
AKEOF

# ── End-to-End AnyKernel3 Self-Test against stock boot.img ──────────────────
AK_TEST="$(mktemp -d)"
trap 'rm -rf "$AK_TEST"' EXIT
cp -r "$AK" "$AK_TEST/ak"
cp "$STOCK_BOOT_IMG" "$AK_TEST/boot_a"
ln -sf "$(command -v busybox)" "$AK_TEST/ak/tools/busybox"
ln -sf "$(command -v magiskboot)" "$AK_TEST/ak/tools/magiskboot"
sed -i \
  -e "s|^BLOCK=boot;|BLOCK=..${AK_TEST}/boot_a;\nCUSTOMDD=\"bs=1048576 count=64\";|" \
  -e 's|cat /proc/version|echo "Linux version 6.1.115-android14-11-gfaa9b1b32a11-ab13269000"|' \
  "$AK_TEST/ak/anykernel.sh"
(
  cd "$AK_TEST/ak"
  PATH="$AK_TEST/ak/tools:$PATH" busybox ash anykernel.sh 1 >/dev/null 2>&1
) || die "AnyKernel3 installer self-test failed on stock boot.img"
(
  mkdir -p "$AK_TEST/verify"
  cd "$AK_TEST/verify"
  cp "$AK_TEST/boot_a" flashed.img
  magiskboot unpack flashed.img >/dev/null 2>&1 || die "AnyKernel3 verify unpack failed"
  cmp -s kernel "$RAWIMG" || die "AnyKernel3 flashed boot.img kernel does NOT match our Image"
)
rm -rf "$AK_TEST"
trap - EXIT
say "AnyKernel3 self-test: PASS (repacked boot_a embeds byte-identical Image)"

ZIP="$OUT/${DEVSLUG}-${VARIANT}-${DATE}.zip"
rm -f "$ZIP"
( cd "$AK" && zip -r9 "$ZIP" . -x '.git*' 'README.md' '.github*' >/dev/null )
cp -f "$ZIP" "$DIST/$(basename "$ZIP")"
say "AnyKernel3 zip: $ZIP"

# ── 2. Prebuilt stock boot.img (magiskboot repack + byte-verify) ────────────
BOOTIMG="$OUT/${DEVSLUG}-boot-${VARIANT}-${DATE}.img"
W="$PROJ/.build/repack-$VARIANT"; rm -rf "$W"; mkdir -p "$W"
cp "$STOCK_BOOT_IMG" "$W/boot.img"
(
  cd "$W"
  magiskboot unpack boot.img >/dev/null 2>&1 || die "magiskboot unpack failed"
  # magiskboot decompresses the kernel on unpack and re-compresses to stock
  # lz4_legacy on repack, so pass the raw Image as `kernel`.
  cp "$RAWIMG" kernel
  magiskboot repack boot.img "$BOOTIMG" >/dev/null 2>&1 || die "magiskboot repack failed"
)
(
  cd "$W"
  rm -f kernel ramdisk.cpio dtb kernel_dtb 2>/dev/null || true
  cp "$BOOTIMG" check.img
  magiskboot unpack check.img >/dev/null 2>&1 || die "verify unpack failed"
  cmp -s kernel "$RAWIMG" || die "boot.img kernel does NOT match our Image — repack verification failed"
)
cp -f "$BOOTIMG" "$DIST/$(basename "$BOOTIMG")"
say "boot.img: $BOOTIMG (verified byte-identical Image after unpack)"

# ── Update flat SHA256SUMS in out/<variant>/ and dist/ ──────────────────────
( shopt -s nullglob; cd "$OUT" && sha256sum -- *.zip *.img Image Image.gz Image.lz4 > SHA256SUMS )
( shopt -s nullglob; cd "$DIST" && sha256sum -- *.zip *.img > SHA256SUMS )
echo
say "SHA256SUMS ($DIST/SHA256SUMS):"
cat "$DIST/SHA256SUMS"
