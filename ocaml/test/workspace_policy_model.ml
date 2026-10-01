type presence = Absent | Present
type operation = Attempt | Cleanup

type normal_stage =
  | Acquire
  | Lookup
  | After_create
  | Before_run
  | Path
  | Callback

type stage = Normal of normal_stage | After_run | Before_remove | Remove
type failure = Rejected | Timed_out
type response = Proceed | Fail of failure | Defect
type reporting = Observed | Reporter_defect
type fault = Operation_defect of stage | Reporting_defect of stage * failure

type scenario = {
  initial : presence;
  operation : operation;
  respond : stage -> response;
  report : stage -> failure -> reporting;
  cancel_at : normal_stage option;
}

type event =
  | Call of stage
  | Release
  | Enter_cleanup
  | Leave_cleanup
  | Report of stage * failure

type outcome =
  | Returned
  | Errored of stage * failure
  | Cancelled of normal_stage
  | Defected of fault

type observation = {
  presence : presence;
  outcome : outcome;
  trace : event list;
}

let normal_result scenario stage =
  if scenario.cancel_at = Some stage then Cancelled stage
  else
    match scenario.respond (Normal stage) with
    | Proceed -> Returned
    | Fail failure -> Errored (Normal stage, failure)
    | Defect -> Defected (Operation_defect (Normal stage))

let rec prefix scenario = function
  | [] -> ([], Returned)
  | stage :: rest -> (
      let call = Call (Normal stage) in
      match normal_result scenario stage with
      | Returned ->
          let trace, outcome = prefix scenario rest in
          (call :: trace, outcome)
      | (Errored _ | Cancelled _ | Defected _) as outcome -> ([ call ], outcome)
      )

let primary first second =
  match first with
  | Returned -> second
  | Errored _ | Cancelled _ | Defected _ -> first

let reported scenario stage failure =
  let outcome =
    match scenario.report stage failure with
    | Observed -> Returned
    | Reporter_defect -> Defected (Reporting_defect (stage, failure))
  in
  ([ Report (stage, failure) ], outcome)

let observed_hook scenario stage =
  match scenario.respond stage with
  | Proceed -> ([ Call stage ], Returned)
  | Fail failure ->
      let trace, outcome = reported scenario stage failure in
      (Call stage :: trace, outcome)
  | Defect -> ([ Call stage ], Defected (Operation_defect stage))

let deletion scenario =
  let trace, hook = observed_hook scenario Before_remove in
  let presence, removal =
    match scenario.respond Remove with
    | Proceed -> (Absent, Returned)
    | Fail failure -> (Present, Errored (Remove, failure))
    | Defect -> (Present, Defected (Operation_defect Remove))
  in
  (presence, primary removal hook, trace @ [ Call Remove ])

let prepared initial =
  match initial with
  | Absent -> [ After_create; Before_run; Path ]
  | Present -> [ Before_run; Path ]

let attempt scenario =
  let opening = [ Call (Normal Acquire) ] in
  match normal_result scenario Acquire with
  | (Errored _ | Cancelled _ | Defected _) as outcome ->
      { presence = scenario.initial; outcome; trace = opening }
  | Returned ->
      let before, preparation = prefix scenario (prepared scenario.initial) in
      let call, outcome, rollback =
        match preparation with
        | Returned ->
            let call, outcome = prefix scenario [ Callback ] in
            (call, outcome, Present)
        | (Errored _ | Cancelled _ | Defected _) as outcome ->
            ([], outcome, scenario.initial)
      in
      let after, after_outcome = observed_hook scenario After_run in
      let presence, suffix, rollback_outcome =
        match rollback with
        | Present -> (Present, [], Returned)
        | Absent ->
            let presence, result, trace = deletion scenario in
            let report, cleanup_outcome =
              match result with
              | Returned -> ([], Returned)
              | Errored (stage, failure) -> reported scenario stage failure
              | Defected _ | Cancelled _ -> ([], result)
            in
            (presence, trace @ report, cleanup_outcome)
      in
      {
        presence;
        outcome = primary outcome (primary after_outcome rollback_outcome);
        trace =
          opening @ before @ call @ [ Enter_cleanup ] @ after @ suffix
          @ [ Leave_cleanup; Release ];
      }

let cleanup scenario =
  let opening = [ Call (Normal Lookup) ] in
  match normal_result scenario Lookup with
  | (Errored _ | Cancelled _ | Defected _) as outcome ->
      { presence = scenario.initial; outcome; trace = opening }
  | Returned -> (
      match scenario.initial with
      | Absent -> { presence = Absent; outcome = Returned; trace = opening }
      | Present ->
          let presence, outcome, trace = deletion scenario in
          {
            presence;
            outcome;
            trace =
              opening @ [ Enter_cleanup ] @ trace @ [ Leave_cleanup; Release ];
          })

let run scenario =
  match scenario.operation with
  | Attempt -> attempt scenario
  | Cleanup -> cleanup scenario

let equal (first : observation) second = first = second

let normal_name = function
  | Acquire -> "acquire"
  | Lookup -> "lookup"
  | After_create -> "after_create"
  | Before_run -> "before_run"
  | Path -> "path"
  | Callback -> "callback"

let stage_name = function
  | Normal stage -> normal_name stage
  | After_run -> "after_run"
  | Before_remove -> "before_remove"
  | Remove -> "remove"

let failure_name = function
  | Rejected -> "rejected"
  | Timed_out -> "timed_out"

let outcome_name = function
  | Returned -> "returned"
  | Errored (stage, failure) -> stage_name stage ^ ":" ^ failure_name failure
  | Cancelled stage -> normal_name stage ^ ":cancelled"
  | Defected (Operation_defect stage) -> stage_name stage ^ ":defect"
  | Defected (Reporting_defect (stage, failure)) ->
      "report(" ^ stage_name stage ^ ":" ^ failure_name failure ^ "):defect"

let event_name = function
  | Call stage -> stage_name stage
  | Release -> "release"
  | Enter_cleanup -> "cleanup.enter"
  | Leave_cleanup -> "cleanup.leave"
  | Report (stage, failure) ->
      "report(" ^ stage_name stage ^ ":" ^ failure_name failure ^ ")"

let show observation =
  let presence =
    match observation.presence with
    | Absent -> "absent"
    | Present -> "present"
  in
  presence ^ "; "
  ^ outcome_name observation.outcome
  ^ "; ["
  ^ String.concat ", " (List.map event_name observation.trace)
  ^ "]"
