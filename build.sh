#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# Xiaomi Poco X7 / Redmi Note 14 Pro 5G (malachite, MT6878) — Build & Gate Orchestrator
#
#   ./build.sh vanilla            stock ACK 6.1.182 + patches/series + vanilla_defconfig + brand
#   ./build.sh vanilla --stock    pure ACK 6.1.182 control build (gki_defconfig + protect fix)
#   ./build.sh --stock            shorthand for ./build.sh vanilla --stock
#   ./build.sh ksunext            vanilla + KernelSU-Next (Wild dev-susfs) + SuSFS v2.3.0
#   ./build.sh all [--pack]       build & gate both vanilla and ksunext sequentially
#
# Flags:
#   --stock        control build with zero feature patches/fragments (measures pure ACK KMI)
#   --gate-only    skip compilation, re-run all 4 gate layers against existing build outputs
#   --pack         run ./package.sh <variant> after a passing gate
#   --jobs N       override make parallelism (default: $(nproc))
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJ"

c()    { printf '\033[%sm' "$1"; }
hdr()  { echo; echo "$(c '1;36')════ $* ════$(c 0)"; }
step() { echo "$(c '1;34')▶$(c 0) $*"; }
ok()   { echo "$(c '1;32')✓$(c 0) $*"; }
warn() { echo "$(c '1;33')⚠$(c 0) $*" >&2; }
die()  { echo "$(c '1;31')✗ ERROR: $*$(c 0)" >&2; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────────────────
VARIANT=""; STOCK=0; GATE_ONLY=0; PACK=0; JOBS="${JOBS:-$(nproc)}"
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    vanilla|ksunext|all) VARIANT="$1" ;;
    --stock)             STOCK=1; [[ -z "$VARIANT" ]] && VARIANT="vanilla" ;;
    --gate-only)         GATE_ONLY=1 ;;
    --pack)              PACK=1 ;;
    --jobs)              shift; JOBS="${1:-}" ;;
    *)                   die "unknown argument: $1" ;;
  esac
  shift
done
[[ -n "$VARIANT" ]] || die "usage: ./build.sh <vanilla|ksunext|all> [--stock] [--gate-only] [--pack] [--jobs N]"

if [[ "$VARIANT" == "all" ]]; then
  [[ "$STOCK" == 0 ]] || die "--stock cannot be combined with 'all'"
  SUB_ARGS=()
  [[ "$GATE_ONLY" == 1 ]] && SUB_ARGS+=("--gate-only")
  [[ "$PACK" == 1 ]]      && SUB_ARGS+=("--pack")
  [[ -n "$JOBS" ]]        && SUB_ARGS+=("--jobs" "$JOBS")
  "$0" vanilla "${SUB_ARGS[@]}"
  "$0" ksunext "${SUB_ARGS[@]}"
  exit 0
fi

[[ "$STOCK" == 1 && "$VARIANT" != "vanilla" ]] && \
  die "--stock is only valid with vanilla (or alone as ./build.sh --stock)"

# ── Load device.conf & sources.lock ──────────────────────────────────────────
[[ -f "$PROJ/device.conf" ]] || die "missing $PROJ/device.conf"
# shellcheck disable=SC1091
source "$PROJ/device.conf"
[[ -f "$PROJ/sources.lock" ]] && source "$PROJ/sources.lock"

[[ "${MODULE_LAYOUT:-}" =~ ^0x[0-9a-fA-F]{8}$ ]] || die \
  "device.conf MODULE_LAYOUT is empty or not an 8-digit hex CRC ('${MODULE_LAYOUT:-}')"

for v in PROJ KERNEL_SRC KMI_REF_TREE KMI_REF_SYSTEM_TREE CLANG_DIR; do
  case "${!v:-}" in
    *[[:space:]]*|*:*) die "$v contains a space or colon: '${!v}'" ;;
  esac
done

# ── Preflight ────────────────────────────────────────────────────────────────
hdr "$DEVICE_FULL_LABEL — variant: $VARIANT$( [[ "$STOCK" == 1 ]] && echo ' (--stock)' || true )"

[[ -f "$KERNEL_SRC/Makefile" ]] || die "no kernel source at $KERNEL_SRC/Makefile"
for _t in bin/clang bin/clang++ bin/llvm-ar bin/llvm-strip bin/llvm-objcopy bin/ld.lld; do
  [[ -x "$CLANG_DIR/$_t" ]] || die "CLANG_DIR=$CLANG_DIR missing executable $_t"
done

if [[ -n "${KERNEL_COMMON_REF:-}" ]]; then
  _cur="$(git -C "$KERNEL_SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ "$_cur" != "$KERNEL_COMMON_REF" && "$_cur" != "${KERNEL_COMMON_UPSTREAM_REF:-}" ]]; then
    die "KERNEL_SRC is at ${_cur:0:12} but sources.lock pins ${KERNEL_COMMON_REF:0:12} (upstream ${KERNEL_COMMON_UPSTREAM_REF:0:12}).
  Restore with: git -C $KERNEL_SRC checkout $KERNEL_COMMON_REF"
  fi
fi

KSRC_VER="$(awk -F' = ' '/^VERSION/{v=$2} /^PATCHLEVEL/{p=$2} /^SUBLEVEL/{s=$2}
                         END{print v"."p"."s}' "$KERNEL_SRC/Makefile")"
KSRC_REF="$(git -C "$KERNEL_SRC" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
KMI_GEN="$(awk -F= '/^KMI_GENERATION/{print $2}' "$KERNEL_SRC/build.config.common" "$KERNEL_SRC/build.config.constants" 2>/dev/null | head -1)"
LOCALVERSION_STR="-${BRAND}-${VARIANT}"
EXPECT_REL="${KSRC_VER}${LOCALVERSION_STR}"

for v in BRAND KBUILD_BUILD_USER KBUILD_BUILD_HOST; do
  [[ "${!v:-}" =~ ^[A-Za-z0-9._-]+$ ]] || die "device.conf $v='${!v:-}' — use only [A-Za-z0-9._-]"
done
(( ${#EXPECT_REL} <= 64 )) || die "release '$EXPECT_REL' exceeds 64 chars (__NEW_UTS_LEN)"

# Locate system python3 with pyelftools BEFORE prepending build-tools to PATH
SYSPY=""
for p in /usr/bin/python3 /usr/local/bin/python3 python3; do
  "$p" -c 'import elftools' >/dev/null 2>&1 && { SYSPY="$p"; break; }
done
[[ -n "$SYSPY" ]] || die "no python3 with pyelftools found (pip install pyelftools)"

NKO_VENDOR="$(find "$KMI_REF_TREE" -name '*.ko' 2>/dev/null | wc -l)"
NKO_SYSTEM="$(find "$KMI_REF_SYSTEM_TREE" -name '*.ko' 2>/dev/null | wc -l)"
[[ "$NKO_VENDOR" -gt 0 ]] || die "no .ko files under $KMI_REF_TREE — run tools/extract-device-material.sh"
[[ "$NKO_SYSTEM" -gt 0 ]] || die "no .ko files under $KMI_REF_SYSTEM_TREE — run tools/extract-device-material.sh"
[[ -f "$STOCK_SYMVERS" ]] || die "missing $STOCK_SYMVERS — run tools/extract-device-material.sh"
NSTOCK_SYMS="$(wc -l < "$STOCK_SYMVERS")"

echo "   source        : Linux $KSRC_VER @ $KSRC_REF (android14-6.1, KMI_GENERATION=$KMI_GEN)"
echo "   clang         : $("$CLANG_DIR/bin/clang" --version | head -1)"
if [[ "$STOCK" == 0 ]]; then
  echo "   release       : $EXPECT_REL (${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST})"
else
  echo "   release       : control build (--stock)"
fi
echo "   KMI target    : $MODULE_LAYOUT ($NKO_VENDOR vendor + $NKO_SYSTEM system_dlkm modules, $NSTOCK_SYMS stock exports)"
echo "   gate python   : $SYSPY"

# ── Toolchain & Reproducible Environment ─────────────────────────────────────
if [[ "$STOCK" == 1 ]]; then
  KOUT="${KOUT:-$PROJ/.build/out-stock}"
  OUT="$PROJ/out/stock"
else
  KOUT="${KOUT:-$PROJ/.build/out-$VARIANT}"
  OUT="$PROJ/out/$VARIANT"
fi
mkdir -p "$KOUT" "$OUT" "$PROJ/.build/logs"

export PATH="$CLANG_DIR/bin:$PATH"

export KBUILD_BUILD_USER KBUILD_BUILD_HOST
SRC_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$KERNEL_SRC" log -1 --format=%ct 2>/dev/null || echo 0)}"
export SOURCE_DATE_EPOCH="$SRC_EPOCH"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-$(date -u -d "@$SRC_EPOCH" 2>/dev/null || date -u)}"

REPRO_FLAGS="-ffile-prefix-map=$KOUT=/build/obj -ffile-prefix-map=$KERNEL_SRC=/build/src"
MK=( make -C "$KERNEL_SRC" O="$KOUT" ARCH=arm64 LLVM=1 LLVM_IAS=1
     CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu-
     KCFLAGS="$REPRO_FLAGS" )

# ── Source Hygiene ───────────────────────────────────────────────────────────
SOURCE_DIRTY=0
cleanup_source() {
  local rc=$?
  if [[ "$SOURCE_DIRTY" == 1 ]]; then
    step "Restoring $KERNEL_SRC to pristine state"
    git -C "$KERNEL_SRC" checkout -q -- . 2>/dev/null || true
    git -C "$KERNEL_SRC" clean -ffdq 2>/dev/null || true
  fi
  exit $rc
}

prepare_source() {
  if [[ -n "$(git -C "$KERNEL_SRC" status --porcelain)" ]]; then
    if [[ "${KEEP_DIRTY:-0}" == "1" ]]; then
      die "$KERNEL_SRC is dirty and KEEP_DIRTY=1"
    fi
    warn "$KERNEL_SRC had leftover changes — resetting to pristine"
    git -C "$KERNEL_SRC" checkout -q -- . 2>/dev/null || true
    git -C "$KERNEL_SRC" clean -ffdq 2>/dev/null || true
  fi
  SOURCE_DIRTY=1
}

# ── Build Phase ──────────────────────────────────────────────────────────────
if [[ "$GATE_ONLY" == 0 ]]; then
  prepare_source
  trap cleanup_source EXIT

  if [[ "$STOCK" == 1 ]]; then
    step "Applying 05-gki-protect-no-module-exports.patch for control build"
    git -C "$KERNEL_SRC" apply --index --recount "$PROJ/patches/05-gki-protect-no-module-exports.patch"
  else
    step "Applying source modifications (apply-mods.sh)"
    KERNEL_SRC="$KERNEL_SRC" PROJ="$PROJ" "$PROJ/apply-mods.sh"
    if [[ "$VARIANT" == "ksunext" ]]; then
      step "Integrating KernelSU-Next + SuSFS (apply-ksunext-susfs.sh)"
      KERNEL_SRC="$KERNEL_SRC" PROJ="$PROJ" LOCKFILE="$PROJ/sources.lock" \
        "$PROJ/apply-ksunext-susfs.sh"
    fi
  fi

  # Extract the 8,911-symbol GKI ABI whitelist (union of all android/abi_gki_aarch64* lists, excluding .stg*)
  step "Generating GKI ABI symbol whitelist ($KOUT/abi_symbollist.raw)"
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ || /^\[/ { next }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print $0 }
  ' "$KERNEL_SRC"/android/abi_gki_aarch64 "$KERNEL_SRC"/android/abi_gki_aarch64_* | sort -u > "$KOUT/abi_symbollist.raw"
  NSYMLIST="$(wc -l < "$KOUT/abi_symbollist.raw")"
  ok "abi_symbollist.raw: $NSYMLIST symbols"

  # Base gki_defconfig
  step "Configuring base gki_defconfig"
  "${MK[@]}" gki_defconfig > "$KOUT/defconfig.log" 2>&1 || {
    tail -30 "$KOUT/defconfig.log" >&2
    die "gki_defconfig failed"
  }

  if [[ "$STOCK" == 1 ]]; then
    "$KERNEL_SRC/scripts/config" --file "$KOUT/.config" \
      --enable TRIM_UNUSED_KSYMS \
      --set-str UNUSED_KSYMS_WHITELIST "$KOUT/abi_symbollist.raw"
    "${MK[@]}" olddefconfig > "$KOUT/olddefconfig.log" 2>&1 || die "olddefconfig failed"
  else
    FRAGS=("$PROJ/config/vanilla_defconfig")
    [[ "$VARIANT" != "vanilla" ]] && FRAGS+=("$PROJ/config/${VARIANT}_defconfig")
    for f in "${FRAGS[@]}"; do [[ -f "$f" ]] || die "missing fragment $f"; done
    if grep -n '^CONFIG_LOCALVERSION' "${FRAGS[@]}"; then
      die "a config fragment sets CONFIG_LOCALVERSION — remove it; build.sh owns the brand"
    fi

    COMPOSED="$OUT/composed_defconfig"
    {
      for f in "${FRAGS[@]}"; do
        echo "# ── ${f#$PROJ/} ──"
        cat "$f"
        echo
      done
      echo "# ── generated by build.sh from device.conf ──"
      echo "CONFIG_LOCALVERSION=\"$LOCALVERSION_STR\""
      echo "CONFIG_LOCALVERSION_AUTO=y"
      echo "CONFIG_MODULE_SCMVERSION=y"
      echo "CONFIG_TRIM_UNUSED_KSYMS=y"
      echo "CONFIG_UNUSED_KSYMS_WHITELIST=\"$KOUT/abi_symbollist.raw\""
    } > "$COMPOSED"

    # Empty .scmversion suppresses setlocalversion's git suffix while keeping
    # CONFIG_LOCALVERSION_AUTO=y (which CONFIG_MODULE_SCMVERSION=y depends on!),
    # producing clean kernel.release: <KSRC_VER>-<BRAND>-<VARIANT>.
    : > "$KERNEL_SRC/.scmversion"

    step "Merging ${FRAGS[*]#$PROJ/} + brand ($LOCALVERSION_STR)"
    "$KERNEL_SRC/scripts/kconfig/merge_config.sh" -m -r -O "$KOUT" "$KOUT/.config" "$COMPOSED" > "$KOUT/merge_config.log" 2>&1
    "${MK[@]}" olddefconfig > "$KOUT/olddefconfig.log" 2>&1 || {
      tail -30 "$KOUT/olddefconfig.log" >&2
      die "olddefconfig failed"
    }
    for inv in CONFIG_LOCALVERSION_AUTO=y CONFIG_MODULE_SCMVERSION=y CONFIG_PAHOLE_HAS_BTF_TAG=y; do
      grep -qx "$inv" "$KOUT/.config" || die "KMI config invariant missing after olddefconfig: $inv"
    done
  fi

  # Compile kernel + modules (modules builds .ko exports excluded from vmlinux)
  step "Building vmlinux, Image, Image.gz, Image.lz4, modules (-j$JOBS)"
  "${MK[@]}" -j"$JOBS" vmlinux Image Image.gz Image.lz4 modules 2>&1 | tee "$OUT/build.log"
  ok "Kernel compilation complete"

  # Verify KernelSU-Next version from Kbuild log when building ksunext
  if [[ "$VARIANT" == "ksunext" && "$STOCK" == 0 ]]; then
    if grep -q "KernelSU-Next version fallback" "$OUT/build.log" \
       || ! grep -qE -- "-- KernelSU-Next version: ${WILDKSU_VER_EXPECT:-?}\b" "$OUT/build.log"; then
      die "KernelSU-Next version in build.log does not match expected ${WILDKSU_VER_EXPECT:-?}:
$(grep -E 'KernelSU-Next (version|tag)' "$OUT/build.log" | sort -u || true)"
    fi
    ok "KernelSU-Next in kernel: $(grep -oE 'KernelSU-Next version: [0-9]+' "$OUT/build.log" | sort -u | tail -1), $(grep -oE 'KernelSU-Next tag: [^ ]+' "$OUT/build.log" | sort -u | tail -1)"
  fi
fi

# ── Verify Release String & Features ─────────────────────────────────────────
SYMVERS="$KOUT/vmlinux.symvers"
MODSYMVERS="$KOUT/Module.symvers"
VMLINUX="$KOUT/vmlinux"
DOTCFG="$KOUT/.config"
SMAP="$KOUT/System.map"
SYMBOLLIST="$KOUT/abi_symbollist.raw"
KREL_FILE="$KOUT/include/config/kernel.release"

[[ -f "$SYMVERS" && -f "$VMLINUX" && -f "$DOTCFG" && -f "$SMAP" ]] || \
  die "missing build outputs under $KOUT — run ./build.sh $VARIANT without --gate-only first"

GOT_REL="$(cat "$KREL_FILE" 2>/dev/null || echo '<none>')"
echo "   kernel.release: $GOT_REL"

if [[ "$STOCK" == 0 ]]; then
  [[ "$GOT_REL" == "$EXPECT_REL" ]] || \
    die "kernel.release is '$GOT_REL', expected '$EXPECT_REL'"
  BANNER="$(LC_ALL=C grep -aom1 'Linux version [^ ]* ([^)]*)' "$KOUT/arch/arm64/boot/Image" 2>/dev/null || true)"
  [[ "$BANNER" == "Linux version $EXPECT_REL (${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST})" ]] || \
    die "Image banner is '$BANNER', expected 'Linux version $EXPECT_REL (${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST})'"
  ok "Banner verified: $BANNER"

  # Verify every fragment option survived olddefconfig and every patch probe is in System.map
  MISS=""
  while IFS= read -r l; do
    case "$l" in
      CONFIG_UNUSED_KSYMS_WHITELIST=*) ;;
      CONFIG_*=*)
        grep -qxF "$l" "$DOTCFG" || MISS+="  missing in .config: $l"$'\n' ;;
      "# CONFIG_"*" is not set")
        o="${l#\# }"; o="${o%% *}"
        grep -q "^$o=" "$DOTCFG" && MISS+="  expected unset in .config: $l"$'\n' ;;
    esac
  done < "$OUT/composed_defconfig"

  while read -r p cfg sym; do
    [[ "$cfg" == "-" ]] || grep -qx "$cfg=y" "$DOTCFG" || MISS+="  $p: $cfg is not =y"$'\n'
    [[ "$sym" == "-" ]] || awk -v s="$sym" '$3==s{f=1} END{exit !f}' "$SMAP" \
      || MISS+="  $p: probe symbol '$sym' missing from System.map"$'\n'
  done < <(awk '!/^[[:space:]]*(#|$)/' "$PROJ/patches/series")

  [[ -z "$MISS" ]] || die "built kernel is missing configured features or patch symbols:
$MISS"
  ok "Feature gate: all composed_defconfig switches active and all $(awk '!/^[[:space:]]*(#|$)/ && $3!="-"' "$PROJ/patches/series" | wc -l) patch probe symbols present in System.map"
fi

# ── 4-Layer KMI / ABI Gate Suite ─────────────────────────────────────────────
hdr "Running 4-Layer KMI / ABI Gate Suite ($VARIANT)"
set +e

step "Layer 1 (Vendor) — symbol CRCs vs $NKO_VENDOR vendor_boot + vendor_dlkm modules"
"$SYSPY" "$PROJ/lib/kmi_check.py" "$SYMVERS" "$KMI_REF_TREE" \
  --extra-exports "$KMI_REF_SYSTEM_TREE/exports.tsv" \
  --expect-vermagic "$KMI_EXPECT_VERMAGIC" \
  --expect-module-layout "$MODULE_LAYOUT" 2>&1 | tee "$OUT/kmi-check.log"
L1=${PIPESTATUS[0]}

step "Layer 2 (Vendor) — protected exports (MODULE_SIG_PROTECT)"
if grep -q '^CONFIG_MODULE_SIG_PROTECT=y' "$DOTCFG" 2>/dev/null; then
  "$SYSPY" "$PROJ/lib/protect_check.py" "$VMLINUX" "$KMI_REF_TREE" \
    --extra-exports "$KMI_REF_SYSTEM_TREE/exports.tsv" 2>&1 | tee "$OUT/protect-check.log"
  L2=${PIPESTATUS[0]}
else
  echo "PASS [protect_check]: MODULE_SIG_PROTECT is off; no export is protected" | tee "$OUT/protect-check.log"
  L2=0
fi

step "Layer 3 (Vendor) — full module import accounting + whitelist check"
"$SYSPY" "$PROJ/lib/import_check.py" "$SYMVERS" "$KMI_REF_TREE" \
  --extra-exports "$KMI_REF_SYSTEM_TREE/exports.tsv" \
  --raw-symbollist "$SYMBOLLIST" 2>&1 | tee "$OUT/import-check.log"
L3=${PIPESTATUS[0]}

step "Layer 1 (system_dlkm) — symbol CRCs vs $NKO_SYSTEM GKI modules"
"$SYSPY" "$PROJ/lib/kmi_check.py" "$SYMVERS" "$KMI_REF_SYSTEM_TREE" \
  --expect-vermagic "$KMI_SYSTEM_EXPECT_VERMAGIC" \
  --expect-module-layout "$MODULE_LAYOUT" 2>&1 | tee "$OUT/kmi-check-system.log"
S1=${PIPESTATUS[0]}

step "Layer 2 (system_dlkm) — protected exports (MODULE_SIG_PROTECT)"
if grep -q '^CONFIG_MODULE_SIG_PROTECT=y' "$DOTCFG" 2>/dev/null; then
  "$SYSPY" "$PROJ/lib/protect_check.py" "$VMLINUX" "$KMI_REF_SYSTEM_TREE" 2>&1 \
    | tee "$OUT/protect-check-system.log"
  S2=${PIPESTATUS[0]}
else
  echo "PASS [protect_check]: MODULE_SIG_PROTECT is off; no export is protected" | tee "$OUT/protect-check-system.log"
  S2=0
fi

step "Layer 3 (system_dlkm) — full module import accounting + whitelist check"
"$SYSPY" "$PROJ/lib/import_check.py" "$SYMVERS" "$KMI_REF_SYSTEM_TREE" \
  --raw-symbollist "$SYMBOLLIST" 2>&1 | tee "$OUT/import-check-system.log"
S3=${PIPESTATUS[0]}

step "Layer 4 (Stock vmlinux symvers) — strict 100% check vs all $NSTOCK_SYMS stock vmlinux exports"
"$SYSPY" "$PROJ/lib/stock_symvers_check.py" "$SYMVERS" "$STOCK_SYMVERS" \
  --required-tsv "$KMI_REF_TREE/required.tsv" \
  --required-tsv "$KMI_REF_SYSTEM_TREE/required.tsv" \
  --strict-all-stock 2>&1 | tee "$OUT/stock-symvers-check.log"
L4=${PIPESTATUS[0]}

set -e
echo
if [[ "$L1" == 0 && "$L2" == 0 && "$L3" == 0 && "$S1" == 0 && "$S2" == 0 && "$S3" == 0 && "$L4" == 0 ]]; then
  if [[ "$STOCK" == 0 ]]; then
    STAGED="$PROJ/.build/staged-$VARIANT"
    rm -rf "$STAGED"; mkdir -p "$STAGED"
    for f in Image Image.gz Image.lz4; do
      [[ -f "$KOUT/arch/arm64/boot/$f" ]] || die "missing $KOUT/arch/arm64/boot/$f"
      cp -f "$KOUT/arch/arm64/boot/$f" "$STAGED/$f"
      cp -f "$KOUT/arch/arm64/boot/$f" "$OUT/$f"
    done
    cp -f "$KREL_FILE" "$STAGED/kernel.release"
    cp -f "$KREL_FILE" "$OUT/kernel.release"
    cp -f "$DOTCFG" "$OUT/kernel.config"
    cp -f "$SYMVERS" "$OUT/vmlinux.symvers"
    ( cd "$OUT" && sha256sum Image Image.gz Image.lz4 > SHA256SUMS )
  fi
  ok "GATE: PASS — Layers 1, 2, 3, and 4 (strict all 7,996 stock exports) 100% CLEAN."
else
  die "GATE: FAIL — vendor L1/L2/L3=$L1/$L2/$L3  system_dlkm S1/S2/S3=$S1/$S2/$S3  stock_symvers L4=$L4"
fi

if [[ "$PACK" == 1 && "$STOCK" == 0 ]]; then
  "$PROJ/package.sh" "$VARIANT"
fi
