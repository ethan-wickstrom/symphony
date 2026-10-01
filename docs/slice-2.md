# Slice 2: owned workspaces and hooks

Status: keys, references, ownership codec and hook policy tested against
independent models; protected Driver composition and macOS process custody pass.
Directory ownership/live hooks remain pending. No workspace containment claim.
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
no new worker. Independent custody review passed. Linux host evidence is pending.

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
native registration remains work.

1. Checked keys and independent model/golden vectors.
2. Frozen reference and refined manager signatures, type-checked with shared paths.
3. Safe POSIX group lifetime and acquired-descriptor cwd host prototype.
4. Directory/ownership/locking driver, then policy manager over it and its fake.
5. Hooks, workspace inspection command, cancellation/rollback/cleanup host cases.
6. Every new parser/byte boundary gets a Crowbar target; update Section 17.2 and
   CONFORMANCE.md only after actual passes. Green Linux/macOS CI and review precede
   merge and tracker work.

The current full local check passes 99 tests and 29,500 model/law cases;
the 15-group seed `20260930` campaign passes 150,000 invocations. The key module's
13 independent hash vectors, length/alias examples and four properties are included.
Reference/policy models compare complete fake-driver traces, primary outcomes,
directory presence and release multiplicity;
sequence properties retain one driver across operations. A same-diagnostic,
changed-error-variant control failed before the oracle was corrected.
The full check passes with 128 paired source files, 19 CLI scenarios normally and
optimized, 34 source and 16 corruption controls. Revised 56 blueprints plus an
assembly witness type-check on 5.5 after temporary doc normalization. No physical
directory/lock/hook behavior is established by those tests.

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
