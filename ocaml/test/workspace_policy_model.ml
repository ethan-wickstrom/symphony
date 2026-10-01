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
type response = Proceed | Fail of failure

type scenario = {
  initial : presence;
  operation : operation;
  respond : stage -> response;
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

let rec prefix scenario = function
  | [] -> ([], Returned)
  | stage :: rest -> (
      let call = Call (Normal stage) in
      match normal_result scenario stage with
      | Returned ->
          let trace, outcome = prefix scenario rest in
          (call :: trace, outcome)
      | (Errored _ | Cancelled _) as outcome -> ([ call ], outcome))

let observed_hook scenario stage =
  match scenario.respond stage with
  | Proceed -> [ Call stage ]
  | Fail failure -> [ Call stage; Report (stage, failure) ]

let deletion scenario =
  let hook = observed_hook scenario Before_remove in
  match scenario.respond Remove with
  | Proceed -> (Absent, Ok (), hook @ [ Call Remove ])
  | Fail failure -> (Present, Error (Remove, failure), hook @ [ Call Remove ])

let prepared initial =
  match initial with
  | Absent -> [ After_create; Before_run; Path ]
  | Present -> [ Before_run; Path ]

let attempt scenario =
  let opening = [ Call (Normal Acquire) ] in
  match normal_result scenario Acquire with
  | (Errored _ | Cancelled _) as outcome ->
      { presence = scenario.initial; outcome; trace = opening }
  | Returned ->
      let before, preparation = prefix scenario (prepared scenario.initial) in
      let call, outcome, rollback =
        match preparation with
        | Returned ->
            let call, outcome = prefix scenario [ Callback ] in
            (call, outcome, Present)
        | (Errored _ | Cancelled _) as outcome -> ([], outcome, scenario.initial)
      in
      let presence, suffix =
        match rollback with
        | Present -> (Present, [])
        | Absent ->
            let presence, result, trace = deletion scenario in
            let report =
              match result with
              | Ok () -> []
              | Error (stage, failure) -> [ Report (stage, failure) ]
            in
            (presence, trace @ report)
      in
      {
        presence;
        outcome;
        trace =
          opening @ before @ call @ [ Enter_cleanup ]
          @ observed_hook scenario After_run
          @ suffix @ [ Leave_cleanup; Release ];
      }

let cleanup scenario =
  let opening = [ Call (Normal Lookup) ] in
  match normal_result scenario Lookup with
  | (Errored _ | Cancelled _) as outcome ->
      { presence = scenario.initial; outcome; trace = opening }
  | Returned -> (
      match scenario.initial with
      | Absent -> { presence = Absent; outcome = Returned; trace = opening }
      | Present ->
          let presence, result, trace = deletion scenario in
          let outcome =
            match result with
            | Ok () -> Returned
            | Error (stage, failure) -> Errored (stage, failure)
          in
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
