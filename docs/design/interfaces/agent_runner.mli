(** Section 3.1 component. Protocol 0.159.2 is normalized at this boundary. *)

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
  | Session_started of { session : Session_id.t; thread : Thread_id.t; turn : Turn_id.t }
  | Turn_started of { session : Session_id.t; turn : Turn_id.t }
  | Output of { session : Session_id.t; event_name : string; message : string option }
  | Usage_report of { thread : Thread_id.t; absolute : Usage.t }
  | Rate_limits of Json.t
  | Unsupported_tool of { name : string; diagnostic : Diagnostic.t }
(** Normalized protocol observations. IDs/counters parse once; unknown extension
    notifications are bounded observations, never implicit terminal events. *)

type turn_outcome =
  | Completed
  | Failed_turn of Diagnostic.t
  | Interrupted_turn of Diagnostic.t option
  | Input_required of Diagnostic.t
type transport_error = Failure of failure | Deadline of timeout

module type PURE = sig
  module Issue : Issue.S
  module Path : Workspace_path.S
  type workspace
  type request
  val request : run_id:Run_id.t -> issue:Issue.t -> workspace:workspace ->
    agent:Agent_settings.t -> policy:Scheduling_policy.t ->
    prompt_file:Workflow_path.t -> prompt_source:string -> attempt:Template.attempt ->
    (request, Workspace_manager.error) result
  (** Freeze the original workspace reference/environment, never a later config root.
      Checked constructor verifies issue/reference ownership. No tracker credential
      or unchecked cwd enters the agent. Continuation reads go through the owner. *)

  val run_id : request -> Run_id.t
  val issue : request -> Issue.t
  (** Frozen launch input, not the canonical current issue used in status. *)

  val workspace : request -> workspace
  val attempt : request -> Template.attempt

  module Phase : sig
    type preparing
    type rendering
    type starting
    type streaming
    type finished
    type _ t
    type _ active =
      | Preparing : preparing active
      | Rendering : rendering active
      | Starting : starting active
      | Streaming : streaming active
    val prepare : request -> preparing t
    val render : preparing t -> Path.t -> rendering t
    val start : rendering t -> prompt:string -> starting t
    val stream : starting t -> thread:Thread_id.t -> turn:Turn_id.t -> streaming t
    val continue : streaming t -> turn:Turn_id.t -> streaming t
    val succeed : streaming t -> finished t
    val fail : 'phase active -> 'phase t -> failure -> finished t
    val timeout : 'phase active -> 'phase t -> timeout -> finished t
    val stall : 'phase active -> 'phase t -> finished t
    val cancel : 'phase active -> 'phase t -> cancel_reason -> finished t
    (** Transitions accept only their source phase; terminal phases cannot continue.
        These pure terminal values do not certify that effectful cleanup has finished. *)

  end

  type notice =
    | Preparing
    | Workspace_ready of Path.t
    | Rendering
    | Starting
    | Protocol of event
  (** Display paths are observed through Path.display, never re-promoted to authority.
      Input/elicitation ends the attempt. Unsupported tools receive failure and continue. *)

  type progress
  val progress : sequence:Positive_count.t -> notice -> progress
  val sequence : progress -> Positive_count.t
  val notice : progress -> notice
  (** One increasing sequence per run; owner ignores duplicates/older observations. *)

  type completed
  val completed_run : completed -> Run_id.t
  val outcome : completed -> outcome
  (** No public constructor: only a run boundary that has closed resources can attest
      completion. Simulation supplies its own abstract instance with the same contract. *)

end

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
