(** Checked, immutable read-time projection. This value grants no scheduling,
    tracker, workspace or process capability. *)

type session = {
  id : Session_id.t;
  thread : Thread_id.t;
  turn : Turn_id.t;
  turn_count : Positive_count.t;
  last_event : string;
  last_message : string option;
  last_event_at : Utc.t option;
  tokens : Usage.t;
}

type phase =
  | Awaiting
  | Preparing
  | Workspace_ready
  | Rendering
  | Starting
  | Streaming of session
  | Between_turns of session
  | Stopping_before_session
  | Stopping_session of session
      (** Only phases that acquired a session can carry session data. *)

type running = {
  issue : Issue.t;
  run_id : Run_id.t;
  attempt : Template.attempt;
  phase : phase;
  started_at : Utc.t option;
  seconds_running : Seconds.t;
  workspace : string option;
}

type retry_phase =
  | Waiting of Utc.t option
  | Refreshing
  | Parked
      (** Only Waiting has a due time. None means a wall projection outside the
          supported RFC 3339 range; it never means a missing monotonic deadline.
      *)

type retry = {
  issue : Issue.t;
  retry_id : Retry_id.t;
  attempt : Positive_count.t;
  phase : retry_phase;
  error : Diagnostic.t option;
}

type data = {
  generated_at : Utc.t;
  running : running list;
  retrying : retry list;
  cleaning : Issue.t list;
  tokens : Usage.t;
  seconds_running : Seconds.t;
  rate_limits : Json.t option;
  workflow_error : Diagnostic.t option;
}

type t

val make : data -> (t, string) result
(** Reject duplicate or overlapping issue IDs/identifiers, duplicate run/retry
    generations and invalid UTF-8 display strings, including rendered
    diagnostics. [data t = d] when [make d = Ok t]; rejection cannot alter d.
    Counts are not stored twice. *)

val data : t -> data

val counts : t -> int * int
(** Exactly the running/retrying list lengths. *)

type found = Running of running | Retrying of retry | Cleaning of Issue.t

val find : t -> Issue_identifier.t -> found option
(** The unique current owner, including cleanup. A released issue is absent.
    Independent list model: search the three disjoint owner lists. *)
