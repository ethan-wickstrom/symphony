module F = Core_fixture
module S = Service_scenario

type 'a captured = Returned of 'a | Raised of exn * Printexc.raw_backtrace

let capture action =
  match action () with
  | value -> Returned value
  | exception error -> Raised (error, Printexc.get_raw_backtrace ())

let checked = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "checked fixture rejected"

let timeout = checked (Milliseconds.parse "1000")
let first_wall = checked (Utc.parse "2026-10-05T00:00:00Z")
let next_wall = checked (Utc.parse "2026-10-05T00:00:01Z")
let flood_size = 130

let run actor =
  Eio_mock.Backend.run (fun () ->
      let mono = Eio_mock.Clock.Mono.make () in
      let wall = Eio_mock.Clock.make () in
      let clock = Clock_posix.create ~mono ~wall in
      S.run ~clock ~observe:ignore (fun ~sw controller ->
          actor ~sw ~mono controller))

let rec await controller inspect =
  let before = S.revision controller in
  match inspect () with
  | Some value -> value
  | None ->
      S.await_change controller ~after:before;
      await controller inspect

let read_call : type answer.
    answer S.call -> Tracker_registry.Contract.reply S.call option =
 fun call ->
  match S.invocation call with
  | S.Reading _ -> Some call
  | S.Loading _ | S.Removing _ | S.Running _ -> None

let load_call : type answer.
    answer S.call -> (F.Config.t, Config_layer.error) result S.call option =
 fun call ->
  match S.invocation call with
  | S.Loading _ -> Some call
  | S.Reading _ | S.Removing _ | S.Running _ -> None

let worker_call : type answer.
    answer S.call -> Agent_runner.outcome S.call option =
 fun call ->
  match S.invocation call with
  | S.Running _ -> Some call
  | S.Loading _ | S.Reading _ | S.Removing _ -> None

type 'a selector = { select : 'answer. 'answer S.call -> 'a option }

let reading = { select = read_call }
let loading = { select = load_call }
let working = { select = worker_call }

let pending controller selector =
  await controller (fun () ->
      List.find_map
        (fun (S.Pending call) -> selector.select call)
        (S.pending controller))

let complete call value =
  S.respond call value;
  S.close call S.Close_ok

let unavailable expected = function
  | Error actual ->
      Alcotest.(check bool) "source unavailability" true (actual = expected)
  | Ok _ -> Alcotest.fail "unavailable source returned a value"

module Harness (Controller : sig
  val value : S.t
end) =
struct
  module Ports = S.Ports (struct
    let controller = Controller.value
  end)

  type sample_gate = {
    entered : unit Eio.Promise.u;
    release : unit Eio.Promise.t;
    canceled : unit Eio.Promise.u;
    closed : bool ref;
  }

  type sample_mode =
    | Sample
    | Reject
    | Crash of exn
    | Hold of unit Eio.Promise.u * unit Eio.Promise.t
    | Observed_hold of sample_gate

  let mode = ref Sample
  let samples = ref 0
  let wall = ref first_wall

  type now_mode =
    | Now
    | Hold_after of int * unit Eio.Promise.u * unit Eio.Promise.t

  let now_mode = ref Now

  module Clock = struct
    include S.Clock

    let now t =
      match !now_mode with
      | Now -> S.Clock.now t
      | Hold_after (remaining, entered, release) when remaining > 0 ->
          now_mode := Hold_after (remaining - 1, entered, release);
          S.Clock.now t
      | Hold_after (_, entered, release) ->
          now_mode := Now;
          Eio.Promise.resolve entered ();
          Eio.Promise.await release;
          S.Clock.now t

    let sample t =
      incr samples;
      begin match !mode with
      | Sample -> ()
      | Reject -> ()
      | Crash error -> raise error
      | Hold (entered, release) ->
          mode := Sample;
          Eio.Promise.resolve entered ();
          Eio.Promise.await release
      | Observed_hold gate ->
          mode := Sample;
          Fun.protect
            ~finally:(fun () -> gate.closed := true)
            (fun () ->
              Eio.Promise.resolve gate.entered ();
              match capture (fun () -> Eio.Promise.await gate.release) with
              | Returned () -> ()
              | Raised ((Eio.Cancel.Cancelled _ as error), trace) ->
                  Eio.Promise.resolve gate.canceled ();
                  Printexc.raise_with_backtrace error trace
              | Raised (error, trace) ->
                  Printexc.raise_with_backtrace error trace)
      end;
      match !mode with
      | Reject -> Error F.diagnostic
      | Sample | Hold _ | Observed_hold _ | Crash _ ->
          Result.map
            (fun monotonic -> { Pure.monotonic; wall = !wall })
            (S.Clock.now t)
  end

  module Host =
    Service.Make (Ports.Tracker) (Clock) (S.Workspace) (S.Agent) (F.Config)
      (S.Load)

  let projection = ref None
  let transitions = ref 0
  let initials = ref 0
  let faults = ref 0

  let observe = function
    | Host.Initial event ->
        incr initials;
        projection := Some event.Host.projection;
        S.notify Controller.value
    | Host.Transition event ->
        incr transitions;
        projection := Some event.Host.projection;
        S.notify Controller.value
    | Host.Effect _ -> S.notify Controller.value

  let create () =
    Host.create ~clock:Controller.value ~workspace:Controller.value
      ~agent:Controller.value ~load:Controller.value
      ~report:(fun _ -> incr faults)
      ~report_host:(fun _ -> incr faults)
      ~observe

  let create_run ~sw host = Host.create_run ~sw host ~query_timeout:timeout

  let launch ~sw handle =
    let controls = Eio.Stream.create 1 in
    let result =
      Eio.Fiber.fork_promise ~sw (fun () ->
          let result =
            capture (fun () -> Host.run handle ~controls (F.config F.A))
          in
          S.notify Controller.value;
          result)
    in
    (controls, result)

  let rec join result =
    let before = S.revision Controller.value in
    List.iter
      (fun (S.Pending call) -> S.close call S.Close_ok)
      (S.pending Controller.value);
    match Eio.Promise.peek result with
    | Some _ -> Eio.Promise.await_exn result
    | None ->
        S.await_change Controller.value ~after:before;
        join result

  let stop controls result =
    Eio.Stream.add controls Host.Shutdown;
    match join result with
    | Returned (Ok ()) -> ()
    | Returned (Error _) -> Alcotest.fail "graceful service returned Error"
    | Raised (error, trace) -> Printexc.raise_with_backtrace error trace

  let ready () = ignore (pending Controller.value reading)

  let prepare issues =
    complete (pending Controller.value reading) (F.reply []);
    complete (pending Controller.value loading) (Ok (F.config F.A));
    complete (pending Controller.value reading) (F.reply issues)

  let idle () =
    await Controller.value (fun () ->
        match !projection with
        | Some projection ->
            if
              projection.Host.Core.mode = Host.Core.Serving
              && projection.Host.Core.cycle = Host.Core.Idle
            then Some ()
            else None
        | None -> None)

  let active issue =
    await Controller.value (fun () ->
        Option.bind !projection (fun projection ->
            List.find_map
              (function
                | Host.Core.Worker worker ->
                    if
                      worker.Host.Core.phase = Host.Core.Active
                      && Issue_id.equal
                           (Issue.id worker.Host.Core.issue)
                           (Issue.id issue)
                    then Some ()
                    else None
                | Host.Core.Retry _ | Host.Core.Cleaning _ -> None)
              projection.Host.Core.owners))
end

let lifetime () =
  run (fun ~sw ~mono:_ controller ->
      let module H = Harness (struct
        let value = controller
      end) in
      let host = H.create () in
      let handle = H.create_run ~sw host in
      let source = H.Host.source handle in
      let unused =
        Eio.Switch.run (fun child ->
            H.Host.source (H.create_run ~sw:child host))
      in
      unavailable Status_source.Shutting_down (H.Host.Source.snapshot unused);
      unavailable Status_source.Shutting_down (H.Host.Source.snapshot source);
      Alcotest.(check int) "unused source reads no clock" 0 !H.samples;
      let controls, result = H.launch ~sw handle in
      H.ready ();
      begin match
        capture (fun () -> H.Host.run handle ~controls (F.config F.A))
      with
      | Raised _ -> ()
      | Returned _ -> Alcotest.fail "active run started twice"
      end;
      ignore (checked (H.Host.Source.snapshot source));
      H.stop controls result;
      let samples = !H.samples in
      unavailable Status_source.Shutting_down (H.Host.Source.snapshot source);
      begin match
        capture (fun () -> H.Host.run handle ~controls (F.config F.A))
      with
      | Raised _ -> ()
      | Returned _ -> Alcotest.fail "closed run started twice"
      end;
      let next = H.create_run ~sw host in
      let next_controls, next_result = H.launch ~sw next in
      H.ready ();
      unavailable Status_source.Shutting_down (H.Host.Source.refresh source);
      Alcotest.(check int) "old source never reattaches" samples !H.samples;
      ignore (checked (H.Host.Source.snapshot (H.Host.source next)));
      H.stop next_controls next_result;
      Alcotest.(check int)
        "all service resources closed" 0
        (List.length (S.pending controller)))

let concurrent_runs () =
  run (fun ~sw ~mono:_ controller ->
      let module H = Harness (struct
        let value = controller
      end) in
      (* These closed ports acquire no resources with fixture-global keys. *)
      let module Tracker = struct
        include H.Ports.Tracker

        let execute _ = F.reply []
      end in
      let module Load = struct
        include S.Load

        let load _ _ = Ok (F.config F.A)
      end in
      let module Host =
        Service.Make (Tracker) (H.Clock) (S.Workspace) (S.Agent) (F.Config)
          (Load)
      in
      let initials = ref 0 in
      let host =
        Host.create ~clock:controller ~workspace:controller ~agent:controller
          ~load:controller
          ~report:(fun _ ->
            Alcotest.fail "unexpected concurrent scheduling fault")
          ~report_host:(fun _ ->
            Alcotest.fail "unexpected concurrent host fault")
          ~observe:(fun observation ->
            begin match observation with
            | Host.Initial _ -> incr initials
            | Host.Transition _ | Host.Effect _ -> ()
            end;
            S.notify controller)
      in
      let launch () =
        let handle = Host.create_run ~sw host ~query_timeout:timeout in
        let controls = Eio.Stream.create 1 in
        let result =
          Eio.Fiber.fork_promise ~sw (fun () ->
              Host.run handle ~controls (F.config F.A))
        in
        (handle, controls, result)
      in
      let stop controls result =
        Eio.Stream.add controls Host.Shutdown;
        checked (Eio.Promise.await_exn result)
      in
      let first, first_controls, first_result = launch () in
      let second, second_controls, second_result = launch () in
      await controller (fun () -> if !initials = 2 then Some () else None);
      ignore (checked (Host.Source.snapshot (Host.source first)));
      ignore (checked (Host.Source.snapshot (Host.source second)));
      stop first_controls first_result;
      unavailable Status_source.Shutting_down
        (Host.Source.snapshot (Host.source first));
      ignore (checked (Host.Source.snapshot (Host.source second)));
      stop second_controls second_result)

let fresh_snapshot () =
  run (fun ~sw ~mono controller ->
      let module H = Harness (struct
        let value = controller
      end) in
      let handle = H.create_run ~sw (H.create ()) in
      let controls, result = H.launch ~sw handle in
      let issue = F.issue ~id:"query-worker" ~identifier:"QUERY-1" () in
      H.prepare [ issue ];
      ignore (pending controller working);
      H.active issue;
      let source = H.Host.source handle in
      let first = Snapshot.data (checked (H.Host.Source.snapshot source)) in
      let steps = !H.transitions in
      Eio_mock.Clock.Mono.set_time mono (Mtime.of_uint64_ns 1_000_000L);
      H.wall := next_wall;
      let next = Snapshot.data (checked (H.Host.Source.snapshot source)) in
      Alcotest.(check int) "one sample per owner read" 2 !H.samples;
      Alcotest.(check string)
        "fresh wall sample" (Utc.rfc3339 next_wall)
        (Utc.rfc3339 next.Snapshot.generated_at);
      Alcotest.(check string)
        "initial live duration" "0"
        (Seconds.decimal first.Snapshot.seconds_running);
      Alcotest.(check string)
        "read-time live duration" "0.001"
        (Seconds.decimal next.Snapshot.seconds_running);
      Alcotest.(check int)
        "reads create no scheduling transitions" steps !H.transitions;
      Alcotest.(check int)
        "canonical running owner" 1
        (List.length next.Snapshot.running);
      H.stop controls result)

let refresh_receipt () =
  run (fun ~sw ~mono:_ controller ->
      let module H = Harness (struct
        let value = controller
      end) in
      let handle = H.create_run ~sw (H.create ()) in
      let controls, result = H.launch ~sw handle in
      H.prepare [];
      H.idle ();
      let source = H.Host.source handle in
      Alcotest.(check bool)
        "idle refresh queues actual owner work" true
        (checked (H.Host.Source.refresh source) = Status_source.Queued);
      ignore (pending controller loading);
      Alcotest.(check bool)
        "busy refresh coalesces" true
        (checked (H.Host.Source.refresh source) = Status_source.Coalesced);
      H.stop controls result)

let shutdown_waiters () =
  run (fun ~sw ~mono:_ controller ->
      let module H = Harness (struct
        let value = controller
      end) in
      let handle = H.create_run ~sw (H.create ()) in
      let controls, result = H.launch ~sw handle in
      H.ready ();
      let entered, signal_entered = Eio.Promise.create () in
      let release, signal_release = Eio.Promise.create () in
      H.mode := H.Hold (signal_entered, release);
      let source = H.Host.source handle in
      let first =
        Eio.Fiber.fork_promise ~sw (fun () -> H.Host.Source.snapshot source)
      in
      Eio.Promise.await entered;
      let rest =
        List.init (flood_size - 1) (fun _ ->
            Eio.Fiber.fork_promise ~sw (fun () -> H.Host.Source.snapshot source))
      in
      Eio.Stream.add controls H.Host.Shutdown;
      List.iter
        (fun pending ->
          unavailable Status_source.Shutting_down
            (Eio.Promise.await_exn pending))
        (first :: rest);
      Alcotest.(check bool)
        "source closes before owner drain" true
        (Eio.Promise.peek result = None);
      Alcotest.(check int) "only received request sampled" 1 !H.samples;
      Eio.Promise.resolve signal_release ();
      begin match H.join result with
      | Returned (Ok ()) -> ()
      | Returned (Error _) | Raised _ -> Alcotest.fail "shutdown failed"
      end)

let requester_cancel () =
  run (fun ~sw ~mono:_ controller ->
      let module H = Harness (struct
        let value = controller
      end) in
      let handle = H.create_run ~sw (H.create ()) in
      let controls, result = H.launch ~sw handle in
      H.ready ();
      let entered, signal_entered = Eio.Promise.create () in
      let release, signal_release = Eio.Promise.create () in
      let context, offer_context = Eio.Promise.create () in
      H.mode := H.Hold (signal_entered, release);
      let source = H.Host.source handle in
      let request =
        Eio.Fiber.fork_promise ~sw (fun () ->
            capture (fun () ->
                Eio.Cancel.sub (fun context ->
                    Eio.Promise.resolve offer_context context;
                    H.Host.Source.snapshot source)))
      in
      Eio.Promise.await entered;
      let cause = Failure "request cancellation marker" in
      Eio.Cancel.cancel (Eio.Promise.await context) cause;
      begin match Eio.Promise.await_exn request with
      | Raised (Eio.Cancel.Cancelled actual, trace) ->
          Alcotest.(check bool)
            "original requester cancellation cause" true (actual == cause);
          Alcotest.(check bool)
            "request cancellation keeps backtrace" true
            (Printexc.raw_backtrace_length trace > 0)
      | Raised _ | Returned _ -> Alcotest.fail "request cancellation replaced"
      end;
      Alcotest.(check bool)
        "requester cannot cancel owner" true
        (Eio.Promise.peek result = None);
      Eio.Promise.resolve signal_release ();
      ignore (checked (H.Host.Source.snapshot source));
      Alcotest.(check int) "owner reports no requester fault" 0 !H.faults;
      H.stop controls result)

let requester_timeout () =
  run (fun ~sw ~mono controller ->
      let module H = Harness (struct
        let value = controller
      end) in
      let handle = H.create_run ~sw (H.create ()) in
      let controls, result = H.launch ~sw handle in
      H.ready ();
      let entered, signal_entered = Eio.Promise.create () in
      let release, signal_release = Eio.Promise.create () in
      H.mode := H.Hold (signal_entered, release);
      let source = H.Host.source handle in
      let request =
        Eio.Fiber.fork_promise ~sw (fun () -> H.Host.Source.snapshot source)
      in
      Eio.Promise.await entered;
      Eio_mock.Clock.Mono.set_time mono (Mtime.of_uint64_ns 1_000_000_000L);
      unavailable Status_source.Timeout (Eio.Promise.await_exn request);
      Alcotest.(check bool)
        "timeout cannot cancel owner" true
        (Eio.Promise.peek result = None);
      Eio.Promise.resolve signal_release ();
      ignore (checked (H.Host.Source.snapshot source));
      Alcotest.(check int) "late reply cannot cross request" 2 !H.samples;
      H.stop controls result)

let abandoned_refresh () =
  run (fun ~sw ~mono:_ controller ->
      let module H = Harness (struct
        let value = controller
      end) in
      let handle = H.create_run ~sw (H.create ()) in
      let controls, result = H.launch ~sw handle in
      H.prepare [];
      H.idle ();
      let steps = !H.transitions in
      let entered, signal_entered = Eio.Promise.create () in
      let release, signal_release = Eio.Promise.create () in
      let context, offer_context = Eio.Promise.create () in
      (* The request deadline reads first; pause the subsequent owner read. *)
      H.now_mode := H.Hold_after (1, signal_entered, release);
      let source = H.Host.source handle in
      let request =
        Eio.Fiber.fork_promise ~sw (fun () ->
            capture (fun () ->
                Eio.Cancel.sub (fun context ->
                    Eio.Promise.resolve offer_context context;
                    H.Host.Source.refresh source)))
      in
      Eio.Promise.await entered;
      let cause = Failure "abandoned refresh marker" in
      Eio.Cancel.cancel (Eio.Promise.await context) cause;
      begin match Eio.Promise.await_exn request with
      | Raised (Eio.Cancel.Cancelled actual, _) ->
          Alcotest.(check bool)
            "refresh requester cancellation cause" true (actual == cause)
      | Raised _ | Returned _ -> Alcotest.fail "refresh cancellation replaced"
      end;
      Eio.Promise.resolve signal_release ();
      ignore (checked (H.Host.Source.snapshot source));
      Alcotest.(check int)
        "abandoned refresh creates no scheduling input" steps !H.transitions;
      Alcotest.(check bool)
        "abandoned refresh starts no workflow read" false
        (List.exists
           (fun (S.Pending call) -> Option.is_some (load_call call))
           (S.pending controller));
      H.stop controls result)

let caller_cancels_owner () =
  Eio_mock.Backend.run_full (fun env ->
      let mono = Eio_mock.Clock.Mono.make () in
      let wall = Eio_mock.Clock.make () in
      let clock = Clock_posix.create ~mono ~wall in
      let watchdog_clock =
        Clock_posix.create
          ~mono:(Eio.Stdenv.mono_clock env)
          ~wall:(Eio.Stdenv.clock env)
      in
      let module Watchdog = Deadline.Make (Clock_posix) in
      S.run ~clock ~observe:ignore (fun ~sw controller ->
          let module H = Harness (struct
            let value = controller
          end) in
          let handle = H.create_run ~sw (H.create ()) in
          let controls = Eio.Stream.create 1 in
          let context, offer_context = Eio.Promise.create () in
          let result =
            Eio.Fiber.fork_promise ~sw (fun () ->
                let result =
                  capture (fun () ->
                      Eio.Cancel.sub (fun context ->
                          Eio.Promise.resolve offer_context context;
                          H.Host.run handle ~controls (F.config F.A)))
                in
                S.notify controller;
                result)
          in
          H.ready ();
          let entered, signal_entered = Eio.Promise.create () in
          let release, signal_release = Eio.Promise.create () in
          let canceled, signal_canceled = Eio.Promise.create () in
          let closed = ref false in
          H.mode :=
            H.Observed_hold
              {
                H.entered = signal_entered;
                H.release;
                H.canceled = signal_canceled;
                H.closed;
              };
          let request =
            Eio.Fiber.fork_promise ~sw (fun () ->
                H.Host.Source.snapshot (H.Host.source handle))
          in
          Eio.Promise.await entered;
          let cause = Failure "service caller cancellation marker" in
          Fun.protect
            ~finally:(fun () ->
              (* The red path may drain only after its missing-cancel assertion. *)
              ignore (Eio.Promise.try_resolve signal_release () : bool);
              ignore (H.join result))
            (fun () ->
              Eio.Cancel.cancel (Eio.Promise.await context) cause;
              unavailable Status_source.Shutting_down
                (Eio.Promise.await_exn request);
              let witnessed =
                Watchdog.run watchdog_clock ~delay:timeout
                  ~on_error:(fun _ ->
                    "owner-cancellation watchdog clock failed")
                  ~on_timeout:(fun () ->
                    "owner clock was not canceled and joined")
                  (fun () ->
                    Eio.Promise.await canceled;
                    Ok (H.join result))
              in
              let actual =
                match witnessed with
                | Ok value -> value
                | Error message -> Alcotest.fail message
              in
              Alcotest.(check bool) "owner sample finalizer joined" true !closed;
              Alcotest.(check bool)
                "held sample never manually released" false
                (Eio.Promise.is_resolved release);
              Alcotest.(check int)
                "caller waits for all effect resources" 0
                (List.length (S.pending controller));
              begin match actual with
              | Raised (Eio.Cancel.Cancelled actual, trace) ->
                  Alcotest.(check bool)
                    "service caller cancellation cause" true (actual == cause);
                  Alcotest.(check bool)
                    "service caller cancellation trace" true
                    (Printexc.raw_backtrace_length trace > 0)
              | Raised _ | Returned _ ->
                  Alcotest.fail "service caller cancellation replaced"
              end)))

let expected_clock_error () =
  run (fun ~sw ~mono:_ controller ->
      let module H = Harness (struct
        let value = controller
      end) in
      let handle = H.create_run ~sw (H.create ()) in
      let controls, result = H.launch ~sw handle in
      H.ready ();
      let source = H.Host.source handle in
      H.mode := H.Reject;
      unavailable Status_source.Clock_unavailable
        (H.Host.Source.snapshot source);
      H.mode := H.Sample;
      ignore (checked (H.Host.Source.snapshot source));
      S.fail_next_now controller F.diagnostic;
      unavailable Status_source.Clock_unavailable
        (H.Host.Source.snapshot source);
      ignore (checked (H.Host.Source.snapshot source));
      Alcotest.(check int)
        "clock query errors do not become scheduling faults" 0 !H.faults;
      H.stop controls result)

let sample_defect () =
  run (fun ~sw ~mono:_ controller ->
      let module H = Harness (struct
        let value = controller
      end) in
      let handle = H.create_run ~sw (H.create ()) in
      let _, result = H.launch ~sw handle in
      H.ready ();
      let defect = Failure "query sample defect marker" in
      H.mode := H.Crash defect;
      let source = H.Host.source handle in
      unavailable Status_source.Shutting_down (H.Host.Source.snapshot source);
      begin match H.join result with
      | Raised (actual, trace) ->
          Alcotest.(check bool)
            "sample defect physical identity" true (actual == defect);
          Alcotest.(check bool)
            "sample defect retains backtrace" true
            (Printexc.raw_backtrace_length trace > 0)
      | Returned _ -> Alcotest.fail "owner swallowed sample defect"
      end;
      let samples = !H.samples in
      unavailable Status_source.Shutting_down (H.Host.Source.snapshot source);
      Alcotest.(check int)
        "fatal source closure samples no clock" samples !H.samples;
      Alcotest.(check int)
        "fatal query drains effect resources" 0
        (List.length (S.pending controller)))

let tests =
  [
    Alcotest.test_case "run source cannot reopen or start twice" `Quick lifetime;
    Alcotest.test_case "reusable service has independent concurrent runs" `Quick
      concurrent_runs;
    Alcotest.test_case "snapshot samples current owner time without stepping"
      `Quick fresh_snapshot;
    Alcotest.test_case "refresh receipts distinguish idle and busy" `Quick
      refresh_receipt;
    Alcotest.test_case "shutdown wakes accepted and admission-waiting requests"
      `Quick shutdown_waiters;
    Alcotest.test_case "request cancellation leaves owner alive" `Quick
      requester_cancel;
    Alcotest.test_case "request timeout retires late owner reply" `Quick
      requester_timeout;
    Alcotest.test_case "abandoned refresh cannot admit scheduling work" `Quick
      abandoned_refresh;
    Alcotest.test_case "caller cancellation cancels and joins owner port" `Quick
      caller_cancels_owner;
    Alcotest.test_case "expected query clock errors preserve scheduler" `Quick
      expected_clock_error;
    Alcotest.test_case "query defect closes source before fatal drain" `Quick
      sample_defect;
  ]
