type totals = { input : Z.t; output : Z.t; total : Z.t }

type event =
  | Preparing
  | Workspace_ready
  | Rendering
  | Starting
  | Session_started of { session : string; thread : string; turn : string }
  | Turn_started of { session : string; turn : string }
  | Turn_completed of { session : string; turn : string }
  | Output of { session : string; name : string; message : string option }
  | Usage_report of { thread : string; turn : string; absolute : totals }
  | Rate_limits of string
  | Unsupported_tool of string

type progress = {
  run : string;
  sequence : Z.t;
  emitted : int;
  now : int;
  event : event;
}

type acceptance = Accepted | Ignored

type error =
  | Wrong_phase
  | Wrong_session
  | Wrong_thread
  | Wrong_turn
  | Wrong_run
  | Future_time
  | Regressing_time
  | Turn_limit

type entry = Observed of progress | Queued of string | Answered of string
type t = { max_turns : int; entries : entry list }

type view = {
  sequence : Z.t;
  phase : string;
  session : string option;
  thread : string option;
  turn : string option;
  turn_count : int;
  last_event : string option;
  last_message : string option;
  last_activity : int option;
  usage : totals;
  rate_limits : string option;
}

let zero = { input = Z.zero; output = Z.zero; total = Z.zero }
let empty ~max_turns = { max_turns; entries = [] }

let reports entries =
  List.filter_map
    (function
      | Observed { event = Usage_report { absolute; _ }; _ } -> Some absolute
      | Observed
          {
            event =
              ( Preparing
              | Workspace_ready
              | Rendering
              | Starting
              | Session_started _
              | Turn_started _
              | Turn_completed _
              | Output _
              | Rate_limits _
              | Unsupported_tool _ );
            _;
          }
      | Queued _ | Answered _ -> None)
    entries

let supremum values =
  let field project = List.fold_left Z.max Z.zero (List.map project values) in
  {
    input = field (fun value -> value.input);
    output = field (fun value -> value.output);
    total = field (fun value -> value.total);
  }

let difference before after =
  {
    input = Z.sub after.input before.input;
    output = Z.sub after.output before.output;
    total = Z.sub after.total before.total;
  }

let phase entries =
  List.find_map
    (function
      | Queued _ -> Some "continuation_queued"
      | Answered _ -> Some "turn_answered"
      | Observed { event; _ } -> (
          match event with
          | Preparing -> Some "preparing"
          | Workspace_ready -> Some "workspace_ready"
          | Rendering -> Some "rendering"
          | Starting -> Some "starting"
          | Session_started _ | Turn_started _ -> Some "running"
          | Turn_completed _ -> Some "turn_completed"
          | Output _ | Usage_report _ | Rate_limits _ | Unsupported_tool _ ->
              None))
    entries
  |> Option.value ~default:"awaiting"

let identity entries =
  let session_turn =
    List.find_map
      (function
        | Observed { event = Session_started { session; turn; _ }; _ }
        | Observed { event = Turn_started { session; turn }; _ } ->
            Some (session, turn)
        | Observed
            {
              event =
                ( Preparing
                | Workspace_ready
                | Rendering
                | Starting
                | Turn_completed _
                | Output _
                | Usage_report _
                | Rate_limits _
                | Unsupported_tool _ );
              _;
            }
        | Queued _ | Answered _ -> None)
      entries
  in
  let thread_run =
    List.find_map
      (function
        | Observed { run; event = Session_started { thread; _ }; _ } ->
            Some (thread, run)
        | Observed
            {
              event =
                ( Preparing
                | Workspace_ready
                | Rendering
                | Starting
                | Turn_started _
                | Turn_completed _
                | Output _
                | Usage_report _
                | Rate_limits _
                | Unsupported_tool _ );
              _;
            }
        | Queued _ | Answered _ -> None)
      entries
  in
  (session_turn, thread_run)

let turns entries =
  List.filter_map
    (function
      | Observed { event = Session_started { turn; _ }; _ }
      | Observed { event = Turn_started { turn; _ }; _ } -> Some turn
      | Observed
          {
            event =
              ( Preparing
              | Workspace_ready
              | Rendering
              | Starting
              | Turn_completed _
              | Output _
              | Usage_report _
              | Rate_limits _
              | Unsupported_tool _ );
            _;
          }
      | Queued _ | Answered _ -> None)
    entries

let sequence entries =
  List.find_map
    (function
      | Observed value -> Some value.sequence
      | Queued _ | Answered _ -> None)
    entries
  |> Option.value ~default:Z.zero

let emitted entries =
  List.find_map
    (function
      | Observed value -> Some value.emitted
      | Queued _ | Answered _ -> None)
    entries

let session_phase phase =
  List.mem phase
    [ "running"; "turn_completed"; "continuation_queued"; "turn_answered" ]

let current_usage entries progress =
  match progress.event with
  | Usage_report { turn; _ } -> (
      match fst (identity entries) with
      | Some (_, current) ->
          String.equal (phase entries) "running" && String.equal turn current
      | None -> false)
  | Preparing
  | Workspace_ready
  | Rendering
  | Starting
  | Session_started _
  | Turn_started _
  | Turn_completed _
  | Output _
  | Rate_limits _
  | Unsupported_tool _ -> true

let display progress =
  match progress.event with
  | Preparing -> ("preparing", None)
  | Workspace_ready -> ("workspace_ready", None)
  | Rendering -> ("rendering", None)
  | Starting -> ("starting", None)
  | Session_started _ -> ("session_started", None)
  | Turn_started _ -> ("turn_started", None)
  | Turn_completed _ -> ("turn_completed", None)
  | Output { name; message; _ } -> (name, message)
  | Usage_report _ -> ("usage_report", None)
  | Rate_limits _ -> ("rate_limits", None)
  | Unsupported_tool name -> ("unsupported_tool", Some name)

let protocol = function
  | Preparing | Workspace_ready | Rendering | Starting -> false
  | Session_started _
  | Turn_started _
  | Turn_completed _
  | Output _
  | Usage_report _
  | Rate_limits _
  | Unsupported_tool _ -> true

let facts entries =
  (* Replay display authority at each report's accepted turn phase. The complete
     history remains the accounting and causal-clock oracle. *)
  let rec walk preceding = function
    | [] -> []
    | Observed progress :: rest ->
        let eligible = current_usage preceding progress in
        (progress, eligible) :: walk (Observed progress :: preceding) rest
    | ((Queued _ | Answered _) as entry) :: rest ->
        walk (entry :: preceding) rest
  in
  List.rev (walk [] (List.rev entries))

let view state =
  let session_turn, thread_run = identity state.entries in
  let facts = facts state.entries in
  let latest =
    List.find_map
      (fun (progress, eligible) ->
        if eligible then Some (display progress) else None)
      facts
  in
  let last_activity =
    List.find_map
      (fun (progress, eligible) ->
        if eligible && protocol progress.event then Some progress.emitted
        else None)
      facts
  in
  let rate_limits =
    List.find_map
      (function
        | Observed { event = Rate_limits value; _ } -> Some value
        | Observed
            {
              event =
                ( Preparing
                | Workspace_ready
                | Rendering
                | Starting
                | Session_started _
                | Turn_started _
                | Turn_completed _
                | Output _
                | Usage_report _
                | Unsupported_tool _ );
              _;
            }
        | Queued _ | Answered _ -> None)
      state.entries
  in
  {
    sequence = sequence state.entries;
    phase = phase state.entries;
    session = Option.map fst session_turn;
    thread = Option.map fst thread_run;
    turn = Option.map snd session_turn;
    turn_count = List.length (turns state.entries);
    last_event = Option.map fst latest;
    last_message = Option.bind latest snd;
    last_activity;
    usage = supremum (reports state.entries);
    rate_limits;
  }

let current state = fst (identity state.entries)
let combine thread turn = thread ^ "-" ^ turn

let session_error state session turn =
  match current state with
  | Some (known_session, known_turn) ->
      if not (String.equal session known_session) then Some Wrong_session
      else if not (String.equal turn known_turn) then Some Wrong_turn
      else None
  | None -> Some Wrong_phase

let admissible state event =
  let current_phase = phase state.entries in
  let same_stage expected =
    if String.equal current_phase expected then Ok Accepted
    else Error Wrong_phase
  in
  match event with
  | Preparing -> same_stage "awaiting"
  | Workspace_ready -> same_stage "preparing"
  | Rendering -> same_stage "workspace_ready"
  | Starting -> same_stage "rendering"
  | Session_started { session; thread; turn } ->
      if not (String.equal current_phase "starting") then Error Wrong_phase
      else if not (String.equal session (combine thread turn)) then
        Error Wrong_session
      else Ok Accepted
  | Turn_started { session; turn } -> (
      match (current state, snd (identity state.entries)) with
      | Some (known_session, known_turn), Some (thread, _) ->
          if not (String.equal session (combine thread turn)) then
            Error Wrong_session
          else if
            String.equal session known_session && String.equal turn known_turn
          then Ok Ignored
          else if List.mem turn (turns state.entries) then Error Wrong_turn
          else if not (String.equal current_phase "turn_answered") then
            Error Wrong_phase
          else if List.length (turns state.entries) >= state.max_turns then
            Error Turn_limit
          else Ok Accepted
      | _ -> Error Wrong_phase)
  | Turn_completed { session; turn } -> (
      match session_error state session turn with
      | Some error -> Error error
      | None ->
          if String.equal current_phase "running" then Ok Accepted
          else if session_phase current_phase then Ok Ignored
          else Error Wrong_phase)
  | Output { session; _ } -> (
      if not (session_phase current_phase) then Error Wrong_phase
      else
        match current state with
        | Some (known, _) when String.equal known session -> Ok Accepted
        | _ -> Error Wrong_session)
  | Usage_report { thread; turn; _ } -> (
      if not (session_phase current_phase) then Error Wrong_phase
      else
        match snd (identity state.entries) with
        | Some (known, _) when not (String.equal known thread) ->
            Error Wrong_thread
        | Some _ ->
            if List.mem turn (turns state.entries) then Ok Accepted
            else Error Wrong_turn
        | None -> Error Wrong_phase)
  | Rate_limits _ ->
      if String.equal current_phase "starting" || session_phase current_phase
      then Ok Accepted
      else Error Wrong_phase
  | Unsupported_tool _ ->
      if session_phase current_phase then Ok Accepted else Error Wrong_phase

let observe (state : t) (progress : progress) =
  if Z.compare progress.sequence (sequence state.entries) <= 0 then
    Ok (state, Ignored, zero)
  else if progress.emitted > progress.now then Error Future_time
  else if
    Option.fold ~none:false
      ~some:(fun previous -> progress.emitted < previous)
      (emitted state.entries)
  then Error Regressing_time
  else
    match snd (identity state.entries) with
    | Some (_, run) when not (String.equal run progress.run) -> Error Wrong_run
    | _ -> (
        match admissible state progress.event with
        | Error error -> Error error
        | Ok Ignored -> Ok (state, Ignored, zero)
        | Ok Accepted ->
            let next =
              { state with entries = Observed progress :: state.entries }
            in
            let delta =
              difference
                (supremum (reports state.entries))
                (supremum (reports next.entries))
            in
            Ok (next, Accepted, delta))

let queue state ~turn =
  match current state with
  | Some (_, known) when not (String.equal known turn) -> Error Wrong_turn
  | None -> Error Wrong_phase
  | Some _ -> (
      match phase state.entries with
      | "turn_completed" ->
          Ok ({ state with entries = Queued turn :: state.entries }, Accepted)
      | "continuation_queued" | "turn_answered" -> Ok (state, Ignored)
      | _ -> Error Wrong_phase)

let need state =
  if String.equal (phase state.entries) "continuation_queued" then
    Option.map snd (current state)
  else None

let answer state ~turn =
  match current state with
  | Some (_, known) when not (String.equal known turn) -> Error Wrong_turn
  | None -> Error Wrong_phase
  | Some _ -> (
      match phase state.entries with
      | "continuation_queued" ->
          Ok { state with entries = Answered turn :: state.entries }
      | "turn_answered" -> Ok state
      | _ -> Error Wrong_phase)
