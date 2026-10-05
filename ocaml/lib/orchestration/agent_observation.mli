(** Canonical accepted facts for one worker. Stream terminals never certify
    closure. *)

type phase =
  | Awaiting
  | Preparing
  | Workspace_ready
  | Rendering
  | Starting
  | Running
  | Turn_completed
  | Continuation_queued
  | Turn_answered

type acceptance = Accepted | Ignored

type error =
  | Wrong_phase
  | Wrong_session
  | Wrong_thread
  | Wrong_turn
  | Wrong_run
  | Future_time
  | Regressing_time
  | Turn_limit

val message : error -> string
(** Fixed bounded descriptions; rejected values never enter diagnostics. *)

module Make (Clock : Clock.PURE) (Agent : Agent_runner.PURE) : sig
  type t

  type view = {
    sequence : Count.t;
    phase : phase;
    session : Session_id.t option;
    thread : Thread_id.t option;
    turn : Turn_id.t option;
    turn_count : Count.t;
    last_event : string option;
    last_message : string option;
    last_activity : Clock.instant option;
    usage : Usage.t;
    rate_limits : Json.t option;
    workspace : string option;
  }

  val empty : Agent_settings.t -> t
  val view : t -> view

  val observe :
    t ->
    run:Run_id.t ->
    now:Clock.instant ->
    emitted_at:Clock.instant ->
    Agent.progress ->
    (t * acceptance * Usage.t, error) result
  (** Accepted sequences strictly increase and their local emission stamps do
      not regress or exceed owner time. Duplicate/older sequences are identity,
      including activity and usage. Rejection preserves the original carrier.
      Preparation advances in order; session/turn identities are checked before
      protocol facts can advance activity or join the run/thread watermark. A
      new turn retains that watermark. Previously accepted turns may report
      cumulative usage without changing activity/display facts. Known turns are
      bounded by the frozen settings' max_turns, with no per-turn watermark. *)

  val queue : t -> turn:Turn_id.t -> (t * acceptance, error) result
  (** A successful matching turn queues one authoritative refresh. Repetition
      before its answer or the next turn is identity. No clock is reset. *)

  val need : t -> Turn_id.t option
  (** A queued turn remains needed while older issue reads discharge. *)

  val answer : t -> turn:Turn_id.t -> (t, error) result
  (** Remember the answered turn until a distinct Turn_started advances it.
      Queue/answer never attest resource completion. *)
end
