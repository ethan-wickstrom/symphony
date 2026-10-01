(** Owned directories beneath one checked Path brand. *)

module type S = sig
  module Contract : Workspace_manager.PURE

  type t
  type lease
  type origin = Created | Reused

  val with_lease :
    t ->
    Contract.reference ->
    (origin -> lease -> 'a) ->
    ('a, Workspace_manager.error) result
  (** Acquire under one persistent key lock. Preserve the callback value and
      frozen reference; release once on every callback exit, after all child
      loans close. Cancellation and defects propagate after release. *)

  val with_existing :
    t ->
    Contract.reference ->
    (lease option -> 'a) ->
    ('a, Workspace_manager.error) result
  (** Same ownership bracket without creation. Missing lookup preserves the
      filesystem; foreign or unowned entries fail before the callback. *)

  val reference : lease -> Contract.reference
  (** [reference lease] equals the checked reference supplied at acquisition.
      Settings and environment remain frozen throughout the lease. *)

  val path : lease -> (Contract.Path.t, Workspace_manager.error) result
  (** Released leases fail before IO; identity reads detect displaced leases
      before hook, launch or removal. A returned Path requires another lease
      check inside the native child bracket before launch; OCaml cannot express
      a linear OS lifetime. *)

  val remove : t -> lease -> (unit, Workspace_manager.error) result
  (** Revalidate after before_remove; delete through anchored directory handles,
      then clear ownership metadata under the same key lock. Keep lock files.
      Repeated successful missing cleanup preserves the filesystem projection.
      Final removal requires a protected parent and cooperating host: POSIX has
      no conditional inode-matching unlink/rmdir. *)
end
