(** Hard-coded protocol durations are checked once during initialization.
    @raise Invalid_argument only if one of those source constants is invalid. *)

val failure : attempt:Positive_count.t -> cap:Milliseconds.t -> Milliseconds.t
(** Section 8.4: [min(cap, 10000 * 2^(attempt - 1))]. Monotone in attempt and
    cap; saturated at cap without overflow. Work is bounded by the representable
    cap, regardless of the size of the attempt. No zero-attempt fallback. This
    bounded recurrence is not a monoid. *)

val continuation : Milliseconds.t
(** Section 8.4 literal 1000 ms. *)
