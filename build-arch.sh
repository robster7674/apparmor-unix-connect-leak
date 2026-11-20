#!/bin/bash
# Build base + fix kernels for one architecture from the pinned mainline commit, in its own worktree.
# Usage: SHA=<sha> build-arch.sh arm64|riscv   (native or cross; CROSS_COMPILE picked automatically)
# Output: /root/out/<arch>/Image-{base,fix}, config, logs.
set -euo pipefail
A=${1:?arch}; SHA=${SHA:?sha}; J=${J:-6}
case $A in
  arm64) IMG=arch/arm64/boot/Image; X=aarch64-linux-gnu- ;;
  riscv) IMG=arch/riscv/boot/Image; X=riscv64-linux-gnu- ;;
  x86)   IMG=arch/x86/boot/bzImage; X= ;;
esac
host=$(uname -m); { [ "$A" = arm64 ] && [ "$host" = aarch64 ]; } || { [ "$A" = riscv ] && [ "$host" = riscv64 ]; } && X=
export ARCH=$A CROSS_COMPILE=$X
# riscv: dynamic ftrace with RISCV_ISA_C needs -fmin-function-alignment (GCC 14); Ubuntu 24.04's default gcc is 13
KCC=; [ "$A" = riscv ] && { KCC=${X}gcc-14; command -v "$KCC" >/dev/null || { echo "need $KCC"; exit 1; }; }
mk() { make ${KCC:+CC=$KCC} "$@"; }
O=/root/out/$A; mkdir -p "$O"
W=${WT:-/root/k-$A}
if [ ! -e "$W/.git" ]; then
  if [ -e /root/k/.git ]; then git -C /root/k worktree add -q --detach "$W" "$SHA"
  else mkdir -p "$W" && cd "$W" && git init -q && git remote add origin https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git && git fetch -q --depth 1 origin "$SHA" && git checkout -q --detach "$SHA"; fi
fi
cd "$W" && git checkout -q --detach "$SHA" && git log -1 --format='%H %s' > "$O/base-commit.txt"
mk -s defconfig
c=scripts/config
$c -e SECURITY -e SECURITY_NETWORK -e SECURITYFS -e AUDIT \
   -e SECURITY_APPARMOR -e SECURITY_APPARMOR_DEBUG -e SECURITY_APPARMOR_DEBUG_ASSERTS -d DEFAULT_SECURITY_DAC -e DEFAULT_SECURITY_APPARMOR \
   --set-str LSM "landlock,lockdown,yama,apparmor,bpf" \
   -d DEBUG_INFO_NONE -e DEBUG_INFO_DWARF5 -d DEBUG_INFO_REDUCED -e DEBUG_INFO_BTF \
   -e BPF_SYSCALL -e BPF_JIT -e BPF_EVENTS -e KPROBES -e KPROBE_EVENTS -e FTRACE -e FUNCTION_TRACER \
   -e DYNAMIC_FTRACE -e PERF_EVENTS \
   -e UNIX -e EXT4_FS -e VIRTIO -e VIRTIO_PCI -e VIRTIO_MMIO -e VIRTIO_BLK -e VIRTIO_NET -e VIRTIO_CONSOLE \
   -e ISO9660_FS -e JOLIET -e DEBUG_KMEMLEAK -d DEBUG_KMEMLEAK_DEFAULT_OFF \
   --set-str LOCALVERSION "-aa3833" -d LOCALVERSION_AUTO
mk -s olddefconfig
for o in SECURITY_APPARMOR DEFAULT_SECURITY_APPARMOR DEBUG_INFO_BTF SECURITY_APPARMOR_DEBUG_ASSERTS BPF_EVENTS FUNCTION_TRACER VIRTIO_BLK VIRTIO_NET EXT4_FS; do
  grep -q "^CONFIG_$o=y" .config || { echo "config $o missing"; exit 1; }
done
cp .config "$O/config"
k=$(basename $IMG)
nice -n 19 make ${KCC:+CC=$KCC} -j"$J" $k > "$O/build-base.log" 2>&1 || { tail -30 "$O/build-base.log"; exit 1; }
cp $IMG "$O/$k-base"
git -c user.name=Rob -c user.email=rob@performanceinsights.ai am -q /root/fix.patch
nice -n 19 make ${KCC:+CC=$KCC} -j"$J" $k > "$O/build-fix.log" 2>&1 || { tail -30 "$O/build-fix.log"; exit 1; }
cp $IMG "$O/$k-fix"
git checkout -q --detach "$SHA"
echo BUILD-OK $A
