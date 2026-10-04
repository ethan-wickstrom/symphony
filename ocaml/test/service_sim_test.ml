module F = Core_fixture
module S = Service_scenario

exception Observer_defect of int
exception Parent_defect of int
exception Cleanup_defect of int
exception Reporter_defect of int

type 'a captured = Returned of 'a | Raised of exn * Printexc.raw_backtrace

let capture work =
  match work () with
  | value -> Returned value
  | exception error -> Raised (error, Printexc.get_raw_backtrace ())

let contains text needle =
  let rec loop index =
    if index + String.length needle > String.length text then false
    else
      String.starts_with ~prefix:needle
        (String.sub text index (String.length text - index))
      || loop (index + 1)
  in
  loop 0

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

let rec await controller inspect =
  let before = S.revision controller in
  match inspect () with
  | Some value -> value
  | None ->
      S.await_change controller ~after:before;
      await controller inspect

let load_call : type answer.
    answer S.call -> (F.Config.t, Config_layer.error) result S.call option =
 fun call ->
  match S.invocation call with
  | S.Loading _ -> Some call
  | S.Reading _ | S.Removing _ | S.Running _ -> None

let read_call : type answer.
    answer S.call -> Tracker_registry.Contract.reply S.call option =
 fun call ->
  match S.invocation call with
  | S.Reading _ -> Some call
  | S.Loading _ | S.Removing _ | S.Running _ -> None

let run_call : type answer. answer S.call -> Agent_runner.outcome S.call option
    =
 fun call ->
  match S.invocation call with
  | S.Running _ -> Some call
  | S.Loading _ | S.Reading _ | S.Removing _ -> None

let loading controller =
  await controller (fun () ->
      List.find_map
        (fun (S.Pending call) -> load_call call)
        (S.pending controller))

let reading controller =
  await controller (fun () ->
      List.find_map
        (fun (S.Pending call) -> read_call call)
        (S.pending controller))

let running controller =
  await controller (fun () ->
      List.find_map
        (fun (S.Pending call) -> run_call call)
        (S.pending controller))

let complete call response =
  S.respond call response;
  S.close call S.Close_ok

let workspace_closed controller key =
  ignore
    (await controller (fun () ->
         if closing controller key then Some () else None))

let service_issue =
  F.issue ~state:"Doing" ~id:"service-0" ~identifier:"SERVICE-0" ()

type reporter_mode = Report | Fail_report of exn

type observer_mode =
  | Observe
  | Fail_transition of exn
  | Fail_poll_close of exn
  | Fail_worker_entry of exn
  | Fail_progress of exn
  | Hold_continue of unit Eio.Promise.u * unit Eio.Promise.t

type oracle = Scheduling_model | Causal_worker

let run actor =
  let mono = Eio_mock.Clock.Mono.make () in
  let wall = Eio_mock.Clock.make () in
  let clock = Clock_posix.create ~mono ~wall in
  S.run ~clock ~observe:ignore (fun ~sw controller ->
      actor ~sw ~mono controller)

let advance mono controller instant =
  let requested = Clock.Pure.nanoseconds instant in
  let current =
    Count.of_uint64_bits (Mtime.to_uint64_ns (Eio.Time.Mono.now mono))
  in
  if Count.compare requested current < 0 then
    invalid_arg "backward fake-clock advance";
  match Count.to_uint64_bits requested with
  | None -> invalid_arg "fake-clock native horizon"
  | Some tick ->
      Eio_mock.Clock.Mono.set_time mono (Mtime.of_uint64_ns tick);
      S.notify controller

module Harness (Controller : sig
  val value : S.t
  val mono : Eio_mock.Clock.Mono.t
end) =
struct
  module P = S.Ports (struct
    let controller = Controller.value
  end)

  module Host =
    Service.Make (P.Tracker) (P.Clock) (P.Workspace) (P.Agent) (P.Config)
      (P.Load)

  module Bridge = Core_bridge.Make (P.Agent) (Host.Core)

  type t = {
    controls : Host.control Eio.Stream.t;
    mutable bridge : Bridge.t option;
    mutable observer : observer_mode;
    mutable reporter : reporter_mode;
    mutable effects : Host.effect_event list;
    mutable secondary : Host.host_fault list;
    mutable origin : Printexc.raw_backtrace option;
    oracle : oracle;
    mutable projection : Host.Core.projection option;
    mutable transitions : Host.transition list;
  }

  let create ?(oracle = Scheduling_model) () =
    {
      controls = Eio.Stream.create 1;
      bridge = None;
      observer = Observe;
      reporter = Report;
      effects = [];
      secondary = [];
      origin = None;
      oracle;
      projection = None;
      transitions = [];
    }

  let fail_observer t error =
    try raise error
    with thrown ->
      let backtrace = Printexc.get_raw_backtrace () in
      t.origin <- Some backtrace;
      Printexc.raise_with_backtrace thrown backtrace

  let saved_backtrace t actual =
    let original =
      match t.origin with
      | Some value -> Printexc.raw_backtrace_to_string value
      | None -> Alcotest.fail "Observer did not retain its originating trace"
    in
    if String.equal original "" then
      Alcotest.fail "Backtrace recording is disabled";
    Alcotest.(check bool)
      "originating raw backtrace frames retained" true
      (String.starts_with ~prefix:original
         (Printexc.raw_backtrace_to_string actual))

  let secondary_worker t expected =
    let id, run =
      match S.key expected with
      | S.Run (id, run) -> (id, run)
      | S.Load _ | S.Read _ | S.Remove _ ->
          Alcotest.fail "Expected worker resource"
    in
    Alcotest.(check int)
      "one losing cleanup diagnostic" 1 (List.length t.secondary);
    List.iter
      (function
        | Host.Secondary_defect
            { key = Host.Worker (other_id, other_run); diagnostic } ->
            Alcotest.(check bool)
              "cleanup report follows owning release" true
              (released Controller.value (S.key expected));
            Alcotest.(check bool)
              "cleanup report retains worker generation" true
              (Issue_id.equal id other_id && Run_id.equal run other_run);
            let message = Diagnostic.render diagnostic in
            Alcotest.(check bool)
              "secondary payload is redacted" false (contains message "302")
        | Host.Secondary_defect
            {
              key =
                ( Host.Owner
                | Host.Controls
                | Host.Workflow _
                | Host.Tracker _
                | Host.Cleanup _
                | Host.Poll _
                | Host.Retry _ );
              _;
            } -> Alcotest.fail "Cleanup diagnostic lost its owning worker key")
      t.secondary

  let require_closed key =
    let acquired =
      List.exists
        (function
          | S.Acquired other -> same_key key other
          | S.Closing _ | S.Released _ -> false)
        (S.trace Controller.value)
    in
    if acquired && not (released Controller.value key) then
      Alcotest.fail "Actual mailbox terminal preceded its fake resource release"

  let closed_input = function
    | Host.Core.Workflow_loaded (id, _) -> require_closed (S.Load id)
    | Host.Core.Tracker_completed (id, _) -> require_closed (S.Read id)
    | Host.Core.Workspace_removed (id, _) -> require_closed (S.Remove id)
    | Host.Core.Request_canceled id ->
        require_closed (S.Load id);
        require_closed (S.Read id)
    | Host.Core.Worker_finished completed ->
        require_closed
          (S.Run
             (P.Agent.completed_issue completed, P.Agent.completed_run completed))
    | Host.Core.Poll_due _
    | Host.Core.Refresh_requested
    | Host.Core.Workflow_changed
    | Host.Core.Worker_started _
    | Host.Core.Worker_progress _
    | Host.Core.Worker_continue _
    | Host.Core.Retry_due _
    | Host.Core.Shutdown -> ()

  let observe t = function
    | Host.Initial value ->
        t.projection <- Some value.Host.projection;
        begin match t.oracle with
        | Causal_worker -> ()
        | Scheduling_model ->
            let bridge, _ =
              Bridge.initial ~profile:F.A ~now:value.Host.now
                ~commands:value.Host.commands ~projection:value.Host.projection
            in
            t.bridge <- Some bridge
        end;
        S.notify Controller.value
    | Host.Transition value ->
        closed_input value.Host.input;
        t.projection <- Some value.Host.projection;
        t.transitions <- value :: t.transitions;
        begin match t.oracle with
        | Causal_worker -> ()
        | Scheduling_model ->
            let previous =
              match t.bridge with
              | Some value -> value
              | None -> Alcotest.fail "Transition preceded Initial"
            in
            let bridge, _, _ =
              Bridge.accept previous ~now:value.Host.now ~input:value.Host.input
                ~commands:value.Host.commands ~projection:value.Host.projection
            in
            t.bridge <- Some bridge
        end;
        S.notify Controller.value;
        begin match t.observer with
        | Observe | Fail_poll_close _ | Fail_worker_entry _ -> ()
        | Hold_continue (entered, release) -> (
            match value.Host.input with
            | Host.Core.Worker_continue _ ->
                t.observer <- Observe;
                Eio.Promise.resolve entered ();
                Eio.Promise.await release
            | Host.Core.Poll_due _
            | Host.Core.Refresh_requested
            | Host.Core.Workflow_changed
            | Host.Core.Workflow_loaded _
            | Host.Core.Tracker_completed _
            | Host.Core.Worker_started _
            | Host.Core.Worker_progress _
            | Host.Core.Worker_finished _
            | Host.Core.Request_canceled _
            | Host.Core.Retry_due _
            | Host.Core.Workspace_removed _
            | Host.Core.Shutdown -> ())
        | Fail_progress error -> (
            match value.Host.input with
            | Host.Core.Worker_progress { issue; run; progress; _ } ->
                let sequence = P.Agent.sequence progress in
                let entered, returned =
                  List.fold_left
                    (fun (entered, returned) -> function
                      | S.Publication_entered (key, count)
                        when same_key key (S.Run (issue, run))
                             && Count.compare
                                  (Positive_count.count count)
                                  (Positive_count.count sequence)
                                = 0 -> (true, returned)
                      | S.Publication_returned (key, count)
                        when same_key key (S.Run (issue, run))
                             && Count.compare
                                  (Positive_count.count count)
                                  (Positive_count.count sequence)
                                = 0 -> (entered, true)
                      | S.Publication_entered _
                      | S.Publication_returned _
                      | S.Refresh_entered _
                      | S.Refresh_returned _ -> (entered, returned))
                    (false, false)
                    (S.worker_trace Controller.value)
                in
                Alcotest.(check bool)
                  "Producer waits for owner receipt" true
                  (entered && not returned);
                t.observer <- Observe;
                fail_observer t error
            | Host.Core.Poll_due _
            | Host.Core.Refresh_requested
            | Host.Core.Workflow_changed
            | Host.Core.Workflow_loaded _
            | Host.Core.Tracker_completed _
            | Host.Core.Worker_started _
            | Host.Core.Worker_continue _
            | Host.Core.Worker_finished _
            | Host.Core.Request_canceled _
            | Host.Core.Retry_due _
            | Host.Core.Workspace_removed _
            | Host.Core.Shutdown -> ())
        | Fail_transition error ->
            t.observer <- Observe;
            fail_observer t error
        end
    | Host.Effect event ->
        t.effects <- event :: t.effects;
        S.notify Controller.value;
        begin match (t.observer, event) with
        | Fail_worker_entry error, Host.Registered (Host.Worker _) ->
            t.observer <- Observe;
            fail_observer t error
        | Fail_poll_close error, Host.Outer_closed (Host.Poll _) ->
            t.observer <- Observe;
            fail_observer t error
        | ( ( Observe
            | Fail_transition _
            | Fail_poll_close _
            | Fail_progress _
            | Hold_continue _
            | Fail_worker_entry _ ),
            ( Host.Registered _ | Host.Child_entered _
            | Host.Outer_closed
                ( Host.Owner
                | Host.Controls
                | Host.Workflow _
                | Host.Tracker _
                | Host.Cleanup _
                | Host.Worker _
                | Host.Poll _
                | Host.Retry _ )
            | Host.Delivered _ | Host.Retired _ ) ) -> ()
        end

  let start ?(config = F.config F.A) ~sw t =
    let ready, signal_ready = Eio.Promise.create () in
    let result, signal_result = Eio.Promise.create () in
    let scope, signal_scope = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
        let closed =
          capture (fun () ->
              Eio.Switch.run (fun child ->
                  Eio.Promise.resolve signal_ready child;
                  let host =
                    Host.create ~clock:Controller.value
                      ~workspace:Controller.value ~agent:Controller.value
                      ~load:Controller.value
                      ~report:(fun _ -> ())
                      ~report_host:(fun fault ->
                        t.secondary <- fault :: t.secondary;
                        match t.reporter with
                        | Report -> ()
                        | Fail_report error -> raise error)
                      ~observe:(observe t)
                  in
                  let outcome =
                    capture (fun () ->
                        Host.run ~sw:child host ~controls:t.controls config)
                  in
                  Eio.Promise.resolve signal_result outcome;
                  S.notify Controller.value))
        in
        Eio.Promise.resolve signal_scope closed;
        S.notify Controller.value);
    (Eio.Promise.await ready, result, scope)

  let prepare ?(config = F.config F.A) controller =
    complete (reading controller) (F.reply []);
    complete (loading controller) (Ok config);
    complete (reading controller) (F.reply [ service_issue ]);
    running controller

  let refresh t = Eio.Stream.add t.controls Host.Refresh
  let shutdown t = Eio.Stream.add t.controls Host.Shutdown

  let quiet t =
    match (t.oracle, t.bridge, t.projection) with
    | Scheduling_model, Some bridge, _ ->
        Bridge.check_quiescent bridge ~actual:true
    | Causal_worker, _, Some projection ->
        Alcotest.(check int)
          "No worker survives join" 0 projection.Host.Core.running;
        Alcotest.(check int)
          "No owner survives join" 0
          (List.length projection.Host.Core.owners)
    | Scheduling_model, None, _ | Causal_worker, _, None ->
        Alcotest.fail "Graceful service returned without Initial"

  let projection t =
    match t.projection with
    | Some value -> value
    | None -> Alcotest.fail "Projection preceded Initial"

  let same_effect left right =
    match (left, right) with
    | Host.Owner, Host.Owner | Host.Controls, Host.Controls -> true
    | Host.Workflow a, Host.Workflow b
    | Host.Tracker a, Host.Tracker b
    | Host.Cleanup a, Host.Cleanup b
    | Host.Poll a, Host.Poll b -> Request_id.equal a b
    | Host.Worker (ia, a), Host.Worker (ib, b) ->
        Issue_id.equal ia ib && Run_id.equal a b
    | Host.Retry (ia, a), Host.Retry (ib, b) ->
        Issue_id.equal ia ib && Retry_id.equal a b
    | ( ( Host.Owner
        | Host.Controls
        | Host.Workflow _
        | Host.Tracker _
        | Host.Cleanup _
        | Host.Worker _
        | Host.Poll _
        | Host.Retry _ ),
        ( Host.Owner
        | Host.Controls
        | Host.Workflow _
        | Host.Tracker _
        | Host.Cleanup _
        | Host.Worker _
        | Host.Poll _
        | Host.Retry _ ) ) -> false

  let has_retired t key =
    List.exists
      (function
        | Host.Retired other -> same_effect key other
        | Host.Registered _
        | Host.Child_entered _
        | Host.Outer_closed _
        | Host.Delivered _ -> false)
      t.effects

  let has_registered t key =
    List.exists
      (function
        | Host.Registered other -> same_effect key other
        | Host.Retired _
        | Host.Child_entered _
        | Host.Outer_closed _
        | Host.Delivered _ -> false)
      t.effects

  let timer t =
    match t.bridge with
    | None -> None
    | Some bridge ->
        let deadlines =
          List.filter_map
            (function
              | Core_model.Arm_poll (id, due) ->
                  Some (Host.Poll (Bridge.request bridge id), due)
              | Core_model.Arm_retry (id, token, due) ->
                  let issue =
                    match Issue_id.parse id with
                    | Ok value -> value
                    | Error error -> Alcotest.fail error
                  in
                  Some (Host.Retry (issue, Bridge.retry bridge token), due)
              | Core_model.Load_workflow _
              | Core_model.Read_tracker _
              | Core_model.Start_worker _
              | Core_model.Stop_worker _
              | Core_model.Remove_workspace _
              | Core_model.Cancel_request _
              | Core_model.Cancel_poll _
              | Core_model.Cancel_retry _
              | Core_model.Report _ -> None)
            (Bridge.history bridge)
        in
        List.fold_left
          (fun least (key, due) ->
            if (not (has_registered t key)) || has_retired t key then least
            else
              Some
                (match least with
                | None -> due
                | Some previous -> min previous due))
          None deadlines

  let advance_timer t =
    match timer t with
    | None -> false
    | Some due ->
        let requested = F.instant due in
        let current =
          match S.Clock.now Controller.value with
          | Ok value -> value
          | Error diagnostic -> Alcotest.fail (Diagnostic.render diagnostic)
        in
        advance Controller.mono Controller.value
          (if Clock.Pure.compare requested current < 0 then current
           else requested);
        Eio.Fiber.yield ();
        true

  let retired_all t =
    List.for_all
      (function
        | Host.Registered key -> has_retired t key
        | Host.Child_entered _
        | Host.Outer_closed _
        | Host.Delivered _
        | Host.Retired _ -> true)
      t.effects

  let load_secondary t expected =
    let id =
      match S.key expected with
      | S.Load id -> id
      | S.Read _ | S.Remove _ | S.Run _ ->
          Alcotest.fail "Expected loader resource"
    in
    Alcotest.(check int)
      "one canceled loader cleanup diagnostic" 1 (List.length t.secondary);
    List.iter
      (function
        | Host.Secondary_defect { key = Host.Workflow other; diagnostic } ->
            Alcotest.(check bool)
              "loader generation retained" true
              (Request_id.equal id other);
            Alcotest.(check bool)
              "loader report follows actual release" true
              (released Controller.value (S.key expected));
            let text = Diagnostic.render diagnostic in
            Alcotest.(check bool)
              "raw loader defect argument redacted" false (contains text "404")
        | Host.Secondary_defect
            {
              key =
                ( Host.Owner
                | Host.Controls
                | Host.Tracker _
                | Host.Cleanup _
                | Host.Worker _
                | Host.Poll _
                | Host.Retry _ );
              _;
            } -> Alcotest.fail "Canceled loader lost its diagnostic key")
      t.secondary
end

type owner_primary = Observer | Clock_error

let assert_released controller call =
  Alcotest.(check bool)
    "actual protected finalizer released" true
    (released controller (S.key call));
  Alcotest.(check int)
    "no fake resource remains" 0
    (List.length (S.pending controller))

let earlier_owner primary () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create () in
          let child, result, scope = H.start ~sw host in
          let worker = H.prepare controller in
          let defect = Observer_defect 101 in
          begin match primary with
          | Observer -> host.H.observer <- Fail_transition defect
          | Clock_error -> S.fail_next_now controller F.diagnostic
          end;
          H.refresh host;
          workspace_closed controller (S.key worker);
          let parent = Parent_defect 201 in
          Eio.Switch.fail child parent;
          S.close worker S.Close_ok;
          let actual = Eio.Promise.await result in
          ignore (Eio.Promise.await scope);
          assert_released controller worker;
          match (primary, actual) with
          | Observer, Raised (error, backtrace) ->
              Alcotest.(check bool)
                "earlier owner exception identity" true (error == defect);
              H.saved_backtrace host backtrace
          | Clock_error, Returned (Error diagnostic) ->
              Alcotest.(check string)
                "earlier checked clock error"
                (Diagnostic.render F.diagnostic)
                (Diagnostic.render diagnostic)
          | Observer, Returned _ ->
              Alcotest.fail "Earlier observer defect disappeared"
          | Clock_error, (Returned (Ok ()) | Raised _) ->
              Alcotest.fail
                "Later caller cancellation replaced earlier clock Error"))

let earlier_caller () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create () in
          let child, result, scope = H.start ~sw host in
          let worker = H.prepare controller in
          let parent = Parent_defect 202 in
          Eio.Switch.fail child parent;
          workspace_closed controller (S.key worker);
          S.close worker (S.Close_defect (Cleanup_defect 302));
          let actual = Eio.Promise.await result in
          ignore (Eio.Promise.await scope);
          assert_released controller worker;
          H.secondary_worker host worker;
          match actual with
          | Raised (Eio.Cancel.Cancelled cause, _) ->
              Alcotest.(check bool)
                "earlier caller cause identity" true (cause == parent)
          | Raised (error, _) ->
              Alcotest.failf "Unexpected earlier caller result: %s"
                (Printexc.to_string error)
          | Returned _ -> Alcotest.fail "Caller cancellation disappeared"))

let canceled_load () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw:_ ~mono:_ controller ->
          let id, _ = Request_id.Allocator.fresh Request_id.Allocator.empty in
          let request = { S.Load.id; file = F.Config.file (F.config F.A) } in
          let cause = Parent_defect 203 in
          let actual =
            capture (fun () ->
                Eio.Cancel.sub (fun context ->
                    Eio.Cancel.cancel context cause;
                    S.Load.load controller request))
          in
          begin match actual with
          | Raised (Eio.Cancel.Cancelled original, _) ->
              Alcotest.(check bool)
                "canceled context cause retained" true (original == cause)
          | Raised (error, _) ->
              Alcotest.failf "Unexpected canceled loader result: %s"
                (Printexc.to_string error)
          | Returned _ -> Alcotest.fail "Canceled loader entered its callback"
          end;
          Alcotest.(check int)
            "canceled acquisition committed no call" 0
            (List.length (S.pending controller));
          Alcotest.(check int)
            "canceled acquisition emitted no resource fact" 0
            (List.length (S.trace controller))))

let poll_error_before_observer () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create () in
          let _, result, scope = H.start ~sw host in
          let startup = reading controller in
          S.fail_next_sleep controller F.diagnostic;
          host.H.observer <- Fail_poll_close (Observer_defect 102);
          complete startup (F.reply []);
          let actual = Eio.Promise.await result in
          ignore (Eio.Promise.await scope);
          assert_released controller startup;
          match actual with
          | Returned (Error diagnostic) ->
              Alcotest.(check string)
                "closed timer Error precedes observer defect"
                (Diagnostic.render F.diagnostic)
                (Diagnostic.render diagnostic)
          | Returned (Ok ()) | Raised _ ->
              Alcotest.fail
                "Outer_closed observer replaced the closed timer Error"))

let first_resolved_cancel () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono:_ controller ->
          let run, _ = Run_id.Allocator.fresh Run_id.Allocator.empty in
          let plan =
            Lifecycle_fixture.plan (F.config F.A) ~run ~issue:service_issue
              ~attempt:Template.First
          in
          let request = Lifecycle_fixture.Plan.request plan in
          let interrupt, signal_cancel = Eio.Promise.create () in
          Eio.Promise.resolve signal_cancel
            (Agent_runner.Cancel Agent_runner.Reconciliation);
          ignore
            (Eio.Promise.try_resolve signal_cancel
               (Agent_runner.Cancel Agent_runner.Host_shutdown)
              : bool);
          let result, signal_result = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
              let actual =
                capture (fun () ->
                    S.Agent.run controller ~clock:controller
                      ~workspace:controller ~interrupt ~emit:ignore
                      ~refresh:(fun ~turn:_ ->
                        Alcotest.fail "Interrupted runner refreshed")
                      request)
              in
              Eio.Promise.resolve signal_result actual;
              S.notify controller);
          let reached =
            await controller (fun () ->
                match Eio.Promise.peek result with
                | Some value -> Some (`Closed value)
                | None ->
                    Option.map
                      (fun call -> `Acquired call)
                      (List.find_map
                         (fun (S.Pending call) -> run_call call)
                         (S.pending controller)))
          in
          let actual =
            match reached with
            | `Closed value -> value
            | `Acquired call ->
                S.close call S.Close_ok;
                Eio.Promise.await result
          in
          begin match actual with
          | Returned completed ->
              Alcotest.(check bool)
                "closed cancellation retains checked issue/run" true
                (Issue_id.equal (Issue.id service_issue)
                   (S.Agent.completed_issue completed)
                && Run_id.equal run (S.Agent.completed_run completed));
              begin match S.Agent.outcome completed with
              | Agent_runner.Canceled
                  { reason = Agent_runner.Reconciliation; remote_error = None }
                -> ()
              | Agent_runner.Canceled
                  {
                    reason =
                      ( Agent_runner.Reconciliation
                      | Agent_runner.Scope_change
                      | Agent_runner.Host_shutdown );
                    remote_error = _;
                  }
              | Agent_runner.Succeeded
              | Agent_runner.Failed _
              | Agent_runner.Timed_out _
              | Agent_runner.Stalled ->
                  Alcotest.fail
                    "Pre-resolved first cancellation reason was lost"
              end
          | Raised (error, _) ->
              Alcotest.failf "Pre-resolved runner raised: %s"
                (Printexc.to_string error)
          end;
          Alcotest.(check int)
            "pre-resolved cancellation acquires no fake resource" 0
            (List.length (S.trace controller));
          Alcotest.(check int)
            "no pending fake operation" 0
            (List.length (S.pending controller))))

let graceful_result = function
  | Returned (Ok ()) -> ()
  | Returned (Error diagnostic) -> Alcotest.fail (Diagnostic.render diagnostic)
  | Raised (error, _) ->
      Alcotest.failf "Graceful service raised: %s" (Printexc.to_string error)

let cancel_losing_loader () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create () in
          let _, result, scope = H.start ~sw host in
          complete (reading controller) (F.reply []);
          let loader = loading controller in
          H.shutdown host;
          workspace_closed controller (S.key loader);
          S.close loader (S.Close_defect (Cleanup_defect 404));
          let actual = Eio.Promise.await result in
          ignore (Eio.Promise.await scope);
          assert_released controller loader;
          graceful_result actual;
          H.quiet host;
          H.load_secondary host loader))

let success_close_defect () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create () in
          let _, result, scope = H.start ~sw host in
          let worker = H.prepare controller in
          let defect = Cleanup_defect 303 in
          S.respond worker Agent_runner.Succeeded;
          workspace_closed controller (S.key worker);
          S.close worker (S.Close_defect defect);
          let actual = Eio.Promise.await result in
          ignore (Eio.Promise.await scope);
          assert_released controller worker;
          match actual with
          | Raised (error, _) ->
              Alcotest.(check bool)
                "success cannot hide actual close defect" true (error == defect)
          | Returned _ ->
              Alcotest.fail
                "Success fabricated a completed proof despite failed close"))

let pre_entry_defect () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create () in
          let _, result, scope = H.start ~sw host in
          complete (reading controller) (F.reply []);
          complete (loading controller) (Ok (F.config F.A));
          let candidates = reading controller in
          let defect = Observer_defect 103 in
          host.H.observer <- Fail_worker_entry defect;
          complete candidates (F.reply [ service_issue ]);
          let actual = Eio.Promise.await result in
          ignore (Eio.Promise.await scope);
          Alcotest.(check int)
            "no pending fake acquisition" 0
            (List.length (S.pending controller));
          Alcotest.(check bool)
            "resolved pre-entry cancel skips runner acquisition" false
            (List.exists
               (function
                 | S.Acquired (S.Run _) -> true
                 | S.Acquired (S.Load _ | S.Read _ | S.Remove _)
                 | S.Closing _ | S.Released _ -> false)
               (S.trace controller));
          match actual with
          | Raised (error, backtrace) ->
              Alcotest.(check bool)
                "pre-entry primary identity" true (error == defect);
              H.saved_backtrace host backtrace
          | Returned _ -> Alcotest.fail "Pre-entry observer defect disappeared"))

let full_controls () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create () in
          let _, result, scope = H.start ~sw host in
          complete (reading controller) (F.reply []);
          complete (loading controller) (Ok (F.config F.A));
          let other =
            F.issue ~state:"Doing" ~id:"service-1" ~identifier:"SERVICE-1" ()
          in
          complete (reading controller) (F.reply [ service_issue; other ]);
          let workers =
            await controller (fun () ->
                let calls =
                  List.filter_map
                    (fun (S.Pending call) -> run_call call)
                    (S.pending controller)
                in
                if List.length calls = 2 then Some calls else None)
          in
          let defect = Observer_defect 104 in
          host.H.observer <- Fail_transition defect;
          H.refresh host;
          List.iter
            (fun call -> workspace_closed controller (S.key call))
            workers;
          (* The caller owns this blocked producer; fatal service drainage must
             not need either another control receipt or an owner clock read. *)
          H.refresh host;
          let blocked, signal_blocked = Eio.Promise.create () in
          let producer, signal_producer = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
              let actual =
                capture (fun () ->
                    Eio.Cancel.sub (fun context ->
                        Eio.Promise.resolve signal_producer context;
                        H.refresh host))
              in
              Eio.Promise.resolve signal_blocked actual);
          let producer_context = Eio.Promise.await producer in
          Eio.Fiber.yield ();
          Alcotest.(check bool)
            "capacity-one caller producer really blocks" true
            (Option.is_none (Eio.Promise.peek blocked));
          List.iter (fun call -> S.close call S.Close_ok) workers;
          let actual = Eio.Promise.await result in
          ignore (Eio.Promise.await scope);
          Alcotest.(check bool)
            "service closed while caller producer remains blocked" true
            (Option.is_none (Eio.Promise.peek blocked));
          Eio.Cancel.cancel producer_context (Parent_defect 204);
          ignore (Eio.Promise.await blocked);
          List.iter (assert_released controller) workers;
          match actual with
          | Raised (error, backtrace) ->
              Alcotest.(check bool)
                "fatal drain retains original observer" true (error == defect);
              H.saved_backtrace host backtrace
          | Returned _ ->
              Alcotest.fail "Full control source changed fatal result"))

let reused_issue () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create () in
          let _, result, scope = H.start ~sw host in
          let first = H.prepare controller in
          S.respond first Agent_runner.Succeeded;
          workspace_closed controller (S.key first);
          H.refresh host;
          complete (reading controller) (F.reply [ service_issue ]);
          complete (loading controller) (Ok (F.config F.A));
          complete (reading controller) (F.reply [ service_issue ]);
          Eio.Fiber.yield ();
          let acquired_runs =
            List.fold_left
              (fun count -> function
                | S.Acquired (S.Run _) -> count + 1
                | S.Acquired (S.Load _ | S.Read _ | S.Remove _)
                | S.Closing _ | S.Released _ -> count)
              0 (S.trace controller)
          in
          Alcotest.(check int)
            "same issue remains owned until original physical close" 1
            acquired_runs;
          S.close first S.Close_ok;
          ignore
            (await controller (fun () ->
                 if released controller (S.key first) then Some () else None));
          let due =
            await controller (fun () ->
                match host.H.bridge with
                | None -> None
                | Some bridge ->
                    List.find_map
                      (function
                        | Core_model.Arm_retry (id, _, due)
                          when String.equal id "service-0" -> Some due
                        | Core_model.Arm_retry _
                        | Core_model.Load_workflow _
                        | Core_model.Read_tracker _
                        | Core_model.Start_worker _
                        | Core_model.Stop_worker _
                        | Core_model.Remove_workspace _
                        | Core_model.Cancel_request _
                        | Core_model.Arm_poll _
                        | Core_model.Cancel_poll _
                        | Core_model.Cancel_retry _
                        | Core_model.Report _ -> None)
                      (List.rev (H.Bridge.history bridge)))
          in
          advance mono controller (F.instant due);
          let replacement =
            F.issue ~state:"Doing" ~title:"Second snapshot" ~id:"service-0"
              ~identifier:"SERVICE-0" ()
          in
          let rec until_run () =
            match
              List.find_map
                (fun (S.Pending call) -> run_call call)
                (S.pending controller)
            with
            | Some call -> call
            | None ->
                begin match S.pending controller with
                | S.Pending call :: _ -> begin
                    match S.invocation call with
                    | S.Loading _ -> complete call (Ok (F.config F.A))
                    | S.Reading (Tracker_registry.Contract.States { names; _ })
                      ->
                        complete call
                          (F.reply
                             (if List.mem "doing" names then [ replacement ]
                              else []))
                    | S.Reading (Tracker_registry.Contract.Ids _) ->
                        complete call (F.reply [ replacement ])
                    | S.Removing _ -> complete call (Ok ())
                    | S.Running _ ->
                        Alcotest.fail "Run selection equation failed"
                  end
                | [] -> ignore (H.advance_timer host : bool)
                end;
                Eio.Fiber.yield ();
                until_run ()
          in
          let second = until_run () in
          begin match S.invocation second with
          | S.Running request ->
              Alcotest.(check string)
                "new attempt uses refreshed current issue" "Second snapshot"
                (Issue.title (F.Agent.issue request))
          end;
          begin match (S.key first, S.key second) with
          | S.Run (id, old), S.Run (next_id, next) ->
              Alcotest.(check bool)
                "reused ID gets fresh run generation" true
                (Issue_id.equal id next_id && not (Run_id.equal old next));
              Alcotest.(check bool)
                "new acquisition follows original close" true
                (released controller (S.key first))
          | ( (S.Load _ | S.Read _ | S.Remove _ | S.Run _),
              (S.Load _ | S.Read _ | S.Remove _ | S.Run _) ) ->
              Alcotest.fail "Expected two actual run calls"
          end;
          H.shutdown host;
          workspace_closed controller (S.key second);
          let requests = ref [] in
          (* Retained poll cadence may leave a concurrent tracker or preflight
             scope. Shutdown joins those canceled requests through their gates. *)
          List.iter
            (fun (S.Pending call) ->
              match S.invocation call with
              | S.Loading _ | S.Reading _ ->
                  let key = S.key call in
                  workspace_closed controller key;
                  requests := key :: !requests;
                  S.close call S.Close_ok
              | S.Removing _ | S.Running _ -> ())
            (S.pending controller);
          S.close second S.Close_ok;
          graceful_result (Eio.Promise.await result);
          ignore (Eio.Promise.await scope);
          assert_released controller second;
          List.iter
            (fun key ->
              Alcotest.(check bool)
                "Shutdown joins concurrent request scopes" true
                (released controller key))
            !requests;
          Alcotest.(check int)
            "Reused issue teardown releases every acquired resource" 0
            (List.length (S.pending controller));
          H.quiet host))

exception Simulation_failure of string

let actor_failure () =
  let original = Parent_defect 707 in
  let controller = ref None in
  let actual =
    capture (fun () ->
        Eio_mock.Backend.run (fun () ->
            run (fun ~sw ~mono value ->
                controller := Some value;
                let module H = Harness (struct
                  let value = value
                  let mono = mono
                end) in
                let host = H.create () in
                ignore (H.start ~sw host);
                ignore (H.prepare value);
                raise original)))
  in
  begin match actual with
  | Raised (error, _) ->
      Alcotest.(check bool)
        "actor failure identity survives join" true (error == original)
  | Returned _ -> Alcotest.fail "Actor failure disappeared"
  end;
  match !controller with
  | None -> Alcotest.fail "Scenario never entered"
  | Some value ->
      Alcotest.(check int)
        "actor failure leaves no acquired resource" 0
        (List.length (S.pending value))

let simulation_fail fmt =
  Printf.ksprintf (fun message -> raise (Simulation_failure message)) fmt

let show_key = function
  | S.Load id -> "load:" ^ Request_id.text id
  | S.Read id -> "read:" ^ Request_id.text id
  | S.Remove id -> "remove:" ^ Request_id.text id
  | S.Run (id, run) -> "run:" ^ Issue_id.text id ^ ":" ^ Run_id.text run

let program seed length =
  let random = Random.State.make [| seed |] in
  let trace = ref [] in
  let note index text = trace := Printf.sprintf "%d:%s" index text :: !trace in
  let choose values =
    let index = Random.State.int random (List.length values) in
    match
      List.find_map
        (fun (offset, value) -> if offset = index then Some value else None)
        (List.mapi (fun offset value -> (offset, value)) values)
    with
    | Some value -> value
    | None -> simulation_fail "Choice index escaped the finite domain"
  in
  try
    Eio_mock.Backend.run (fun () ->
        run (fun ~sw ~mono controller ->
            let module H = Harness (struct
              let value = controller
              let mono = mono
            end) in
            let host = H.create () in
            let _, result, scope = H.start ~sw host in
            let sample () =
              List.filter_map
                (fun index ->
                  if Random.State.int random 4 = 0 then None
                  else
                    let state = choose [ "Doing"; "Todo"; "Done"; "Closed" ] in
                    Some
                      (F.issue ~state
                         ~title:
                           ("Snapshot-"
                           ^ string_of_int (Random.State.int random 4))
                         ~labels:
                           (List.filter
                              (fun _ -> Random.State.bool random)
                              [ "ready"; "reviewed" ])
                         ~priority:(Random.State.int random 5)
                         ~created_at:
                           (Printf.sprintf "2026-01-01T00:00:%02dZ"
                              (Random.State.int random 60))
                         ~id:("sim-" ^ string_of_int index)
                         ~identifier:("SIM-" ^ string_of_int index)
                         ()))
                [ 0; 1; 2 ]
            in
            let respond : type answer. int -> answer S.call -> unit =
             fun index call ->
              note index ("respond " ^ show_key (S.key call));
              begin match S.invocation call with
              | S.Loading _ ->
                  S.respond call
                    (if Random.State.int random 8 = 0 then
                       Error F.invalid_config
                     else Ok (F.config (choose Core_bridge.profiles)))
              | S.Reading request ->
                  let values = sample () in
                  let selected =
                    match request with
                    | Tracker_registry.Contract.States { names; _ } ->
                        List.filter
                          (fun value -> List.mem (Issue.state_key value) names)
                          values
                    | Tracker_registry.Contract.Ids { ids; _ } ->
                        List.filter
                          (fun value -> Issue_id.Set.mem (Issue.id value) ids)
                          values
                  in
                  S.respond call
                    (if Random.State.int random 8 = 0 then Error F.tracker_error
                     else F.reply selected)
              | S.Removing _ -> S.respond call (Ok ())
              | S.Running _ ->
                  S.respond call
                    (match Random.State.int random 4 with
                    | 0 ->
                        Agent_runner.Failed
                          (Agent_runner.Turn_failed F.diagnostic)
                    | 1 ->
                        Agent_runner.Timed_out
                          (Agent_runner.Response_deadline F.diagnostic)
                    | _ -> Agent_runner.Succeeded)
              end;
              workspace_closed controller (S.key call)
            in
            let act index =
              let rec ready () =
                let before = S.revision controller in
                match Eio.Promise.peek result with
                | Some _ ->
                    simulation_fail "Service finished before scripted shutdown"
                | None -> (
                    let calls = S.pending controller in
                    match (calls, H.timer host) with
                    | [], Some due -> `Timer due
                    | _ :: _, Some due when Random.State.int random 4 = 0 ->
                        `Timer due
                    | _ :: _, (None | Some _) -> `Call (choose calls)
                    | [], None ->
                        S.await_change controller ~after:before;
                        ready ())
              in
              match ready () with
              | `Timer due ->
                  note index ("advance " ^ string_of_int due);
                  ignore (H.advance_timer host : bool)
              | `Call (S.Pending call) ->
                  if closing controller (S.key call) then begin
                    note index ("close " ^ show_key (S.key call));
                    S.close call S.Close_ok;
                    ignore
                      (await controller (fun () ->
                           if released controller (S.key call) then Some ()
                           else None))
                  end
                  else respond index call;
                  Eio.Fiber.yield ()
            in
            for index = 0 to length - 1 do
              act index
            done;
            H.shutdown host;
            let rec drain index =
              let before = S.revision controller in
              match Eio.Promise.peek result with
              | Some value -> value
              | None ->
                  begin match S.pending controller with
                  | S.Pending call :: _ ->
                      if closing controller (S.key call) then begin
                        note index ("tail-close " ^ show_key (S.key call));
                        S.close call S.Close_ok;
                        ignore
                          (await controller (fun () ->
                               if released controller (S.key call) then Some ()
                               else None))
                      end
                      else begin
                        match S.invocation call with
                        | S.Removing _ ->
                            note index ("tail-cleanup " ^ show_key (S.key call));
                            S.respond call (Ok ());
                            workspace_closed controller (S.key call)
                        | S.Loading _ | S.Reading _ | S.Running _ ->
                            S.await_change controller ~after:before
                      end
                  | [] -> S.await_change controller ~after:before
                  end;
                  drain (index + 1)
            in
            let actual = drain length in
            ignore (Eio.Promise.await scope);
            begin match actual with
            | Returned (Ok ()) -> ()
            | Returned (Error diagnostic) ->
                simulation_fail "Unexpected service Error: %s"
                  (Diagnostic.render diagnostic)
            | Raised (error, backtrace) ->
                simulation_fail "Unexpected service exception: %s\n%s"
                  (Printexc.to_string error)
                  (Printexc.raw_backtrace_to_string backtrace)
            end;
            if S.pending controller <> [] then
              simulation_fail "Joined service retained a fake resource";
            if not (H.retired_all host) then
              simulation_fail "Joined service retained a registered effect";
            let acquired =
              List.filter_map
                (function
                  | S.Acquired key -> Some key
                  | S.Closing _ | S.Released _ -> None)
                (S.trace controller)
            in
            List.iter
              (fun key ->
                let count predicate =
                  List.fold_left
                    (fun total event ->
                      if predicate event then total + 1 else total)
                    0 (S.trace controller)
                in
                if
                  count (function
                    | S.Closing other -> same_key key other
                    | S.Acquired _ | S.Released _ -> false)
                  <> 1
                  || count (function
                       | S.Released other -> same_key key other
                       | S.Acquired _ | S.Closing _ -> false)
                     <> 1
                then
                  simulation_fail "Resource did not close exactly once: %s"
                    (show_key key))
              acquired;
            H.quiet host;
            true))
  with Simulation_failure message | Core_bridge.Difference message ->
    simulation_fail "seed=%d prefix=%d\n%s\n%s" seed length message
      (String.concat "\n" (List.rev !trace))

let replay ~seed ~prefix =
  if seed < 0 || prefix < 0 then Error "Seed and prefix must be nonnegative."
  else begin
    ignore (program seed prefix : bool);
    Ok ()
  end

type reporter_primary = No_primary | Owner_primary

let reporter_failure primary () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create () in
          let _, result, scope = H.start ~sw host in
          let reporter = Reporter_defect 501 in
          let owner = Observer_defect 502 in
          host.H.reporter <- Fail_report reporter;
          begin match primary with
          | No_primary ->
              complete (reading controller) (F.reply []);
              let loader = loading controller in
              H.shutdown host;
              workspace_closed controller (S.key loader);
              S.close loader (S.Close_defect (Cleanup_defect 503))
          | Owner_primary ->
              let worker = H.prepare controller in
              host.H.observer <- Fail_transition owner;
              H.refresh host;
              workspace_closed controller (S.key worker);
              S.close worker (S.Close_defect (Cleanup_defect 504))
          end;
          let actual = Eio.Promise.await result in
          ignore (Eio.Promise.await scope);
          Alcotest.(check int)
            "all resources close before reporter failure" 0
            (List.length (S.pending controller));
          match actual with
          | Raised (error, _) ->
              let expected =
                match primary with
                | No_primary -> reporter
                | Owner_primary -> owner
              in
              Alcotest.(check bool)
                "first fatal identity survives reporting" true
                (error == expected)
          | Returned _ -> Alcotest.fail "Host reporter failure disappeared"))

type Eio.Exn.err += Shared_io
type fault_identity = Same_exception | Same_io_payload

let independent_ports identity () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create () in
          let _, result, scope = H.start ~sw host in
          let worker = H.prepare controller in
          let first = Eio.Exn.create Shared_io in
          let second =
            match (identity, first) with
            | Same_exception, _ -> first
            | Same_io_payload, Eio.Io (error, context) -> Eio.Io (error, context)
            | Same_io_payload, _ -> Alcotest.fail "Expected an IO failure"
          in
          S.fail worker second;
          workspace_closed controller (S.key worker);
          host.H.observer <- Fail_transition first;
          H.refresh host;
          ignore (await controller (fun () -> host.H.origin));
          S.close worker S.Close_ok;
          let actual = Eio.Promise.await result in
          ignore (Eio.Promise.await scope);
          assert_released controller worker;
          H.secondary_worker host worker;
          match actual with
          | Raised (error, backtrace) ->
              Alcotest.(check bool)
                "original observer failure survives independent worker failure"
                true (error == first);
              H.saved_backtrace host backtrace
          | Returned _ -> Alcotest.fail "Observer failure disappeared"))

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let thread = checked (Thread_id.parse "thread-service")
let turn = checked (Turn_id.parse "turn-service")
let session_id = checked (Session_id.parse "thread-service-turn-service")
let second_turn = checked (Turn_id.parse "turn-next")
let second_session = checked (Session_id.parse "thread-service-turn-next")

let worker_request (call : Agent_runner.outcome S.call) =
  match S.invocation call with
  | S.Running request -> request

let returned_publication controller call sequence =
  List.exists
    (function
      | S.Publication_returned (key, count) ->
          same_key key (S.key call)
          && Count.compare
               (Positive_count.count sequence)
               (Positive_count.count count)
             = 0
      | S.Publication_entered _ | S.Refresh_entered _ | S.Refresh_returned _ ->
          false)
    (S.worker_trace controller)

let feed controller call sequence notice =
  let sequence = checked (Positive_count.parse (string_of_int sequence)) in
  S.publish call ~sequence notice;
  ignore
    (await controller (fun () ->
         if returned_publication controller call sequence then Some () else None))

let script_session controller call =
  feed controller call 1 F.Agent.Preparing;
  F.with_path
    (F.Agent.workspace (worker_request call))
    (fun path -> feed controller call 2 (F.Agent.Workspace_ready path));
  feed controller call 3 F.Agent.Rendering;
  feed controller call 4 F.Agent.Starting;
  feed controller call 5
    (F.Agent.Protocol
       (Agent_runner.Session_started { session = session_id; thread; turn }))

let refresh_answer controller call turn =
  List.find_map
    (function
      | S.Refresh_returned (key, current, answer)
        when same_key key (S.key call) && Turn_id.equal turn current ->
          Some answer
      | S.Publication_entered _
      | S.Publication_returned _
      | S.Refresh_entered _
      | S.Refresh_returned _ -> None)
    (S.worker_trace controller)

let progress_and_refresh () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create ~oracle:Causal_worker () in
          let _, result, scope = H.start ~sw host in
          let worker = H.prepare controller in
          script_session controller worker;
          let projected = H.projection host in
          (match projected.H.Host.Core.owners with
          | [ H.Host.Core.Worker current ] ->
              Alcotest.(check bool)
                "Acknowledged session is canonical" true
                (current.H.Host.Core.agent_phase = Agent_observation.Running);
              Alcotest.(check string)
                "First accepted turn" "1"
                (Count.decimal current.H.Host.Core.turn_count)
          | []
          | [ (H.Host.Core.Retry _ | H.Host.Core.Cleaning _) ]
          | _ :: _ :: _ -> Alcotest.fail "Session lost its canonical worker");
          let usage =
            Usage.make
              ~input:(checked (Count.parse "9007199254740993"))
              ~output:Count.one
              ~total:(checked (Count.parse "9007199254740998"))
          in
          feed controller worker 6
            (F.Agent.Protocol
               (Agent_runner.Usage_report { thread; turn; absolute = usage }));
          let rates = checked (Json.parse "{\"remaining\":0}") in
          feed controller worker 7
            (F.Agent.Protocol (Agent_runner.Rate_limits rates));
          feed controller worker 8
            (F.Agent.Protocol
               (Agent_runner.Turn_completed { session = session_id; turn }));
          Alcotest.(check int)
            "Inner turn terminal retains worker slot" 1
            (H.projection host).H.Host.Core.running;
          S.refresh worker ~turn;
          let read = reading controller in
          let current =
            F.issue ~state:"Doing" ~title:"Refreshed turn" ~id:"service-0"
              ~identifier:"SERVICE-0" ()
          in
          S.respond read (F.reply [ current ]);
          workspace_closed controller (S.key read);
          Alcotest.(check bool)
            "Refresh waits tracker resource closure" true
            (Option.is_none (refresh_answer controller worker turn));
          S.close read S.Close_ok;
          let answer =
            await controller (fun () -> refresh_answer controller worker turn)
          in
          (match answer with
          | Ok (Agent_runner.Continue issue) ->
              Alcotest.(check string)
                "Callback receives current issue" "Refreshed turn"
                (Issue.title issue)
          | Ok Agent_runner.Stop | Error _ ->
              Alcotest.fail "Active turn did not continue");
          feed controller worker 9
            (F.Agent.Protocol
               (Agent_runner.Turn_started
                  { session = second_session; turn = second_turn }));
          (match (H.projection host).H.Host.Core.owners with
          | [ H.Host.Core.Worker current ] ->
              Alcotest.(check string)
                "Distinct accepted continuation turn" "2"
                (Count.decimal current.H.Host.Core.turn_count)
          | []
          | [ (H.Host.Core.Retry _ | H.Host.Core.Cleaning _) ]
          | _ :: _ :: _ -> Alcotest.fail "Continuation lost its worker");
          H.shutdown host;
          workspace_closed controller (S.key worker);
          S.close worker S.Close_ok;
          graceful_result (Eio.Promise.await result);
          ignore (Eio.Promise.await scope);
          assert_released controller worker;
          H.quiet host;
          let projected = H.projection host in
          Alcotest.(check string)
            "Exact usage survives worker close" "9007199254740998"
            (Count.decimal (Usage.total projected.H.Host.Core.total_usage));
          Alcotest.(check bool)
            "Latest rate limits survive close" true
            (match projected.H.Host.Core.latest_rate_limits with
            | Some value -> Json.equal rates value
            | None -> false);
          Alcotest.(check bool)
            "Every registered Host handle retires" true (H.retired_all host)))

let progress_during_receipt () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create ~oracle:Causal_worker () in
          let _, result, scope = H.start ~sw host in
          let worker = H.prepare controller in
          script_session controller worker;
          feed controller worker 6
            (F.Agent.Protocol
               (Agent_runner.Turn_completed { session = session_id; turn }));
          let entered, signal_entered = Eio.Promise.create () in
          let receipt, permit_receipt = Eio.Promise.create () in
          let late, permit_late = Eio.Promise.create () in
          let permit resolver =
            ignore (Eio.Promise.try_resolve resolver () : bool)
          in
          Fun.protect
            ~finally:(fun () ->
              permit permit_late;
              permit permit_receipt)
            (fun () ->
              host.H.observer <- Hold_continue (signal_entered, receipt);
              let sequence = checked (Positive_count.parse "7") in
              let usage =
                Usage.make
                  ~input:(checked (Count.parse "9007199254740993"))
                  ~output:Count.one
                  ~total:(checked (Count.parse "9007199254740998"))
              in
              S.refresh_with_progress worker ~turn ~sequence ~after:late
                (F.Agent.Protocol
                   (Agent_runner.Usage_report { thread; turn; absolute = usage }));
              Eio.Promise.await entered;
              Alcotest.(check int)
                "Pending continuation receipt retains custody" 1
                (H.projection host).H.Host.Core.running;
              permit permit_late;
              ignore
                (await controller (fun () ->
                     if
                       List.exists
                         (function
                           | S.Publication_entered (key, count) ->
                               same_key key (S.key worker)
                               && Count.compare
                                    (Positive_count.count count)
                                    (Positive_count.count sequence)
                                  = 0
                           | S.Publication_returned _
                           | S.Refresh_entered _
                           | S.Refresh_returned _ -> false)
                         (S.worker_trace controller)
                     then Some ()
                     else None));
              Eio.Fiber.yield ();
              Alcotest.(check bool)
                "Late publication waits owner acknowledgement" false
                (returned_publication controller worker sequence);
              Alcotest.(check bool)
                "Tracker decision has not answered refresh" true
                (Option.is_none (refresh_answer controller worker turn));
              permit permit_receipt;
              let next =
                await controller (fun () ->
                    if returned_publication controller worker sequence then
                      Some `Receipt
                    else if closing controller (S.key worker) then Some `Closed
                    else None)
              in
              (match next with
              | `Closed ->
                  (* A failing host must still join the fixture resources before
                     the regression reports the actual callback defect. *)
                  let actual =
                    await controller (fun () ->
                        List.iter
                          (fun (S.Pending call) -> S.close call S.Close_ok)
                          (S.pending controller);
                        Eio.Promise.peek result)
                  in
                  ignore (Eio.Promise.await scope);
                  assert_released controller worker;
                  graceful_result actual;
                  Alcotest.fail "Late publication closed a live worker"
              | `Receipt -> ());
              let read = reading controller in
              Alcotest.(check bool)
                "Progress receipt precedes tracker decision" true
                (Option.is_none (refresh_answer controller worker turn));
              let delivered =
                List.filter_map
                  (fun transition ->
                    match transition.H.Host.input with
                    | H.Host.Core.Worker_continue (_, _, current)
                      when Turn_id.equal current turn -> Some "continuation"
                    | H.Host.Core.Worker_progress { progress; _ }
                      when Count.compare
                             (Positive_count.count
                                (H.P.Agent.sequence progress))
                             (Positive_count.count sequence)
                           = 0 -> Some "usage"
                    | H.Host.Core.Poll_due _
                    | H.Host.Core.Refresh_requested
                    | H.Host.Core.Workflow_changed
                    | H.Host.Core.Workflow_loaded _
                    | H.Host.Core.Tracker_completed _
                    | H.Host.Core.Worker_started _
                    | H.Host.Core.Worker_progress _
                    | H.Host.Core.Worker_continue _
                    | H.Host.Core.Worker_finished _
                    | H.Host.Core.Request_canceled _
                    | H.Host.Core.Retry_due _
                    | H.Host.Core.Workspace_removed _
                    | H.Host.Core.Shutdown -> None)
                  (List.rev host.H.transitions)
              in
              Alcotest.(check (list string))
                "Owner receives both messages in publication order"
                [ "continuation"; "usage" ]
                delivered;
              Alcotest.(check string)
                "Late usage reaches canonical projection" "9007199254740998"
                (Count.decimal
                   (Usage.total (H.projection host).H.Host.Core.total_usage));
              complete read (F.reply [ service_issue ]);
              (match
                 await controller (fun () ->
                     refresh_answer controller worker turn)
               with
              | Ok (Agent_runner.Continue _) -> ()
              | Ok Agent_runner.Stop | Error _ ->
                  Alcotest.fail "Refresh lost its fenced tracker answer");
              H.shutdown host;
              workspace_closed controller (S.key worker);
              S.close worker S.Close_ok;
              graceful_result (Eio.Promise.await result);
              ignore (Eio.Promise.await scope);
              assert_released controller worker;
              H.quiet host;
              Alcotest.(check bool)
                "Both receipted messages finish without Host fatal" true
                (H.retired_all host))))

let progress_observer_failure () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create ~oracle:Causal_worker () in
          let _, result, scope = H.start ~sw host in
          let worker = H.prepare controller in
          let defect = Observer_defect 105 in
          host.H.observer <- Fail_progress defect;
          S.publish worker ~sequence:Positive_count.first F.Agent.Preparing;
          workspace_closed controller (S.key worker);
          S.close worker S.Close_ok;
          let actual = Eio.Promise.await result in
          ignore (Eio.Promise.await scope);
          assert_released controller worker;
          Alcotest.(check bool)
            "Observer failure joins every acquired fake scope" true
            (List.for_all
               (function
                 | S.Acquired key -> released controller key
                 | S.Closing _ | S.Released _ -> true)
               (S.trace controller));
          match actual with
          | Raised (error, backtrace) ->
              Alcotest.(check bool)
                "Receipt observer retains primary identity" true
                (error == defect);
              H.saved_backtrace host backtrace
          | Returned _ -> Alcotest.fail "Progress observer failure disappeared"))

let cancel_refresh_join () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create ~oracle:Causal_worker () in
          let _, result, scope = H.start ~sw host in
          let worker = H.prepare controller in
          script_session controller worker;
          feed controller worker 6
            (F.Agent.Protocol
               (Agent_runner.Turn_completed { session = session_id; turn }));
          S.refresh worker ~turn;
          let read = reading controller in
          H.shutdown host;
          workspace_closed controller (S.key worker);
          workspace_closed controller (S.key read);
          Alcotest.(check int)
            "Cancellation retains worker until close" 1
            (H.projection host).H.Host.Core.running;
          S.close worker S.Close_ok;
          ignore
            (await controller (fun () ->
                 if (H.projection host).H.Host.Core.running = 0 then Some ()
                 else None));
          Alcotest.(check bool)
            "Closed worker cannot skip canceled refresh closure" true
            (Option.is_none (Eio.Promise.peek result));
          S.close read S.Close_ok;
          graceful_result (Eio.Promise.await result);
          ignore (Eio.Promise.await scope);
          assert_released controller worker;
          H.quiet host;
          Alcotest.(check bool)
            "Canceled refresh releases its fake resource" true
            (released controller (S.key read));
          (match refresh_answer controller worker turn with
          | Some (Ok Agent_runner.Stop) -> ()
          | Some (Ok (Agent_runner.Continue _) | Error _) | None ->
              Alcotest.fail "Interrupted refresh did not return Stop");
          Alcotest.(check bool)
            "Canceled waiters and handles retire" true (H.retired_all host)))

let typed_stall () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let config = F.with_stall ~milliseconds:10 F.A in
          let host = H.create ~oracle:Causal_worker () in
          let _, result, scope = H.start ~config ~sw host in
          let worker = H.prepare ~config controller in
          advance mono controller (F.instant 10);
          let equality_read = reading controller in
          Alcotest.(check bool)
            "Equality does not interrupt the worker" false
            (closing controller (S.key worker));
          complete equality_read (F.reply [ service_issue ]);
          complete (loading controller) (Ok config);
          complete (reading controller) (F.reply [ service_issue ]);
          ignore
            (await controller (fun () ->
                 if
                   List.exists
                     (fun (transition : H.Host.transition) ->
                       Clock.Pure.compare transition.H.Host.now (F.instant 10)
                       = 0
                       && List.exists
                            (function
                              | H.Host.Core.Arm_poll _ -> true
                              | H.Host.Core.Load_workflow _
                              | H.Host.Core.Read_tracker _
                              | H.Host.Core.Start_worker _
                              | H.Host.Core.Stop_worker _
                              | H.Host.Core.Continue_worker _
                              | H.Host.Core.Remove_workspace _
                              | H.Host.Core.Cancel_request _
                              | H.Host.Core.Cancel_poll _
                              | H.Host.Core.Arm_retry _
                              | H.Host.Core.Cancel_retry _
                              | H.Host.Core.Report _ -> false)
                            transition.H.Host.commands)
                     host.H.transitions
                 then Some ()
                 else None));
          advance mono controller (F.instant 15);
          workspace_closed controller (S.key worker);
          let read = reading controller in
          Alcotest.(check bool)
            "Owner emits typed Stall interruption" true
            (List.exists
               (fun (transition : H.Host.transition) ->
                 List.exists
                   (function
                     | H.Host.Core.Stop_worker (_, _, Agent_runner.Stall) ->
                         true
                     | H.Host.Core.Stop_worker (_, _, Agent_runner.Cancel _)
                     | H.Host.Core.Load_workflow _
                     | H.Host.Core.Read_tracker _
                     | H.Host.Core.Start_worker _
                     | H.Host.Core.Continue_worker _
                     | H.Host.Core.Remove_workspace _
                     | H.Host.Core.Cancel_request _
                     | H.Host.Core.Arm_poll _
                     | H.Host.Core.Cancel_poll _
                     | H.Host.Core.Arm_retry _
                     | H.Host.Core.Cancel_retry _
                     | H.Host.Core.Report _ -> false)
                   transition.H.Host.commands)
               host.H.transitions);
          Alcotest.(check int)
            "Stall keeps slot during protected close" 1
            (H.projection host).H.Host.Core.running;
          S.close worker S.Close_ok;
          ignore
            (await controller (fun () ->
                 match (H.projection host).H.Host.Core.owners with
                 | [ H.Host.Core.Retry _ ] -> Some ()
                 | []
                 | [ (H.Host.Core.Worker _ | H.Host.Core.Cleaning _) ]
                 | _ :: _ :: _ -> None));
          Alcotest.(check bool)
            "Port publishes Stalled only after scope close" true
            (List.exists
               (fun (transition : H.Host.transition) ->
                 match transition.H.Host.input with
                 | H.Host.Core.Worker_finished completed ->
                     S.Agent.outcome completed = Agent_runner.Stalled
                 | H.Host.Core.Poll_due _
                 | H.Host.Core.Refresh_requested
                 | H.Host.Core.Workflow_changed
                 | H.Host.Core.Workflow_loaded _
                 | H.Host.Core.Tracker_completed _
                 | H.Host.Core.Worker_started _
                 | H.Host.Core.Worker_progress _
                 | H.Host.Core.Worker_continue _
                 | H.Host.Core.Request_canceled _
                 | H.Host.Core.Retry_due _
                 | H.Host.Core.Workspace_removed _
                 | H.Host.Core.Shutdown -> false)
               host.H.transitions);
          H.shutdown host;
          workspace_closed controller (S.key read);
          S.close read S.Close_ok;
          graceful_result (Eio.Promise.await result);
          ignore (Eio.Promise.await scope);
          assert_released controller worker;
          H.quiet host;
          Alcotest.(check bool)
            "Typed stall leaves no Host custody" true (H.retired_all host)))

let stalled_refresh_reconcile () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let config = F.with_stall ~milliseconds:10 F.A in
          let host = H.create ~oracle:Causal_worker () in
          let _, result, scope = H.start ~config ~sw host in
          let worker = H.prepare ~config controller in
          script_session controller worker;
          feed controller worker 6
            (F.Agent.Protocol
               (Agent_runner.Turn_completed { session = session_id; turn }));
          S.refresh worker ~turn;
          let original = reading controller in
          let original_id =
            match S.key original with
            | S.Read id -> id
            | S.Load _ | S.Remove _ | S.Run _ ->
                Alcotest.fail "Expected continuation tracker scope"
          in
          let reads (transition : H.Host.transition) =
            List.filter_map
              (function
                | H.Host.Core.Read_tracker request -> Some request
                | H.Host.Core.Load_workflow _
                | H.Host.Core.Start_worker _
                | H.Host.Core.Stop_worker _
                | H.Host.Core.Continue_worker _
                | H.Host.Core.Remove_workspace _
                | H.Host.Core.Cancel_request _
                | H.Host.Core.Arm_poll _
                | H.Host.Core.Cancel_poll _
                | H.Host.Core.Arm_retry _
                | H.Host.Core.Cancel_retry _
                | H.Host.Core.Report _ -> None)
              transition.H.Host.commands
          in
          let terminal matches =
            await controller (fun () ->
                List.find_opt
                  (fun (transition : H.Host.transition) ->
                    matches transition.H.Host.input)
                  host.H.transitions)
          in
          let request_matches expected = function
            | H.Host.Core.Request_canceled id -> Request_id.equal expected id
            | H.Host.Core.Poll_due _
            | H.Host.Core.Refresh_requested
            | H.Host.Core.Workflow_changed
            | H.Host.Core.Workflow_loaded _
            | H.Host.Core.Tracker_completed _
            | H.Host.Core.Worker_started _
            | H.Host.Core.Worker_progress _
            | H.Host.Core.Worker_continue _
            | H.Host.Core.Worker_finished _
            | H.Host.Core.Retry_due _
            | H.Host.Core.Workspace_removed _
            | H.Host.Core.Shutdown -> false
          in

          (* The owner poll must defer reconciliation until the canceled read
             closes; its finalizer cannot be mistaken for an accepted reply. *)
          advance mono controller (F.instant 15);
          workspace_closed controller (S.key worker);
          workspace_closed controller (S.key original);
          let poll =
            terminal (function
              | H.Host.Core.Poll_due _ -> true
              | H.Host.Core.Refresh_requested
              | H.Host.Core.Workflow_changed
              | H.Host.Core.Workflow_loaded _
              | H.Host.Core.Tracker_completed _
              | H.Host.Core.Worker_started _
              | H.Host.Core.Worker_progress _
              | H.Host.Core.Worker_continue _
              | H.Host.Core.Worker_finished _
              | H.Host.Core.Request_canceled _
              | H.Host.Core.Retry_due _
              | H.Host.Core.Workspace_removed _
              | H.Host.Core.Shutdown -> false)
          in
          Alcotest.(check int)
            "Canceled read retains exclusive tracker custody" 0
            (List.length (reads poll));
          Alcotest.(check bool)
            "Canceled tracker remains physically open" false
            (released controller (S.key original));
          Alcotest.(check int)
            "Stalled worker retains its slot during close" 1
            (H.projection host).H.Host.Core.running;
          S.close original S.Close_ok;
          let canceled = terminal (request_matches original_id) in
          let fresh_id =
            match reads canceled with
            | [ Tracker_registry.Contract.Ids { id; binding; ids; _ } ] ->
                Alcotest.(check bool)
                  "Reconciliation uses the worker's original binding" true
                  (Tracker_registry.Contract.equal binding
                     (F.Config.tracker config));
                Alcotest.(check bool)
                  "Reconciliation targets only the stopped issue" true
                  (Issue_id.Set.equal ids
                     (Issue_id.Set.singleton (Issue.id service_issue)));
                id
            | [] ->
                Alcotest.fail
                  "Closed continuation must resume deferred reconciliation"
            | [ Tracker_registry.Contract.States _ ] | _ :: _ :: _ ->
                Alcotest.fail "Expected one fresh issue reconciliation"
          in
          Alcotest.(check bool)
            "Canceled request identity is retired" false
            (Request_id.equal original_id fresh_id);
          let fresh = reading controller in
          Alcotest.(check bool)
            "Fresh tracker starts after original scope release" true
            (released controller (S.key original));
          Alcotest.(check bool)
            "Fresh scope carries the emitted request identity" true
            (same_key (S.Read fresh_id) (S.key fresh));
          let done_issue =
            F.issue ~state:"Done" ~id:"service-0" ~identifier:"SERVICE-0" ()
          in
          complete fresh (F.reply [ done_issue ]);
          ignore
            (terminal (function
              | H.Host.Core.Tracker_completed (id, _) ->
                  Request_id.equal fresh_id id
              | H.Host.Core.Poll_due _
              | H.Host.Core.Refresh_requested
              | H.Host.Core.Workflow_changed
              | H.Host.Core.Workflow_loaded _
              | H.Host.Core.Worker_started _
              | H.Host.Core.Worker_progress _
              | H.Host.Core.Worker_continue _
              | H.Host.Core.Worker_finished _
              | H.Host.Core.Request_canceled _
              | H.Host.Core.Retry_due _
              | H.Host.Core.Workspace_removed _
              | H.Host.Core.Shutdown -> false));
          Alcotest.(check bool)
            "Terminal tracker reply cannot release the worker" false
            (released controller (S.key worker));
          Alcotest.(check bool)
            "Cleanup waits for closed worker proof" false
            (List.exists
               (function
                 | S.Acquired (S.Remove _) -> true
                 | S.Acquired (S.Load _ | S.Read _ | S.Run _)
                 | S.Closing _ | S.Released _ -> false)
               (S.trace controller));

          (* Shutdown before retry must retain the accepted terminal cleanup. *)
          H.shutdown host;
          ignore
            (terminal (function
              | H.Host.Core.Shutdown -> true
              | H.Host.Core.Poll_due _
              | H.Host.Core.Refresh_requested
              | H.Host.Core.Workflow_changed
              | H.Host.Core.Workflow_loaded _
              | H.Host.Core.Tracker_completed _
              | H.Host.Core.Worker_started _
              | H.Host.Core.Worker_progress _
              | H.Host.Core.Worker_continue _
              | H.Host.Core.Worker_finished _
              | H.Host.Core.Request_canceled _
              | H.Host.Core.Retry_due _
              | H.Host.Core.Workspace_removed _ -> false));
          List.iter
            (fun (S.Pending call) ->
              match S.invocation call with
              | S.Loading _ | S.Reading _ -> S.close call S.Close_ok
              | S.Removing _ | S.Running _ -> ())
            (S.pending controller);
          S.close worker S.Close_ok;
          let finish_cleanup =
            await controller (fun () ->
                List.find_map
                  (fun (S.Pending call) ->
                    match S.invocation call with
                    | S.Removing _ -> Some (fun () -> complete call (Ok ()))
                    | S.Loading _ | S.Reading _ | S.Running _ -> None)
                  (S.pending controller))
          in
          Alcotest.(check bool)
            "Cleanup acquisition follows worker release" true
            (released controller (S.key worker));
          Alcotest.(check bool)
            "Service joins the pending cleanup" true
            (Option.is_none (Eio.Promise.peek result));
          finish_cleanup ();
          graceful_result (Eio.Promise.await result);
          ignore (Eio.Promise.await scope);
          assert_released controller worker;
          H.quiet host;
          Alcotest.(check bool)
            "Deferred reconciliation leaves no Host custody" true
            (H.retired_all host)))

let repeated_refresh_contract () =
  Eio_mock.Backend.run (fun () ->
      run (fun ~sw ~mono controller ->
          let module H = Harness (struct
            let value = controller
            let mono = mono
          end) in
          let host = H.create ~oracle:Causal_worker () in
          let _, result, scope = H.start ~sw host in
          let worker = H.prepare controller in
          script_session controller worker;
          feed controller worker 6
            (F.Agent.Protocol
               (Agent_runner.Turn_completed { session = session_id; turn }));
          S.refresh worker ~turn;
          complete (reading controller) (F.reply [ service_issue ]);
          ignore
            (await controller (fun () -> refresh_answer controller worker turn));
          S.refresh worker ~turn;
          let requests () =
            List.fold_left
              (fun count (transition : H.Host.transition) ->
                match transition.H.Host.input with
                | H.Host.Core.Worker_continue (_, _, current)
                  when Turn_id.equal current turn -> count + 1
                | H.Host.Core.Poll_due _
                | H.Host.Core.Refresh_requested
                | H.Host.Core.Workflow_changed
                | H.Host.Core.Workflow_loaded _
                | H.Host.Core.Tracker_completed _
                | H.Host.Core.Worker_started _
                | H.Host.Core.Worker_progress _
                | H.Host.Core.Worker_continue _
                | H.Host.Core.Worker_finished _
                | H.Host.Core.Request_canceled _
                | H.Host.Core.Retry_due _
                | H.Host.Core.Workspace_removed _
                | H.Host.Core.Shutdown -> count)
              0 host.H.transitions
          in
          let returns () =
            List.fold_left
              (fun count -> function
                | S.Refresh_returned (key, current, _)
                  when same_key key (S.key worker) && Turn_id.equal current turn
                  -> count + 1
                | S.Publication_entered _
                | S.Publication_returned _
                | S.Refresh_entered _
                | S.Refresh_returned _ -> count)
              0
              (S.worker_trace controller)
          in
          let next =
            await controller (fun () ->
                if closing controller (S.key worker) then Some `Rejected
                else if requests () = 2 then Some `Waiting
                else None)
          in
          begin match next with
          | `Rejected -> ()
          | `Waiting ->
              Alcotest.(check int)
                "Repeated callback is still awaiting an answer" 1 (returns ());
              H.shutdown host;
              workspace_closed controller (S.key worker)
          end;
          S.close worker S.Close_ok;
          let actual = Eio.Promise.await result in
          ignore (Eio.Promise.await scope);
          assert_released controller worker;
          match actual with
          | Raised (error, _) ->
              Alcotest.(check bool)
                "Repeated callback is a port contract defect" true
                (contains (Printexc.to_string error) "Broken_contract");
              Alcotest.(check int)
                "Rejected callback never reaches owner" 1 (requests ());
              Alcotest.(check int)
                "Only the accepted callback returns an answer" 1 (returns ())
          | Returned _ ->
              Alcotest.fail
                "Repeated refresh required interruption instead of rejecting \
                 the port defect"))

let tests =
  [
    Alcotest.test_case "independent ports may raise the same exception" `Quick
      (independent_ports Same_exception);
    Alcotest.test_case "independent ports may share an IO payload" `Quick
      (independent_ports Same_io_payload);
    Alcotest.test_case "host reporter defect becomes the first fatal failure"
      `Quick
      (reporter_failure No_primary);
    Alcotest.test_case "host reporter defect cannot replace an earlier primary"
      `Quick
      (reporter_failure Owner_primary);
    Alcotest.test_case "actor failure releases owned finalizer gates" `Quick
      actor_failure;
    Alcotest.test_case
      "reused issue waits for original scope and gets fresh generation" `Quick
      reused_issue;
    Alcotest.test_case
      "cancel winner preserves semantic close and reports loser" `Quick
      cancel_losing_loader;
    Alcotest.test_case "successful runner exposes actual closing defect" `Quick
      success_close_defect;
    Alcotest.test_case "pre-entry observer defect closes undelivered worker"
      `Quick pre_entry_defect;
    Alcotest.test_case "fatal drain ignores a full caller control stream" `Quick
      full_controls;
    Alcotest.test_case "first resolved cancel skips all acquisition" `Quick
      first_resolved_cancel;
    Alcotest.test_case "already canceled loader creates no resource" `Quick
      canceled_load;
    Alcotest.test_case "closed timer Error precedes observer defect" `Quick
      poll_error_before_observer;
    Alcotest.test_case "earlier observer defect survives caller cancellation"
      `Quick (earlier_owner Observer);
    Alcotest.test_case "earlier clock Error survives caller cancellation" `Quick
      (earlier_owner Clock_error);
    Alcotest.test_case "earlier caller cancellation survives cleanup defect"
      `Quick earlier_caller;
    Alcotest.test_case "acknowledged progress and fenced refresh" `Quick
      progress_and_refresh;
    Alcotest.test_case "late usage waits continuation owner receipt" `Quick
      progress_during_receipt;
    Alcotest.test_case "observer failure releases pending publication" `Quick
      progress_observer_failure;
    Alcotest.test_case "cancellation joins refresh and worker scopes" `Quick
      cancel_refresh_join;
    Alcotest.test_case "typed stall waits closed worker proof" `Quick
      typed_stall;
    Alcotest.test_case "stalled refresh resumes terminal reconciliation" `Quick
      stalled_refresh_reconcile;
    Alcotest.test_case "repeated refresh rejects before owner delivery" `Quick
      repeated_refresh_contract;
  ]

let properties =
  let open QCheck2 in
  let gen =
    Gen.map2
      (fun seed length -> (seed, length))
      (Gen.no_shrink (Gen.int_range 0 1_000_000))
      (Gen.set_shrink (Shrink.int_towards 0) (Gen.int_range 50 60))
  in
  [
    Test.make ~name:"actual Service mailbox agrees with independent core model"
      ~count:1000
      ~print:(fun (seed, length) ->
        Printf.sprintf "seed=%d prefix=%d" seed length)
      gen
      (fun (seed, length) ->
        try program seed length
        with Simulation_failure message -> Test.fail_report message);
  ]
