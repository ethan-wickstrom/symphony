let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let tracker_checked = function
  | Ok value -> value
  | Error error ->
      Alcotest.fail (Diagnostic.render (Tracker_error.diagnostic error))

let issue state id =
  checked
    (Issue.parse
       {
         Issue.id;
         identifier = "FIX-" ^ id;
         title = "snapshot " ^ id;
         description = Some "complete snapshot";
         priority = None;
         state;
         branch_name = None;
         url = None;
         assignee_id = None;
         labels = [ "checked" ];
         blocked_by = [];
         created_at = None;
         updated_at = None;
         dispatchable = Issue.Dispatchable;
         native_ref = None;
       })

let batch = function
  | Ok batch -> batch
  | Error (Issue_batch.Duplicate_id _) -> Alcotest.fail "duplicate fixture ID"
  | Error (Issue_batch.Duplicate_identifier _) ->
      Alcotest.fail "duplicate fixture identifier"

module Provider = struct
  type settings = { provider : Json.t; credential : string option }

  type trace =
    | States of settings * Tracker_read_policy.t * string list
    | Ids of settings * Tracker_read_policy.t * string list

  type outcome =
    | Batch of Issue_batch.t
    | Failed of Tracker_error.t
    | Raised of exn

  type io = { calls : trace list ref; outcome : outcome }

  let kind = "binding-fixture"

  let equal a b =
    Json.equal a.provider b.provider && a.credential = b.credential

  let credential_source = "FIXTURE_TOKEN"
  let secret_names _ = [ credential_source ]
  let scope _ = checked (Tracker_scope.parse "binding-fixture-project")

  let parse ~env provider =
    let credential = Environment.lookup env credential_source in
    let public =
      Environment.public env ~deny:[ credential_source ]
        ~secrets:
          (List.filter_map Environment.Secret.make (Option.to_list credential))
    in
    Result.map
      (fun provider ->
        let settings = { provider; credential } in
        (settings, public))
      (Result.map_error
         (fun message ->
           Tracker_error.make Tracker_error.Invalid_tracker_config
             (Fields.diagnostic ~key:"tracker.provider" message))
         (Fields.json public provider))

  let states io settings ~policy names =
    match names with
    | [] -> Ok Issue_batch.empty
    | _ :: _ -> (
        io.calls := States (settings, policy, names) :: !(io.calls);
        match io.outcome with
        | Batch batch -> Ok batch
        | Failed error -> Error error
        | Raised exn -> raise exn)

  let ids io settings ~policy ids =
    if Issue_id.Set.is_empty ids then Ok Issue_id.Map.empty
    else (
      io.calls :=
        Ids
          (settings, policy, List.map Issue_id.text (Issue_id.Set.elements ids))
        :: !(io.calls);
      match io.outcome with
      | Batch batch ->
          Ok
            (Issue_id.Map.filter
               (fun id _ -> Issue_id.Set.mem id ids)
               (Issue_batch.by_id batch))
      | Failed error -> Error error
      | Raised exn -> raise exn)
end

let io issues =
  Provider.
    { calls = ref []; outcome = Batch (batch (Issue_batch.of_list issues)) }

let registry io =
  tracker_checked
    (Tracker_registry.make [ Tracker_registry.Entry ((module Provider), io) ])

let env token =
  checked
    (Environment.of_bindings
       ~temp_dir:(checked (Absolute_path.parse "/fixture/temp"))
       [ ("FIXTURE_TOKEN", token) ])

let binding registry revision token =
  fst
    (tracker_checked
       (Tracker_registry.configure registry ~env:(env token)
          ~kind:(checked (Config_value.parse Provider.kind))
          ~provider:
            (checked
               (Config_value.parse (Printf.sprintf "revision: %d" revision)))))

let request_id, _ = Request_id.Allocator.fresh Request_id.Allocator.empty

module Config = Config_layer.Make (Tracker_registry)

let config registry revision token active terminal =
  let file =
    checked
      (Workflow_path.resolve
         ~base:(checked (Absolute_path.parse "/fixture/workflows"))
         "WORKFLOW.md")
  in
  let source =
    Printf.sprintf
      "---\n\
       tracker:\n\
      \  kind: binding-fixture\n\
      \  active_states: [%s]\n\
      \  terminal_states: [%s]\n\
      \  provider: {revision: %d}\n\
       ---\n"
      (String.concat ", " active)
      (String.concat ", " terminal)
      revision
  in
  let document =
    match Workflow_document.parse ~file source with
    | Ok document -> document
    | Error
        ( Workflow_document.Parse_error diagnostic
        | Workflow_document.Front_matter_not_map diagnostic ) ->
        Alcotest.fail (Diagnostic.render diagnostic)
  in
  match Config.resolve registry ~env:(env token) ~document with
  | Ok config -> config
  | Error (Config_layer.Fields errors) ->
      Alcotest.fail
        (String.concat "\n"
           (List.map Diagnostic.render (Nonempty_list.to_list errors)))
  | Error (Config_layer.Tracker error) ->
      Alcotest.fail (Diagnostic.render (Tracker_error.diagnostic error))
  | Error (Config_layer.Workflow _) -> Alcotest.fail "parsed workflow failed"

let policy config = Tracker_read_policy.of_scheduling (Config.scheduling config)

let default_policy registry =
  policy (config registry 0 "fixture-a" [ "Todo" ] [ "Done" ])

let states binding policy names =
  Tracker_registry.execute
    (Tracker_registry.Contract.States
       { id = request_id; binding; policy; names })

let frozen_context () =
  let old_io = io [ issue "Todo" "old" ]
  and new_io = io [ issue "Doing" "new" ] in
  let old_registry = registry old_io and new_registry = registry new_io in
  let old_config = config old_registry 1 "fixture-a" [ "Todo" ] [ "Done" ] in
  let new_config = config new_registry 2 "fixture-b" [ "Doing" ] [ "Closed" ] in
  let prior = Config.initial old_config in
  let next = Config.apply prior (Ok new_config) in
  let old = Config.tracker (Config.effective prior) in
  let current = Config.tracker (Config.effective next) in
  let old_policy = policy old_config and current_policy = policy new_config in
  let old_result = tracker_checked (states old old_policy [ "Todo" ]) in
  let current_result =
    tracker_checked (states current current_policy [ "Doing" ])
  in
  Alcotest.(check (list string))
    "old snapshot" [ "old" ]
    (List.map
       (fun (id, _) -> Issue_id.text id)
       (Issue_id.Map.bindings old_result));
  Alcotest.(check (list string))
    "new snapshot" [ "new" ]
    (List.map
       (fun (id, _) -> Issue_id.text id)
       (Issue_id.Map.bindings current_result));
  let expect io revision token terminal names =
    match !(io.Provider.calls) with
    | [ Provider.States (settings, policy, actual_names) ] ->
        let expected =
          checked (Json.parse (Printf.sprintf {|{"revision":%d}|} revision))
        in
        Alcotest.(check bool)
          "frozen provider tree" true
          (Json.equal expected settings.Provider.provider);
        Alcotest.(check bool)
          "frozen credential" true
          (settings.Provider.credential = Some token);
        Alcotest.(check (list string))
          "request terminal policy" terminal
          (Tracker_read_policy.terminal policy);
        Alcotest.(check (list string)) "request names" names actual_names
    | [] | Provider.Ids _ :: _ | Provider.States _ :: _ ->
        Alcotest.fail "wrong bound adapter trace"
  in
  expect old_io 1 "fixture-a" [ "done" ] [ "Todo" ];
  expect new_io 2 "fixture-b" [ "closed" ] [ "Doing" ];
  Alcotest.(check bool)
    "contexts differ" false
    (Tracker_registry.Contract.equal old current);
  let old_id = checked (Issue_id.parse "old") in
  let refreshed =
    tracker_checked
      (Tracker_registry.execute
         (Tracker_registry.Contract.Ids
            {
              id = request_id;
              binding = old;
              policy = current_policy;
              ids = Issue_id.Set.singleton old_id;
            }))
  in
  Alcotest.(check bool)
    "old ID refresh keeps old IO" true
    (Issue_id.Map.mem old_id refreshed);
  (match !(old_io.Provider.calls) with
  | Provider.Ids (settings, policy, [ "old" ]) :: _ ->
      Alcotest.(check bool)
        "old ID refresh retains old authentication" true
        (settings.Provider.credential = Some "fixture-a");
      Alcotest.(check (list string))
        "old ID refresh uses current terminal policy" [ "closed" ]
        (Tracker_read_policy.terminal policy)
  | [] | Provider.Ids _ :: _ | Provider.States _ :: _ ->
      Alcotest.fail "wrong original binding refresh trace");
  Alcotest.(check int)
    "new context receives no old refresh" 1
    (List.length !(new_io.Provider.calls))

let policy_reload () =
  let io = io [ issue "Todo" "a" ] in
  let table = registry io in
  let first = config table 1 "fixture-a" [ "Todo" ] [ "Done" ] in
  let changed = config table 1 "fixture-a" [ "Todo" ] [ "Closed" ] in
  let original = Config.tracker first in
  Alcotest.(check bool)
    "same authority despite policy change" true
    (Tracker_registry.Contract.equal original (Config.tracker changed));
  Alcotest.(check bool)
    "reload still observes policy change" false
    (Config.equal first changed);
  ignore (tracker_checked (states original (policy changed) [ "Todo" ]));
  match !(io.Provider.calls) with
  | [ Provider.States (settings, policy, _) ] ->
      Alcotest.(check bool)
        "unchanged authentication" true
        (settings.Provider.credential = Some "fixture-a");
      Alcotest.(check (list string))
        "changed policy reaches original adapter" [ "closed" ]
        (Tracker_read_policy.terminal policy)
  | [] | Provider.Ids _ :: _ | Provider.States _ :: _ ->
      Alcotest.fail "wrong policy reload trace"

let ordered_projection () =
  let issues = [ issue "Todo" "z"; issue "Todo" "a" ] in
  let table = registry (io issues) in
  let binding = binding table 0 "fixture-a" in
  let policy = default_policy table in
  let ordered =
    tracker_checked (Tracker_registry.states binding ~policy [ "Todo" ])
  in
  Alcotest.(check (list string))
    "provider order" [ "z"; "a" ]
    (List.map
       (fun issue -> Issue_id.text (Issue.id issue))
       (Issue_batch.ordered ordered));
  let reply = tracker_checked (states binding policy [ "Todo" ]) in
  List.iter
    (fun issue ->
      match Issue_id.Map.find_opt (Issue.id issue) reply with
      | None -> Alcotest.fail "core projection lost issue"
      | Some actual ->
          Alcotest.(check bool)
            "full snapshot" true
            (Json.equal (Issue.to_json issue) (Issue.to_json actual)))
    issues

let empty_reads () =
  let io = io [ issue "Todo" "a" ] in
  let table = registry io in
  let binding = binding table 0 "fixture-a" in
  let policy = default_policy table in
  ignore (tracker_checked (states binding policy []));
  ignore
    (tracker_checked
       (Tracker_registry.execute
          (Tracker_registry.Contract.Ids
             { id = request_id; binding; policy; ids = Issue_id.Set.empty })));
  Alcotest.(check int) "no provider calls" 0 (List.length !(io.Provider.calls))

let error_identity () =
  let error =
    Tracker_error.make Tracker_error.Tracker_rate_limited
      (Fields.diagnostic ~key:"tracker" "fixture rate limit")
  in
  let io = Provider.{ calls = ref []; outcome = Failed error } in
  let table = registry io in
  let binding = binding table 0 "fixture-a" in
  match states binding (default_policy table) [ "Todo" ] with
  | Ok _ -> Alcotest.fail "expected categorized failure"
  | Error actual -> Alcotest.(check bool) "original value" true (actual == error)

let defect_identity () =
  let defect = Sys_error "fixture worker defect" in
  let io = Provider.{ calls = ref []; outcome = Raised defect } in
  let table = registry io in
  let binding = binding table 0 "fixture-a" in
  match states binding (default_policy table) [ "Todo" ] with
  | Ok _ | Error _ -> Alcotest.fail "unexpected defect became a reply"
  | exception actual ->
      Alcotest.(check bool) "original exception" true (actual == defect)

let unique_kind () =
  let io = io [] in
  match
    Tracker_registry.make
      [
        Tracker_registry.Entry ((module Provider), io);
        Tracker_registry.Entry ((module Provider), io);
      ]
  with
  | Ok _ -> Alcotest.fail "duplicate kind was accepted"
  | Error error ->
      Alcotest.(check bool)
        "category" true
        (Tracker_error.category error = Tracker_error.Unsupported_tracker_kind);
      Alcotest.(check int)
        "no provider calls" 0
        (List.length !(io.Provider.calls))

let tests =
  [
    Alcotest.test_case "old binding keeps auth and IO with current read policy"
      `Quick frozen_context;
    Alcotest.test_case "policy reload retains original authority" `Quick
      policy_reload;
    Alcotest.test_case "ordered states project full snapshots" `Quick
      ordered_projection;
    Alcotest.test_case "empty reads perform zero requests" `Quick empty_reads;
    Alcotest.test_case "categorized failure value is preserved" `Quick
      error_identity;
    Alcotest.test_case "worker defect is preserved" `Quick defect_identity;
    Alcotest.test_case "duplicate kinds fail without IO" `Quick unique_kind;
  ]

let properties =
  [
    QCheck2.Test.make
      ~name:"binding equality agrees with frozen-entry settings model"
      ~count:1000
      QCheck2.Gen.(triple (int_range 0 20) (int_range 0 20) (int_range 0 20))
      (fun (a, b, c) ->
        let table = registry (io []) in
        let make revision = binding table revision "fixture-a" in
        let x = make a and y = make b and z = make c in
        let equal = Tracker_registry.Contract.equal in
        equal x x
        && equal x y = (a = b)
        && equal x y = equal y x
        && ((not (equal x y && equal y z)) || equal x z)
        && (not (equal x (binding table a "fixture-b")))
        && not (equal x (binding (registry (io [])) a "fixture-a")));
  ]
