(** Bounded benchmark observations, with exact nanosecond and byte units. *)

type memory = {
  live_heap_bytes : Count.t;
  fiber_stack_bytes : Count.t;
  reserved_heap_bytes : Count.t;
  allocated_bytes : Count.t;
}

val of_stat : Gc.stat -> (memory, Diagnostic.t) result
(** Pure decoder for program-wide OCaml counters. Reject negative word counts,
    inconsistent promotion totals, and nonfinite, negative, nonintegral or
    >=2^53 allocation counters. Convert each counter before integer arithmetic.
    Stack bytes include stack metadata and cached fragments. *)

val snapshot : unit -> (memory, Diagnostic.t) result
(** [Gc.stat] performs a full major collection. Call outside timed sections;
    these managed-memory observations do not measure resident memory. *)

type samples
type added = Added of samples | Full of samples

val make : limit:Positive_count.t -> samples
val count : samples -> Count.t

val add : Seconds.t -> samples -> added
(** Added retains the exact duration and increases count by one. Full returns
    the unchanged population. Count never exceeds the explicit limit. *)

val quantile : numerator:int -> denominator:int -> samples -> Count.t option
(** Exact nanosecond nearest-rank quantile: rank
    ceil(count*numerator/denominator). Require 0 < numerator <= denominator;
    empty or invalid input returns None. Permutations preserve quantiles, and
    equal durations yield that duration. *)
