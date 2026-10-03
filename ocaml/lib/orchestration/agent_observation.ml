type phase =
  | Awaiting
  | Preparing
  | Workspace_ready
  | Rendering
  | Starting
  | Running
  | Turn_completed
  | Continuation_queued
  | Turn_answered

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

let message = function
  | Wrong_phase -> "Agent observation does not follow its accepted phase"
  | Wrong_session -> "Agent observation belongs to a different session"
  | Wrong_thread -> "Agent observation belongs to a different thread"
  | Wrong_turn -> "Agent observation belongs to an unknown or different turn"
  | Wrong_run -> "Agent observation belongs to a different run"
  | Future_time -> "Agent emission time exceeds its owner observation time"
  | Regressing_time -> "Agent emission time regresses its accepted clock"
  | Turn_limit -> "Agent turn count exceeds its frozen turn limit"

module Make (Clock : Clock.PURE) (Agent : Agent_runner.PURE) = struct
  type preparation = Initial | Prepare | Ready | Render | Launch
  type barrier = In_turn | Completed | Queued | Answered

  type session = {
    run : Run_id.t;
    thread : Thread_id.t;
    turn : Turn_id.t;
    session : Session_id.t;
    turns : Turn_id.Set.t;
    turn_count : Count.t;
    barrier : barrier;
    watermark : Usage.watermark;
  }

  type state = Preparation of preparation | Session of session

  type t = {
    sequence : Count.t;
    emitted_at : Clock.instant option;
    state : state;
    max_turns : Count.t;
    last_event : string option;
    last_message : string option;
    last_activity : Clock.instant option;
    rate_limits : Json.t option;
  }

  type view = {
    sequence : Count.t;
    phase : phase;
    session : Session_id.t option;
    thread : Thread_id.t option;
    turn : Turn_id.t option;
    turn_count : Count.t;
    last_event : string option;
    last_message : string option;
    last_activity : Clock.instant option;
    usage : Usage.t;
    rate_limits : Json.t option;
  }

  let empty settings =
    {
      sequence = Count.zero;
      emitted_at = None;
      state = Preparation Initial;
      max_turns =
        Count.of_uint64_bits (Int64.of_int (Agent_settings.max_turns settings));
      last_event = None;
      last_message = None;
      last_activity = None;
      rate_limits = None;
    }

  let phase = function
    | Preparation Initial -> Awaiting
    | Preparation Prepare -> Preparing
    | Preparation Ready -> Workspace_ready
    | Preparation Render -> Rendering
    | Preparation Launch -> Starting
    | Session { barrier = In_turn; _ } -> Running
    | Session { barrier = Completed; _ } -> Turn_completed
    | Session { barrier = Queued; _ } -> Continuation_queued
    | Session { barrier = Answered; _ } -> Turn_answered

  let view (value : t) =
    let session, thread, turn, turn_count, usage =
      match value.state with
      | Preparation _ -> (None, None, None, Count.zero, Usage.zero)
      | Session current ->
          ( Some current.session,
            Some current.thread,
            Some current.turn,
            current.turn_count,
            Usage.absolute current.watermark )
    in
    {
      sequence = value.sequence;
      phase = phase value.state;
      session;
      thread;
      turn;
      turn_count;
      last_event = value.last_event;
      last_message = value.last_message;
      last_activity = value.last_activity;
      usage;
      rate_limits = value.rate_limits;
    }

  let session_agrees session thread turn =
    String.equal (Session_id.text session)
      (Thread_id.text thread ^ "-" ^ Turn_id.text turn)

  let display (value : t) event_name message =
    { value with last_event = Some event_name; last_message = message }

  let prepare (value : t) expected next event_name =
    match value.state with
    | Preparation current when current = expected ->
        Ok (display { value with state = Preparation next } event_name None)
    | Preparation _ | Session _ -> Error Wrong_phase

  let protocol (value : t) ~run ~emitted_at event =
    let finish next delta = Ok (next, Accepted, delta) in
    let active next name message =
      display { next with last_activity = Some emitted_at } name message
    in
    match event with
    | Agent_runner.Session_started { session; thread; turn } -> begin
        match value.state with
        | Preparation Launch ->
            if not (session_agrees session thread turn) then Error Wrong_session
            else
              let current =
                {
                  run;
                  thread;
                  turn;
                  session;
                  turns = Turn_id.Set.singleton turn;
                  turn_count = Count.one;
                  barrier = In_turn;
                  watermark = Usage.initial ~run ~thread;
                }
              in
              finish
                (active
                   { value with state = Session current }
                   "session_started" None)
                Usage.zero
        | Preparation (Initial | Prepare | Ready | Render) | Session _ ->
            Error Wrong_phase
      end
    | Agent_runner.Rate_limits payload -> begin
        match value.state with
        | Preparation Launch | Session _ ->
            finish
              (active
                 { value with rate_limits = Some payload }
                 "rate_limits" None)
              Usage.zero
        | Preparation (Initial | Prepare | Ready | Render) -> Error Wrong_phase
      end
    | Agent_runner.Turn_started { session; turn } -> begin
        match value.state with
        | Preparation _ -> Error Wrong_phase
        | Session current ->
            if not (session_agrees session current.thread turn) then
              Error Wrong_session
            else if Turn_id.equal current.turn turn then
              Ok (value, Ignored, Usage.zero)
            else if Turn_id.Set.mem turn current.turns then Error Wrong_turn
            else if current.barrier <> Answered then Error Wrong_phase
            else
              let turn_count = Count.add current.turn_count Count.one in
              if Count.compare turn_count value.max_turns > 0 then
                Error Turn_limit
              else
                let current =
                  {
                    current with
                    session;
                    turn;
                    turn_count;
                    turns = Turn_id.Set.add turn current.turns;
                    barrier = In_turn;
                  }
                in
                finish
                  (active
                     { value with state = Session current }
                     "turn_started" None)
                  Usage.zero
      end
    | Agent_runner.Turn_completed { session; turn } -> begin
        match value.state with
        | Preparation _ -> Error Wrong_phase
        | Session current ->
            if not (Session_id.equal current.session session) then
              Error Wrong_session
            else if not (Turn_id.equal current.turn turn) then Error Wrong_turn
            else if current.barrier <> In_turn then
              Ok (value, Ignored, Usage.zero)
            else
              finish
                (active
                   {
                     value with
                     state = Session { current with barrier = Completed };
                   }
                   "turn_completed" None)
                Usage.zero
      end
    | Agent_runner.Usage_report { thread; turn; absolute } -> begin
        match value.state with
        | Preparation _ -> Error Wrong_phase
        | Session current ->
            if not (Thread_id.equal current.thread thread) then
              Error Wrong_thread
            else if not (Turn_id.Set.mem turn current.turns) then
              Error Wrong_turn
            else begin
              match Usage.observe current.watermark ~run ~thread ~absolute with
              | Error _ -> Error Wrong_run
              | Ok (watermark, delta) ->
                  let next =
                    { value with state = Session { current with watermark } }
                  in
                  (* Late reports retain thread totals without renewing a
                     completed turn's display or silence deadline. *)
                  let next =
                    if
                      current.barrier = In_turn
                      && Turn_id.equal current.turn turn
                    then active next "usage_report" None
                    else next
                  in
                  finish next delta
            end
      end
    | Agent_runner.Output { session; event_name; message } -> begin
        match value.state with
        | Session current when Session_id.equal current.session session ->
            finish (active value event_name message) Usage.zero
        | Session _ -> Error Wrong_session
        | Preparation _ -> Error Wrong_phase
      end
    | Agent_runner.Unsupported_tool { name; _ } -> begin
        match value.state with
        | Session _ ->
            finish (active value "unsupported_tool" (Some name)) Usage.zero
        | Preparation _ -> Error Wrong_phase
      end

  let observe (value : t) ~run ~now ~emitted_at progress =
    let sequence = Positive_count.count (Agent.sequence progress) in
    if Count.compare sequence value.sequence <= 0 then
      Ok (value, Ignored, Usage.zero)
    else if Clock.compare emitted_at now > 0 then Error Future_time
    else if
      Option.fold ~none:false
        ~some:(fun previous -> Clock.compare emitted_at previous < 0)
        value.emitted_at
    then Error Regressing_time
    else if
      match value.state with
      | Session current -> not (Run_id.equal current.run run)
      | Preparation _ -> false
    then Error Wrong_run
    else
      let result =
        match Agent.notice progress with
        | Agent.Preparing ->
            Result.map
              (fun next -> (next, Accepted, Usage.zero))
              (prepare value Initial Prepare "preparing")
        | Agent.Workspace_ready _ ->
            Result.map
              (fun next -> (next, Accepted, Usage.zero))
              (prepare value Prepare Ready "workspace_ready")
        | Agent.Rendering ->
            Result.map
              (fun next -> (next, Accepted, Usage.zero))
              (prepare value Ready Render "rendering")
        | Agent.Starting ->
            Result.map
              (fun next -> (next, Accepted, Usage.zero))
              (prepare value Render Launch "starting")
        | Agent.Protocol event -> protocol value ~run ~emitted_at event
      in
      Result.map
        (function
          | next, Accepted, delta ->
              ( { next with sequence; emitted_at = Some emitted_at },
                Accepted,
                delta )
          | _, Ignored, _ -> (value, Ignored, Usage.zero))
        result

  let queue (value : t) ~turn =
    match value.state with
    | Preparation _ -> Error Wrong_phase
    | Session current when not (Turn_id.equal current.turn turn) ->
        Error Wrong_turn
    | Session { barrier = In_turn; _ } -> Error Wrong_phase
    | Session { barrier = Queued | Answered; _ } -> Ok (value, Ignored)
    | Session ({ barrier = Completed; _ } as current) ->
        Ok
          ( { value with state = Session { current with barrier = Queued } },
            Accepted )

  let need (value : t) =
    match value.state with
    | Session { barrier = Queued; turn; _ } -> Some turn
    | Preparation _ | Session { barrier = In_turn | Completed | Answered; _ } ->
        None

  let answer (value : t) ~turn =
    match value.state with
    | Preparation _ -> Error Wrong_phase
    | Session current when not (Turn_id.equal current.turn turn) ->
        Error Wrong_turn
    | Session { barrier = Answered; _ } -> Ok value
    | Session { barrier = In_turn | Completed; _ } -> Error Wrong_phase
    | Session ({ barrier = Queued; _ } as current) ->
        Ok { value with state = Session { current with barrier = Answered } }
end
