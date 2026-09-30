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
  type cleanup = { request_id : Request_id.t; workspace : reference }
end

module type DRIVER = sig
  module Contract : PURE with type Issue.t = Issue.t
  type t
  type lease
  val with_lease : t -> Contract.reference -> (lease -> ('a, error) result) ->
    ('a, error) result
  (** Caller scope owns the bracket. Serialize under the ownership lock; atomically
      acquire the directory without following a symlink. Metadata binds original
      identifier/scope. Lock, mkdir, metadata and open are not one OS transaction.
      Release on normal, error and cancellation paths. Released handles reject use:
      OCaml cannot prevent a callback from retaining a non-linear value. *)

  val path : lease -> Contract.Path.t
  val hook : t -> lease -> Workspace_settings.hook -> (unit, error) result
  (** Trusted bash -lc script; bounded output/time; reference's immutable environment. *)

  val remove : t -> Contract.cleanup -> (unit, error) result
  (** Absent directory succeeds. Verify ownership/containment before removal.
      Successful repetition is idempotent. Failed IO need not be idempotent. *)

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
end

module Make (Driver : DRIVER) :
  S with module Contract = Driver.Contract and type t = Driver.t
