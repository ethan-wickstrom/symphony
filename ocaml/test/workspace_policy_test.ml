module Model = Workspace_policy_model

module Path = struct
  type t = Checked

  let display Checked = "/checked/workspace"
end

module Reference = Workspace_reference.Make (Path)

exception Cancelled of Model.normal_stage

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let normal_stages =
  Model.[ Acquire; Lookup; After_create; Before_run; Path; Callback ]

let stages =
  List.map (fun stage -> Model.Normal stage) normal_stages
  @ Model.[ After_run; Before_remove; Remove ]

let error stage failure =
  let observation : Model.observation =
    {
      Model.presence = Model.Present;
      outcome = Model.Errored (stage, failure);
      trace = [];
    }
  in
  let diagnostic =
    Diagnostic.make ~site:(Diagnostic.Host "policy fixture")
      ~message:(Model.show observation) ~remedy:"Injected control."
  in
  match (stage, failure) with
  | Model.Normal (Model.Acquire | Model.Lookup), _ ->
      Workspace_manager.Ownership_conflict diagnostic
  | Model.Normal Model.Path, _ -> Workspace_manager.Unsafe_path diagnostic
  | Model.Normal Model.Callback, _ | Model.Remove, _ ->
      Workspace_manager.Filesystem_error diagnostic
  | ( ( Model.Normal (Model.After_create | Model.Before_run)
      | Model.After_run | Model.Before_remove ),
      Model.Rejected ) -> Workspace_manager.Hook_failed diagnostic
  | ( ( Model.Normal (Model.After_create | Model.Before_run)
      | Model.After_run | Model.Before_remove ),
      Model.Timed_out ) -> Workspace_manager.Hook_timeout diagnostic

let diagnostic = function
  | Workspace_manager.Invalid_key value
  | Workspace_manager.Unsafe_path value
  | Workspace_manager.Ownership_conflict value
  | Workspace_manager.Filesystem_error value
  | Workspace_manager.Hook_failed value
  | Workspace_manager.Hook_timeout value -> Diagnostic.render value

let failures = Model.[ Rejected; Timed_out ]

type error_kind =
  | Key_error
  | Path_error
  | Owner_error
  | File_error
  | Hook_error
  | Timeout_error

let error_kind = function
  | Workspace_manager.Invalid_key _ -> Key_error
  | Workspace_manager.Unsafe_path _ -> Path_error
  | Workspace_manager.Ownership_conflict _ -> Owner_error
  | Workspace_manager.Filesystem_error _ -> File_error
  | Workspace_manager.Hook_failed _ -> Hook_error
  | Workspace_manager.Hook_timeout _ -> Timeout_error

let find_error value =
  let catalog =
    List.concat_map
      (fun stage -> List.map (fun failure -> (stage, failure)) failures)
      stages
  in
  List.find_opt
    (fun (stage, failure) ->
      let expected = error stage failure in
      error_kind value = error_kind expected
      && String.equal (diagnostic value) (diagnostic expected))
    catalog

let error_identity value =
  match find_error value with
  | Some identity -> identity
  | None -> Alcotest.fail ("Unknown policy error: " ^ diagnostic value)

module Driver = struct
  module Contract = Reference

  type t = {
    mutable scenario : Model.scenario;
    mutable presence : Model.presence;
    mutable trace : Model.event list;
  }

  type status = Held | Released
  type lease = { owner : t; mutable status : status }
  type origin = Created | Reused

  let create scenario =
    { scenario; presence = scenario.Model.initial; trace = [] }

  let record t event = t.trace <- event :: t.trace

  let response t stage =
    record t (Model.Call stage);
    match stage with
    | Model.Normal normal when t.scenario.Model.cancel_at = Some normal ->
        raise (Cancelled normal)
    | Model.Normal _ | Model.After_run | Model.Before_remove | Model.Remove -> (
        match t.scenario.Model.respond stage with
        | Model.Proceed -> Ok ()
        | Model.Fail failure -> Error (error stage failure))

  let release lease =
    match lease.status with
    | Released -> Alcotest.fail "Duplicate lease release"
    | Held ->
        lease.status <- Released;
        record lease.owner Model.Release

  let with_lease t _reference run =
    Result.map
      (fun () ->
        let origin =
          match t.presence with
          | Model.Absent ->
              t.presence <- Model.Present;
              Created
          | Model.Present -> Reused
        in
        let lease = { owner = t; status = Held } in
        Fun.protect
          ~finally:(fun () -> release lease)
          (fun () -> run origin lease))
      (response t (Model.Normal Model.Acquire))

  let with_existing t _reference run =
    Result.map
      (fun () ->
        match t.presence with
        | Model.Absent -> run None
        | Model.Present ->
            let lease = { owner = t; status = Held } in
            Fun.protect
              ~finally:(fun () -> release lease)
              (fun () -> run (Some lease)))
      (response t (Model.Normal Model.Lookup))

  let path lease =
    match lease.status with
    | Released -> Alcotest.fail "Path read after release"
    | Held ->
        Result.map
          (fun () -> Path.Checked)
          (response lease.owner (Model.Normal Model.Path))

  let hook t _lease phase =
    let stage =
      match phase with
      | Workspace_settings.After_create -> Model.Normal Model.After_create
      | Workspace_settings.Before_run -> Model.Normal Model.Before_run
      | Workspace_settings.After_run -> Model.After_run
      | Workspace_settings.Before_remove -> Model.Before_remove
    in
    response t stage

  let remove t _lease =
    Result.map (fun () -> t.presence <- Model.Absent) (response t Model.Remove)

  let cleanup_scope t run =
    record t Model.Enter_cleanup;
    Fun.protect ~finally:(fun () -> record t Model.Leave_cleanup) run

  let report t value =
    let stage, failure = error_identity value in
    record t (Model.Report (stage, failure))
end

module Manager = Workspace_manager.Make (Driver)

let reference =
  let base = checked (Absolute_path.parse "/tmp/symphony-policy-tests") in
  let workflow_file = checked (Workflow_path.resolve ~base "WORKFLOW.md") in
  let env = checked (Environment.of_bindings ~temp_dir:base []) in
  let settings =
    match
      Workspace_settings.parse ~env ~workflow_file
        (checked (Config_value.parse "{}"))
    with
    | Ok settings -> settings
    | Error errors ->
        Alcotest.fail
          (String.concat "\n"
             (List.map Diagnostic.render (Nonempty_list.to_list errors)))
  in
  checked
    (Result.map_error diagnostic
       (Reference.reference ~settings
          ~env:(Environment.child env ~allow:[] ~deny:[])
          ~scope:(checked (Tracker_scope.parse "fixture"))
          ~identifier:(checked (Issue_identifier.parse "SYM-1"))))

let request =
  let request_id, _ = Request_id.Allocator.fresh Request_id.Allocator.empty in
  { Reference.request_id; workspace = reference }

let callback_value = "preserved callback value"

let run_driver driver operation =
  let callback path =
    Alcotest.(check string)
      "checked callback path" "/checked/workspace" (Path.display path);
    Result.map
      (fun () -> callback_value)
      (Driver.response driver (Model.Normal Model.Callback))
  in
  let outcome =
    match
      match operation with
      | Model.Attempt ->
          Result.map
            (fun value ->
              Alcotest.(check string)
                "callback result retained" callback_value value)
            (Manager.with_workspace driver reference callback)
      | Model.Cleanup -> Manager.cleanup driver request
    with
    | Ok () -> Model.Returned
    | Error value ->
        let stage, failure = error_identity value in
        Model.Errored (stage, failure)
    | exception Cancelled stage -> Model.Cancelled stage
  in
  {
    Model.presence = driver.Driver.presence;
    outcome;
    trace = List.rev driver.Driver.trace;
  }

let actual scenario =
  run_driver (Driver.create scenario) scenario.Model.operation

let compare scenario =
  let expected = Model.run scenario in
  let observed = actual scenario in
  if Model.equal expected observed then true
  else
    QCheck2.Test.fail_report
      ("expected " ^ Model.show expected ^ "\nobserved " ^ Model.show observed)

let plain initial operation : Model.scenario =
  {
    Model.initial;
    operation;
    respond = (fun _ -> Model.Proceed);
    cancel_at = None;
  }

let inject scenario target failure =
  {
    scenario with
    Model.respond =
      (fun stage ->
        if stage = target then Model.Fail failure else Model.Proceed);
  }

let single_faults () =
  List.iter
    (fun initial ->
      List.iter
        (fun operation ->
          let scenario = plain initial operation in
          ignore (compare scenario);
          List.iter
            (fun stage ->
              List.iter
                (fun failure ->
                  ignore (compare (inject scenario stage failure)))
                failures)
            stages;
          List.iter
            (fun stage ->
              ignore (compare { scenario with Model.cancel_at = Some stage }))
            normal_stages)
        Model.[ Attempt; Cleanup ])
    Model.[ Absent; Present ]

let rollback_errors () =
  let scenario = plain Model.Absent Model.Attempt in
  let scenario =
    {
      scenario with
      Model.respond =
        (function
        | Model.Normal Model.Path -> Model.Fail Model.Rejected
        | Model.After_run | Model.Remove -> Model.Fail Model.Rejected
        | Model.Before_remove -> Model.Fail Model.Timed_out
        | Model.Normal
            ( Model.Acquire
            | Model.Lookup
            | Model.After_create
            | Model.Before_run
            | Model.Callback ) -> Model.Proceed);
    }
  in
  let expected : Model.observation =
    {
      Model.presence = Model.Present;
      outcome = Model.Errored (Model.Normal Model.Path, Model.Rejected);
      trace =
        [
          Model.Call (Model.Normal Model.Acquire);
          Model.Call (Model.Normal Model.After_create);
          Model.Call (Model.Normal Model.Before_run);
          Model.Call (Model.Normal Model.Path);
          Model.Enter_cleanup;
          Model.Call Model.After_run;
          Model.Report (Model.After_run, Model.Rejected);
          Model.Call Model.Before_remove;
          Model.Report (Model.Before_remove, Model.Timed_out);
          Model.Call Model.Remove;
          Model.Report (Model.Remove, Model.Rejected);
          Model.Leave_cleanup;
          Model.Release;
        ];
    }
  in
  Alcotest.(check string)
    "preparation error survives failed cleanup" (Model.show expected)
    (Model.show (actual scenario));
  ignore (compare scenario)

let cleanup_twice () =
  let scenario = plain Model.Present Model.Cleanup in
  let driver = Driver.create scenario in
  let first = run_driver driver Model.Cleanup in
  let second = run_driver driver Model.Cleanup in
  let expected = Model.run scenario in
  let absent = Model.run { scenario with Model.initial = Model.Absent } in
  Alcotest.(check string)
    "first cleanup trace" (Model.show expected) (Model.show first);
  let repeated =
    { absent with Model.trace = expected.Model.trace @ absent.Model.trace }
  in
  Alcotest.(check string)
    "second cleanup preserves absence and performs no hooks"
    (Model.show repeated) (Model.show second)

let variant_control () =
  let value = error (Model.Normal Model.Path) Model.Rejected in
  let changed =
    match value with
    | Workspace_manager.Unsafe_path detail ->
        Workspace_manager.Hook_failed detail
    | Workspace_manager.Invalid_key _
    | Workspace_manager.Ownership_conflict _
    | Workspace_manager.Filesystem_error _
    | Workspace_manager.Hook_failed _
    | Workspace_manager.Hook_timeout _ ->
        Alcotest.fail "Invalid path error fixture"
  in
  Alcotest.(check bool)
    "original error recognized" true
    (Option.is_some (find_error value));
  Alcotest.(check bool)
    "changed error variant rejected" true
    (Option.is_none (find_error changed))

let tests =
  [
    Alcotest.test_case "all single fault and cancellation boundaries" `Quick
      single_faults;
    Alcotest.test_case
      "failed rollback reports errors and preserves primary failure" `Quick
      rollback_errors;
    Alcotest.test_case "successful cleanup is absent on repetition" `Quick
      cleanup_twice;
    Alcotest.test_case "primary error observation includes its variant" `Quick
      variant_control;
  ]

let rec zip first second =
  match (first, second) with
  | item :: rest, value :: values -> (item, value) :: zip rest values
  | [], _ | _, [] -> []

let generator =
  QCheck2.Gen.(
    map
      (fun ((initial, operation), (cancel_at, responses)) ->
        let bindings = zip stages responses in
        let respond stage =
          match List.assoc_opt stage bindings with
          | Some value -> value
          | None -> Model.Proceed
        in
        Model.{ initial; operation; respond; cancel_at })
      (pair
         (pair
            (oneof_list Model.[ Absent; Present ])
            (oneof_list Model.[ Attempt; Cleanup ]))
         (pair
            (oneof_list (None :: List.map Option.some normal_stages))
            (list_size
               (return (List.length stages))
               (oneof_list
                  Model.[ Proceed; Proceed; Fail Rejected; Fail Timed_out ])))))

let sequence scenarios =
  let driver = Driver.create (plain Model.Absent Model.Attempt) in
  let rec step presence = function
    | [] -> true
    | scenario :: rest ->
        let scenario = { scenario with Model.initial = presence } in
        let expected = Model.run scenario in
        driver.Driver.scenario <- scenario;
        driver.Driver.trace <- [];
        let observed = run_driver driver scenario.Model.operation in
        if Model.equal expected observed then step expected.Model.presence rest
        else
          QCheck2.Test.fail_report
            ("expected " ^ Model.show expected ^ "\nobserved "
           ^ Model.show observed)
  in
  step Model.Absent scenarios

let properties =
  [
    QCheck2.Test.make
      ~name:"workspace policy matches declarative fault trace model" ~count:2000
      generator compare;
    QCheck2.Test.make
      ~name:"workspace operation sequences preserve model observations"
      ~count:1000
      QCheck2.Gen.(list_size (int_range 0 20) generator)
      sequence;
  ]
