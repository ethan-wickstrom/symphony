module Port = struct
  module Pure = Clock.Pure

  type t = {
    observe : unit -> (Pure.instant, Diagnostic.t) result;
    wait : Pure.instant -> (unit, Diagnostic.t) result;
  }

  let now clock = clock.observe ()
  let sleep_until clock due = clock.wait due
  let sample _ = failwith "output must not sample wall time"
end

module Output = Native_output.Make (Port)

module Sink = struct
  type t = { bytes : Buffer.t; before_write : unit -> unit }

  let single_write sink buffers =
    sink.before_write ();
    List.iter
      (fun buffer -> Buffer.add_string sink.bytes (Cstruct.to_string buffer))
      buffers;
    List.fold_left
      (fun length buffer -> length + Cstruct.length buffer)
      0 buffers

  let copy sink ~src = Eio.Flow.Pi.simple_copy ~single_write sink ~src
end

type fault = Write_fault | Unwind_fault
type 'a outcome = Returned of 'a | Raised of exn * Printexc.raw_backtrace

let capture action =
  try Returned (action ())
  with error -> Raised (error, Printexc.get_raw_backtrace ())

let record_limit = 4096
let queue_limit = 1_048_576

let flush_delay =
  match Milliseconds.parse "1000" with
  | Ok delay -> delay
  | Error message -> failwith message

let start = Clock.Pure.of_nanoseconds Count.zero
let full_prefix = "event=bound value="
let full_value = String.make (record_limit - String.length full_prefix - 1) 'x'
let full_record = full_prefix ^ full_value ^ "\n"
let queue_records = queue_limit / record_limit
let ensure flag message = Alcotest.(check bool) message true flag
let mock action = Eio_mock.Backend.run action
let clock wait = Port.{ observe = (fun () -> Ok start); wait }

let held_clock () =
  let pending, _ = Eio.Promise.create () in
  clock (fun _ -> Eio.Promise.await pending)

let sink before_write =
  let state = Sink.{ bytes = Buffer.create record_limit; before_write } in
  (state, Eio.Resource.T (state, Eio.Flow.Pi.sink (module Sink)))

let successful = function
  | Ok () -> ()
  | Error error -> Alcotest.fail (Diagnostic.render error)

let contains text fragment =
  let last = String.length text - String.length fragment in
  let rec scan index =
    if index > last then false
    else if String.sub text index (String.length fragment) = fragment then true
    else scan (index + 1)
  in
  scan 0

let redacted = function
  | Ok () -> Alcotest.fail "output fault was ignored"
  | Error error ->
      let rendered = Diagnostic.render error in
      ensure (rendered <> "") "output fault has a diagnostic";
      ensure
        (not (contains rendered "secret"))
        "private sink payload is redacted"

let emit_full output =
  Output.emit output ~event:"bound" [ ("value", full_value) ]

let queued_fifo () =
  mock (fun () ->
      let entered, enter = Eio.Promise.create () in
      let release, resume = Eio.Promise.create () in
      let state, destination =
        sink (fun () ->
            if not (Eio.Promise.is_resolved entered) then (
              Eio.Promise.resolve enter ();
              Eio.Promise.await release))
      in
      let result =
        Output.with_output ~clock:(held_clock ()) ~sink:destination
          (fun output ->
            Output.emit output ~event:"ready"
              [
                ("issue", "A B");
                ("path", "x=y\\z");
                ("bytes", "\000\n\r\t\127\195\169");
              ];
            Eio.Promise.await entered;
            (* Publications continue while the first sink write is held. *)
            Output.emit output ~event:"next" [];
            Output.emit output ~event:"final" [ ("value", "plain-_.") ];
            Alcotest.(check int)
              "held sink has not consumed a record" 0
              (Buffer.length state.Sink.bytes);
            Eio.Promise.resolve resume ();
            Ok ())
      in
      successful result;
      Alcotest.(check string)
        "FIFO, byte escaping, and one physical line per event"
        ("event=ready issue=A\\x20B path=x\\x3dy\\x5cz"
       ^ " bytes=\\x00\\x0a\\x0d\\x09\\x7f\\xc3\\xa9\n"
       ^ "event=next\nevent=final value=plain-_.\n")
        (Buffer.contents state.Sink.bytes))

let full_queue () =
  mock (fun () ->
      let entered, enter = Eio.Promise.create () in
      let release, resume = Eio.Promise.create () in
      let state, destination =
        sink (fun () ->
            if not (Eio.Promise.is_resolved entered) then (
              Eio.Promise.resolve enter ();
              Eio.Promise.await release))
      in
      let result =
        Output.with_output ~clock:(held_clock ()) ~sink:destination
          (fun output ->
            emit_full output;
            Eio.Promise.await entered;
            for _ = 2 to queue_records do
              emit_full output
            done;
            Eio.Promise.resolve resume ();
            Ok ())
      in
      successful result;
      Alcotest.(check int)
        "in-flight and queued records fill the documented bound" queue_limit
        (Buffer.length state.Sink.bytes);
      Alcotest.(check string)
        "full queue drains without dropped records"
        (String.concat "" (List.init queue_records (fun _ -> full_record)))
        (Buffer.contents state.Sink.bytes))

let overflow () =
  mock (fun () ->
      let entered, enter = Eio.Promise.create () in
      let pending, _ = Eio.Promise.create () in
      let unwound = ref false in
      let accepted = ref 0 in
      let state, destination =
        sink (fun () ->
            Fun.protect
              ~finally:(fun () -> unwound := true)
              (fun () ->
                Eio.Promise.resolve enter ();
                Eio.Promise.await pending))
      in
      let result =
        Output.with_output
          ~clock:(clock (fun _ -> Ok ()))
          ~sink:destination
          (fun output ->
            emit_full output;
            incr accepted;
            Eio.Promise.await entered;
            for _ = 2 to queue_records + 1 do
              emit_full output;
              incr accepted
            done;
            Ok ())
      in
      redacted result;
      Alcotest.(check int)
        "overflow cannot admit another in-flight-sized record" queue_records
        !accepted;
      ensure !unwound "overflow joins the held writer";
      Alcotest.(check int)
        "no record silently escapes a failed held writer" 0
        (Buffer.length state.Sink.bytes))

let rejected_record event fields =
  mock (fun () ->
      let state, destination = sink (fun () -> ()) in
      let result =
        Output.with_output ~clock:(held_clock ()) ~sink:destination
          (fun output ->
            Output.emit output ~event fields;
            Ok ())
      in
      redacted result;
      Alcotest.(check int)
        "rejected record never reaches the sink" 0
        (Buffer.length state.Sink.bytes))

let invalid_records () =
  List.iter
    (fun (event, fields) -> rejected_record event fields)
    [
      ("", []);
      ("bad event", []);
      ("ready", [ ("bad=key", "secret") ]);
      ("ready", [ ("event", "secret") ]);
      ("ready", [ ("key", "first"); ("key", "secret") ]);
      ("bound", [ ("value", full_value ^ "x") ]);
      ("bound", [ ("value", String.make record_limit '\n') ]);
    ]

let writer_failure () =
  mock (fun () ->
      Eio.Switch.run (fun sw ->
          let entered, enter = Eio.Promise.create () in
          let fail, trigger = Eio.Promise.create () in
          let pending, _ = Eio.Promise.create () in
          let closing, close = Eio.Promise.create () in
          let release, resume = Eio.Promise.create () in
          let finished, finish = Eio.Promise.create () in
          let callback_closed = ref false in
          let _, destination =
            sink (fun () ->
                Eio.Promise.resolve enter ();
                Eio.Promise.await fail;
                raise
                  (Unix.Unix_error
                     (Unix.EPIPE, "secret-operation", "secret-path")))
          in
          Eio.Fiber.fork ~sw (fun () ->
              let result =
                Output.with_output ~clock:(held_clock ()) ~sink:destination
                  (fun output ->
                    Fun.protect
                      ~finally:(fun () ->
                        Eio.Cancel.protect (fun () ->
                            Eio.Promise.resolve close ();
                            Eio.Promise.await release;
                            callback_closed := true))
                      (fun () ->
                        Output.emit output ~event:"ready" [];
                        Eio.Promise.await entered;
                        Eio.Promise.resolve trigger ();
                        Eio.Promise.await pending))
              in
              Eio.Promise.resolve finish result);
          Eio.Promise.await closing;
          ensure
            (not (Eio.Promise.is_resolved finished))
            "writer failure waits for callback cleanup";
          Eio.Promise.resolve resume ();
          let result = Eio.Promise.await finished in
          ensure !callback_closed "callback is joined before diagnostic returns";
          redacted result))

let caught_rejection () =
  mock (fun () ->
      let pending, _ = Eio.Promise.create () in
      let callback_closed = ref false in
      let state, destination = sink (fun () -> ()) in
      let result =
        Output.with_output ~clock:(held_clock ()) ~sink:destination
          (fun output ->
            Fun.protect
              ~finally:(fun () -> callback_closed := true)
              (fun () ->
                (match
                   capture (fun () -> Output.emit output ~event:"bad event" [])
                 with
                | Raised _ -> ()
                | Returned () -> Alcotest.fail "invalid event was accepted");
                (* A caught publication fault must still wake the scope owner. *)
                Eio.Promise.await pending))
      in
      redacted result;
      ensure !callback_closed
        "caught rejection interrupts and joins the callback";
      Alcotest.(check int)
        "caught rejection never writes an invalid record" 0
        (Buffer.length state.Sink.bytes))

let slow_flush () =
  mock (fun () ->
      Eio.Switch.run (fun sw ->
          let entered, enter = Eio.Promise.create () in
          let pending, _ = Eio.Promise.create () in
          let timer, started = Eio.Promise.create () in
          let expire, finish_timer = Eio.Promise.create () in
          let unwound = ref false in
          let _, destination =
            sink (fun () ->
                Fun.protect
                  ~finally:(fun () -> unwound := true)
                  (fun () ->
                    Eio.Promise.resolve enter ();
                    Eio.Promise.await pending))
          in
          let exact_clock =
            clock (fun due ->
                Eio.Promise.resolve started due;
                Eio.Promise.await expire)
          in
          Eio.Fiber.fork ~sw (fun () ->
              let due = Eio.Promise.await timer in
              ensure
                (Clock.Pure.compare due (Clock.Pure.after start flush_delay) = 0)
                "flush uses the supplied exact clock and documented delay";
              Eio.Promise.resolve finish_timer (Ok ()));
          let result =
            Output.with_output ~clock:exact_clock ~sink:destination
              (fun output ->
                Output.emit output ~event:"ready" [];
                Eio.Promise.await entered;
                Ok ())
          in
          redacted result;
          ensure !unwound "expired flush cancels and joins the writer"))

let run_fault fault callback =
  let entered, enter = Eio.Promise.create () in
  let release, resume = Eio.Promise.create () in
  let pending, _ = Eio.Promise.create () in
  let unwound = ref false in
  let _, destination =
    sink (fun () ->
        Eio.Promise.resolve enter ();
        match fault with
        | Write_fault ->
            Eio.Cancel.protect (fun () ->
                Eio.Promise.await release;
                unwound := true;
                raise
                  (Unix.Unix_error
                     (Unix.EPIPE, "secret-operation", "secret-path")))
        | Unwind_fault ->
            Fun.protect
              ~finally:(fun () ->
                unwound := true;
                failwith "secret writer unwind defect")
              (fun () -> Eio.Promise.await pending))
  in
  let exact_clock =
    match fault with
    | Write_fault -> held_clock ()
    | Unwind_fault -> clock (fun _ -> Ok ())
  in
  let observed =
    capture (fun () ->
        Output.with_output ~clock:exact_clock ~sink:destination (fun output ->
            Output.emit output ~event:"ready" [];
            Eio.Promise.await entered;
            (match fault with
            | Write_fault -> Eio.Promise.resolve resume ()
            | Unwind_fault -> ());
            callback ()))
  in
  ensure !unwound "secondary writer fault is joined";
  observed

let primary_error fault () =
  mock (fun () ->
      let primary =
        Diagnostic.make ~site:(Diagnostic.Host "output.fixture")
          ~message:"primary callback rejection" ~remedy:"repair callback"
      in
      match run_fault fault (fun () -> Error primary) with
      | Returned (Error observed) ->
          ensure (observed == primary)
            "callback Error retains physical identity"
      | Returned (Ok ()) | Raised _ ->
          Alcotest.fail "secondary writer fault replaced callback Error")

let[@inline never] raise_original primary original =
  try raise primary
  with exn ->
    let trace = Printexc.get_raw_backtrace () in
    original := Printexc.raw_backtrace_to_string trace;
    Printexc.raise_with_backtrace exn trace

let check_defect primary original = function
  | Raised (observed, trace) ->
      ensure (observed == primary) "defect retains physical identity";
      ensure
        (!original <> ""
        && String.starts_with ~prefix:!original
             (Printexc.raw_backtrace_to_string trace))
        "defect retains original backtrace prefix"
  | Returned _ -> Alcotest.fail "unexpected defect became an output diagnostic"

let primary_defect fault () =
  mock (fun () ->
      let primary = Failure "unique output callback defect" in
      let original = ref "" in
      run_fault fault (fun () -> raise_original primary original)
      |> check_defect primary original)

let writer_defect () =
  mock (fun () ->
      Eio.Switch.run (fun sw ->
          let entered, enter = Eio.Promise.create () in
          let fail, trigger = Eio.Promise.create () in
          let pending, _ = Eio.Promise.create () in
          let closing, close = Eio.Promise.create () in
          let release, resume = Eio.Promise.create () in
          let finished, finish = Eio.Promise.create () in
          let callback_closed = ref false in
          let primary = Failure "unique unexpected writer defect" in
          let original = ref "" in
          let _, destination =
            sink (fun () ->
                Eio.Promise.resolve enter ();
                Eio.Promise.await fail;
                raise_original primary original)
          in
          Eio.Fiber.fork ~sw (fun () ->
              let observed =
                capture (fun () ->
                    Output.with_output ~clock:(held_clock ()) ~sink:destination
                      (fun output ->
                        Fun.protect
                          ~finally:(fun () ->
                            Eio.Cancel.protect (fun () ->
                                Eio.Promise.resolve close ();
                                Eio.Promise.await release;
                                callback_closed := true))
                          (fun () ->
                            Output.emit output ~event:"ready" [];
                            Eio.Promise.await entered;
                            Eio.Promise.resolve trigger ();
                            Eio.Promise.await pending)))
              in
              Eio.Promise.resolve finish observed);
          Eio.Promise.await closing;
          ensure
            (not (Eio.Promise.is_resolved finished))
            "unexpected writer defect waits for callback cleanup";
          Eio.Promise.resolve resume ();
          let observed = Eio.Promise.await finished in
          ensure !callback_closed "callback joins before writer defect escapes";
          check_defect primary original observed))

let run_flush wait =
  mock (fun () ->
      Eio.Switch.run (fun sw ->
          let entered, enter = Eio.Promise.create () in
          let pending, _ = Eio.Promise.create () in
          let timer, started = Eio.Promise.create () in
          let release, resume = Eio.Promise.create () in
          let writer_closed = ref false in
          let callback_closed = ref false in
          let _, destination =
            sink (fun () ->
                Fun.protect
                  ~finally:(fun () -> writer_closed := true)
                  (fun () ->
                    Eio.Promise.resolve enter ();
                    Eio.Promise.await pending))
          in
          let exact_clock =
            clock (fun due ->
                Eio.Promise.resolve started due;
                Eio.Promise.await release;
                wait ())
          in
          Eio.Fiber.fork ~sw (fun () ->
              let due = Eio.Promise.await timer in
              ensure
                (Clock.Pure.compare due (Clock.Pure.after start flush_delay) = 0)
                "faulting timer uses the supplied exact deadline";
              Eio.Promise.resolve resume ());
          let observed =
            capture (fun () ->
                Output.with_output ~clock:exact_clock ~sink:destination
                  (fun output ->
                    Fun.protect
                      ~finally:(fun () -> callback_closed := true)
                      (fun () ->
                        Output.emit output ~event:"ready" [];
                        Eio.Promise.await entered;
                        Ok ())))
          in
          ensure
            (!writer_closed && !callback_closed)
            "flush fault joins the successful callback and held writer";
          observed))

let flush_defect () =
  let primary = Failure "unique unexpected flush clock defect" in
  let original = ref "" in
  run_flush (fun () -> raise_original primary original)
  |> check_defect primary original

let flush_error () =
  let private_error =
    Diagnostic.make ~site:(Diagnostic.Host "secret clock source")
      ~message:"secret clock payload" ~remedy:"secret clock repair"
  in
  match run_flush (fun () -> Error private_error) with
  | Returned result -> redacted result
  | Raised _ -> Alcotest.fail "known clock Error became an exception"

let rejected_before_clock () =
  mock (fun () ->
      let clock_calls = ref 0 in
      let state, destination = sink (fun () -> ()) in
      let exact_clock =
        Port.
          {
            observe =
              (fun () ->
                incr clock_calls;
                failwith "secret flush clock must not run after rejection");
            wait =
              (fun _ -> Alcotest.fail "rejected output cannot start a timer");
          }
      in
      let result =
        Output.with_output ~clock:exact_clock ~sink:destination (fun output ->
            (match
               capture (fun () -> Output.emit output ~event:"invalid token" [])
             with
            | Raised _ -> ()
            | Returned () -> Alcotest.fail "invalid event was accepted");
            Ok ())
      in
      redacted result;
      Alcotest.(check int)
        "recorded rejection skips the flush clock" 0 !clock_calls;
      Alcotest.(check int)
        "rejected record was never written" 0
        (Buffer.length state.Sink.bytes))

let closing_record () =
  let release, resume = Eio.Promise.create () in
  let pending, _ = Eio.Promise.create () in
  let callback_closed = ref false in
  let state, destination = sink (fun () -> Eio.Promise.await release) in
  let exact_clock =
    Port.
      {
        observe =
          (fun () ->
            ensure !callback_closed "drain begins after callback return";
            Eio.Promise.resolve resume ();
            Ok start);
        wait = (fun _ -> Eio.Promise.await pending);
      }
  in
  (state, destination, exact_clock, callback_closed)

let error_record () =
  mock (fun () ->
      let state, destination, exact_clock, callback_closed =
        closing_record ()
      in
      let primary =
        Diagnostic.make ~site:(Diagnostic.Host "output callback")
          ~message:"Callback rejected startup."
          ~remedy:"Preserve this diagnostic."
      in
      let result =
        Output.with_output ~clock:exact_clock ~sink:destination (fun output ->
            Fun.protect
              ~finally:(fun () -> callback_closed := true)
              (fun () ->
                Output.emit output ~event:"startup_error" [];
                Alcotest.(check int)
                  "record remains queued before callback return" 0
                  (Buffer.length state.Sink.bytes);
                Error primary))
      in
      (match result with
      | Error error ->
          ensure (error == primary) "callback diagnostic identity retained"
      | Ok () -> Alcotest.fail "callback diagnostic was lost");
      Alcotest.(check string)
        "callback rejection record flushes before return"
        "event=startup_error\n"
        (Buffer.contents state.Sink.bytes))

let defect_record () =
  mock (fun () ->
      let state, destination, exact_clock, callback_closed =
        closing_record ()
      in
      let primary = Failure "unique queued callback defect" in
      let original = ref "" in
      capture (fun () ->
          Output.with_output ~clock:exact_clock ~sink:destination (fun output ->
              Fun.protect
                ~finally:(fun () -> callback_closed := true)
                (fun () ->
                  Output.emit output ~event:"host_failure" [];
                  Alcotest.(check int)
                    "record remains queued before callback defect" 0
                    (Buffer.length state.Sink.bytes);
                  raise_original primary original)))
      |> check_defect primary original;
      Alcotest.(check string)
        "callback defect record flushes before return" "event=host_failure\n"
        (Buffer.contents state.Sink.bytes))

let io_before_hook_defect () =
  mock (fun () ->
      let parked, park = Eio.Promise.create () in
      let callback_closed = ref false in
      let writer_closed = ref false in
      let hook_called = ref false in
      let marker = Failure "secret cancellation hook defect" in
      let original = ref "" in
      let _, destination =
        sink (fun () ->
            Fun.protect
              ~finally:(fun () -> writer_closed := true)
              (fun () ->
                Eio.Promise.await parked;
                raise
                  (Unix.Unix_error
                     (Unix.EPIPE, "secret-operation", "secret-path"))))
      in
      let result =
        Output.with_output ~clock:(held_clock ()) ~sink:destination
          (fun output ->
            Fun.protect
              ~finally:(fun () -> callback_closed := true)
              (fun () ->
                Output.emit output ~event:"ready" [];
                (* The provider resumes cancellation before throwing its own defect. *)
                Eio.Private.Suspend.enter "output cancellation fixture"
                  (fun context enqueue ->
                    Eio.Private.Fiber_context.set_cancel_fn context
                      (fun canceled ->
                        enqueue (Error canceled);
                        hook_called := true;
                        raise_original marker original);
                    Eio.Promise.resolve park ())))
      in
      ensure
        (!hook_called && !original <> "")
        "cancellation hook actually raised";
      ensure
        (!callback_closed && !writer_closed)
        "hook failure cannot prevent joins";
      redacted result)

let external_cancel () =
  mock (fun () ->
      Eio.Switch.run (fun sw ->
          let entered, enter = Eio.Promise.create () in
          let context, store = Eio.Promise.create () in
          let finished, finish = Eio.Promise.create () in
          let writer_pending, _ = Eio.Promise.create () in
          let body_pending, _ = Eio.Promise.create () in
          let writer_closed = ref false in
          let callback_closed = ref false in
          let original = ref None in
          let cause = Failure "unique external cancellation" in
          let _, destination =
            sink (fun () ->
                Fun.protect
                  ~finally:(fun () -> writer_closed := true)
                  (fun () ->
                    Eio.Promise.resolve enter ();
                    Eio.Promise.await writer_pending))
          in
          Eio.Fiber.fork ~sw (fun () ->
              let observed =
                capture (fun () ->
                    Eio.Cancel.sub (fun cancel ->
                        Eio.Promise.resolve store cancel;
                        Output.with_output ~clock:(held_clock ())
                          ~sink:destination (fun output ->
                            Fun.protect
                              ~finally:(fun () -> callback_closed := true)
                              (fun () ->
                                Output.emit output ~event:"ready" [];
                                try Eio.Promise.await body_pending
                                with error ->
                                  let trace = Printexc.get_raw_backtrace () in
                                  original := Some (error, trace);
                                  Printexc.raise_with_backtrace error trace))))
              in
              Eio.Promise.resolve finish observed);
          let cancel = Eio.Promise.await context in
          Eio.Promise.await entered;
          Eio.Cancel.cancel cancel cause;
          let observed = Eio.Promise.await finished in
          ensure
            (!writer_closed && !callback_closed)
            "external cancellation joins callback and writer";
          match (observed, !original) with
          | Raised (error, trace), Some (before, before_trace) -> (
              ensure (error == before)
                "external cancellation retains physical identity";
              ensure
                (String.starts_with
                   ~prefix:(Printexc.raw_backtrace_to_string before_trace)
                   (Printexc.raw_backtrace_to_string trace))
                "external cancellation retains original backtrace";
              match error with
              | Eio.Cancel.Cancelled observed_cause ->
                  ensure (observed_cause == cause)
                    "external cancellation cause retained"
              | _ -> Alcotest.fail "external cancellation was replaced")
          | Returned _, _ | Raised _, None ->
              Alcotest.fail "external cancellation became an output diagnostic"))

let closed_publication () =
  mock (fun () ->
      let retained = ref None in
      let state, destination = sink (fun () -> ()) in
      Output.with_output ~clock:(held_clock ()) ~sink:destination (fun output ->
          retained := Some output;
          Ok ())
      |> successful;
      let output =
        match !retained with
        | Some output -> output
        | None -> Alcotest.fail "callback was not called"
      in
      (match capture (fun () -> Output.emit output ~event:"late" []) with
      | Raised _ -> ()
      | Returned () -> Alcotest.fail "closed output accepted an event");
      Alcotest.(check int)
        "late publication cannot reach the caller-owned sink" 0
        (Buffer.length state.Sink.bytes))

let tests =
  [
    Alcotest.test_case "held writer allows FIFO escaped publication" `Quick
      queued_fifo;
    Alcotest.test_case "full bounded queue drains every record" `Quick
      full_queue;
    Alcotest.test_case "overflow counts the held in-flight record" `Quick
      overflow;
    Alcotest.test_case "invalid and oversized records fail before writing"
      `Quick invalid_records;
    Alcotest.test_case "writer failure cancels and joins callback" `Quick
      writer_failure;
    Alcotest.test_case "caught rejection still interrupts callback" `Quick
      caught_rejection;
    Alcotest.test_case "slow flush is bounded by the supplied clock" `Quick
      slow_flush;
    Alcotest.test_case "callback Error survives write failure" `Quick
      (primary_error Write_fault);
    Alcotest.test_case "callback Error survives writer unwind defect" `Quick
      (primary_error Unwind_fault);
    Alcotest.test_case "callback defect survives write failure" `Quick
      (primary_defect Write_fault);
    Alcotest.test_case "callback defect survives writer unwind defect" `Quick
      (primary_defect Unwind_fault);
    Alcotest.test_case "unexpected writer defect survives callback join" `Quick
      writer_defect;
    Alcotest.test_case "unexpected flush clock defect survives writer join"
      `Quick flush_defect;
    Alcotest.test_case "known clock Error is redacted after writer join" `Quick
      flush_error;
    Alcotest.test_case "recorded rejection skips later flush clock defect"
      `Quick rejected_before_clock;
    Alcotest.test_case
      "callback rejection drains its accepted diagnostic record" `Quick
      error_record;
    Alcotest.test_case "callback defect drains its accepted failure record"
      `Quick defect_record;
    Alcotest.test_case
      "recorded IO failure survives later cancellation hook defect" `Quick
      io_before_hook_defect;
    Alcotest.test_case "external cancellation retains identity after joins"
      `Quick external_cancel;
    Alcotest.test_case "closed publication is rejected" `Quick
      closed_publication;
  ]
