type 'a outcome = Returned of 'a | Raised of exn * Printexc.raw_backtrace
type 'a primary = Pending | Captured of 'a outcome

type event =
  | Client_acquired
  | Primary_captured
  | Client_closing
  | Daemon_failed
  | Gate_released
  | Client_closed
  | Outer_closed
  | Boundary_returned

type 'a receipt = {
  outcome : 'a outcome;
  original : 'a outcome;
  daemon : exn;
  events : event list;
}

let deadline_seconds = 2.

let capture action =
  try Returned (action ())
  with error -> Raised (error, Printexc.get_raw_backtrace ())

let restore = function
  | Returned value -> value
  | Raised (error, bt) -> Printexc.raise_with_backtrace error bt

let ensure label value = Alcotest.check Alcotest.bool label true value

(* The client-like bracket saves its callback before protected cleanup. A later
   outer daemon failure cannot stop that cleanup or change its returned value. *)
let joined_client record closing release original action =
  let primary = ref Pending in
  let closure =
    capture (fun () ->
        Eio.Cancel.protect (fun () ->
            Eio.Switch.run (fun sw ->
                Eio.Switch.on_release sw (fun () ->
                    record Client_closing;
                    Eio.Promise.resolve closing ();
                    Eio.Promise.await release;
                    record Client_closed);
                record Client_acquired;
                let value = capture action in
                primary := Captured value;
                Eio.Promise.resolve original value;
                record Primary_captured)))
  in
  restore closure;
  match !primary with
  | Pending -> Alcotest.fail "Client callback was not entered"
  | Captured value -> restore value

let staged action =
  Eio_posix.run (fun env ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) deadline_seconds
        (fun () ->
          Eio.Switch.run (fun controllers ->
              let events = ref [] in
              let record event = events := event :: !events in
              let closing, closing_resolve = Eio.Promise.create () in
              let failed, failed_resolve = Eio.Promise.create () in
              let release, release_resolve = Eio.Promise.create () in
              let original, original_resolve = Eio.Promise.create () in
              let daemon = Failure "late outer daemon fault" in
              Eio.Fiber.fork ~sw:controllers (fun () ->
                  Fun.protect
                    ~finally:(fun () ->
                      record Gate_released;
                      Eio.Promise.resolve release_resolve ())
                    (fun () -> Eio.Promise.await failed));
              let outcome =
                capture (fun () ->
                    Native_scope.with_scope (fun owned ->
                        Eio.Switch.on_release owned (fun () ->
                            record Outer_closed);
                        Eio.Fiber.fork ~sw:owned (fun () ->
                            Eio.Promise.await closing;
                            record Daemon_failed;
                            Eio.Promise.resolve failed_resolve ();
                            raise daemon);
                        joined_client record closing_resolve release
                          original_resolve action))
              in
              record Boundary_returned;
              {
                outcome;
                original = Eio.Promise.await original;
                daemon;
                events = List.rev !events;
              })))

let joined receipt =
  ensure "client, controller and outer finalizers joined before return"
    (receipt.events
    = [
        Client_acquired;
        Primary_captured;
        Client_closing;
        Daemon_failed;
        Gate_released;
        Client_closed;
        Outer_closed;
        Boundary_returned;
      ])

let expected_error () =
  let error =
    Diagnostic.make ~site:(Diagnostic.Host "scope callback")
      ~message:"Expected callback failure" ~remedy:"Resolve the callback error"
  in
  let receipt = staged (fun () -> Error error) in
  joined receipt;
  match receipt.outcome with
  | Returned (Error observed) -> ensure "same checked error" (observed == error)
  | Returned (Ok _) -> Alcotest.fail "Callback error was changed to success"
  | Raised (ex, _) ->
      Alcotest.fail ("Callback error was lost: " ^ Printexc.to_string ex)

let original_raise original =
  Printexc.record_backtrace true;
  let receipt = staged (fun () -> raise original) in
  joined receipt;
  match (receipt.original, receipt.outcome) with
  | Raised (_, original_bt), Raised (observed, bt) ->
      ensure "physical exception survives closure" (observed == original);
      let original_trace = Printexc.raw_backtrace_to_string original_bt in
      let trace = Printexc.raw_backtrace_to_string bt in
      ensure "original backtrace exists" (String.length original_trace > 0);
      ensure "original backtrace prefix survives"
        (String.starts_with ~prefix:original_trace trace)
  | Returned _, (Returned _ | Raised _) ->
      Alcotest.fail "Fixture did not capture the original exception"
  | Raised _, Returned _ -> Alcotest.fail "Callback exception became a value"

let callback_defect () = original_raise (Failure "original callback defect")

let callback_cancellation () =
  original_raise (Eio.Cancel.Cancelled (Failure "original caller cancellation"))

let success_closure_fault () =
  let receipt = staged (fun () -> Ok 7) in
  joined receipt;
  match receipt.outcome with
  | Raised (observed, bt) ->
      ensure "successful callback exposes original closure fault"
        (observed == receipt.daemon);
      ensure "closure fault retains backtrace"
        (Printexc.raw_backtrace_length bt > 0)
  | Returned _ -> Alcotest.fail "Successful callback hid the closure fault"

let success_identity () =
  Eio_posix.run (fun _ ->
      let value = ref 7 in
      match Native_scope.with_scope (fun _ -> Ok value) with
      | Ok observed -> ensure "success keeps value identity" (observed == value)
      | Error _ -> Alcotest.fail "Successful scope was rejected")

let parked_callback () =
  Printexc.record_backtrace true;
  Eio_posix.run (fun env ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) deadline_seconds
        (fun () ->
          Eio.Switch.run (fun controllers ->
              let events = ref [] in
              let record event = events := event :: !events in
              let entered, entered_resolve = Eio.Promise.create () in
              let closing, closing_resolve = Eio.Promise.create () in
              let release, release_resolve = Eio.Promise.create () in
              let parked, _ = Eio.Promise.create () in
              let original =
                Failure "original daemon before callback outcome"
              in
              Eio.Fiber.fork ~sw:controllers (fun () ->
                  Fun.protect
                    ~finally:(fun () ->
                      record Gate_released;
                      Eio.Promise.resolve release_resolve ())
                    (fun () -> Eio.Promise.await closing));
              let outcome =
                capture (fun () ->
                    Native_scope.with_scope (fun owned ->
                        Eio.Switch.on_release owned (fun () ->
                            record Outer_closed);
                        Eio.Fiber.fork ~sw:owned (fun () ->
                            Eio.Promise.await entered;
                            record Daemon_failed;
                            raise original);
                        Eio.Switch.run (fun client ->
                            Eio.Switch.on_release client (fun () ->
                                Eio.Cancel.protect (fun () ->
                                    record Client_closing;
                                    Eio.Promise.resolve closing_resolve ();
                                    Eio.Promise.await release;
                                    record Client_closed));
                            record Client_acquired;
                            Eio.Promise.resolve entered_resolve ();
                            Eio.Promise.await parked)))
              in
              record Boundary_returned;
              ensure "daemon-first cancellation joins the parked callback"
                (List.rev !events
                = [
                    Client_acquired;
                    Daemon_failed;
                    Client_closing;
                    Gate_released;
                    Client_closed;
                    Outer_closed;
                    Boundary_returned;
                  ]);
              match outcome with
              | Raised (observed, bt) ->
                  ensure "induced callback cancellation keeps original daemon"
                    (observed == original);
                  ensure "daemon backtrace survives callback cancellation"
                    (Printexc.raw_backtrace_length bt > 0)
              | Returned _ ->
                  Alcotest.fail "Parked callback hid its daemon failure")))

let tests =
  [
    Alcotest.test_case "expected error survives later daemon and joined client"
      `Quick expected_error;
    Alcotest.test_case "original callback exception survives joined cleanup"
      `Quick callback_defect;
    Alcotest.test_case "cancellation remains the original exception" `Quick
      callback_cancellation;
    Alcotest.test_case "successful callback exposes closure failure" `Quick
      success_closure_fault;
    Alcotest.test_case "successful scope preserves its value" `Quick
      success_identity;
    Alcotest.test_case
      "daemon-first fault survives parked callback cancellation" `Quick
      parked_callback;
  ]
