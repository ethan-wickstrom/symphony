(** Independent last-write list oracle; no production queue operations. *)

module Make
    (Clock : Clock.PURE)
    (Owner : Ownership.OWNER with type instant = Clock.instant) : sig
  type t

  val empty : t
  val put : Owner.t -> t -> t
  val remove : Issue_id.t -> t -> t
  val find : Issue_id.t -> t -> Owner.t option

  val bindings : t -> (Issue_id.t * Owner.t) list
  (** Unique bindings in exact issue-ID order, obtained by a list sort. *)

  val running_ids : t -> Issue_id.Set.t
  val retry_ids : t -> Issue_id.Set.t
  val claimed : t -> Issue_id.Set.t

  val next_retry : t -> (Issue_id.t * Retry_id.t * Clock.instant) option
  (** Filter the list, then sort waiting retries by due and ID. *)
end
