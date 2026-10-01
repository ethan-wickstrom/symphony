(** Hook policy over scoped directory and process capabilities. *)

type error =
  | Invalid_key of Diagnostic.t
  | Unsafe_path of Diagnostic.t
  | Ownership_conflict of Diagnostic.t
  | Filesystem_error of Diagnostic.t
  | Hook_failed of Diagnostic.t
  | Hook_timeout of Diagnostic.t

module type PURE = sig
  module Path : Workspace_path.S

  type reference

  val reference :
    settings:Workspace_settings.t ->
    env:Environment.child ->
    scope:Tracker_scope.t ->
    identifier:Issue_identifier.t ->
    (reference, error) result
  (** Freeze settings and identity. Constructing a reference never acquires a
      path. *)

  val identifier : reference -> Issue_identifier.t
  val scope : reference -> Tracker_scope.t
  val environment : reference -> Environment.child
  val key : reference -> Workspace_key.t

  val settings : reference -> Workspace_settings.t
  (** Accessors preserve the checked constructor inputs. The key agrees with
      [Workspace_key.of_identifier]. *)

  type cleanup = { request_id : Request_id.t; workspace : reference }
end

module type DRIVER = sig
  module Contract : PURE

  type t
  type lease
  type origin = Created | Reused

  val with_lease :
    t -> Contract.reference -> (origin -> lease -> 'a) -> ('a, error) result
  (** Serialize acquisition and release once on every callback exit. Only
      Created permits after_create and preparation rollback. Preserve the
      callback value; cancellation and defects propagate after release. *)

  val with_existing :
    t -> Contract.reference -> (lease option -> 'a) -> ('a, error) result
  (** Non-creating lookup under the ownership lock. Absence leaves the
      filesystem unchanged. Identity/ownership conflicts fail before the
      callback. *)

  val path : lease -> (Contract.Path.t, error) result
  (** A released or displaced lease returns Error without filesystem effects.
      OCaml cannot encode a linear OS lifetime: the driver checks before
      returning this capability, and each later path effect revalidates it. *)

  val hook : t -> lease -> Workspace_settings.hook -> (unit, error) result
  (** Execute the frozen trusted script with bounded output/time and sanitized
      environment. Absence of the hook is the identity operation. *)

  val remove : t -> lease -> (unit, error) result
  (** Revalidate identity and delete under the same lease as before_remove. A
      stale lease never touches a replacement. Keep the lock file to prevent
      inode ABA. *)

  val cleanup_scope : t -> (unit -> 'a) -> 'a
  (** Shield outer cancellation and provide a fresh scope for bounded hooks,
      then release that scope. It cannot promise a finite POSIX child-reap
      duration. *)

  val report : t -> error -> unit
  (** Observe ignored cleanup failures. Expected logging failures do not raise;
      defects may propagate. Reporting never changes the primary result. *)
end

module type S = sig
  module Contract : PURE

  type t

  val with_workspace :
    t ->
    Contract.reference ->
    (Contract.Path.t -> ('a, error) result) ->
    ('a, error) result
  (** Created: after_create, before_run, callback, after_run. Reused omits
      after_create. Preparation failure skips callback and rolls back only
      Created, after after_run and before_remove. Callback failure preserves the
      workspace. after_run occurs once after any acquired attempt, including
      cancellation. Ignored hook/rollback failures preserve the primary error.
      Driver cancellation and defects propagate with cleanup; no expected error
      escapes as an exception. *)

  val cleanup : t -> Contract.cleanup -> (unit, error) result
  (** Missing cleanup is identity. before_remove failure is reported, then
      deletion proceeds under the same lease. After successful removal with no
      recreation, another cleanup returns Ok and preserves the resulting
      filesystem projection; hook/log traces are not equal. Failed cleanup has
      no idempotence guarantee. Owner fencing must reject delayed cleanup before
      effects. *)
end

module Make (Driver : DRIVER) :
  S with module Contract = Driver.Contract and type t = Driver.t
