module Make (Clock : Clock.S) = struct
  module Path = Workspace_path_posix.Public
  module Contract = Workspace_contract_posix
  module Store = Workspace_store_posix
  module Process = Workspace_process_posix.Make (Clock)
  module Hooks = Workspace_hooks.Make (Contract) (Process) (Clock)
  module Driver = Workspace_driver.Make (Store) (Hooks)
  module Workspace = Workspace_manager.Make (Driver)

  type t = { process : Process.t; workspace : Workspace.t }

  let create ~fs ~clock ~emit ~report =
    let store =
      Store.create ~fs ~report ~close_path:Workspace_path_posix.close
    in
    let process =
      Process.create ~clock ~report:(fun diagnostic ->
          report (Workspace_manager.Filesystem_error diagnostic))
    in
    let hooks = Hooks.create ~process ~clock ~emit in
    { process; workspace = Driver.create ~store ~hooks ~report }

  let process t = t.process
  let workspace t = t.workspace
end
