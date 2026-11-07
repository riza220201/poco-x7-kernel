#!/usr/bin/env bash
# fetch-kernel-source.sh — Fetch pinned Google ACK android14-6.1-lts source tree
# from android.googlesource.com/+archive/<COMMIT>.tar.gz and initialize a clean
# local git repository for transient patch application.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJ/sources.lock"

KSRC="${KERNEL_SRC:-$PROJ/.build/kernel-src}"
TARBALL="$PROJ/.build/kernel-common-${KERNEL_COMMIT}.tar.gz"
URL="https://android.googlesource.com/kernel/common/+archive/${KERNEL_COMMIT}.tar.gz"

mkdir -p "$PROJ/.build"

if [[ ! -s "$TARBALL" ]]; then
  echo "Downloading Google ACK ${KERNEL_BRANCH} (${KERNEL_VERSION}, commit ${KERNEL_COMMIT:0:12})..."
  curl -fL --retry 5 --retry-delay 2 -o "$TARBALL.tmp" "$URL"
  mv "$TARBALL.tmp" "$TARBALL"
fi

echo "Extracting ${TARBALL} -> ${KSRC}..."
rm -rf "$KSRC"
mkdir -p "$KSRC"
tar -xzf "$TARBALL" -C "$KSRC"

echo "Initializing baseline git repository in ${KSRC}..."
(
  cd "$KSRC"
  git init -q
  git config user.name "RizaKernel"
  git config user.email "riza@local"
  git add -A
  git commit -q -m "Import Google ACK ${KERNEL_BRANCH} (${KERNEL_VERSION}, upstream ${KERNEL_COMMIT})"
)
echo "Kernel source ready at ${KSRC} (upstream ${KERNEL_COMMIT})"
