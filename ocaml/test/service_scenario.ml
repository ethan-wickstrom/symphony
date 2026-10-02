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

type 'answer call = {
  key : key;
  invocation : 'answer invocation;
  answer : 'answer response Eio.Promise.t;
  respond : 'answer response Eio.Promise.u;
  closure : closure Eio.Promise.t;
  close : closure Eio.Promise.u;
}

type pending = Pending : 'answer call -> pending
type clock_fault = Healthy | Reject of Diagnostic.t | Crash of exn
type lifetime = Controlling | Ended

type t = {
  mono : Eio_mock.Clock.Mono.t;
  base : Clock_posix.t;
  changed : Eio.Condition.t;
  mutable revision : int;
  mutable pending : pending list;
  mutable trace : resource_event list;
  mutable clock_fault : clock_fault;
  mutable sleep_fault : clock_fault;
  mutable lifetime : lifetime;
}

let create () =
  let mono = Eio_mock.Clock.Mono.make () in
  let wall = Eio_mock.Clock.make () in
  {
    mono;
    base = Clock_posix.create ~mono ~wall;
    changed = Eio.Condition.create ();
    revision = 0;
    pending = [];
    trace = [];
    clock_fault = Healthy;
    sleep_fault = Healthy;
    lifetime = Controlling;
  }

let key (call : 'a call) = call.key
let invocation (call : 'a call) = call.invocation
let pending (t : t) = List.rev t.pending
let trace (t : t) = List.rev t.trace
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
  notify t

let begin_call : type a. t -> a invocation -> a call =
 fun t invocation ->
  let key = invocation_key invocation in
  if List.exists (fun (Pending call) -> same_key key call.key) t.pending then
    invalid_arg "duplicate live fake resource";
  let answer, respond = Eio.Promise.create () in
  let closure, close = Eio.Promise.create () in
  let call = { key; invocation; answer; respond; closure; close } in
  call

let respond call answer =
  ignore (Eio.Promise.try_resolve call.respond (Answer answer) : bool)

let fail call error =
  ignore (Eio.Promise.try_resolve call.respond (Defect error) : bool)

let close call closure =
  ignore (Eio.Promise.try_resolve call.close closure : bool)

let run actor =
  let controller = create () in
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

let advance t instant =
  let current = Eio.Time.Mono.now t.mono in
  let requested = Clock.Pure.nanoseconds instant in
  let current = Count.of_uint64_bits (Mtime.to_uint64_ns current) in
  if Count.compare requested current < 0 then
    invalid_arg "backward fake-clock advance";
  match Count.to_uint64_bits requested with
  | None -> invalid_arg "fake-clock native horizon"
  | Some tick ->
      Eio_mock.Clock.Mono.set_time t.mono (Mtime.of_uint64_ns tick);
      notify t

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

  let with_workspace _t reference callback =
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

  let run t ~clock ~workspace ~cancel request =
    if t != clock || t != workspace then
      invalid_arg "fake runner received a different clock/workspace instance";
    let result =
      match Eio.Promise.peek cancel with
      | Some reason ->
          Eio.Switch.run (fun _sw ->
              Agent_runner.Canceled { reason; remote_error = None })
      | None ->
          scoped t (Running request) (fun call ->
              match
                Workspace.with_workspace workspace (F.Agent.workspace request)
                  (fun _path ->
                    Ok
                      (match Eio.Promise.peek cancel with
                      | Some reason ->
                          Agent_runner.Canceled { reason; remote_error = None }
                      | None ->
                          Eio.Fiber.first
                            (fun () -> answer call)
                            (fun () ->
                              let reason = Eio.Promise.await cancel in
                              Agent_runner.Canceled
                                { reason; remote_error = None })))
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
