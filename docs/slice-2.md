# Slice 2: owned workspaces and hooks

Status: native owned workspaces, hooks, process custody and non-creating
inspection are implemented. Independent models and complete native gates
pass normally and optimized on macOS and Linux/glibc at `b30263e`; the complete service
and Linux musl/static release remain later slices.
Slice 1 is merged at
`f56a66c`.

## Contracts and intentional equalities

[Workspace keys](../ocaml/lib/domain/workspace_key.mli) are checked ASCII directory
components. [References](design/interfaces/workspace_reference.mli) freeze settings,
scope, opaque issue ID, original identifier and sanitized child environment. The
[manager](design/interfaces/workspace_manager.mli) acquires live leases; the
[process driver](design/interfaces/agent_process.mli) accepts only their path type.

```ocaml
Agent.Contract.workspace = Workspace.Contract.reference
Agent.Contract.Path = Workspace.Contract.Path
Transport.Path = Workspace.Contract.Path
Agent_process.Path = Workspace.Contract.Path
```

These relationships precede implementation. The concrete POSIX directory driver
owns Path.t and its descriptor, identity and lifetime. Public display text cannot
be promoted into launch authority. Pure references contain no live directory.

The acquisition algebra distinguishes Created from Reused. Only Created runs
after_create and permits preparation rollback. with_existing never creates;
cleanup runs before_remove and deletion under that same lease. Retain lock files
after deletion so an old and a new lock cannot protect the same key independently.

## Models and laws

- Key model: list-of-bytes sanitization, candidate assembly and exact length/dot
  predicate. Unchanged safe identifiers preserve bytes; changed identifiers append
  the first 128 SHA-256 bits in lowercase hex. No truncation. Independent Python
  hashlib golden outputs verify the hash/encoding; sampled properties are not a
  proof of cryptographic collision resistance.
  The portable profile must name byte-wise replacement explicitly: UTF-8 é
  becomes two underscores before the suffix. The spec says character without
  defining an encoding unit. Proposed wording: "On the POSIX UTF-8 profile,
  replace each disallowed byte; implementations using Unicode scalar replacement
  must publish that choice and test fixtures rather than assume identical keys."
- Filesystem model: entry-to-directory identity map plus an ownership map. Reject
  foreign ownership, symlink/non-directory entries, case aliases and literal/hash
  aliases before hooks. Missing cleanup is an identity operation. After successful
  removal without recreation, another cleanup preserves the filesystem projection
  and returns success; hook/log traces differ. Delayed commands require owner fencing
  before effects, since a recreated directory is a new generation.
- Lease model: acquisition adds one resource; every callback exit releases it
  exactly once. A stale handle cannot launch, hook or delete a replacement.
- Hook model: trace of after_create (Created only), before_run, attempt, after_run,
  then optional before_remove/deletion. Preparation failure rolls back only Created.
  after_run and before_remove errors are observations and preserve the primary error.
- Process model: argv and descriptor cwd are separate from trusted script text.
  Exit observation is stable; group identity survives leader exit until cleanup;
  release sends KILL before exactly-once direct-child reap. Released handles never
  signal a recycled group. Streams and TERM/KILL grace/drain waits have named bounds.

after_run is armed once a directory is acquired and runs once after failures,
timeouts and cancellation, including failed before_run. §5.3.4 requires it after
every attempt; §16.5's early before_run return omits it. Follow the normative
contract and propose adding after_run to that return in the pseudocode.
Cancellation cleanup runs in a fresh bounded scope; the original cancellation
propagates afterward. Existing attempts retain their frozen hooks/environment.

## Mechanism gaps and boundaries

Eio 1.6's POSIX process implementation immediately reaps a leader. Its protected
positive-PID signaling does not protect a later raw negative-PGID signal. Such a
check-then-signal race can target a recycled process group. Use a small pinned
Eio_posix Group extension: abstract handle, closed exit/signal types, exit observed
without reaping, and switch-owned KILL-before-reap with private custody. Only the
short authority transition holds the mutex; kernel waits run outside it. Reuse
the library's C fork actions; never execute OCaml between fork and exec. Group.spawn
takes descriptor cwd, stdin/stdout/stderr, executable, argv and environment;
it constructs the fixed action sequence itself. An arbitrary action list could
otherwise change group/session membership before exec and break custody.

Use explicit Eio_posix.run on macOS and Linux: those low-level effects cannot run
under Eio_main's Linux backend. Descriptor cwd uses the existing fchdir action.
Record the source delta/provenance and the failing old-API reproducer with the pin.

The old API counterexample was reproduced on macOS: after the leader exited and
was reaped, protected positive-PID KILL left its TERM-ignoring descendant alive.
No unsafe attempt to force OS identifier reuse was made. Both Eio packages are
now pinned to the [reviewed source](../vendor/eio/PATCHES.md). The frozen macOS
gate passed 15,000 cases plus cancellation, concurrent close, permission/reap
errors, signal normalization and failed-exec cleanup controls. Exact-source
normal/optimized worker-admission tests preserve finalizers, original backtraces
and defect categories; rejected admission forks no child and leaves the same
switch usable. One reserved native worker observes and reaps; cleanup allocates
no new worker. Independent custody review passed. Hosted Linux/glibc and macOS evidence is
recorded in vendor/eio/PATCHES.md; all nine frozen hashes matched.

Darwin's zombie-only process group can report EPERM for a group signal. Modern
killpg has the same behavior; its legacy variant also hides live permission
failures and is unsuitable. Accept that EPERM only if a confined process-group
snapshot proves there is no live member; query failure or any live member retains
the permission error. Keep custody until this check and direct-child reap finish.

POSIX provides no finite bound for actual exit/reaping after SIGKILL. Reap direct
children only; pipe EOF does not prove group emptiness. A descendant that changes
groups/credentials requires stronger host isolation. These are kernel/host limits,
not guarantees that a test or OCaml type can establish.

Root identity, ownership metadata and lease lifetime remain hidden in one driver.
The root's control directory is @symphony, outside the allowed workspace-key
alphabet, with restricted host permissions. Locks/metadata are outside the issue's
Codex writable root. OS mutation and non-linear callback values require identity
and lifetime checks there; OCaml cannot encode exclusive external filesystem
authority. Protected parent/control directories and a cooperating host are the
ownership boundary; stronger same-user containment is a later isolation extension.

## Build order and checks

[Live composition](design/workspace-live.md) separates Store, hook interpreter and
process ports under one sealed Path brand. Private child loans retain semantic
ownership through process closure; FD reference counting alone cannot do that.
Fresh protected cleanup scopes run before the lease enters Closing. Store/Hooks
port signatures and Driver delegation are implemented; three actual Eio tests
cover path rejection, protected after_run child joining/reporting and original
cancellation/defect propagation. The broader agent assembly type-checks on 5.5;
native registration and public-host tests now exercise real resources.

1. Checked keys and independent model/golden vectors.
2. Frozen reference and refined manager signatures, type-checked with shared paths.
3. Safe POSIX group lifetime and acquired-descriptor cwd host prototype.
4. Directory/ownership/locking driver, then policy manager over it and its fake.
5. Hooks, workspace inspection command, cancellation/rollback/cleanup host cases.
6. Every new parser/byte boundary gets a Crowbar target; update Section 17.2 and
   CONFORMANCE.md only after actual passes. Green Linux/macOS CI and review precede
   merge and tracker work.

The current core suite passes 126 tests and 41,500 model/law samples;
the 15-group seed `20260930` campaign passes 150,000 invocations. The key module's
13 independent hash vectors, length/alias examples and four properties are included.
Reference/policy models compare complete fake-driver traces, primary outcomes,
directory presence and release multiplicity;
sequence properties retain one driver across operations. A same-diagnostic,
changed-error-variant control failed before the oracle was corrected.
The source gate checks 178 source/interface files; 27 CLI scenarios pass normally and
optimized, 34 source and 16 corruption controls. Revised 56 blueprints plus an
assembly witness type-check on 5.5 after temporary doc normalization. Those
interface/model results are distinct from the native cases below.

## Ownership record boundary

The spec requires identifiers to be unique within a tracker scope (§4.1.1), but
does not promise permanent identifier-to-ID binding. Frozen references now retain
the opaque issue ID. Reuse compares scope, ID and original identifier, plus the
acquired directory's device/inode; key equality alone grants no ownership.

[Workspace_owner](../ocaml/lib/workspace/workspace_owner.mli) defines the protected
record format: exactly six JSON fields, version token `1`, checked scope/ID/
identifier, and device/inode as 16 lowercase hex digits preserving all int64 bits.
Its 16,384-byte limit accommodates the Linear identity profile while bounding
corrupted-file reads. The format stores no key, path or credential. Canonical
encoding roundtrips; equality is componentwise. The independent model observes
strings and validates structured JSON without calling the owner parser.

Place per-key lock and owner entries under `@symphony` in the same filesystem
namespace as workspace keys, preserving case aliases and 255-byte key support.
Never unlink persistent lock files. Check opened lock identity after acquisition,
read metadata only while holding the lock, and reject unknown existing directories.
Clear ownership after successful removal under that lock. POSIX cannot atomically
remove only an inode-matching name; final name-based removal relies on the protected
parent/cooperating-host boundary and revalidates identity after before_remove.


## Native integration

`Workspace_host_posix.Make(Clock)` seals one Path brand shared by Contract,
Workspace and Process. The public host exports Workspace policy; raw Store,
lease/remove and descriptor authority remain private. Public callbacks therefore
cannot join their own admitted scope. Inspection returns only a display label.

The native kernel target compiles copies of the exact private production files;
a separate target exercises the actual public library. This tests private
mechanisms without exporting their constructors or relying on hidden CMI paths.
The focused groups pass: Directory17, Store11, Process8, lifetime7, IO classifier4,
and public Host7. The lifetime group runs 1,000 replayable Eio mock seeds; an
explicit seed619 replay also passes. Whole-service simulation remains slice4.

Retained failing regressions cover unpublished-directory leakage, escaped pending
pipe reads, primary failure aggregation, dropped secondary IO errors, cleanup
faults masking removal and worker defects becoming expected errors. The fixes
change representations or one hidden boundary: fresh-directory capability,
shared scope ownership, separate primary result, retired physical outcome and
one native expected-error classifier. Secondary release traces may be empty under
Eio1.6; primary traces retain their original frames.

Real CLI tests independently construct the published metadata profile. They check
missing/owned/busy/foreign/symlinked entries, no hook invocation, unchanged
filesystem projection, redaction and terminal-control escaping.

Native executables run under a 90s watchdog. Logs and manifests record platform,
source hashes, executed binary hashes and outcomes; this identifies artifacts,
not a source-to-binary attestation. Complete normal/optimized runs pass 50 kernel
and seven public-host cases. Timeout, interruption, admission and normal-exit
controls retain the group through KILL-before-reap. The exec wrapper retains one
live sentinel until final KILL, avoiding Darwin's zombie-only EPERM without
normalizing a possible permission failure. The wrapper is hashed in each manifest.
Eight real watchdog scenarios cover timeout, INT/TERM, launch admission, leftover
descendants, an empty exiting group and native signal dispositions. The latter
failed before resetting Python's ignored pipe/file-size signals before exec.
Bootstrap isolation ignores Python environment/site customization. Exec retains
the target PID; no wait-status protocol or build attestation is introduced.

Review exposed a nested-result bug: successful process callbacks could contain
failed hooks, allowing cleanup to replace timeout, exit and stream outcomes.
Four failing/passing hook controls and three native regressions now check primary
precedence, typed error identity, mapper suppression and conversion after reap.
Process and private Path brackets carry the callback's error type directly;
mechanism errors use an explicit mapper only when they determine the outcome.

Hosted [PR run 36840015440](https://github.com/ethan-wickstrom/symphony/actions/runs/36840015440)
and [push run 36840011609](https://github.com/ethan-wickstrom/symphony/actions/runs/36840011609)
passed at `b30263e00705d06a1118229d4aaf99c68ce6adab`. All four native manifests
match 56 selected committed sources and both runner/helper hashes, with optimization
levels 0/1. The two custody manifests match all nine frozen Eio source hashes;
each passed 5,000 scenarios and 2,000 normal closures. Repeated-signal permission
errors remain visible (Linux 0, macOS 8); cleanup permission errors were zero.
