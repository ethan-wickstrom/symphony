module Model = Workspace_policy_model

module Path = struct
  type t = Checked

  let display Checked = "/checked/workspace"
end

module Reference = Workspace_reference.Make (Path)

exception Cancelled of Model.normal_stage
exception Fault of Model.fault
exception Lease_defect

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
        | Model.Fail failure -> Error (error stage failure)
        | Model.Defect -> raise (Fault (Model.Operation_defect stage)))

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
    record t (Model.Report (stage, failure));
    match t.scenario.Model.report stage failure with
    | Model.Observed -> ()
    | Model.Reporter_defect ->
        raise (Fault (Model.Reporting_defect (stage, failure)))
end

module Manager = Workspace_manager.Make (Driver)

module Lease_driver = struct
  include Driver

  let with_lease t reference run =
    ignore (Driver.with_lease t reference run);
    raise Lease_defect

  let with_existing t reference run =
    ignore (Driver.with_existing t reference run);
    raise Lease_defect
end

module Lease_manager = Workspace_manager.Make (Lease_driver)

let reference =
  let base = checked (Absolute_path.parse "/tmp/symphony-policy-tests") in
  let workflow_file = checked (Workflow_path.resolve ~base "WORKFLOW.md") in
  let env = checked (Environment.of_bindings ~temp_dir:base []) in
  let env = Environment.public env ~deny:[] ~secrets:[] in
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
          ~env:(Environment.child env ~allow:[])
          ~scope:(checked (Tracker_scope.parse "fixture"))
          ~issue_id:(checked (Issue_id.parse "opaque-fixture-id"))
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
            (Manager.with_workspace driver reference ~on_error:Fun.id callback)
      | Model.Cleanup -> Manager.cleanup driver request
    with
    | Ok () -> Model.Returned
    | Error value ->
        let stage, failure = error_identity value in
        Model.Errored (stage, failure)
    | exception Cancelled stage -> Model.Cancelled stage
    | exception Fault fault -> Model.Defected fault
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
    report = (fun _ _ -> Model.Observed);
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

let cleanup_defects () =
  let cleanup_stages = Model.[ After_run; Before_remove; Remove ] in
  List.iter
    (fun initial ->
      List.iter
        (fun operation ->
          let scenario = plain initial operation in
          List.iter
            (fun target ->
              let scenario =
                {
                  scenario with
                  Model.respond =
                    (fun stage ->
                      if stage = target then Model.Defect else Model.Proceed);
                }
              in
              ignore (compare scenario))
            cleanup_stages;
          List.iter
            (fun target ->
              let scenario = inject scenario target Model.Rejected in
              ignore
                (compare
                   {
                     scenario with
                     Model.report = (fun _ _ -> Model.Reporter_defect);
                   }))
            cleanup_stages)
        Model.[ Attempt; Cleanup ])
    Model.[ Absent; Present ]

let compound_defects () =
  List.iter
    (fun initial ->
      List.iter
        (fun primary_stage ->
          List.iter
            (fun response ->
              List.iter
                (fun secondary ->
                  let scenario = plain initial Model.Attempt in
                  let scenario =
                    {
                      scenario with
                      Model.respond =
                        (fun stage ->
                          if stage = Model.Normal primary_stage then response
                          else if stage = secondary then Model.Defect
                          else Model.Proceed);
                    }
                  in
                  ignore (compare scenario);
                  ignore
                    (compare
                       { scenario with Model.cancel_at = Some primary_stage });
                  ignore
                    (compare
                       {
                         scenario with
                         Model.respond =
                           (fun stage ->
                             if stage = secondary then Model.Fail Model.Rejected
                             else scenario.Model.respond stage);
                         report = (fun _ _ -> Model.Reporter_defect);
                       }))
                Model.[ After_run; Before_remove; Remove ])
            Model.[ Fail Rejected; Fail Timed_out; Defect ])
        Model.[ After_create; Before_run; Path; Callback ])
    Model.[ Absent; Present ]

let defect_backtrace () =
  List.iter
    (fun (after_run, reporting) ->
      let scenario = plain Model.Present Model.Attempt in
      let scenario =
        {
          scenario with
          Model.respond =
            (fun stage ->
              if stage = Model.After_run then after_run else Model.Proceed);
          report = (fun _ _ -> reporting);
        }
      in
      let driver = Driver.create scenario in
      let primary =
        Fault (Model.Operation_defect (Model.Normal Model.Callback))
      in
      let traces = ref [] in
      let callback _ =
        try raise primary
        with exn ->
          let trace = Printexc.get_raw_backtrace () in
          traces := [ trace ];
          Printexc.raise_with_backtrace exn trace
      in
      match
        Manager.with_workspace driver reference ~on_error:Fun.id callback
      with
      | Ok _ | Error _ -> Alcotest.fail "Primary defect did not propagate"
      | exception exn ->
          let observed = Printexc.get_raw_backtrace () in
          Alcotest.(check bool)
            "original exception identity" true (exn == primary);
          (match !traces with
          | [ expected ] ->
              Alcotest.(check bool)
                "primary backtrace contains frames" true
                (Printexc.raw_backtrace_length expected > 0);
              Alcotest.(check bool)
                "original backtrace retained" true
                (String.starts_with
                   ~prefix:(Printexc.raw_backtrace_to_string expected)
                   (Printexc.raw_backtrace_to_string observed))
          | [] | _ :: _ -> Alcotest.fail "Primary backtrace was not captured");
          Alcotest.(check int)
            "one release after finalizer defect" 1
            (List.fold_left
               (fun count event ->
                 match event with
                 | Model.Release -> count + 1
                 | Model.Call _
                 | Model.Enter_cleanup
                 | Model.Leave_cleanup
                 | Model.Report _ -> count)
               0 driver.Driver.trace))
    Model.[ (Defect, Observed); (Fail Rejected, Reporter_defect) ]

let check_released driver =
  let releases =
    List.fold_left
      (fun count -> function
        | Model.Release -> count + 1
        | Model.Call _
        | Model.Enter_cleanup
        | Model.Leave_cleanup
        | Model.Report _ -> count)
      0 driver.Driver.trace
  in
  Alcotest.check Alcotest.int "lease closed before returning the primary" 1
    releases

let lease_error_precedence () =
  let driver = Driver.create (plain Model.Present Model.Attempt) in
  let primary = Failure "foreign callback error" in
  let outcome =
    try
      `Returned
        (Lease_manager.with_workspace driver reference
           ~on_error:(fun _ ->
             Alcotest.fail "Foreign error reached the workspace mapper")
           (fun _ -> Error primary))
    with defect -> `Raised defect
  in
  check_released driver;
  match outcome with
  | `Returned (Error observed) when observed == primary -> ()
  | `Returned (Ok _ | Error _) | `Raised _ ->
      Alcotest.fail "Lease cleanup replaced the primary callback error"

let foreign_error_precedence () =
  List.iter
    (fun (after_run, reporting) ->
      let scenario = plain Model.Present Model.Attempt in
      let scenario =
        {
          scenario with
          Model.respond =
            (fun stage ->
              if stage = Model.After_run then after_run else Model.Proceed);
          report = (fun _ _ -> reporting);
        }
      in
      let driver = Driver.create scenario in
      let primary = Failure "foreign callback error" in
      let outcome =
        Manager.with_workspace driver reference
          ~on_error:(fun _ ->
            Alcotest.fail "Foreign error reached the workspace mapper")
          (fun _ -> Error primary)
      in
      check_released driver;
      match outcome with
      | Error observed when observed == primary -> ()
      | Ok _ | Error _ ->
          Alcotest.fail "Cleanup replaced the foreign callback error")
    Model.[ (Defect, Observed); (Fail Rejected, Reporter_defect) ]

let lease_defect_backtrace () =
  List.iter
    (fun primary ->
      let driver = Driver.create (plain Model.Present Model.Attempt) in
      let expected = ref None in
      let callback _ =
        try raise primary
        with error ->
          let trace = Printexc.get_raw_backtrace () in
          expected := Some trace;
          Printexc.raise_with_backtrace error trace
      in
      match
        Lease_manager.with_workspace driver reference ~on_error:Fun.id callback
      with
      | Ok _ | Error _ -> Alcotest.fail "Callback defect did not propagate"
      | exception observed -> (
          let trace = Printexc.get_raw_backtrace () in
          check_released driver;
          Alcotest.check Alcotest.bool "callback exception identity" true
            (observed == primary);
          match !expected with
          | None -> Alcotest.fail "Callback backtrace was not captured"
          | Some expected ->
              Alcotest.check Alcotest.bool "callback backtrace retained" true
                (String.starts_with
                   ~prefix:(Printexc.raw_backtrace_to_string expected)
                   (Printexc.raw_backtrace_to_string trace))))
    [
      Failure "callback defect";
      Eio.Cancel.Cancelled (Failure "foreign cancellation");
    ]

let mapper_after_cleanup () =
  List.iter
    (fun target ->
      List.iter
        (fun primary ->
          let driver =
            Driver.create
              (inject (plain Model.Absent Model.Attempt) target Model.Rejected)
          in
          let expected = ref None in
          let mapper _ =
            check_released driver;
            Alcotest.check Alcotest.bool "created workspace rolled back" true
              (driver.Driver.presence = Model.Absent);
            try raise primary
            with error ->
              let trace = Printexc.get_raw_backtrace () in
              expected := Some trace;
              Printexc.raise_with_backtrace error trace
          in
          match
            Manager.with_workspace driver reference ~on_error:mapper (fun _ ->
                Alcotest.fail "Preparation error entered the callback")
          with
          | Ok _ | Error _ -> Alcotest.fail "Mapper defect did not propagate"
          | exception observed -> (
              let trace = Printexc.get_raw_backtrace () in
              check_released driver;
              Alcotest.check Alcotest.bool "mapper exception identity" true
                (observed == primary);
              match !expected with
              | None -> Alcotest.fail "Mapper ran before cleanup finished"
              | Some expected ->
                  Alcotest.check Alcotest.bool "mapper backtrace retained" true
                    (String.starts_with
                       ~prefix:(Printexc.raw_backtrace_to_string expected)
                       (Printexc.raw_backtrace_to_string trace))))
        [
          Failure "mapper defect";
          Eio.Cancel.Cancelled (Failure "foreign mapper cancellation");
        ])
    Model.[ Normal Before_run; Normal Path ]

let canceled_scope_primary () =
  let module Canceled_driver = struct
    include Driver

    let with_lease t reference run =
      Eio.Switch.run (fun sw ->
          let value = Driver.with_lease t reference run in
          Eio.Switch.fail sw Lease_defect;
          value)
  end in
  let module Canceled_manager = Workspace_manager.Make (Canceled_driver) in
  Eio_mock.Backend.run (fun () ->
      let driver = Driver.create (plain Model.Present Model.Attempt) in
      let primary = Failure "foreign callback error" in
      let outcome =
        Canceled_manager.with_workspace driver reference
          ~on_error:(fun _ ->
            Alcotest.fail "Canceled scope mapped the callback error")
          (fun _ -> Error primary)
      in
      check_released driver;
      match outcome with
      | Error observed when observed == primary -> ()
      | Ok _ | Error _ ->
          Alcotest.fail "Canceled scope replaced the primary callback error")

let successful_lease_defect () =
  let driver = Driver.create (plain Model.Present Model.Attempt) in
  match
    Lease_manager.with_workspace driver reference ~on_error:Fun.id (fun _ ->
        Ok ())
  with
  | Ok _ | Error _ -> Alcotest.fail "Successful callback hid the lease defect"
  | exception Lease_defect -> check_released driver

let cleanup_error_precedence () =
  let scenario =
    inject (plain Model.Present Model.Cleanup) Model.Remove Model.Rejected
  in
  let driver = Driver.create scenario in
  let outcome =
    try `Returned (Lease_manager.cleanup driver request)
    with defect -> `Raised defect
  in
  check_released driver;
  match outcome with
  | `Returned (Error observed)
    when error_identity observed = Model.(Remove, Rejected) -> ()
  | `Returned (Ok _ | Error _) | `Raised _ ->
      Alcotest.fail "Lease cleanup replaced the primary removal error"

let cleanup_scope_precedence () =
  let module Scope_driver = struct
    include Driver

    let cleanup_scope t run =
      ignore (Driver.cleanup_scope t run);
      raise Lease_defect
  end in
  let module Scope_manager = Workspace_manager.Make (Scope_driver) in
  let scenario =
    inject (plain Model.Present Model.Cleanup) Model.Remove Model.Rejected
  in
  let driver = Driver.create scenario in
  let outcome =
    try `Returned (Scope_manager.cleanup driver request)
    with defect -> `Raised defect
  in
  check_released driver;
  match outcome with
  | `Returned (Error observed)
    when error_identity observed = Model.(Remove, Rejected) -> ()
  | `Returned (Ok _ | Error _) | `Raised _ ->
      Alcotest.fail "Cleanup scope replaced the primary removal error"

let cleanup_fault_backtrace () =
  List.iter
    (fun primary ->
      let expected = ref None in
      let module Closing_driver = struct
        include Lease_driver

        let remove _ _ =
          try raise primary
          with error ->
            let trace = Printexc.get_raw_backtrace () in
            expected := Some trace;
            Printexc.raise_with_backtrace error trace

        let cleanup_scope t run =
          ignore (Driver.cleanup_scope t run);
          raise Lease_defect
      end in
      let module Closing_manager = Workspace_manager.Make (Closing_driver) in
      let driver = Driver.create (plain Model.Present Model.Cleanup) in
      match Closing_manager.cleanup driver request with
      | Ok _ | Error _ -> Alcotest.fail "Removal defect did not propagate"
      | exception observed -> (
          let trace = Printexc.get_raw_backtrace () in
          check_released driver;
          Alcotest.check Alcotest.bool "removal exception identity" true
            (observed == primary);
          match !expected with
          | None -> Alcotest.fail "Removal backtrace was not captured"
          | Some expected ->
              Alcotest.check Alcotest.bool "removal backtrace retained" true
                (String.starts_with
                   ~prefix:(Printexc.raw_backtrace_to_string expected)
                   (Printexc.raw_backtrace_to_string trace))))
    [
      Failure "removal defect";
      Eio.Cancel.Cancelled (Failure "foreign removal cancellation");
    ]

let successful_cleanup_defect () =
  let driver = Driver.create (plain Model.Present Model.Cleanup) in
  match Lease_manager.cleanup driver request with
  | Ok _ | Error _ -> Alcotest.fail "Successful removal hid the lease defect"
  | exception Lease_defect ->
      check_released driver;
      Alcotest.check Alcotest.bool "workspace removed before lease defect" true
        (driver.Driver.presence = Model.Absent)

type finish_fault = After_run_fault | Reporter_fault

let finish_fault_precedence () =
  List.iter
    (fun source ->
      let primary = Failure "first finalizer defect" in
      let expected = ref None in
      let raise_primary () =
        try raise primary
        with error ->
          let trace = Printexc.get_raw_backtrace () in
          expected := Some trace;
          Printexc.raise_with_backtrace error trace
      in
      let module Scope_driver = struct
        include Driver

        let hook t lease phase =
          match (phase, source) with
          | Workspace_settings.After_run, After_run_fault ->
              Driver.record t (Model.Call Model.After_run);
              raise_primary ()
          | Workspace_settings.After_run, Reporter_fault
          | ( ( Workspace_settings.After_create
              | Workspace_settings.Before_run
              | Workspace_settings.Before_remove ),
              (After_run_fault | Reporter_fault) ) -> Driver.hook t lease phase

        let report _ _ = raise_primary ()

        let cleanup_scope t run =
          Fun.protect
            ~finally:(fun () -> raise Lease_defect)
            (fun () -> Driver.cleanup_scope t run)
      end in
      let module Scope_manager = Workspace_manager.Make (Scope_driver) in
      let scenario =
        inject
          (plain Model.Present Model.Attempt)
          Model.After_run Model.Rejected
      in
      let driver = Driver.create scenario in
      match
        Scope_manager.with_workspace driver reference ~on_error:Fun.id (fun _ ->
            Ok ())
      with
      | Ok _ | Error _ -> Alcotest.fail "Finalizer defect did not propagate"
      | exception observed -> (
          let trace = Printexc.get_raw_backtrace () in
          check_released driver;
          Alcotest.check Alcotest.bool "first finalizer exception identity" true
            (observed == primary);
          match !expected with
          | None -> Alcotest.fail "Finalizer backtrace was not captured"
          | Some expected ->
              Alcotest.check Alcotest.bool "first finalizer backtrace retained"
                true
                (String.starts_with
                   ~prefix:(Printexc.raw_backtrace_to_string expected)
                   (Printexc.raw_backtrace_to_string trace))))
    [ After_run_fault; Reporter_fault ]

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

let inspection_examples () =
  let observed =
    Alcotest.testable
      (fun formatter value ->
        Format.pp_print_string formatter (Model.show value))
      Model.equal
  in
  let check driver expected label =
    let outcome =
      match Manager.inspect driver reference with
      | Ok actual ->
          Alcotest.(check (option string)) "informational label" label actual;
          Model.Returned
      | Error value ->
          let stage, failure = error_identity value in
          Model.Errored (stage, failure)
      | exception Cancelled stage -> Model.Cancelled stage
      | exception Fault fault -> Model.Defected fault
    in
    let actual =
      {
        Model.presence = driver.Driver.presence;
        outcome;
        trace = List.rev driver.Driver.trace;
      }
    in
    Alcotest.check observed "read-only lifecycle" expected actual;
    driver.Driver.trace <- []
  in
  let lookup = Model.Call (Model.Normal Model.Lookup) in
  let held = [ lookup; Model.Call (Model.Normal Model.Path); Model.Release ] in
  let absent = Driver.create (plain Model.Absent Model.Cleanup) in
  let missing =
    {
      Model.presence = Model.Absent;
      outcome = Model.Returned;
      trace = [ lookup ];
    }
  in
  check absent missing None;
  check absent missing None;
  let present = Driver.create (plain Model.Present Model.Cleanup) in
  let owned =
    { Model.presence = Model.Present; outcome = Model.Returned; trace = held }
  in
  check present owned (Some "/checked/workspace");
  check present owned (Some "/checked/workspace");
  List.iter
    (fun (stage, trace) ->
      let scenario =
        inject
          (plain Model.Present Model.Cleanup)
          (Model.Normal stage) Model.Rejected
      in
      check (Driver.create scenario)
        {
          Model.presence = Model.Present;
          outcome = Model.Errored (Model.Normal stage, Model.Rejected);
          trace;
        }
        None)
    [ (Model.Lookup, [ lookup ]); (Model.Path, held) ];
  let scenario =
    {
      (plain Model.Present Model.Cleanup) with
      Model.cancel_at = Some Model.Path;
    }
  in
  check (Driver.create scenario)
    {
      Model.presence = Model.Present;
      outcome = Model.Cancelled Model.Path;
      trace = held;
    }
    None;
  let scenario =
    {
      (plain Model.Present Model.Cleanup) with
      Model.respond =
        (function
        | Model.Normal Model.Path -> Model.Defect
        | Model.Normal
            ( Model.Acquire
            | Model.Lookup
            | Model.After_create
            | Model.Before_run
            | Model.Callback )
        | Model.After_run | Model.Before_remove | Model.Remove -> Model.Proceed);
    }
  in
  check (Driver.create scenario)
    {
      Model.presence = Model.Present;
      outcome =
        Model.Defected (Model.Operation_defect (Model.Normal Model.Path));
      trace = held;
    }
    None

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
    Alcotest.test_case "cleanup defects cannot skip deletion or release" `Quick
      cleanup_defects;
    Alcotest.test_case "primary faults survive cleanup and reporter defects"
      `Quick compound_defects;
    Alcotest.test_case "cleanup retains original defect identity and backtrace"
      `Quick defect_backtrace;
    Alcotest.test_case "callback error outranks lease cleanup defect" `Quick
      lease_error_precedence;
    Alcotest.test_case
      "foreign callback error survives finalizer and reporter defects" `Quick
      foreign_error_precedence;
    Alcotest.test_case
      "callback defects survive lease closure with original backtrace" `Quick
      lease_defect_backtrace;
    Alcotest.test_case "workspace mapper runs after rollback and release" `Quick
      mapper_after_cleanup;
    Alcotest.test_case "canceled lease scope retains callback error" `Quick
      canceled_scope_primary;
    Alcotest.test_case "successful callback exposes lease defect" `Quick
      successful_lease_defect;
    Alcotest.test_case "removal error outranks existing lease cleanup defect"
      `Quick cleanup_error_precedence;
    Alcotest.test_case "removal error outranks cleanup scope defect" `Quick
      cleanup_scope_precedence;
    Alcotest.test_case
      "removal faults survive both scopes with original backtrace" `Quick
      cleanup_fault_backtrace;
    Alcotest.test_case "successful removal exposes lease defect" `Quick
      successful_cleanup_defect;
    Alcotest.test_case "first finalizer defect survives cleanup scope closure"
      `Quick finish_fault_precedence;
    Alcotest.test_case "inspection preserves contents and scoped ownership"
      `Quick inspection_examples;
  ]

let rec zip first second =
  match (first, second) with
  | item :: rest, value :: values -> (item, value) :: zip rest values
  | [], _ | _, [] -> []

let generator =
  QCheck2.Gen.(
    map
      (fun ((initial, operation), (cancel_at, (responses, reports))) ->
        let bindings = zip stages responses in
        let respond stage =
          match List.assoc_opt stage bindings with
          | Some value -> value
          | None -> Model.Proceed
        in
        let reporting = zip stages reports in
        let report stage _ =
          match List.assoc_opt stage reporting with
          | Some value -> value
          | None -> Model.Observed
        in
        Model.{ initial; operation; respond; cancel_at; report })
      (pair
         (pair
            (oneof_list Model.[ Absent; Present ])
            (oneof_list Model.[ Attempt; Cleanup ]))
         (pair
            (oneof_list (None :: List.map Option.some normal_stages))
            (pair
               (list_size
                  (return (List.length stages))
                  (oneof_list
                     Model.
                       [
                         Proceed; Proceed; Fail Rejected; Fail Timed_out; Defect;
                       ]))
               (list_size
                  (return (List.length stages))
                  (oneof_list Model.[ Observed; Observed; Reporter_defect ]))))))

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
