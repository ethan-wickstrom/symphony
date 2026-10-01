# Native workspace filesystem boundary

Use Eio 1.6's public filesystem and descriptor APIs. The missing kernel operation
is a nonblocking exclusive `flock`; directory opening, anchored traversal, exact
identity, bounded IO and descriptor lifetime already have suitable APIs.

This is a mechanism sketch for the private native modules. The public Store,
Contract and display-only Path signatures remain unchanged. No production
filesystem code has been added.

## Acquiring directory authority

Start with the supplied Eio filesystem capability and the reference's frozen,
checked absolute root. `Eio.Path.open_in ~sw ~follow:false` can open a directory.
On the POSIX backend it uses read-only, nofollow flags, then returns a resource
backed by the managed descriptor. Obtain that same wrapper with
`Eio_unix.Resource.fd_opt`; an unsupported backend is an error value.

`fd_opt` borrows authority. It does not transfer ownership. Keep the resource and
its switch alive; do not call `Fd.remove`, duplicate ownership with another
wrapper, or turn the descriptor into an ambient pathname. Use
`Eio_posix.Low_level.fstat` to require a directory and retain its full-width
device/inode identity. Its public `Fd` directory capability then anchors further
`openat`, `fstatat`, `mkdir`, `rename`, `readdir` and `unlink` operations. Never use
`Low_level.Fs`, `Low_level.Cwd` or a private Eio module.

`follow:false` protects only the final path component. Open the root, control
directory, key directory and metadata leaves separately. Below the acquired root,
every open takes one checked component and nofollow; directory opens also require
the directory flag. No multi-component metadata path is handed to the resolver.

Evidence: [Path's follow contract](../../vendor/eio/lib_eio/path.mli),
[POSIX open_in](../../vendor/eio/lib_eio_posix/fs.ml),
[resource descriptor lookup](../../vendor/eio/lib_eio/unix/resource.ml), and
[public low-level operations](../../vendor/eio/lib_eio_posix/low_level.mli).

## Permanent key locks

The layout is:

```text
root/
  <actual Workspace_key>/       agent working directory
  @symphony/                   protected host control directory
    <actual Workspace_key>/
      lock                     permanent regular file
      owner                    bounded ownership record
```

`@` is outside the workspace-key alphabet. Using the actual key as its own
component preserves 255-byte keys and makes case, literal and hash aliases use
the filesystem's name equivalence. Control/key directories must remain on the
root filesystem with the same name semantics. Reject unsafe existing control
entries; creating a restrictive directory does not repair an unsafe existing
one. The protected parent and cooperating host are part of the ownership boundary.

Open `lock` read/write with create-if-missing and nofollow, require a regular file,
then acquire `LOCK_EX | LOCK_NB`. Contention is `Busy`; other host failures remain
error values. After acquisition, compare the opened file's identity with the
current lock entry before granting authority. Retain its managed descriptor for
the lease. Never unlink the lock file or its key directory, including after
workspace removal: replacing the lock inode could create two independent owners.

The smallest new private kernel interface is:

```ocaml
type status = Acquired | Busy
type error = Host of Unix.error | Worker_unavailable of string

val acquire : Eio_unix.Fd.t -> (status, error) result
(** Acquired locks belong to this open file description until its final close.
    Repeating acquisition on that description is idempotent. Separate opens of
    the same lock file cannot both acquire it. Busy grants no authority.
    Cancellation and defects propagate; only the scheduler's typed admission
    failure becomes Worker_unavailable. Worker callback defects are unchanged. *)
```

Implement one fixed-operation stub using `<sys/file.h>`, called inside
`Fd.use_exn`. A system-thread call keeps host latency off the scheduler. It must
retain the descriptor through the whole syscall and preserve errno before any
runtime reentry. No explicit unlock is needed: close after all loans have joined.

`Unix.lockf` is unsuitable: process-associated locks do not exclude another fiber
in the same process, and closing another descriptor for that file can release the
lock. `flock` uses independent open file descriptions and also excludes another
open in the same process. See the [Linux flock manual](https://man7.org/linux/man-pages/man2/flock.2.html),
[Apple flock manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html),
and [lockf manual](https://man7.org/linux/man-pages/man3/lockf.3.html).

## Missing lookup preserves the filesystem

Preparation may create the root, control/key directories and persistent lock.
Inspection must not create them. If protected metadata or its lock is absent,
observe the workspace entry without creating metadata. A missing workspace calls
the callback with `None`; an existing workspace is rejected as unowned. Existing
persistent locks are acquired and revalidated normally.

A competing creation after a missing observation grants no deletion authority.
This preserves the literal missing-lookup contract; it does not promise an
unchanging external filesystem after the observation.

## Exact ownership and metadata publication

Under the key lock, open the workspace directory with nofollow and inspect the
opened descriptor. Read at most `Workspace_owner.max_bytes + 1` bytes from a
regular owner file; reject the extra byte before parsing. Successful reuse
requires equality of tracker scope, opaque issue ID, original identifier, device
and inode. Neither key equality nor a pathname grants ownership. Compare the
full int64 identity bits from Low_level; do not narrow through OCaml `int` or
derive identity from timestamps.

Publish canonical owner bytes through a temporary regular file in the protected
key directory, then atomically rename under the lock. A partial write never
replaces the last complete record. Handle write/publication failure as a value;
never reinterpret an unknown existing directory as a newly owned one. This
protocol makes no untested crash-durability claim.

The private directory mechanism needs only abstract root, key-guard and directory
handles, identity observations, and operations for root/key brackets, existing
lookup, creation, owner read/replacement, revalidation, child cwd lending and
removal. Checked keys and fixed metadata names select entries; expose no arbitrary
relative-path operation or raw descriptor getter. Store supplies ownership policy.
Owner clearing belongs to successful removal, not an independently callable
public operation.

## Cancellation and child ownership

Eio owns every opened descriptor through a switch. Low_level opens are nonblocking
and close-on-exec. `Fd.use` retains a descriptor across suspension. Keep native
open jobs inside the switch that receives their descriptors, so that switch cannot
finish before the suspended job returns and registers its descriptor.

Do not rely on finished-switch registration to recover a raw descriptor inside a
native worker: that branch invokes `Cancel.protect`, which requires an Eio fiber
context. Ordinary cancellation of the owning scope is safe because scope closure
joins its fibers first. Neither raw descriptor transfer nor a separate
close-on-cancellation path is needed with this ownership ordering. Check
cancellation before granting the Store callback after acquisition. Catch expected
host failures around the operation that produced them, not around the callback.

A descriptor reference is not a semantic lease. `Workspace_path_posix` owns the
Held/Closing/Released lifecycle and admitted child scopes. Its private child
bracket revalidates root/key entries against retained identities, then lends cwd
only to the native process module through launch, process closure and reap. A
Closing lease rejects new loans, cancels and joins existing loans, then closes
directory handles and the key-lock descriptor. Released paths grant no effect.
Cleanup hooks obtain fresh protected caller scopes while the lease is still Held.

Release must preserve the callback value, cancellation or original defect after
cleanup. Observe expected release failures through the supplied reporter; a
switch release exception must not silently replace the primary outcome. Never
retry a numeric descriptor close after an ambiguous close error.

Evidence: [managed FD contract](../../vendor/eio/lib_eio/unix/fd.mli),
[reference-counted lifetime](../../vendor/eio/lib_eio/unix/rcfd.ml),
[finished-switch registration](../../vendor/eio/lib_eio/core/switch.ml), and
[semantic child ownership](workspace-live.md).

## Anchored removal and its limit

After `before_remove`, revalidate the lease, owner record and root/key identity.
Traverse through retained directory descriptors. Open each directory child with
directory plus nofollow flags; unlink file/symlink leaves relative to their parent.
Do not use `Eio.Path.rmtree` on the display path: its pathname lookup does not
establish the Store's owner identity.

Keep the owner record after partial failure. Clear it only after successful
workspace removal, under the same persistent key lock. A missing target never
authorizes removing a replacement entry.

POSIX has no inode-conditional `unlinkat`/`rmdir`. The final name operation still
depends on the protected parent and cooperating host after revalidation. Directory
FDs prevent symlink traversal and descriptor reuse; they cannot make an external
rename race unrepresentable. Stronger same-user isolation remains a separate host
extension.

## Behavioral gates before implementation acceptance

- Separate opens in one process and a second process contend for the same lock;
  cancellation releases it after all child loans close.
- Reject symlinked root/control/key/lock/owner entries and displaced identities.
- Case and literal/hash aliases serialize; full-length keys create valid metadata.
- Missing inspection creates no root, control directory, key directory or lock.
- Foreign scope/ID/identifier and exact identity mismatches prevent callbacks.
- Oversized, duplicate-field and truncated owner records fail closed.
- Publication and partial removal faults preserve usable ownership information.
- A child loan survives suspension, blocks lease release until process closure,
  and cannot be reused after Closing or Released.

Run these on macOS and the Linux static-release host. Unsupported filesystems or
lock semantics are errors, not a fallback to weaker locking.
