module Make (Config : Config_layer.S) (IO : Workflow_loader.IO) = struct
  module Loader = Workflow_loader.Make (IO)

  type config = Config.t
  type t = { io : IO.t; registry : Config.registry; env : Environment.t }
  type request = { id : Request_id.t; file : Workflow_path.t }

  let create ~io ~registry ~env = { io; registry; env }

  let load t (request : request) =
    match Loader.load t.io ~file:request.file with
    | Error error -> Error (Config_layer.Workflow error)
    | Ok document -> Config.resolve t.registry ~env:t.env ~document
end
