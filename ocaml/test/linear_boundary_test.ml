module Model = Linear_boundary_model

let samples = 2_000

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let node view = checked (Json.of_view view)
let str value = node (Json.String value)
let obj fields = node (Json.Object fields)
let array values = node (Json.Array values)
let null = node Json.Null
let num text = node (Json.Number text)

let json_test =
  Alcotest.testable
    (fun fmt value -> Format.pp_print_string fmt (Json.encode value))
    Json.equal

let contains text fragment =
  let length = String.length fragment in
  let limit = String.length text - length in
  let rec loop offset =
    offset <= limit
    && (String.sub text offset length = fragment || loop (offset + 1))
  in
  loop 0

let body = function
  | Model.Invalid_json -> "{provider-secret"
  | Model.Valid (errors, data) ->
      let errors =
        match errors with
        | Model.No_errors -> "\"errors\":[]"
        | Model.Ordinary_errors ->
            "\"errors\":[{\"message\":\"provider-secret\"}]"
        | Model.Rate_errors ->
            "\"errors\":[{\"message\":\"provider-secret\",\"extensions\":{\"code\":\"RATELIMITED\"}}]"
        | Model.Invalid_errors -> "\"errors\":\"provider-secret\""
      in
      let data =
        match data with
        | Model.Object_data -> ",\"data\":{\"marker\":\"accepted\"}"
        | Model.Missing_data -> ""
        | Model.Other_data -> ",\"data\":null"
      in
      "{" ^ errors ^ data ^ "}"

let response_name = function
  | Model.Accepted -> "accepted"
  | Model.Rate -> "rate"
  | Model.Status -> "status"
  | Model.Malformed -> "malformed"

let observed = function
  | Ok _ -> Model.Accepted
  | Error error -> (
      match Tracker_error.category error with
      | Tracker_error.Tracker_rate_limited -> Model.Rate
      | Tracker_error.Tracker_status -> Model.Status
      | Tracker_error.Tracker_response -> Model.Malformed
      | Tracker_error.Unsupported_tracker_kind
      | Tracker_error.Invalid_tracker_config
      | Tracker_error.Missing_tracker_secret
      | Tracker_error.Tracker_request
      | Tracker_error.Tracker_pagination ->
          Alcotest.fail "unexpected response error category")

let check_response status envelope =
  let expected = Model.response ~status envelope in
  let actual = Linear_response.parse ~status ~body:(body envelope) in
  Alcotest.check Alcotest.string (string_of_int status) (response_name expected)
    (response_name (observed actual))

let status_beats_rate () =
  List.iter
    (fun status ->
      check_response status (Model.Valid (Model.Rate_errors, Model.Object_data)))
    [ 401; 403; 500; 503 ]

let envelopes =
  Model.Invalid_json
  :: List.concat_map
       (fun errors ->
         List.map
           (fun data -> Model.Valid (errors, data))
           [ Model.Object_data; Model.Missing_data; Model.Other_data ])
       [
         Model.No_errors;
         Model.Ordinary_errors;
         Model.Rate_errors;
         Model.Invalid_errors;
       ]

let response_table () =
  List.iter
    (fun status -> List.iter (check_response status) envelopes)
    [ 199; 200; 204; 299; 300; 400; 401; 429; 500 ]

let response_redaction () =
  List.iter
    (fun status ->
      List.iter
        (fun envelope ->
          match Linear_response.parse ~status ~body:(body envelope) with
          | Ok _ -> ()
          | Error error ->
              let text = Diagnostic.render (Tracker_error.diagnostic error) in
              Alcotest.check Alcotest.bool "provider text absent" false
                (contains text "provider-secret"))
        envelopes)
    [ 200; 400; 401; 429; 500 ]

let response_shapes () =
  List.iter
    (fun body ->
      match Linear_response.parse ~status:200 ~body with
      | Error _ -> Alcotest.fail "valid no-error envelope rejected"
      | Ok data ->
          Alcotest.check json_test "data object"
            (obj [ ("marker", str "ok") ])
            data)
    [
      "{\"data\":{\"marker\":\"ok\"}}";
      "{\"errors\":null,\"data\":{\"marker\":\"ok\"}}";
    ];
  List.iter
    (fun body ->
      Alcotest.check Alcotest.string "bad successful envelope" "malformed"
        (response_name (observed (Linear_response.parse ~status:200 ~body))))
    [
      "{\"data\":[],\"errors\":[]}";
      "{\"data\":{},\"errors\":[null]}";
      "{\"data\":{},\"data\":{}}";
      "{\"data\":{},\"errors\":[{\"extensions\":{\"code\":\"ratelimited\"}}]}";
    ]

let page ~nodes info = obj [ ("nodes", array nodes); ("pageInfo", obj info) ]
let finished nodes = page ~nodes [ ("hasNextPage", node (Json.Bool false)) ]

let continuing nodes cursor =
  page ~nodes
    [ ("hasNextPage", node (Json.Bool true)); ("endCursor", str cursor) ]

let checked_page json =
  match Linear_page.parse json with
  | Ok value -> value
  | Error error ->
      Alcotest.fail (Diagnostic.render (Tracker_error.diagnostic error))

let cursor text =
  match Linear_page.next (checked_page (continuing [ null ] text)) with
  | Some value -> value
  | None -> Alcotest.fail "continuing page lost cursor"

let pagination_error json =
  match Linear_page.parse json with
  | Ok _ -> Alcotest.fail "malformed page accepted"
  | Error error ->
      Alcotest.check Alcotest.bool "pagination category" true
        (Tracker_error.category error = Tracker_error.Tracker_pagination)

let page_progress () =
  List.iter pagination_error
    [
      obj [];
      obj [ ("nodes", array []) ];
      page ~nodes:[] [ ("hasNextPage", node (Json.Bool true)) ];
      continuing [] "cursor";
      continuing [ null ] "";
      continuing [ null ] " \t ";
      continuing [ null ] "cursor\000secret";
      continuing [ null ] (String.make 4_097 'x');
      page ~nodes:[ null ] [ ("hasNextPage", str "false") ];
    ];
  let maximum = String.make 4_096 'x' in
  Alcotest.check Alcotest.string "bounded exact cursor" maximum
    (Linear_page.cursor_text (cursor maximum));
  let terminal =
    page ~nodes:[]
      [ ("hasNextPage", node (Json.Bool false)); ("endCursor", num "7") ]
    |> checked_page
  in
  Alcotest.check Alcotest.bool "explicit completion" true
    (Option.is_none (Linear_page.next terminal));
  Alcotest.check (Alcotest.list json_test) "empty final page" []
    (Linear_page.nodes terminal)

let cursor_cycles () =
  let a = cursor "a" and b = cursor "b" in
  let advance history value =
    match Linear_page.advance history value with
    | Ok next -> next
    | Error _ -> Alcotest.fail "fresh cursor rejected"
  in
  let history = advance (advance Linear_page.start a) b in
  List.iter
    (fun value ->
      match Linear_page.advance history value with
      | Ok _ -> Alcotest.fail "repeated cursor accepted"
      | Error error ->
          Alcotest.check Alcotest.bool "cycle category" true
            (Tracker_error.category error = Tracker_error.Tracker_pagination))
    [ a; b ];
  Alcotest.check Alcotest.bool "exact cursor equality" false
    (Linear_page.cursor_equal a (cursor " a"));
  ignore (advance history (cursor " a"))

let issue_id = "opaque:id"

let base_fields =
  [
    ("id", str issue_id);
    ("identifier", str "LIN-1");
    ("title", str "Boundary issue");
    ("state", obj [ ("name", str "Todo") ]);
  ]

let record fields =
  obj
    (List.fold_left
       (fun found (key, value) -> (key, value) :: List.remove_assoc key found)
       base_fields fields)

let completeness = function
  | Model.Complete -> Linear_record.Complete
  | Model.Incomplete -> Linear_record.Incomplete

let parse_record ?(labels = []) ?(relations = []) ?(evidence = Model.Complete)
    json =
  Linear_record.parse ~terminal:[ "Done"; "Canceled" ] ~labels ~relations
    ~completeness:(completeness evidence) json

let checked_record ?labels ?relations ?evidence json =
  match parse_record ?labels ?relations ?evidence json with
  | Ok issue -> issue
  | Error omission ->
      Alcotest.fail (Diagnostic.render (Linear_omission.diagnostic omission))

let expected fields =
  let defaults =
    [
      ("id", str issue_id);
      ("identifier", str "LIN-1");
      ("title", str "Boundary issue");
      ("description", null);
      ("priority", null);
      ("state", str "Todo");
      ("branch_name", null);
      ("url", null);
      ("assignee_id", null);
      ("labels", array []);
      ("blocked_by", array []);
      ("created_at", null);
      ("updated_at", null);
      ("dispatchable", node (Json.Bool true));
      ("native_ref", obj [ ("issue_id", str issue_id) ]);
    ]
  in
  obj
    (List.fold_left
       (fun found (key, value) -> (key, value) :: List.remove_assoc key found)
       defaults fields)

let optional_fallback () =
  let issue =
    checked_record
      (record
         [
           ("description", node (Json.Bool true));
           ("priority", num "1.25");
           ("branchName", str "");
           ("url", str "bad\000url");
           ("assignee", array []);
           ("createdAt", str "bad-date");
           ("updatedAt", num "42");
           ("project", obj [ ("id", str ""); ("slugId", str " ") ]);
         ])
  in
  Alcotest.check json_test "full fallback snapshot"
    (expected [ ("branch_name", str "") ])
    (Issue.to_json issue)

let native_allowlist () =
  let issue =
    checked_record
      (record
         [
           ("description", str "");
           ("assignee", obj [ ("id", str "") ]);
           ("url", str "https://fixture.invalid/1");
           ("secret", str "provider-secret");
           ("native_ref", obj [ ("secret", str "provider-secret") ]);
           ( "project",
             obj
               [
                 ("id", str "project:opaque");
                 ("slugId", str "a-project");
                 ("secret", str "provider-secret");
               ] );
         ])
  in
  Alcotest.check json_test "only constructed identities"
    (expected
       [
         ("description", str "");
         ("assignee_id", str "");
         ("url", str "https://fixture.invalid/1");
         ( "native_ref",
           obj
             [
               ("issue_id", str issue_id);
               ("project_id", str "project:opaque");
               ("project_slug", str "a-project");
             ] );
       ])
    (Issue.to_json issue)

let required_failures () =
  List.iter
    (fun key ->
      let json = obj (List.remove_assoc key base_fields) in
      match parse_record json with
      | Ok _ -> Alcotest.fail ("missing " ^ key ^ " accepted")
      | Error omission ->
          let field =
            match key with
            | "id" -> Linear_omission.Id
            | "identifier" -> Linear_omission.Identifier
            | "title" -> Linear_omission.Title
            | "state" -> Linear_omission.State
            | _ -> Alcotest.fail "unknown required fixture key"
          in
          Alcotest.check Alcotest.bool "typed missing field" true
            (Linear_omission.reason omission
            = Linear_omission.Missing_field field))
    [ "id"; "identifier"; "title"; "state" ];
  List.iter
    (fun (key, value) ->
      let json =
        record [ (key, value); ("description", str "provider-secret") ]
      in
      match parse_record json with
      | Ok _ -> Alcotest.fail ("invalid " ^ key ^ " accepted")
      | Error omission ->
          let text = Diagnostic.render (Linear_omission.diagnostic omission) in
          Alcotest.check Alcotest.bool "bounded omission" true
            (String.length text <= 4_096);
          Alcotest.check Alcotest.bool "unused provider text absent" false
            (contains text "provider-secret"))
    [
      ("id", str " ");
      ("identifier", null);
      ("title", str "bad\000title");
      ("state", obj [ ("name", num "1") ]);
    ]

let relation = function
  | Model.Other -> obj [ ("type", str "related") ]
  | Model.Unknown -> obj [ ("type", str "blocks") ]
  | Model.Blocks { source; target; state } ->
      let state =
        match state with
        | None -> null
        | Some name -> obj [ ("name", str name) ]
      in
      obj
        [
          ("type", str "blocks");
          ( "issue",
            obj
              [
                ("id", str source); ("identifier", str "LIN-2"); ("state", state);
              ] );
          ("relatedIssue", obj [ ("id", str target) ]);
        ]

let routing_matches state evidence blockers =
  let expected =
    Model.dispatchable ~id:issue_id ~state ~terminal:[ "Done"; "Canceled" ]
      evidence blockers
  in
  let issue =
    checked_record ~evidence
      ~relations:(List.map relation blockers)
      (record [ ("state", obj [ ("name", str state) ]) ])
  in
  let actual =
    match Issue.routing issue with
    | Issue.Dispatchable -> true
    | Issue.Unroutable -> false
  in
  expected = actual

let routing_table () =
  let blocks source target state = Model.Blocks { source; target; state } in
  let alternatives =
    [
      [];
      [ Model.Other ];
      [ Model.Unknown ];
      [ blocks "blocker" issue_id (Some "Done") ];
      [ blocks "blocker" issue_id (Some "Todo") ];
      [ blocks "blocker" issue_id None ];
      [ blocks issue_id issue_id (Some "Done") ];
      [ blocks issue_id "blocker" (Some "Done") ];
      [ blocks "blocker" "foreign" (Some "Done") ];
      [ blocks "blocker" issue_id (Some "Done"); Model.Unknown ];
    ]
  in
  List.iter
    (fun state ->
      List.iter
        (fun evidence ->
          List.iter
            (fun blockers ->
              Alcotest.check Alcotest.bool "independent routing truth" true
                (routing_matches state evidence blockers))
            alternatives)
        [ Model.Complete; Model.Incomplete ])
    [ "Todo"; " TODO "; "In Progress" ]

let label_fallback () =
  let labels =
    [
      obj [ ("name", str " Bug ") ];
      null;
      obj [ ("name", num "7") ];
      obj [ ("name", str "BUG") ];
      obj [ ("name", str " ") ];
      obj [ ("name", str "urgent") ];
      obj [ ("name", str "bad\000label") ];
    ]
  in
  let issue = checked_record ~labels (record []) in
  Alcotest.check json_test "normalized labels and all output keys"
    (expected [ ("labels", array [ str "bug"; str "urgent" ]) ])
    (Issue.to_json issue)

let priority_value text =
  let json = num text in
  let issue = checked_record (record [ ("priority", json) ]) in
  (Json.to_int json, Issue.priority issue)

let exact_priorities () =
  let huge = String.make 2_000 '9' in
  let above = Z.to_string (Z.succ (Z.of_int max_int)) in
  let below = Z.to_string (Z.pred (Z.of_int min_int)) in
  List.iter
    (fun (text, expected) ->
      let json, issue = priority_value text in
      Alcotest.check (Alcotest.option Alcotest.int) text expected json;
      Alcotest.check
        (Alcotest.option Alcotest.int)
        ("priority " ^ text) expected issue)
    [
      ("1", Some 1);
      ("1.0", Some 1);
      ("1e0", Some 1);
      ("1.00000", Some 1);
      ("100.00e-2", Some 1);
      ("0.00010e4", Some 1);
      ("1.25", None);
      ("1.0001", None);
      ("-0", Some 0);
      ("-0.000e-" ^ huge, Some 0);
      ("0e" ^ huge, Some 0);
      ("1e" ^ huge, None);
      ("1e-" ^ huge, None);
      (string_of_int min_int, Some min_int);
      (string_of_int max_int ^ ".0", Some max_int);
      (above, None);
      (below, None);
    ];
  let issue = checked_record (record [ ("priority", str "1") ]) in
  Alcotest.check
    (Alcotest.option Alcotest.int)
    "strings are not numbers" None (Issue.priority issue)

let optional_times () =
  let issue =
    checked_record
      (record
         [
           ("createdAt", str "2026-10-01T01:00:00+01:00");
           ("updatedAt", str "2026-10-01T00:00:00Z");
         ])
  in
  Alcotest.check json_test "normalized exact UTC metadata"
    (expected
       [
         ("created_at", str "2026-10-01T00:00:00.000000000000Z");
         ("updated_at", str "2026-10-01T00:00:00.000000000000Z");
       ])
    (Issue.to_json issue)

let history_matches cursors =
  let rec loop expected actual = function
    | [] -> true
    | text :: rest -> (
        let expected = Model.advance expected text in
        let actual = Linear_page.advance actual (cursor text) in
        match (expected, actual) with
        | None, Error error ->
            Tracker_error.category error = Tracker_error.Tracker_pagination
        | Some expected, Ok actual -> loop expected actual rest
        | None, Ok _ | Some _, Error _ -> false)
  in
  loop Model.start Linear_page.start cursors

let page_order pages =
  let expected = Model.ordered pages in
  let actual =
    List.concat_map
      (fun items ->
        Linear_page.nodes (checked_page (finished (List.map str items))))
      pages
  in
  List.equal Json.equal (List.map str expected) actual

let decimal_projection decimal =
  let expected = Model.integer decimal in
  let json, issue = priority_value (Model.lexeme decimal) in
  expected = json && expected = issue

let labels_match labels =
  let normalized = Model.labels labels in
  let issue texts =
    checked_record
      ~labels:(List.map (fun name -> obj [ ("name", str name) ]) texts)
      (record [])
  in
  let first = issue labels and second = issue normalized in
  Issue.labels first = normalized
  && Json.equal (Issue.to_json first) (Issue.to_json second)

let print_labels labels =
  let expected = Model.labels labels in
  let issue =
    checked_record
      ~labels:(List.map (fun name -> obj [ ("name", str name) ]) labels)
      (record [])
  in
  let texts values = Json.encode (array (List.map str values)) in
  Printf.sprintf "input=%s expected=%s observed=%s" (texts labels)
    (texts expected)
    (texts (Issue.labels issue))

let unused_fields text =
  let before = checked_record (record []) in
  let after =
    checked_record
      (record
         [
           ("unknownProviderField", str text);
           ("native_ref", obj [ ("secret", str text) ]);
         ])
  in
  Json.equal (Issue.to_json before) (Issue.to_json after)

type json_shape = Leaf | Repeated | Nested

let sizing_fixture (texts, count, shape) =
  let child = array (List.map str texts) in
  let repeated = array (List.init count (fun _ -> child)) in
  match shape with
  | Leaf -> child
  | Repeated -> repeated
  | Nested ->
      obj
        [
          ("quote\"\\\n\000\127é", repeated);
          ("number", num "100.00e-2");
          ("bool", node (Json.Bool true));
          ("null", null);
        ]

let json_size_matches value =
  let text = Json.encode value in
  let parsed = checked (Json.parse text) in
  Json.encoded_bytes value = String.length text
  && Json.encoded_bytes parsed = String.length (Json.encode parsed)

let json_sizes () =
  let controls = String.init 32 Char.chr in
  List.iter
    (fun shape ->
      Alcotest.check Alcotest.bool "exact encoded size" true
        (json_size_matches
           (sizing_fixture ([ controls; "\127"; "é😊"; "\"\\" ], 3, shape))))
    [ Leaf; Repeated; Nested ]

let json_size_gen =
  QCheck2.Gen.(
    map sizing_fixture
      (triple
         (list_size (int_range 0 20)
            (oneof_list [ ""; "\000\001\n\t"; "\127"; "é😊"; "\"\\"; "abc" ]))
         (int_range 0 10)
         (oneof_list [ Leaf; Repeated; Nested ])))

let decimal_gen =
  QCheck2.Gen.(
    map
      (fun (mantissa, scale, exponent) ->
        match Model.decimal ~mantissa ~scale ~exponent with
        | Some value -> value
        | None -> Alcotest.fail "decimal generator escaped its declared corpus")
      (triple
         (int_range (-1_000_000) 1_000_000)
         (int_range 0 6) (int_range (-25) 25)))

let blocker_gen =
  QCheck2.Gen.(
    oneof
      [
        return Model.Other;
        return Model.Unknown;
        map
          (fun (source, target, state) ->
            Model.Blocks { source; target; state })
          (triple
             (oneof_list [ "blocker"; issue_id ])
             (oneof_list [ issue_id; "foreign" ])
             (oneof_list [ None; Some "Done"; Some "Canceled"; Some "Todo" ]));
      ])

let tests =
  [
    Alcotest.test_case "HTTP status beats provider rate code" `Quick
      status_beats_rate;
    Alcotest.test_case "response precedence and error absorption" `Quick
      response_table;
    Alcotest.test_case "response diagnostics redact provider text" `Quick
      response_redaction;
    Alcotest.test_case "response envelope shapes" `Quick response_shapes;
    Alcotest.test_case "page completion and bounded progress" `Quick
      page_progress;
    Alcotest.test_case "cursor cycles and exact identity" `Quick cursor_cycles;
    Alcotest.test_case "optional fallback preserves full snapshot" `Quick
      optional_fallback;
    Alcotest.test_case "native references contain only allowed identities"
      `Quick native_allowlist;
    Alcotest.test_case "required fields reject with bounded diagnostics" `Quick
      required_failures;
    Alcotest.test_case "Todo requires complete incoming blocker evidence" `Quick
      routing_table;
    Alcotest.test_case "labels normalize with malformed-node fallback" `Quick
      label_fallback;
    Alcotest.test_case "priorities use exact bounded integer semantics" `Quick
      exact_priorities;
    Alcotest.test_case "optional timestamps normalize exact UTC" `Quick
      optional_times;
    Alcotest.test_case "encoded byte counts match actual JSON serialization"
      `Quick json_sizes;
  ]

let properties =
  [
    QCheck2.Test.make ~name:"Linear response agrees with finite envelope model"
      ~count:samples
      QCheck2.Gen.(pair (int_range 100 599) (oneof_list envelopes))
      (fun (status, envelope) ->
        Model.response ~status envelope
        = observed (Linear_response.parse ~status ~body:(body envelope)));
    QCheck2.Test.make ~name:"Linear cursor history agrees with list membership"
      ~count:samples
      QCheck2.Gen.(
        list_size (int_range 0 30) (map string_of_int (int_range 0 8)))
      history_matches;
    QCheck2.Test.make ~name:"Linear pages preserve ordered partitions"
      ~count:samples
      QCheck2.Gen.(
        list_size (int_range 0 8)
          (list_size (int_range 0 8) (map string_of_int (int_range 0 20))))
      page_order;
    QCheck2.Test.make ~name:"Linear priority agrees with exact rational model"
      ~count:samples decimal_gen decimal_projection;
    QCheck2.Test.make ~name:"Linear routing agrees with complete-evidence truth"
      ~count:samples
      QCheck2.Gen.(
        triple
          (oneof_list [ "Todo"; " todo "; "In Progress"; "Done" ])
          (oneof_list [ Model.Complete; Model.Incomplete ])
          (list_size (int_range 0 8) blocker_gen))
      (fun (state, evidence, blockers) ->
        routing_matches state evidence blockers);
    QCheck2.Test.make
      ~name:"Linear labels agree with idempotent list normalizer" ~count:samples
      ~print:print_labels
      QCheck2.Gen.(
        list_size (int_range 0 30)
          (oneof_list [ " Bug "; "BUG"; "urgent"; " "; "x"; "X" ]))
      labels_match;
    QCheck2.Test.make
      ~name:"Linear unused provider fields cannot change snapshot"
      ~count:samples
      QCheck2.Gen.(
        map (String.concat "")
          (list_size (int_range 0 30)
             (oneof_list [ "a"; "é"; "\000"; "\027"; " " ])))
      unused_fields;
    QCheck2.Test.make ~name:"JSON byte count agrees with actual serializer"
      ~count:samples json_size_gen json_size_matches;
  ]
