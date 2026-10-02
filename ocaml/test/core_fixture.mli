(** Checked offline scheduling fixtures. The fake agent completion witnesses
    certify only the fixture's empty resource scope. *)

module Path = Lifecycle_fixture.Path
module Workspace = Lifecycle_fixture.Workspace
module Agent = Lifecycle_fixture.Agent
module Config = Lifecycle_fixture.Config

val with_path : Workspace.reference -> (Path.t -> 'a) -> 'a
(** The owning fixture's lexical bracket. Fake acquisition and scoped closure
    remain the caller's responsibility; the path is only an informational
    fixture capability. *)

module Core :
    module type of
      Orchestrator.Make (Tracker_registry.Contract) (Clock.Pure) (Workspace)
        (Agent)
        (Config)

type profile =
  | A
  | B
  | Declining
  | Other_scope
  | Tight
  | New_policy
  | Required
  | Growing_retry
      (** Required changes only the normalized required labels to
          ready/reviewed. Growing_retry changes only the retry cap to 45000ms.
          Both retain A's binding, scope, root, launch settings and concurrency
          limits. *)

val config : profile -> Config.t
val binding_profile : Tracker_registry.Contract.binding -> profile

val issue :
  ?state:string ->
  ?title:string ->
  ?routing:Issue.routing ->
  ?labels:string list ->
  ?priority:int ->
  ?created_at:string ->
  id:string ->
  identifier:string ->
  unit ->
  Issue.t

val reply : Issue.t list -> Tracker_registry.Contract.reply
val instant : int -> Clock.Pure.instant

val completed :
  issue:Issue_id.t -> run:Run_id.t -> Agent_runner.outcome -> Agent.completed

val diagnostic : Diagnostic.t
val tracker_error : Tracker_error.t
val invalid_config : Config_layer.error
