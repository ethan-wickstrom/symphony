(** Normalized agent port. The protocol implementation is a later instance;
    completion factories belong only to resource-owning port implementations. *)

type failure =
  | Codex_not_found of Diagnostic.t
  | Invalid_workspace_cwd of Diagnostic.t
  | Port_exit of Diagnostic.t
  | Response_error of Diagnostic.t
  | Turn_failed of Diagnostic.t
  | Turn_input_required of Diagnostic.t
  | Template_error of Template.error
  | Workspace_error of Workspace_manager.error
  | Tracker_error of Tracker_error.t

type cancel_reason = Reconciliation | Scope_change | Host_shutdown
type timeout = Response_deadline of Diagnostic.t | Turn_silence of Diagnostic.t

type outcome =
  | Succeeded
  | Failed of failure
  | Timed_out of timeout
  | Stalled
  | Canceled of { reason : cancel_reason; remote_error : Diagnostic.t option }

type interrupt = Cancel of cancel_reason | Stall
type continuation = Continue of Issue.t | Stop

type event =
  | Session_started of {
      session : Session_id.t;
      thread : Thread_id.t;
      turn : Turn_id.t;
    }
  | Turn_started of { session : Session_id.t; turn : Turn_id.t }
  | Output of {
      session : Session_id.t;
      event_name : string;
      message : string option;
    }
  | Usage_report of { thread : Thread_id.t; absolute : Usage.t }
  | Rate_limits of Json.t
  | Unsupported_tool of { name : string; diagnostic : Diagnostic.t }
(** Protocol parsing checks IDs/counters and bounds extension observations
    before construction. Input requests terminate the attempt; unsupported tools
    fail the tool response and preserve the turn. No raw terminal is a completion. *)

module type PURE = sig
  include Agent_plan.S

  type notice =
    | Preparing
    | Workspace_ready of Path.t
    | Rendering
    | Starting
    | Protocol of event

  type progress

  val progress : sequence:Positive_count.t -> notice -> progress
  val sequence : progress -> Positive_count.t
  val notice : progress -> notice
  (** One sequence per run; observe facts without changing them. Causal checking
      belongs to the canonical lifecycle observation, not another progress map. *)

  type completed

  val completed_issue : completed -> Issue_id.t
  val completed_run : completed -> Run_id.t
  val outcome : completed -> outcome
  (** Observers identify the original request. No public completion constructor:
      only a port boundary after workspace/process/hook closure can attest this
      value. Host publishes it after its enclosing worker switch also closes.
      Unrequested host cancellation and defects drain then propagate instead of
      fabricating an expected outcome. Fake ports own a distinct abstract instance. *)
end

(** Proposed effectful instance; not implemented by the pure port above. *)
type turn_outcome =
  | Completed
  | Failed_turn of Diagnostic.t
  | Interrupted_turn of Diagnostic.t option
  | Input_required of Diagnostic.t

type transport_error = Failure of failure | Deadline of timeout

module type TRANSPORT = sig
  module Path : Workspace_path.S
  type t
  type session
  val with_session : t -> cwd:Path.t -> env:Environment.child -> settings:Agent_settings.t ->
    (session -> ('a, transport_error) result) -> ('a, transport_error) result
  (** Launch from the live directory capability, handshake, scoped child/group,
      bounded TERM/KILL grace/stream drain and direct-child reap on every exit.
      POSIX has no finite actual reap bound. Preserve cancellation. *)

  val turn : session -> prompt:string -> emit:(event -> unit) ->
    (turn_outcome, transport_error) result
  (** JSONL; request/response identity; read_timeout bounds responses, turn_timeout
      measures output silence. Continuations reuse the same thread. Only this layer
      interprets wire approvals/tools/input requests and normalizes turn outcomes. *)

end

module type S = sig
  module Contract : PURE with type Issue.t = Issue.t
  type t
  val run : t -> Contract.request -> emit:(Contract.progress -> unit) ->
    refresh:(turn:Turn_id.t -> (continuation, Tracker_error.t) result) ->
    interrupted:(unit -> interrupt option) -> Contract.completed
  (** After each successful turn, ask the owner for a fenced refresh of the original
      binding; the owner adopts that issue and replies. Return only after workspace,
      subprocess and after_run cleanup. Requested cancellation/stall yields a completed
      witness after cleanup. Unrequested host cancellation propagates; never retry it. *)

end

module Make
    (Issue : Issue.S with type t = Issue.t)
    (Workspace : Workspace_manager.S)
    (Transport : TRANSPORT with module Path = Workspace.Contract.Path) : sig
  include S with module Contract.Path = Workspace.Contract.Path
             and module Contract.Issue = Issue
             and type Contract.workspace = Workspace.Contract.reference
  val create : workspace:Workspace.t -> transport:Transport.t -> t
end
