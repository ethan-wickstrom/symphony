type issue = {
  id : string;
  identifier : string;
  state : string;
  title : string;
}

type target = Unnamed of string | Named of string * string * string * string

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

type t = view

let unclaimed issue = Unclaimed issue
let view state = state
let invalid () = Error "Invalid model source state"
let same_issue a b = a.id = b.id && a.identifier = b.identifier

let scope = function
  | Unnamed value | Named (value, _, _, _) -> value

let start state plan ~now =
  match state with
  | Unclaimed current when same_issue current plan.issue && plan.attempt = None
    -> Ok (Worker { current; plan; phase = Starting; started = now })
  | Unclaimed _ | Worker _ | Retry_owner _ | Cleaning _ | Released -> invalid ()

let activate = function
  | Worker worker -> (
      match worker.phase with
      | Starting -> Ok (Worker { worker with phase = Active })
      | Active | Stopping _ -> invalid ())
  | Unclaimed _ | Retry_owner _ | Cleaning _ | Released -> invalid ()

let stop state reason =
  let disposition =
    match reason with
    | Terminal -> Cleanup
    | Stall -> Retry
    | Inactive | Missing | Unroutable | Scope | Shutdown -> Release
  in
  match state with
  | Worker worker -> (
      match worker.phase with
      | Starting | Active ->
          Ok (Worker { worker with phase = Stopping (reason, disposition) })
      | Stopping _ -> invalid ())
  | Unclaimed _ | Retry_owner _ | Cleaning _ | Released -> invalid ()

let rank = function
  | Retry -> 0
  | Release -> 1
  | Cleanup -> 2

let refine state requested =
  match state with
  | Worker worker -> (
      match worker.phase with
      | Stopping (reason, current) ->
          let chosen =
            if rank requested > rank current then requested else current
          in
          Ok (Worker { worker with phase = Stopping (reason, chosen) })
      | Starting | Active -> invalid ())
  | Unclaimed _ | Retry_owner _ | Cleaning _ | Released -> invalid ()

let replace_issue state current =
  match state with
  | Worker worker when worker.current.id = current.id ->
      Ok (Worker { worker with current })
  | Retry_owner retry when retry.current.id = current.id ->
      Ok (Retry_owner { retry with current })
  | Cleaning (before, target, request) when before.id = current.id ->
      Ok (Cleaning (current, target, request))
  | Unclaimed _ | Worker _ | Retry_owner _ | Cleaning _ | Released -> invalid ()

let next = function
  | None -> 1
  | Some attempt -> attempt + 1

let finish state ~issue_id ~run outcome ~token ~due ~cleanup =
  match state with
  | Worker worker when worker.plan.run = run && worker.plan.issue.id = issue_id
    -> (
      let disposition, cause, attempt =
        match worker.phase with
        | Stopping (_, Retry) -> (Retry, Stalled, next worker.plan.attempt)
        | Stopping (_, Release) -> (Release, Continuation, 1)
        | Stopping (_, Cleanup) -> (Cleanup, Continuation, 1)
        | Starting | Active -> (
            match outcome with
            | Succeeded -> (Retry, Continuation, 1)
            | Failed -> (Retry, Attempt_failed, next worker.plan.attempt)
            | Timed_out -> (Retry, Attempt_timed_out, next worker.plan.attempt)
            | Stalled_outcome -> (Retry, Stalled, next worker.plan.attempt)
            | Canceled -> (Release, Continuation, 1))
      in
      match disposition with
      | Release -> Ok Released
      | Cleanup -> Ok (Cleaning (worker.current, worker.plan.target, cleanup))
      | Retry ->
          Ok
            (Retry_owner
               {
                 current = worker.current;
                 target = worker.plan.target;
                 token;
                 attempt;
                 cause;
                 phase = Waiting due;
               }))
  | Unclaimed _ | Worker _ | Retry_owner _ | Cleaning _ | Released -> invalid ()

let reject_start state plan ~target ~token ~due =
  match state with
  | Unclaimed current when same_issue current plan.issue && plan.attempt = None
    ->
      Ok
        (Retry_owner
           {
             current;
             target;
             token;
             attempt = 1;
             cause = Planning_failed;
             phase = Waiting due;
           })
  | Unclaimed _ | Worker _ | Retry_owner _ | Cleaning _ | Released -> invalid ()

let matching_resume (retry : retry) (plan : plan) =
  same_issue retry.current plan.issue
  && plan.attempt = Some retry.attempt
  && scope retry.target = scope plan.target

let reject_resume state plan ~token ~due =
  match state with
  | Retry_owner retry -> (
      match retry.phase with
      | Refreshed when matching_resume retry plan ->
          Ok
            (Retry_owner
               {
                 retry with
                 token;
                 attempt = retry.attempt + 1;
                 cause = Planning_failed;
                 phase = Waiting due;
               })
      | Refreshed | Waiting _ | Refreshing | Parked -> invalid ())
  | Unclaimed _ | Worker _ | Cleaning _ | Released -> invalid ()

let change_retry state source target =
  match state with
  | Retry_owner retry when source retry.phase ->
      Ok (Retry_owner { retry with phase = target })
  | Unclaimed _ | Worker _ | Retry_owner _ | Cleaning _ | Released -> invalid ()

let refresh state =
  change_retry state
    (function
      | Waiting _ -> true
      | Refreshed | Refreshing | Parked -> false)
    Refreshing

let settled state = change_retry state (( = ) Refreshing) Refreshed
let park state = change_retry state (( = ) Refreshed) Parked
let reread state = change_retry state (( = ) Parked) Refreshing

let requeue state cause ~token ~due =
  match state with
  | Retry_owner retry -> (
      match retry.phase with
      | Refreshed when cause = Refresh_failed || cause = No_slots ->
          Ok
            (Retry_owner
               {
                 retry with
                 token;
                 attempt = retry.attempt + 1;
                 cause;
                 phase = Waiting due;
               })
      | Refreshed | Waiting _ | Refreshing | Parked -> invalid ())
  | Unclaimed _ | Worker _ | Cleaning _ | Released -> invalid ()

let resume state plan ~now =
  match state with
  | Retry_owner retry -> (
      match retry.phase with
      | Refreshed when matching_resume retry plan ->
          Ok
            (Worker
               {
                 current = retry.current;
                 plan;
                 phase = Starting;
                 started = now;
               })
      | Refreshed | Waiting _ | Refreshing | Parked -> invalid ())
  | Unclaimed _ | Worker _ | Cleaning _ | Released -> invalid ()

let release = function
  | Retry_owner retry -> (
      match retry.phase with
      | Waiting _ | Refreshed | Parked -> Ok Released
      | Refreshing -> invalid ())
  | Unclaimed _ | Worker _ | Cleaning _ | Released -> invalid ()

let terminal state ~cleanup =
  match state with
  | Retry_owner retry -> (
      match retry.phase with
      | Refreshed -> (
          match retry.target with
          | Unnamed _ -> Ok Released
          | Named _ -> Ok (Cleaning (retry.current, retry.target, cleanup)))
      | Waiting _ | Refreshing | Parked -> invalid ())
  | Unclaimed _ | Worker _ | Cleaning _ | Released -> invalid ()

let clean_startup state target ~cleanup =
  match (state, target) with
  | Unclaimed current, Named (_, id, identifier, _)
    when current.id = id && current.identifier = identifier ->
      Ok (Cleaning (current, target, cleanup))
  | ( (Unclaimed _ | Worker _ | Retry_owner _ | Cleaning _ | Released),
      (Unnamed _ | Named _) ) -> invalid ()

let cleaned = function
  | Cleaning _ -> Ok Released
  | Unclaimed _ | Worker _ | Retry_owner _ | Released -> invalid ()
