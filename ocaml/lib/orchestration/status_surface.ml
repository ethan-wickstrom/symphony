type method_ = Http_message.method_ = Get | Post | Other of string

type request = Http_message.request = {
  method_ : method_;
  path : string;
  body : string;
}

type response = Http_message.response = {
  status : int;
  content_type : string;
  body : string;
  allow : method_ list;
}

let ( let* ) = Result.bind
let ok_status = 200
let accepted_status = 202
let bad_request_status = 400
let missing_status = 404
let method_status = 405
let unavailable_status = 503
let object_ fields = Json.of_view (Json.Object fields)
let text value = Json.of_view (Json.String value)
let number value = Json.of_view (Json.Number value)
let null () = Json.of_view Json.Null

let optional f = function
  | None -> null ()
  | Some value -> f value

let timestamp value = text (Utc.rfc3339 value)

let list f values =
  let step checked value =
    let* reversed = checked in
    let* encoded = f value in
    Ok (encoded :: reversed)
  in
  let* reversed = List.fold_left step (Ok []) values in
  Json.of_view (Json.Array (List.rev reversed))

let usage_fields usage =
  let* input = number (Count.decimal (Usage.input usage)) in
  let* output = number (Count.decimal (Usage.output usage)) in
  let* total = number (Count.decimal (Usage.total usage)) in
  Ok
    [
      ("input_tokens", input); ("output_tokens", output); ("total_tokens", total);
    ]

let usage usage =
  let* fields = usage_fields usage in
  object_ fields

let issue_fields issue =
  let* id = text (Issue_id.text (Issue.id issue)) in
  let* identifier = text (Issue_identifier.text (Issue.identifier issue)) in
  let* title = text (Issue.title issue) in
  let* state = text (Issue.state issue) in
  let* url =
    match Json.view (Issue.to_json issue) with
    | Json.Object fields -> (
        match List.assoc_opt "url" fields with
        | Some value -> Ok value
        | None -> null ())
    | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
        null ()
  in
  Ok
    [
      ("issue_id", id);
      ("issue_identifier", identifier);
      ("issue_url", url);
      ("title", title);
      ("state", state);
    ]

let phase = function
  | Snapshot.Awaiting -> ("awaiting", None)
  | Snapshot.Preparing -> ("preparing", None)
  | Snapshot.Workspace_ready -> ("workspace_ready", None)
  | Snapshot.Rendering -> ("rendering", None)
  | Snapshot.Starting -> ("starting", None)
  | Snapshot.Streaming session -> ("streaming", Some session)
  | Snapshot.Between_turns session -> ("between_turns", Some session)
  | Snapshot.Stopping_before_session -> ("stopping", None)
  | Snapshot.Stopping_session session -> ("stopping", Some session)

let session_fields session =
  let* id =
    optional
      (fun (s : Snapshot.session) -> text (Session_id.text s.Snapshot.id))
      session
  in
  let* thread =
    optional
      (fun (s : Snapshot.session) -> text (Thread_id.text s.Snapshot.thread))
      session
  in
  let* turn =
    optional
      (fun (s : Snapshot.session) -> text (Turn_id.text s.Snapshot.turn))
      session
  in
  let* turns =
    number
      (Count.decimal
         (Option.fold ~none:Count.zero
            ~some:(fun (s : Snapshot.session) ->
              Positive_count.count s.Snapshot.turn_count)
            session))
  in
  let* event =
    optional (fun (s : Snapshot.session) -> text s.Snapshot.last_event) session
  in
  let* message =
    optional
      (fun (s : Snapshot.session) -> optional text s.Snapshot.last_message)
      session
  in
  let* at =
    optional
      (fun (s : Snapshot.session) ->
        optional timestamp s.Snapshot.last_event_at)
      session
  in
  let* tokens =
    usage
      (Option.fold ~none:Usage.zero
         ~some:(fun (s : Snapshot.session) -> s.Snapshot.tokens)
         session)
  in
  Ok
    [
      ("session_id", id);
      ("thread_id", thread);
      ("turn_id", turn);
      ("turn_count", turns);
      ("last_event", event);
      ("last_message", message);
      ("last_event_at", at);
      ("tokens", tokens);
    ]

let running (row : Snapshot.running) =
  let* issue = issue_fields row.Snapshot.issue in
  let name, session = phase row.Snapshot.phase in
  let* phase_name = text name in
  let* session = session_fields session in
  let* run = text (Run_id.text row.Snapshot.run_id) in
  let* started = optional timestamp row.Snapshot.started_at in
  let* runtime = number (Seconds.decimal row.Snapshot.seconds_running) in
  let* path = optional text row.Snapshot.workspace in
  object_
    (issue @ session
    @ [
        ("run_id", run);
        ("phase", phase_name);
        ("started_at", started);
        ("seconds_running", runtime);
        ("workspace_path", path);
      ])

let retry (row : Snapshot.retry) =
  let* issue = issue_fields row.Snapshot.issue in
  let name, due =
    match row.Snapshot.phase with
    | Snapshot.Waiting due -> ("waiting", due)
    | Snapshot.Refreshing -> ("refreshing", None)
    | Snapshot.Parked -> ("parked", None)
  in
  let* phase = text name in
  let* due = optional timestamp due in
  let* attempt =
    number (Count.decimal (Positive_count.count row.Snapshot.attempt))
  in
  let* id = text (Retry_id.text row.Snapshot.retry_id) in
  let* error =
    optional (fun value -> text (Diagnostic.render value)) row.Snapshot.error
  in
  object_
    (issue
    @ [
        ("retry_id", id);
        ("phase", phase);
        ("attempt", attempt);
        ("due_at", due);
        ("error", error);
      ])

let cleaning issue =
  let* fields = issue_fields issue in
  object_ fields

let json snapshot =
  let data = Snapshot.data snapshot in
  let running_count, retry_count = Snapshot.counts snapshot in
  let* generated = timestamp data.Snapshot.generated_at in
  let* running_count = number (string_of_int running_count) in
  let* retry_count = number (string_of_int retry_count) in
  let* cleaning_count =
    number (string_of_int (List.length data.Snapshot.cleaning))
  in
  let* counts =
    object_
      [
        ("running", running_count);
        ("retrying", retry_count);
        ("cleaning", cleaning_count);
      ]
  in
  let* running = list running data.Snapshot.running in
  let* retrying = list retry data.Snapshot.retrying in
  let* cleaning = list cleaning data.Snapshot.cleaning in
  let* totals = usage_fields data.Snapshot.tokens in
  let* runtime = number (Seconds.decimal data.Snapshot.seconds_running) in
  let* totals = object_ (totals @ [ ("seconds_running", runtime) ]) in
  let* limits = optional (fun value -> Ok value) data.Snapshot.rate_limits in
  let* workflow_error =
    optional
      (fun value -> text (Diagnostic.render value))
      data.Snapshot.workflow_error
  in
  object_
    [
      ("generated_at", generated);
      ("counts", counts);
      ("running", running);
      ("retrying", retrying);
      ("cleaning", cleaning);
      ("codex_totals", totals);
      ("rate_limits", limits);
      ("workflow_error", workflow_error);
    ]

let attempts attempt =
  let* current = number (Count.decimal attempt) in
  let* restarts =
    number (Count.decimal (Count.delta ~previous:Count.one ~current:attempt))
  in
  object_ [ ("restart_count", restarts); ("current_retry_attempt", current) ]

let detail found =
  let issue, status, run, pending, workspace, attempt, error =
    match found with
    | Snapshot.Running row ->
        let attempt =
          match row.Snapshot.attempt with
          | Template.First -> Count.zero
          | Template.Follow_up n -> Positive_count.count n
        in
        ( row.Snapshot.issue,
          "running",
          Some row,
          None,
          row.Snapshot.workspace,
          Some attempt,
          None )
    | Snapshot.Retrying row ->
        ( row.Snapshot.issue,
          "retrying",
          None,
          Some row,
          None,
          Some (Positive_count.count row.Snapshot.attempt),
          row.Snapshot.error )
    | Snapshot.Cleaning issue ->
        (issue, "cleaning", None, None, None, None, None)
  in
  let* fields = issue_fields issue in
  let* status = text status in
  let* run = optional running run in
  let* pending = optional retry pending in
  let* path = optional text workspace in
  let* workspace = object_ [ ("path", path) ] in
  let* attempts = optional attempts attempt in
  let* error = optional (fun value -> text (Diagnostic.render value)) error in
  object_
    (fields
    @ [
        ("status", status);
        ("workspace", workspace);
        ("attempts", attempts);
        ("running", run);
        ("retry", pending);
        ("last_error", error);
      ])

let max_html_bytes = 4 * 1024 * 1024

let html snapshot =
  let buffer = Buffer.create 1024 in
  let append value =
    if String.length value > max_html_bytes - Buffer.length buffer then
      Error "status HTML exceeds four MiB"
    else (
      Buffer.add_string buffer value;
      Ok ())
  in
  let escaped value =
    String.fold_left
      (fun checked char ->
        let* () = checked in
        append
          (match char with
          | '&' -> "&amp;"
          | '<' -> "&lt;"
          | '>' -> "&gt;"
          | '"' -> "&quot;"
          | '\'' -> "&#39;"
          | c -> String.make 1 c))
      (Ok ()) value
  in
  let cell value =
    let* () = append "<td>" in
    let* () = escaped value in
    append "</td>"
  in
  let row issue status session runtime due event =
    let* () = append "<tr>" in
    let* () = cell (Issue_identifier.text (Issue.identifier issue)) in
    let* () = cell (Issue.title issue) in
    let* () = cell (Issue.state issue) in
    let* () = cell status in
    let* () = cell session in
    let* () = cell runtime in
    let* () = cell due in
    let* () = cell event in
    append "</tr>"
  in
  let rows f values =
    List.fold_left
      (fun checked value ->
        let* () = checked in
        f value)
      (Ok ()) values
  in
  let data = Snapshot.data snapshot in
  let running_count, retry_count = Snapshot.counts snapshot in
  let* () =
    append
      "<!doctype html><html lang=\"en\"><head><meta \
       charset=\"utf-8\"><title>Symphony \
       status</title></head><body><h1>Symphony</h1><p>Updated "
  in
  let* () = escaped (Utc.rfc3339 data.Snapshot.generated_at) in
  let* () =
    append
      "</p><form method=\"post\" action=\"/api/v1/refresh\"><button \
       type=\"submit\">Refresh tracker</button></form><p>Running: "
  in
  let* () = escaped (string_of_int running_count) in
  let* () = append "; retrying: " in
  let* () = escaped (string_of_int retry_count) in
  let* () = append "; runtime seconds: " in
  let* () = escaped (Seconds.decimal data.Snapshot.seconds_running) in
  let* () = append "; total tokens: " in
  let* () = escaped (Count.decimal (Usage.total data.Snapshot.tokens)) in
  let* () = append "</p>" in
  let* () =
    match data.Snapshot.rate_limits with
    | None -> append "<p>Rate limits: unavailable</p>"
    | Some limits ->
        let* () = append "<p>Rate limits:</p><pre>" in
        let* () = escaped (Json.encode limits) in
        append "</pre>"
  in
  let* () =
    match data.Snapshot.workflow_error with
    | None -> Ok ()
    | Some error ->
        let* () = append "<p role=\"alert\">" in
        let* () = escaped (Diagnostic.render error) in
        append "</p>"
  in
  let* () =
    append
      "<table><thead><tr><th>Issue</th><th>Title</th><th>State</th><th>Phase</th><th>Session</th><th>Runtime \
       seconds</th><th>Retry due</th><th>Last event</th></tr></thead><tbody>"
  in
  let* () =
    rows
      (fun (r : Snapshot.running) ->
        let name, session = phase r.Snapshot.phase in
        let id =
          Option.fold ~none:"not started"
            ~some:(fun (s : Snapshot.session) -> Session_id.text s.Snapshot.id)
            session
        in
        let event =
          Option.fold ~none:""
            ~some:(fun (s : Snapshot.session) -> s.Snapshot.last_event)
            session
        in
        row r.Snapshot.issue name id
          (Seconds.decimal r.Snapshot.seconds_running)
          "" event)
      data.Snapshot.running
  in
  let* () =
    rows
      (fun (r : Snapshot.retry) ->
        let name, due =
          match r.Snapshot.phase with
          | Snapshot.Waiting due ->
              ( "retry waiting",
                Option.fold ~none:"wall time unavailable" ~some:Utc.rfc3339 due
              )
          | Snapshot.Refreshing -> ("retry refreshing", "")
          | Snapshot.Parked -> ("retry parked", "")
        in
        row r.Snapshot.issue name "" "" due
          (Option.fold ~none:"" ~some:Diagnostic.render r.Snapshot.error))
      data.Snapshot.retrying
  in
  let* () =
    rows (fun issue -> row issue "cleaning" "" "" "" "") data.Snapshot.cleaning
  in
  let* () = append "</tbody></table></body></html>" in
  Ok (Buffer.contents buffer)

module type S = sig
  type source

  val handle : source -> request -> response
end

module Make (Source : Status_source.S) = struct
  type source = Source.t

  let json_type = "application/json; charset=utf-8"

  let response ?(allow = []) status content_type body =
    { status; content_type; body; allow }

  let json_response status value = response status json_type (Json.encode value)

  let error ?(allow = []) status code message =
    response ~allow status json_type
      ("{\"error\":{\"code\":\"" ^ code ^ "\",\"message\":\"" ^ message ^ "\"}}")

  let unavailable = function
    | Status_source.Timeout ->
        error unavailable_status "snapshot_timeout" "Snapshot timed out"
    | Status_source.Shutting_down ->
        error unavailable_status "snapshot_unavailable"
          "Service is shutting down"
    | Status_source.Clock_unavailable ->
        error unavailable_status "clock_unavailable"
          "Status clock is unavailable"
    | Status_source.Projection_unavailable ->
        error unavailable_status "snapshot_unavailable"
          "Status projection is unavailable"

  let rendered = function
    | Ok value -> json_response ok_status value
    | Error _ ->
        error unavailable_status "snapshot_too_large"
          "Status exceeds the response limit"

  let snapshot source f =
    match Source.snapshot source with
    | Error why -> unavailable why
    | Ok value -> f value

  let not_found () = error missing_status "not_found" "Unknown route"

  let method_error allowed =
    error ~allow:[ allowed ] method_status "method_not_allowed"
      "Unsupported method"

  let detail_route path =
    let prefix = "/api/v1/" in
    if not (String.starts_with ~prefix path) then None
    else
      let identifier =
        String.sub path (String.length prefix)
          (String.length path - String.length prefix)
      in
      if String.contains identifier '/' then None
      else Result.to_option (Issue_identifier.parse identifier)

  let empty_refresh body =
    if String.trim body = "" then true
    else
      match Json.parse body with
      | Error _ -> false
      | Ok value -> (
          match Json.view value with
          | Json.Object [] -> true
          | Json.Null
          | Json.Bool _
          | Json.Number _
          | Json.String _
          | Json.Array _
          | Json.Object (_ :: _) -> false)

  let refresh source body =
    if not (empty_refresh body) then
      error bad_request_status "invalid_refresh_body"
        "Refresh body must be empty or an empty JSON object"
    else
      match Source.refresh source with
      | Error why -> unavailable why
      | Ok result ->
          let coalesced =
            match result with
            | Status_source.Queued -> "false"
            | Status_source.Coalesced -> "true"
          in
          response accepted_status json_type
            ("{\"queued\":true,\"coalesced\":" ^ coalesced
           ^ ",\"operations\":[\"poll\",\"reconcile\"]}")

  let handle source (request : request) =
    match (request.path, request.method_) with
    | "/", Get ->
        snapshot source (fun value ->
            match html value with
            | Ok body -> response ok_status "text/html; charset=utf-8" body
            | Error _ ->
                error unavailable_status "snapshot_too_large"
                  "Status exceeds the response limit")
    | "/api/v1/state", Get ->
        snapshot source (fun value -> rendered (json value))
    | "/api/v1/refresh", Post -> refresh source request.body
    | ("/" | "/api/v1/state"), _ -> method_error Get
    | "/api/v1/refresh", _ -> method_error Post
    | path, (Get | Post | Other _) -> (
        match detail_route path with
        | None -> not_found ()
        | Some identifier -> (
            match request.method_ with
            | Post | Other _ -> method_error Get
            | Get ->
                snapshot source (fun value ->
                    match Snapshot.find value identifier with
                    | None ->
                        error missing_status "issue_not_found"
                          "Issue is not currently owned"
                    | Some found -> rendered (detail found))))
end
