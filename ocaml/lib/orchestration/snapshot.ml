type session = {
  id : Session_id.t;
  thread : Thread_id.t;
  turn : Turn_id.t;
  turn_count : Positive_count.t;
  last_event : string;
  last_message : string option;
  last_event_at : Utc.t option;
  tokens : Usage.t;
}

type phase =
  | Awaiting
  | Preparing
  | Workspace_ready
  | Rendering
  | Starting
  | Streaming of session
  | Between_turns of session
  | Stopping_before_session
  | Stopping_session of session

type running = {
  issue : Issue.t;
  run_id : Run_id.t;
  attempt : Template.attempt;
  phase : phase;
  started_at : Utc.t option;
  seconds_running : Seconds.t;
  workspace : string option;
}

type retry_phase = Waiting of Utc.t option | Refreshing | Parked

type retry = {
  issue : Issue.t;
  retry_id : Retry_id.t;
  attempt : Positive_count.t;
  phase : retry_phase;
  error : Diagnostic.t option;
}

type data = {
  generated_at : Utc.t;
  running : running list;
  retrying : retry list;
  cleaning : Issue.t list;
  tokens : Usage.t;
  seconds_running : Seconds.t;
  rate_limits : Json.t option;
  workflow_error : Diagnostic.t option;
}

type t = data
type found = Running of running | Retrying of retry | Cleaning of Issue.t

let ( let* ) = Result.bind
let valid_optional = Option.fold ~none:true ~some:Text.valid_utf8

let diagnostic_text =
  Option.fold ~none:true ~some:(fun error ->
      Text.valid_utf8 (Diagnostic.render error))

let diagnostic_error = "snapshot: diagnostic text must be valid UTF-8"

let session_text (session : session) =
  Text.valid_utf8 session.last_event && valid_optional session.last_message

let running_text (running : running) =
  let session_valid =
    match running.phase with
    | Streaming session | Between_turns session | Stopping_session session ->
        session_text session
    | Awaiting
    | Preparing
    | Workspace_ready
    | Rendering
    | Starting
    | Stopping_before_session -> true
  in
  session_valid && valid_optional running.workspace

let check_owners issues =
  let add checked issue =
    let* ids, identifiers = checked in
    let id = Issue.id issue and identifier = Issue.identifier issue in
    if Issue_id.Set.mem id ids then Error "snapshot: duplicate issue ID"
    else if Issue_identifier.Set.mem identifier identifiers then
      Error "snapshot: duplicate issue identifier"
    else
      Ok
        ( Issue_id.Set.add id ids,
          Issue_identifier.Set.add identifier identifiers )
  in
  Result.map
    (fun _ -> ())
    (List.fold_left add
       (Ok (Issue_id.Set.empty, Issue_identifier.Set.empty))
       issues)

let check_runs running =
  List.fold_left
    (fun checked (row : running) ->
      let* seen = checked in
      if Run_id.Set.mem row.run_id seen then
        Error "snapshot: duplicate run generation"
      else if not (running_text row) then
        Error "snapshot: display text must be valid UTF-8"
      else Ok (Run_id.Set.add row.run_id seen))
    (Ok Run_id.Set.empty) running

let check_retries retrying =
  List.fold_left
    (fun checked (row : retry) ->
      let* seen = checked in
      if Retry_id.Set.mem row.retry_id seen then
        Error "snapshot: duplicate retry generation"
      else if not (diagnostic_text row.error) then Error diagnostic_error
      else Ok (Retry_id.Set.add row.retry_id seen))
    (Ok Retry_id.Set.empty) retrying

let make (data : data) =
  let issues =
    List.map (fun (row : running) -> row.issue) data.running
    @ List.map (fun (row : retry) -> row.issue) data.retrying
    @ data.cleaning
  in
  let* () = check_owners issues in
  let* _ = check_runs data.running in
  let* _ = check_retries data.retrying in
  if diagnostic_text data.workflow_error then Ok data
  else Error diagnostic_error

let data t = t
let counts t = (List.length t.running, List.length t.retrying)

let find t identifier =
  let matches issue =
    Issue_identifier.equal (Issue.identifier issue) identifier
  in
  match List.find_opt (fun (row : running) -> matches row.issue) t.running with
  | Some row -> Some (Running row)
  | None -> (
      match
        List.find_opt (fun (row : retry) -> matches row.issue) t.retrying
      with
      | Some row -> Some (Retrying row)
      | None ->
          Option.map
            (fun issue -> Cleaning issue)
            (List.find_opt matches t.cleaning))
