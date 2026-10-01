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

let run ~fs ~net ~clock ~runtime ~cwd ~env ~default_ca_bundle ~argv ~out ~err =
  let io = Workflow_file.make fs in
  let load ?(ca_bundle = default_ca_bundle) filename =
    let* file = Workflow_path.resolve ~base:cwd filename in
    let* document = Result.map_error loader_error (Loader.load io ~file) in
    let* registry =
      Result.map_error
        (fun e -> Diagnostic.render (Tracker_error.diagnostic e))
        (Tracker_runtime.registry ~fs ~net ~clock ~runtime ~cwd ~ca_bundle
           ~warning:(fun text -> Format.fprintf err "%s\n%!" text))
    in
    let* config =
      Result.map_error config_error (Config.resolve registry ~env ~document)
    in
    let* template =
      Result.map_error template_error
        (Template.compile ~file (Config.prompt_source config))
    in
    Ok (config, template)
  in
  let doctor filename =
    let* config, _ = load filename in
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
    let* _, template = load filename in
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
    let* config, _ = load filename in
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
    let* config, _ = load ~ca_bundle filename in
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
  let file_arg =
    Cmdliner.Arg.(
      value & pos 0 string "WORKFLOW.md"
      & info [] ~docv:"WORKFLOW" ~doc:"Workflow file to inspect.")
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
      Cmdliner.Term.(const tracker $ file_arg $ ca_arg)
  in
  let doctor =
    Cmdliner.Cmd.v
      (Cmdliner.Cmd.info "doctor"
         ~doc:"Validate workflow settings and prompt syntax.")
      Cmdliner.Term.(const doctor $ file_arg)
  in
  let dry =
    Cmdliner.Cmd.v
      (Cmdliner.Cmd.info "dry-run"
         ~doc:"Render a prompt using a local issue fixture.")
      Cmdliner.Term.(const dry $ file_arg $ issue_arg $ attempt_arg)
  in
  let workspace =
    Cmdliner.Cmd.v
      (Cmdliner.Cmd.info "workspace"
         ~doc:
           "Inspect an existing owned workspace without creating it or running \
            hooks.")
      Cmdliner.Term.(const workspace $ file_arg $ issue_arg)
  in
  let command =
    Cmdliner.Cmd.group
      (Cmdliner.Cmd.info "symphony" ~version:"0.1.0"
         ~doc:"Symphony OCaml workflow and workspace inspection.")
      [ doctor; dry; workspace; tracker ]
  in
  Cmdliner.Cmd.eval_result ~catch:false ~env:(fun _ -> None) ~argv ~err command
