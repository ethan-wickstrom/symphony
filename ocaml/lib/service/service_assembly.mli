(** Common-parent effect assembly. Exact shared types precede instances. *)
module type PORTS = sig
  module Tracker : Tracker.S
  module Clock : Clock.S
  module Workspace : Workspace_manager.S

  module Agent :
    Service.CLOSED_RUNNER
      with module Issue = Tracker.Contract.Issue
       and module Path = Workspace.Contract.Path
       and type workspace = Workspace.Contract.reference
       and type clock = Clock.t
       and type workspace_manager = Workspace.t

  module Config :
    Config_layer.S
      with type tracker = Tracker.Contract.binding
       and type registry = Tracker.t

  module File : Workflow_loader.IO
end

module Compose (Ports : PORTS) : sig
  module Load : module type of Workflow_load.Make (Ports.Config) (Ports.File)

  module Host :
      module type of
        Service.Make (Ports.Tracker) (Ports.Clock) (Ports.Workspace)
          (Ports.Agent)
          (Ports.Config)
          (Load)

  val create :
    clock:Ports.Clock.t ->
    workspace:Ports.Workspace.t ->
    agent:Ports.Agent.t ->
    file:Ports.File.t ->
    registry:Ports.Tracker.t ->
    env:Environment.t ->
    report:(Host.Core.fault -> unit) ->
    report_host:(Host.host_fault -> unit) ->
    observe:(Host.observation -> unit) ->
    Host.t
  (** Capture one named clock/workspace instance. Construct registry IO
      factories from that clock in the containing host assembly; the loader uses
      its captured registry and environment. Module equalities prevent
      exchanging independently abstract fake/live types; they do not prove a
      third-party implementation obeys its capability law. No fake
      request/completion is converted to the native runner's abstract instance.
      This assembly starts no IO/fiber. *)
end
