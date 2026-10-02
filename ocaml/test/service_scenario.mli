(** Scoped fake effects for the actual Service.Make interpreter. The named
    controller interprets checked fixture requests; it executes no native IO. *)

module F = Core_fixture

type key =
  | Load of Request_id.t
  | Read of Request_id.t
  | Remove of Request_id.t
  | Run of Issue_id.t * Run_id.t

type resource_event = Acquired of key | Closing of key | Released of key
type closure = Close_ok | Close_defect of exn

type _ invocation =
  | Loading : {
      id : Request_id.t;
      file : Workflow_path.t;
    }
      -> (F.Config.t, Config_layer.error) result invocation
  | Reading :
      Tracker_registry.Contract.request
      -> Tracker_registry.Contract.reply invocation
  | Removing :
      F.Workspace.cleanup
      -> (unit, Workspace_manager.error) result invocation
  | Running : F.Agent.request -> Agent_runner.outcome invocation

type 'answer call
type pending = Pending : 'answer call -> pending
type t

val run : (sw:Eio.Switch.t -> t -> 'a) -> 'a
(** Own the manual mock clocks, controller and every child on [sw]. The actor
    must join its service before normal return. On any actor exit, permit every
    finalizer before joining children. Actor failure thus cannot strand a gate
    that only the failed actor could release. Permission never fabricates
    [Released]: the actual finalizer still emits it after [Closing].

    Opening a gate twice is identity; the first explicit close outcome wins. No
    new operation may enter after the actor exits. Trace inspection remains
    valid after join. Exceptions from the actor propagate after child closure.
*)

val key : 'answer call -> key
val invocation : 'answer call -> 'answer invocation

val pending : t -> pending list
(** Outstanding fake operations in entry order, including protected Closing
    gates. This is fake-resource evidence, not a Host scheduling ledger. *)

val respond : 'answer call -> 'answer -> unit

val fail : 'answer call -> exn -> unit
(** First response/defect wins. A supplied defect is raised by its actual port
    callback, retaining the callback's backtrace. *)

val close : 'answer call -> closure -> unit
(** Permit the actual protected scope finalizer to release. Permitting early or
    twice is idempotent; it does not release resources before Closing. *)

val trace : t -> resource_event list
val revision : t -> int
val notify : t -> unit

val await_change : t -> after:int -> unit
(** Predicate-based notification; safe against already committed changes. *)

val advance : t -> Clock.Pure.instant -> unit
(** Manually advance the supplied Eio_mock monotonic clock. Backward/native-
    horizon inputs are fixture defects; generated tests use bounded ticks. *)

val fail_next_now : t -> Diagnostic.t -> unit
val defect_next_now : t -> exn -> unit
val fail_next_sleep : t -> Diagnostic.t -> unit

val defect_next_sleep : t -> exn -> unit
(** One-shot source failures; unaffected operations use Clock_posix over the
    same explicit Eio_mock clock capabilities. No ambient clock is sampled. *)

module Clock : Clock.S with module Pure = Clock.Pure and type t = t

module Workspace :
  Workspace_manager.S with module Contract = F.Workspace and type t = t

(** Shares the checked request parent, but owns a distinct abstract completed
    carrier. Its completion factory runs only after its fake scope closes. *)
module Agent :
  Service.CLOSED_RUNNER
    with module Issue = Issue
     and module Path = F.Path
     and type workspace = F.Workspace.reference
     and type request = F.Agent.request
     and type clock = Clock.t
     and type workspace_manager = Workspace.t
     and type t = t

module Load : Service.WORKFLOW_LOAD with type config = F.Config.t and type t = t

(** Tracker.execute interprets the request's original fixture binding through
    this explicit named capability. It never calls native/fixture-forbidden IO,
    reparses opaque bindings or selects from the latest configuration. *)
module Ports (_ : sig
  val controller : t
end) : sig
  module Tracker :
    Tracker.S
      with module Contract = Tracker_registry.Contract
       and type t = Tracker_registry.t

  module Clock = Clock
  module Workspace = Workspace
  module Agent = Agent
  module Config = F.Config
  module Load = Load
end
