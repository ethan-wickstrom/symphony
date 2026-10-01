module Model = Linear_pager_model

let samples = 500
let project = "sample"
let success_status = 200
let maximum_posts = 1_000
let maximum_nodes = 200_000
let maximum_issues = 10_000
let maximum_bytes = 16_777_216
let page_size = 50

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let node view = checked (Json.of_view view)
let str value = node (Json.String value)
let obj fields = node (Json.Object fields)
let array values = node (Json.Array values)
let null = node Json.Null

let json_test =
  Alcotest.testable
    (fun fmt value -> Format.pp_print_string fmt (Json.encode value))
    Json.equal

let field name json =
  match Json.view json with
  | Json.Object fields -> List.assoc_opt name fields
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      None

let text_field name json =
  match Option.map Json.view (field name json) with
  | Some (Json.String text) -> text
  | None
  | Some (Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _)
    -> Alcotest.fail ("missing string request field " ^ name)

let contains text fragment =
  let length = String.length fragment in
  let limit = String.length text - length in
  let rec loop offset =
    offset <= limit
    && (String.sub text offset length = fragment || loop (offset + 1))
  in
  loop 0

let compact text =
  String.to_seq text
  |> Seq.filter (function
    | ' ' | '\n' | '\r' | '\t' -> false
    | _ -> true)
  |> String.of_seq

let operation_name = function
  | Model.Issues -> "SymphonyIssues"
  | Model.Labels -> "SymphonyLabels"
  | Model.Relations -> "SymphonyRelations"

let dynamic_values = function
  | Model.Issues_page { selection; after } ->
      let values =
        match selection with
        | Model.States names | Model.Ids names -> names
      in
      (project :: Option.to_list after) @ values
  | Model.Labels_page { id; after } | Model.Relations_page { id; after } ->
      project :: id :: Option.to_list after

type answer =
  | Reply of Http_transport.response
  | Reject of Diagnostic.t
  | Crash of exn

type step = { request : Model.request; answer : answer }
type fake = { mutable remaining : step list; mutable seen : Json.t list }

let scripted steps = { remaining = steps; seen = [] }
let calls fake = List.length fake.seen

let verify_request previous request body =
  let name = operation_name (Model.operation request) in
  Alcotest.check Alcotest.string "operationName" name
    (text_field "operationName" body);
  let query = text_field "query" body in
  let query_text = compact query in
  Alcotest.check Alcotest.bool "named query" true
    (String.starts_with ~prefix:("query" ^ name ^ "(") query_text);
  Alcotest.check Alcotest.bool "explicit bounded connection request" true
    (contains query_text "first:$pageSize" && contains query_text "after:$after");
  (match Model.operation request with
  | Model.Issues ->
      Alcotest.check Alcotest.bool "outer query options" true
        (contains query_text "includeArchived:false"
        && contains query_text "orderBy:createdAt"
        && contains query_text "filter:$filter")
  | Model.Labels | Model.Relations ->
      Alcotest.check Alcotest.bool "nested issue lookup" true
        (contains query_text "issue(id:$id)"));
  List.iter
    (fun value ->
      Alcotest.check Alcotest.bool "dynamic value stays in variables" false
        (contains query (Json.encode (str value))))
    (dynamic_values request);
  List.iter
    (fun earlier ->
      if text_field "operationName" earlier = name then
        Alcotest.check Alcotest.string "constant document"
          (text_field "query" earlier)
          query)
    previous;
  let variables =
    match field "variables" body with
    | Some value -> value
    | None -> Alcotest.fail "missing GraphQL variables"
  in
  Alcotest.check json_test "exact variables"
    (Model.variables ~project request)
    variables

let post fake body =
  match fake.remaining with
  | [] -> Alcotest.fail "unexpected post after script ended"
  | step :: rest -> (
      verify_request fake.seen step.request body;
      fake.remaining <- rest;
      fake.seen <- body :: fake.seen;
      match step.answer with
      | Reply response -> Ok response
      | Reject error -> Error error
      | Crash defect -> raise defect)

let diagnostic =
  Diagnostic.make ~site:(Diagnostic.Host "fake.linear")
    ~message:"fixture transport failure" ~remedy:"replace the scripted response"

let connection nodes next =
  let page_info =
    match next with
    | None ->
        obj [ ("hasNextPage", node (Json.Bool false)); ("endCursor", null) ]
    | Some cursor ->
        obj
          [ ("hasNextPage", node (Json.Bool true)); ("endCursor", str cursor) ]
  in
  obj [ ("nodes", array nodes); ("pageInfo", page_info) ]

let entry number =
  {
    Model.id = Printf.sprintf "opaque:%03d" number;
    identifier = Printf.sprintf "LIN-%03d" number;
    state = "Todo";
    project;
  }

let raw_issue ?(labels = connection [] None) ?(relations = connection [] None)
    entry =
  obj
    [
      ("id", str entry.Model.id);
      ("identifier", str entry.Model.identifier);
      ("title", str ("Title " ^ entry.Model.identifier));
      ("description", str ("Details " ^ entry.Model.id));
      ("state", obj [ ("name", str entry.Model.state) ]);
      ( "project",
        obj [ ("id", str "project-id"); ("slugId", str entry.Model.project) ] );
      ("labels", labels);
      ("inverseRelations", relations);
    ]

let envelope data = obj [ ("data", data) ]

let response body =
  Reply { Http_transport.status = success_status; body = Json.encode body }

let outer nodes next =
  response (envelope (obj [ ("issues", connection nodes next) ]))

let nested entry name nodes next =
  response
    (envelope
       (obj
          [
            ( "issue",
              obj
                [
                  ("id", str entry.Model.id);
                  ("project", obj [ ("slugId", str entry.Model.project) ]);
                  (name, connection nodes next);
                ] );
          ]))

let issue_request selection after = Model.Issues_page { selection; after }
let step request answer = { request; answer }

let read ?(omitted = fun _ -> Ok ()) fake selection =
  let selection =
    match selection with
    | Model.States names -> Linear_pager.States names
    | Model.Ids names ->
        Linear_pager.Ids
          (List.fold_left
             (fun found id ->
               Issue_id.Set.add (checked (Issue_id.parse id)) found)
             Issue_id.Set.empty names)
  in
  Linear_pager.read ~post:(post fake) ~project ~terminal:[ "Done"; "Canceled" ]
    ~omitted selection

let succeeded fake result =
  match result with
  | Error error ->
      Alcotest.fail (Diagnostic.render (Tracker_error.diagnostic error))
  | Ok batch ->
      Alcotest.check Alcotest.int "whole script consumed" 0
        (List.length fake.remaining);
      Issue_batch.ordered batch

let failed category result =
  match result with
  | Ok _ -> Alcotest.fail "partial batch escaped failure"
  | Error error ->
      Alcotest.check Alcotest.bool "categorized atomic failure" true
        (Tracker_error.category error = category)

let ids issues = List.map (fun issue -> Issue_id.text (Issue.id issue)) issues

let outer_steps selection pages =
  let pages =
    match pages with
    | [] -> [ [] ]
    | _ :: _ -> pages
  in
  let rec loop index previous = function
    | [] -> []
    | nodes :: rest ->
        let next =
          match rest with
          | [] -> None
          | _ :: _ -> Some ("page:" ^ string_of_int index)
        in
        step (issue_request selection previous) (outer nodes next)
        :: loop (index + 1) next rest
  in
  loop 0 None pages

let empty_reads () =
  List.iter
    (fun selection ->
      let fake = scripted [] in
      let issues = succeeded fake (read fake selection) in
      Alcotest.check Alcotest.int "zero requests" 0 (calls fake);
      Alcotest.check Alcotest.int "empty result" 0 (List.length issues))
    [ Model.States []; Model.Ids [] ]

let snapshot entry =
  obj
    [
      ("id", str entry.Model.id);
      ("identifier", str entry.Model.identifier);
      ("title", str ("Title " ^ entry.Model.identifier));
      ("description", str ("Details " ^ entry.Model.id));
      ("priority", null);
      ("state", str entry.Model.state);
      ("branch_name", null);
      ("url", null);
      ("assignee_id", null);
      ("labels", array []);
      ("blocked_by", array []);
      ("created_at", null);
      ("updated_at", null);
      ("dispatchable", node (Json.Bool true));
      ( "native_ref",
        obj
          [
            ("issue_id", str entry.Model.id);
            ("project_id", str "project-id");
            ("project_slug", str entry.Model.project);
          ] );
    ]

let conservative_relations () =
  let a = entry 1 in
  let selection = Model.States [ "Todo" ] in
  let reversed =
    obj
      [
        ("type", str "blocks");
        ( "issue",
          obj
            [ ("id", str a.Model.id); ("state", obj [ ("name", str "Done") ]) ]
        );
        ("relatedIssue", obj [ ("id", str "foreign") ]);
      ]
  in
  List.iter
    (fun relations ->
      let fake =
        scripted
          [
            step
              (issue_request selection None)
              (outer [ raw_issue a ~relations ] None);
          ]
      in
      match succeeded fake (read fake selection) with
      | [ issue ] ->
          Alcotest.check Alcotest.bool
            "unusable evidence cannot prove eligibility" true
            (Issue.routing issue = Issue.Unroutable)
      | [] | _ :: _ :: _ -> Alcotest.fail "unexpected delivered count")
    [ null; connection [ reversed ] None ]

let nested_partition_matches lengths =
  let a = entry 1 in
  let selection = Model.States [ "Todo" ] in
  let names = [ "bug"; "urgent"; "BUG"; "x"; "urgent" ] in
  let pages =
    Model.partition lengths
      (List.map (fun name -> obj [ ("name", str name) ]) names)
  in
  match pages with
  | [] -> Alcotest.fail "nonempty metadata partition was lost"
  | first :: rest -> (
      let cursor index = "label:" ^ string_of_int index in
      let first_next =
        match rest with
        | [] -> None
        | _ :: _ -> Some (cursor 0)
      in
      let outer_step =
        step
          (issue_request selection None)
          (outer [ raw_issue a ~labels:(connection first first_next) ] None)
      in
      let rec nested_steps index = function
        | [] -> []
        | page :: rest ->
            let next =
              match rest with
              | [] -> None
              | _ :: _ -> Some (cursor (index + 1))
            in
            step
              (Model.Labels_page
                 { id = a.Model.id; after = Some (cursor index) })
              (nested a "labels" page next)
            :: nested_steps (index + 1) rest
      in
      let fake = scripted (outer_step :: nested_steps 0 rest) in
      match succeeded fake (read fake selection) with
      | [ issue ] -> Issue.labels issue = [ "bug"; "urgent"; "x" ]
      | [] | _ :: _ :: _ -> false)

let state_order () =
  let a = entry 2 and b = entry 1 and c = entry 3 in
  let selection = Model.States [ " TODO "; "todo" ] in
  let fake =
    scripted
      (outer_steps selection [ [ raw_issue a; raw_issue b ]; [ raw_issue c ] ])
  in
  let issues = succeeded fake (read fake selection) in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "provider order"
    [ a.Model.id; b.Model.id; c.Model.id ]
    (ids issues);
  Alcotest.check Alcotest.int "later page fetched" 2 (calls fake);
  Alcotest.check (Alcotest.list json_test) "ordered full snapshots"
    (List.map snapshot [ a; b; c ])
    (List.map Issue.to_json issues)

let id_chunks () =
  let entries = List.init 101 entry in
  let selection =
    Model.Ids (List.rev_map (fun entry -> entry.Model.id) entries)
  in
  let chunks = Model.chunks selection in
  let returned chunk =
    match chunk with
    | Model.States _ -> Alcotest.fail "IDs became states"
    | Model.Ids names ->
        List.rev
          (List.filter
             (fun entry -> List.exists (String.equal entry.Model.id) names)
             entries)
        |> List.map (fun entry -> { entry with Model.state = "Done" })
  in
  let expected = List.concat_map returned chunks in
  let scripts =
    List.map
      (fun chunk ->
        step (issue_request chunk None)
          (outer
             (List.map (fun entry -> raw_issue entry) (returned chunk))
             None))
      chunks
  in
  let fake = scripted scripts in
  let issues = succeeded fake (read fake selection) in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "ordered chunk delivery"
    (List.map (fun entry -> entry.Model.id) expected)
    (ids issues);
  Alcotest.check Alcotest.int "50/50/1 chunks" 3 (calls fake);
  Alcotest.check Alcotest.bool "non-active states refreshed" true
    (List.for_all (fun issue -> Issue.state issue = "Done") issues)

let metadata_pages () =
  let a = entry 1 and b = entry 2 in
  let label name = obj [ ("name", str name) ] in
  let blocker =
    obj
      [
        ("type", str "blocks");
        ( "issue",
          obj
            [
              ("id", str "blocker");
              ("identifier", str "BLOCK-1");
              ("state", obj [ ("name", str "Done") ]);
            ] );
        ("relatedIssue", obj [ ("id", str a.Model.id) ]);
      ]
  in
  let selection = Model.States [ "Todo" ] in
  let raw =
    raw_issue a
      ~labels:(connection [ label "Bug" ] (Some "label:1"))
      ~relations:(connection [ blocker ] (Some "relation:1"))
  in
  let fake =
    scripted
      [
        step (issue_request selection None) (outer [ raw; raw_issue b ] None);
        step
          (Model.Labels_page { id = a.Model.id; after = Some "label:1" })
          (nested a "labels" [ label "Urgent" ] (Some "label:2"));
        step
          (Model.Labels_page { id = a.Model.id; after = Some "label:2" })
          (nested a "labels" [ label "BUG" ] None);
        step
          (Model.Relations_page { id = a.Model.id; after = Some "relation:1" })
          (nested a "inverseRelations" [ blocker ] None);
      ]
  in
  match succeeded fake (read fake selection) with
  | [ first; second ] ->
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "nested labels complete" [ "bug"; "urgent" ] (Issue.labels first);
      Alcotest.check Alcotest.bool "terminal incoming blockers eligible" true
        (Issue.routing first = Issue.Dispatchable);
      Alcotest.check Alcotest.string "next outer node retains order" b.Model.id
        (Issue_id.text (Issue.id second));
      Alcotest.check Alcotest.int "all nested pages" 4 (calls fake)
  | [] | [ _ ] | _ :: _ :: _ :: _ -> Alcotest.fail "unexpected delivered count"

let duplicates () =
  let a = entry 1 and b = entry 2 in
  let selection = Model.States [ "Todo" ] in
  List.iter
    (fun (duplicate, category) ->
      let fake =
        scripted
          (outer_steps selection [ [ raw_issue a ]; [ raw_issue duplicate ] ])
      in
      failed category (read fake selection);
      Alcotest.check Alcotest.int "failure after second page" 2 (calls fake))
    [
      ({ b with Model.id = a.Model.id }, Tracker_error.Tracker_pagination);
      ( { b with Model.identifier = a.Model.identifier },
        Tracker_error.Tracker_response );
    ];
  let requested =
    List.init 51 entry |> List.map (fun entry -> entry.Model.id)
  in
  let selection = Model.Ids requested in
  match Model.chunks selection with
  | [ first; second ] ->
      let fake =
        scripted
          [
            step (issue_request first None) (outer [ raw_issue a ] None);
            step (issue_request second None) (outer [ raw_issue a ] None);
          ]
      in
      failed Tracker_error.Tracker_response (read fake selection)
  | [] | [ _ ] | _ :: _ :: _ :: _ -> Alcotest.fail "invalid chunk fixture"

let late_failures () =
  let a = entry 1 in
  let selection = Model.States [ "Todo" ] in
  let graphql =
    response
      (obj
         [
           ("data", obj [ ("issues", connection [ raw_issue (entry 2) ] None) ]);
           ("errors", array [ obj [ ("message", str "provider-secret") ] ]);
         ])
  in
  List.iter
    (fun (answer, category) ->
      let fake =
        scripted
          [
            step
              (issue_request selection None)
              (outer [ raw_issue a ] (Some "next"));
            step (issue_request selection (Some "next")) answer;
            step (issue_request selection (Some "unreachable")) (outer [] None);
          ]
      in
      failed category (read fake selection);
      Alcotest.check Alcotest.int "failure absorbs suffix" 2 (calls fake))
    [
      (Reject diagnostic, Tracker_error.Tracker_request);
      (graphql, Tracker_error.Tracker_response);
      ( outer [ raw_issue (entry 2) ] (Some "next"),
        Tracker_error.Tracker_pagination );
    ]

let scoped_filter () =
  let wanted = entry 1 in
  List.iter
    (fun (selection, returned) ->
      let fake =
        scripted
          [
            step
              (issue_request selection None)
              (outer [ raw_issue returned ] None);
          ]
      in
      failed Tracker_error.Tracker_response (read fake selection))
    [
      (Model.States [ "Todo" ], { wanted with Model.project = "foreign" });
      (Model.States [ "Todo" ], { wanted with Model.state = "Done" });
      (Model.Ids [ wanted.Model.id ], entry 2);
    ]

let malformed entry =
  match Json.view (raw_issue entry) with
  | Json.Object fields -> obj (List.remove_assoc "title" fields)
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      Alcotest.fail "fixture is not an object"

let omissions () =
  let a = entry 1 and b = entry 2 in
  let selection = Model.States [ "Todo" ] in
  let fake =
    scripted
      [
        step
          (issue_request selection None)
          (outer [ malformed a; raw_issue b ] None);
      ]
  in
  let reports = ref [] in
  let omitted omission =
    reports := omission :: !reports;
    Error diagnostic
  in
  let issues = succeeded fake (read ~omitted fake selection) in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "malformed state node omitted" [ b.Model.id ] (ids issues);
  Alcotest.check Alcotest.int "warning expected error ignored" 1
    (List.length !reports);
  let selection = Model.Ids [ a.Model.id; b.Model.id ] in
  let fake =
    scripted
      [
        step
          (issue_request selection None)
          (outer [ raw_issue b; malformed a ] None);
      ]
  in
  failed Tracker_error.Tracker_response (read fake selection);
  let unidentifiable = obj [ ("project", obj [ ("slugId", str project) ]) ] in
  let fake =
    scripted
      [ step (issue_request selection None) (outer [ unidentifiable ] None) ]
  in
  failed Tracker_error.Tracker_response (read fake selection)

let reporter_defect () =
  let selection = Model.States [ "Todo" ] in
  let fake =
    scripted
      [
        step (issue_request selection None) (outer [ malformed (entry 1) ] None);
      ]
  in
  let defect = Failure "reporter defect" in
  let outcome =
    try
      ignore (read ~omitted:(fun _ -> raise defect) fake selection);
      None
    with exception_ -> Some exception_
  in
  Alcotest.check Alcotest.bool "original reporter defect" true
    (match outcome with
    | None -> false
    | Some actual -> actual == defect)

let post_defect () =
  let selection = Model.States [ "Todo" ] in
  let defect = Failure "post defect" in
  let fake =
    scripted
      [
        step
          (issue_request selection None)
          (outer [ raw_issue (entry 1) ] (Some "next"));
        step (issue_request selection (Some "next")) (Crash defect);
      ]
  in
  let outcome =
    try
      ignore (read fake selection);
      None
    with exception_ -> Some exception_
  in
  Alcotest.check Alcotest.bool "original post defect" true
    (match outcome with
    | None -> false
    | Some actual -> actual == defect);
  Alcotest.check Alcotest.int "no detached continuation" 2 (calls fake)

let nested_failure () =
  let a = entry 1 in
  let selection = Model.States [ "Todo" ] in
  let raw =
    raw_issue a
      ~labels:(connection [ obj [ ("name", str "bug") ] ] (Some "labels"))
  in
  let fake =
    scripted
      [
        step (issue_request selection None) (outer [ raw ] None);
        step
          (Model.Labels_page { id = a.Model.id; after = Some "labels" })
          (Reject diagnostic);
      ]
  in
  failed Tracker_error.Tracker_request (read fake selection);
  let foreign = { a with Model.id = "foreign" } in
  let fake =
    scripted
      [
        step (issue_request selection None) (outer [ raw ] None);
        step
          (Model.Labels_page { id = a.Model.id; after = Some "labels" })
          (nested foreign "labels" [] None);
      ]
  in
  failed Tracker_error.Tracker_response (read fake selection)

let request_bound () =
  let selection = Model.States [ "Todo" ] in
  let pages =
    List.init (maximum_posts + 1) (fun number -> [ raw_issue (entry number) ])
  in
  let fake = scripted (outer_steps selection pages) in
  failed Tracker_error.Tracker_pagination (read fake selection);
  Alcotest.check Alcotest.int "no post beyond cumulative bound" maximum_posts
    (calls fake)

let node_bound () =
  let selection = Model.States [ "Todo" ] in
  let labels = connection (List.init page_size (fun _ -> obj [])) None in
  let relations =
    connection
      (List.init page_size (fun _ -> obj [ ("type", str "related") ]))
      None
  in
  (* Each outer node carries two completed inline connections. Counting only
     HTTP posts or outer nodes misses this independently sized amplification. *)
  let nodes_per_page = page_size * (1 + page_size + page_size) in
  let failing_post = (maximum_nodes / nodes_per_page) + 1 in
  let pages =
    List.init failing_post (fun page ->
        List.init page_size (fun index ->
            raw_issue ~labels ~relations (entry ((page * page_size) + index))))
  in
  let fake = scripted (outer_steps selection pages) in
  failed Tracker_error.Tracker_pagination (read fake selection);
  Alcotest.check Alcotest.int "connection node budget includes inline metadata"
    failing_post (calls fake)

let issue_bound () =
  let selection = Model.States [ "Todo" ] in
  let failing_post = (maximum_issues / page_size) + 1 in
  let pages =
    List.init failing_post (fun page ->
        List.init page_size (fun index ->
            raw_issue (entry ((page * page_size) + index))))
  in
  let fake = scripted (outer_steps selection pages) in
  failed Tracker_error.Tracker_pagination (read fake selection);
  Alcotest.check Alcotest.int "outer issue cap independent of total node cap"
    failing_post (calls fake)

let byte_bound () =
  let selection = Model.States [ "Todo" ] in
  let body_bytes = maximum_bytes / 16 in
  let failing_post = (maximum_bytes / body_bytes) + 1 in
  let pages =
    List.init failing_post (fun index -> [ raw_issue (entry index) ])
  in
  let scripts =
    outer_steps selection pages
    |> List.map (fun step ->
        match step.answer with
        | Reply response ->
            let padding =
              body_bytes - String.length response.Http_transport.body
            in
            let response =
              {
                response with
                Http_transport.body =
                  response.Http_transport.body ^ String.make padding ' ';
              }
            in
            Alcotest.check Alcotest.int "physical response body size" body_bytes
              (String.length response.Http_transport.body);
            { step with answer = Reply response }
        | Reject _ | Crash _ -> Alcotest.fail "invalid byte-budget fixture")
  in
  (* Each body fits the individual JSON limit. Valid trailing whitespace adds
     no logical nodes, but still counts toward the cumulative byte budget. *)
  let fake = scripted scripts in
  failed Tracker_error.Tracker_pagination (read fake selection);
  Alcotest.check Alcotest.int "raw bytes accumulate across responses"
    failing_post (calls fake)

let partition_matches (lengths, count) =
  let entries = List.init count (fun index -> entry (count - index)) in
  let selection = Model.States [ "Todo" ] in
  let pages =
    Model.partition lengths (List.map (fun entry -> raw_issue entry) entries)
  in
  let fake = scripted (outer_steps selection pages) in
  let actual = succeeded fake (read fake selection) in
  match
    Model.collect ~project selection
      (List.map (fun value -> Model.Valid value) entries)
  with
  | Error _ -> false
  | Ok model ->
      ids actual = List.map (fun value -> value.Model.id) model.Model.entries

let filtering_matches nodes =
  let selection = Model.States [ "todo" ] in
  let raw =
    List.map
      (function
        | Model.Valid entry -> raw_issue entry
        | Model.Malformed -> malformed (entry 99))
      nodes
  in
  let fake =
    scripted [ step (issue_request selection None) (outer raw None) ]
  in
  let warnings = ref 0 in
  let result =
    read
      ~omitted:(fun _ ->
        incr warnings;
        Ok ())
      fake selection
  in
  match (Model.collect ~project selection nodes, result) with
  | Ok model, Ok batch ->
      ids (Issue_batch.ordered batch)
      = List.map (fun entry -> entry.Model.id) model.Model.entries
      && !warnings = model.Model.omitted
  | Error failure, Error error ->
      let expected =
        match failure with
        | Model.Duplicate_id -> Tracker_error.Tracker_pagination
        | Model.Duplicate_identifier
        | Model.Scope
        | Model.Filter
        | Model.Required -> Tracker_error.Tracker_response
      in
      Tracker_error.category error = expected
  | Ok _, Error _ | Error _, Ok _ -> false

let model_node_gen =
  QCheck2.Gen.(
    oneof
      [
        return Model.Malformed;
        map
          (fun (id, identifier, state, scope) ->
            Model.Valid
              {
                Model.id = "opaque:" ^ string_of_int id;
                identifier = "LIN-" ^ string_of_int identifier;
                state;
                project = scope;
              })
          (quad (int_range 0 8) (int_range 0 8)
             (oneof_list [ "Todo"; " todo "; "Done" ])
             (oneof_list [ project; "foreign" ]));
      ])

let tests =
  [
    Alcotest.test_case "empty selections perform zero posts" `Quick empty_reads;
    Alcotest.test_case "outer pages preserve provider order" `Quick state_order;
    Alcotest.test_case "IDs use sorted50 chunks and refresh non-active states"
      `Quick id_chunks;
    Alcotest.test_case "labels and relations complete before delivery" `Quick
      metadata_pages;
    Alcotest.test_case
      "unusable and reversed relations cannot prove eligibility" `Quick
      conservative_relations;
    Alcotest.test_case "duplicates fail across pages and chunks" `Quick
      duplicates;
    Alcotest.test_case "late errors and cycles absorb the entire read" `Quick
      late_failures;
    Alcotest.test_case "scope and requested membership are verified" `Quick
      scoped_filter;
    Alcotest.test_case "malformed states warn; ID reads fail atomically" `Quick
      omissions;
    Alcotest.test_case "reporter defects preserve identity" `Quick
      reporter_defect;
    Alcotest.test_case "post defects preserve identity after earlier data"
      `Quick post_defect;
    Alcotest.test_case "nested errors and foreign identities fail atomically"
      `Quick nested_failure;
    Alcotest.test_case "whole read enforces cumulative request bound" `Quick
      request_bound;
    Alcotest.test_case "whole read counts outer and inline connection nodes"
      `Quick node_bound;
    Alcotest.test_case "outer issue cap fails without truncating output" `Quick
      issue_bound;
    Alcotest.test_case "raw response bytes count across pages" `Quick byte_bound;
  ]

let properties =
  [
    QCheck2.Test.make ~name:"Linear paging agrees with ordered partition model"
      ~count:samples
      QCheck2.Gen.(
        pair (list_size (int_range 0 10) (int_range 1 8)) (int_range 0 30))
      partition_matches;
    QCheck2.Test.make ~name:"Linear nested metadata partition preserves labels"
      ~count:samples
      QCheck2.Gen.(list_size (int_range 0 10) (int_range 1 4))
      nested_partition_matches;
    QCheck2.Test.make
      ~name:"Linear filtering/omission/uniqueness agrees with list model"
      ~count:samples
      QCheck2.Gen.(list_size (int_range 0 12) model_node_gen)
      filtering_matches;
  ]
