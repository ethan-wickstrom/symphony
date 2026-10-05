exception Callback_defect of string

module Drain_clock = struct
  module Pure = Clock.Pure

  type t = (unit, Diagnostic.t) result Eio.Promise.t

  let now _ = Ok (Pure.of_nanoseconds Count.zero)
  let sleep_until pending _ = Eio.Promise.await pending
  let sample _ = failwith "shutdown flush must not sample wall time"
end

module Output = Native_output.Make (Drain_clock)

module Held_sink = struct
  type t = {
    bytes : Buffer.t;
    entered : unit Eio.Promise.u;
    release : unit Eio.Promise.t;
  }

  let single_write sink buffers =
    Eio.Promise.resolve sink.entered ();
    Eio.Promise.await sink.release;
    List.iter
      (fun buffer -> Buffer.add_string sink.bytes (Cstruct.to_string buffer))
      buffers;
    List.fold_left
      (fun length buffer -> length + Cstruct.length buffer)
      0 buffers

  let copy sink ~src = Eio.Flow.Pi.simple_copy ~single_write sink ~src
end

let signal_cycles = 24
let ignore_report _ = ()

let successful = function
  | Ok () -> ()
  | Error error -> Alcotest.fail (Diagnostic.render error)

let fd_count () =
  let directory = Unix.opendir "/dev/fd" in
  Fun.protect
    ~finally:(fun () -> Unix.closedir directory)
    (fun () ->
      let rec count total =
        match Unix.readdir directory with
        | "." | ".." -> count total
        | _ -> count (total + 1)
        | exception End_of_file -> total
      in
      count 0)

let with_handlers use =
  let seen = ref [] in
  let handler signal = seen := signal :: !seen in
  let interrupt = Sys.signal Sys.sigint (Sys.Signal_handle handler) in
  Fun.protect
    ~finally:(fun () -> Sys.set_signal Sys.sigint interrupt)
    (fun () ->
      let terminate = Sys.signal Sys.sigterm (Sys.Signal_handle handler) in
      Fun.protect
        ~finally:(fun () -> Sys.set_signal Sys.sigterm terminate)
        (fun () -> use seen))

let restored seen =
  Unix.kill (Unix.getpid ()) Sys.sigint;
  Eio.Fiber.yield ();
  Unix.kill (Unix.getpid ()) Sys.sigterm;
  Eio.Fiber.yield ();
  Alcotest.(check (list int))
    "original handlers restored"
    [ Sys.sigterm; Sys.sigint ]
    !seen

let received number expected () =
  Eio_posix.run (fun _ ->
      with_handlers (fun seen ->
          successful
            (Native_shutdown.with_signal ~report:ignore_report (fun signal ->
                 Unix.kill (Unix.getpid ()) number;
                 let actual = Eio.Promise.await signal in
                 Alcotest.(check bool)
                   "shutdown signal received" true (actual = expected);
                 Ok ()));
          restored seen))

let coalesced () =
  Eio_posix.run (fun _ ->
      with_handlers (fun seen ->
          successful
            (Native_shutdown.with_signal ~report:ignore_report (fun signal ->
                 Unix.kill (Unix.getpid ()) Sys.sigint;
                 let first = Eio.Promise.await signal in
                 Unix.kill (Unix.getpid ()) Sys.sigint;
                 Unix.kill (Unix.getpid ()) Sys.sigterm;
                 Eio.Fiber.yield ();
                 Alcotest.(check bool)
                   "first signal remains authoritative" true
                   (first = Native_shutdown.Interrupt
                   && Eio.Promise.peek signal = Some first);
                 Alcotest.(check (list int))
                   "old handlers remain suspended" [] !seen;
                 Ok ()));
          restored seen))

let rejected () =
  Eio_posix.run (fun _ ->
      with_handlers (fun seen ->
          let primary =
            Diagnostic.make ~site:(Diagnostic.Host "signal test")
              ~message:"Callback rejected the host."
              ~remedy:"Retain this exact diagnostic after closure."
          in
          let before = fd_count () in
          let result =
            Native_shutdown.with_signal ~report:ignore_report (fun _ ->
                Error primary)
          in
          (match result with
          | Error error ->
              Alcotest.(check bool)
                "callback diagnostic identity" true (error == primary)
          | Ok () -> Alcotest.fail "callback rejection was lost");
          Alcotest.(check int)
            "descriptors closed after rejection" before (fd_count ());
          restored seen))

let raise_callback error = raise error

let defect () =
  Eio_posix.run (fun _ ->
      with_handlers (fun seen ->
          let primary = Callback_defect "signal callback" in
          let before = fd_count () in
          (match
             Native_shutdown.with_signal ~report:ignore_report (fun _ ->
                 raise_callback primary)
           with
          | Ok () | Error _ -> Alcotest.fail "callback defect was lost"
          | exception error ->
              let trace = Printexc.get_raw_backtrace () in
              Alcotest.(check bool)
                "callback exception identity" true (error == primary);
              Alcotest.(check bool)
                "original callback backtrace" true
                (Printexc.raw_backtrace_length trace > 0));
          Alcotest.(check int)
            "descriptors closed after defect" before (fd_count ());
          restored seen))

let external_cancel () =
  Eio_posix.run (fun _ ->
      with_handlers (fun seen ->
          Eio.Switch.run (fun sw ->
              let ready, start = Eio.Promise.create () in
              let context, store = Eio.Promise.create () in
              let pending, _ = Eio.Promise.create () in
              let closing, close = Eio.Promise.create () in
              let release, resume = Eio.Promise.create () in
              let finished, finish = Eio.Promise.create () in
              let original = ref None in
              let reports = ref [] in
              let callback_closed = ref false in
              let cause = Failure "unique signal owner cancellation" in
              let before = fd_count () in
              Eio.Fiber.fork ~sw (fun () ->
                  let observed =
                    try
                      `Returned
                        (Eio.Cancel.sub (fun cancel ->
                             Eio.Promise.resolve store cancel;
                             Native_shutdown.with_signal
                               ~report:(fun error ->
                                 reports := error :: !reports)
                               (fun _ ->
                                 Fun.protect
                                   ~finally:(fun () ->
                                     Eio.Cancel.protect (fun () ->
                                         Eio.Promise.resolve close ();
                                         Eio.Promise.await release);
                                     callback_closed := true)
                                   (fun () ->
                                     Eio.Promise.resolve start ();
                                     try
                                       Eio.Promise.await pending;
                                       Ok ()
                                     with error ->
                                       let trace =
                                         Printexc.get_raw_backtrace ()
                                       in
                                       original := Some (error, trace);
                                       Printexc.raise_with_backtrace error trace))))
                    with error ->
                      `Raised (error, Printexc.get_raw_backtrace ())
                  in
                  Eio.Promise.resolve finish observed);
              let cancel = Eio.Promise.await context in
              Eio.Promise.await ready;
              Eio.Cancel.cancel cancel cause;
              Eio.Promise.await closing;
              Alcotest.(check bool)
                "callback finalizer must finish before return" true
                (Eio.Promise.peek finished = None);
              Eio.Promise.resolve resume ();
              let observed = Eio.Promise.await finished in
              Alcotest.(check bool)
                "callback finalizer joined" true !callback_closed;
              (match (observed, !original) with
              | `Raised (error, trace), Some (first, first_trace) -> (
                  Alcotest.(check bool)
                    "original cancellation identity" true (error == first);
                  Alcotest.(check bool)
                    "original cancellation backtrace" true
                    (String.starts_with
                       ~prefix:(Printexc.raw_backtrace_to_string first_trace)
                       (Printexc.raw_backtrace_to_string trace));
                  match error with
                  | Eio.Cancel.Cancelled actual ->
                      Alcotest.(check bool)
                        "original cancellation cause" true (actual == cause)
                  | _ -> Alcotest.fail "external cancellation was replaced")
              | `Returned _, _ | `Raised _, None ->
                  Alcotest.fail
                    "external cancellation became a signal diagnostic");
              Alcotest.(check int)
                "external cancellation reports no cleanup fault" 0
                (List.length !reports);
              Alcotest.(check int)
                "canceled scope closes descriptors" before (fd_count ());
              restored seen)))

let held_flush_signals () =
  Eio_posix.run (fun _ ->
      with_handlers (fun seen ->
          Eio.Switch.run (fun sw ->
              let entered, enter = Eio.Promise.create () in
              let release, resume = Eio.Promise.create () in
              let pending, _ = Eio.Promise.create () in
              let selected, store = Eio.Promise.create () in
              let bytes = Buffer.create 64 in
              let reports = ref [] in
              let state = Held_sink.{ bytes; entered = enter; release } in
              let sink =
                Eio.Resource.T (state, Eio.Flow.Pi.sink (module Held_sink))
              in
              let before = fd_count () in
              Eio.Fiber.fork ~sw (fun () ->
                  let signal = Eio.Promise.await selected in
                  Eio.Promise.await entered;
                  (* Keep the signal bracket active until final output drainage. *)
                  Unix.kill (Unix.getpid ()) Sys.sigint;
                  Unix.kill (Unix.getpid ()) Sys.sigterm;
                  Eio.Fiber.yield ();
                  Alcotest.(check (list int))
                    "old handlers remain suspended during flush" [] !seen;
                  Alcotest.(check bool)
                    "duplicate signal retains original shutdown" true
                    (Eio.Promise.peek signal = Some Native_shutdown.Interrupt);
                  Alcotest.(check int)
                    "last record is held during duplicate signals" 0
                    (Buffer.length bytes);
                  Eio.Promise.resolve resume ());
              Native_shutdown.with_signal
                ~report:(fun error -> reports := error :: !reports)
                (fun signal ->
                  Eio.Promise.resolve store signal;
                  Output.with_output ~clock:pending ~sink (fun output ->
                      Unix.kill (Unix.getpid ()) Sys.sigint;
                      ignore (Eio.Promise.await signal : Native_shutdown.signal);
                      Output.emit output ~event:"shutdown" [];
                      Ok ()))
              |> successful;
              Alcotest.(check string)
                "held final record drains exactly once" "event=shutdown\n"
                (Buffer.contents bytes);
              Alcotest.(check int)
                "duplicate signals report no cleanup fault" 0
                (List.length !reports);
              Alcotest.(check int)
                "flush completes before descriptors close" before (fd_count ());
              restored seen)))

let repeated () =
  Eio_posix.run (fun _ ->
      with_handlers (fun seen ->
          let before = fd_count () in
          for _ = 1 to signal_cycles do
            successful
              (Native_shutdown.with_signal ~report:ignore_report (fun signal ->
                   Unix.kill (Unix.getpid ()) Sys.sigterm;
                   ignore (Eio.Promise.await signal : Native_shutdown.signal);
                   Ok ()))
          done;
          Alcotest.(check int)
            "repeated scopes retain no descriptors" before (fd_count ());
          restored seen))

let tests =
  [
    Alcotest.test_case "SIGINT closes then restores handlers" `Quick
      (received Sys.sigint Native_shutdown.Interrupt);
    Alcotest.test_case "SIGTERM closes then restores handlers" `Quick
      (received Sys.sigterm Native_shutdown.Terminate);
    Alcotest.test_case "signals coalesce through closure" `Quick coalesced;
    Alcotest.test_case "callback rejection survives closure" `Quick rejected;
    Alcotest.test_case "callback defect survives closure" `Quick defect;
    Alcotest.test_case "external cancellation closes before escaping" `Quick
      external_cancel;
    Alcotest.test_case
      "duplicate signals remain coalesced during final output flush" `Quick
      held_flush_signals;
    Alcotest.test_case "repeated scopes close actual descriptors" `Quick
      repeated;
  ]
