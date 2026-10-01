module Model = Issue_batch_model

let samples = 2_000
let maximum_items = 30

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let issue id identifier snapshot =
  let text = string_of_int snapshot in
  let blocked_by : Issue.blocker list =
    [
      {
        Issue.id = Some (checked (Issue_id.parse ("blocker:" ^ text)));
        identifier = Some (checked (Issue_identifier.parse ("BLOCK-" ^ text)));
        state = Some "Done";
      };
    ]
  in
  let native_ref =
    checked
      (Json.of_view
         (Json.Object [ ("fixture", checked (Json.of_view (Json.Number text))) ]))
  in
  let input : Issue.input =
    {
      Issue.id;
      identifier;
      title = "Snapshot " ^ text;
      description = Some ("Details " ^ text);
      priority = Some (string_of_int (snapshot mod 5));
      state = (if snapshot mod 2 = 0 then "Todo" else "In Progress");
      branch_name = Some ("branch-" ^ text);
      url = Some ("https://fixture.invalid/issues/" ^ text);
      assignee_id = Some ("person-" ^ text);
      labels = [ " LABEL " ^ text; "fixture" ];
      blocked_by;
      created_at = Some "2026-10-01T00:00:00Z";
      updated_at =
        Some (Printf.sprintf "2026-10-01T00:00:%02dZ" (snapshot mod 60));
      dispatchable =
        (if snapshot mod 2 = 0 then Issue.Dispatchable else Issue.Unroutable);
      native_ref = Some native_ref;
    }
  in
  checked (Issue.parse input)

let equal_issue left right =
  Json.equal (Issue.to_json left) (Issue.to_json right)

let equal_issues = List.equal equal_issue

let equal_error left right =
  match (left, right) with
  | Issue_batch.Duplicate_id left, Issue_batch.Duplicate_id right ->
      Issue_id.equal left right
  | ( Issue_batch.Duplicate_identifier left,
      Issue_batch.Duplicate_identifier right ) ->
      Issue_identifier.equal left right
  | Issue_batch.Duplicate_id _, Issue_batch.Duplicate_identifier _
  | Issue_batch.Duplicate_identifier _, Issue_batch.Duplicate_id _ -> false

let model_error = function
  | Model.Duplicate_id id -> Issue_batch.Duplicate_id id
  | Model.Duplicate_identifier identifier ->
      Issue_batch.Duplicate_identifier identifier

let batch issues =
  match Issue_batch.of_list issues with
  | Ok batch -> batch
  | Error _ -> Alcotest.fail "unique fixture batch rejected"

let expect_error expected issues =
  match Issue_batch.of_list issues with
  | Ok _ -> Alcotest.fail "duplicate fixture batch accepted"
  | Error actual ->
      Alcotest.(check bool)
        "typed duplicate key" true
        (equal_error actual expected)

let absent_id = checked (Issue_id.parse "absent-query")

let map_agrees issues actual =
  let map = Issue_batch.by_id actual in
  let queries = absent_id :: List.map Issue.id issues in
  Issue_id.Map.cardinal map = List.length issues
  && List.for_all
       (fun id ->
         match (Issue_id.Map.find_opt id map, Model.find id issues) with
         | None, None -> true
         | Some actual, Some expected -> equal_issue actual expected
         | None, Some _ | Some _, None -> false)
       queries

let empty () =
  List.iter
    (fun value ->
      Alcotest.(check bool)
        "empty order" true
        (equal_issues [] (Issue_batch.ordered value));
      Alcotest.(check int)
        "empty map" 0
        (Issue_id.Map.cardinal (Issue_batch.by_id value)))
    [ Issue_batch.empty; batch [] ]

let snapshot_order () =
  let issues = [ issue "opaque-z" "SYM-2" 7; issue "opaque-a" "SYM-1" 4 ] in
  let actual = batch issues in
  Alcotest.(check bool)
    "ordered complete snapshots" true
    (equal_issues issues (Issue_batch.ordered actual));
  Alcotest.(check bool) "map complete snapshots" true (map_agrees issues actual);
  Alcotest.(check (list string))
    "map traversal uses named ID order" [ "opaque-a"; "opaque-z" ]
    (List.map
       (fun (id, _issue) -> Issue_id.text id)
       (Issue_id.Map.bindings (Issue_batch.by_id actual)))

let duplicate_id () =
  let first = issue "opaque-a" "SYM-1" 0 in
  let changed = issue "opaque-a" "SYM-2" 1 in
  expect_error (Issue_batch.Duplicate_id (Issue.id first)) [ first; changed ]

let duplicate_identifier () =
  let first = issue "opaque-a" "SYM-1" 0 in
  let changed = issue "opaque-b" "SYM-1" 1 in
  expect_error
    (Issue_batch.Duplicate_identifier (Issue.identifier first))
    [ first; changed ]

let both_collide () =
  let first = issue "opaque-a" "SYM-1" 0 in
  expect_error (Issue_batch.Duplicate_id (Issue.id first)) [ first; first ]

let first_collision () =
  let first = issue "opaque-a" "SYM-1" 0 in
  let other = issue "opaque-b" "SYM-1" 1 in
  let expected = Issue_batch.Duplicate_identifier (Issue.identifier first) in
  expect_error expected [ first; other ];
  expect_error expected [ first; other; first; first ]

let byte_identities () =
  let issues =
    [
      issue "opaque" "SYM-1" 0;
      issue "Opaque" "sym-1" 1;
      issue " opaque" "SYM-1 " 2;
      issue "é" "é" 3;
      issue "é" "é" 4;
    ]
  in
  Alcotest.(check bool)
    "byte-distinct identities remain distinct" true
    (equal_issues issues (Issue_batch.ordered (batch issues)))

let page_collision () =
  let first = issue "opaque-a" "SYM-1" 0 in
  let last = issue "opaque-a" "SYM-2" 1 in
  expect_error
    (Issue_batch.Duplicate_id (Issue.id first))
    (List.concat [ [ first ]; []; [ last ] ])

let issue_generator =
  QCheck2.Gen.(
    map
      (fun (id, (identifier, snapshot)) -> issue id identifier snapshot)
      (pair
         (oneof_list [ "opaque"; "Opaque"; " opaque"; "é"; "é" ])
         (pair
            (oneof_list [ "SYM-1"; "sym-1"; "SYM-1 "; "é"; "é" ])
            (int_range 0 99))))

let any_generator =
  QCheck2.Gen.(list_size (int_range 0 maximum_items) issue_generator)

let unique_generator =
  QCheck2.Gen.(
    map
      (List.mapi (fun index snapshot ->
           let text = string_of_int index in
           issue ("opaque:" ^ text) ("SYM-" ^ text) snapshot))
      (list_size (int_range 0 maximum_items) (int_range 0 99)))

let constructor_agrees issues =
  match (Issue_batch.of_list issues, Model.of_list issues) with
  | Ok actual, Ok expected ->
      equal_issues (Issue_batch.ordered actual) expected
      && map_agrees expected actual
  | Error actual, Error expected -> equal_error actual (model_error expected)
  | Ok _, Error _ | Error _, Ok _ -> false

let preserves_snapshots issues =
  match Issue_batch.of_list issues with
  | Error _ -> false
  | Ok actual -> equal_issues issues (Issue_batch.ordered actual)

let lookup_agrees issues =
  match Issue_batch.of_list issues with
  | Error _ -> false
  | Ok actual -> map_agrees issues actual

let reconstructs issues =
  match Issue_batch.of_list issues with
  | Error _ -> false
  | Ok original -> (
      match Issue_batch.of_list (Issue_batch.ordered original) with
      | Error _ -> false
      | Ok reconstructed ->
          equal_issues
            (Issue_batch.ordered original)
            (Issue_batch.ordered reconstructed)
          && map_agrees issues reconstructed)

let suffix_absorbed (prefix, suffix) =
  match Issue_batch.of_list prefix with
  | Ok _ -> true
  | Error expected -> (
      match Issue_batch.of_list (prefix @ suffix) with
      | Ok _ -> false
      | Error actual -> equal_error actual expected)

let tests =
  [
    Alcotest.test_case "empty batch has empty projections" `Quick empty;
    Alcotest.test_case "provider order and full snapshots survive indexing"
      `Quick snapshot_order;
    Alcotest.test_case "duplicate IDs never overwrite snapshots" `Quick
      duplicate_id;
    Alcotest.test_case "conflicting identifiers are rejected" `Quick
      duplicate_identifier;
    Alcotest.test_case "ID wins a collision in both identities" `Quick
      both_collide;
    Alcotest.test_case "first collision absorbs later input" `Quick
      first_collision;
    Alcotest.test_case "identity equality preserves exact bytes" `Quick
      byte_identities;
    Alcotest.test_case "duplicate across pages fails whole batch" `Quick
      page_collision;
  ]

let properties =
  [
    QCheck2.Test.make ~name:"issue batch agrees with prefix-list model"
      ~count:samples any_generator constructor_agrees;
    QCheck2.Test.make ~name:"issue batch preserves ordered full snapshots"
      ~count:samples unique_generator preserves_snapshots;
    QCheck2.Test.make ~name:"issue batch map agrees with list lookup"
      ~count:samples unique_generator lookup_agrees;
    QCheck2.Test.make ~name:"issue batch reconstruction is a retraction"
      ~count:samples unique_generator reconstructs;
    QCheck2.Test.make ~name:"first batch collision absorbs arbitrary suffix"
      ~count:samples
      QCheck2.Gen.(pair any_generator any_generator)
      suffix_absorbed;
  ]
