(** Independent source-state oracle. Only small tags, records and integers; no
    production Lifecycle/Ownership/Backoff/Run_plan calls. *)

type issue = {
  id : string;
  identifier : string;
  state : string;
  title : string;
}

type target =
  | Unnamed of string
  | Named of string * string * string * string
      (** Named(scope, opaque issue ID, original identifier, original root). *)

type plan = {
  run : int;
  issue : issue;
  target : target;
  attempt : int option;
  profile : int;
}

type stop =
  | Terminal
  | Inactive
  | Missing
  | Unroutable
  | Scope
  | Stall
  | Shutdown

type disposition = Retry | Release | Cleanup
type worker_phase = Starting | Active | Stopping of stop * disposition
type retry_phase = Waiting of int | Refreshing | Refreshed | Parked

type cause =
  | Continuation
  | Attempt_failed
  | Attempt_timed_out
  | Stalled
  | Planning_failed
  | Refresh_failed
  | No_slots

type outcome = Succeeded | Failed | Timed_out | Stalled_outcome | Canceled

type worker = {
  current : issue;
  plan : plan;
  phase : worker_phase;
  started : int;
}

type retry = {
  current : issue;
  target : target;
  token : int;
  attempt : int;
  cause : cause;
  phase : retry_phase;
}

type view =
  | Unclaimed of issue
  | Worker of worker
  | Retry_owner of retry
  | Cleaning of issue * target * int
  | Released

type t

val unclaimed : issue -> t
val view : t -> view
val start : t -> plan -> now:int -> (t, string) result
val activate : t -> (t, string) result
val stop : t -> stop -> (t, string) result

val refine : t -> disposition -> (t, string) result
(** Disposition is max in Retry < Release < Cleanup. Refinements commute and are
    idempotent; original stop cause is unchanged. Cleanup is absorbing. *)

val replace_issue : t -> issue -> (t, string) result
(** Same opaque ID preserves all frozen plan/target/token facts. *)

val finish :
  t ->
  issue_id:string ->
  run:int ->
  outcome ->
  token:int ->
  due:int ->
  cleanup:int ->
  (t, string) result
(** Matching closure selects retry/release/cleanup. Success resets attempt to1;
    failure advances First to1 or Follow_up n to n+1. Stop disposition wins. *)

val reject_start :
  t -> plan -> target:target -> token:int -> due:int -> (t, string) result

val reject_resume : t -> plan -> token:int -> due:int -> (t, string) result
(** Resumed rejection keeps the preceding cleanup target and advances attempt.
*)

val refresh : t -> (t, string) result
val settled : t -> (t, string) result
val park : t -> (t, string) result

val reread : t -> (t, string) result
(** Waiting loses due on refresh; park/reread preserve
    token/attempt/cause/target. *)

val requeue : t -> cause -> token:int -> due:int -> (t, string) result
val resume : t -> plan -> now:int -> (t, string) result
val release : t -> (t, string) result
val terminal : t -> cleanup:int -> (t, string) result
val clean_startup : t -> target -> cleanup:int -> (t, string) result
val cleaned : t -> (t, string) result
