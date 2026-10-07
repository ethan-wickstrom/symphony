(** Preserve a callback's primary outcome across its owning switch closure. *)

val with_scope :
  (Eio.Switch.t -> ('a, Diagnostic.t) result) -> ('a, Diagnostic.t) result
(** The callback outcome is captured before joining children. After every child
    and release obligation closes, callback [Error d] returns that same [d]; a
    callback exception is raised with its original identity and backtrace.
    Neither can be replaced by a later switch/child closure failure. A callback
    cancellation matching the switch's already-canceled cause is induced, not a
    new primary: the switch closure retains that preceding failure. A manually
    raised cancellation with another cause retains its original identity.

    Callback [Ok value] returns [Ok value] exactly when switch closure succeeds;
    otherwise the closure failure propagates. Cancellation remains an exception,
    never a diagnostic. No callback exception is reclassified or rebuilt into a
    new aggregate. Eio's usual cancellation/join behavior is preserved.

    This scope has no duration bound: child/finalizer termination belongs to
    their effect-port contracts. All owned scopes are joined before this
    operation returns or raises. *)
