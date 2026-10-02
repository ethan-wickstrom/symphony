(** One persistent keyed collection of canonical owners. The retry order is
    derived from those payloads; no second map, queue or stored claim set
    exists. Space follows live bindings, without retired retry entries or claim
    history. *)

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
  (** Stable pure observations. Starting, active and stopping runs remain
      [Worker] until resource closure. Cleanup reserves a claim but no worker
      slot; waiting and refreshing retries retain their claim. *)
end

module Make
    (Clock : Clock.PURE)
    (Owner : OWNER with type instant = Clock.instant) : sig
  type t

  val empty : t
  (** [find i empty = None]; every derived ID set is empty and
      [next_retry empty = None]. *)

  val put : Owner.t -> t -> t
  (** Let [id o = Issue.id (Owner.issue o)]. [find (id o) (put o q) = Some o],
      even when retry rank is unchanged. Same-key writes are last-write:
      [put a (put b q) = put a q] when [id a = id b]. Distinct-key writes
      commute; [put o (put o q) = put o q]. Every other lookup is unchanged.
      Lifecycle fencing belongs to Core. *)

  val remove : Issue_id.t -> t -> t
  (** [remove i (remove i q) = remove i q]; absent removal is identity.
      Distinct-key removals commute; all other lookups are unchanged. *)

  val find : Issue_id.t -> t -> Owner.t option
  (** Reference model: a finite last-write function keyed by exact issue ID. *)

  val fold : (Issue_id.t -> Owner.t -> 'a -> 'a) -> t -> 'a -> 'a
  (** Fold each binding once. Agrees with a right fold over the reference list
      sorted by [Issue_id.Order]; [fold f empty z = z]. *)

  val running_ids : t -> Issue_id.Set.t
  (** Worker and cleanup IDs. Occupied slots project only Worker roles. *)

  val retry_ids : t -> Issue_id.Set.t
  (** Waiting and refreshing IDs. The closed role gives
      [running_ids q intersect retry_ids q = empty]. *)

  val claimed : t -> Issue_id.Set.t
  (** [claimed q = running_ids q union retry_ids q], exactly the binding keys.
      No independent claim state is stored. *)

  val next_retry : t -> (Issue_id.t * Retry_id.t * Clock.instant) option
  (** Reference model: filter waiting retries and choose the least (due, ID),
      with [Clock.compare] then [Issue_id.Order]. Peeking changes nothing.
      Refreshing removes the due rank while preserving the owner and claim. No
      waiting binding means None, even when other roles remain. *)
end
