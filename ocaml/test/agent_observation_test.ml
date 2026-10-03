module F = Core_fixture
module A = F.Agent
module O = Agent_observation.Make (Clock.Pure) (A)
module M = Agent_observation_model

let samples = 1_000
let maximum_reports = 30
let thread_name = "thread:one"
let first_turn = "turn:one"
let second_turn = "turn:two"

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let check_bool message expected actual =
  if not (Bool.equal expected actual) then Alcotest.fail message

let check_option message expected actual =
  if not (Option.equal String.equal expected actual) then Alcotest.fail message

let count value = checked (Count.parse (Z.to_string value))
let positive value = checked (Positive_count.parse (Z.to_string value))
let thread value = checked (Thread_id.parse value)
let turn value = checked (Turn_id.parse value)
let session thread turn = checked (Session_id.parse (thread ^ "-" ^ turn))
let settings = F.Config.agent (F.config F.A)
let run, allocator = Run_id.Allocator.fresh Run_id.Allocator.empty
let other_run, _ = Run_id.Allocator.fresh allocator

let workspace_notice =
  let module L = Lifecycle_fixture in
  let issue = L.issue ~id:"observation" ~identifier:"OBS-1" () in
  let plan = L.plan (L.config L.Original) ~run ~issue ~attempt:Template.First in
  F.with_path
    (A.workspace (L.Plan.request plan))
    (fun path -> A.Workspace_ready path)

let usage (value : M.totals) =
  Usage.make ~input:(count value.M.input) ~output:(count value.M.output)
    ~total:(count value.M.total)

let totals input output total =
  { M.input = Z.of_int input; output = Z.of_int output; total = Z.of_int total }

let model_totals value =
  {
    M.input = Z.of_string (Count.decimal (Usage.input value));
    output = Z.of_string (Count.decimal (Usage.output value));
    total = Z.of_string (Count.decimal (Usage.total value));
  }

let same_totals (left : M.totals) (right : M.totals) =
  Z.equal left.M.input right.M.input
  && Z.equal left.M.output right.M.output
  && Z.equal left.M.total right.M.total

let normalize = function
  | A.Preparing -> M.Preparing
  | A.Workspace_ready _ -> M.Workspace_ready
  | A.Rendering -> M.Rendering
  | A.Starting -> M.Starting
  | A.Protocol event -> (
      match event with
      | Agent_runner.Session_started { session; thread; turn } ->
          M.Session_started
            {
              session = Session_id.text session;
              thread = Thread_id.text thread;
              turn = Turn_id.text turn;
            }
      | Agent_runner.Turn_started { session; turn } ->
          M.Turn_started
            { session = Session_id.text session; turn = Turn_id.text turn }
      | Agent_runner.Turn_completed { session; turn } ->
          M.Turn_completed
            { session = Session_id.text session; turn = Turn_id.text turn }
      | Agent_runner.Output { session; event_name; message } ->
          M.Output
            { session = Session_id.text session; name = event_name; message }
      | Agent_runner.Usage_report { thread; turn; absolute } ->
          M.Usage_report
            {
              thread = Thread_id.text thread;
              turn = Turn_id.text turn;
              absolute = model_totals absolute;
            }
      | Agent_runner.Rate_limits value -> M.Rate_limits (Json.encode value)
      | Agent_runner.Unsupported_tool { name; _ } -> M.Unsupported_tool name)

let phase = function
  | Agent_observation.Awaiting -> "awaiting"
  | Agent_observation.Preparing -> "preparing"
  | Agent_observation.Workspace_ready -> "workspace_ready"
  | Agent_observation.Rendering -> "rendering"
  | Agent_observation.Starting -> "starting"
  | Agent_observation.Running -> "running"
  | Agent_observation.Turn_completed -> "turn_completed"
  | Agent_observation.Continuation_queued -> "continuation_queued"
  | Agent_observation.Turn_answered -> "turn_answered"

let error = function
  | Agent_observation.Wrong_phase -> M.Wrong_phase
  | Agent_observation.Wrong_session -> M.Wrong_session
  | Agent_observation.Wrong_thread -> M.Wrong_thread
  | Agent_observation.Wrong_turn -> M.Wrong_turn
  | Agent_observation.Wrong_run -> M.Wrong_run
  | Agent_observation.Future_time -> M.Future_time
  | Agent_observation.Regressing_time -> M.Regressing_time
  | Agent_observation.Turn_limit -> M.Turn_limit

let acceptance = function
  | Agent_observation.Accepted -> M.Accepted
  | Agent_observation.Ignored -> M.Ignored

let same_json expected actual =
  match (expected, actual) with
  | None, None -> true
  | Some raw, Some value -> Json.equal (checked (Json.parse raw)) value
  | None, Some _ | Some _, None -> false

let agrees expected actual =
  let expected = M.view expected and actual = O.view actual in
  Z.equal expected.M.sequence (Z.of_string (Count.decimal actual.O.sequence))
  && String.equal expected.M.phase (phase actual.O.phase)
  && Option.equal String.equal expected.M.session
       (Option.map Session_id.text actual.O.session)
  && Option.equal String.equal expected.M.thread
       (Option.map Thread_id.text actual.O.thread)
  && Option.equal String.equal expected.M.turn
       (Option.map Turn_id.text actual.O.turn)
  && Z.equal
       (Z.of_int expected.M.turn_count)
       (Z.of_string (Count.decimal actual.O.turn_count))
  && Option.equal String.equal expected.M.last_event actual.O.last_event
  && Option.equal String.equal expected.M.last_message actual.O.last_message
  && Option.equal
       (fun left right -> Clock.Pure.compare left right = 0)
       (Option.map F.instant expected.M.last_activity)
       actual.O.last_activity
  && same_totals expected.M.usage (model_totals actual.O.usage)
  && same_json expected.M.rate_limits actual.O.rate_limits

type harness = { actual : O.t; expected : M.t }
type verdict = Accepted | Ignored | Rejected of M.error

let initial () =
  {
    actual = O.empty settings;
    expected = M.empty ~max_turns:(Agent_settings.max_turns settings);
  }

let assert_view harness =
  check_bool "production facts equal accepted-history oracle" true
    (agrees harness.expected harness.actual)

let send ?(worker = run) ~sequence ~emitted ~now harness notice =
  let sequence = Z.of_int sequence in
  let expected =
    M.observe harness.expected
      {
        M.run = Run_id.text worker;
        sequence;
        emitted;
        now;
        event = normalize notice;
      }
  in
  let actual =
    O.observe harness.actual ~run:worker ~now:(F.instant now)
      ~emitted_at:(F.instant emitted)
      (A.progress ~sequence:(positive sequence) notice)
  in
  match (expected, actual) with
  | Ok (expected, decision, delta), Ok (actual, observed, counted) ->
      check_bool "same acceptance" true (decision = acceptance observed);
      check_bool "token delta equals history growth" true
        (same_totals delta (model_totals counted));
      let next = { expected; actual } in
      assert_view next;
      let verdict =
        match decision with
        | M.Accepted -> Accepted
        | M.Ignored -> Ignored
      in
      (next, verdict)
  | Error expected, Error actual ->
      check_bool "same rejection" true (expected = error actual);
      assert_view harness;
      (harness, Rejected expected)
  | Error _, Ok _ -> Alcotest.fail "Production accepted rejected oracle input"
  | Ok _, Error actual ->
      Alcotest.fail
        ("Production rejected accepted oracle input: "
        ^ Agent_observation.message actual)

let expect verdict (harness, actual) =
  check_bool "expected event disposition" true (verdict = actual);
  harness

let emit ?worker ?emitted ?now ~sequence harness notice =
  let emitted = Option.value ~default:sequence emitted in
  let now = Option.value ~default:emitted now in
  send ?worker ~sequence ~emitted ~now harness notice

let accept ?worker ?emitted ?now ~sequence harness notice =
  expect Accepted (emit ?worker ?emitted ?now ~sequence harness notice)

let prepare harness =
  let harness = accept ~sequence:1 harness A.Preparing in
  let harness = accept ~sequence:2 harness workspace_notice in
  let harness = accept ~sequence:3 harness A.Rendering in
  accept ~sequence:4 harness A.Starting

let started turn_name =
  A.Protocol
    (Agent_runner.Session_started
       {
         session = session thread_name turn_name;
         thread = thread thread_name;
         turn = turn turn_name;
       })

let next_turn turn_name =
  A.Protocol
    (Agent_runner.Turn_started
       { session = session thread_name turn_name; turn = turn turn_name })

let completed turn_name =
  A.Protocol
    (Agent_runner.Turn_completed
       { session = session thread_name turn_name; turn = turn turn_name })

let output ?(thread = thread_name) ?(turn = first_turn) ?message name =
  A.Protocol
    (Agent_runner.Output
       { session = session thread turn; event_name = name; message })

let report ?(thread_name = thread_name) ?(turn_name = first_turn) value =
  A.Protocol
    (Agent_runner.Usage_report
       {
         thread = thread thread_name;
         turn = turn turn_name;
         absolute = usage value;
       })

let running () = accept ~sequence:5 (prepare (initial ())) (started first_turn)

let queue harness turn_name =
  let expected = M.queue harness.expected ~turn:turn_name in
  let actual = O.queue harness.actual ~turn:(turn turn_name) in
  match (expected, actual) with
  | Ok (expected, decision), Ok (actual, observed) -> (
      check_bool "same queue decision" true (decision = acceptance observed);
      let next = { expected; actual } in
      assert_view next;
      check_option "same refresh need" (M.need expected)
        (Option.map Turn_id.text (O.need actual));
      ( next,
        match decision with
        | M.Accepted -> Accepted
        | M.Ignored -> Ignored ))
  | Error expected, Error actual ->
      check_bool "same queue rejection" true (expected = error actual);
      assert_view harness;
      (harness, Rejected expected)
  | Error _, Ok _ | Ok _, Error _ ->
      Alcotest.fail "Queue differs from history oracle"

let answer harness turn_name =
  match
    ( M.answer harness.expected ~turn:turn_name,
      O.answer harness.actual ~turn:(turn turn_name) )
  with
  | Ok expected, Ok actual ->
      let next = { expected; actual } in
      assert_view next;
      next
  | Error expected, Error actual ->
      check_bool "same answer rejection" true (expected = error actual);
      harness
  | Error _, Ok _ | Ok _, Error _ ->
      Alcotest.fail "Answer differs from history oracle"

let continuation harness ~sequence turn_name =
  let harness = accept ~sequence harness (completed turn_name) in
  let harness = expect Accepted (queue harness turn_name) in
  answer harness turn_name

let preparation_examples () =
  let harness = initial () in
  assert_view harness;
  let harness =
    expect (Rejected M.Wrong_phase)
      (emit ~sequence:1 harness (started first_turn))
  in
  let harness =
    expect (Rejected M.Wrong_phase) (emit ~sequence:1 harness workspace_notice)
  in
  let harness = accept ~sequence:1 harness A.Preparing in
  let harness =
    expect (Rejected M.Wrong_phase) (emit ~sequence:2 harness A.Rendering)
  in
  let harness = accept ~sequence:2 harness workspace_notice in
  let harness = accept ~sequence:3 harness A.Rendering in
  let harness = accept ~sequence:4 harness A.Starting in
  let malformed =
    A.Protocol
      (Agent_runner.Session_started
         {
           session = checked (Session_id.parse "crossed-session");
           thread = thread thread_name;
           turn = turn first_turn;
         })
  in
  let harness =
    expect (Rejected M.Wrong_session) (emit ~sequence:5 harness malformed)
  in
  check_option "preparation has no Codex activity" None
    (Option.map (fun _ -> "activity") (O.view harness.actual).O.last_activity);
  let rates = checked (Json.parse "{\"remaining\":3,\"window\":null}") in
  let harness =
    accept ~sequence:5 harness (A.Protocol (Agent_runner.Rate_limits rates))
  in
  let harness = accept ~sequence:6 harness (started first_turn) in
  check_bool "global rate payload survives session start" true
    (same_json (Some (Json.encode rates)) (O.view harness.actual).O.rate_limits);
  let changed = checked (Json.parse "{\"remaining\":0,\"window\":30}") in
  let harness =
    accept ~sequence:7 harness (A.Protocol (Agent_runner.Rate_limits changed))
  in
  let harness =
    expect Ignored
      (emit ~sequence:6 harness (A.Protocol (Agent_runner.Rate_limits rates)))
  in
  check_bool "stale rate payload cannot replace current observation" true
    (same_json
       (Some (Json.encode changed))
       (O.view harness.actual).O.rate_limits);
  let harness =
    accept ~sequence:8 harness
      (A.Protocol
         (Agent_runner.Unsupported_tool
            { name = "unavailable-tool"; diagnostic = F.diagnostic }))
  in
  check_option "unsupported tool retains its checked name"
    (Some "unavailable-tool") (O.view harness.actual).O.last_message

let identity_examples () =
  let harness = running () in
  let notices =
    [
      (M.Wrong_session, output ~thread:"thread:other" "output");
      (M.Wrong_thread, report ~thread_name:"thread:other" (totals 99 99 99));
      (M.Wrong_turn, report ~turn_name:"turn:other" (totals 99 99 99));
      ( M.Wrong_turn,
        A.Protocol
          (Agent_runner.Turn_completed
             {
               session = session thread_name first_turn;
               turn = turn "turn:other";
             }) );
    ]
  in
  let harness =
    List.fold_left
      (fun harness (error, notice) ->
        expect (Rejected error) (emit ~sequence:6 harness notice))
      harness notices
  in
  let harness =
    expect (Rejected M.Wrong_run)
      (emit ~worker:other_run ~sequence:6 harness (report (totals 99 99 99)))
  in
  let harness = accept ~sequence:6 harness (report (totals 2 3 11)) in
  check_bool "crossed identities do not poison accounting" true
    (same_totals (totals 2 3 11) (model_totals (O.view harness.actual).O.usage))

let causal_examples () =
  let harness = running () in
  let harness =
    accept ~sequence:9 ~emitted:10 ~now:15 harness
      (output ~message:"current" "item/output")
  in
  let ignored = report (totals 100 100 100) in
  let harness =
    expect Ignored (emit ~sequence:9 ~emitted:100 ~now:20 harness ignored)
  in
  let harness =
    expect Ignored (emit ~sequence:6 ~emitted:1 ~now:20 harness ignored)
  in
  let harness =
    expect (Rejected M.Future_time)
      (emit ~sequence:10 ~emitted:21 ~now:20 harness ignored)
  in
  let harness =
    expect (Rejected M.Regressing_time)
      (emit ~sequence:10 ~emitted:9 ~now:20 harness ignored)
  in
  let harness =
    accept ~sequence:10 ~emitted:10 ~now:20 harness (report (totals 1 2 8))
  in
  check_bool "activity uses emission time, not owner dequeue time" true
    (match (O.view harness.actual).O.last_activity with
    | Some instant -> Clock.Pure.compare instant (F.instant 10) = 0
    | None -> false)

let barrier_examples () =
  let harness = running () in
  let harness = expect (Rejected M.Wrong_phase) (queue harness first_turn) in
  let harness = accept ~sequence:6 harness (completed first_turn) in
  let harness =
    expect Ignored (emit ~sequence:7 harness (completed first_turn))
  in
  let harness = expect Accepted (queue harness first_turn) in
  let harness = expect (Rejected M.Wrong_turn) (queue harness "turn:other") in
  let harness = answer harness "turn:other" in
  let harness = expect Ignored (queue harness first_turn) in
  let harness =
    expect Ignored (emit ~sequence:7 harness (completed first_turn))
  in
  let harness =
    expect (Rejected M.Wrong_phase)
      (emit ~sequence:7 harness (next_turn second_turn))
  in
  let harness = answer harness first_turn in
  let harness = answer harness first_turn in
  let harness = expect Ignored (queue harness first_turn) in
  let harness =
    expect Ignored (emit ~sequence:7 harness (completed first_turn))
  in
  let harness =
    expect Ignored (emit ~sequence:7 harness (next_turn first_turn))
  in
  let harness = accept ~sequence:7 harness (next_turn second_turn) in
  let harness =
    expect (Rejected M.Wrong_session)
      (emit ~sequence:8 harness (output "stale-output"))
  in
  let harness = continuation harness ~sequence:8 second_turn in
  let harness =
    expect (Rejected M.Wrong_turn)
      (emit ~sequence:9 harness (next_turn first_turn))
  in
  check_option "answered barrier cleared by next turn" None
    (Option.map Turn_id.text (O.need harness.actual));
  Alcotest.(check string)
    "same thread retained" thread_name
    (match (O.view harness.actual).O.thread with
    | Some value -> Thread_id.text value
    | None -> Alcotest.fail "Missing thread")

let usage_examples () =
  let harness = running () in
  let harness = accept ~sequence:6 harness (report (totals 10 20 17)) in
  let harness = accept ~sequence:7 harness (report (totals 8 25 9)) in
  let harness = accept ~sequence:8 harness (report (totals 8 25 9)) in
  let harness = accept ~sequence:9 harness (report (totals 10 20 17)) in
  let harness = continuation harness ~sequence:10 first_turn in
  let harness = accept ~sequence:11 harness (next_turn second_turn) in
  let harness =
    accept ~sequence:12 harness
      (output ~turn:second_turn ~message:"new" "new-output")
  in
  let before = O.view harness.actual in
  let harness =
    accept ~sequence:13 ~emitted:20 harness (report (totals 15 22 19))
  in
  let after = O.view harness.actual in
  check_option "old-turn usage preserves latest event" before.O.last_event
    after.O.last_event;
  check_option "old-turn usage preserves latest message" before.O.last_message
    after.O.last_message;
  check_bool "old-turn usage preserves current activity" true
    (Option.equal
       (fun left right -> Clock.Pure.compare left right = 0)
       before.O.last_activity after.O.last_activity);
  let harness =
    accept ~sequence:14 ~emitted:20 harness
      (report ~turn_name:second_turn (totals 12 28 18))
  in
  check_bool "same-thread reports telescope across turns" true
    (same_totals (totals 15 28 19)
       (model_totals (O.view harness.actual).O.usage));
  ignore
    (expect (Rejected M.Wrong_turn)
       (emit ~sequence:15 ~emitted:21 harness
          (report ~turn_name:"never-started" (totals 999 999 999))))

let turn_limit_examples () =
  let maximum = Agent_settings.max_turns settings in
  let rec advance number sequence harness current =
    let harness = continuation harness ~sequence current in
    let next = "turn:" ^ string_of_int (number + 1) in
    if number = maximum then
      expect (Rejected M.Turn_limit)
        (emit ~sequence:(sequence + 1) harness (next_turn next))
    else
      let harness = accept ~sequence:(sequence + 1) harness (next_turn next) in
      advance (number + 1) (sequence + 2) harness next
  in
  let harness = advance 1 6 (running ()) first_turn in
  Alcotest.(check string)
    "accepted turns stay within frozen cap" (string_of_int maximum)
    (Count.decimal (O.view harness.actual).O.turn_count)

let totals_generator =
  let natural =
    QCheck2.Gen.(
      oneof
        [
          map Z.of_int (int_range 0 1_000_000);
          map (fun exponent -> Z.shift_left Z.one exponent) (int_range 0 256);
        ])
  in
  QCheck2.Gen.(
    map
      (fun (input, (output, total)) -> { M.input; output; total })
      (pair natural (pair natural natural)))

let usage_history reports =
  let rec process harness sequence = function
    | [] -> harness
    | report_value :: rest ->
        let notice = report report_value in
        let harness = accept ~sequence harness notice in
        let harness =
          expect Ignored
            (emit ~sequence ~emitted:(sequence + 50) ~now:sequence harness
               notice)
        in
        process harness (sequence + 1) rest
  in
  let harness = process (running ()) 6 reports in
  agrees harness.expected harness.actual

let mixed_history actions =
  let harness = continuation (running ()) ~sequence:6 first_turn in
  let harness = accept ~sequence:7 harness (next_turn second_turn) in
  let rec process harness sequence = function
    | [] -> harness
    | (kind, value) :: rest ->
        let current = report ~turn_name:second_turn value in
        let verdict, sequence_used, emitted, notice =
          match kind with
          | 0 -> (Accepted, sequence, sequence, report value)
          | 1 -> (Accepted, sequence, sequence, current)
          | 2 -> (Ignored, sequence - 1, sequence + 50, current)
          | 3 -> (Rejected M.Future_time, sequence, sequence + 1, current)
          | 4 -> (Rejected M.Regressing_time, sequence, 0, current)
          | 5 ->
              ( Rejected M.Wrong_thread,
                sequence,
                sequence,
                report ~thread_name:"other-thread" ~turn_name:second_turn value
              )
          | 6 ->
              ( Rejected M.Wrong_turn,
                sequence,
                sequence,
                report ~turn_name:"never-started" value )
          | 7 ->
              ( Rejected M.Wrong_session,
                sequence,
                sequence,
                output "retired-output" )
          | _ ->
              ( Accepted,
                sequence,
                sequence,
                output ~turn:second_turn ~message:"current" "current-output" )
        in
        let harness =
          expect verdict
            (emit ~sequence:sequence_used ~emitted ~now:sequence harness notice)
        in
        let next_sequence =
          if verdict = Accepted then sequence + 1 else sequence
        in
        process harness next_sequence rest
  in
  let harness = process harness 8 actions in
  agrees harness.expected harness.actual

let properties =
  [
    QCheck2.Test.make
      ~name:"Observation equals complete accepted report history" ~count:samples
      QCheck2.Gen.(list_size (int_range 0 maximum_reports) totals_generator)
      usage_history;
    QCheck2.Test.make
      ~name:"Mixed-turn histories preserve causal and identity fences"
      ~count:samples
      QCheck2.Gen.(
        list_size
          (int_range 0 maximum_reports)
          (pair (int_range 0 8) totals_generator))
      mixed_history;
  ]

let tests =
  [
    Alcotest.test_case "Ordered preparation and global rate payload" `Quick
      preparation_examples;
    Alcotest.test_case "Protocol and worker identity fences" `Quick
      identity_examples;
    Alcotest.test_case "Causal sequence and emission timestamps" `Quick
      causal_examples;
    Alcotest.test_case "Completed queued answered continuation barrier" `Quick
      barrier_examples;
    Alcotest.test_case "Usage repeats reorder and prior-turn accounting" `Quick
      usage_examples;
    Alcotest.test_case "Frozen turn cap" `Quick turn_limit_examples;
  ]
