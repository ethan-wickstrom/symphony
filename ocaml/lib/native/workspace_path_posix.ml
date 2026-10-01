type t = {
  directory : Workspace_directory.directory;
  validate : unit -> (unit, Workspace_manager.error) result;
  lifetime : Native_lifetime.t;
}

let create ~directory ~validate ~report =
  let lifetime =
    Native_lifetime.create ~report:(fun _ ->
        report
          (Workspace_manager.Filesystem_error
             (Diagnostic.make
                ~site:(Diagnostic.Host (Workspace_directory.display directory))
                ~message:
                  "Workspace child-scope release raised an unexpected defect"
                ~remedy:
                  "Inspect child/resource release diagnostics before retrying")))
  in
  { directory; validate; lifetime }

module Public = struct
  type nonrec t = t

  let display t = Workspace_directory.display t.directory
end

let unavailable t =
  Workspace_manager.Unsafe_path
    (Diagnostic.make
       ~site:(Diagnostic.Host (Public.display t))
       ~message:"Workspace lease is closing or released"
       ~remedy:"Acquire a fresh workspace lease before starting a child")

let check t =
  if Native_lifetime.held t.lifetime then t.validate ()
  else Error (unavailable t)

let with_child t f =
  match
    Native_lifetime.with_scope t.lifetime (fun ~sw ->
        match t.validate () with
        | Error error -> Error error
        | Ok () ->
            Eio.Fiber.check ();
            Workspace_directory.with_cwd t.directory (f ~sw))
  with
  | Error Native_lifetime.Closed -> Error (unavailable t)
  | Error (Native_lifetime.Rejected error) -> Error error
  | Ok value -> Ok value

let close t = Native_lifetime.close t.lifetime
