#!/usr/bin/env bash
# Integrate KernelSU-Next ("Wild" pershoot fork, SusFS in-driver) + SusFS into $KERNEL_SRC
# for the POCO X7 Pro / Redmi Note 14 Pro 5G (malachite, android14-6.1-lts).
# Called by build.sh for the ksunext variant on a pristine git tree (after apply-mods.sh),
# which build.sh reverts afterwards.
#
# RECIPE — mirrors itel-rs4-kernel and infinix-hot-60-pro-kernel:
#   * KSU side:    pershoot/KernelSU-Next (SusFS *in-driver*, so NO `10_` patch)
#   * kernel side: simonpunk SusFS `50_add_susfs_in_gki-android14-6.1.patch`
#                  + its fs/ and include/linux/ files
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
LOCKFILE="${LOCKFILE:-$PROJ/sources.lock}"
# shellcheck source=/dev/null
[[ -f "$LOCKFILE" ]] && source "$LOCKFILE"

WILDKSU_SRC="${WILDKSU_SRC:-$PROJ/.build/wildksu}"
WILDKSU_REF="${WILDKSU_REF:-}"
WILDKSU_VERBASE="${WILDKSU_VERBASE:-}"
WILDKSU_VER_EXPECT="${WILDKSU_VER_EXPECT:-}"
SUSFS="${SUSFS:-$PROJ/.build/susfs-61}"
SUSFS_REF="${SUSFS_REF:-}"
KVER="gki-android14-6.1"

say(){ echo "  [ksunext] $*"; }
die(){ echo "✗ [ksunext] $*" >&2; exit 1; }

[[ -f "$LOCKFILE" ]] || say "⚠ sources.lock not found — falling back to branch tips (NOT reproducible)"
[[ -n "$WILDKSU_REF" ]] || die "WILDKSU_REF is empty — pin the KSU commit in sources.lock first."
[[ -d "$WILDKSU_SRC/.git" ]] || die "Wild KSU clone missing at $WILDKSU_SRC
   (git clone https://github.com/pershoot/KernelSU-Next $WILDKSU_SRC)"
[[ -d "$WILDKSU_SRC/kernel" ]] || die "$WILDKSU_SRC/kernel not found — wrong repo?"
if git -C "$WILDKSU_SRC" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
  die "Wild KSU clone is shallow — the version rev-count would be wrong; re-clone full"
fi

# ── 1) pin SusFS, then pin the driver ────────────────────────────────────────────
if [[ -n "$SUSFS_REF" && -d "$SUSFS/.git" ]]; then
  git -C "$SUSFS" checkout -q -- . 2>/dev/null || true; git -C "$SUSFS" clean -fdq 2>/dev/null || true
  git -C "$SUSFS" checkout -q "$SUSFS_REF" 2>/dev/null \
    || die "SusFS ref ${SUSFS_REF:0:12} not in $SUSFS — fetch it or fix sources.lock"
  say "pin SusFS (simonpunk $KVER) @ ${SUSFS_REF:0:12}"
fi
PATCH50="$SUSFS/kernel_patches/50_add_susfs_in_${KVER}.patch"
[[ -f "$PATCH50" ]] || die "susfs 50_ patch missing at $PATCH50"

say "pin Wild KSU (pershoot KernelSU-Next) @ ${WILDKSU_REF:0:12}"
git -C "$WILDKSU_SRC" checkout -q -- . 2>/dev/null || true; git -C "$WILDKSU_SRC" clean -fdq
git -C "$WILDKSU_SRC" checkout -q "$WILDKSU_REF" 2>/dev/null \
  || git -C "$WILDKSU_SRC" checkout -q "origin/$WILDKSU_REF" 2>/dev/null \
  || die "ref $WILDKSU_REF not in clone — fetch it or fix sources.lock"

KVCOMMIT="${WILDKSU_VERBASE:-HEAD}"
KVERNUM=$(( 30000 + $(git -C "$WILDKSU_SRC" rev-list --count "$KVCOMMIT") ))
[[ -z "$WILDKSU_VER_EXPECT" || "$KVERNUM" == "$WILDKSU_VER_EXPECT" ]] \
  || die "KSU version drift: computed $KVERNUM but sources.lock expects $WILDKSU_VER_EXPECT
   — WILDKSU_REF/VERBASE moved; reconcile sources.lock (and the package banner) first."
KSUN_TAG=$(git -C "$WILDKSU_SRC" describe --tags --abbrev=0 --match 'v[0-9]*' \
           --exclude '*-legacy' "$KVCOMMIT" 2>/dev/null || echo "v?")
KSUN_DESC=$(git -C "$WILDKSU_SRC" describe --tags --match 'v[0-9]*' \
            --exclude '*-legacy' "$KVCOMMIT" 2>/dev/null || echo "$KSUN_TAG")
UAPI_HEAD=$(git -C "$WILDKSU_SRC" show "$KVCOMMIT:uapi/supercall.h" 2>/dev/null \
            | sed -n 's/.*KERNEL_SU_UAPI_VERSION[[:space:]]*[=[:space:]][[:space:]]*\([0-9]*\).*/\1/p')
UAPI_TAG=$(git -C "$WILDKSU_SRC" show "$KSUN_TAG:uapi/supercall.h" 2>/dev/null \
           | sed -n 's/.*KERNEL_SU_UAPI_VERSION[[:space:]]*[=[:space:]][[:space:]]*\([0-9]*\).*/\1/p')
if [[ -n "$UAPI_HEAD" && -n "$UAPI_TAG" && "$UAPI_HEAD" != "$UAPI_TAG" ]]; then
  MGR_NOTE="manager = CI build of $KSUN_DESC (uapi $UAPI_HEAD > $KSUN_TAG's $UAPI_TAG)"
else
  MGR_NOTE="the $KSUN_TAG manager binds it"
fi
say "Wild KSU-Next $KSUN_TAG, reported version = $KVERNUM ($MGR_NOTE)"

if grep -q '^#define SUSFS_EXPORT' "$WILDKSU_SRC/kernel/feature/selinux_hide.c" 2>/dev/null; then
  say "static.patch NOT needed: this tree de-statics selinux_hide itself (SUSFS_EXPORT)"
elif [[ -f "$PROJ/patches/ksunext-static.patch" ]]; then
  say "apply WildKernels static.patch (de-static selinux_hide fns)"
  ( cd "$WILDKSU_SRC" && patch -p1 --no-backup-if-mismatch --forward < "$PROJ/patches/ksunext-static.patch" ) \
    || die "static.patch failed on $WILDKSU_SRC"
else
  die "this tree lacks SUSFS_EXPORT and no patches/ksunext-static.patch is present"
fi

# ── 2) wire the driver in as a REAL directory ────────────────────────────────────
say "copy drivers/kernelsu ← $WILDKSU_SRC/kernel  (real dir, self-contained)"
rm -rf "$KERNEL_SRC/drivers/kernelsu"
cp -a "$WILDKSU_SRC/kernel" "$KERNEL_SRC/drivers/kernelsu"
rm -rf "$KERNEL_SRC/drivers/kernelsu/.git"
[[ -f "$KERNEL_SRC/drivers/kernelsu/Kconfig" ]] || die "drivers/kernelsu Kconfig missing after copy"
[[ ! -L "$KERNEL_SRC/drivers/kernelsu" ]] || die "drivers/kernelsu is a symlink"

while IFS= read -r lnk; do
  [[ -n "$lnk" ]] || continue
  rel="${lnk#$KERNEL_SRC/drivers/kernelsu/}"
  src_target="$(cd "$(dirname "$WILDKSU_SRC/kernel/$rel")" && readlink -f "$(basename "$(readlink "$lnk")")" 2>/dev/null || true)"
  [[ -z "$src_target" ]] && src_target="$(readlink -f "$WILDKSU_SRC/kernel/$rel" 2>/dev/null || true)"
  [[ -n "$src_target" && -e "$src_target" ]] \
    || die "cannot resolve symlink $rel -> $(readlink "$lnk") against $WILDKSU_SRC"
  rm -f "$lnk"; cp -aL "$src_target" "$lnk"
  say "materialised out-of-tree symlink: $rel -> $(basename "$src_target")/"
done < <(find "$KERNEL_SRC/drivers/kernelsu" -type l 2>/dev/null)

BROKEN=$(find "$KERNEL_SRC/drivers/kernelsu" -xtype l 2>/dev/null | head -3)
[[ -z "$BROKEN" ]] || die "dangling symlinks remain under drivers/kernelsu:
$BROKEN"
[[ -f "$KERNEL_SRC/drivers/kernelsu/include/uapi/app_profile.h" ]] \
  || die "drivers/kernelsu/include/uapi/app_profile.h missing"

KBD="$KERNEL_SRC/drivers/kernelsu/Kbuild"
grep -q '^# Check if this is a git repository' "$KBD" \
  || die "drivers/kernelsu/Kbuild: the git-version probe moved — re-check how it derives KSU_VERSION"
PIN="# [ksunext] pinned by apply-ksunext-susfs.sh — the driver is copied in without .git
KSU_GIT_VERSION := $((KVERNUM - 30000))
KSU_GIT_TAG := $KSUN_TAG
KSU_GIT_VERSION_VALID := 1
"
PIN="$PIN" awk '/^# Check if this is a git repository/ { printf "%s", ENVIRON["PIN"] } { print }' \
  "$KBD" > "$KBD.pinned" && mv "$KBD.pinned" "$KBD"
grep -qx "KSU_GIT_VERSION := $((KVERNUM - 30000))" "$KBD" && grep -qx "KSU_GIT_TAG := $KSUN_TAG" "$KBD" \
  || die "failed to pin KSU_GIT_VERSION/TAG in $KBD"
say "pinned driver version: KSU_VERSION=$KVERNUM, tag $KSUN_TAG (no .git in the copied tree)"

DMK="$KERNEL_SRC/drivers/Makefile"; DKC="$KERNEL_SRC/drivers/Kconfig"
grep -q 'kernelsu' "$DMK" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DMK"
grep -q 'drivers/kernelsu/Kconfig' "$DKC" \
  || sed -i '/^endmenu/i\source "drivers/kernelsu/Kconfig"' "$DKC"

# ── 3) SusFS kernel side ─────────────────────────────────────────────────────────
SUSFS_VER=$(sed -n 's/.*#define SUSFS_VERSION[[:space:]]*"\(v[0-9.]*\)".*/\1/p' \
            "$SUSFS/kernel_patches/include/linux/susfs.h" 2>/dev/null | head -1 || true)
[[ -n "$SUSFS_VER" ]] || SUSFS_VER="unknown"
say "copy susfs fs/ + include/linux/ headers ($SUSFS_VER)"
cp "$SUSFS/kernel_patches/fs/"*            "$KERNEL_SRC/fs/"
cp "$SUSFS/kernel_patches/include/linux/"* "$KERNEL_SRC/include/linux/"

say "apply $(basename "$PATCH50") at kernel root"
( cd "$KERNEL_SRC" && patch -p1 --no-backup-if-mismatch --forward < "$PATCH50" ) \
  || die "50_ patch failed — inspect .rej under $KERNEL_SRC"
[[ -z "$(find "$KERNEL_SRC" -name '*.rej' 2>/dev/null | head -1)" ]] \
  || die "50_ patch left .rej files — fixup needed before this can be trusted"

say "Wild KSU-Next ${WILDKSU_REF:0:12} (v$KVERNUM) + SusFS $SUSFS_VER integrated (no 10_ — SusFS in-driver)"
