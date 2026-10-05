module Config = Tracker_runtime.Config
module Loader = Workflow_loader.Make (Workflow_file)

let ( let* ) = Result.bind

let loader_error = function
  | Workflow_loader.Missing_file d | Workflow_loader.Read_error d ->
      Diagnostic.render d
  | Workflow_loader.Invalid_document
      ( Workflow_document.Parse_error d
      | Workflow_document.Front_matter_not_map d ) -> Diagnostic.render d

let config_error = function
  | Config_layer.Workflow e -> loader_error e
  | Config_layer.Fields es ->
      String.concat "\n" (List.map Diagnostic.render (Nonempty_list.to_list es))
  | Config_layer.Tracker e -> Diagnostic.render (Tracker_error.diagnostic e)

let template_error = function
  | Template.Parse_error d | Template.Render_error d -> Diagnostic.render d

let read_issue io ~cwd filename =
  let* file = Workflow_path.resolve ~base:cwd filename in
  let* text = Result.map_error loader_error (Workflow_file.read io ~file) in
  Result.map_error
    (fun message ->
      Text.escape (Workflow_path.display file)
      ^ ": " ^ Text.escape message ^ "; fix the normalized issue JSON")
    (Prompt_fixture.parse text)

let run ~fs ~net ~sink ~clock ~runtime ~cwd ~env ~default_ca_bundle ~argv ~out
    ~err =
  let io = Workflow_file.make fs in
  let document filename =
    let* file = Workflow_path.resolve ~base:cwd filename in
    Result.map_error loader_error (Loader.load io ~file)
  in
  let load ?(ca_bundle = default_ca_bundle) filename =
    let* document = document filename in
    let* registry =
      Result.map_error
        (fun e -> Diagnostic.render (Tracker_error.diagnostic e))
        (Tracker_runtime.registry ~fs ~net ~clock ~runtime ~cwd ~ca_bundle
           ~warning:(fun text -> Format.fprintf err "%s\n%!" text))
    in
    let* config =
      Result.map_error config_error (Config.resolve registry ~env ~document)
    in
    Ok config
  in
  let doctor filename =
    let* config = load filename in
    out
      (Printf.sprintf
         "Workflow valid: %s\nWorkspace root: %s\nConcurrency: %d\n"
         (Workflow_path.display (Config.file config))
         (Absolute_path.display
            (Workspace_settings.root (Config.workspace config)))
         (Scheduling_policy.global_limit (Config.scheduling config)));
    Ok ()
  in
  let dry filename fixture attempt =
    let* config = load filename in
    let* template =
      Result.map_error template_error
        (Template.compile ~file:(Config.file config)
           (Config.prompt_source config))
    in
    let* issue = read_issue io ~cwd fixture in
    let* attempt =
      match attempt with
      | None -> Ok Template.First
      | Some s ->
          Result.map
            (fun n -> Template.Follow_up n)
            (Result.map_error
               (fun message ->
                 "--attempt: " ^ message
                 ^ "; use a positive decimal retry attempt")
               (Positive_count.parse s))
    in
    let* prompt =
      Result.map_error template_error (Template.render template ~issue ~attempt)
    in
    out (prompt ^ "\n");
    Ok ()
  in
  let workspace filename fixture =
    let* config = load filename in
    let* issue = read_issue io ~cwd fixture in
    let identifier =
      Text.escape (Issue_identifier.text (Issue.identifier issue))
    in
    let* found =
      Result.map_error
        (fun error ->
          Text.escape (Workflow_path.display (Config.file config))
          ^ ": issue " ^ identifier ^ ": " ^ Workspace_cli.error error)
        (Workspace_cli.inspect ~fs ~clock ~settings:(Config.workspace config)
           ~env:(Config.child_env config)
           ~scope:(Tracker_registry.Contract.scope (Config.tracker config))
           ~issue)
    in
    out
      (match found with
      | None -> "Workspace missing: " ^ identifier ^ "\n"
      | Some label -> "Workspace: " ^ Text.escape label ^ "\n");
    Ok ()
  in
  let tracker filename ca_bundle =
    let* config = load ~ca_bundle filename in
    let* batch =
      Result.map_error
        (fun e -> Diagnostic.render (Tracker_error.diagnostic e))
        (Tracker_runtime.inspect config)
    in
    (* Emit only after the entire read succeeds; the batch preserves page order. *)
    out "[";
    List.iteri
      (fun index issue ->
        if index > 0 then out ",";
        out (Json.encode (Issue.to_json issue)))
      (Issue_batch.ordered batch);
    out "]\n";
    Ok ()
  in
  let serve filename ca_bundle =
    let* document = document filename in
    (* Runtime failures are already reported by the scoped output writer. *)
    let status =
      try
        match
          Service_cli.run ~fs ~net ~sink ~clock ~runtime ~cwd ~ca_bundle ~io
            ~env ~document
        with
        | Ok () -> Cmdliner.Cmd.Exit.ok
        | Error _ -> Cmdliner.Cmd.Exit.some_error
      with _ -> Cmdliner.Cmd.Exit.some_error
    in
    Ok status
  in
  let inspected action = Result.map (fun () -> Cmdliner.Cmd.Exit.ok) action in
  let file_arg =
    Cmdliner.Arg.(
      value & pos 0 string "WORKFLOW.md"
      & info [] ~docv:"WORKFLOW"
          ~doc:"Workflow file; defaults to ./WORKFLOW.md.")
  in
  let issue_arg =
    Cmdliner.Arg.(
      required
      & opt (some string) None
      & info [ "issue" ] ~docv:"ISSUE.json"
          ~doc:"Local normalized issue JSON; no tracker request.")
  in
  let attempt_arg =
    Cmdliner.Arg.(
      value
      & opt (some string) None
      & info [ "attempt" ] ~docv:"N"
          ~doc:"Positive retry attempt; omitted for the first attempt.")
  in
  let ca_arg =
    Cmdliner.Arg.(
      value
      & opt string default_ca_bundle
      & info [ "ca-bundle" ] ~docv:"CA.pem"
          ~doc:"Explicit PEM trust anchors for authenticated tracker HTTPS.")
  in
  let tracker =
    Cmdliner.Cmd.v
      (Cmdliner.Cmd.info "tracker"
         ~doc:"Fetch configured active issues as ordered normalized JSON.")
      Cmdliner.Term.(
        const (fun file ca -> inspected (tracker file ca)) $ file_arg $ ca_arg)
  in
  let doctor =
    Cmdliner.Cmd.v
      (Cmdliner.Cmd.info "doctor"
         ~doc:"Validate workflow settings and prompt syntax.")
      Cmdliner.Term.(const (fun file -> inspected (doctor file)) $ file_arg)
  in
  let dry =
    Cmdliner.Cmd.v
      (Cmdliner.Cmd.info "dry-run"
         ~doc:"Render a prompt using a local issue fixture.")
      Cmdliner.Term.(
        const (fun file issue attempt -> inspected (dry file issue attempt))
        $ file_arg $ issue_arg $ attempt_arg)
  in
  let workspace =
    Cmdliner.Cmd.v
      (Cmdliner.Cmd.info "workspace"
         ~doc:
           "Inspect an existing owned workspace without creating it or running \
            hooks.")
      Cmdliner.Term.(
        const (fun file issue -> inspected (workspace file issue))
        $ file_arg $ issue_arg)
  in
  let run_term = Cmdliner.Term.(const serve $ file_arg $ ca_arg) in
  let run_command =
    Cmdliner.Cmd.make
      (Cmdliner.Cmd.info "run"
         ~doc:"Run issue polling and closed agent attempts.")
      run_term
  in
  let info =
    Cmdliner.Cmd.info "symphony" ~version:"0.1.0"
      ~doc:"Run Symphony using a workflow file."
      ~man:
        [
          `S Cmdliner.Manpage.s_description;
          `P
            "SIGINT and SIGTERM stop admission, then join workers, hooks and \
             workspace leases.";
          `P
            "Use the run subcommand when the workflow filename matches an \
             inspection command.";
          `S Cmdliner.Manpage.s_commands;
          `P "run, doctor, dry-run, workspace, tracker";
        ]
  in
  let group =
    Cmdliner.Cmd.group info [ run_command; doctor; dry; workspace; tracker ]
  in
  (* Cmdliner groups require -- before a default positional path. A direct root
     command gives the specified symphony [WORKFLOW] syntax without rewriting argv. *)
  let command =
    match Array.to_list argv with
    | _ :: ("run" | "doctor" | "dry-run" | "workspace" | "tracker") :: _ ->
        group
    | [] | [ _ ] | _ :: _ :: _ -> Cmdliner.Cmd.make info run_term
  in
  Cmdliner.Cmd.eval_result' ~catch:false ~env:(fun _ -> None) ~argv ~err command
