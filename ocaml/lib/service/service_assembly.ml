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

module Compose (Ports : PORTS) = struct
  module Load = Workflow_load.Make (Ports.Config) (Ports.File)

  module Host =
    Service.Make (Ports.Tracker) (Ports.Clock) (Ports.Workspace) (Ports.Agent)
      (Ports.Config)
      (Load)

  let create ~clock ~workspace ~agent ~file ~registry ~env ~report ~report_host
      ~observe =
    let load = Load.create ~io:file ~registry ~env in
    Host.create ~clock ~workspace ~agent ~load ~report ~report_host ~observe
end
