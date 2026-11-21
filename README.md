# AppArmor: every AF_UNIX stream `connect()` leaks a label reference

`apparmor_unix_stream_connect()` in `security/apparmor/lsm.c` overwrites the label that `apparmor_sk_alloc_security()`
already stored in the new server-side socket, without putting it. Every successful AF_UNIX stream connect therefore
leaks one reference to the connecting task's label. A label that is never released keeps its profiles and their policy
namespace allocated after the profile is removed or replaced.

This repository holds the one-line fix ([`fix.patch`](fix.patch)), the reproducer and test scripts, and the workflows
that run them on real kernels. Everything below can be re-run from here.

**Status:** on 2026-11-20 it was unfixed in mainline, `apparmor-next` and `apparmor-next-next`, with no other report
on lore.kernel.org or in the apparmor-kernel GitLab; mainline still leaks as of 2026-11-21 (see the results). The patch is going to the AppArmor list as an ordinary public patch.
This section is updated with the lore link once it is sent.

## Which kernels

| Kernel | Has the bug? |
|---|---|
| mainline, `apparmor-next` | yes |
| v7.3 stable, v6.18 longterm | yes (checked in the source of 7.3.5 and 6.18.64; built and run, see the [results](#results)) |
| v6.17 | yes by the source (first release with 88fec3526e84; not run) |
| v6.16 and older mainline | no (the commit is not in v6.16) |
| longterm 6.12, 6.6, 6.1, 5.15, 5.10 | no (no `apparmor_unix_stream_connect()` in the latest of each) |
| Ubuntu 7.0.0-42 | yes (reproduced) |
| Ubuntu 6.8 (noble) | no (its out-of-tree code leaves the label NULL at alloc and guards the connect hook) |

## The bug

Since 88fec3526e84 ("apparmor: make sure unix socket labeling is correctly updated.", v6.17):

1. `unix_stream_connect()` allocates the server-side socket `newsk` with `unix_create1()`, which calls
   `security_sk_alloc()`. `apparmor_sk_alloc_security()` stores `aa_get_label(<current label>)` in `newsk`'s context.
   This holds for any task, the namespace's `unconfined` label included (read from the source, not tested separately).
2. `unix_stream_connect()` then calls `security_unix_stream_connect()`. `apparmor_unix_stream_connect()` does
   `rcu_assign_pointer(new_ctx->label, aa_get_label(peer_ctx->label))`. It never puts the label from step 1.

Before that commit the label was NULL at alloc and the hook guarded the assignment with `if (!new_ctx->label)`.
f3c0675bb9e0 later removed the `AA_BUG()` that asserted `new_ctx->label` was still NULL here, which left the reference.
The sibling hooks `apparmor_socket_post_create()`, `apparmor_socket_socketpair()` and `apparmor_sk_clone_security()` all
put the old label before overwriting it. Only the connect hook does not.

## The fix

```c
	/* newsk doesn't go through post_create, but does go through
	 * security_sk_alloc()
	 */
+	aa_put_label(rcu_dereference_protected(new_ctx->label, true));
	rcu_assign_pointer(new_ctx->label,
```

The full patch with changelog is [`fix.patch`](fix.patch). It applies, with an offset, to v6.18.64 and v7.3.5.

## How it was found

A CI host running Ubuntu's 7.0 kernel (with Incus containers, each job in its own AppArmor namespace and profile) showed
steadily growing unreclaimable slab. Two AppArmor leaks were behind it:

1. `aa_get_newest_profile()` in a `labels_profile()` macro that evaluates its argument twice. Fixed upstream in
   33ed50716251 (in stable 6.18.63 and 7.3.4), not yet in Ubuntu 7.0.0-42 or -43.
2. This bug. It was found because the first one did not explain everything: the profile of a finished job was still
   never freed.

For the second leak a hardware watchpoint (bpftrace `watchpoint`) on one job's stacked label counted every refcount
write by call site, 568,224 of them. The container made 52 AF_UNIX stream connects; each one is an increment at
`apparmor_unix_stream_connect+226` with no matching put anywhere, and the label kept exactly 52 references for three
minutes after the container was gone. Every other object kind balanced within the window. In a survey of 13 such jobs,
none of the stacked labels was ever freed, each holding 51 or 52 references.

## The reproducer

[`guest-test.sh`](guest-test.sh) runs inside a guest that boots the kernel under test. A bpftrace
`fentry:aa_free_profile` probe, attached before each action, counts frees of the profile under test. All profiles are
in complain mode and the client runs under `aa-exec`.

| Test | What it does | Expected |
|---|---|---|
| T1 | Load a profile, make N AF_UNIX stream connects (N = 0, 1, 20) from a client confined by it, remove the profile. | Profile freed. N = 0 is the control. |
| T2 | `SO_PEERSEC` on both ends of a connection. | Server sees the client's label, client sees the peer's: the fix must not change labeling. |
| T3 | 2000 connects with 50 sockets held open across `apparmor_parser -r`, then close them and remove the profile. | 2 frees: the original and the replacement. |
| T4 | Kernel log, cleared at the start. | No `refcount_t`, KASAN, `BUG:`, `Oops` or `WARNING:` lines. |

Unpatched, N = 0 frees the profile, but N = 1 and N = 20 do not (the test waits 30 s) and T3 frees 1 of 2. A leak of one reference per
connect is why one connect is enough.

## Results

### Mainline 4405c18c95d2 (v7.4-rc3+, 2026-11-18), three architectures

Defconfig plus AppArmor as the default LSM, `SECURITY_APPARMOR_DEBUG_ASSERTS`, BTF and ftrace for bpftrace, and
kmemleak. KASAN was not enabled, so "clean" in T4 means no refcount, `BUG:` or `WARNING:` lines, not a KASAN pass. The same tree was built unpatched and with `fix.patch`. Guests: Ubuntu 24.04 cloud image release-20261017
(pinned by SHA256), booted with `-kernel` under QEMU TCG (no KVM). x86-b is an independent repeat on a fresh disk.

| | x86-a | x86-b | arm64 | riscv64 |
|---|---|---|---|---|
| **unpatched** T1 n=0 (control) | freed | freed | freed | freed |
| **unpatched** T1 n=1 / n=20 | **not freed** | **not freed** | **not freed** | **not freed** |
| **unpatched** T3 frees | **1 of 2** | **1 of 2** | **1 of 2** | **1 of 2** |
| **fix** T1 n=0 / 1 / 20 | freed | freed | freed | freed |
| **fix** T3 frees | 2 of 2 | 2 of 2 | 2 of 2 | 2 of 2 |
| T2 peer labels, unpatched = fix | yes | yes | yes | yes |
| T4 kernel log | clean | clean | clean | clean |

The riscv64 column is QEMU emulation on an x86 host. `riscv.yml` builds natively on a riscv64 runner, but RISC-V
runners available to me lack the hypervisor extension, so the guest still runs under TCG there: it exercises the same
emulated CPU, and the leak is architecture-independent refcount logic.

Ubuntu 7.0.0-42 (distribution kernel, bpftrace on the live host): n=1 and n=20 not freed, T3 1 of 2.

Patch checks: `checkpatch.pl` reports no code findings (it complains about the missing Signed-off-by and about
unknown commit ids in a shallow tree); `W=1` on `security/apparmor/lsm.o` is empty with and without the fix on all three
architectures. Peer labels read the same on both kernels: `SERVER_SAW=t1n20 (complain)`, `CLIENT_SAW=unconfined`.

### Latest longterm, stable and mainline (x86_64)

The newest longterm, newest stable and the head of mainline on 2026-11-21, built unpatched and with `fix.patch` by
[`x86.yml`](.github/workflows/x86.yml) (run [44920931145](https://github.com/robster7674/apparmor-unix-connect-leak/actions/runs/44920931145)).
Same config and test as above; the guest ran under KVM on a GitHub-hosted runner. Ubuntu 24.04 cloud image
release-20261017, as before.

| | longterm 6.18.64 | stable 7.3.5 | mainline head (7.4.0-rc3+) |
|---|---|---|---|
| commit | `fd7cfd39c885` | `988117cc1bb1` | `c44104f3642d` |
| **unpatched** T1 n=0 (control) | freed | freed | freed |
| **unpatched** T1 n=1 / n=20 | **not freed** | **not freed** | **not freed** |
| **unpatched** T3 frees | **1 of 2** | **1 of 2** | **1 of 2** |
| **fix** T1 n=0 / 1 / 20 | freed | freed | freed |
| **fix** T3 frees | 2 of 2 | 2 of 2 | 2 of 2 |
| T2 peer labels, unpatched = fix | yes | yes | yes |
| T4 kernel log, unpatched and fix | clean | clean | clean |

The longterm 6.18.64 kernel already contains 33ed50716251 (the `labels_profile()` fix mentioned above), so this leak is
independent of it. Full commit ids: `fd7cfd39c88596fec816639ad83cbf3e9d316372`,
`988117cc1bb17338c586a4e21ade88b5397eac33`, `c44104f3642da720164042623e4832836aefdd8e`. The unpatched mainline head
still leaks, three days after 4405c18c95d2.

## Run it yourself

- **Actions:** `x86_64 kernel matrix` (`x86.yml`) resolves the newest longterm, stable and mainline head from
  kernel.org, builds each unpatched and fixed, runs T1 to T4 in a QEMU guest and uploads the logs and configs. Start it
  from the Actions tab (optionally with `only` = `longterm`, `stable` or `mainline`). `aa3833 riscv64 kernel test`
  (`riscv.yml`) does the same natively on a riscv64 runner, for one pinned commit.
- **By hand:** `SHA=<sha> build-arch.sh x86|arm64|riscv` builds the two kernels from a pinned commit (it applies
  `fix.patch` with `git am`); `vm.sh <arch> <name> prep` then `vm.sh <arch> <name> run <kernel> <label>` boots one in a
  guest and runs `guest-test.sh`. The scripts assume `/root` as the working directory and a Debian or Ubuntu host with
  QEMU. They are test scaffolding, not polished tools.
- **On a live host:** `KEEP_DMESG=1 bash guest-test.sh` as root runs the same tests without clearing the kernel log. It
  needs `bpftrace`, `apparmor_parser`, `aa-exec` and python3, and it loads and removes profiles named `t1n*` and `t3`.

## Side finding

`AA_BUG(!addr)` in `map_addr()` (`security/apparmor/af_inet.c:100`) fires on `read()` from INET sockets through
`aa_inet_msg_perm()` with a NULL `msg_name`; `map_sock_addr()` also passes NULL explicitly. It only exists with
`CONFIG_SECURITY_APPARMOR_DEBUG_ASSERTS`, which distribution kernels leave off, so it is harmless in practice. The test
counts these lines separately in T4.

## About this work

The bug was found, and the patch, its changelog and these scripts were written, with an AI coding assistant (Claude
Code) while tracing the slab growth. A human reviews the patch and sends it upstream; the assistant sends nothing and adds
no `Signed-off-by:`, following the kernel's `Documentation/process/coding-assistants.rst`. The
logs of every run are in the workflow artifacts.
