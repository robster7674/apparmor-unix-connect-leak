#!/bin/bash
# Runs inside the QEMU guest as root. Prints one RESULT line per test.
# T1: profile freed after removal, for N = 0, 1, 20 stream connects by a confined client.
# T2: SO_PEERSEC on both ends still reports the right labels (fix must not change labeling).
# T3: 2000 connects with 50 sockets held open across a profile replace, then close + remove: old and new profile freed.
# T4: kernel log during the test (cleared at start) has no refcount/BUG/WARNING lines. af_inet.c:100 is the
#     unrelated AA_BUG(!addr) debug assert in map_addr(), reachable from read() on INET sockets; counted separately.
set -u
D=$(mktemp -d /tmp/aat.XXXX); chmod 755 "$D"
SOCK=$D/s
uname -r
echo "boot-time af_inet.c:100 asserts before the test: $(dmesg | grep -c 'af_inet.c:100')"
[ -n "${KEEP_DMESG:-}" ] || dmesg -C   # KEEP_DMESG=1 on a shared host: never clear its log
python3 -I -c '
import socket, os, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1]); os.chmod(sys.argv[1], 0o777); s.listen(512)
while True:
    c, _ = s.accept()
    try: lab = c.getsockopt(socket.SOL_SOCKET, socket.SO_PEERSEC, 256).rstrip(b"\0").decode()
    except OSError as e: lab = "ERR " + str(e)
    try: c.sendall(lab.encode() + b"\n")
    except OSError: pass
    c.close()
' "$SOCK" & SRV=$!
sleep 1

mkprof() { printf 'abi <abi/4.0>,\nprofile %s flags=(complain) {\n  /** rwmix,\n  unix,\n%s}\n' "$1" "${2:-}" > "$D/$1"; }

# watch_start NAME SECONDS OUT: count aa_free_profile calls for NAME; returns once the probe is attached.
watch_start() {
  bpftrace -q -e "BEGIN { printf(\"READY\n\"); } fentry:aa_free_profile /strncmp(str(args->profile->base.hname), \"$1\", ${#1}) == 0/ { @n++; }
    interval:s:$2 { exit(); } END { printf(\"FREES %d\n\", @n); clear(@n); }" > "$3" 2>&1 &
  WPID=$!
  for _ in $(seq 600); do grep -q READY "$3" && return 0; kill -0 $WPID 2>/dev/null || break; sleep 0.5; done
  echo "bpftrace did not attach:"; cat "$3"; return 1
}
frees() { awk '/^FREES/{print $2}' "$1"; }  # call after: wait "$WPID" (not inside $(...): a subshell cannot wait for it)

client() { # PROFILE N HOLD READYFILE
  aa-exec -p "$1" -- python3 -I -c '
import socket, sys, os, time
n, hold = int(sys.argv[2]), int(sys.argv[3]); keep = []; last = ""
for i in range(n):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.connect(sys.argv[1])
    last = c.recv(256).decode().strip()
    if len(keep) < hold: keep.append(c)
    else: c.close()
mine = ""
if n:
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.connect(sys.argv[1]); c.recv(256)
    mine = c.getsockopt(socket.SOL_SOCKET, socket.SO_PEERSEC, 256).rstrip(b"\0").decode(); c.close()
print("SERVER_SAW=%s CLIENT_SAW=%s" % (last, mine))
if hold:
    sys.stdout.flush(); open(sys.argv[4], "w").close()
    while not os.path.exists(sys.argv[4] + ".go"): time.sleep(0.2)
' "$SOCK" "$2" "${3:-0}" "${4:-/dev/null}"
}

# T1 + T2
for n in 0 1 20; do
  P=t1n$n; mkprof $P; apparmor_parser -a "$D/$P"
  out=$(client $P $n)
  watch_start $P 30 "$D/f.$P"
  apparmor_parser -R "$D/$P"
  wait "$WPID"; f=$(frees "$D/f.$P")
  echo "RESULT T1 n=$n frees=$f $([ "${f:-0}" -ge 1 ] && echo FREED || echo NOT_FREED)"
  [ "$n" = 20 ] && echo "RESULT T2 $out"
done

# T3: replace while sockets are held
P=t3; mkprof $P; apparmor_parser -a "$D/$P"
watch_start $P 150 "$D/f.t3"
client $P 2000 50 "$D/ready" > "$D/t3.out" & C=$!
for _ in $(seq 300); do [ -e "$D/ready" ] && break; sleep 1; done
mkprof $P '  capability chown,
'; apparmor_parser -r "$D/$P"
touch "$D/ready.go"; wait $C
sleep 1; apparmor_parser -R "$D/$P"
wait "$WPID"; f=$(frees "$D/f.t3")
echo "RESULT T3 frees=$f (expect 2: original + replacement) $(cat "$D/t3.out")"

# T4
afinet=$(dmesg | grep -c 'af_inet.c:100')
bad=$(dmesg | grep -E 'refcount_t|use-after-free|KASAN|BUG:|Oops|WARNING:' | grep -vc 'af_inet.c:100')
echo "RESULT T4 problems=$bad unrelated_af_inet_asserts=$afinet"
dmesg | grep -E 'refcount_t|use-after-free|KASAN|BUG:|Oops|WARNING:' | grep -v 'af_inet.c:100' | head -20
kill $SRV; rm -rf "$D"
