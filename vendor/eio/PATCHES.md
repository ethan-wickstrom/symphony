# Eio source and local refinement

This directory retains the full Eio 1.6 source baseline from the installed,
opam-verified `eio_posix.1.6` archive. Symphony pins both `eio` and `eio_posix`
to this copy. The macOS custody gate passes; Linux host behavior remains unverified.

- Upstream: <https://github.com/ocaml-multicore/eio>
- Release: <https://github.com/ocaml-multicore/eio/releases/download/v1.6/eio-1.6.tbz>
- Release commit: `1fc0efa41ccfb3818b09f54feec90ec29b47f1b6`
- Archive SHA-256: `c1f04986b401094176494863dde1ca9b292b59fdc679a9d7023e558d80fb5b15`
- Archive SHA-512: `92ed8cf20300b8a4e0141bdbc373c0803c5a24530cb65852637d905fff4a5b956a8859a00a424034ff78c1112da9b0391194bcd558326168bdebd1ce683a8890`
- `LICENSE.md` is unchanged, including its third-party notices. Its SHA-256 is
  `59c3be7bdb792b7d7cf7a7b946eca4301454db6ea3164cf86fda4666d2707b41`.

## Delta

`lib_eio_posix/low_level.ml` and `.mli` add the narrow
`Process.Group` module. `eio_group_stubs.c` implements non-reaping `waitid`
observation and a bounded Darwin group snapshot. `dune` registers that stub;
`primitives.h` declares its two externals. `lib_eio/unix/thread_pool.ml` and
`.mli` resume suspended callers when native worker acquisition fails, preserving
backtraces. Only acquisition `Sys_error` becomes the typed
`Eio.Io / Not_available / Worker_unavailable` reason; worker callback exceptions
retain their original categories. Existing C fork actions are unchanged.

The new module owns its process identity. Callers supply a directory descriptor,
the three standard streams, and explicit executable, arguments, and environment.
The library establishes the group, changes directory by descriptor, maps exactly
those streams, and executes. It runs no OCaml code between fork and exec.

The private lifecycle is `Reserved -> Launching -> Held -> Reaping -> Reaped`.
Cancellation during launch records `Launching_cancelled`; failed or canceled
pre-fork reservation becomes `Revoked`. One Eio system-thread job acknowledges
availability before fork, observes with blocking `WNOWAIT`, then retains custody
until cleanup grants sole reap authority. Native condition waits release the
runtime. Cleanup requests final group/direct KILL while the leader reserves its
PID, wakes that existing worker, and joins completion. It allocates no additional
native worker. A failed fork/exec joins cleanup before returning an error value.
No scheduler mutex is held across a condition or kernel wait.

Numeric identity and wait authority remain private. Cancellation callbacks make
only short custody changes/signaling requests and never join or switch fibers.
Cleanup errors remain values in execution order. A mandatory sink reports each
failed cleanup once outside the native job/mutex, with shared reporting completion
for concurrent closes. Failed launch plus cleanup failure returns both errors.
Automatic release retains sink defects without replacing primary outcomes;
public close exposes a retained sink defect after checking cancellation.
Kernel liveness has no finite reaping guarantee.

## Host evidence and boundary

The original API reproduced the motivating failure on macOS: the shell leader
exited and was reaped while its TERM-ignoring descendant retained stdout; the
old protected positive-PID KILL could no longer terminate that descendant.
Reusing the released identifier for a raw negative-PID signal is unsafe. The
regression does not attempt real PID recycling or signal unrelated processes.

The frozen candidate builds all local Eio/Unix/POSIX libraries against installed
dependencies without installing them. On macOS 26.5.1 arm64 with OCaml 5.5.0,
three quiet campaigns passed 15,000 scenarios: early leader exit, retained status,
TERM-ignoring children, scope cleanup, startup/running cancellation, and failed
exec. Each also checked descriptor cwd after rename/symlink replacement. Explicit
successful/permission-error cleanup counts were 2,000/0, 1,999/1, and 1,999/1;
repeated-signal permission-error counts were 4, 1, and 2. Errors remain values.

Focused controls passed 1,000 public-close cancellations, 1,000 concurrent-close
pairs, first TERM/KILL permission failures, ordered group/direct/reap errors,
and TERM/KILL/ABRT observations compared with actual `waitpid`. A native barrier
forces cancellation before worker acknowledgement, proving joined revocation
with zero fork and observation calls. Failed exec retains both launch and cleanup
errors after a real reap. Repeated/concurrent closes report once; reporter defects
preserve the primary cancellation or launch result.

Independent exact-source controls passed normally and with `PYTHONOPTIMIZE=1`.
They inject worker-acquisition failure and compare the original uncaught path,
verify typed classification and original backtrace, prove zero fork, then dispatch
and reap successfully in the same switch. Worker callback `Sys_error`,
`Out_of_memory`, and `Invalid_argument` retain their categories. An injected
initial native-condition defect joins revoked completion with zero fork and
preserves its original exception. This deterministic fault control does not prove
recovery from corrupted native synchronization or arbitrary memory exhaustion.
No actual thread exhaustion is attempted. Independent final custody review found
no remaining concrete blocker in the frozen source.

Frozen SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `lib_eio_posix/low_level.ml` | `5657d0b954fa42ec67fd6d431acf53a2a78cee599b999cee1b2a876a3c925567` |
| `lib_eio_posix/low_level.mli` | `3db12a21ffd3880b6fb3c809f0c157eb54857cc9daf8d4c0778328fabae17fd4` |
| `lib_eio_posix/eio_group_stubs.c` | `eb2efda1ad4aeb970725ae23272a07cb3eb263edf47ba9ea36d3efa567926803` |
| `lib_eio/unix/thread_pool.ml` | `39a2e51ecf1d9c01b91f954947e44938ba814d1fe49d0ec189664a4435a34886` |
| `lib_eio/unix/thread_pool.mli` | `f1bd75e98c668926258e6667d923ed2e6164f40eaddc83eef6675b49dcc3de37` |
| `lib_eio_posix/sched.ml` (unchanged) | `752a5faac33ce44dc4f876a04e16fffaf310f2f5f7e6765c39ed1ff3afc27519` |
| `lib_eio_posix/sched.mli` (unchanged) | `d47a05e43ec4421414539e9f611d5385723e6e93b3e04ead5c6a9480e8276480` |
| `lib_eio_posix/dune` | `b378971d8f2af70113a99805b78f851515f041cd08b88b75db188e0a5b29ef7d` |
| `lib_eio_posix/primitives.h` | `8194dd3d12a8712187cdff5cdc0adec2cea1b09648dab4cdf953517903ddbace` |

Reproduction and paired fixtures are in `symphony_tests/`. Retained logs:
`/private/tmp/symphony-group-frozen-final`,
`/private/tmp/symphony-typed-thread-frozen-normal`, and
`/private/tmp/symphony-typed-thread-frozen-optimized`.
The native runner's `provenance.json` also hashes scheduler and build declarations.

Darwin's public POSIX group signal excludes zombies and can report `EPERM` for a
group with no eligible recipient. `killpg` uses the same kernel behavior; its
legacy compatibility symbol maps genuine permission failures to `ESRCH`.
Neither changes the custody problem. Blanket `EPERM` suppression was rejected.
After `EPERM` only, the current helper accepts an empty or entirely `SZOMB`
snapshot. Any live member, query failure, malformed result, or full/oversized
bounded snapshot preserves the original error value. Eight syscall-boundary
controls verify those negative cases, including `SRUN` with `P_WEXIT`.

The failing host snapshot contains `SRUN`, `P_WEXIT`, and `P_EXEC` after an earlier
KILL. These flags are not accepted as a death certificate. A snapshot is not an
atomic membership lock. Group departure, later group joins, credential changes,
and forks racing delivery prevent a universal descendant-containment guarantee.
Container/VM enforcement remains a separate host boundary.

Relevant primary sources:

- [Darwin group signaling](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sig.c)
- [Darwin process snapshots](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sysctl.c)
- [Darwin `waitid`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exit.c)
- [Darwin `killpg`](https://github.com/apple-oss-distributions/Libc/blob/main/compat-43/FreeBSD/killpg.c)
- [Linux `waitid`](https://man7.org/linux/man-pages/man2/waitid.2.html)

The implementation requires the Eio POSIX backend. It does not add handlers to
Eio's separate Linux io_uring backend. Linux host behavior remains unverified.
