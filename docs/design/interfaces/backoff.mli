val failure : attempt:Positive_count.t -> cap:Milliseconds.t -> Milliseconds.t
(** §8.4: min(cap,10000*2^(attempt-1)). Monotone in attempt/cap,
    saturates without overflow. No zero-attempt fallback. *)

val continuation : Milliseconds.t
(** §8.4 literal 1000 ms. Backoff is a bounded recurrence, not a monoid. *)
