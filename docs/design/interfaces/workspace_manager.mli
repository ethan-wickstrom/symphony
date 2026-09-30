(** Section 3.1 component. References are frozen work identities; paths are live IO
    capabilities. Protocol-returned cwd strings cannot manufacture either. *)

type error =
  | Invalid_key of Diagnostic.t
  | Unsafe_path of Diagnostic.t
  | Ownership_conflict of Diagnostic.t
  | Filesystem_error of Diagnostic.t
  | Hook_failed of Diagnostic.t
  | Hook_timeout of Diagnostic.t

module type PURE = sig
  module Issue : Issue.S
  module Path : Workspace_path.S
  type reference
  val reference : settings:Workspace_settings.t -> env:Environment.child ->
    scope:Tracker_scope.t -> identifier:Issue_identifier.t -> (reference, error) result
  (** Freeze root, hooks, environment and ownership. Physical safety is acquired later. *)

  val identifier : reference -> Issue_identifier.t
  val scope : reference -> Tracker_scope.t
  val environment : reference -> Environment.child
  val key : reference -> Workspace_key.t
  val settings : reference -> Workspace_settings.t
  (** Read the frozen inputs; drivers never reread current configuration.
      key(reference s e scope id) agrees with Workspace_key.of_identifier id. *)
  type cleanup = { request_id : Request_id.t; workspace : reference }
end

module type DRIVER = sig
  module Contract : PURE with type Issue.t = Issue.t
  type t
  type lease
  type origin = Created | Reused
  val with_lease : t -> Contract.reference -> (origin -> lease -> 'a) ->
    ('a, error) result
  (** Acquire/create exactly once. Only Created permits after_create or preparation
      rollback. The callback may return its own result type; the driver does not
      change that result or swallow cancellation/defects. *)
  val with_existing : t -> Contract.reference -> (lease option -> 'a) ->
    ('a, error) result
  (** Lookup under the same ownership lock; absence is None and never creates a
      directory. In a stable filesystem, repeated absent lookup leaves it unchanged.
      Caller scope owns both brackets. Serialize under the ownership lock; atomically
      acquire the directory without following a symlink. Metadata binds original
      identifier/scope. Lock, mkdir, metadata and open are not one OS transaction.
      Release on normal, error and cancellation paths. Released handles reject use:
      OCaml cannot prevent a callback from retaining a non-linear value. *)

  val path : lease -> Contract.Path.t
  val hook : t -> lease -> Workspace_settings.hook -> (unit, error) result
  (** Trusted bash -lc script; bounded output/time; reference's immutable environment. *)

  val remove : t -> lease -> (unit, error) result
  (** Delete only through the lease that ran before_remove; do not unlock/reacquire.
      Revalidate identity/containment. Successful removal makes subsequent existing
      lookup absent. Stale leases fail without touching a replacement directory.
      The lock file survives removal, preventing lock-inode ABA. *)

end

module type S = sig
  module Contract : PURE with type Issue.t = Issue.t
  type t
  val with_workspace : t -> Contract.reference ->
    (Contract.Path.t -> ('a, error) result) -> ('a, error) result
  (** Serialize workspace use; release on every exit. Hooks retain §9.4 behavior.
      after_run gets a bounded fresh cleanup scope after cancellation. Host cancellation
      propagates after cleanup. No launcher may use an escaped/released Path.t. *)

  val cleanup : t -> Contract.cleanup -> (unit, error) result
  (** Non-creating lookup, before_remove and deletion share one lease. Repeated
      cleanup is idempotent in a stable filesystem; a delayed stale command must
      also be fenced by the owner before any effect, not merely at its reply. *)
end

module Make (Driver : DRIVER) :
  S with module Contract = Driver.Contract and type t = Driver.t
