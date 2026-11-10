# Riza Kernel — Xiaomi Poco X7 / Redmi Note 14 Pro 5G (`malachite`)

A GKI build-and-gate pipeline for the **Xiaomi Poco X7 / Redmi Note 14 Pro 5G (`malachite`, MediaTek Dimensity 7300-Ultra `MT6878`, `android14-6.1-lts`)**.

> **Status:** **v2 (`20261110`)** — built from Google ACK `android14-6.1-lts` (**Linux 6.1.182**, 67 LTS releases ahead of stock `6.1.115`) with **Neutron Clang 24** (`06092026`, LLVM `f42c87ba`), integrating **BORE 7.0.0**, **Google BBRv3**, **Reflex 0.4.0**, **`malachite_balance`**, **ADIOS 3.3.0**, **Kcompressd 0.5**, **le9uo 1.14**, **ntsync**, **LZ4HC ZRAM**, and **KernelSU-Next 33465** (`v3.4.2-110-g0c9c4438`, **uapi 6**) + **SuSFS v2.3.0** (`e3d5ec08b94a`) — is built, gated clean across all **524 device modules** (`464 vendor + 60 system_dlkm`) and all **7,996 stock `vmlinux` exports**, self-tested, and packaged. **v2 fixes a kernel panic in v1 that hit on the first `fsync` after the ADIOS I/O scheduler was selected**; the default `mq-deadline` was never affected.

## Variants & Features

| Variant | What | `uname -r` |
|---|---|---|
| **vanilla** | BORE 7.0.0 + BBRv3 + Reflex 0.4.0 + `malachite_balance` + ADIOS 3.3.0 + Kcompressd 0.5 + le9uo 1.14 + ntsync + LZ4HC/fq/CAKE, no root | `6.1.182-Riza-vanilla` |
| **ksunext** | vanilla + KernelSU-Next **33465** (`v3.4.2-110-g0c9c4438`, **uapi 6**) + SuSFS **v2.3.0** (`e3d5ec08b94a`) | `6.1.182-Riza-ksunext` |

* **Scheduler:** **BORE 7.0.0** (Burst-Oriented Response Enhancer, `firelzrd`), KABI-packed into `struct sched_entity::android_kabi_reserved3` (`_Static_assert(sizeof(struct sched_entity) == 512)`). Toggle live via `sysctl kernel.sched_bore=0`.
* **CPUFreq:** **Reflex v0.4.0** (`firelzrd`, `latency_weight` default `300`) + **`malachite_balance`** (boot boost, direct `freq_qos` input touch floor, and deferrable screen-off cap gated on `lcd-backlight` for MT6878 clusters `policy0` @ CPU 0 and `policy4` @ CPU 4).
* **Compat:** **ntsync** (`/dev/ntsync`, complete mainline driver with semaphores, mutexes, events, wait-all/wait-any + mainline fixes `180a232ea780` and `61611481f7b5`) for Wine / Proton / Winlator.
* **Memory & Storage:** **MGLRU** (`CONFIG_LRU_GEN_ENABLED=y`), **Kcompressd 0.5** (`vm.kcompressd`, async per-node ZRAM swap-out using a static side table so `struct pglist_data` layout is untouched), **le9uo 1.14** (`vm.workingset_protection=0` dormant by default), built-in **LZ4HC / ZSTD / LZ4 / Deflate** crypto compressors exposed directly to 6.1's `zram.ko`, and **ADIOS 3.3.0** + **BFQ** + **Kyber** + **mq-deadline** I/O schedulers.
* **Networking:** **Google BBRv3** (default TCP congestion control, KABI-packed into unused `ANDROID_KABI_RESERVE` slots of `inet_sock`, `inet_connection_sock`, and `tcp_sock` so `ICSK_CA_PRIV_SIZE == 104` and `sizeof(struct tcp_sock) == 2368`) + **fq** (default qdisc) + **CAKE** + Westwood / Vegas / H-TCP + TTL/HL netfilter targets.
* **Compiler:** **Neutron Clang 24** (`clang version 24.0.0git`, LLVM `f42c87ba`).
* **ksunext Manager Note (uapi 6):** KernelSU-Next `33465` (`v3.4.2-110-g0c9c4438`) speaks **KSU uapi 6**. Because the `v3.4.2` release APK uses uapi 5, install the official CI manager build of `v3.4.2-110-g0c9c4438` (versionCode `33465`): [manager.zip](https://nightly.link/KernelSU-Next/KernelSU-Next/actions/runs/42217584009/manager.zip).

## The Point of This Repo

Not "a kernel with tweaks". A **four-layer gate that refuses to ship a kernel that would brick the device or break its modules**, built and proven able to fail before any feature was added.

This phone ships a stock Google-built GKI (`6.1.115-android14-11-gfaa9b1b32a11-ab13269000`). Its **464 vendor modules** (`37 vendor_boot + 427 vendor_dlkm`) and **60 `system_dlkm` modules** are signed blobs we cannot rebuild, and they agree on `module_layout 0xea759d7f` and **7,996 `vmlinux` symbol CRCs**. Get one wrong — or leave a GKI module export on `CONFIG_MODULE_SIG_PROTECT`'s protected list — and modules fail to load (no Wi-Fi, no Bluetooth, no 5G/RIL, no touch, no display).

```text
layer 1  symbol CRCs & module_layout (0xea759d7f) against 464 vendor + 60 system_dlkm modules
layer 2  protected symbol exports table in vmlinux = 0 (no module refused with -EACCES by MODULE_SIG_PROTECT)
layer 3  26,224 vendor + 3,586 system_dlkm import edges = 0 UNRESOLVED · 0 CRC mismatch · 0 unwhitelisted
layer 4  strict 7,996 / 7,996 symbol & CRC verification against stock boot.img's __ksymtab/__kcrctab
```

All four layers were **proven able to fail** via 17 positive and negative self-tests, none of which need a kernel build to run:

```bash
bash test/kmi-gate-selftest.sh
bash test/protect-gate-selftest.sh
bash test/import-gate-selftest.sh
bash test/stock-symvers-gate-selftest.sh
```

The gate proves the ABI, not that a feature runs: v1 passed all of the above and still panicked once ADIOS was selected. `test/adios-qemu-selftest.sh` boots a built `Image` in QEMU and drives `fsync`, journal-commit and f2fs-checkpoint I/O through ADIOS on loop devices, with `mq-deadline` as the positive control and the v1 `Image` as the negative one (needs `qemu-system-aarch64`, `mkfs.ext4`, `mkfs.f2fs`):

```bash
test/adios-qemu-selftest.sh          # after ./build.sh <variant>; ~35 s
```

## Critical KMI Invariants on `android14-6.1`

1. **`CONFIG_LOCALVERSION_AUTO=y` + `CONFIG_MODULE_SCMVERSION=y` + empty `.scmversion`:**
   In `kernel/module/Kconfig`, `CONFIG_MODULE_SCMVERSION` depends on `CONFIG_LOCALVERSION_AUTO`. Disabling `CONFIG_LOCALVERSION_AUTO` silently drops `const char *scmversion;` from `struct module`, shifting `module_layout` from `0xea759d7f` to `0x83fa5dd2` and breaking 5,378 symbol CRCs. `build.sh` keeps `CONFIG_LOCALVERSION_AUTO=y` and `CONFIG_MODULE_SCMVERSION=y` enabled while writing an empty `.scmversion` file so `UTS_RELEASE` stays cleanly `6.1.182-Riza-<variant>`.
2. **`pahole >= 1.23` for `CONFIG_PAHOLE_HAS_BTF_TAG=y`:**
   In `include/linux/compiler_types.h`, `__user` expands to `__attribute__((btf_type_tag("user")))` when `CONFIG_PAHOLE_HAS_BTF_TAG=y` (`pahole >= 1.23`). Using an older `pahole` (such as AOSP prebuilt `1.19`) drops `CONFIG_PAHOLE_HAS_BTF_TAG=y` during `olddefconfig` and alters `genksyms` CRCs on every function taking a `__user` pointer (`__arch_copy_from_user`, `__arch_copy_to_user`, etc.). `build.sh` asserts `CONFIG_PAHOLE_HAS_BTF_TAG=y` after `olddefconfig`.
3. **No Protected Module Symbol Collisions (`05-gki-protect-no-module-exports.patch`):**
   With `CONFIG_MODULE_SIG_PROTECT=y`, any symbol listed in `gki_module_protected.h` (`56` GKI modules in `system_dlkm`) that is also exported by `vmlinux` causes `is_protected_symbol()` to reject unsigned vendor modules importing that symbol with `-EACCES`. When `CONFIG_CRYPTO_LZ4HC=y` pulls `lib/lz4/` into `vmlinux`, `05-gki-protect-no-module-exports.patch` guards `EXPORT_SYMBOL` under `#ifdef MODULE` so Layer 2 stays at `0` collisions.

## Build, Gate & Package

Drop the device's stock `boot.img`, `vendor_boot.img`, `vendor_dlkm.img`, and `system_dlkm.img` in the repository root, then run:

```bash
./tools/fetch-kernel-source.sh       # fetches Google ACK android14-6.1-lts @ sources.lock into .build/kernel-src
./tools/extract-device-material.sh   # unpacks stock images -> .build/ikconfig/stock.config, .build/stock/stock.symvers, .build/kmi-ref*
./build.sh --stock                   # pure Google ACK 6.1.182 control build + 4-layer gate
./build.sh vanilla                   # + patches/series + config/vanilla_defconfig + 4-layer gate
./build.sh ksunext                   # vanilla + KernelSU-Next 33465 (uapi 6) + SuSFS v2.3.0 + 4-layer gate
./build.sh --gate-only vanilla       # re-run the 4-layer gate without rebuilding
./package.sh vanilla                 # AnyKernel3 zip + repacked boot.img + mock-recovery self-test
./package.sh ksunext                 # AnyKernel3 zip + repacked boot.img + mock-recovery self-test
```

Beyond the 4-layer KMI gate, `build.sh` asserts the release string in `kernel.release` and the `Image` banner, every required Kconfig symbol in the built `.config`, and every patch's probe symbols in `System.map`.

`package.sh` runs an automated **AnyKernel3 mock-recovery execution self-test** against a copy of the stock header-v4 kernel-only `boot.img` on every run, unpacking the resulting image with `magiskboot` and verifying byte-for-byte identity of the flashed `Image` payload and preservation of header v4 metadata (`os_version=14.0.0`, `os_patch_level=2025-07`).

## Layout

```text
build.sh                        build + 4-layer KMI gate + feature/symbol assertions
apply-mods.sh                   applies patches/series to the pinned tree — strict, idempotent
apply-ksunext-susfs.sh          KernelSU-Next (pershoot dev-susfs) + SuSFS v2.3.0, ksunext only
patches/                        the ported modifications, one patch each, ordered by patches/series
config/                         vanilla_defconfig + ksunext_defconfig fragments
package.sh                      AnyKernel3 zip + boot.img repack + mock-recovery execution self-test
sources.lock                    pinned kernel ref, KSU-Next/SuSFS commits, and toolchain versions
device.conf                     device facts: module_layout, vermagic, kernel format, brand, toolchain
lib/kmi_check.py                gate layer 1 — symbol CRCs vs the 464 vendor & 60 system_dlkm modules
lib/protect_check.py            gate layer 2 — protected_symbol_exports table in vmlinux ELF
lib/import_check.py             gate layer 3 — full import edge accounting + abi_symbollist.raw whitelist
lib/stock_symvers_check.py      gate layer 4 — strict 7,996-symbol comparison vs stock vmlinux
tools/fetch-kernel-source.sh    fetches pinned Google ACK android14-6.1-lts into .build/kernel-src
tools/extract-device-material.sh builds .build/ reference baselines from stock firmware images
tools/extract-stock-symvers.py  extracts Module.symvers directly from stock Image __ksymtab/__kcrctab
tools/harvest-kmi-ref.py        harvests per-module imports/exports/vermagic TSVs from .ko trees
tools/vmlinux-only-symvers.py   filters Module.symvers down to vmlinux-only exports
test/*-gate-selftest.sh         17 positive & negative unit tests for all 4 gate layers
test/adios-qemu-selftest.sh     boots the built Image in QEMU and runs fsync/FUA-heavy I/O through ADIOS
```

## Credits

GKI is Google's. BORE, Reflex, ADIOS, Kcompressd-Unofficial, and le9uo are firelzrd's (Kcompressd after Qun-Wei Lin, MediaTek); BBRv3 is Google's (`Neal Cardwell` et al.); ntsync is Elizabeth Figura's (CodeWeavers). KernelSU-Next, pershoot's `dev-susfs`, simonpunk's SuSFS. Neutron Clang is Neutron-Toolchains'. AnyKernel3 is osm0sis'.
