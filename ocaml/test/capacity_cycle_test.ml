module F = Core_fixture
module S = Service_test_support.Service_scenario
module Cycle = Capacity_cycle
module Workload = Capacity_fixture

let query_timeout =
  match Milliseconds.parse "15000" with
  | Ok value -> value
  | Error _ -> failwith "invalid capacity query fixture timeout"

let checked = function
  | Ok value -> value
  | Error diagnostic -> Alcotest.fail (Diagnostic.render diagnostic)

let same_key left right =
  match (left, right) with
  | S.Load a, S.Load b | S.Read a, S.Read b | S.Remove a, S.Remove b ->
      Request_id.equal a b
  | S.Run (ia, a), S.Run (ib, b) -> Issue_id.equal ia ib && Run_id.equal a b
  | ( (S.Load _ | S.Read _ | S.Remove _ | S.Run _),
      (S.Load _ | S.Read _ | S.Remove _ | S.Run _) ) -> false

let closing controller key =
  List.exists
    (function
      | S.Closing other -> same_key key other
      | S.Acquired _ | S.Released _ -> false)
    (S.trace controller)

let released controller key =
  List.exists
    (function
      | S.Released other -> same_key key other
      | S.Acquired _ | S.Closing _ -> false)
    (S.trace controller)

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

let run_call : type answer. answer S.call -> Agent_runner.outcome S.call option
    =
 fun call ->
  match S.invocation call with
  | S.Running _ -> Some call
  | S.Loading _ | S.Reading _ | S.Removing _ -> None

let complete call reply =
  S.respond call reply;
  S.close call S.Close_ok

let elapsed started ended =
  Count.delta
    ~previous:(Clock.Pure.nanoseconds started)
    ~current:(Clock.Pure.nanoseconds ended)

let scoped_cycle_close () =
  let mono = Eio_mock.Clock.Mono.make () in
  let wall = Eio_mock.Clock.make () in
  let clock = Clock_posix.create ~mono ~wall in
  S.run ~clock ~observe:ignore (fun ~sw controller ->
      let module P = S.Ports (struct
        let controller = controller
      end) in
      let module Host =
        Service.Make (P.Tracker) (P.Clock) (P.Workspace) (P.Agent) (P.Config)
          (P.Load)
      in
      let controls = Eio.Stream.create 1 in
      let joined, signal = Eio.Promise.create () in
      let projection = ref None in
      let metric = ref (Cycle.create ()) in
      let samples = ref [] in
      let measuring = ref false in
      let poll_ticks = ref 0 in
      let next_poll = ref None in
      let reports = ref 0 in
      let host_reports = ref 0 in
      let read_receipts = ref [] in
      let snapshot at input (value : Host.Core.projection) commands =
        List.iter
          (function
            | Host.Core.Arm_poll (_, due) -> next_poll := Some due
            | Host.Core.Load_workflow _
            | Host.Core.Read_tracker _
            | Host.Core.Start_worker _
            | Host.Core.Stop_worker _
            | Host.Core.Continue_worker _
            | Host.Core.Remove_workspace _
            | Host.Core.Cancel_request _
            | Host.Core.Cancel_poll _
            | Host.Core.Arm_retry _
            | Host.Core.Cancel_retry _
            | Host.Core.Report _ -> ())
          commands;
        let phase =
          match value.Host.Core.cycle with
          | Host.Core.Idle -> Cycle.Idle
          | Host.Core.Busy -> Cycle.Busy
        in
        let next, interval =
          Cycle.observe ~at
            ~now:(checked (Clock_posix.now clock))
            ~input ~phase !metric
        in
        metric := next;
        if !measuring then
          Option.iter (fun value -> samples := value :: !samples) interval;
        projection := Some value;
        S.notify controller
      in
      let observe = function
        | Host.Initial value ->
            snapshot value.Host.now Cycle.Other value.Host.projection
              value.Host.commands
        | Host.Transition value ->
            let input =
              match value.Host.input with
              | Host.Core.Poll_due _ ->
                  incr poll_ticks;
                  Cycle.Poll
              | Host.Core.Tracker_completed (id, _) ->
                  read_receipts :=
                    released controller (S.Read id) :: !read_receipts;
                  Cycle.Other
              | Host.Core.Refresh_requested
              | Host.Core.Workflow_changed
              | Host.Core.Workflow_loaded _
              | Host.Core.Request_canceled _
              | Host.Core.Worker_started _
              | Host.Core.Worker_progress _
              | Host.Core.Worker_continue _
              | Host.Core.Worker_finished _
              | Host.Core.Retry_due _
              | Host.Core.Workspace_removed _
              | Host.Core.Shutdown -> Cycle.Other
            in
            snapshot value.Host.now input value.Host.projection
              value.Host.commands
        | Host.Effect _ -> S.notify controller
      in
      Eio.Fiber.fork ~sw (fun () ->
          let result =
            match
              Eio.Switch.run (fun child ->
                  let host =
                    Host.create ~clock:controller ~workspace:controller
                      ~agent:controller ~load:controller
                      ~report:(fun _ -> incr reports)
                      ~report_host:(fun _ -> incr host_reports)
                      ~observe
                  in
                  let run = Host.create_run ~sw:child host ~query_timeout in
                  Host.run run ~controls Workload.config)
            with
            | value -> Ok value
            | exception error -> Error error
          in
          Eio.Promise.resolve signal result;
          S.notify controller);
      let rec await inspect =
        let before = S.revision controller in
        match inspect () with
        | Some value -> value
        | None -> (
            match Eio.Promise.peek joined with
            | Some (Error error) ->
                Alcotest.failf "Capacity service raised: %s"
                  (Printexc.to_string error)
            | Some (Ok (Error diagnostic)) ->
                Alcotest.fail (Diagnostic.render diagnostic)
            | Some (Ok (Ok ())) ->
                Alcotest.fail "Capacity service returned before its gate"
            | None ->
                S.await_change controller ~after:before;
                await inspect)
      in
      let reading () =
        await (fun () ->
            List.find_map
              (fun (S.Pending call) -> read_call call)
              (S.pending controller))
      in
      let loading () =
        await (fun () ->
            List.find_map
              (fun (S.Pending call) -> load_call call)
              (S.pending controller))
      in
      let running () =
        await (fun () ->
            List.find_map
              (fun (S.Pending call) -> run_call call)
              (S.pending controller))
      in
      let idle () =
        match !projection with
        | Some value -> value.Host.Core.cycle = Host.Core.Idle
        | None -> false
      in
      let tick () =
        let before = !poll_ticks in
        let due =
          match !next_poll with
          | Some value -> value
          | None -> Alcotest.fail "Capacity cycle has no retained poll timer"
        in
        let bits =
          match Count.to_uint64_bits (Clock.Pure.nanoseconds due) with
          | Some value -> value
          | None -> Alcotest.fail "Capacity timer exceeds the native horizon"
        in
        Eio_mock.Clock.Mono.set_time mono (Mtime.of_uint64_ns bits);
        S.notify controller;
        await (fun () -> if !poll_ticks > before then Some () else None)
      in
      let issue =
        match Workload.issues ~sessions:1 with
        | [ value ] -> value
        | [] | _ :: _ :: _ -> Alcotest.fail "Expected one capacity worker"
      in
      complete (reading ()) (F.reply []);
      complete (loading ()) (Ok Workload.config);
      complete (reading ()) (F.reply [ issue ]);
      let worker = running () in
      await (fun () ->
          match !projection with
          | Some value
            when idle ()
                 && List.exists
                      (function
                        | Host.Core.Worker
                            { Host.Core.phase = Host.Core.Active; _ } -> true
                        | Host.Core.Worker
                            {
                              Host.Core.phase =
                                Host.Core.Starting | Host.Core.Stopping;
                              _;
                            }
                        | Host.Core.Retry _ | Host.Core.Cleaning _ -> false)
                      value.Host.Core.owners -> Some ()
          | Some _ | None -> None);
      measuring := true;
      tick ();
      let started = checked (Clock_posix.now clock) in
      let read = reading () in
      let before_reply = List.length !samples in
      let busy_ticks = 2 in
      for _ = 1 to busy_ticks do
        tick ()
      done;
      let after_busy_ticks = List.length !samples in
      (* A response is insufficient: its real protected scope must also close. *)
      S.respond read (F.reply [ issue ]);
      await (fun () ->
          if closing controller (S.key read) then Some () else None);
      tick ();
      let before_close = List.length !samples in
      let held_until = checked (Clock_posix.now clock) in
      let phase_before_close = Cycle.phase !metric in
      S.close read S.Close_ok;
      complete (loading ()) (Ok Workload.config);
      complete (reading ()) (F.reply [ issue ]);
      await (fun () -> if idle () then Some () else None);
      let completed = !samples in
      measuring := false;
      S.close worker S.Close_ok;
      Eio.Stream.add controls Host.Shutdown;
      (match Eio.Promise.await joined with
      | Ok (Ok ()) -> ()
      | Ok (Error diagnostic) -> Alcotest.fail (Diagnostic.render diagnostic)
      | Error error ->
          Alcotest.failf "Capacity join raised: %s" (Printexc.to_string error));
      Alcotest.(check int) "no cycle before reconciliation reply" 0 before_reply;
      Alcotest.(check int)
        "busy poll ticks complete no cycle" 0 after_busy_ticks;
      Alcotest.(check int)
        "reply without scope closure completes no cycle" 0 before_close;
      Alcotest.(check bool)
        "held scope remains Busy" true
        (phase_before_close = Cycle.Busy);
      Alcotest.(check int) "one completed whole cycle" 1 (List.length completed);
      (match completed with
      | [ { Cycle.started = first; ended } ] ->
          Alcotest.(check bool)
            "latency includes every held interval" true
            (Count.compare (elapsed first ended) (elapsed started held_until)
            >= 0)
      | [] | _ :: _ :: _ -> Alcotest.fail "Missing single full-cycle interval");
      Alcotest.(check bool)
        "owner tracker receipts follow actual scope release" true
        (List.for_all Fun.id !read_receipts);
      Alcotest.(check bool)
        "worker scope closed before completion" true
        (released controller (S.key worker));
      Alcotest.(check int)
        "all fake resources closed" 0
        (List.length (S.pending controller));
      Alcotest.(check int) "no reducer faults" 0 !reports;
      Alcotest.(check int) "no host faults" 0 !host_reports)

let delayed_cycle_close () = Eio_mock.Backend.run scoped_cycle_close

let suite () =
  ( "whole capacity cycles",
    [
      Alcotest.test_case
        "busy timer ticks and delayed tracker closure retain whole latency"
        `Quick delayed_cycle_close;
    ] )
