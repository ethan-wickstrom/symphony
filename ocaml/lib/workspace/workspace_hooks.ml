type outcome = Completed of (unit, Workspace_manager.error) result | Cancelled
type event = Started | Finished of outcome

module type S = sig
  module Contract : Workspace_manager.PURE

  type t

  val run :
    t ->
    workspace:Contract.reference ->
    cwd:Contract.Path.t ->
    Workspace_settings.hook ->
    (unit, Workspace_manager.error) result
end

module Make
    (Contract : Workspace_manager.PURE)
    (Process : Agent_process.S with module Path = Contract.Path)
    (Clock : Clock.S) =
struct
  module Contract = Contract

  type t = {
    process : Process.t;
    clock : Clock.t;
    emit : Contract.reference -> Workspace_settings.hook -> event -> unit;
  }

  type terminal =
    | Returned of (unit, Workspace_manager.error) result
    | Raised of exn * Printexc.raw_backtrace

  let create ~process ~clock ~emit = { process; clock; emit }
  let ( let* ) = Result.bind

  let name = function
    | Workspace_settings.After_create -> "after_create"
    | Workspace_settings.Before_run -> "before_run"
    | Workspace_settings.After_run -> "after_run"
    | Workspace_settings.Before_remove -> "before_remove"

  let diagnostic workspace hook message remedy =
    Diagnostic.make
      ~site:
        (Diagnostic.Issue
           {
             id = Contract.issue_id workspace;
             identifier = Contract.identifier workspace;
           })
      ~message:(name hook ^ ": " ^ message)
      ~remedy

  let failed workspace hook error =
    Workspace_manager.Hook_failed
      (diagnostic workspace hook (Diagnostic.render error)
         "Check the configured hook and host process/clock diagnostics")

  let rec drain read =
    let* bytes = read () in
    match bytes with
    | None -> Ok ()
    | Some _ ->
        Eio.Fiber.yield ();
        drain read

  let exit workspace hook = function
    | Process.Exited 0 -> Ok ()
    | Process.Exited code ->
        Error
          (Workspace_manager.Hook_failed
             (diagnostic workspace hook
                ("Hook exited with status " ^ string_of_int code)
                "Fix the hook command so it exits successfully"))
    | Process.Signaled signal ->
        Error
          (Workspace_manager.Hook_failed
             (diagnostic workspace hook
                ("Hook ended on signal " ^ string_of_int signal)
                "Check hook termination and host resource limits"))

  let observe workspace hook process =
    Eio.Fiber.first
      (fun () ->
        match Process.await_exit process with
        | Error error -> Error (failed workspace hook error)
        | Ok status -> exit workspace hook status)
      (fun () ->
        let watch read =
          match drain read with
          | Error error -> Error (failed workspace hook error)
          | Ok () -> Eio.Fiber.await_cancel ()
        in
        Eio.Fiber.first
          (fun () -> watch (fun () -> Process.read process))
          (fun () -> watch (fun () -> Process.stderr process)))

  let execute t workspace cwd hook script =
    match Clock.now t.clock with
    | Error error -> Error (failed workspace hook error)
    | Ok started ->
        let deadline =
          Clock.Pure.after started
            (Workspace_settings.timeout (Contract.settings workspace))
        in
        Process.with_process t.process ~cwd
          ~env:(Contract.environment workspace)
          ~command:script ~on_error:(failed workspace hook) (fun process ->
            Eio.Fiber.first
              (fun () -> observe workspace hook process)
              (fun () ->
                match Clock.sleep_until t.clock deadline with
                | Error error -> Error (failed workspace hook error)
                | Ok () ->
                    Error
                      (Workspace_manager.Hook_timeout
                         (diagnostic workspace hook
                            "Hook exceeded its configured timeout"
                            "Fix the hook or increase hooks.timeout_ms in \
                             WORKFLOW.md"))))

  let capture f =
    try Returned (f ()) with ex -> Raised (ex, Printexc.get_raw_backtrace ())

  let resolve = function
    | Returned value -> value
    | Raised (ex, bt) -> Printexc.raise_with_backtrace ex bt

  let run t ~workspace ~cwd hook =
    match Workspace_settings.script (Contract.settings workspace) hook with
    | None -> Ok ()
    | Some script -> (
        t.emit workspace hook Started;
        let primary = capture (fun () -> execute t workspace cwd hook script) in
        let finish =
          match primary with
          | Returned result ->
              capture (fun () ->
                  Eio.Cancel.protect (fun () ->
                      t.emit workspace hook (Finished (Completed result)));
                  Ok ())
          | Raised (Eio.Cancel.Cancelled _, _) ->
              capture (fun () ->
                  Eio.Cancel.protect (fun () ->
                      t.emit workspace hook (Finished Cancelled));
                  Ok ())
          | Raised _ -> Returned (Ok ())
        in
        match primary with
        | Returned (Ok ()) -> resolve finish
        | Returned (Error _) | Raised _ -> resolve primary)
end
