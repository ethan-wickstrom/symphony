(** One canonical owner map plus an encapsulated priority index containing IDs only.
    The index is a container representation, never an independently mutable cache. *)

module type OWNER = sig
  type t
  type instant
  type role =
    | Worker
    | Cleanup
    | Retry_waiting of Retry_id.t * instant
    | Retry_refreshing of Retry_id.t
  val issue : t -> Issue.t
  val role : t -> role
  (** Starting, active and stopping runs remain Worker until Agent.completed attests
      resource closure. Complete/cleanup-only owners use Cleanup and reserve no slot.
      Stopping is not a capacity release; retry wait/refresh both retain a claim. *)

end

module Make
    (Clock : Clock.PURE)
    (Owner : OWNER with type instant = Clock.instant) : sig
  type t
  val empty : t
  val put : Owner.t -> t -> t
  (** Last-write map law: put a (put b m) = put a m for the same issue ID.
      Different IDs commute. Priority index equals the waiting-retry map projection. *)

  val remove : Issue_id.t -> t -> t
  (** Idempotent; absent removal is identity. Different-ID removals commute. *)

  val find : Issue_id.t -> t -> Owner.t option
  val fold : (Issue_id.t -> Owner.t -> 'a -> 'a) -> t -> 'a -> 'a
  val running_ids : t -> Issue_id.Set.t
  (** Includes draining/cleanup ownership; actual occupied worker slots are derived
      from Worker roles. Cleanup does not reserve a concurrency slot. *)

  val retry_ids : t -> Issue_id.Set.t
  val claimed : t -> Issue_id.Set.t
  (** running_ids union retry_ids; their intersection is empty by closed owner role. *)

  val next_retry : t -> (Issue_id.t * Retry_id.t * Clock.instant) option
  (** List model: project waiting retries and sort by due, then issue ID. Peeking
      never drops ownership. Refreshing removes only the priority-index entry;
      the retry remains owned until the refresh result decides its next transition. *)

end
