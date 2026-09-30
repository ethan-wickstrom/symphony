(** Immutable read-time projection. No cached counts, slots, or runtime totals. *)

type session = {
  id : Session_id.t;
  thread : Thread_id.t;
  turn : Turn_id.t;
  turn_count : Positive_count.t;
  last_event : string;
  last_message : string option;
  last_event_at : Utc.t;
  tokens : Usage.t;
}
type phase =
  | Preparing
  | Rendering
  | Starting
  | Streaming of session
  | Between_turns of session
  | Stopping_before_session
  | Stopping_session of session
  | Finishing_before_session
  | Finishing_session of session
(** Session data exists only in phases that acquired it. No Streaming/Awaiting pair. *)

type running = {
  issue : Issue.t;
  run_id : Run_id.t;
  scope : Tracker_scope.t;
  phase : phase;
  started_at : Utc.t;
  seconds_running : Seconds.t;
  workspace : string option;
}
type retry = {
  issue : Issue.t;
  retry_id : Retry_id.t;
  attempt : Positive_count.t;
  due_at : Utc.t option;
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
(** Validate disjoint unique issue IDs, run IDs and retry IDs. Scheduling authority
    never comes from a snapshot. [data (make d)] is d for a valid projection. *)

val data : t -> data
val counts : t -> int * int
(** Exactly list lengths; no separately stored counters. *)

type found = Running of running | Retrying of retry | Cleaning of Issue.t
val find : t -> Issue_identifier.t -> found option
(** Includes cleanup ownership; released IDs are not retained forever. *)
