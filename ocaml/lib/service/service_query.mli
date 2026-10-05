(** Private, single-domain request mailbox. Replies grant no owner authority. *)

module Make (Clock : Clock.S) : sig
  type t
  type 'a reply

  type request =
    | Snapshot of Snapshot.t reply
    | Refresh of Status_source.refresh reply

  module Source : Status_source.S with type t = t

  val create :
    clock:Clock.t -> changed:Eio.Condition.t -> timeout:Milliseconds.t -> t

  val activate : t -> bool
  (** Exactly one Dormant-to-Active transition. Closed never reopens. *)

  val close : t -> unit
  (** Non-suspending closure wakes accepted and admission-waiting requests. *)

  val take : t -> request option
  (** Owner-only FIFO receipt. A received request still occupies its credit. *)

  val pending : 'a reply -> bool
  (** Recheck after a suspending port before admitting scheduling work. *)

  val reply : t -> 'a reply -> ('a, Status_source.unavailable) result -> unit
  (** Non-suspending at-most-once publication. Abandoned replies are inert. *)
end
