module F = Core_fixture

type key =
  | Load of Request_id.t
  | Read of Request_id.t
  | Remove of Request_id.t
  | Run of Issue_id.t * Run_id.t

type resource_event = Acquired of key | Closing of key | Released of key
type closure = Close_ok | Close_defect of exn

type _ invocation =
  | Loading : {
      id : Request_id.t;
      file : Workflow_path.t;
    }
      -> (F.Config.t, Config_layer.error) result invocation
  | Reading :
      Tracker_registry.Contract.request
      -> Tracker_registry.Contract.reply invocation
  | Removing :
      F.Workspace.cleanup
      -> (unit, Workspace_manager.error) result invocation
  | Running : F.Agent.request -> Agent_runner.outcome invocation

type 'a response = Answer of 'a | Defect of exn

type worker_action =
  | Publish of Positive_count.t * F.Agent.notice
  | Refresh of Turn_id.t
  | Parallel_refresh of
      Turn_id.t * Positive_count.t * F.Agent.notice * unit Eio.Promise.t

type worker_event =
  | Publication_entered of key * Positive_count.t
  | Publication_returned of key * Positive_count.t
  | Refresh_entered of key * Turn_id.t
  | Refresh_returned of
      key * Turn_id.t * (Agent_runner.continuation, Tracker_error.t) result

type 'answer call = {
  key : key;
  invocation : 'answer invocation;
  answer : 'answer response Eio.Promise.t;
  respond : 'answer response Eio.Promise.u;
  closure : closure Eio.Promise.t;
  close : closure Eio.Promise.u;
  actions : worker_action Eio.Stream.t;
}

type pending = Pending : 'answer call -> pending
type clock_fault = Healthy | Reject of Diagnostic.t | Crash of exn
type lifetime = Controlling | Ended

type t = {
  base : Clock_posix.t;
  observe : resource_event -> unit;
  changed : Eio.Condition.t;
  mutable revision : int;
  mutable pending : pending list;
  mutable trace : resource_event list;
  mutable worker_trace : worker_event list;
  mutable clock_fault : clock_fault;
  mutable sleep_fault : clock_fault;
  mutable lifetime : lifetime;
}

let create clock observe =
  {
    base = clock;
    observe;
    changed = Eio.Condition.create ();
    revision = 0;
    pending = [];
    trace = [];
    worker_trace = [];
    clock_fault = Healthy;
    sleep_fault = Healthy;
    lifetime = Controlling;
  }

let key (call : 'a call) = call.key
let invocation (call : 'a call) = call.invocation
let pending (t : t) = List.rev t.pending
let trace (t : t) = List.rev t.trace
let worker_trace (t : t) = List.rev t.worker_trace
let revision (t : t) = t.revision

let notify (t : t) =
  t.revision <- t.revision + 1;
  Eio.Condition.broadcast t.changed

let rec await_change (t : t) ~after =
  if t.revision = after then begin
    Eio.Condition.await_no_mutex t.changed;
    await_change t ~after
  end

let same_key a b =
  match (a, b) with
  | Load a, Load b | Read a, Read b | Remove a, Remove b -> Request_id.equal a b
  | Run (ia, a), Run (ib, b) -> Issue_id.equal ia ib && Run_id.equal a b
  | (Load _ | Read _ | Remove _ | Run _), _ -> false

let invocation_key : type a. a invocation -> key = function
  | Loading { id; _ } -> Load id
  | Reading
      ( Tracker_registry.Contract.States { id; _ }
      | Tracker_registry.Contract.Ids { id; _ } ) -> Read id
  | Removing request -> Remove request.F.Workspace.request_id
  | Running request ->
      Run (Issue.id (F.Agent.issue request), F.Agent.run_id request)

let record (t : t) event =
  t.trace <- event :: t.trace;
  notify t;
  t.observe event

let record_worker t event =
  t.worker_trace <- event :: t.worker_trace;
  notify t

let begin_call : type a. t -> a invocation -> a call =
 fun t invocation ->
  let key = invocation_key invocation in
  if List.exists (fun (Pending call) -> same_key key call.key) t.pending then
    invalid_arg "duplicate live fake resource";
  let answer, respond = Eio.Promise.create () in
  let closure, close = Eio.Promise.create () in
  let actions = Eio.Stream.create 1 in
  let call = { key; invocation; answer; respond; closure; close; actions } in
  call

let respond call answer =
  ignore (Eio.Promise.try_resolve call.respond (Answer answer) : bool)

let fail call error =
  ignore (Eio.Promise.try_resolve call.respond (Defect error) : bool)

let close call closure =
  ignore (Eio.Promise.try_resolve call.close closure : bool)

let publish call ~sequence notice =
  Eio.Stream.add call.actions (Publish (sequence, notice))

let refresh call ~turn = Eio.Stream.add call.actions (Refresh turn)

let refresh_with_progress call ~turn ~sequence ~after notice =
  Eio.Stream.add call.actions (Parallel_refresh (turn, sequence, notice, after))

let run ~clock ~observe actor =
  let controller = create clock observe in
  Eio.Switch.run (fun sw ->
      Fun.protect
        (fun () ->
          let value = actor ~sw controller in
          if controller.pending <> [] then
            invalid_arg "scenario actor returned with acquired resources";
          value)
        ~finally:(fun () ->
          (* Release permissions before Switch joins canceled children. A switch
             release hook would run too late: those children need these gates. *)
          controller.lifetime <- Ended;
          List.iter
            (fun (Pending call) -> close call Close_ok)
            controller.pending))

let answer call =
  match Eio.Promise.await call.answer with
  | Answer answer -> answer
  | Defect error -> raise error

let finish t call =
  record t (Closing call.key);
  let closure = Eio.Promise.await call.closure in
  t.pending <-
    List.filter
      (fun (Pending active) -> not (same_key active.key call.key))
      t.pending;
  record t (Released call.key);
  match closure with
  | Close_ok -> ()
  | Close_defect error -> raise error

let scoped t invocation work =
  begin match t.lifetime with
  | Controlling -> ()
  | Ended -> invalid_arg "scenario operation entered after actor exit"
  end;
  Eio.Switch.run (fun sw ->
      let call = begin_call t invocation in
      Eio.Switch.on_release sw (fun () -> finish t call);
      t.pending <- Pending call :: t.pending;
      record t (Acquired call.key);
      work call)

let perform t invocation = scoped t invocation answer
let fail_next_now t diagnostic = t.clock_fault <- Reject diagnostic
let defect_next_now t error = t.clock_fault <- Crash error
let fail_next_sleep t diagnostic = t.sleep_fault <- Reject diagnostic
let defect_next_sleep t error = t.sleep_fault <- Crash error

module Clock = struct
  module Pure = Clock.Pure

  type nonrec t = t

  let now t =
    let fault = t.clock_fault in
    t.clock_fault <- Healthy;
    match fault with
    | Healthy -> Clock_posix.now t.base
    | Reject diagnostic -> Error diagnostic
    | Crash error -> raise error

  let sleep_until t deadline =
    let fault = t.sleep_fault in
    t.sleep_fault <- Healthy;
    match fault with
    | Healthy -> Clock_posix.sleep_until t.base deadline
    | Reject diagnostic -> Error diagnostic
    | Crash error -> raise error

  let sample t = Clock_posix.sample t.base
end

module Workspace = struct
  module Contract = F.Workspace

  type nonrec t = t

  let with_workspace _t reference ~on_error:_ callback =
    Eio.Switch.run (fun _sw -> F.with_path reference callback)

  let cleanup t request = perform t (Removing request)

  let inspect _t _reference =
    Error
      (Workspace_manager.Filesystem_error
         (Diagnostic.make ~site:(Diagnostic.Host "service.scenario inspection")
            ~message:"The fake workspace has no inspection backend."
            ~remedy:"Use a workspace interpreter with stored inspection state."))
end

module Agent = struct
  include (
    F.Agent :
      Agent_plan.S
        with module Issue = Issue
         and module Path = F.Path
         and type workspace = F.Workspace.reference
         and type request = F.Agent.request)

  type notice =
    | Preparing
    | Workspace_ready of Path.t
    | Rendering
    | Starting
    | Protocol of Agent_runner.event

  type progress = Progress of Positive_count.t * notice

  let progress ~sequence notice = Progress (sequence, notice)
  let sequence (Progress (sequence, _)) = sequence
  let notice (Progress (_, notice)) = notice

  type completed = Closed of Issue_id.t * Run_id.t * Agent_runner.outcome

  let completed_issue (Closed (issue, _, _)) = issue
  let completed_run (Closed (_, run, _)) = run
  let outcome (Closed (_, _, outcome)) = outcome

  type nonrec t = t
  type clock = Clock.t
  type workspace_manager = Workspace.t

  let stopped = function
    | Agent_runner.Cancel reason ->
        Agent_runner.Canceled { reason; remote_error = None }
    | Agent_runner.Stall -> Agent_runner.Stalled

  let normalize = function
    | F.Agent.Preparing -> Preparing
    | F.Agent.Workspace_ready path -> Workspace_ready path
    | F.Agent.Rendering -> Rendering
    | F.Agent.Starting -> Starting
    | F.Agent.Protocol event -> Protocol event

  let run t ~clock ~workspace ~interrupt ~emit ~refresh request =
    if t != clock || t != workspace then
      invalid_arg "fake runner received a different clock/workspace instance";
    let result =
      match Eio.Promise.peek interrupt with
      | Some cause -> Eio.Switch.run (fun _sw -> stopped cause)
      | None ->
          scoped t (Running request) (fun call ->
              let publication sequence notice =
                record_worker t (Publication_entered (call.key, sequence));
                emit (progress ~sequence (normalize notice));
                record_worker t (Publication_returned (call.key, sequence))
              in
              let continuation turn =
                record_worker t (Refresh_entered (call.key, turn));
                let answer = refresh ~turn in
                record_worker t (Refresh_returned (call.key, turn, answer));
                answer
              in
              let terminal = function
                | Error error ->
                    Some
                      (Agent_runner.Failed (Agent_runner.Tracker_error error))
                | Ok Agent_runner.Stop -> Some Agent_runner.Succeeded
                | Ok (Agent_runner.Continue _) -> None
              in
              let rec work () =
                match Eio.Promise.peek interrupt with
                | Some cause -> stopped cause
                | None -> (
                    let next =
                      Eio.Fiber.first
                        (fun () -> `Answer (answer call))
                        (fun () ->
                          Eio.Fiber.first
                            (fun () -> `Interrupt (Eio.Promise.await interrupt))
                            (fun () -> `Action (Eio.Stream.take call.actions)))
                    in
                    match next with
                    | `Answer outcome -> outcome
                    | `Interrupt cause -> stopped cause
                    | `Action action -> begin
                        match Eio.Promise.peek interrupt with
                        | Some cause -> stopped cause
                        | None -> (
                            let terminal =
                              match action with
                              | Publish (sequence, notice) ->
                                  publication sequence notice;
                                  None
                              | Refresh turn -> terminal (continuation turn)
                              | Parallel_refresh (turn, sequence, notice, after)
                                ->
                                  (* Model the session owner pumping a late fact
                                     while its refresh callback is suspended. *)
                                  let answer, () =
                                    Eio.Fiber.pair
                                      (fun () -> continuation turn)
                                      (fun () ->
                                        Eio.Promise.await after;
                                        publication sequence notice)
                                  in
                                  terminal answer
                            in
                            match (Eio.Promise.peek interrupt, terminal) with
                            | Some cause, _ -> stopped cause
                            | None, Some outcome -> outcome
                            | None, None -> work ())
                      end)
              in
              match
                Workspace.with_workspace workspace (F.Agent.workspace request)
                  ~on_error:Fun.id (fun _path -> Ok (work ()))
              with
              | Ok outcome -> outcome
              | Error error ->
                  Agent_runner.Failed (Agent_runner.Workspace_error error))
    in
    (* Only this port may construct its witness, after the real fake scope joins. *)
    Closed (Issue.id (F.Agent.issue request), F.Agent.run_id request, result)
end

module Load = struct
  type config = F.Config.t
  type nonrec t = t
  type request = { id : Request_id.t; file : Workflow_path.t }

  let load t (request : request) =
    perform t (Loading { id = request.id; file = request.file })
end

module Ports (Controller : sig
  val controller : t
end) =
struct
  module Tracker = struct
    include Tracker_registry

    let execute request =
      let binding =
        match request with
        | Contract.States { binding; _ } | Contract.Ids { binding; _ } ->
            binding
      in
      ignore (F.binding_profile binding : F.profile);
      perform Controller.controller (Reading request)
  end

  module Clock = Clock
  module Workspace = Workspace
  module Agent = Agent
  module Config = F.Config
  module Load = Load
end
