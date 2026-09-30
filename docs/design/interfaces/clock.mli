module type PURE = sig
  type instant
  type sample = { monotonic : instant; wall : Utc.t }
  val compare : instant -> instant -> int
  (** Total order within one clock instance. *)

  val after : instant -> Milliseconds.t -> instant
  (** Exact time action: [after (after t a) b = after t (a+b)] for representable
      configuration sums. The instant carrier itself does not overflow. *)

  val elapsed : since:instant -> until:instant -> Seconds.t
  (** Nonnegative elapsed ticks; additive over ordered adjacent intervals. *)

  val wall_at : sample -> instant -> Utc.t option
  (** Display-only affine projection of a monotonic deadline onto current wall time.
      None means outside the supported RFC 3339 range; never controls scheduling. *)

end

module type S = sig
  module Pure : PURE
  type t
  val sample : t -> Pure.sample
  (** Explicit capability; monotonic observations never decrease. *)

  val sleep_until : t -> Pure.instant -> unit
  (** Cancelable in the caller's Eio switch. Cancellation may propagate;
      expected timer failures must be mapped by the runtime boundary. Translate
      exact deadlines into bounded native sleep chunks and recheck; never overflow
      finite Eio/Mtime representations on a large valid configuration interval. *)

end
