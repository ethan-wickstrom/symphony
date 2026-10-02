(** Scoped effect interpreter over the implemented scheduling reducer. *)

module type WORKFLOW_LOAD = sig
  type config
  type t
  type request = { id : Request_id.t; file : Workflow_path.t }

  val load : t -> request -> (config, Config_layer.error) result
  (** Bounded scoped read/parse/resolve through captured registry/environment.
      The request ID supplies causal identity, not scheduling authority.
      Expected failures are values; cancellation and defects propagate. *)
end

module type CLOSED_RUNNER = sig
  include Agent_runner.PURE

  type t
  type clock
  type workspace_manager

  val run :
    t ->
    clock:clock ->
    workspace:workspace_manager ->
    cancel:Agent_runner.cancel_reason Eio.Promise.t ->
    request ->
    completed
  (** Use exactly the supplied clock and workspace instance. Return only after
      this invocation's workspace/process/hook scopes close. A previously
      resolved cancellation promise reaches the runner, which must discharge it
      with a matching Canceled completion and no workspace/process/hook
      acquisition, after its empty invocation scope closes. Only the runner
      constructs its opaque completion. Unrequested cancellation and defects
      drain then propagate with the supplied exception identity/backtrace. No
      progress/continuation/stall input is added to the first service operation
      language. *)
end

module Make
    (Tracker : Tracker.S)
    (Clock : Clock.S)
    (Workspace : Workspace_manager.S)
    (Agent :
      CLOSED_RUNNER
        with module Issue = Tracker.Contract.Issue
         and module Path = Workspace.Contract.Path
         and type workspace = Workspace.Contract.reference
         and type clock = Clock.t
         and type workspace_manager = Workspace.t)
    (Config : Config_layer.PURE with type tracker = Tracker.Contract.binding)
    (Load : WORKFLOW_LOAD with type config = Config.t) =
struct
  module Failure = Service_failure
  open Failure

  module Core =
    Orchestrator.Make (Tracker.Contract) (Clock.Pure) (Workspace.Contract)
      (Agent)
      (Config)

  type control = Refresh | Shutdown

  type transition = {
    now : Clock.Pure.instant;
    input : Core.input;
    projection : Core.projection;
    commands : Core.command list;
    elapsed : Seconds.t;
  }

  type effect_key =
    | Owner
    | Controls
    | Workflow of Request_id.t
    | Tracker of Request_id.t
    | Cleanup of Request_id.t
    | Worker of Issue_id.t * Run_id.t
    | Poll of Request_id.t
    | Retry of Issue_id.t * Retry_id.t

  type host_fault =
    | Secondary_defect of { key : effect_key; diagnostic : Diagnostic.t }

  type delivery = Entry | Terminal | Private_close

  type effect_event =
    | Registered of effect_key
    | Child_entered of effect_key
    | Outer_closed of effect_key
    | Delivered of effect_key * delivery
    | Retired of effect_key

  type initial = {
    now : Clock.Pure.instant;
    projection : Core.projection;
    commands : Core.command list;
    elapsed : Seconds.t;
  }

  type observation =
    | Initial of initial
    | Transition of transition
    | Effect of effect_event

  type t = {
    clock : Clock.t;
    workspace : Workspace.t;
    agent : Agent.t;
    load : Load.t;
    report : Core.fault -> unit;
    report_host : host_fault -> unit;
    observe : observation -> unit;
  }

  let create ~clock ~workspace ~agent ~load ~report ~report_host ~observe =
    { clock; workspace; agent; load; report; report_host; observe }

  module Keys = struct
    type t = effect_key

    let rank = function
      | Owner -> 0
      | Controls -> 1
      | Workflow _ -> 2
      | Tracker _ -> 3
      | Cleanup _ -> 4
      | Worker _ -> 5
      | Poll _ -> 6
      | Retry _ -> 7

    let compare a b =
      let order = Int.compare (rank a) (rank b) in
      if order <> 0 then order
      else
        match (a, b) with
        | Owner, Owner | Controls, Controls -> 0
        | Workflow a, Workflow b
        | Tracker a, Tracker b
        | Cleanup a, Cleanup b
        | Poll a, Poll b -> Request_id.compare a b
        | Worker (ia, a), Worker (ib, b) ->
            let order = Issue_id.compare ia ib in
            if order <> 0 then order else Run_id.compare a b
        | Retry (ia, a), Retry (ib, b) ->
            let order = Issue_id.compare ia ib in
            if order <> 0 then order else Retry_id.compare a b
        | ( ( Owner
            | Controls
            | Workflow _
            | Tracker _
            | Cleanup _
            | Worker _
            | Poll _
            | Retry _ ),
            _ ) -> order
  end

  module Registry = Map.Make (Keys)

  type terminal =
    | Semantic of Core.input
    | Canceled
    | Controls_stopped
    | Clock_error of Diagnostic.t

  type 'a capture = Awaiting | Captured of 'a outcome

  type closed = {
    outcome : terminal outcome;
    secondary : effect_key Failure.secondary list;
  }

  type message = Entered of effect_key | Closed of effect_key * closed

  type cancellation =
    | Job_cancel of unit Eio.Promise.u
    | Worker_cancel of Agent_runner.cancel_reason Eio.Promise.u

  type handle = {
    entry : message Service_inbox.slot;
    closed : message Service_inbox.slot;
    cancel : cancellation;
  }

  type control_fact = No_control | Refresh_pending | Shutdown_pending

  type runtime = {
    changed : Eio.Condition.t;
    inbox : message Service_inbox.t;
    mutable handles : handle Registry.t;
    mutable control : control_fact;
    failure : effect_key Failure.t;
  }

  exception Broken_contract of string

  let key_text = function
    | Owner -> "owner"
    | Controls -> "controls"
    | Workflow id -> "workflow request=" ^ Request_id.text id
    | Tracker id -> "tracker request=" ^ Request_id.text id
    | Cleanup id -> "cleanup request=" ^ Request_id.text id
    | Worker (issue, run) ->
        "worker issue=" ^ Issue_id.text issue ^ " run=" ^ Run_id.text run
    | Poll id -> "poll request=" ^ Request_id.text id
    | Retry (issue, retry) ->
        "retry issue=" ^ Issue_id.text issue ^ " retry=" ^ Retry_id.text retry

  let remember_closed runtime key = function
    | Returned (Clock_error diagnostic) ->
        Failure.record runtime.failure key (Returned (Error diagnostic))
    | Raised (error, backtrace) ->
        Failure.record runtime.failure key (Raised (error, backtrace))
    | Returned (Semantic _ | Canceled | Controls_stopped) -> ()

  let unsuccessful = function
    | Semantic
        ( Core.Workflow_loaded (_, Error _)
        | Core.Tracker_completed (_, Error _)
        | Core.Workspace_removed (_, Error _)
        | Core.Request_canceled _ )
    | Canceled | Clock_error _ -> true
    | Semantic (Core.Worker_finished completed) -> begin
        match Agent.outcome completed with
        | Agent_runner.Succeeded -> false
        | Agent_runner.Failed _
        | Agent_runner.Timed_out _
        | Agent_runner.Stalled
        | Agent_runner.Canceled _ -> true
      end
    | Controls_stopped
    | Semantic
        ( Core.Poll_due _ | Core.Refresh_requested | Core.Workflow_changed
        | Core.Workflow_loaded (_, Ok _)
        | Core.Tracker_completed (_, Ok _)
        | Core.Worker_started _ | Core.Retry_due _
        | Core.Workspace_removed (_, Ok _)
        | Core.Shutdown ) -> false

  (* Capture the semantic result before Fiber.first or Switch aggregates cleanup.
     An expected failure remains primary even if a losing finalizer raises. *)
  let settle key captured actual =
    match (!captured, actual) with
    | Awaiting, outcome -> { outcome; secondary = [] }
    | Captured original, Returned _ -> { outcome = original; secondary = [] }
    | Captured (Raised (error, backtrace)), Raised (cleanup, _) ->
        {
          outcome = Raised (error, backtrace);
          secondary = secondary key ~primary:[ error ] cleanup;
        }
    | Captured (Returned terminal), Raised (cleanup, backtrace) ->
        if unsuccessful terminal then
          {
            outcome = Returned terminal;
            secondary = secondary key ~primary:[] cleanup;
          }
        else { outcome = Raised (cleanup, backtrace); secondary = [] }

  let select selected outcome =
    match !selected with
    | Awaiting -> selected := Captured outcome
    | Captured _ -> ()

  let within key ~cancel ~canceled work =
    let selected = ref Awaiting in
    let work () =
      match work () with
      | value ->
          select selected (Returned value);
          value
      | exception error ->
          let backtrace = Printexc.get_raw_backtrace () in
          select selected (Raised (error, backtrace));
          Printexc.raise_with_backtrace error backtrace
    in
    let canceled () =
      Eio.Promise.await cancel;
      select selected (Returned canceled);
      canceled
    in
    let actual =
      capture (fun () ->
          Eio.Switch.run (fun _sw ->
              match Eio.Promise.peek cancel with
              | Some () -> canceled ()
              | None -> Eio.Fiber.first work canceled))
    in
    settle key selected actual

  let worker_scope key work =
    let selected = ref Awaiting in
    let actual =
      capture (fun () ->
          Eio.Switch.run (fun _sw ->
              let outcome = capture work in
              selected := Captured outcome;
              restore outcome))
    in
    settle key selected actual

  let resolve_cancel reason = function
    | Job_cancel resolver -> ignore (Eio.Promise.try_resolve resolver () : bool)
    | Worker_cancel resolver ->
        ignore (Eio.Promise.try_resolve resolver reason : bool)

  let emit t event = t.observe (Effect event)

  let flush_secondary t runtime =
    Failure.flush runtime.failure ~describe:key_text
      ~report:(fun key diagnostic ->
        t.report_host (Secondary_defect { key; diagnostic }))

  let reserve (runtime : runtime) key cancel =
    if Registry.mem key runtime.handles then
      raise (Broken_contract "duplicate live effect generation");
    let entry, entry_writer = Service_inbox.reserve runtime.inbox in
    let closed, closed_writer = Service_inbox.reserve runtime.inbox in
    let handle = { entry; closed; cancel } in
    runtime.handles <- Registry.add key handle runtime.handles;
    (handle, entry_writer, closed_writer)

  let retract (runtime : runtime) key handle =
    ignore (Service_inbox.retract handle.entry : Service_inbox.retraction);
    ignore (Service_inbox.retract handle.closed : Service_inbox.retraction);
    runtime.handles <- Registry.remove key runtime.handles

  let spawn t (runtime : runtime) ~sw key cancel run =
    Eio.Switch.check sw;
    let handle, entry, closed = reserve runtime key cancel in
    let admission = ref Awaiting in
    let forked =
      capture (fun () ->
          Eio.Fiber.fork ~sw (fun () ->
              admission := Captured (Returned ());
              ignore
                (Service_inbox.publish entry (Entered key)
                  : Service_inbox.publication);
              let result =
                match
                  capture (fun () -> run (fun () -> Eio.Fiber.yield ()))
                with
                | Returned result -> result
                | Raised (error, backtrace) ->
                    { outcome = Raised (error, backtrace); secondary = [] }
              in
              ignore
                (Service_inbox.publish closed (Closed (key, result))
                  : Service_inbox.publication)))
    in
    begin match (forked, !admission) with
    | Raised (error, backtrace), Awaiting ->
        retract runtime key handle;
        Printexc.raise_with_backtrace error backtrace
    | Raised (error, backtrace), Captured _ ->
        Printexc.raise_with_backtrace error backtrace
    | Returned (), Awaiting ->
        retract runtime key handle;
        Eio.Switch.check sw;
        raise (Broken_contract "registered child did not enter")
    | Returned (), Captured _ -> emit t (Registered key)
    end

  let spawn_job t (runtime : runtime) ~sw key ~canceled work =
    let cancel, resolver = Eio.Promise.create () in
    spawn t runtime ~sw key (Job_cancel resolver) (fun yield ->
        within key ~cancel ~canceled (fun () ->
            yield ();
            work ()))

  let tracker_id = function
    | Tracker.Contract.States { id; _ } | Tracker.Contract.Ids { id; _ } -> id

  let cancel_request (runtime : runtime) id =
    List.iter
      (fun key ->
        match Registry.find_opt key runtime.handles with
        | None -> ()
        | Some handle -> resolve_cancel Agent_runner.Host_shutdown handle.cancel)
      [ Workflow id; Tracker id; Cleanup id ]

  let cancel_key (runtime : runtime) key reason =
    match Registry.find_opt key runtime.handles with
    | None -> ()
    | Some handle -> resolve_cancel reason handle.cancel

  let interpret t (runtime : runtime) ~sw commands =
    List.iter
      (function
        | Core.Load_workflow { id; file } ->
            let key = Workflow id in
            spawn_job t runtime ~sw key
              ~canceled:(Semantic (Core.Request_canceled id)) (fun () ->
                Semantic
                  (Core.Workflow_loaded (id, Load.load t.load { Load.id; file })))
        | Core.Read_tracker request ->
            let id = tracker_id request in
            spawn_job t runtime ~sw (Tracker id)
              ~canceled:(Semantic (Core.Request_canceled id)) (fun () ->
                Semantic (Core.Tracker_completed (id, Tracker.execute request)))
        | Core.Remove_workspace request ->
            let id = request.Workspace.Contract.request_id in
            spawn_job t runtime ~sw (Cleanup id)
              ~canceled:(Semantic (Core.Request_canceled id)) (fun () ->
                Semantic
                  (Core.Workspace_removed
                     (id, Workspace.cleanup t.workspace request)))
        | Core.Start_worker request ->
            let issue = Agent.Issue.id (Agent.issue request) in
            let run = Agent.run_id request in
            let cancel, resolver = Eio.Promise.create () in
            let key = Worker (issue, run) in
            spawn t runtime ~sw key (Worker_cancel resolver) (fun yield ->
                worker_scope key (fun () ->
                    yield ();
                    Semantic
                      (Core.Worker_finished
                         (Agent.run t.agent ~clock:t.clock
                            ~workspace:t.workspace ~cancel request))))
        | Core.Stop_worker (issue, run, reason) ->
            cancel_key runtime (Worker (issue, run)) reason
        | Core.Cancel_request id -> cancel_request runtime id
        | Core.Arm_poll (id, due) ->
            spawn_job t runtime ~sw (Poll id) ~canceled:Canceled (fun () ->
                match Clock.sleep_until t.clock due with
                | Ok () -> Semantic (Core.Poll_due id)
                | Error diagnostic -> Clock_error diagnostic)
        | Core.Cancel_poll id ->
            cancel_key runtime (Poll id) Agent_runner.Host_shutdown
        | Core.Arm_retry (issue, retry, due) ->
            spawn_job t runtime ~sw
              (Retry (issue, retry))
              ~canceled:Canceled
              (fun () ->
                match Clock.sleep_until t.clock due with
                | Ok () -> Semantic (Core.Retry_due (issue, retry))
                | Error diagnostic -> Clock_error diagnostic)
        | Core.Cancel_retry (issue, retry) ->
            cancel_key runtime (Retry (issue, retry)) Agent_runner.Host_shutdown
        | Core.Report fault -> t.report fault)
      commands

  let start_controls t (runtime : runtime) ~sw controls =
    let rec forward () =
      let control = Eio.Stream.take controls in
      runtime.control <-
        begin match (runtime.control, control) with
        | (No_control | Refresh_pending), Refresh -> Refresh_pending
        | (No_control | Refresh_pending | Shutdown_pending), Shutdown
        | Shutdown_pending, Refresh -> Shutdown_pending
        end;
      Eio.Condition.broadcast runtime.changed;
      match control with
      | Shutdown -> Controls_stopped
      | Refresh ->
          Eio.Fiber.yield ();
          forward ()
    in
    spawn_job t runtime ~sw Controls ~canceled:Canceled forward

  let take (runtime : runtime) =
    match Service_inbox.consume runtime.inbox with
    | None -> None
    | Some (slot, message) -> (
        let key =
          match message with
          | Entered key | Closed (key, _) -> key
        in
        match Registry.find_opt key runtime.handles with
        | None ->
            raise (Broken_contract "notification without registered effect")
        | Some handle ->
            begin match message with
            | Entered _ ->
                if not (Service_inbox.same slot handle.entry) then
                  raise (Broken_contract "crossed entry notification")
            | Closed (_, result) ->
                if not (Service_inbox.same slot handle.closed) then
                  raise (Broken_contract "crossed closure notification");
                runtime.handles <- Registry.remove key runtime.handles;
                remember_closed runtime key result.outcome;
                Failure.retain runtime.failure result.secondary
            end;
            Some message)

  let cancel_all (runtime : runtime) =
    Registry.iter
      (fun _ handle -> resolve_cancel Agent_runner.Host_shutdown handle.cancel)
      runtime.handles

  let rec drain (runtime : runtime) =
    match take runtime with
    | Some (Entered _) -> drain runtime
    | Some (Closed _) -> drain runtime
    | None ->
        if not (Registry.is_empty runtime.handles) then begin
          (* No suspension between checking the FIFO and installing this waiter. *)
          Eio.Condition.await_no_mutex runtime.changed;
          drain runtime
        end

  let measured t runtime computation =
    Result.bind (Failure.check runtime.failure) (fun () ->
        match Clock.now t.clock with
        | Error diagnostic -> Error diagnostic
        | Ok now ->
            Result.bind (Failure.check runtime.failure) (fun () ->
                let value = computation now in
                match Clock.now t.clock with
                | Error diagnostic -> Error diagnostic
                | Ok until ->
                    Result.map
                      (fun () ->
                        (now, Clock.Pure.elapsed ~since:now ~until, value))
                      (Failure.check runtime.failure)))

  let transition t (runtime : runtime) ~sw state input =
    match
      measured t runtime (fun now ->
          let state, commands = Core.step state (Core.event ~now input) in
          (state, commands, Core.project ~now state))
    with
    | Error diagnostic -> Error diagnostic
    | Ok (now, elapsed, (state, commands, projection)) ->
        t.observe (Transition { now; input; projection; commands; elapsed });
        interpret t runtime ~sw commands;
        Ok state

  let rec loop t (runtime : runtime) ~sw state =
    match Failure.check runtime.failure with
    | Error diagnostic -> Error diagnostic
    | Ok () -> (
        match runtime.control with
        | Shutdown_pending ->
            runtime.control <- No_control;
            continue t runtime ~sw state Core.Shutdown
        | No_control | Refresh_pending -> (
            match take runtime with
            | Some (Entered key) ->
                emit t (Child_entered key);
                begin match key with
                | Worker (issue, run) ->
                    emit t (Delivered (key, Entry));
                    continue t runtime ~sw state
                      (Core.Worker_started (issue, run))
                | Owner
                | Controls
                | Workflow _
                | Tracker _
                | Cleanup _
                | Poll _
                | Retry _ ->
                    emit t (Delivered (key, Entry));
                    loop t runtime ~sw state
                end
            | Some (Closed (key, result)) ->
                emit t (Outer_closed key);
                let delivery =
                  match result.outcome with
                  | Returned (Semantic _) -> Terminal
                  | Returned (Canceled | Controls_stopped | Clock_error _)
                  | Raised _ -> Private_close
                in
                emit t (Delivered (key, delivery));
                emit t (Retired key);
                if not (Failure.failed runtime.failure) then
                  flush_secondary t runtime;
                begin match result.outcome with
                | Returned (Semantic input) ->
                    continue t runtime ~sw state input
                | Returned (Canceled | Controls_stopped) ->
                    loop t runtime ~sw state
                | Returned (Clock_error diagnostic) -> Error diagnostic
                | Raised (error, backtrace) ->
                    Printexc.raise_with_backtrace error backtrace
                end
            | None ->
                if Core.quiescent state then begin
                  cancel_key runtime Controls Agent_runner.Host_shutdown;
                  if Registry.is_empty runtime.handles then Ok ()
                  else wait t runtime ~sw state
                end
                else begin
                  match runtime.control with
                  | Refresh_pending ->
                      runtime.control <- No_control;
                      continue t runtime ~sw state Core.Refresh_requested
                  | No_control -> wait t runtime ~sw state
                  | Shutdown_pending -> loop t runtime ~sw state
                end))

  and continue t (runtime : runtime) ~sw state input =
    match transition t runtime ~sw state input with
    | Error diagnostic -> Error diagnostic
    | Ok state -> loop t runtime ~sw state

  and wait t (runtime : runtime) ~sw state =
    Eio.Condition.await_no_mutex runtime.changed;
    loop t runtime ~sw state

  let owner t (runtime : runtime) controls config =
    let actual =
      capture (fun () ->
          Eio.Switch.run (fun sw ->
              let observed =
                capture (fun () ->
                    emit t (Registered Owner);
                    emit t (Child_entered Owner);
                    Eio.Fiber.yield ();
                    start_controls t runtime ~sw controls;
                    match
                      measured t runtime (fun now ->
                          let state, commands = Core.create ~now config in
                          (state, commands, Core.project ~now state))
                    with
                    | Error diagnostic -> Error diagnostic
                    | Ok (now, elapsed, (state, commands, projection)) ->
                        t.observe
                          (Initial { now; projection; commands; elapsed });
                        interpret t runtime ~sw commands;
                        loop t runtime ~sw state)
              in
              Failure.record runtime.failure Owner observed;
              let primary = Failure.prefer runtime.failure observed in
              (* The first failure is committed before this protected drain can
               suspend. No clock, reducer or user sink participates in drain. *)
              Eio.Cancel.protect (fun () ->
                  cancel_all runtime;
                  drain runtime);
              restore primary))
    in
    Failure.record runtime.failure Owner actual;
    let primary = Failure.prefer runtime.failure actual in
    begin match primary with
    | Returned (Ok ()) ->
        let notified =
          capture (fun () ->
              emit t (Outer_closed Owner);
              emit t (Delivered (Owner, Private_close));
              emit t (Retired Owner))
        in
        begin match notified with
        | Returned () -> ()
        | Raised (error, backtrace) ->
            Failure.record runtime.failure Owner (Raised (error, backtrace))
        end;
        flush_secondary t runtime;
        Failure.prefer runtime.failure primary
    | Returned (Error _) | Raised _ ->
        flush_secondary t runtime;
        primary
    end

  let run ~sw t ~controls config =
    Eio.Switch.check sw;
    let changed = Eio.Condition.create () in
    let runtime =
      {
        changed;
        inbox = Service_inbox.create ~changed;
        handles = Registry.empty;
        control = No_control;
        failure = Failure.create ();
      }
    in
    let completed =
      Eio.Fiber.fork_promise ~sw (fun () ->
          let outcome =
            flatten (capture (fun () -> owner t runtime controls config))
          in
          Failure.record runtime.failure Owner outcome;
          outcome)
    in
    match Eio.Promise.await_exn completed with
    | outcome -> restore (Failure.prefer runtime.failure outcome)
    | exception error ->
        let backtrace = Printexc.get_raw_backtrace () in
        Failure.record runtime.failure Owner (Raised (error, backtrace));
        Eio.Condition.broadcast changed;
        Eio.Cancel.protect (fun () ->
            let joined =
              flatten (capture (fun () -> Eio.Promise.await_exn completed))
            in
            Failure.record runtime.failure Owner joined);
        flush_secondary t runtime;
        restore (Failure.prefer runtime.failure (Raised (error, backtrace)))
end
