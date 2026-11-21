#!/bin/bash
# QEMU guest (TCG; KVM when an x86 guest runs on an x86 host that has /dev/kvm) from a pinned Ubuntu 24.04 cloud image, one directory per VM.
# Usage: vm.sh <x86|arm64|riscv> <vmname> prep            -> fresh disk + cloud-init seed (installs bpftrace)
#        vm.sh <x86|arm64|riscv> <vmname> run <kernel> <label> -> boot kernel, run guest-test.sh, save /root/out/test-<vmname>-<label>.txt
set -euo pipefail
A=$1; N=$2; CMD=$3
R=https://cloud-images.ubuntu.com/releases/noble/release-20261017
case $A in
  x86)   F=ubuntu-24.04-server-cloudimg-amd64.img;   S=04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94
         Q="qemu-system-x86_64 -machine q35 -cpu max"; CON=ttyS0 ;;
  arm64) F=ubuntu-24.04-server-cloudimg-arm64.img;   S=50e24e1fb79e89116e939d90aa7738f7af48c442fa1bc2510131e0b39c50348e
         Q="qemu-system-aarch64 -machine virt -cpu max"; CON=ttyAMA0 ;;
  riscv) F=ubuntu-24.04-server-cloudimg-riscv64.img; S=2d48190b4de1a809879c7b2137381a24b52a3a23a65b4d4a7b3f6d7ae774b7e9
         Q="qemu-system-riscv64 -machine virt -cpu rv64"; CON=ttyS0 ;;
esac
ACCEL=tcg,thread=multi
if [ "$A" = x86 ] && [ "$(uname -m)" = x86_64 ] && [ -w /dev/kvm ]; then ACCEL=kvm; Q=${Q/-cpu max/-cpu host}; fi
I=/root/vm/images; V=/root/vm/$N; mkdir -p "$I" "$V"
PORT=$((2200 + $(printf '%s' "$N" | cksum | cut -d' ' -f1) % 700))
SSH="ssh -q -i $V/key -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 root@127.0.0.1"

case $CMD in
prep)
  [ -e "$I/$F" ] || curl -sfL -o "$I/$F" "$R/$F"
  (cd "$I" && echo "$S  $F" | sha256sum -c -)
  rm -f "$V/disk.qcow2"; qemu-img create -q -f qcow2 -F qcow2 -b "$I/$F" "$V/disk.qcow2" 20G
  rm -f "$V/key" "$V/key.pub"; ssh-keygen -q -t ed25519 -N '' -f "$V/key"
  cat > "$V/user-data" <<EOF
#cloud-config
disable_root: false
users: [{name: root, ssh_authorized_keys: ["$(cat "$V/key.pub")"]}]
package_update: true
packages: [bpftrace, python3]
runcmd: [[touch, /root/cloud-init-done]]
EOF
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$N" "$(date +%s)" "$N" > "$V/meta-data"
  cloud-localds "$V/seed.img" "$V/user-data" "$V/meta-data"
  echo "PREP-OK $N port=$PORT" ;;
run)
  K=$4; L=$5
  $Q -accel $ACCEL -smp 4 -m 6G \
    -kernel "$K" -append "root=/dev/vda1 rw console=$CON apparmor=1 lsm=landlock,lockdown,yama,apparmor,bpf net.ifnames=0" \
    -drive file="$V/disk.qcow2",if=virtio,format=qcow2 -drive file="$V/seed.img",if=virtio,format=raw \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22 -device virtio-net-pci,netdev=n0,romfile= \
    -display none -serial file:"$V/console-$L.log" -daemonize -pidfile "$V/qemu.pid"
  up=; for _ in $(seq 240); do $SSH true 2>/dev/null && { up=1; break; }; sleep 10; done
  [ -n "$up" ] || { echo "guest did not come up"; tail -40 "$V/console-$L.log"; kill "$(cat "$V/qemu.pid")"; exit 1; }
  for _ in $(seq 180); do $SSH test -e /root/cloud-init-done && break; sleep 10; done
  echo "accel=$ACCEL"
  $SSH 'uname -a; command -v bpftrace aa-exec apparmor_parser python3; cat /sys/kernel/security/lsm; echo; aa-enabled'
  $SSH 'cat > /root/guest-test.sh' < /root/guest-test.sh
  $SSH 'bash /root/guest-test.sh' 2>&1 | tee "/root/out/test-$N-$L.txt"
  $SSH 'dmesg' > "/root/out/dmesg-$N-$L.txt" || true
  $SSH 'poweroff' || true
  for _ in $(seq 60); do kill -0 "$(cat "$V/qemu.pid")" 2>/dev/null || break; sleep 5; done
  kill "$(cat "$V/qemu.pid")" 2>/dev/null || true
  echo "RUN-OK $N $L" ;;
esac
