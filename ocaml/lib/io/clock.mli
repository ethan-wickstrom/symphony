(** Exact time algebra and the effectful clock port. *)

module type PURE = sig
  type instant
  type sample = { monotonic : instant; wall : Utc.t }

  val compare : instant -> instant -> int
  (** Total order within one clock instance. *)

  val after : instant -> Milliseconds.t -> instant
  (** Exact action: [after t zero = t] and [after (after t a) b = after t (a+b)]
      for representable configuration sums. The instant carrier itself never
      overflows. *)

  val elapsed : since:instant -> until:instant -> Seconds.t
  (** Nonnegative elapsed ticks; additive over ordered adjacent intervals. An
      earlier until value yields zero. *)

  val wall_at : sample -> instant -> Utc.t option
  (** Display-only affine POSIX projection. The sample's own instant projects to
      its wall value; None means outside the supported RFC 3339 range. Wall
      values never control scheduling. *)
end

module type S = sig
  module Pure : PURE

  type t

  val now : t -> (Pure.instant, Diagnostic.t) result
  (** Read only monotonic authority; valid observations never decrease. A
      wall-clock failure cannot prevent deadline checks or cleanup timers. Eio
      cancellation and unexpected source defects may propagate. *)

  val sample : t -> (Pure.sample, Diagnostic.t) result
  (** Pair a monotonic observation with a checked wall value. Expected clock
      source failures are diagnostics; never replace an invalid wall sample. Eio
      cancellation and unexpected source defects may propagate. *)

  val sleep_until : t -> Pure.instant -> (unit, Diagnostic.t) result
  (** Cancelable in the caller's Eio context. Ok means a monotonic observation
      reached the fixed exact deadline. Recheck after bounded native sleeps;
      never overflow, saturate or accumulate floating-point deltas. Native
      horizon/source/timer failures are diagnostics. Eio cancellation propagates
      with cleanup; unexpected exceptions are defects and may propagate. *)
end

module Pure : sig
  include PURE

  val of_nanoseconds : Count.t -> instant
  (** Checked native/simulator ticks, preserving their exact nonnegative value.
  *)

  val nanoseconds : instant -> Count.t
  (** [nanoseconds (of_nanoseconds n) = n]. This numerical projection grants no
      OS clock capability; instants remain distinct from counts and durations.
  *)
end
