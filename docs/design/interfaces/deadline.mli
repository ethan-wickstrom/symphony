(** One fixed monotonic deadline, shared by HTTP posts and complete tracker
    reads. Own and join both branches before converting the winning outcome. *)

module Make (Clock : Clock.S) : sig
  val run :
    Clock.t ->
    delay:Milliseconds.t ->
    on_error:(Diagnostic.t -> 'e) ->
    on_timeout:(unit -> 'e) ->
    (unit -> ('a, 'e) result) ->
    ('a, 'e) result
  (** Sample the supplied clock once and race action against sleep_until at
      after(sample,delay). Return the first completed observation and join the
      canceled branch. An action Error remains caller-typed; no nested result
      hides it from the resource owner.

      Error/timeout mapping occurs only for the winning timer outcome, after
      joining both branches. A callback defect is captured before Eio's parallel
      exception aggregation and re-raised with physical identity/backtrace.
      External cancellation propagates after branch cleanup. No detached timer,
      ambient clock, hidden timeout exception or shared mutable deadline. *)
end
