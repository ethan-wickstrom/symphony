type entry = Entry :
  (module Tracker_adapter.S with type settings = 'settings and type io = 'io) * 'io -> entry
type t
val make : entry list -> (t, Tracker_error.t) result
(** Each adapter kind occurs once. Registry creation performs no provider requests. *)

val select : t -> kind:string -> (entry, Tracker_error.t) result
(** Runtime selection preserves each hidden settings/IO equality in its package.
    No provider-specific branch or native_ref observation enters the orchestrator. *)
