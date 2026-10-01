# Live workspace composition

Store, native host, Process, hooks and the Driver adapter are implemented. The
existing manager remains policy.
Directory ownership and subprocess custody are separate lower ports. Their public
parent seals one Path brand before the agent/protocol layers are instantiated.

The actual public host is exercised separately from tests of private native
mechanisms. Agent/protocol composition remains interface evidence until slice 5.
Process custody has Linux/glibc and macOS evidence in vendor/eio/PATCHES.md;
musl/static linkage remains unverified.

## workspace_store.mli

```ocaml
module type S = sig
  module Contract : Workspace_manager.PURE
  type t
  type lease
  type origin = Created | Reused

  val with_lease :
    t -> Contract.reference ->
    (origin -> lease -> 'a) -> ('a, Workspace_manager.error) result
  (** Under one persistent key lock, acquire an owned directory and run the
      callback. Keep ownership until all child loans have closed. Every exit
      releases the lease once; cancellation propagates after release. *)

  val with_existing :
    t -> Contract.reference ->
    (lease option -> 'a) -> ('a, Workspace_manager.error) result
  (** Same lock/identity contract, without directory creation. Missing lookup
      preserves the filesystem. Foreign or unowned existing entries fail. *)

  val reference : lease -> Contract.reference
  (** Returns the frozen reference supplied to acquisition. No copied settings. *)

  val path : lease -> (Contract.Path.t, Workspace_manager.error) result
  (** Released/displaced leases fail. A returned Path cannot become launch
      authority without the native child bracket rechecking its lease. *)

  val remove : t -> lease -> (unit, Workspace_manager.error) result
  (** Revalidate after before_remove, delete through anchored directory FDs,
      then clear ownership metadata under the same key lock. Keep lock files.
      Successful repeated missing cleanup preserves the filesystem projection.
      Final name-based removal relies on the protected-parent/cooperating-host
      boundary: POSIX has no conditional inode-matching unlink/rmdir. *)
end
```

## workspace_hooks.mli

```ocaml
type outcome =
  | Completed of (unit, Workspace_manager.error) result
  | Cancelled

type event = Started | Finished of outcome

module type S = sig
  module Contract : Workspace_manager.PURE
  type t
  val run :
    t -> workspace:Contract.reference -> cwd:Contract.Path.t ->
    Workspace_settings.hook -> (unit, Workspace_manager.error) result
  (** No configured script is identity, including the event trace. Otherwise
      execute the frozen script/environment/timeout with bounded byte streams;
      emit Started then one Finished. Cancellation emits Finished Cancelled
      after child closure and then propagates with its original backtrace.
      Both stdout/stderr readers finish or reach their named drain bounds. *)
end

module Make
    (Contract : Workspace_manager.PURE)
    (Process : Agent_process.S with module Path = Contract.Path)
    (Clock : Clock.S) : sig
  include S with module Contract = Contract
  val create :
    process:Process.t -> clock:Clock.t ->
    emit:(Contract.reference -> Workspace_settings.hook -> event -> unit) -> t
end
```

Process is the sole trusted-shell module: executable /bin/bash plus argv
[| "/bin/bash"; "-lc"; script |]. Hook interpreters pass script separately from
checked Path and allowlisted Environment.child. They never build shell text from
issue data. Hooks are the same interpreter over live/fake process and clock ports.
The process bracket carries the caller's error type directly. Hooks map mechanism
diagnostics with `on_error`, while timeout, exit and stream failures remain ordinary
callback errors. Primary failure therefore outranks cleanup without a nested result
or cached callback outcome. The private Path loan uses the same error relationship.

## workspace_driver.mli

```ocaml
module Make
    (Store : Workspace_store.S)
    (Hooks : Workspace_hooks.S with module Contract = Store.Contract) : sig
  include Workspace_manager.DRIVER
    with module Contract = Store.Contract
     and type lease = Store.lease
     and type origin = Store.origin

  val create :
    store:Store.t -> hooks:Hooks.t ->
    report:(Workspace_manager.error -> unit) -> t
end
```

This adapter delegates directory operations to Store. hook obtains Store.path and
calls Hooks.run with Store.reference. cleanup_scope uses Eio.Switch.run_protected
to create a fresh protected caller scope. The frozen lease remains Held until
manager cleanup finishes. Three actual Eio tests verify delegation, child joining,
error reporting and cancellation/defect preservation; no manager policy is copied.

## workspace_host_posix.mli

```ocaml
module Make (Clock : Clock.S) : sig
  module Path : Workspace_path.S
  module Contract : Workspace_manager.PURE with module Path = Path
  module Process : Agent_process.S with module Path = Path
  module Workspace : Workspace_manager.S with module Contract = Contract

  type t
  val create :
    fs:Eio.Fs.dir_ty Eio.Path.t -> clock:Clock.t ->
    emit:(Contract.reference -> Workspace_settings.hook ->
          Workspace_hooks.event -> unit) ->
    report:(Workspace_manager.error -> unit) -> t

  val process : t -> Process.t
  val workspace : t -> Workspace.t
end
```

The Clock functor is real abstraction: native process grace/drain and hooks share
the injected clock instance. fs is an explicit Eio filesystem capability; no
module reads ambient cwd, environment, clock or filesystem authority.

The parent exports no descriptor, path constructor, revoke, signal or reap getter.
Native handle/store/process units remain private in the native library. The parent
implementation is assembly, not an implementation monolith:

```ocaml
module Path = Workspace_path_posix.Public
module Contract = Workspace_contract_posix
module Store = Workspace_store_posix
module Process = Workspace_process_posix.Make (Clock)
module Hooks = Workspace_hooks.Make (Contract) (Process) (Clock)
module Driver = Workspace_driver.Make (Store) (Hooks)
module Workspace = Workspace_manager.Make (Driver)
```

Contract is the single private application of Workspace_reference.Make(Path).
Store.Contract and Process.Path share this public brand by construction.

## Private native authority

Workspace_path_posix has a display-only Public module and a private child bracket.
The latter lends descriptor cwd only to the native process module and retains a
semantic lease loan through the entire child lifecycle, including closure.

- Held admits a loan and revalidates root/key entries against retained FDs.
- Closing rejects new loans, cancels and joins admitted child scopes.
- Released rejects every launch/hook/remove before filesystem effects.
- Key-lock release follows all admitted child scopes' closure.
- Loan scopes derive from the current caller, including fresh protected cleanup;
  they are not blindly attached to an already-cancelled preparation scope.

The private operation has the shape with_child : path -> (child scope -> cwd fd
-> result) -> result. Its descriptor/scope types never appear in the public parent.
One private Native_lifetime gate owns admitted scopes for both workspace and
process operations. A persistent Map tracks their completion promises. Closing
atomically revokes admission, cancels every scope, joins them, then publishes
Released. Pending reads/writes cannot retain pipes after process closure.

Callbacks return explicit results. Their value or captured exception/backtrace
stays outside Switch exception aggregation; a private failure marker cancels
children. Secondary release defects are reported independently. This avoids
guessing exception identity after Eio merges IO failures. Eio 1.6 does not retain
release-hook backtraces; secondary traces are forwarded as supplied, possibly
empty. The original primary trace is retained.

Raw Driver/remove operations remain private. A public process callback receives
only a Path, so it cannot close and join its own admitted scope. Concurrent public
cleanup instead acquires another lock and returns Busy.

Installed Eio 1.6 evidence: Fd.use delegates to Rcfd.use; Rcfd.use retains the FD
until its callback returns or raises (unix/rcfd.ml:166-175). Close marks Closing and
defers Unix.close while references remain (111-134). Fork_action.fchdir borrows
the FD around its continuation (fork_action.ml:36-39), and with_actions recursively
nests these borrows (12-18). Current Group.spawn waits for its producer inside that
continuation. This protects the descriptor during suspension; it does not by itself
keep a key lock held or close an escaped process.

Store acquisition protocol: anchored nofollow root/control/key handles; persistent
regular key lock plus identity check after flock; owner JSON read under that lock;
compare scope + opaque issue ID + original identifier + exact device/inode. Unknown
existing directories are never adopted. Same-filesystem case/literal/hash aliases
must contend for the same physical lock, not separate identifier-hash locks.
Metadata replacement is atomic under the lock, bounded before parsing, and leaves
no writable metadata/control directory inside the agent sandbox root.

The [filesystem mechanism](workspace-filesystem.md) reuses public Eio APIs for
directory handles and adds only nonblocking flock. Missing inspection creates no
metadata. Native open jobs remain inside the switch owning their descriptors.

## Cancellation client and build order

```ocaml
module Host = Workspace_host_posix.Make (Clock)
module Workspace = Host.Workspace
module Transport = App_server.Make (Host.Process) (Clock)
module Agent = Agent_runner.Make (Issue) (Workspace) (Transport)
```

Manager.run acquires a lease, calls before_run, then enters the agent callback.
If that callback is cancelled, its Process.with_process closes/reaps first.
Manager's after_run executes via cleanup_scope in a fresh protected caller scope.
Because Store has not begun Closing, this hook can acquire a new child loan even
though the original caller scope is cancelled. After after_run, Store begins
Closing, joins any escaped loans and finally releases the key lock. Preparation
failure follows the same after_run bracket, then Created-only before_remove/remove.

Build in this order:

1. Lower Store/Hooks signatures and the small Driver adapter; type-check an assembly
   witness with the existing manager and Path equality before representations.
2. Private native directory bindings and Path authority; nofollow acquisition,
   lock/root/entry identity, bounded owner IO, and guarded resource handoff.
3. Native Store and Process, including the semantic lease/child registration gate.
   Kernel waits run off the scheduler; asynchronous FD acquisition must transfer
   ownership safely even when cancellation wins before delivery.
4. Hooks over Process/Clock; manager over composed Driver; real cancellation,
   replacement, rollback, reused-directory and cleanup cases on each target host.
5. Fake host with one fake Path brand, fake Store map and lower fake byte/process
   port. Reuse the actual hook, manager and later app-server interpreters.
6. Workspace inspection CLI, parser fuzzing and conformance mapping after host
   evidence. No tracker slice before the complete workspace slice is merged green.
