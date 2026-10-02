(** Source-state orchestration lifecycle over checked immutable inputs.
    Reference model: current issue plus a frozen plan for each worker; retries
    retain only an Unnamed scope or original Named cleanup reference. No
    released history, effect handle or acquired Path is retained. *)

module Make
    (Tracker : Tracker.PURE with type Issue.t = Issue.t)
    (Clock : Clock.PURE)
    (Workspace : Workspace_manager.PURE)
    (Agent :
      Agent_runner.PURE
        with module Issue = Tracker.Issue
         and module Path = Workspace.Path
         and type workspace = Workspace.reference)
    (Plan :
      Run_plan.S
        with type binding = Tracker.binding
         and type request = Agent.request
         and type workspace = Workspace.reference) : sig
  type unclaimed
  type released
  type starting
  type active
  type stopping
  type waiting
  type refreshing
  type refreshed
  type parked
  type 'phase run
  type 'phase retry
  type cleanup
  type retryable
  type releasable
  type cleanable
  type 'disposition finished

  type completion =
    | Retryable of retryable finished
    | Releasable of releasable finished
    | Cleanable of cleanable finished
        (** Transient witnesses, never stored owners. A released or cleanup-only
            completion cannot be passed to retry. Every matching closed
            completion discharges its worker obligation, including expected
            failure outcomes. *)

  type owned =
    | Starting of starting run
    | Active of active run
    | Stopping of stopping run
    | Waiting of waiting retry
    | Refreshing of refreshing retry
    | Parked of parked retry
    | Cleaning of cleanup

  type retry_cause =
    | Continuation
    | Attempt_failed of Agent_runner.failure
    | Attempt_timed_out of Agent_runner.timeout
    | Stall
    | Planning_failed of Workspace_manager.error
    | Refresh_failed of Tracker_error.t
    | No_slots

  type refresh_failure = Tracker_failed of Tracker_error.t | Slots_unavailable

  type disposition =
    | Retry_after_close
    | Release_after_close
    | Cleanup_after_close

  val unclaimed : Issue.t -> unclaimed

  val start :
    unclaimed ->
    Plan.t ->
    now:Clock.instant ->
    (starting run, Diagnostic.t) result

  val resume :
    refreshed retry ->
    Plan.t ->
    now:Clock.instant ->
    (starting run, Diagnostic.t) result
  (** A run stores Plan.t once plus its current issue and monotonic start.
      Identity checks occur here only where dynamic values meet; checked plan
      inputs are not reparsed. Start requires First; resume requires Follow_up
      matching the retry attempt and its original scope. Source issue ID and
      identifier must match the request. Admission belongs to Core. *)

  val activate : starting run -> active run
  val stop_starting : starting run -> Stop_reason.t -> stopping run
  val stop_active : active run -> Stop_reason.t -> stopping run
  val clean_after_close : stopping run -> stopping run

  val release_after_close : stopping run -> stopping run
  (** Preserve the first stop cause. After-close dispositions form Retry <
      Release < Cleanup; refinement is monotone and idempotent, with Cleanup
      absorbing. Both refinements commute. No second stop command is needed when
      a fresh terminal observation upgrades an existing stall stop. *)

  val finish_starting :
    starting run -> Agent.completed -> (completion, Diagnostic.t) result

  val finish_active :
    active run -> Agent.completed -> (completion, Diagnostic.t) result

  val finish_stopping :
    stopping run -> Agent.completed -> (completion, Diagnostic.t) result
  (** Check matching issue and run IDs, captured from the immutable request. The
      runner witness proves its resources closed; Service emits it only after
      the enclosing worker switch also closes. Pure protocol terminal values
      cannot supply this witness. Starting and Active cancellation release,
      regardless of cancellation reason. Stopping uses its after-close
      disposition even when the agent reports a racing success or failure; the
      original closed outcome remains unchanged. *)

  val retry :
    retryable finished ->
    retry_id:Retry_id.t ->
    due:Clock.instant ->
    waiting retry

  val next_attempt : retryable finished -> Positive_count.t

  val finish_cause : retryable finished -> retry_cause
  (** Succeeded means Continuation/attempt 1. Failure advances First to 1 or
      Follow_up n to n+1; stall disposition retains Stall regardless of a racing
      remote terminal. Due is computed by Core using the current checked cap. *)

  val reject_start :
    unclaimed ->
    Plan.rejection ->
    retry_id:Retry_id.t ->
    due:Clock.instant ->
    (waiting retry, Diagnostic.t) result

  val reject_resume :
    refreshed retry ->
    Plan.rejection ->
    retry_id:Retry_id.t ->
    due:Clock.instant ->
    (waiting retry, Diagnostic.t) result
  (** Planning failure is not worker completion. Initial failure keeps the
      rejection's Unnamed/Named target and attempt 1. Resume failure advances
      attempt, adopts the same-ID current issue and retains the old cleanup
      target; it does not retain the obsolete launch binding. *)

  val refresh : waiting retry -> refreshing retry

  val settled : refreshing retry -> refreshed retry
  (** Refresh removes the due rank but retains token and claim. Settled is a
      transient source-state witness: Core calls it only after consuming the
      fenced post-close request terminal from its private pending ledger. It
      does not by itself prove OS closure; that attestation belongs to Host. *)

  val park : refreshed retry -> parked retry

  val reread : parked retry -> refreshing retry
  (** A superseded ID read closes before park. Retain attempt, cause, target and
      retry ID; no live read, due rank or timer exists in Parked. A valid reload
      awakens it with a fresh Request_id and current binding/policy, without
      treating policy replacement as failure. Project Parked to Ownership's
      inactive Retry_refreshing role. Ready may park/reread in the same step. *)

  val requeue :
    refreshed retry ->
    refresh_failure ->
    retry_id:Retry_id.t ->
    due:Clock.instant ->
    waiting retry
  (** Increment positive attempt and retain the closed refresh/slot cause. *)

  val release_waiting : waiting retry -> released
  val release_refreshed : refreshed retry -> released
  val release_parked : parked retry -> released
  val release_run : releasable finished -> released

  val clean_startup :
    unclaimed -> Workspace.cleanup -> (cleanup, Diagnostic.t) result

  val clean_run : cleanable finished -> request_id:Request_id.t -> cleanup

  type terminal_retry = Release of released | Cleanup of cleanup

  val terminal_retry :
    refreshed retry -> request_id:Request_id.t -> terminal_retry
  (** Named uses its original reference; Unnamed releases and cannot authorize
      removal. The current refreshed identifier cannot replace the frozen
      directory identity. Cleanup stores Workspace.cleanup once. *)

  val cleaned : cleanup -> released
  (** Core calls only after the matching post-close Workspace_removed terminal.
      Both Ok and Error release the reservation; Error is reported and does not
      assert deletion. The spec defines no implicit cleanup retry. *)

  val plan : 'phase run -> Plan.t
  val started : 'phase run -> Clock.instant
  val stop_reason : stopping run -> Stop_reason.t
  val after_close : stopping run -> disposition
  val finished_plan : 'disposition finished -> Plan.t
  val finished_outcome : 'disposition finished -> Agent.completed
  val retry_id : 'phase retry -> Retry_id.t
  val due : waiting retry -> Clock.instant
  val attempt : 'phase retry -> Positive_count.t
  val cause : 'phase retry -> retry_cause
  val retry_target : 'phase retry -> Plan.target
  val cleanup_request : cleanup -> Workspace.cleanup
  val issue : owned -> Issue.t

  val replace_issue : owned -> Issue.t -> (owned, Diagnostic.t) result
  (** Same opaque issue ID only; successful replacement preserves lifecycle,
      generations, original plan/cleanup authority and all unrelated facts. *)
end
