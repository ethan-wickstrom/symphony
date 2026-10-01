(** One assembly supplies both pure configuration and frozen-bound execution. *)

type entry =
  | Entry :
      (module Tracker_adapter.S with type settings = 's and type io = 'i) * 'i
      -> entry

include Tracker.S

val make : entry list -> (t, Tracker_error.t) result
(** Pure capability capture; reject duplicate kinds without executing an
    adapter. Allocate one Type.Id witness per entry. Private bindings carry the
    same existential module, witness, settings and io. No cast, token getter or
    settings reparse is needed to execute or compare a binding. *)

val states :
  Contract.binding ->
  policy:Tracker_read_policy.t ->
  string list ->
  (Issue_batch.t, Tracker_error.t) result
(** Ordered inspection projection of the same bound adapter used by execute. On
    success,
    [execute (States { binding; policy; names; id }) = Ok (Issue_batch.by_id b)]
    when states binding ~policy names = Ok b for the same provider observation.
    A read is an effect, so this equation compares identical scripted
    observations rather than making two independent live calls.

    Dropping/replacing the registry does not revoke prior bindings. Their
    captured capabilities remain live until old requests/workers drain in the
    owning host scope. Registry owns no separate mutable lifetime or global
    warning store. *)
