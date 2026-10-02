(** Test-only correspondence over actual Core envelopes. The independent oracle
    remains Core_model. Shared request values precede the completion instance.
*)

exception Difference of string

val profiles : Core_fixture.profile list

val config : Core_fixture.profile -> Core_model.config
(** Independently declared finite fixture truth, never Config.apply, planner,
    lifecycle, ownership, dispatch or backoff observations. *)

val issue : Issue.t -> Core_model.issue

val actual_issue : Core_model.issue -> Issue.t
(** Checked issue observations and the existing finite fixture constructor. No
    unchecked JSON or issue constructor is introduced. *)

val show_input : Core_model.input -> string
val show_command : Core_model.command -> string
val show_projection : Core_model.projection -> string

module Make
    (Agent :
      Agent_runner.PURE
        with module Issue = Issue
         and module Path = Core_fixture.Path
         and type workspace = Core_fixture.Workspace.reference
         and type request = Core_fixture.Agent.request)
    (Core :
      Orchestrator.S
        with type config = Core_fixture.Config.t
         and type instant = Clock.Pure.instant
         and type tracker_request = Tracker_registry.Contract.request
         and type tracker_reply = Tracker_registry.Contract.reply
         and type agent_request = Agent.request
         and type agent_completed = Agent.completed
         and type workspace_cleanup = Core_fixture.Workspace.cleanup) : sig
  type t

  val initial :
    profile:Core_fixture.profile ->
    now:Core.instant ->
    commands:Core.command list ->
    projection:Core.projection ->
    t * Core_model.command list
  (** Core_model.create at the actual initial instant; compare every actual
      initial command and projection. Bind generations from actual commands.
      There is no manufactured bootstrap input or dependency on F.Core.state. *)

  val accept :
    t ->
    now:Core.instant ->
    input:Core.input ->
    commands:Core.command list ->
    projection:Core.projection ->
    t * Core_model.input * Core_model.command list
  (** Reverse-decode the ACTUAL envelope, step the independent model once, then
      compare complete ordered commands and the derived public projection.
      Workflow config decoding identifies a declared fixture by Config.equal;
      expected truth still comes from [config]. Agent completions are observed
      through this Agent instance, never converted to an empty-scope witness.

      Retained token bijections reject rebinding/reuse and recognize delayed
      known generations. No Core state/ledger, actual issue snapshot or latest
      command list is copied into the bridge. Any difference raises Difference
      with actual input plus expected/actual facts. A failed comparison never
      publishes a replacement bridge state. *)

  val request : t -> Core_model.request -> Request_id.t
  val run : t -> Core_model.run -> Run_id.t

  val retry : t -> Core_model.retry_id -> Retry_id.t
  (** Typed inverse lookups for the pure scripted driver. They construct no
      generation or opaque completion. Service controllers already have actual
      issued keys and need not synthesize Core inputs. *)

  val time : t -> int
  val history : t -> Core_model.command list

  val quiescent : t -> bool
  (** Oracle observations. History is the compared command history retained for
      causal generation/replay, not a production registry or auth view. *)

  val check_quiescent : t -> actual:bool -> unit
  (** Pure tests compare Core.quiescent explicitly. Service tests call with true
      only after actual graceful Service.run returns, and separately join/count
      fake scopes. Fatal drainage need not make the untouched Core quiescent. *)
end
