(** Independent mathematical/list reference models; no production operations. *)

type dispatch_key = {
  priority : int option;
  created_at : int option;
  identifier : string;
}

val dispatch : dispatch_key -> dispatch_key -> int

val backoff : attempt:Z.t -> cap:Z.t -> Z.t
(** Closed-form [min(cap, 10000 * 2^(attempt - 1))] for positive attempts and
    nonnegative caps; bounds exponentiation by cap bit length. *)

type totals = { input : Z.t; output : Z.t; total : Z.t }

val zero : totals
val sum : totals list -> totals
val supremum : totals list -> totals
val growth : previous:totals -> current:totals -> totals

type identity_error = Wrong_run | Wrong_thread
type watermark

val initial : run:string -> thread:string -> watermark
val absolute : watermark -> totals

val observe :
  watermark ->
  run:string ->
  thread:string ->
  report:totals ->
  (watermark * totals, identity_error) result
(** Retains every report in a list; accepted totals are its supremum. *)
