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

module Harness (Controller : sig
  val value : S.t
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
  }

  let create () =
    {
      controls = Eio.Stream.create 1;
      bridge = None;
      observer = Observe;
      reporter = Report;
      effects = [];
      secondary = [];
      origin = None;
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
    | Host.Core.Retry_due _
    | Host.Core.Shutdown -> ()

  let observe t = function
    | Host.Initial value ->
        let bridge, _ =
          Bridge.initial ~profile:F.A ~now:value.Host.now
            ~commands:value.Host.commands ~projection:value.Host.projection
        in
        t.bridge <- Some bridge;
        S.notify Controller.value
    | Host.Transition value ->
        closed_input value.Host.input;
        let previous =
          match t.bridge with
          | Some value -> value
          | None -> Alcotest.fail "Transition preceded Initial"
        in
        let bridge, _, _ =
          Bridge.accept previous ~now:value.Host.now ~input:value.Host.input
            ~commands:value.Host.commands ~projection:value.Host.projection
        in
        t.bridge <- Some bridge;
        S.notify Controller.value;
        begin match t.observer with
        | Observe | Fail_poll_close _ | Fail_worker_entry _ -> ()
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

  let start ~sw t =
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
                        Host.run ~sw:child host ~controls:t.controls
                          (F.config F.A))
                  in
                  Eio.Promise.resolve signal_result outcome;
                  S.notify Controller.value))
        in
        Eio.Promise.resolve signal_scope closed;
        S.notify Controller.value);
    (Eio.Promise.await ready, result, scope)

  let prepare controller =
    complete (reading controller) (F.reply []);
    complete (loading controller) (Ok (F.config F.A));
    complete (reading controller) (F.reply [ service_issue ]);
    running controller

  let refresh t = Eio.Stream.add t.controls Host.Refresh
  let shutdown t = Eio.Stream.add t.controls Host.Shutdown

  let quiet t =
    match t.bridge with
    | Some bridge -> Bridge.check_quiescent bridge ~actual:true
    | None -> Alcotest.fail "Graceful service returned without Initial"

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
        S.advance Controller.value
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
      S.run (fun ~sw controller ->
          let module H = Harness (struct
            let value = controller
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
      S.run (fun ~sw controller ->
          let module H = Harness (struct
            let value = controller
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
      S.run (fun ~sw:_ controller ->
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
      S.run (fun ~sw controller ->
          let module H = Harness (struct
            let value = controller
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
      S.run (fun ~sw controller ->
          let run, _ = Run_id.Allocator.fresh Run_id.Allocator.empty in
          let plan =
            Lifecycle_fixture.plan (F.config F.A) ~run ~issue:service_issue
              ~attempt:Template.First
          in
          let request = Lifecycle_fixture.Plan.request plan in
          let cancel, signal_cancel = Eio.Promise.create () in
          Eio.Promise.resolve signal_cancel Agent_runner.Reconciliation;
          ignore
            (Eio.Promise.try_resolve signal_cancel Agent_runner.Host_shutdown
              : bool);
          let result, signal_result = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
              let actual =
                capture (fun () ->
                    S.Agent.run controller ~clock:controller
                      ~workspace:controller ~cancel request)
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
      S.run (fun ~sw controller ->
          let module H = Harness (struct
            let value = controller
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
      S.run (fun ~sw controller ->
          let module H = Harness (struct
            let value = controller
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
      S.run (fun ~sw controller ->
          let module H = Harness (struct
            let value = controller
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
      S.run (fun ~sw controller ->
          let module H = Harness (struct
            let value = controller
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
      S.run (fun ~sw controller ->
          let module H = Harness (struct
            let value = controller
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
          S.advance controller (F.instant due);
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
          S.close second S.Close_ok;
          graceful_result (Eio.Promise.await result);
          ignore (Eio.Promise.await scope);
          assert_released controller second;
          H.quiet host))

exception Simulation_failure of string

let actor_failure () =
  let original = Parent_defect 707 in
  let controller = ref None in
  let actual =
    capture (fun () ->
        Eio_mock.Backend.run (fun () ->
            S.run (fun ~sw value ->
                controller := Some value;
                let module H = Harness (struct
                  let value = value
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
        S.run (fun ~sw controller ->
            let module H = Harness (struct
              let value = controller
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
      S.run (fun ~sw controller ->
          let module H = Harness (struct
            let value = controller
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

let tests =
  [
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
