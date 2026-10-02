let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let diagnostic =
  Diagnostic.make ~site:(Diagnostic.Host "lifecycle.fixture")
    ~message:"Fixture failure" ~remedy:"Repair the fixture input"

let tracker_error = Tracker_error.make Tracker_error.Tracker_request diagnostic

let workspace_error = function
  | Workspace_manager.Invalid_key error
  | Workspace_manager.Unsafe_path error
  | Workspace_manager.Ownership_conflict error
  | Workspace_manager.Filesystem_error error
  | Workspace_manager.Hook_failed error
  | Workspace_manager.Hook_timeout error -> Diagnostic.render error

module Path = struct
  type t = Path of string

  let display (Path value) = value
end

module Workspace = Workspace_reference.Make (Path)

let with_path reference use =
  let root =
    Absolute_path.display
      (Workspace_settings.root (Workspace.settings reference))
  in
  let key = Workspace_key.text (Workspace.key reference) in
  use (Path.Path (Filename.concat root key))

module Agent = struct
  module Base = Agent_plan.Make (Workspace)
  include Base

  let request ~run_id ~issue ~workspace ~agent ~prompt_file ~prompt_source
      ~attempt =
    if String.equal prompt_source "decline" then
      Error (Workspace_manager.Ownership_conflict diagnostic)
    else
      Base.request ~run_id ~issue ~workspace ~agent ~prompt_file ~prompt_source
        ~attempt

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

  (* No resource is acquired by this test port. Only it can mint this witness. *)
  type completed = Closed of Issue_id.t * Run_id.t * Agent_runner.outcome

  let completed ~issue ~run outcome = Closed (issue, run, outcome)
  let completed_issue (Closed (issue, _, _)) = issue
  let completed_run (Closed (_, run, _)) = run
  let outcome (Closed (_, _, outcome)) = outcome
end

module Config = Config_layer.Make (Tracker_registry)

module Plan =
  Run_plan.Make (Tracker_registry.Contract) (Workspace) (Agent) (Config)

module Lifecycle =
  Issue_lifecycle.Make (Tracker_registry.Contract) (Clock.Pure) (Workspace)
    (Agent)
    (Plan)

type profile = Original | Replacement | Declining | Other_scope

let base = checked (Absolute_path.parse "/fixture/lifecycle")
let file = checked (Workflow_path.resolve ~base "WORKFLOW.md")

let config profile =
  let tag, project, prompt =
    match profile with
    | Original -> ("original", "lifecycle-fixture", "original")
    | Replacement -> ("replacement", "lifecycle-fixture", "replacement")
    | Declining -> ("declining", "lifecycle-fixture", "decline")
    | Other_scope -> ("other", "another-project", "other")
  in
  let env =
    checked
      (Environment.of_bindings ~temp_dir:base
         [
           ("LINEAR_API_KEY", "fixture-secret-" ^ tag);
           ("HOME", "/fixture/home-" ^ tag);
           ("PATH", "/fixture/bin-" ^ tag);
         ])
  in
  let source =
    Printf.sprintf
      "---\n\
       tracker:\n\
      \  kind: linear\n\
      \  active_states: [Todo, Doing]\n\
      \  terminal_states: [Done]\n\
      \  provider:\n\
      \    project_slug: %s\n\
       workspace:\n\
      \  root: /fixture/root-%s\n\
       hooks:\n\
      \  after_run: finish-%s\n\
       codex:\n\
      \  command: agent-%s app-server\n\
       ---\n\
       %s"
      project tag tag tag prompt
  in
  let document =
    match Workflow_document.parse ~file source with
    | Ok value -> value
    | Error
        ( Workflow_document.Parse_error error
        | Workflow_document.Front_matter_not_map error ) ->
        Alcotest.fail (Diagnostic.render error)
  in
  match Config.resolve Tracker_fixture.registry ~env ~document with
  | Ok value -> value
  | Error (Config_layer.Tracker error) ->
      Alcotest.fail (Diagnostic.render (Tracker_error.diagnostic error))
  | Error (Config_layer.Fields errors) ->
      Alcotest.fail
        (String.concat "\n"
           (List.map Diagnostic.render (Nonempty_list.to_list errors)))
  | Error (Config_layer.Workflow _) -> Alcotest.fail "Fixture workflow failed"

let issue ?(state = "Todo") ?(title = "Lifecycle fixture") ~id ~identifier () =
  checked
    (Issue.parse
       {
         Issue.id;
         identifier;
         title;
         description = None;
         priority = None;
         state;
         branch_name = None;
         url = None;
         assignee_id = None;
         labels = [];
         blocked_by = [];
         created_at = None;
         updated_at = None;
         dispatchable = Issue.Dispatchable;
         native_ref = None;
       })

let plan config ~run ~issue ~attempt =
  match Plan.create config ~run ~issue ~attempt with
  | Ok value -> value
  | Error rejection ->
      Alcotest.fail (workspace_error (Plan.rejected_error rejection))

let rejection config ~run ~issue ~attempt =
  match Plan.create config ~run ~issue ~attempt with
  | Error value -> value
  | Ok _ -> Alcotest.fail "Expected checked planning rejection"

let completed = Agent.completed

let instant milliseconds =
  Clock.Pure.of_nanoseconds
    (checked (Count.parse (string_of_int (milliseconds * 1_000_000))))

let positive value = checked (Positive_count.parse (string_of_int value))
