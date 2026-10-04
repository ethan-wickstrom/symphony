module Make
    (Workspace : Workspace_manager.S)
    (Process : Agent_process.S with module Path = Workspace.Contract.Path)
    (Clock : Clock.S) =
struct
  include Agent_plan.Make (Workspace.Contract)
  module Session = App_server.Make (Process) (Clock)

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

  type t = { process : Process.t; version : string }
  type clock = Clock.t
  type workspace_manager = Workspace.t
  type stage = Preparing_scope | Protocol_scope
  type 'a captured = Returned of 'a | Raised of exn * Printexc.raw_backtrace

  let capture run =
    try Returned (run ()) with
    | Eio.Cancel.Cancelled _ as error ->
        let trace = Printexc.get_raw_backtrace () in
        Eio.Fiber.check ();
        Raised (error, trace)
    | error -> Raised (error, Printexc.get_raw_backtrace ())

  let choose a b =
    match (a, b) with
    | Raised (a, at), Raised (b, bt) ->
        let error, trace = Eio.Exn.combine (a, at) (b, bt) in
        Raised (error, trace)
    | Raised _, Returned _ -> a
    | Returned _, Raised _ -> b
    | Returned _, Returned _ -> a

  let create ~process ~version = { process; version }

  let stopped = function
    | Agent_runner.Cancel reason ->
        Agent_runner.Canceled { reason; remote_error = None }
    | Agent_runner.Stall -> Agent_runner.Stalled

  let session_error = function
    | App_server.Failure failure -> Agent_runner.Failed failure
    | App_server.Deadline timeout -> Agent_runner.Timed_out timeout
    | App_server.Stopped
        { interrupt = Agent_runner.Cancel reason; remote_error } ->
        Agent_runner.Canceled { reason; remote_error }
    | App_server.Stopped { interrupt = Agent_runner.Stall; _ } ->
        Agent_runner.Stalled

  let terminal_result = function
    | App_server.Completed -> Ok Agent_runner.Succeeded
    | App_server.Failed d ->
        Error (App_server.Failure (Agent_runner.Turn_failed d))
    | App_server.Interrupted d ->
        Error
          (App_server.Failure
             (Agent_runner.Turn_failed
                (Option.value d
                   ~default:
                     (Diagnostic.make
                        ~site:
                          (Diagnostic.Protocol
                             {
                               method_name = "turn/completed";
                               request_id = None;
                             })
                        ~message:
                          "The remote turn was interrupted without a local \
                           request."
                        ~remedy:"Check the Codex session status."))))
    | App_server.Input_required d ->
        Error (App_server.Failure (Agent_runner.Turn_input_required d))

  let interrupted cause =
    App_server.Stopped { interrupt = cause; remote_error = None }

  let guidance =
    "Continue working on this issue in the existing thread. Review the current "
    ^ "workspace and issue state, finish the remaining work, and verify the \
       result."

  let turns session ~interrupt ~emit ~refresh ~limit ~prompt =
    let rec loop count prompt =
      match Eio.Promise.peek interrupt with
      | Some cause -> Error (interrupted cause)
      | None -> (
          match Session.turn session ~prompt ~emit with
          | Error error -> Error error
          | Ok { App_server.outcome = App_server.Completed; turn } -> (
              let answer = Session.await session (fun () -> refresh ~turn) in
              match answer with
              | Error error -> Error error
              | Ok answer -> (
                  match Eio.Promise.peek interrupt with
                  | Some cause -> Error (interrupted cause)
                  | None -> (
                      match answer with
                      | Error error ->
                          Error
                            (App_server.Failure
                               (Agent_runner.Tracker_error error))
                      | Ok Agent_runner.Stop -> Ok Agent_runner.Succeeded
                      | Ok (Agent_runner.Continue _) when count >= limit ->
                          Ok Agent_runner.Succeeded
                      | Ok (Agent_runner.Continue _) ->
                          loop (count + 1) guidance)))
          | Ok
              ({
                 App_server.outcome =
                   ( App_server.Failed _
                   | App_server.Interrupted _
                   | App_server.Input_required _ );
                 _;
               } as ended) -> terminal_result ended.App_server.outcome)
    in
    loop 1 prompt

  let run t ~clock ~workspace:manager ~interrupt ~emit:callback ~refresh request
      =
    let sequence = ref Positive_count.first in
    let emit notice =
      let progress = progress ~sequence:!sequence notice in
      sequence := Positive_count.next !sequence;
      callback progress
    in
    let prepare notice =
      (* Receipt callbacks can resolve interruption without yielding. *)
      emit notice;
      match Eio.Promise.peek interrupt with
      | Some cause -> Error (stopped cause)
      | None -> Ok ()
    in
    let stage = ref Preparing_scope in
    let result, resolve = Eio.Promise.create () in
    let acquire () =
      let value =
        match
          Workspace.with_workspace manager (workspace request)
            ~on_error:(fun error ->
              Agent_runner.Failed (Agent_runner.Workspace_error error))
            (fun cwd ->
              let ( let* ) = Result.bind in
              let template_error error =
                Agent_runner.Failed (Agent_runner.Template_error error)
              in
              let* () = prepare (Workspace_ready cwd) in
              let* () = prepare Rendering in
              let* template =
                Result.map_error template_error
                  (Template.compile ~file:(prompt_file request)
                     (prompt_source request))
              in
              let* prompt =
                Result.map_error template_error
                  (Template.render template ~issue:(issue request)
                     ~attempt:(attempt request))
              in
              let* () = prepare Starting in
              (* Protocol interruption drains before process and workspace closure. *)
              stage := Protocol_scope;
              let value =
                Session.with_session ~process:t.process ~clock ~interrupt ~cwd
                  ~env:(Workspace.Contract.environment (workspace request))
                  ~settings:(agent request) ~version:t.version
                  ~title:
                    (Issue_identifier.text (Issue.identifier (issue request))
                    ^ ": "
                    ^ Issue.title (issue request))
                  (fun session ->
                    turns session ~interrupt
                      ~emit:(fun event -> emit (Protocol event))
                      ~refresh
                      ~limit:(Agent_settings.max_turns (agent request))
                      ~prompt)
              in
              Result.map_error session_error value)
        with
        | Ok value | Error value -> value
      in
      value
    in
    let execute () =
      match prepare Preparing with
      | Error outcome -> outcome
      | Ok () -> acquire ()
    in
    let invoke () =
      let value = capture execute in
      Eio.Promise.resolve resolve value;
      value
    in
    let watch () =
      let cause = Eio.Promise.await interrupt in
      match !stage with
      | Preparing_scope -> Returned (stopped cause)
      | Protocol_scope -> Eio.Promise.await result
    in
    let value =
      Eio.Switch.run (fun _sw ->
          match Eio.Promise.peek interrupt with
          | Some cause -> Returned (stopped cause)
          | None -> Eio.Fiber.first ~combine:choose invoke watch)
    in
    match value with
    | Returned value -> Closed (Issue.id (issue request), run_id request, value)
    | Raised (error, trace) -> Printexc.raise_with_backtrace error trace
end
