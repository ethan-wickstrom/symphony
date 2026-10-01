(** Source-state transitions. Owned values live in one canonical issue-ID map.
    Unclaimed/Released witnesses are transient; no historical claims accumulate. *)

module Make
    (Issue : Issue.S with type t = Issue.t)
    (Clock : Clock.PURE)
    (Workspace : Workspace_manager.PURE)
    (Agent : Agent_runner.PURE with module Issue = Issue
                               and module Path = Workspace.Path
                               and type workspace = Workspace.reference) : sig
  type unclaimed
  type released
  type starting
  type active
  type stopping
  type complete
  type waiting
  type refreshing
  type 'phase run
  type 'phase retry
  type cleanup
  type owned =
    | Starting of starting run
    | Active of active run
    | Stopping of stopping run
    | Complete of complete run
    | Waiting of waiting retry
    | Refreshing of refreshing retry
    | Cleaning of cleanup

  val unclaimed : Issue.t -> unclaimed
  val start : unclaimed -> request:Agent.request -> now:Clock.sample ->
    (starting run, string) result
  (** Reject a request for another issue ID; checked once at this value boundary. *)

  val activate : starting run -> active run
  val stop_starting : starting run -> Stop_reason.t -> stopping run
  val stop_active : active run -> Stop_reason.t -> stopping run
  val finish_starting : starting run -> Agent.completed -> (complete run, string) result
  val finish_active : active run -> Agent.completed -> (complete run, string) result
  val finish_stopping : stopping run -> Agent.completed -> (complete run, string) result
  (** Runtime run-ID equality is checked once: OCaml has no dependent value equality.
      Completion witnesses attest resource closure; raw protocol terminal events cannot. *)

  val retry : complete run -> retry_id:Retry_id.t -> due:Clock.instant ->
    attempt:Positive_count.t -> waiting retry
  val refresh : waiting retry -> refreshing retry
  val requeue : refreshing retry -> retry_id:Retry_id.t -> due:Clock.instant -> waiting retry
  val resume : refreshing retry -> request:Agent.request -> now:Clock.sample ->
    (starting run, string) result
  val release_run : complete run -> released
  val release_waiting : waiting retry -> released
  val release_refreshing : refreshing retry -> released
  val cleanup : unclaimed -> workspace:Workspace.reference -> (cleanup, string) result
  val clean_run : complete run -> cleanup
  val clean_retry : refreshing retry -> cleanup
  val cleaned : cleanup -> released
  val forget : released -> unclaimed
  (** Core admission checks precede start/resume. Cleaning reserves ownership, no slot.
      Start -> release/retry and Waiting -> resume are absent from the interface. *)

  val request : 'phase run -> Agent.request
  val started : 'phase run -> Clock.sample
  val stop_reason : stopping run -> Stop_reason.t
  type completion = Finished of Agent.completed | Stopped of Stop_reason.t * Agent.completed
  val completion : complete run -> completion
  val retry_id : 'phase retry -> Retry_id.t
  val due : 'phase retry -> Clock.instant
  val attempt : 'phase retry -> Positive_count.t
  val retry_workspace : 'phase retry -> Workspace.reference
  val cleanup_workspace : cleanup -> Workspace.reference
  (** Observe canonical facts for fencing, deadlines, runtime and original-root cleanup;
      do not repeat them in a wrapper record. Run ID/attempt/workspace come from request. *)

  val issue : owned -> Issue.t
  val replace_issue : owned -> Issue.t -> (owned, string) result
  (** Same dispatch ID required. One canonical issue; no copied state/title/label cache. *)

end
