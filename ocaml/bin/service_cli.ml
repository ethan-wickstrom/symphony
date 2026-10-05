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
module Output = Native_output.Make (Clock_posix)

let issue_fields issue =
  [
    ("issue_id", Issue_id.text (Issue.id issue));
    ("identifier", Issue_identifier.text (Issue.identifier issue));
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

let key_fields = function
  | Host.Owner -> [ ("effect", "owner") ]
  | Host.Controls -> [ ("effect", "controls") ]
  | Host.Workflow id ->
      [ ("effect", "workflow"); ("request_id", Request_id.text id) ]
  | Host.Tracker id ->
      [ ("effect", "tracker"); ("request_id", Request_id.text id) ]
  | Host.Cleanup id ->
      [ ("effect", "cleanup"); ("request_id", Request_id.text id) ]
  | Host.Worker (issue, run) ->
      [
        ("effect", "worker");
        ("issue_id", Issue_id.text issue);
        ("run_id", Run_id.text run);
      ]
  | Host.Poll id -> [ ("effect", "poll"); ("request_id", Request_id.text id) ]
  | Host.Retry (issue, retry) ->
      [
        ("effect", "retry");
        ("issue_id", Issue_id.text issue);
        ("retry_id", Retry_id.text retry);
      ]

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

let observe output =
  let ready = ref false in
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
  let progress issue run value =
    let fields =
      [ ("issue_id", Issue_id.text issue); ("run_id", Run_id.text run) ]
    in
    match Agent.notice value with
    | Agent.Protocol (Agent_runner.Session_started { session; thread; turn }) ->
        Output.emit output ~event:"session_started"
          (fields
          @ [
              ("session_id", Session_id.text session);
              ("thread_id", Thread_id.text thread);
              ("turn_id", Turn_id.text turn);
            ])
    | Agent.Protocol (Agent_runner.Turn_started { session; turn }) ->
        Output.emit output ~event:"turn_started"
          (fields
          @ [
              ("session_id", Session_id.text session);
              ("turn_id", Turn_id.text turn);
            ])
    | Agent.Protocol (Agent_runner.Turn_completed { session; turn }) ->
        Output.emit output ~event:"turn_completed"
          (fields
          @ [
              ("session_id", Session_id.text session);
              ("turn_id", Turn_id.text turn);
            ])
    | Agent.Protocol (Agent_runner.Unsupported_tool { name; diagnostic }) ->
        Output.emit output ~event:"unsupported_tool"
          (fields
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
  function
  | Host.Initial initial ->
      project initial.Host.projection;
      List.iter dispatch initial.Host.commands
  | Host.Transition transition -> (
      project transition.Host.projection;
      List.iter dispatch transition.Host.commands;
      match transition.Host.input with
      | Host.Core.Worker_progress
          { issue; run; progress = value; emitted_at = _ } ->
          progress issue run value
      | Host.Core.Worker_finished completed ->
          Output.emit output ~event:"worker_closed"
            ([
               ("issue_id", Issue_id.text (Agent.completed_issue completed));
               ("run_id", Run_id.text (Agent.completed_run completed));
             ]
            @ outcome_fields (Agent.outcome completed))
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
      | Host.Core.Shutdown -> ())
  | Host.Effect _ -> ()

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

let run ~fs ~net ~sink ~clock ~runtime ~cwd ~ca_bundle ~io ~env ~document =
  (* Signal custody covers output drainage as well as service closure. *)
  let closed = ref None in
  let report_signal diagnostic =
    match !closed with
    | None -> closed := Some diagnostic
    | Some _ -> ()
  in
  let result =
    Native_shutdown.with_signal ~report:report_signal (fun signal ->
        Output.with_output ~clock ~sink (fun output ->
            let report diagnostic =
              Output.emit output ~event:"host_cleanup_failure"
                [ ("diagnostic", Diagnostic.render diagnostic) ]
            in
            let startup =
              match
                Tracker_runtime.registry ~fs ~net ~clock ~runtime ~cwd
                  ~ca_bundle ~warning:(fun text ->
                    Output.emit output ~event:"tracker_omission"
                      [ ("diagnostic", text) ])
              with
              | Error error -> Error (Tracker_error.diagnostic error)
              | Ok registry -> (
                  match Config.resolve registry ~env ~document with
                  | Ok config -> Ok (registry, config)
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
                           ~remedy:
                             "Correct the workflow before restarting Symphony.")
                  )
            in
            match startup with
            | Error diagnostic ->
                (try
                   Output.emit output ~event:"workflow_invalid"
                     [ ("diagnostic", Diagnostic.render diagnostic) ]
                 with _ -> ());
                Error diagnostic
            | Ok (registry, config) -> (
                let host =
                  Native.create ~fs ~clock
                    ~emit:(fun reference hook event ->
                      Output.emit output ~event:"hook"
                        ([
                           ( "issue_id",
                             Issue_id.text (Native.Contract.issue_id reference)
                           );
                           ("hook", hook_name hook);
                         ]
                        @ hook_fields event))
                    ~report:(fun error -> report (workspace_error error))
                in
                let service =
                  Assembly.create ~clock ~workspace:(Native.workspace host)
                    ~agent:
                      (Agent.create ~process:(Native.process host)
                         ~version:"0.1.0")
                    ~file:io ~registry ~env ~report:(fault output)
                    ~report_host:(function
                      | Host.Secondary_defect { key; diagnostic } ->
                          Output.emit output ~event:"host_cleanup_failure"
                            (key_fields key
                            @ [ ("diagnostic", Diagnostic.render diagnostic) ]))
                    ~observe:(observe output)
                in
                let execute () =
                  Eio.Switch.run (fun sw ->
                      let controls = Eio.Stream.create 1 in
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
                      Output.emit output ~event:"service_started"
                        [
                          ( "workflow",
                            Workflow_path.display (Config.file config) );
                        ];
                      Host.run ~sw service ~controls config)
                in
                let result =
                  try execute ()
                  with error ->
                    let trace = Printexc.get_raw_backtrace () in
                    (* The process edge never records an exception payload. *)
                    (try Output.emit output ~event:"host_failure" []
                     with _ -> ());
                    Printexc.raise_with_backtrace error trace
                in
                match result with
                | Ok () ->
                    Output.emit output ~event:"service_stopped" [];
                    Ok ()
                | Error diagnostic ->
                    (try
                       Output.emit output ~event:"service_failure"
                         [ ("diagnostic", Diagnostic.render diagnostic) ]
                     with _ -> ());
                    Error diagnostic)))
  in
  match (result, !closed) with
  | Error _, _ | Ok (), None -> result
  | Ok (), Some diagnostic -> Error diagnostic
