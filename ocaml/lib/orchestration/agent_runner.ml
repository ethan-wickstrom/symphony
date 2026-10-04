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

type timeout =
  | Response_deadline of Diagnostic.t
  | Turn_silence of Diagnostic.t

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
  | Turn_completed of { session : Session_id.t; turn : Turn_id.t }
  | Output of {
      session : Session_id.t;
      event_name : string;
      message : string option;
    }
  | Usage_report of {
      thread : Thread_id.t;
      turn : Turn_id.t;
      absolute : Usage.t;
    }
  | Rate_limits of Json.t
  | Unsupported_tool of { name : string; diagnostic : Diagnostic.t }

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

  type completed

  val completed_issue : completed -> Issue_id.t
  val completed_run : completed -> Run_id.t
  val outcome : completed -> outcome
end
