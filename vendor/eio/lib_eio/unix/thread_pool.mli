(** A pool of systhreads, to avoid the overhead of creating a new thread for each operation. *)

type t

type Eio.Exn.Backend.t += Worker_unavailable of string
(** A host failure while acquiring a native worker. The original runtime
    diagnostic is retained without guessing a Unix error number. *)

val create : sleep_q:Eio_utils.Zzz.t -> t
(** [create ~sleep_q] is a new thread pool.

    [sleep_q] is used to register a clean-up task to finish idle threads. *)

val run : t -> (unit -> 'a) -> 'a
(** [run t fn] runs [fn ()] and then marks [t] as closed, releasing all idle threads. *)

val submit :
  t ->
  ctx:Eio.Private.Fiber_context.t ->
  enqueue:(('a, Eio.Exn.with_bt) result -> unit) ->
  (unit -> 'a) ->
  unit
(** [submit t ~ctx ~enqueue fn] starts running [fn] in a sys-thread, which uses [enqueue] to return the result.

    If [ctx] is already cancelled then the error is passed to [enqueue] immediately.
    Worker-acquisition failures are also passed to [enqueue], with their
    original backtrace, so the suspended caller can run its cleanup.
    An acquisition [Sys_error] becomes {!Eio.Io} with {!Eio.Exn.Not_available}
    and [Worker_unavailable]. Job failures and other defects stay unchanged.
    Systhreads do not respond to cancellation once running. *)

type _ Effect.t += Run_in_systhread : (unit -> 'a) -> (('a, Eio.Exn.with_bt) result * t) Effect.t
val run_in_systhread : ?label:string -> (unit -> 'a) -> 'a
