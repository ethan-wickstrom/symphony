module Group = Eio_posix.Low_level.Process.Group
module Io = Eio_posix.Low_level

module Make (Clock : Clock.S) = struct
  module Path = Workspace_path_posix.Public

  type error = Diagnostic.t
  type exit = Exited of int | Signaled of int
  type t = { clock : Clock.t; report : Diagnostic.t -> unit }

  type pipes = {
    input_r : Eio_unix.Fd.t;
    input_w : Eio_unix.Fd.t;
    output_r : Eio_unix.Fd.t;
    output_w : Eio_unix.Fd.t;
    errors_r : Eio_unix.Fd.t;
    errors_w : Eio_unix.Fd.t;
  }

  type resources = { group : Group.t; pipes : pipes }

  type process = {
    site : string;
    lifetime : Native_lifetime.t;
    resources : resources;
  }

  type reporting = Report | Already_reported

  let chunk_bytes = 4096
  let shell = "/bin/bash"

  let duration literal =
    match Milliseconds.parse literal with
    | Ok value -> value
    | Error message -> invalid_arg ("process duration constant: " ^ message)

  let term_grace = duration "1000"
  let drain_grace = duration "100"
  let create ~clock ~report = { clock; report }

  let diagnostic site message =
    Diagnostic.make ~site:(Diagnostic.Host site) ~message
      ~remedy:
        "Check the workspace process, host pipes and supplied capabilities"

  let host site operation run =
    match Native_io.capture run with
    | Ok value -> Ok value
    | Error (Native_io.Unix (error, _)) ->
        Error (diagnostic site (operation ^ ": " ^ Unix.error_message error))
    | Error (Native_io.Io _) -> Error (diagnostic site (operation ^ " failed"))

  let unavailable process =
    diagnostic process.site "Process scope is closing or closed"

  let operation process run =
    match
      Native_lifetime.with_scope process.lifetime (fun ~sw:_ ->
          run process.resources)
    with
    | Ok value -> Ok value
    | Error Native_lifetime.Closed -> Error (unavailable process)
    | Error (Native_lifetime.Rejected error) -> Error error

  let chunk site fd =
    let buffer = Bytes.create chunk_bytes in
    Result.map
      (function
        | 0 -> None
        | length -> Some (Bytes.sub_string buffer 0 length))
      (host site "Pipe read" (fun () -> Io.read fd buffer 0 chunk_bytes))

  let read process =
    operation process (fun resources ->
        chunk process.site resources.pipes.output_r)

  let stderr process =
    operation process (fun resources ->
        chunk process.site resources.pipes.errors_r)

  let write process frame =
    operation process (fun resources ->
        let bytes = Bytes.of_string frame in
        let length = Bytes.length bytes in
        let rec send offset =
          if offset = length then Ok ()
          else
            Result.bind
              (host process.site "Pipe write" (fun () ->
                   Io.write resources.pipes.input_w bytes offset
                     (length - offset)))
              (fun written ->
                if written = 0 then
                  Error (diagnostic process.site "Pipe write made no progress")
                else send (offset + written))
        in
        send 0)

  let observe_exit site group =
    match Group.await_exit group with
    | Ok (Group.Exited code) -> Ok (Exited code)
    | Ok (Group.Signaled signal) -> Ok (Signaled signal)
    | Error error ->
        Error
          (diagnostic site ("Exit observation: " ^ Unix.error_message error))

  let await_exit process =
    operation process (fun resources ->
        observe_exit process.site resources.group)

  let cause = function
    | Group.Group_signal error -> "group signal: " ^ Unix.error_message error
    | Group.Leader_signal error -> "leader signal: " ^ Unix.error_message error
    | Group.Reap error -> "child reap: " ^ Unix.error_message error

  let cleanup_error site (first, rest) =
    diagnostic site (String.concat "; " (List.map cause (first :: rest)))

  let spawn_error site = function
    | Group.Spawn_error error ->
        diagnostic site ("Process launch: " ^ Unix.error_message error)
    | Group.Worker_unavailable _ ->
        diagnostic site "Process launch worker unavailable; no child was forked"
    | Group.Spawn_cleanup_failed (error, cleanup) ->
        diagnostic site
          ("Process launch: " ^ Unix.error_message error ^ "; "
          ^ Diagnostic.render (cleanup_error site cleanup))

  let first_failure first second =
    match (first, second) with
    | Native_outcome.Raised _, _ -> first
    | _, Native_outcome.Raised _ -> second
    | Native_outcome.Returned (Error _), Native_outcome.Returned _ -> first
    | Native_outcome.Returned (Ok ()), Native_outcome.Returned _ -> second

  let obligation t reporting action =
    let outcome = Native_outcome.capture action in
    match outcome with
    | Native_outcome.Returned (Ok ()) | Native_outcome.Raised _ -> outcome
    | Native_outcome.Returned (Error error) -> (
        match reporting with
        | Already_reported -> outcome
        | Report ->
            let reported =
              Native_outcome.capture (fun () ->
                  t.report error;
                  Ok ())
            in
            first_failure outcome reported)

  let complete t steps =
    List.fold_left
      (fun previous (reporting, action) ->
        let outcome = obligation t reporting action in
        first_failure previous outcome)
      (Native_outcome.Returned (Ok ())) steps

  let close_fd site fd () =
    host site "Pipe close" (fun () -> Eio_unix.Fd.close fd)

  let timed t delay action =
    Result.bind (Clock.now t.clock) (fun now ->
        let deadline = Clock.Pure.after now delay in
        Eio.Switch.run (fun _ ->
            Eio.Fiber.first action (fun () ->
                Clock.sleep_until t.clock deadline)))

  let rec discard site fd () =
    Result.bind (chunk site fd) (function
      | None -> Ok ()
      | Some _ -> discard site fd ())

  let drain t site pipes () =
    timed t drain_grace (fun () ->
        let output, errors =
          Eio.Fiber.pair
            (discard site pipes.output_r)
            (discard site pipes.errors_r)
        in
        Result.bind output (fun () -> errors))

  let signal site group value () =
    match Group.signal group value with
    | Ok () -> Ok ()
    | Error error ->
        Error (diagnostic site ("Group signal: " ^ Unix.error_message error))

  let close_group site group () =
    match Group.close group with
    | Ok () -> Ok ()
    | Error error -> Error (cleanup_error site error)

  let close t process =
    Eio.Cancel.protect (fun () ->
        let { group; pipes } = process.resources in
        (* Capture each obligation independently: no reporter or timer defect
           can skip operation joins, custody closure or a later pipe close. *)
        complete t
          [
            ( Report,
              fun () ->
                Native_lifetime.close process.lifetime;
                Ok () );
            (Report, signal process.site group Group.Term);
            ( Report,
              fun () ->
                timed t term_grace (fun () ->
                    Result.map (fun _ -> ()) (observe_exit process.site group))
            );
            (Report, signal process.site group Group.Kill);
            (Already_reported, close_group process.site group);
            (Report, drain t process.site pipes);
            (Report, close_fd process.site pipes.input_r);
            (Report, close_fd process.site pipes.input_w);
            (Report, close_fd process.site pipes.output_r);
            (Report, close_fd process.site pipes.output_w);
            (Report, close_fd process.site pipes.errors_r);
            (Report, close_fd process.site pipes.errors_w);
          ])

  let resolve ~on_error primary cleanup =
    match primary with
    | Native_outcome.Returned (Error _ as error) -> error
    | Native_outcome.Raised (error, trace) ->
        Printexc.raise_with_backtrace error trace
    | Native_outcome.Returned (Ok value) -> (
        match Native_outcome.resolve cleanup with
        | Ok () -> Ok value
        | Error error -> Error (on_error error))

  let pipes site sw =
    host site "Pipe creation" (fun () ->
        let input_r, input_w = Io.pipe ~sw in
        let output_r, output_w = Io.pipe ~sw in
        let errors_r, errors_w = Io.pipe ~sw in
        { input_r; input_w; output_r; output_w; errors_r; errors_w })

  let launch t ~sw ~cwd ~env ~command ~on_error site run =
    Result.bind
      (Result.map_error on_error (pipes site sw))
      (fun pipes ->
        (* Spec section 10.1 requires this trusted shell invocation. Issue data
           never enters the command; argv and environment are separate arrays. *)
        let argv = [| shell; "-lc"; command |] in
        let env =
          Environment.bindings env
          |> List.map (fun (name, value) -> name ^ "=" ^ value)
          |> Array.of_list
        in
        match
          Group.spawn ~sw ~cwd ~stdin:pipes.input_r ~stdout:pipes.output_w
            ~stderr:pipes.errors_w ~executable:shell ~argv ~env
            ~report_cleanup:(fun error -> t.report (cleanup_error site error))
        with
        | Error error -> Error (on_error (spawn_error site error))
        | Ok group ->
            let process =
              {
                site;
                lifetime =
                  Native_lifetime.create ~report:(fun (_error, _trace) ->
                      t.report
                        (diagnostic site "Process operation cleanup failed"));
                resources = { group; pipes };
              }
            in
            let primary =
              Native_outcome.capture (fun () ->
                  match
                    complete t
                      [
                        (Report, close_fd site pipes.input_r);
                        (Report, close_fd site pipes.output_w);
                        (Report, close_fd site pipes.errors_w);
                      ]
                    |> Native_outcome.resolve
                  with
                  | Ok () -> run process
                  | Error error -> Error (on_error error))
            in
            let cleanup =
              Native_outcome.capture (fun () ->
                  Native_outcome.resolve (close t process))
            in
            resolve ~on_error primary cleanup)

  let path_error = function
    | Workspace_manager.Invalid_key error
    | Workspace_manager.Unsafe_path error
    | Workspace_manager.Ownership_conflict error
    | Workspace_manager.Filesystem_error error
    | Workspace_manager.Hook_failed error
    | Workspace_manager.Hook_timeout error -> error

  let with_process t ~cwd ~env ~command ~on_error run =
    Workspace_path_posix.with_child cwd
      ~on_error:(fun error -> on_error (path_error error))
      (fun ~sw cwd_fd ->
        launch t ~sw ~cwd:cwd_fd ~env ~command ~on_error (Path.display cwd) run)
end
