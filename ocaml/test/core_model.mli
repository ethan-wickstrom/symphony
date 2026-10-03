(** Standalone scheduling oracle: immutable lists, tagged integer generations
    and bounded millisecond ticks. No production modules or planner calls.
    Fixtures supply checked-input truth independently: ASCII state/label names,
    positive caps/delays, at most eight IDs and ticks <=100000000ms. The finite
    event horizon bounds native generation/attempt counters; exact integer
    backoff has no artificial attempt ceiling and is capped before conversion to
    fixture ticks. *)
type request = Request of int

type run = Run of int
type retry_id = Retry_id of int
type plan_mode = Accept | Decline
type key = Safe | Unsafe

type issue = {
  id : string;
  identifier : string;
  title : string;
  state : string;
  dispatchable : bool;
  labels : string list;
  priority : int option;
  created : int option;
  key : key;
}

type config = {
  binding : int;
  scope : int;
  root : int;
  launch : int;
  file : string;
  active : string list;
  terminal : string list;
  required : string list;
  global_cap : int;
  state_caps : (string * int) list;
  poll_ms : int;
  retry_cap_ms : int;
  plan_mode : plan_mode;
}
(** Binding/launch/root integers name finite fixture facts, never credentials.
    Safe+Accept succeeds; Unsafe rejects before a reference; Safe+Decline
    rejects after a reference but before effects. Startup ignores agent Decline.
*)

type reference = { scope : int; id : string; identifier : string; root : int }
type selection = States of string list | Ids of string list

type read = {
  id : request;
  binding : int;
  terminal : string list;
  selection : selection;
}

type start = {
  issue : issue;
  run : run;
  reference : reference;
  launch : int;
  attempt : int option;
}

type cancel_reason = Reconciliation | Scope_change | Host_shutdown

type outcome =
  | Succeeded
  | Failed
  | Timed_out
  | Stalled
  | Canceled
  | Cancel_error

type fault =
  | Config_failure
  | Tracker_failure
  | Issue_tracker_failure of issue
  | Planning_failure of issue
  | Cleanup_failure of issue
  | Lifecycle_failure of issue
  | Attempt_failure of issue
  | Attempt_timeout of issue
  | Attempt_stalled of issue
  | Attempt_cancel_error of issue

type command =
  | Load_workflow of request * string
  | Read_tracker of read
  | Start_worker of start
  | Stop_worker of string * run * cancel_reason
  | Remove_workspace of request * reference
  | Cancel_request of request
  | Arm_poll of request * int
  | Cancel_poll of request
  | Arm_retry of string * retry_id * int
  | Cancel_retry of string * retry_id
  | Report of fault

type input =
  | Poll_due of request
  | Refresh_requested
  | Workflow_changed
  | Workflow_loaded of request * (config, unit) result
  | Tracker_completed of request * (issue list, unit) result
  | Worker_started of string * run
  | Worker_finished of string * run * outcome
  | Request_canceled of request
  | Retry_due of string * retry_id
  | Workspace_removed of request * (unit, unit) result
  | Shutdown

type mode = Startup | Serving | Draining_scope | Shutting_down
type readiness = Ready | Loading | Invalid
type worker_phase = Starting | Active | Stopping
type retry_phase = Waiting of int | Refreshing | Parked
type cycle_status = Idle | Busy

type worker = {
  issue : issue;
  run : run;
  phase : worker_phase;
  attempt : int option;
  seconds_ms : int;
}

type retry = {
  issue : issue;
  retry : retry_id;
  phase : retry_phase;
  attempt : int;
}

type owner = Worker of worker | Retry of retry | Cleaning of issue

type projection = {
  mode : mode;
  readiness : readiness;
  cycle : cycle_status;
  owners : owner list;
  running : int;
  available_slots : int;
  total_runtime_ms : int;
}

type state

val create : now:int -> config -> state * command list
(** Bootstrap joins every canonical job, including superseded loader custody,
    before a fresh terminal read or Serving. This is a chosen stronger ordering,
    not an additional specification requirement. Completing bootstrap reserves
    one initial poll; it does not also reschedule as an already-serving reload.
*)

val step : now:int -> input -> state -> state * command list
(** A latest loader replacing a pending cycle validation fulfills that same
    validation. A selected loader borrowed after grouped reconciliation joins
    that cycle's validation barrier. Every canceled predecessor loader still
    belongs to its cycle until closed; the watcher origin alone adds no
    reconciliation. Closing the selected canceled loader restores its prior
    completed validation; closing an older loader changes no readiness. An
    invalid latest replacement finishes its canceled cycle at the normal polling
    interval. Closing a superseded retry read parks/rereads only its matched
    owner; unrelated timers require their own due event or workflow validation.
*)

val project : now:int -> state -> projection
val quiescent : state -> bool

val invariant : state -> (unit, string) result
(** Claims/counts/barriers derive from canonical lists. Delayed post-close
    events alone retire resource custody. Retired generations live only in test
    history, so duplicate/stale/crossed replies cannot affect a replacement
    owner. *)
