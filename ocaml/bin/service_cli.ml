module Native = Workspace_host_posix.Make (Clock_posix)

module Agent =
  Codex_runner.Make (Native.Workspace) (Native.Process) (Clock_posix)

module Config = Tracker_runtime.Config

module Assembly = Service_assembly.Compose (struct
  module Tracker = Tracker_registry
  module Clock = Clock_posix
  module Workspace = Native.Workspace
  module Agent = Agent
  module Config = Config
  module File = Workflow_file
end)

module Host = Assembly.Host
module Status = Status_surface.Make (Host.Source)
module Http = Native_status.Make (Clock_posix)

let query_timeout = Result.get_ok (Milliseconds.parse "1000")

module Output = Native_output.Make (Clock_posix)

let issue_fields issue =
  [
    ("issue_id", Issue_id.text (Issue.id issue));
    ("issue_identifier", Issue_identifier.text (Issue.identifier issue));
  ]

let workspace_error = function
  | Workspace_manager.Invalid_key diagnostic
  | Workspace_manager.Unsafe_path diagnostic
  | Workspace_manager.Ownership_conflict diagnostic
  | Workspace_manager.Filesystem_error diagnostic
  | Workspace_manager.Hook_failed diagnostic
  | Workspace_manager.Hook_timeout diagnostic -> diagnostic

let template_error = function
  | Template.Parse_error diagnostic | Template.Render_error diagnostic ->
      diagnostic

let config_error = function
  | Config_layer.Workflow
      ( Workflow_loader.Missing_file diagnostic
      | Workflow_loader.Read_error diagnostic )
  | Config_layer.Workflow
      (Workflow_loader.Invalid_document
         ( Workflow_document.Parse_error diagnostic
         | Workflow_document.Front_matter_not_map diagnostic )) ->
      Diagnostic.render diagnostic
  | Config_layer.Fields diagnostics ->
      String.concat "\n"
        (List.map Diagnostic.render (Nonempty_list.to_list diagnostics))
  | Config_layer.Tracker error ->
      Diagnostic.render (Tracker_error.diagnostic error)

let agent_error = function
  | Agent_runner.Codex_not_found diagnostic
  | Agent_runner.Invalid_workspace_cwd diagnostic
  | Agent_runner.Port_exit diagnostic
  | Agent_runner.Response_error diagnostic
  | Agent_runner.Turn_failed diagnostic
  | Agent_runner.Turn_input_required diagnostic -> diagnostic
  | Agent_runner.Template_error error -> template_error error
  | Agent_runner.Workspace_error error -> workspace_error error
  | Agent_runner.Tracker_error error -> Tracker_error.diagnostic error

let timeout_error = function
  | Agent_runner.Response_deadline diagnostic
  | Agent_runner.Turn_silence diagnostic -> diagnostic

let cancel_name = function
  | Agent_runner.Reconciliation -> "reconciliation"
  | Agent_runner.Scope_change -> "scope_change"
  | Agent_runner.Host_shutdown -> "host_shutdown"

let outcome_fields = function
  | Agent_runner.Succeeded -> [ ("outcome", "succeeded") ]
  | Agent_runner.Failed _ -> [ ("outcome", "failed") ]
  | Agent_runner.Timed_out _ -> [ ("outcome", "timed_out") ]
  | Agent_runner.Stalled -> [ ("outcome", "stalled") ]
  | Agent_runner.Canceled { reason; remote_error = _ } ->
      [ ("outcome", "canceled"); ("reason", cancel_name reason) ]

let fault output fault =
  let emit event fields = Output.emit output ~event fields in
  let issue event issue diagnostic =
    emit event
      (issue_fields issue @ [ ("diagnostic", Diagnostic.render diagnostic) ])
  in
  match fault with
  | Host.Core.Config_failure error ->
      emit "workflow_invalid" [ ("diagnostic", config_error error) ]
  | Host.Core.Tracker_failure error ->
      emit "tracker_failure"
        [ ("diagnostic", Diagnostic.render (Tracker_error.diagnostic error)) ]
  | Host.Core.Issue_tracker_failure (current, error) ->
      issue "issue_tracker_failure" current (Tracker_error.diagnostic error)
  | Host.Core.Attempt_failure (current, error) ->
      issue "attempt_failure" current (agent_error error)
  | Host.Core.Attempt_timeout (current, error) ->
      issue "attempt_timeout" current (timeout_error error)
  | Host.Core.Attempt_stalled current ->
      emit "attempt_stalled" (issue_fields current)
  | Host.Core.Attempt_cancel_error (current, diagnostic) ->
      issue "attempt_cancel_error" current diagnostic
  | Host.Core.Planning_failure (current, error) ->
      issue "planning_failure" current (workspace_error error)
  | Host.Core.Cleanup_failure (current, error) ->
      issue "cleanup_failure" current (workspace_error error)
  | Host.Core.Lifecycle_failure (current, diagnostic) ->
      issue "lifecycle_failure" current diagnostic

let worker projection issue run =
  List.find_map
    (function
      | Host.Core.Worker current
        when Issue_id.equal (Issue.id current.Host.Core.issue) issue
             && Run_id.equal current.Host.Core.run run -> Some current
      | Host.Core.Worker _ | Host.Core.Retry _ | Host.Core.Cleaning _ -> None)
    projection.Host.Core.owners

let worker_fields (current : Host.Core.worker) =
  issue_fields current.Host.Core.issue
  @ [ ("run_id", Run_id.text current.Host.Core.run) ]

let session_fields (current : Host.Core.worker) =
  match current.Host.Core.session with
  | None -> [ ("session_state", "not_started") ]
  | Some session ->
      [ ("session_state", "started"); ("session_id", Session_id.text session) ]

let key_fields projection =
  let unavailable = [ ("context", "unavailable") ] in
  function
  | Host.Owner -> [ ("effect", "owner") ]
  | Host.Controls -> [ ("effect", "controls") ]
  | Host.Workflow id ->
      [ ("effect", "workflow"); ("request_id", Request_id.text id) ]
  | Host.Tracker id ->
      [ ("effect", "tracker"); ("request_id", Request_id.text id) ]
  | Host.Cleanup id ->
      [ ("effect", "cleanup"); ("request_id", Request_id.text id) ]
  | Host.Worker (issue, run) ->
      let context =
        match Option.bind projection (fun view -> worker view issue run) with
        | Some current -> worker_fields current @ session_fields current
        | None ->
            [ ("issue_id", Issue_id.text issue); ("run_id", Run_id.text run) ]
            @ unavailable
      in
      ("effect", "worker") :: context
  | Host.Poll id -> [ ("effect", "poll"); ("request_id", Request_id.text id) ]
  | Host.Retry (issue, retry) -> (
      let current =
        Option.bind projection (fun view ->
            List.find_map
              (function
                | Host.Core.Retry current
                  when Issue_id.equal (Issue.id current.Host.Core.issue) issue
                       && Retry_id.equal current.Host.Core.retry retry ->
                    Some current.Host.Core.issue
                | Host.Core.Worker _ | Host.Core.Retry _ | Host.Core.Cleaning _
                  -> None)
              view.Host.Core.owners)
      in
      [ ("effect", "retry"); ("retry_id", Retry_id.text retry) ]
      @
      match current with
      | Some current -> issue_fields current
      | None -> ("issue_id", Issue_id.text issue) :: unavailable)

let observe output =
  let ready = ref false in
  let previous = ref None in
  let project projection =
    if (not !ready) && projection.Host.Core.mode = Host.Core.Serving then (
      ready := true;
      Output.emit output ~event:"service_ready" [])
  in
  let dispatch = function
    | Host.Core.Start_worker request ->
        Output.emit output ~event:"dispatch"
          (issue_fields (Agent.issue request)
          @ [ ("run_id", Run_id.text (Agent.run_id request)) ])
    | Host.Core.Load_workflow _
    | Host.Core.Read_tracker _
    | Host.Core.Stop_worker _
    | Host.Core.Continue_worker _
    | Host.Core.Remove_workspace _
    | Host.Core.Cancel_request _
    | Host.Core.Arm_poll _
    | Host.Core.Cancel_poll _
    | Host.Core.Arm_retry _
    | Host.Core.Cancel_retry _
    | Host.Core.Report _ -> ()
  in
  let progress (current : Host.Core.worker) value =
    let fields = worker_fields current in
    let session event session context =
      match current.Host.Core.session with
      | Some accepted when Session_id.equal accepted session ->
          Output.emit output ~event
            (fields @ [ ("session_id", Session_id.text accepted) ] @ context)
      | None | Some _ -> ()
    in
    match Agent.notice value with
    | Agent.Protocol
        (Agent_runner.Session_started { session = id; thread; turn }) ->
        session "session_started" id
          [
            ("thread_id", Thread_id.text thread); ("turn_id", Turn_id.text turn);
          ]
    | Agent.Protocol (Agent_runner.Turn_started { session = id; turn }) ->
        session "turn_started" id [ ("turn_id", Turn_id.text turn) ]
    | Agent.Protocol (Agent_runner.Turn_completed { session = id; turn }) ->
        session "turn_completed" id [ ("turn_id", Turn_id.text turn) ]
    | Agent.Protocol (Agent_runner.Unsupported_tool { name; diagnostic }) ->
        Output.emit output ~event:"unsupported_tool"
          (fields @ session_fields current
          @ [ ("tool", name); ("diagnostic", Diagnostic.render diagnostic) ])
    | Agent.Preparing
    | Agent.Workspace_ready _
    | Agent.Rendering
    | Agent.Starting
    | Agent.Protocol
        ( Agent_runner.Output _
        | Agent_runner.Usage_report _
        | Agent_runner.Rate_limits _ ) -> ()
  in
  let closed completed =
    match !previous with
    | None -> ()
    | Some projection -> (
        match
          worker projection
            (Agent.completed_issue completed)
            (Agent.completed_run completed)
        with
        | None -> ()
        | Some current ->
            Output.emit output ~event:"worker_closed"
              (worker_fields current @ session_fields current
              @ outcome_fields (Agent.outcome completed)))
  in
  let report_host = function
    | Host.Secondary_defect { key; diagnostic } ->
        Output.emit output ~event:"host_cleanup_failure"
          (key_fields !previous key
          @ [ ("diagnostic", Diagnostic.render diagnostic) ])
  in
  let observe = function
    | Host.Initial initial ->
        project initial.Host.projection;
        List.iter dispatch initial.Host.commands;
        previous := Some initial.Host.projection
    | Host.Transition transition ->
        project transition.Host.projection;
        List.iter dispatch transition.Host.commands;
        (match transition.Host.input with
        | Host.Core.Worker_progress
            { issue; run; progress = value; emitted_at = _ } -> (
            match worker transition.Host.projection issue run with
            | None -> ()
            | Some current -> progress current value)
        | Host.Core.Worker_finished completed -> closed completed
        | Host.Core.Poll_due _
        | Host.Core.Refresh_requested
        | Host.Core.Workflow_changed
        | Host.Core.Workflow_loaded _
        | Host.Core.Tracker_completed _
        | Host.Core.Worker_started _
        | Host.Core.Worker_continue _
        | Host.Core.Request_canceled _
        | Host.Core.Retry_due _
        | Host.Core.Workspace_removed _
        | Host.Core.Shutdown -> ());
        (* Retain one immutable view for closure after the next transition retires it. *)
        previous := Some transition.Host.projection
    | Host.Effect _ -> ()
  in
  (observe, report_host)

let hook_name = function
  | Workspace_settings.After_create -> "after_create"
  | Workspace_settings.Before_run -> "before_run"
  | Workspace_settings.After_run -> "after_run"
  | Workspace_settings.Before_remove -> "before_remove"

let hook_fields = function
  | Workspace_hooks.Started -> [ ("phase", "started") ]
  | Workspace_hooks.Finished (Workspace_hooks.Completed (Ok ())) ->
      [ ("phase", "finished"); ("outcome", "succeeded") ]
  | Workspace_hooks.Finished (Workspace_hooks.Completed (Error _)) ->
      [ ("phase", "finished"); ("outcome", "failed") ]
  | Workspace_hooks.Finished Workspace_hooks.Cancelled ->
      [ ("phase", "finished"); ("outcome", "canceled") ]

let serve ~fs ~net ~clock ~runtime ~cwd ~ca_bundle ~port ~io ~env ~document
    output signal =
  let report diagnostic =
    Output.emit output ~event:"host_cleanup_failure"
      [ ("diagnostic", Diagnostic.render diagnostic) ]
  in
  let startup =
    match
      Tracker_runtime.registry ~fs ~net ~clock ~runtime ~cwd ~ca_bundle
        ~warning:(fun text ->
          Output.emit output ~event:"tracker_omission" [ ("diagnostic", text) ])
    with
    | Error error -> Error (Tracker_error.diagnostic error)
    | Ok registry -> (
        match Config.resolve_startup registry ~env ~document with
        | Ok startup -> Ok (registry, startup)
        | Error error ->
            Error
              (Diagnostic.make
                 ~site:
                   (Diagnostic.Workflow
                      {
                        file =
                          Workflow_path.display
                            (Workflow_document.file document);
                        key = None;
                        line = None;
                      })
                 ~message:(config_error error)
                 ~remedy:"Correct the workflow before restarting Symphony."))
  in
  match startup with
  | Error diagnostic ->
      (try
         Output.emit output ~event:"workflow_invalid"
           [ ("diagnostic", Diagnostic.render diagnostic) ]
       with _ -> ());
      Error diagnostic
  | Ok (registry, startup) -> (
      let config = Config.runtime startup in
      let host =
        Native.create ~fs ~clock
          ~emit:(fun reference hook event ->
            Output.emit output ~event:"hook"
              ([
                 ("issue_id", Issue_id.text (Native.Contract.issue_id reference));
                 ( "issue_identifier",
                   Issue_identifier.text (Native.Contract.identifier reference)
                 );
                 ("hook", hook_name hook);
               ]
              @ hook_fields event))
          ~report:(fun error -> report (workspace_error error))
      in
      let observe, report_host = observe output in
      let service =
        Assembly.create ~clock ~workspace:(Native.workspace host)
          ~agent:(Agent.create ~process:(Native.process host) ~version:"0.1.0")
          ~file:io ~registry ~env ~report:(fault output) ~report_host ~observe
      in
      let execute () =
        Native_scope.with_scope (fun sw ->
            let controls = Eio.Stream.create 1 in
            let run = Host.create_run ~sw service ~query_timeout in
            Eio.Fiber.fork_daemon ~sw (fun () ->
                let received = Eio.Promise.await signal in
                Output.emit output ~event:"shutdown_requested"
                  [
                    ( "signal",
                      match received with
                      | Native_shutdown.Interrupt -> "SIGINT"
                      | Native_shutdown.Terminate -> "SIGTERM" );
                  ];
                Eio.Stream.add controls Host.Shutdown;
                `Stop_daemon);
            let dispatch () =
              Output.emit output ~event:"service_started"
                [ ("workflow", Workflow_path.display (Config.file config)) ];
              Host.run run ~controls config
            in
            let port =
              match port with
              | Some _ -> port
              | None -> Config.listener_port startup
            in
            match port with
            | None -> dispatch ()
            | Some port ->
                Http.with_server ~net ~clock ~port
                  ~ready:(fun port ->
                    Output.emit output ~event:"status_listening"
                      [ ("port", string_of_int port) ])
                  ~handler:(Status.handle (Host.source run))
                  dispatch)
      in
      let result = execute () in
      match result with
      | Ok () ->
          Output.emit output ~event:"service_stopped" [];
          Ok ()
      | Error diagnostic ->
          (try
             Output.emit output ~event:"service_failure"
               [ ("diagnostic", Diagnostic.render diagnostic) ]
           with _ -> ());
          Error diagnostic)

type setup = Signal_setup | Output_setup | Entered_output

let run ~fs ~net ~sink ~clock ~runtime ~cwd ~ca_bundle ~port ~io ~env ~document
    =
  (* Signal custody covers output drainage as well as service closure. *)
  let closed = ref None in
  let setup = ref Signal_setup in
  let report_signal diagnostic =
    match !closed with
    | None -> closed := Some diagnostic
    | Some _ -> ()
  in
  let execute () =
    Native_shutdown.with_signal ~report:report_signal (fun signal ->
        setup := Output_setup;
        Output.with_output ~clock ~sink (fun output ->
            setup := Entered_output;
            try
              serve ~fs ~net ~clock ~runtime ~cwd ~ca_bundle ~port ~io ~env
                ~document output signal
            with error ->
              let trace = Printexc.get_raw_backtrace () in
              (try Output.emit output ~event:"host_failure" [] with _ -> ());
              Printexc.raise_with_backtrace error trace))
  in
  let result =
    try execute ()
    with error ->
      let trace = Printexc.get_raw_backtrace () in
      let reason =
        match !setup with
        | Signal_setup -> Some "signal_setup"
        | Output_setup -> Some "output_setup"
        | Entered_output -> None
      in
      (* Early setup has fully closed, and no writer has attempted the sink. *)
      Option.iter
        (fun reason ->
          try
            ignore
              (Output.with_output ~clock ~sink (fun output ->
                   Output.emit output ~event:"host_startup_failure"
                     [ ("reason", reason) ];
                   Ok ()))
          with _ -> ())
        reason;
      Printexc.raise_with_backtrace error trace
  in
  match (result, !closed) with
  | Error _, _ | Ok (), None -> result
  | Ok (), Some diagnostic -> Error diagnostic
