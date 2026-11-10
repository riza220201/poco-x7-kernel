#!/usr/bin/env bash
# adios-qemu-selftest.sh — Boot a built Image in QEMU and drive the ADIOS elevator
# with the I/O the phone does all day: fsync, journal commits, f2fs checkpoints.
#
# Why this exists: the 4-layer KMI gate proves the ABI and build.sh proves the
# feature set is present, but neither one ever RUNS a feature. v1 shipped an
# ADIOS port that panicked on the first fsync (adios_completed_request+0x2c,
# NULL adios_rq_data on a REQ_PREFLUSH/REQ_FUA request — see the header of
# patches/50-adios-3.3.0.patch); a tester found it. This test would have.
#
#   test/adios-qemu-selftest.sh                 # out/ksunext/Image, else out/vanilla/Image
#   test/adios-qemu-selftest.sh path/to/Image
#   KEEP=1 test/adios-qemu-selftest.sh          # keep the work dir (serial logs)
#
# Cases:
#   POS-1  <Image> + mq-deadline   the rig itself passes on a known-good elevator
#   POS-2  <Image> + adios         every guest test passes, no Oops/WARN/CFI in the log
#   NEG-1  v1 Image + adios        must die in adios_completed_request (proves POS-2
#                                  can fail). Needs dist/PocoX7-ksunext-20261107.zip;
#                                  skipped, and said so, when that zip is not there.
#
# The guest uses loop devices because loop is the only blk-mq driver built into
# GKI (virtio-blk is a module). A loop device has a write cache and no FUA, so a
# REQ_PREFLUSH|REQ_FUA write runs the whole PREFLUSH -> DATA -> POSTFLUSH
# sequence, which is the path that crashed.
# Needs: qemu-system-aarch64, mkfs.ext4, mkfs.f2fs, cpio, gzip, unzip (NEG-1).
set -uo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-}"
if [[ -z "$IMAGE" ]]; then
  for c in "$PROJ/out/ksunext/Image" "$PROJ/out/vanilla/Image"; do
    [[ -f "$c" ]] && { IMAGE="$c"; break; }
  done
fi
[[ -f "$IMAGE" ]] || { echo "no Image to test (build first, or pass a path)"; exit 2; }
BUSYBOX="$PROJ/anykernel/tools/busybox"
V1_ZIP="$PROJ/dist/PocoX7-ksunext-20261107.zip"
export PATH="$PATH:/usr/sbin:/sbin"
for t in qemu-system-aarch64 mkfs.ext4 mkfs.f2fs cpio gzip; do
  command -v "$t" >/dev/null || { echo "missing host tool: $t"; exit 2; }
done
[[ -f "$BUSYBOX" ]] || { echo "missing $BUSYBOX"; exit 2; }

TMP="$(mktemp -d)"
trap '[[ "${KEEP:-0}" == 1 ]] && echo "work dir kept: $TMP" || rm -rf "$TMP"' EXIT

# ── Guest: /init ─────────────────────────────────────────────────────────────
R="$TMP/root"
mkdir -p "$R"/{bin,dev,proc,sys,tmp,img,mnt/e,mnt/f}
cp "$BUSYBOX" "$R/bin/busybox"; chmod 755 "$R/bin/busybox"
cat > "$R/init" <<'EOF'
#!/bin/busybox sh
# GKI has no devtmpfs: make the nodes by hand. Everything is reported through
# /dev/kmsg so that it lands in the serial log in order with the kernel's own.
/bin/busybox --install -s /bin
export PATH=/bin
mknod /dev/kmsg c 1 11; mknod /dev/null c 1 3; mknod /dev/zero c 1 5; mknod /dev/urandom c 1 9
for i in 0 1 2; do mknod /dev/loop$i b 7 $i; done
exec 0</dev/null 1>/dev/null 2>/dev/kmsg
mount -t proc proc /proc; mount -t sysfs sysfs /sys
say(){ echo "RIG: $*" >/dev/kmsg; }
FAILED=0; fail(){ say "FAIL: $*"; FAILED=1; }
SCHED=$(sed -n 's/.*rig\.sched=\([^ ]*\).*/\1/p' /proc/cmdline)
say "kernel $(uname -r) sched=$SCHED cpus=$(grep -c ^processor /proc/cpuinfo)"

losetup /dev/loop0 /img/raw.img  || fail "losetup raw"
losetup /dev/loop1 /img/ext4.img || fail "losetup ext4"
losetup /dev/loop2 /img/f2fs.img || fail "losetup f2fs"
# loop0 is made rotational BEFORE the elevator attaches: ADIOS samples that once,
# and it is the only way to reach its seek-weight and elevator-order code.
echo 1 > /sys/block/loop0/queue/rotational
for d in loop0 loop1 loop2; do
  echo "$SCHED" > /sys/block/$d/queue/scheduler || fail "cannot select $SCHED on $d"
  say "$d scheduler: $(cat /sys/block/$d/queue/scheduler)"
done

# A failed write leaves dd's own last line (the errno text) in /tmp/bad.
w(){ for i in $(seq 1 $3); do dd if=/dev/urandom of=$1/$2.$i bs=64k count=4 $4 2>/tmp/err.$$.$2 || tail -1 /tmp/err.$$.$2 >> /tmp/bad; done; }
# The images are small: drop a stage's files before the next one fills them again.
clean(){ rm -f /mnt/e/[a-z].* /mnt/f/[a-z].*; sync; }
r(){ for i in 1 2 3 4 5 6; do dd if=$1 of=/dev/null bs=1M 2>/dev/null; dd if=$1 of=/dev/null bs=4k iflag=direct count=512 2>/dev/null; done; }
: > /tmp/bad

say "T1 raw write + fsync (an empty REQ_PREFLUSH request)"
dd if=/dev/zero of=/dev/loop0 bs=4k count=64 conv=fsync 2>/dev/null || fail "T1 dd"
say "T1 done"

say "T2 ext4+journal: fsync per file (jbd2 commit block = REQ_PREFLUSH|REQ_FUA)"
if mount -t ext4 /dev/loop1 /mnt/e; then
  for i in $(seq 1 40); do dd if=/dev/urandom of=/mnt/e/f$i bs=4k count=16 conv=fsync 2>/dev/null || fail "T2 dd $i"; done
  sync; ( cd /mnt/e && md5sum f* > /tmp/e.md5 )
  umount /mnt/e && mount -t ext4 /dev/loop1 /mnt/e && ( cd /mnt/e && md5sum -c /tmp/e.md5 >/dev/null ) || fail "T2 verify"
  say "T2 done"
else fail "T2 mount ext4"; fi

say "T3 f2fs: fsync per file + checkpoint"
if mount -t f2fs /dev/loop2 /mnt/f; then
  for i in $(seq 1 40); do dd if=/dev/urandom of=/mnt/f/f$i bs=4k count=16 conv=fsync 2>/dev/null || fail "T3 dd $i"; done
  sync; ( cd /mnt/f && md5sum f* > /tmp/f.md5 )
  umount /mnt/f && mount -t f2fs /dev/loop2 /mnt/f && ( cd /mnt/f && md5sum -c /tmp/f.md5 >/dev/null ) || fail "T3 verify"
  say "T3 done"
else fail "T3 mount f2fs"; fi

say "T4 parallel mixed load: buffered, O_DIRECT and fsync writers, readers, discards"
w /mnt/e a 30 conv=fsync & w /mnt/e b 30 "oflag=direct conv=fsync" & w /mnt/e c 60 "" & w /mnt/e d 30 oflag=direct &
w /mnt/f a 30 conv=fsync & w /mnt/f b 30 "oflag=direct conv=fsync" & w /mnt/f c 60 "" &
r /dev/loop1 & r /dev/loop2 & r /dev/loop0 &
( for i in $(seq 1 30); do dd if=/dev/zero of=/dev/loop0 bs=4k count=32 seek=$((i*64)) conv=fsync 2>/dev/null
    blkdiscard -o $((i*262144)) -l 131072 /dev/loop0 2>/dev/null; done ) &
( for i in $(seq 1 20); do sync; fstrim /mnt/e 2>/dev/null; fstrim /mnt/f 2>/dev/null; done ) &
wait; sync
say "T4 done"

say "T5 elevator switching under I/O (exit_sched / init_sched with requests around)"
( for i in $(seq 1 40); do dd if=/dev/urandom of=/mnt/e/s.$i bs=16k count=8 conv=fsync 2>/dev/null || echo bad >> /tmp/bad; done ) &
( for i in $(seq 1 40); do dd if=/dev/urandom of=/mnt/f/s.$i bs=16k count=8 conv=fsync 2>/dev/null || echo bad >> /tmp/bad; done ) &
for n in 1 2 3 4 5 6; do
  for s in mq-deadline "$SCHED" none kyber "$SCHED" bfq "$SCHED"; do
    for d in loop0 loop1 loop2; do echo $s > /sys/block/$d/queue/scheduler; done
  done
done
wait; sync
for d in loop0 loop1 loop2; do
  case "$(cat /sys/block/$d/queue/scheduler)" in *"[$SCHED]"*) ;; *) fail "$d did not end on $SCHED";; esac
done
say "T5 done"

clean
say "T6 nr_requests raised after init, then load"
for d in loop0 loop1 loop2; do echo 256 > /sys/block/$d/queue/nr_requests; done
say "nr_requests: $(cat /sys/block/loop1/queue/nr_requests)"
w /mnt/e z 40 conv=fsync & w /mnt/f z 40 conv=fsync & w /mnt/e y 80 "" & w /mnt/f y 80 "" & r /dev/loop1 & r /dev/loop2 &
wait; sync
say "T6 done"

if [ "$SCHED" = adios ]; then
  say "T7 adios sysfs: every show/store handler (kCFI-checked indirect calls), then load"
  for d in loop0 loop1; do
    I=/sys/block/$d/queue/iosched
    [ -d $I ] || { fail "T7 no $I"; continue; }
    for f in $I/*; do cat $f >/dev/null 2>&1; done
    echo 1 > $I/reset_bq_stats;          echo 1 > $I/reset_lat_model
    echo 30 > $I/bq_refill_below_ratio;  echo 20000000 > $I/global_latency_window
    echo 400000000 > $I/lat_model_latency_limit
    echo 3000000 > $I/lat_target_read;   echo 1500000000 > $I/lat_target_write; echo 6000000000 > $I/lat_target_discard
    echo 48 > $I/batch_limit_read;       echo 64 > $I/batch_limit_write;        echo 2 > $I/batch_limit_discard
    echo -5 > $I/read_priority;          echo 1 > $I/compliance_flags
    echo 4000 > $I/shrink_at_kreqs;      echo 40 > $I/shrink_at_gbytes;         echo 3 > $I/shrink_resist
    echo "100000 500" > $I/lat_model_read; echo "200000 800" > $I/lat_model_write; echo "900000 10" > $I/lat_model_discard
    echo "100000 500 200000 800 900000 10" > $I/reset_lat_model
  done
  # loop0 is rotational: only there is batch_order=1 (elevator order) accepted.
  echo 1 > /sys/block/loop0/queue/iosched/batch_order || fail "T7 batch_order=1 on rotational loop0"
  say "adios $(cat /sys/block/loop1/queue/iosched/adios_version); loop0 batch_order=$(cat /sys/block/loop0/queue/iosched/batch_order)"
  clean
  w /mnt/e q 30 conv=fsync & w /mnt/f q 30 conv=fsync & w /mnt/e p 40 "" & r /dev/loop0 & r /dev/loop1 &
  ( for i in $(seq 1 60); do dd if=/dev/urandom of=/dev/loop0 bs=4k count=8 seek=$(( (i*37) % 3000 )) oflag=direct conv=fsync 2>/dev/null || echo bad >> /tmp/bad; done ) &
  ( for i in $(seq 1 60); do dd if=/dev/loop0 of=/dev/null bs=4k count=8 skip=$(( (i*91) % 3000 )) iflag=direct 2>/dev/null; done ) &
  wait; sync
  say "batch_actual_max: $(cat /sys/block/loop1/queue/iosched/batch_actual_max | tr '\n' ' ')"
  say "T7 done"
fi

[ -s /tmp/bad ] && fail "writer errors: $(wc -l < /tmp/bad), first: $(head -1 /tmp/bad)"
say "T8 data written in T2/T3 still verifies after everything above"
umount /mnt/e && mount -t ext4 /dev/loop1 /mnt/e && ( cd /mnt/e && md5sum -c /tmp/e.md5 >/dev/null ) || fail "T8 ext4 verify"
umount /mnt/f && mount -t f2fs /dev/loop2 /mnt/f && ( cd /mnt/f && md5sum -c /tmp/f.md5 >/dev/null ) || fail "T8 f2fs verify"
umount /mnt/e || fail "umount ext4"; umount /mnt/f || fail "umount f2fs"
say "T8 done"

[ "$FAILED" = 0 ] && say "ALL TESTS PASSED sched=$SCHED" || say "SOME TESTS FAILED sched=$SCHED"
echo o > /proc/sysrq-trigger; sleep 30
EOF
chmod 755 "$R/init"
truncate -s 16M "$R/img/raw.img"
truncate -s 96M "$R/img/ext4.img" && mkfs.ext4 -q -F -O has_journal -J size=8 "$R/img/ext4.img" || { echo "mkfs.ext4 failed"; exit 2; }
truncate -s 128M "$R/img/f2fs.img" && mkfs.f2fs -q -f "$R/img/f2fs.img" >/dev/null || { echo "mkfs.f2fs failed"; exit 2; }
( cd "$R" && find . | cpio -o -H newc --quiet | gzip -1 ) > "$TMP/initramfs.cpio.gz" || { echo "cpio failed"; exit 2; }

# ── Host: boot one Image with one elevator, leave the serial log in $TMP ─────
# cortex-a76 keeps AArch32 EL0, which the zip's ARM32 busybox needs. A panic
# reboots (CONFIG_PANIC_TIMEOUT=-1) and -no-reboot turns that into an exit.
boot() { # <image> <sched> <log>
  timeout 600 qemu-system-aarch64 -machine virt,gic-version=3 -cpu cortex-a76 -smp 4 -m 3072 \
    -nographic -no-reboot -monitor none -serial "file:$3" \
    -kernel "$1" -initrd "$TMP/initramfs.cpio.gz" \
    -append "console=ttyAMA0 earlycon=pl011,0x9000000 rdinit=/init printk.devkmsg=on nokaslr loglevel=7 rig.sched=$2" \
    </dev/null >/dev/null 2>&1
}
BAD='Unable to handle|Internal error|Kernel panic|kernel BUG|BUG:|WARNING:|CFI failure|Call trace|RIG: FAIL|SOME TESTS FAILED'

expect_clean() { # <image> <sched> <log>
  boot "$1" "$2" "$3"
  if grep -aEq "$BAD" "$3"; then grep -aE "$BAD|pc :|lr :" "$3" | head -12; return 1; fi
  grep -aq "RIG: ALL TESTS PASSED sched=$2" "$3" || { echo "guest never reported ALL TESTS PASSED:"; tail -5 "$3"; return 1; }
  grep -aq "RIG: T8 done" "$3" || { echo "guest did not reach T8"; return 1; }
  grep -a "RIG: kernel" "$3" | sed 's/^.*RIG: //'
}
expect_adios_oops() { # <image> <log>
  boot "$1" adios "$2"
  grep -aq "pc : adios_completed_request" "$2" && grep -aq "Kernel panic" "$2" \
    && ! grep -aq "RIG: ALL TESTS PASSED" "$2" || { echo "v1 did not die in adios_completed_request:"; grep -aE "RIG:|pc :" "$2" | tail -8; return 1; }
  grep -aE "RIG: kernel|Unable to handle|pc : " "$2" | sed 's/^\[[^]]*\]\[[^]]*\] //'
}

pass=0; fail=0
run_case() {
  local name="$1" out rc; shift
  out="$("$@" 2>&1)"; rc=$?
  if [[ "$rc" == 0 ]]; then printf "  [PASS] %s\n" "$name"; pass=$((pass + 1))
  else printf "  [FAIL] %s\n" "$name"; fail=$((fail + 1)); fi
  echo "$out" | sed 's/^/         /'
}

echo "=== ADIOS runtime self-test (QEMU) — $IMAGE ==="
run_case "POS-1: built Image, mq-deadline: the rig passes on a known-good elevator" \
  expect_clean "$IMAGE" mq-deadline "$TMP/pos1.log"
run_case "POS-2: built Image, adios: flush/FUA I/O, switching, sysfs — clean log" \
  expect_clean "$IMAGE" adios "$TMP/pos2.log"
if [[ -f "$V1_ZIP" ]] && command -v unzip >/dev/null; then
  unzip -p "$V1_ZIP" Image > "$TMP/Image.v1"
  run_case "NEG-1: v1 (20261107) Image, adios: dies in adios_completed_request" \
    expect_adios_oops "$TMP/Image.v1" "$TMP/neg1.log"
else
  echo "  [SKIP] NEG-1: $V1_ZIP not present — the negative control did not run"
fi

echo "=== $pass passed, $fail failed ==="
[[ "$fail" == 0 ]]
