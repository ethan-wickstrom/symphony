let checked = function
  | Ok value -> value
  | Error why -> Alcotest.fail why

let rejected = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected checked rejection"

let count value = checked (Count.parse value)
let at = checked (Utc.parse "2026-10-05T12:00:00Z")
let run, _ = Run_id.Allocator.fresh Run_id.Allocator.empty
let retry_id, _ = Retry_id.Allocator.fresh Retry_id.Allocator.empty
let seconds = Seconds.of_nanoseconds (count "1000000001")
let issue id = Core_fixture.issue ~id ~identifier:("ISSUE-" ^ id) ()

let session : Snapshot.session =
  {
    Snapshot.id = checked (Session_id.parse "thread-turn");
    thread = checked (Thread_id.parse "thread");
    turn = checked (Turn_id.parse "turn");
    turn_count = Positive_count.next Positive_count.first;
    last_event = "turn_completed";
    last_message = Some "<script>bad()</script>";
    last_event_at = None;
    tokens =
      Usage.make ~input:(count "9007199254740993") ~output:Count.one
        ~total:(count "9007199254740997");
  }

let running ?(phase = Snapshot.Streaming session) issue : Snapshot.running =
  {
    Snapshot.issue;
    run_id = run;
    attempt = Template.First;
    phase;
    started_at = None;
    seconds_running = seconds;
    workspace = Some "/workspace/observed";
  }

let retry ?(phase = Snapshot.Waiting None) issue : Snapshot.retry =
  {
    Snapshot.issue;
    retry_id;
    attempt = Positive_count.first;
    phase;
    error = None;
  }

let data ?(running = []) ?(retrying = []) ?(cleaning = []) () : Snapshot.data =
  {
    Snapshot.generated_at = at;
    running;
    retrying;
    cleaning;
    tokens = session.Snapshot.tokens;
    seconds_running = seconds;
    rate_limits = None;
    workflow_error = None;
  }

let field key value =
  match Json.view value with
  | Json.Object fields -> (
      match List.assoc_opt key fields with
      | Some value -> value
      | None -> Alcotest.fail ("missing field: " ^ key))
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      Alcotest.fail "expected object"

let string value =
  match Json.view value with
  | Json.String value -> value
  | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _ ->
      Alcotest.fail "expected string"

let numeric value =
  match Json.view value with
  | Json.Number value -> value
  | Json.Null | Json.Bool _ | Json.String _ | Json.Array _ | Json.Object _ ->
      Alcotest.fail "expected exact number"

let array value =
  match Json.view value with
  | Json.Array value -> value
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Object _ ->
      Alcotest.fail "expected array"

let is_null value =
  match Json.view value with
  | Json.Null -> true
  | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ | Json.Object _
    -> false

let contains haystack needle =
  let width = String.length needle in
  let rec search start =
    start + width <= String.length haystack
    && (String.sub haystack start width = needle || search (start + 1))
  in
  search 0

module Source = struct
  type t = {
    value : (Snapshot.t, Status_source.unavailable) result;
    refreshed : (Status_source.refresh, Status_source.unavailable) result;
    mutable reads : int;
    mutable triggers : int;
  }

  let snapshot t =
    t.reads <- t.reads + 1;
    t.value

  let refresh t =
    t.triggers <- t.triggers + 1;
    t.refreshed
end

module Surface = Status_surface.Make (Source)

let source ?(refreshed = Ok Status_source.Queued) value : Source.t =
  { Source.value; refreshed; reads = 0; triggers = 0 }

let request ?(method_ = Status_surface.Get) ?(body = "") path :
    Status_surface.request =
  { Http_message.method_; path; body }

let response_json (response : Status_surface.response) =
  checked (Json.parse response.Http_message.body)

let status expected (response : Status_surface.response) =
  Alcotest.check Alcotest.int "HTTP status" expected
    response.Http_message.status

let allow expected (response : Status_surface.response) =
  let method_name = function
    | Http_message.Get -> "GET"
    | Http_message.Post -> "POST"
    | Http_message.Other value -> "unsupported: " ^ value
  in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "allowed methods" expected
    (List.map method_name response.Http_message.allow)

let uniqueness () =
  let one = issue "1" and two = issue "2" in
  let original = checked (Snapshot.make (data ~running:[ running one ] ())) in
  rejected
    (Snapshot.make (data ~running:[ running one ] ~retrying:[ retry one ] ()));
  rejected (Snapshot.make (data ~running:[ running one; running two ] ()));
  rejected (Snapshot.make (data ~retrying:[ retry one; retry two ] ()));
  let alias = Core_fixture.issue ~id:"different" ~identifier:"ISSUE-1" () in
  rejected
    (Snapshot.make (data ~running:[ running one ] ~cleaning:[ alias ] ()));
  rejected
    (Snapshot.make
       (data
          ~running:[ { (running one) with Snapshot.workspace = Some "\xff" } ]
          ()));
  Alcotest.check Alcotest.int "original preserved" 1
    (fst (Snapshot.counts original))

type diagnostic_field = Retry_error | Workflow_error

let diagnostic_data field error =
  match field with
  | Retry_error ->
      data
        ~retrying:
          [ { (retry (issue "utf8")) with Snapshot.error = Some error } ]
        ()
  | Workflow_error -> { (data ()) with Snapshot.workflow_error = Some error }

let diagnostic_utf8 target () =
  let make site message remedy = Diagnostic.make ~site ~message ~remedy in
  let invalid =
    [
      make (Diagnostic.Host "host") "\xff" "repair";
      make (Diagnostic.Host "host") "failed" "\xe2\x82";
      make (Diagnostic.Host "\xc0\x80") "failed" "repair";
      make
        (Diagnostic.Workflow { file = "\xff"; key = None; line = None })
        "failed" "repair";
      make
        (Diagnostic.Workflow
           { file = "workflow"; key = Some "\xed\xa0\x80"; line = None })
        "failed" "repair";
      make
        (Diagnostic.Protocol
           { method_name = "\xf5\x80\x80\x80"; request_id = None })
        "failed" "repair";
      make
        (Diagnostic.Protocol
           { method_name = "method"; request_id = Some "\x80" })
        "failed" "repair";
    ]
  in
  List.iter
    (fun error -> rejected (Snapshot.make (diagnostic_data target error)))
    invalid;
  let error =
    make
      (Diagnostic.Workflow { file = "流程.md"; key = Some "状態"; line = None })
      "Δ repaired <retry> & ready" "Follow ✓"
  in
  let original = diagnostic_data target error in
  let snapshot = checked (Snapshot.make original) in
  Alcotest.check Alcotest.bool "checked data is preserved" true
    (Snapshot.data snapshot == original);
  let encoded = checked (Status_surface.json snapshot) in
  let rendered =
    match target with
    | Retry_error -> (
        match array (field "retrying" encoded) with
        | [ row ] -> string (field "error" row)
        | [] | _ :: _ -> Alcotest.fail "one retry expected")
    | Workflow_error -> string (field "workflow_error" encoded)
  in
  Alcotest.check Alcotest.string "valid Unicode diagnostic is retained"
    (Diagnostic.render error) rendered;
  let html = checked (Status_surface.html snapshot) in
  Alcotest.check Alcotest.bool "HTML remains UTF-8" true (Text.valid_utf8 html);
  Alcotest.check Alcotest.bool "Unicode diagnostic is escaped text" true
    (contains html "Δ repaired &lt;retry&gt; &amp; ready")

let exact_json () =
  let snapshot =
    checked
      (Snapshot.make
         (data
            ~running:[ running (issue "1") ]
            ~retrying:[ retry (issue "2") ]
            ()))
  in
  let encoded = checked (Status_surface.json snapshot) in
  Alcotest.check Alcotest.string "exact seconds" "1.000000001"
    (numeric (field "seconds_running" (field "codex_totals" encoded)));
  Alcotest.check Alcotest.string "above float precision" "9007199254740997"
    (numeric (field "total_tokens" (field "codex_totals" encoded)));
  let rows = array (field "running" encoded) in
  match rows with
  | [ row ] ->
      Alcotest.check Alcotest.bool "missing display time stays null" true
        (is_null (field "started_at" row));
      Alcotest.check Alcotest.bool "missing event time stays null" true
        (is_null (field "last_event_at" row));
      Alcotest.check Alcotest.string "actual session" "thread-turn"
        (string (field "session_id" row));
      Alcotest.check Alcotest.string "actual turns" "2"
        (numeric (field "turn_count" row));
      Alcotest.check Alcotest.bool "round trip" true
        (Json.equal encoded (checked (Json.parse (Json.encode encoded))))
  | [] | _ :: _ -> Alcotest.fail "expected one running row"

let no_session () =
  let snapshot =
    checked
      (Snapshot.make
         (data
            ~running:
              [ running ~phase:Snapshot.Stopping_before_session (issue "1") ]
            ()))
  in
  let response =
    Surface.handle (source (Ok snapshot)) (request "/api/v1/ISSUE-1")
  in
  status 200 response;
  let row = field "running" (response_json response) in
  Alcotest.check Alcotest.bool "no fabricated session" true
    (is_null (field "session_id" row));
  Alcotest.check Alcotest.string "turn identity" "0"
    (numeric (field "turn_count" row));
  Alcotest.check Alcotest.string "first attempt" "0"
    (numeric
       (field "current_retry_attempt"
          (field "attempts" (response_json response))))

let owner_detail () =
  let snapshot =
    checked
      (Snapshot.make
         (data
            ~retrying:[ retry ~phase:Snapshot.Parked (issue "2") ]
            ~cleaning:[ issue "3" ]
            ()))
  in
  let source = source (Ok snapshot) in
  let pending = Surface.handle source (request "/api/v1/ISSUE-2") in
  status 200 pending;
  let pending = field "retry" (response_json pending) in
  Alcotest.check Alcotest.string "parked phase" "parked"
    (string (field "phase" pending));
  Alcotest.check Alcotest.bool "park has no due" true
    (is_null (field "due_at" pending));
  let cleaning = Surface.handle source (request "/api/v1/ISSUE-3") in
  status 200 cleaning;
  let cleaning = response_json cleaning in
  Alcotest.check Alcotest.string "cleanup owner remains visible" "cleaning"
    (string (field "status" cleaning));
  Alcotest.check Alcotest.bool "no guessed cleanup workspace" true
    (is_null (field "path" (field "workspace" cleaning)));
  status 404 (Surface.handle source (request "/api/v1/ISSUE-released"));
  Alcotest.check Alcotest.int "one fresh read per detail" 3 source.Source.reads

let route_authority () =
  let source = source (Ok (checked (Snapshot.make (data ())))) in
  List.iter
    (fun path ->
      let response =
        Surface.handle source (request ~method_:Status_surface.Post path)
      in
      status 405 response;
      allow [ "GET" ] response)
    [ "/"; "/api/v1/state"; "/api/v1/ISSUE-1" ];
  let response = Surface.handle source (request "/api/v1/refresh") in
  status 405 response;
  allow [ "POST" ] response;
  let response =
    Surface.handle source
      (request ~method_:(Status_surface.Other "GET") "/api/v1/state")
  in
  status 405 response;
  allow [ "GET" ] response;
  List.iter
    (fun path ->
      let response = Surface.handle source (request path) in
      status 404 response;
      allow [] response)
    [ "/missing"; "/api/v1/"; "/api/v1/a/b" ];
  Alcotest.check Alcotest.int "rejected routes read no state" 0
    source.Source.reads;
  Alcotest.check Alcotest.int "rejected routes enqueue nothing" 0
    source.Source.triggers;
  List.iter
    (fun path ->
      let response = Surface.handle source (request path) in
      status 200 response;
      allow [] response)
    [ "/api/v1/state"; "/" ];
  Alcotest.check Alcotest.int "two accepted reads" 2 source.Source.reads

let refresh () =
  List.iter
    (fun value ->
      let source = source ~refreshed:(Ok value) (Error Status_source.Timeout) in
      let response =
        Surface.handle source
          (request ~method_:Status_surface.Post "/api/v1/refresh")
      in
      status 202 response;
      allow [] response;
      let value =
        match value with
        | Status_source.Queued -> false
        | Status_source.Coalesced -> true
      in
      let expected = checked (Json.of_view (Json.Bool value)) in
      Alcotest.check Alcotest.bool "coalescing truth" true
        (Json.equal expected (field "coalesced" (response_json response)));
      Alcotest.check Alcotest.int "refresh does not request snapshot" 0
        source.Source.reads;
      Alcotest.check Alcotest.int "exactly one trigger" 1 source.Source.triggers)
    [ Status_source.Queued; Status_source.Coalesced ]

let refresh_body () =
  let source = source (Error Status_source.Timeout) in
  List.iter
    (fun body ->
      let response =
        Surface.handle source
          (request ~method_:Status_surface.Post ~body "/api/v1/refresh")
      in
      status 400 response;
      allow [] response;
      Alcotest.check Alcotest.string "checked body failure"
        "invalid_refresh_body"
        (string (field "code" (field "error" (response_json response)))))
    [
      "{";
      "null";
      "[]";
      "0";
      "true";
      "\"refresh\"";
      "{\"force\":true}";
      "{} trailing";
    ];
  Alcotest.check Alcotest.int "invalid bodies invoke no trigger" 0
    source.Source.triggers;
  List.iter
    (fun body ->
      let response =
        Surface.handle source
          (request ~method_:Status_surface.Post ~body "/api/v1/refresh")
      in
      status 202 response;
      allow [] response)
    [ ""; " \t\r\n"; "{}"; " \n{ }\t" ];
  Alcotest.check Alcotest.int "only accepted bodies enqueue" 4
    source.Source.triggers;
  Alcotest.check Alcotest.int "body validation reads no snapshot" 0
    source.Source.reads

let unavailable () =
  List.iter
    (fun why ->
      let source = source ~refreshed:(Error why) (Error why) in
      List.iter
        (fun path ->
          let response = Surface.handle source (request path) in
          status 503 response;
          ignore (field "error" (response_json response)))
        [ "/"; "/api/v1/state"; "/api/v1/ISSUE-1" ];
      status 503
        (Surface.handle source
           (request ~method_:Status_surface.Post "/api/v1/refresh")))
    [
      Status_source.Timeout;
      Status_source.Shutting_down;
      Status_source.Clock_unavailable;
      Status_source.Projection_unavailable;
    ]

let escaped_html () =
  let issue =
    Core_fixture.issue ~id:"unsafe" ~identifier:"<unsafe&\"'"
      ~title:"</td><script>bad()</script>" ()
  in
  let snapshot = checked (Snapshot.make (data ~cleaning:[ issue ] ())) in
  let html = checked (Status_surface.html snapshot) in
  Alcotest.check Alcotest.bool "title is escaped text" true
    (contains html "&lt;/td&gt;&lt;script&gt;bad()&lt;/script&gt;");
  Alcotest.check Alcotest.bool "identifier is escaped" true
    (contains html "&lt;unsafe&amp;&quot;&#39;");
  Alcotest.check Alcotest.bool "no executable markup" false
    (contains html "<script>");
  Alcotest.check Alcotest.bool "refresh operational endpoint" true
    (contains html "action=\"/api/v1/refresh\"");
  Alcotest.check Alcotest.string "same snapshot same page" html
    (checked (Status_surface.html snapshot))

let omitted_authority () =
  let base = issue "1" in
  let fields =
    match Json.view (Issue.to_json base) with
    | Json.Object fields -> fields
    | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
        Alcotest.fail "issue shape"
  in
  let encoded =
    Json.encode
      (checked
         (Status_surface.json
            (checked (Snapshot.make (data ~cleaning:[ base ] ())))))
  in
  List.iter
    (fun key ->
      Alcotest.check Alcotest.bool
        ("private tracker field " ^ key)
        false
        (contains encoded ("\"" ^ key ^ "\":")))
    [ "native_ref"; "assignee_id"; "description" ];
  Alcotest.check Alcotest.bool "fixture is normalized" true
    (List.mem_assoc "native_ref" fields)

let oversize () =
  let max_json_bytes = 1024 * 1024 in
  let limits =
    checked (Json.of_view (Json.String (String.make (max_json_bytes - 2) 'x')))
  in
  let snapshot =
    checked
      (Snapshot.make { (data ()) with Snapshot.rate_limits = Some limits })
  in
  rejected (Status_surface.json snapshot);
  status 503 (Surface.handle (source (Ok snapshot)) (request "/api/v1/state"))

let html_limit () =
  let title = String.make (64 * 1024) 'x' in
  let cleaning =
    List.init 64 (fun n ->
        Core_fixture.issue ~id:(string_of_int n)
          ~identifier:("LARGE-" ^ string_of_int n)
          ~title ())
  in
  let snapshot = checked (Snapshot.make (data ~cleaning ())) in
  rejected (Status_surface.html snapshot);
  status 503 (Surface.handle (source (Ok snapshot)) (request "/"))

let health_summary () =
  let limits = checked (Json.parse "{\"remaining\":0}") in
  let snapshot =
    checked
      (Snapshot.make
         {
           (data
              ~running:[ running (issue "1") ]
              ~retrying:
                [ retry ~phase:(Snapshot.Waiting (Some at)) (issue "2") ]
              ())
           with
           Snapshot.rate_limits = Some limits;
           workflow_error = Some Core_fixture.diagnostic;
         })
  in
  let html = checked (Status_surface.html snapshot) in
  List.iter
    (fun value ->
      Alcotest.check Alcotest.bool
        ("summary contains " ^ value)
        true (contains html value))
    [
      "Runtime seconds";
      "1.000000001";
      "Retry due";
      Utc.rfc3339 at;
      "turn_completed";
      "thread-turn";
      "Rate limits:";
      "&quot;remaining&quot;:0";
      "role=\"alert\"";
    ]

let thousand_rows () =
  let session_row n =
    let thread = checked (Thread_id.parse ("thread" ^ string_of_int n)) in
    {
      session with
      Snapshot.thread;
      id = checked (Session_id.parse (Thread_id.text thread ^ "-turn"));
    }
  in
  let rows, _ =
    List.fold_left
      (fun (rows, allocator) n ->
        let run_id, allocator = Run_id.Allocator.fresh allocator in
        let row =
          running
            ~phase:(Snapshot.Streaming (session_row n))
            (issue (string_of_int n))
        in
        ({ row with Snapshot.run_id } :: rows, allocator))
      ([], Run_id.Allocator.empty)
      (List.init 1000 Fun.id)
  in
  let tokens =
    List.fold_left
      (fun total (_ : Snapshot.running) ->
        Usage.add total session.Snapshot.tokens)
      Usage.zero rows
  in
  let seconds_running =
    List.fold_left
      (fun total (row : Snapshot.running) ->
        Seconds.add total row.Snapshot.seconds_running)
      Seconds.zero rows
  in
  let snapshot =
    checked
      (Snapshot.make
         { (data ~running:rows ()) with Snapshot.tokens; seconds_running })
  in
  let json = checked (Status_surface.json snapshot) in
  Alcotest.check Alcotest.int "all checked rows fit" 1000
    (List.length (array (field "running" json)));
  Alcotest.check Alcotest.string "joined exact runtime" "1000.000001"
    (numeric (field "seconds_running" (field "codex_totals" json)));
  let html = checked (Status_surface.html snapshot) in
  Alcotest.check Alcotest.bool "first and last owner rendered" true
    (contains html "ISSUE-0" && contains html "ISSUE-999")

let tests =
  [
    Alcotest.test_case "checked disjoint ownership" `Quick uniqueness;
    Alcotest.test_case "retry diagnostic rejects invalid UTF-8" `Quick
      (diagnostic_utf8 Retry_error);
    Alcotest.test_case "workflow diagnostic rejects invalid UTF-8" `Quick
      (diagnostic_utf8 Workflow_error);
    Alcotest.test_case "exact JSON and nullable wall display" `Quick exact_json;
    Alcotest.test_case "pre-session phase cannot fabricate session" `Quick
      no_session;
    Alcotest.test_case "retry and cleanup detail" `Quick owner_detail;
    Alcotest.test_case "routing rejects before port authority" `Quick
      route_authority;
    Alcotest.test_case "refresh calls only trigger" `Quick refresh;
    Alcotest.test_case "refresh body rejects before trigger" `Quick refresh_body;
    Alcotest.test_case "unavailability is 503, never issue 404" `Quick
      unavailable;
    Alcotest.test_case "HTML text escaping and refresh" `Quick escaped_html;
    Alcotest.test_case "selected public fields omit tracker internals" `Quick
      omitted_authority;
    Alcotest.test_case "oversized JSON remains expected failure" `Quick oversize;
    Alcotest.test_case "HTML has its own bounded output" `Quick html_limit;
    Alcotest.test_case "retry/runtime/rate health are visible" `Quick
      health_summary;
    Alcotest.test_case "1000 checked rows fit both renderers" `Quick
      thousand_rows;
  ]

let properties =
  let open QCheck2 in
  [
    Test.make ~name:"snapshot agrees with disjoint list model" ~count:300
      Gen.(triple (int_range 0 30) (int_range 0 30) (int_range 0 30))
      (fun (nr, nq, nc) ->
        let running, _ =
          List.fold_left
            (fun (rows, allocator) n ->
              let run_id, allocator = Run_id.Allocator.fresh allocator in
              ( {
                  (running (issue ("r" ^ string_of_int n))) with
                  Snapshot.run_id;
                }
                :: rows,
                allocator ))
            ([], Run_id.Allocator.empty)
            (List.init nr Fun.id)
        in
        let retrying, _ =
          List.fold_left
            (fun (rows, allocator) n ->
              let retry_id, allocator = Retry_id.Allocator.fresh allocator in
              ( {
                  (retry (issue ("q" ^ string_of_int n))) with
                  Snapshot.retry_id;
                }
                :: rows,
                allocator ))
            ([], Retry_id.Allocator.empty)
            (List.init nq Fun.id)
        in
        let cleaning = List.init nc (fun n -> issue ("c" ^ string_of_int n)) in
        let snapshot =
          checked (Snapshot.make (data ~running ~retrying ~cleaning ()))
        in
        let lookup issue expected =
          match Snapshot.find snapshot (Issue.identifier issue) with
          | Some (Snapshot.Running row) ->
              expected = "running"
              && Issue_id.equal (Issue.id issue) (Issue.id row.Snapshot.issue)
          | Some (Snapshot.Retrying row) ->
              expected = "retrying"
              && Issue_id.equal (Issue.id issue) (Issue.id row.Snapshot.issue)
          | Some (Snapshot.Cleaning found) ->
              expected = "cleaning"
              && Issue_id.equal (Issue.id issue) (Issue.id found)
          | None -> false
        in
        Snapshot.counts snapshot = (nr, nq)
        && List.for_all
             (fun (row : Snapshot.running) ->
               lookup row.Snapshot.issue "running")
             running
        && List.for_all
             (fun (row : Snapshot.retry) ->
               lookup row.Snapshot.issue "retrying")
             retrying
        && List.for_all (fun issue -> lookup issue "cleaning") cleaning
        && Option.is_none
             (Snapshot.find snapshot (Issue.identifier (issue "released"))));
  ]
