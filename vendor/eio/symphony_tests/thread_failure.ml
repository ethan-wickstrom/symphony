let message = "Thread.create: Resource temporarily unavailable (fixture)"
let origin = "Raised at Eio_unix__Thread_pool.Free_pool.make_thread"
let finalizer = ref false
let release = ref false
let backtrace = ref false
let io_error = ref false

let remember_trace () =
  backtrace :=
    Printexc.get_backtrace () |> String.split_on_char '\n'
    |> List.exists (String.starts_with ~prefix:origin)

let () =
  Printexc.record_backtrace true;
  Eio_unix.Private.Thread_pool.Fixture.arm ();
  let outcome =
    match
      Eio_posix.run (fun _ ->
          Eio.Switch.run (fun sw ->
              Eio.Switch.on_release sw (fun () -> release := true);
              Fun.protect
                ~finally:(fun () -> finalizer := true)
                (fun () -> Eio_unix.run_in_systhread (fun () -> ()))))
    with
    | () -> "returned"
    | exception
        Eio.Io
          ( Eio.Exn.Not_available
              (Eio_unix.Private.Thread_pool.Worker_unavailable error),
            _ ) ->
        remember_trace ();
        io_error := true;
        error
    | exception Sys_error error ->
        remember_trace ();
        error
    | exception ex -> Printexc.to_string ex
  in
  Printf.printf
    "original_error=%b original_backtrace=%b io_error=%b caller_finalizer=%b \
     switch_release=%b\n\
     %!"
    (String.equal outcome message)
    !backtrace !io_error !finalizer !release;
  if
    not
      (String.equal outcome message
      && !backtrace && !io_error && !finalizer && !release)
  then exit 1
