module Path = Lifecycle_fixture.Path
module Workspace = Lifecycle_fixture.Workspace
module Agent = Lifecycle_fixture.Agent
module Config = Lifecycle_fixture.Config

module Core =
  Orchestrator.Make (Tracker_registry.Contract) (Clock.Pure) (Workspace) (Agent)
    (Config)

type profile =
  | A
  | B
  | Declining
  | Other_scope
  | Tight
  | New_policy
  | Required
  | Growing_retry

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let base = checked (Absolute_path.parse "/fixture/core")
let file = checked (Workflow_path.resolve ~base "WORKFLOW.md")
let poll_ms = 5
let retry_cap_ms = 40
let growing_retry_cap_ms = 45000
let initial_cap = 2

let resolve profile =
  let tag, project, prompt =
    match profile with
    | A | Tight | New_policy | Required | Growing_retry ->
        ("a", "core-fixture", "a")
    | B -> ("b", "core-fixture", "b")
    | Declining -> ("declining", "core-fixture", "decline")
    | Other_scope -> ("other", "another-core", "other")
  in
  let cap =
    match profile with
    | Tight -> 1
    | A | B | Declining | Other_scope | New_policy | Required | Growing_retry ->
        initial_cap
  in
  let terminal, interval =
    match profile with
    | New_policy -> ("Done, Closed", 7)
    | A | B | Declining | Other_scope | Tight | Required | Growing_retry ->
        ("Done", poll_ms)
  in
  let required_labels =
    match profile with
    | Required -> "[\"  READY  \", \" Reviewed \"]"
    | A | B | Declining | Other_scope | Tight | New_policy | Growing_retry ->
        "[]"
  in
  let retry_cap =
    match profile with
    | Growing_retry -> growing_retry_cap_ms
    | A | B | Declining | Other_scope | Tight | New_policy | Required ->
        retry_cap_ms
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
      \  terminal_states: [%s]\n\
      \  required_labels: %s\n\
      \  provider:\n\
      \    project_slug: %s\n\
       polling:\n\
      \  interval_ms: %d\n\
       agent:\n\
      \  max_concurrent_agents: %d\n\
      \  max_concurrent_agents_by_state: {Todo: 1, Doing: 2}\n\
      \  max_retry_backoff_ms: %d\n\
       workspace:\n\
      \  root: /fixture/root-%s\n\
       hooks:\n\
      \  after_run: finish-%s\n\
       codex:\n\
      \  command: agent-%s app-server\n\
       ---\n\
       %s"
      terminal required_labels project interval cap retry_cap tag tag tag prompt
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

(* Keep one checked value per profile; no registry/network operation occurs. *)
let profiles =
  List.map
    (fun profile -> (profile, resolve profile))
    [ A; B; Declining; Other_scope; Tight; New_policy; Required; Growing_retry ]

let config profile =
  match List.assoc_opt profile profiles with
  | Some value -> value
  | None -> Alcotest.fail "Unknown core fixture profile"

let binding_profile binding =
  match
    List.find_opt
      (fun (_, config) ->
        Tracker_registry.Contract.equal binding (Config.tracker config))
      profiles
  with
  | Some (profile, _) -> profile
  | None -> Alcotest.fail "Core command uses an unknown fixture binding"

let issue ?(state = "Todo") ?(title = "Core fixture")
    ?(routing = Issue.Dispatchable) ?(labels = []) ?priority ?created_at ~id
    ~identifier () =
  checked
    (Issue.parse
       {
         Issue.id;
         identifier;
         title;
         description = None;
         priority = Option.map string_of_int priority;
         state;
         branch_name = None;
         url = None;
         assignee_id = None;
         labels;
         blocked_by = [];
         created_at;
         updated_at = None;
         dispatchable = routing;
         native_ref = None;
       })

let reply issues =
  Ok
    (List.fold_left
       (fun found issue -> Issue_id.Map.add (Issue.id issue) issue found)
       Issue_id.Map.empty issues)

let instant = Lifecycle_fixture.instant
let completed = Lifecycle_fixture.completed
let diagnostic = Lifecycle_fixture.diagnostic
let tracker_error = Lifecycle_fixture.tracker_error
let invalid_config = Config_layer.Fields (Nonempty_list.singleton diagnostic)
