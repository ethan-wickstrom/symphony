module Port = struct
  module Pure = Clock.Pure

  type t = {
    observe : unit -> (Pure.instant, Diagnostic.t) result;
    wait : Pure.instant -> (unit, Diagnostic.t) result;
  }

  let now clock = clock.observe ()
  let sleep_until clock due = clock.wait due
  let sample _ = failwith "deadline must not sample wall time"
end

module Run = Deadline.Make (Port)

type error = Semantic of unit ref | Mapped of Diagnostic.t | Timed_out

let checked = function
  | Ok value -> value
  | Error message -> failwith message

let delay = checked (Milliseconds.parse "1000")
let start = Clock.Pure.of_nanoseconds Count.zero

let diagnostic =
  Diagnostic.make ~site:(Diagnostic.Host "deadline.fixture")
    ~message:"clock fixture unavailable" ~remedy:"repair fixture"

let ensure flag message = Alcotest.(check bool) message true flag
let mock action = Eio_mock.Backend.run action

let observe_error () =
  let called = ref false in
  let clock =
    Port.
      { observe = (fun () -> Error diagnostic); wait = (fun _ -> assert false) }
  in
  let result =
    Run.run clock ~delay
      ~on_error:(fun error -> Mapped error)
      ~on_timeout:(fun () -> assert false)
      (fun () ->
        called := true;
        Ok ())
  in
  ensure (not !called) "no action after clock failure";
  match result with
  | Error (Mapped error) ->
      ensure (error == diagnostic) "clock diagnostic identity"
  | Ok () | Error (Semantic _ | Timed_out) ->
      Alcotest.fail "wrong clock failure"

let action_error () =
  mock (fun () ->
      let timer_closed = ref false in
      let mapped = ref 0 in
      let pending, _ = Eio.Promise.create () in
      let clock =
        Port.
          {
            observe = (fun () -> Ok start);
            wait =
              (fun _ ->
                Fun.protect
                  ~finally:(fun () -> timer_closed := true)
                  (fun () -> Eio.Promise.await pending));
          }
      in
      let primary = Semantic (ref ()) in
      let result =
        Run.run clock ~delay
          ~on_error:(fun error ->
            incr mapped;
            Mapped error)
          ~on_timeout:(fun () ->
            incr mapped;
            Timed_out)
          (fun () ->
            Eio.Fiber.yield ();
            Error primary)
      in
      ensure !timer_closed "timer canceled and joined";
      Alcotest.(check int) "no losing mapper" 0 !mapped;
      match result with
      | Error error -> ensure (error == primary) "primary caller error retained"
      | Ok () -> Alcotest.fail "primary error lost")

let timer_wins expected =
  mock (fun () ->
      let action_closed = ref false in
      let pending, _ = Eio.Promise.create () in
      let clock =
        Port.
          {
            observe = (fun () -> Ok start);
            wait =
              (fun _ ->
                Eio.Fiber.yield ();
                expected);
          }
      in
      let mapper error =
        ensure !action_closed "action joined before mapping";
        Mapped error
      in
      let result =
        Run.run clock ~delay ~on_error:mapper
          ~on_timeout:(fun () ->
            ensure !action_closed "action joined before timeout";
            Timed_out)
          (fun () ->
            Fun.protect
              ~finally:(fun () -> action_closed := true)
              (fun () -> Eio.Promise.await pending))
      in
      match (expected, result) with
      | Ok (), Error Timed_out -> ()
      | Error before, Error (Mapped after) ->
          ensure (before == after) "timer diagnostic identity"
      | (Ok () | Error _), (Ok () | Error (Semantic _ | Mapped _ | Timed_out))
        -> Alcotest.fail "wrong winning timer result")

let defect_identity () =
  mock (fun () ->
      let timer_closed = ref false in
      let pending, _ = Eio.Promise.create () in
      let clock =
        Port.
          {
            observe = (fun () -> Ok start);
            wait =
              (fun _ ->
                Fun.protect
                  ~finally:(fun () -> timer_closed := true)
                  (fun () -> Eio.Promise.await pending));
          }
      in
      let defect = Failure "unique deadline callback defect" in
      let original = ref "" in
      let raise_original () =
        try raise defect
        with exn ->
          let trace = Printexc.get_raw_backtrace () in
          original := Printexc.raw_backtrace_to_string trace;
          Printexc.raise_with_backtrace exn trace
      in
      let caught =
        try
          let _ =
            Run.run clock ~delay
              ~on_error:(fun error -> Mapped error)
              ~on_timeout:(fun () -> Timed_out)
              (fun () ->
                Eio.Fiber.yield ();
                raise_original ())
          in
          None
        with exn -> Some (exn, Printexc.get_raw_backtrace ())
      in
      ensure !timer_closed "timer joined before defect escapes";
      match caught with
      | None -> Alcotest.fail "callback defect swallowed"
      | Some (exn, trace) ->
          ensure (exn == defect) "physical exception identity";
          let rendered = Printexc.raw_backtrace_to_string trace in
          ensure
            (!original <> "" && String.starts_with ~prefix:!original rendered)
            "original backtrace prefix")

let tests =
  [
    Alcotest.test_case "clock failure avoids action" `Quick observe_error;
    Alcotest.test_case "caller error survives joined timer" `Quick action_error;
    Alcotest.test_case "timeout maps after action join" `Quick (fun () ->
        timer_wins (Ok ()));
    Alcotest.test_case "timer error maps after action join" `Quick (fun () ->
        timer_wins (Error diagnostic));
    Alcotest.test_case "callback defect keeps identity and trace" `Quick
      defect_identity;
  ]
