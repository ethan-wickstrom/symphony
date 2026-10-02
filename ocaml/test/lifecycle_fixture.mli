(** Checked offline inputs and one test-only agent port. No workspace is
    acquired, subprocess launched or hook run. Its completion factory certifies
    only this empty fixture scope; it does not establish real OS resource
    closure. *)

module Path : Workspace_path.S
module Workspace : Workspace_manager.PURE with module Path = Path

module Agent :
  Agent_runner.PURE
    with module Issue = Issue
     and module Path = Path
     and type workspace = Workspace.reference

module Config :
  Config_layer.S
    with type tracker = Tracker_registry.Contract.binding
     and type registry = Tracker_registry.t

module Plan :
  Run_plan.S
    with type config = Config.t
     and type binding = Tracker_registry.Contract.binding
     and type request = Agent.request
     and type workspace = Workspace.reference

module Lifecycle :
    module type of
      Issue_lifecycle.Make (Tracker_registry.Contract) (Clock.Pure) (Workspace)
        (Agent)
        (Plan)

type profile = Original | Replacement | Declining | Other_scope

val config : profile -> Config.t

val issue :
  ?state:string ->
  ?title:string ->
  id:string ->
  identifier:string ->
  unit ->
  Issue.t

val plan :
  Config.t ->
  run:Run_id.t ->
  issue:Issue.t ->
  attempt:Template.attempt ->
  Plan.t

val rejection :
  Config.t ->
  run:Run_id.t ->
  issue:Issue.t ->
  attempt:Template.attempt ->
  Plan.rejection

val completed :
  issue:Issue_id.t -> run:Run_id.t -> Agent_runner.outcome -> Agent.completed
(** Confined to the fake test port above. Intentionally accepts crossed IDs so
    the lifecycle's value-equality rejection can be observed. *)

val instant : int -> Clock.Pure.instant
val positive : int -> Positive_count.t
val diagnostic : Diagnostic.t
val tracker_error : Tracker_error.t
