# apparmor-unix-connect-leak

Test harness for an AppArmor label refcount leak in `apparmor_unix_stream_connect()` (mainline v6.17+): every
AF_UNIX stream connect leaks one reference to the connecting task's label. The workflow builds a pinned mainline
commit natively on riscv64, unpatched and with the fix (`fix.patch`), and runs the same QEMU guest test on both.
Run it from Actions → "aa3833 riscv64 kernel test" → Run workflow.
