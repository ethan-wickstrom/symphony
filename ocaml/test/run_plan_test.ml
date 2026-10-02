let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let workspace_error = function
  | Workspace_manager.Invalid_key diagnostic
  | Workspace_manager.Unsafe_path diagnostic
  | Workspace_manager.Ownership_conflict diagnostic
  | Workspace_manager.Filesystem_error diagnostic
  | Workspace_manager.Hook_failed diagnostic
  | Workspace_manager.Hook_timeout diagnostic -> Diagnostic.render diagnostic

let config_error = function
  | Config_layer.Tracker error ->
      Diagnostic.render (Tracker_error.diagnostic error)
  | Config_layer.Fields errors ->
      String.concat "\n"
        (List.map Diagnostic.render (Nonempty_list.to_list errors))
  | Config_layer.Workflow
      ( Workflow_loader.Missing_file diagnostic
      | Workflow_loader.Read_error diagnostic )
  | Config_layer.Workflow
      (Workflow_loader.Invalid_document
         ( Workflow_document.Parse_error diagnostic
         | Workflow_document.Front_matter_not_map diagnostic )) ->
      Diagnostic.render diagnostic

module Path = struct
  type t = |

  let display (value : t) =
    match value with
    | _ -> .
end

module Workspace = Workspace_reference.Make (Path)
module Agent = Agent_plan.Make (Workspace)
module Config = Config_layer.Make (Tracker_registry)

module Plan =
  Run_plan.Make (Tracker_registry.Contract) (Workspace) (Agent) (Config)

let base = checked (Absolute_path.parse "/fixture/workflows")
let file = checked (Workflow_path.resolve ~base "WORKFLOW.md")
let run, _ = Run_id.Allocator.fresh Run_id.Allocator.empty

let issue id identifier =
  checked
    (Prompt_fixture.parse
       (Yojson.Safe.to_string
          (`Assoc
             [
               ("id", `String id);
               ("identifier", `String identifier);
               ("title", `String "Plan fixture");
               ("state", `String "Todo");
               ("dispatchable", `Bool true);
             ])))

let config tag =
  let credential = "fixture-secret-" ^ tag in
  let env =
    checked
      (Environment.of_bindings ~temp_dir:base
         [
           ("LINEAR_API_KEY", credential);
           ("LANG", credential);
           ("HOME", "/fixture/home-" ^ tag);
           ("PATH", "/fixture/bin-" ^ tag);
         ])
  in
  let source =
    Printf.sprintf
      "---\n\
       tracker:\n\
      \  kind: linear\n\
      \  active_states: [Todo]\n\
      \  terminal_states: [Done]\n\
      \  provider:\n\
      \    project_slug: planning-fixture\n\
       workspace:\n\
      \  root: /fixture/root-%s\n\
       hooks:\n\
      \  after_run: finish-%s\n\
       codex:\n\
      \  command: agent-%s app-server\n\
       ---\n\
       prompt-%s"
      tag tag tag tag
  in
  let document =
    match Workflow_document.parse ~file source with
    | Ok document -> document
    | Error
        ( Workflow_document.Parse_error diagnostic
        | Workflow_document.Front_matter_not_map diagnostic ) ->
        Alcotest.fail (Diagnostic.render diagnostic)
  in
  match Config.resolve Tracker_fixture.registry ~env ~document with
  | Ok config -> config
  | Error error -> Alcotest.fail (config_error error)

let planned config issue attempt =
  match Plan.create config ~run ~issue ~attempt with
  | Ok plan -> plan
  | Error rejected ->
      Alcotest.fail (workspace_error (Plan.rejected_error rejected))

let attempt = function
  | Template.First -> "first"
  | Template.Follow_up value -> Count.decimal (Positive_count.count value)

let observe plan =
  let request = Plan.request plan in
  let reference = Agent.workspace request in
  let settings = Workspace.settings reference in
  ( Run_id.text (Agent.run_id request),
    Json.encode (Issue.to_json (Agent.issue request)),
    Issue_id.text (Workspace.issue_id reference),
    Issue_identifier.text (Workspace.identifier reference),
    Tracker_scope.text (Workspace.scope reference),
    Absolute_path.display (Workspace_settings.root settings),
    Workspace_settings.script settings Workspace_settings.After_run,
    Environment.bindings (Workspace.environment reference),
    Agent_settings.command (Agent.agent request),
    Workflow_path.display (Agent.prompt_file request),
    Agent.prompt_source request,
    attempt (Agent.attempt request) )

let frozen_launch () =
  let original = config "old" in
  let current = config "new" in
  let original_issue = issue "opaque/issue" "PLAN-1" in
  let follow_up = Template.Follow_up (checked (Positive_count.parse "17")) in
  let old = planned original original_issue follow_up in
  let before = observe old in
  let replacement = planned current original_issue Template.First in
  Alcotest.(check bool)
    "original binding" true
    (Tracker_registry.Contract.equal (Config.tracker original)
       (Plan.binding old));
  Alcotest.(check bool)
    "changed binding is distinguishable" false
    (Tracker_registry.Contract.equal (Plan.binding old)
       (Plan.binding replacement));
  Alcotest.(check bool)
    "credential changes preserve tracker scope" true
    (Tracker_scope.equal
       (Tracker_registry.Contract.scope (Plan.binding old))
       (Tracker_registry.Contract.scope (Plan.binding replacement)));
  Alcotest.(check bool)
    "later planning preserves original facts" true
    (before = observe old);
  let request = Plan.request old in
  let reference = Agent.workspace request in
  Alcotest.(check string)
    "original root" "/fixture/root-old"
    (Absolute_path.display
       (Workspace_settings.root (Workspace.settings reference)));
  Alcotest.(check (option string))
    "original hook" (Some "finish-old")
    (Workspace_settings.script
       (Workspace.settings reference)
       Workspace_settings.After_run);
  Alcotest.(check (list (pair string string)))
    "sanitized original child environment"
    [ ("HOME", "/fixture/home-old"); ("PATH", "/fixture/bin-old") ]
    (Environment.bindings (Workspace.environment reference));
  Alcotest.(check string)
    "original prompt" "prompt-old"
    (Agent.prompt_source request);
  Alcotest.(check string)
    "follow-up attempt" "17"
    (attempt (Agent.attempt request));
  Alcotest.(check bool)
    "reference scope derives from original binding" true
    (Tracker_scope.equal
       (Workspace.scope reference)
       (Tracker_registry.Contract.scope (Plan.binding old)))

let unnamed_rejection () =
  let configured = config "unnamed" in
  let rejected_issue = issue "opaque/rejected" "." in
  match
    Plan.create configured ~run ~issue:rejected_issue ~attempt:Template.First
  with
  | Ok _ -> Alcotest.fail "unsafe key produced an agent request"
  | Error rejected ->
      (match Plan.rejected_target rejected with
      | Plan.Named _ ->
          Alcotest.fail "unsafe key fabricated a workspace reference"
      | Plan.Unnamed scope ->
          Alcotest.(check bool)
            "scope retained without cleanup authority" true
            (Tracker_scope.equal scope
               (Tracker_registry.Contract.scope (Config.tracker configured))));
      (match Plan.rejected_error rejected with
      | Workspace_manager.Invalid_key _ -> ()
      | Workspace_manager.Unsafe_path _
      | Workspace_manager.Ownership_conflict _
      | Workspace_manager.Filesystem_error _
      | Workspace_manager.Hook_failed _
      | Workspace_manager.Hook_timeout _ -> Alcotest.fail "wrong planning error");
      Alcotest.(check string)
        "rejected issue retained" "opaque/rejected"
        (Issue_id.text (Issue.id (Plan.rejected_issue rejected)));
      Alcotest.(check string)
        "rejected attempt retained" "first"
        (attempt (Plan.rejected_attempt rejected))

module Declining = struct
  include Agent

  let request ~run_id:_ ~issue ~workspace:_ ~agent:_ ~prompt_file:_
      ~prompt_source:_ ~attempt:_ =
    Error
      (Workspace_manager.Ownership_conflict
         (Diagnostic.make
            ~site:
              (Diagnostic.Issue
                 { id = Issue.id issue; identifier = Issue.identifier issue })
            ~message:"Fixture launch declined"
            ~remedy:"Repair the fixture launch policy"))
end

module Declined_plan =
  Run_plan.Make (Tracker_registry.Contract) (Workspace) (Declining) (Config)

let named_rejection () =
  let configured = config "named" in
  let selected = issue "opaque/named" "PLAN-2" in
  let follow_up = Template.Follow_up Positive_count.first in
  match
    Declined_plan.create configured ~run ~issue:selected ~attempt:follow_up
  with
  | Ok _ -> Alcotest.fail "declined request produced a run plan"
  | Error rejected ->
      (match Declined_plan.rejected_target rejected with
      | Declined_plan.Unnamed _ ->
          Alcotest.fail "checked reference was discarded"
      | Declined_plan.Named reference ->
          Alcotest.(check string)
            "original checked reference" "opaque/named"
            (Issue_id.text (Workspace.issue_id reference)));
      Alcotest.(check string)
        "exact request failure retained"
        (workspace_error
           (Workspace_manager.Ownership_conflict
              (Diagnostic.make
                 ~site:
                   (Diagnostic.Issue
                      {
                        id = Issue.id selected;
                        identifier = Issue.identifier selected;
                      })
                 ~message:"Fixture launch declined"
                 ~remedy:"Repair the fixture launch policy")))
        (workspace_error (Declined_plan.rejected_error rejected));
      Alcotest.(check string)
        "attempt survived request rejection" "1"
        (attempt (Declined_plan.rejected_attempt rejected))

let identity_fencing () =
  let configured = config "identity" in
  let original = issue "opaque/original" "PLAN-3" in
  let request = Plan.request (planned configured original Template.First) in
  let reference = Agent.workspace request in
  List.iter
    (fun other ->
      match
        Agent.request ~run_id:run ~issue:other ~workspace:reference
          ~agent:(Config.agent configured) ~prompt_file:(Config.file configured)
          ~prompt_source:(Config.prompt_source configured)
          ~attempt:Template.First
      with
      | Error (Workspace_manager.Ownership_conflict _) -> ()
      | Error
          (( Workspace_manager.Invalid_key _
           | Workspace_manager.Unsafe_path _
           | Workspace_manager.Filesystem_error _
           | Workspace_manager.Hook_failed _
           | Workspace_manager.Hook_timeout _ ) as error) ->
          Alcotest.fail (workspace_error error)
      | Ok _ -> Alcotest.fail "mismatched opaque ID or identifier accepted")
    [ issue "opaque/recreated" "PLAN-3"; issue "opaque/original" "PLAN-4" ]

let tests =
  [
    Alcotest.test_case "frozen launch inputs and secret exclusion" `Quick
      frozen_launch;
    Alcotest.test_case "key rejection has no cleanup authority" `Quick
      unnamed_rejection;
    Alcotest.test_case "request rejection retains checked reference" `Quick
      named_rejection;
    Alcotest.test_case "launch identity checks ID and identifier" `Quick
      identity_fencing;
  ]

let properties =
  [
    QCheck2.Test.make
      ~name:"plans are pure and freeze the original configuration" ~count:1000
      QCheck2.Gen.(pair (int_range 0 10000) (int_range 1 1000))
      (fun (tag, n) ->
        let configured = config (string_of_int tag) in
        let selected =
          issue ("opaque/" ^ string_of_int tag) ("PLAN-" ^ string_of_int tag)
        in
        let turn =
          Template.Follow_up (checked (Positive_count.parse (string_of_int n)))
        in
        let first = planned configured selected turn in
        let second = planned configured selected turn in
        let before = observe first in
        ignore
          (planned (config (string_of_int (tag + 1))) selected Template.First);
        before = observe second
        && before = observe first
        && Tracker_registry.Contract.equal (Plan.binding first)
             (Config.tracker configured)
        && Issue_id.equal
             (Issue.id (Agent.issue (Plan.request first)))
             (Issue.id selected)
        && Issue_identifier.equal
             (Workspace.identifier (Agent.workspace (Plan.request first)))
             (Issue.identifier selected));
  ]
