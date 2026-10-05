type signal = Interrupt | Terminate

let wake_byte = "\000"

let rec wake fd =
  try ignore (Unix.write_substring fd wake_byte 0 1) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> wake fd
  | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()

let defect () =
  Diagnostic.make ~site:(Diagnostic.Host "shutdown signals")
    ~message:"Signal bridge cleanup failed."
    ~remedy:"Check the host signal and descriptor lifecycle."

let with_signal ~report run =
  let releases = ref [] in
  let own release = releases := release :: !releases in
  let deactivate = ref (fun () -> ()) in
  let body = ref None in
  let scope =
    Native_outcome.capture (fun () ->
        let input, output = Unix.pipe ~cloexec:true () in
        own (fun () -> Unix.close input);
        own (fun () -> Unix.close output);
        Unix.set_nonblock input;
        Unix.set_nonblock output;
        Eio.Switch.run (fun sw ->
            let first = ref None in
            let enabled = ref true in
            (deactivate := fun () -> enabled := false);
            let handle signal _ =
              if !enabled && Option.is_none !first then (
                first := Some signal;
                wake output)
            in
            let install number signal =
              let previous =
                Sys.signal number (Sys.Signal_handle (handle signal))
              in
              own (fun () -> Sys.set_signal number previous)
            in
            install Sys.sigint Interrupt;
            install Sys.sigterm Terminate;
            let signal, resolve = Eio.Promise.create () in
            Eio.Fiber.fork_daemon ~sw (fun () ->
                Eio_unix.await_readable input;
                match !first with
                | Some value ->
                    Eio.Promise.resolve resolve value;
                    `Stop_daemon
                | None -> invalid_arg "shutdown wakeup without a signal");
            body := Some (Native_outcome.capture (fun () -> run signal))))
  in
  (* Each release is attempted independently, under cancellation protection. *)
  let closed =
    Eio.Cancel.protect (fun () ->
        (* Disable captured handlers before restoration or descriptor close. *)
        !deactivate ();
        List.filter_map
          (fun release ->
            match Native_outcome.capture release with
            | Native_outcome.Returned () -> None
            | Native_outcome.Raised (error, trace) -> Some (error, trace))
          !releases)
  in
  let faults =
    match scope with
    | Native_outcome.Returned () -> closed
    | Native_outcome.Raised (error, trace) -> (error, trace) :: closed
  in
  let result =
    match !body with
    | Some value -> value
    | None -> (
        match scope with
        | Native_outcome.Raised (error, trace) ->
            Native_outcome.Raised (error, trace)
        | Native_outcome.Returned () ->
            invalid_arg "shutdown scope returned without invoking its callback")
  in
  let selected, secondary =
    match (result, faults) with
    | Native_outcome.Returned (Ok _), (error, trace) :: rest ->
        (Native_outcome.Raised (error, trace), rest)
    | Native_outcome.Returned (Ok _), [] -> (result, [])
    | Native_outcome.Returned (Error _), _ -> (result, faults)
    | Native_outcome.Raised _, _ ->
        (result, if Option.is_none !body then closed else faults)
  in
  let secondary =
    List.concat_map Eio_failure.leaves secondary
    |> List.filter (function
      | Eio.Cancel.Cancelled _, _ -> false
      | _ -> true)
  in
  List.iter
    (fun _ -> ignore (Native_outcome.capture (fun () -> report (defect ()))))
    secondary;
  Native_outcome.resolve selected
