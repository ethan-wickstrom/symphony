module Path = struct
  type t = Checked

  let display Checked = "/checked/driver"
end

module Contract = Workspace_reference.Make (Path)

type event =
  | Acquired
  | Hook of Workspace_settings.hook
  | Child_closed
  | Reported
  | Released

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let diagnostic =
  Diagnostic.make ~site:(Diagnostic.Host "workspace driver fixture")
    ~message:"Injected boundary failure." ~remedy:"Fixture control."

let unsafe = Workspace_manager.Unsafe_path diagnostic
let hook_error = Workspace_manager.Hook_failed diagnostic

let reference () =
  let base = checked (Absolute_path.parse "/tmp/symphony-driver-tests") in
  let workflow_file = checked (Workflow_path.resolve ~base "WORKFLOW.md") in
  let env = checked (Environment.of_bindings ~temp_dir:base []) in
  let settings =
    match
      Workspace_settings.parse ~env ~workflow_file
        (checked
           (Config_value.parse
              {|{"hooks":{"before_run":"exit 0","after_run":"exit 1"}}|}))
    with
    | Ok value -> value
    | Error errors ->
        Alcotest.fail
          (String.concat "\n"
             (List.map Diagnostic.render (Nonempty_list.to_list errors)))
  in
  match
    Contract.reference ~settings
      ~env:(Environment.child env ~allow:[] ~deny:[])
      ~scope:(checked (Tracker_scope.parse "driver-fixture"))
      ~issue_id:(checked (Issue_id.parse "opaque-driver-id"))
      ~identifier:(checked (Issue_identifier.parse "SYM-2"))
  with
  | Ok value -> value
  | Error _ -> Alcotest.fail "reference construction failed"

module Store = struct
  module Contract = Contract

  type status = Held | Released
  type t = event list ref

  type lease = {
    reference : Contract.reference;
    mutable status : status;
    mutable path : (Path.t, Workspace_manager.error) result;
  }

  type origin = Created | Reused

  let with_lease trace reference run =
    let lease = { reference; status = Held; path = Ok Path.Checked } in
    trace := Acquired :: !trace;
    Ok
      (Fun.protect
         ~finally:(fun () ->
           lease.status <- Released;
           trace := Released :: !trace)
         (fun () -> run Reused lease))

  let with_existing trace reference run =
    with_lease trace reference (fun _origin lease -> run (Some lease))

  let reference lease = lease.reference

  let path lease =
    match lease.status with
    | Held -> lease.path
    | Released -> Error unsafe

  let remove _trace lease = Result.map (fun _path -> ()) (path lease)
end

module Hooks = struct
  module Contract = Contract

  type t =
    Contract.reference ->
    Path.t ->
    Workspace_settings.hook ->
    (unit, Workspace_manager.error) result

  let run run ~workspace ~cwd phase = run workspace cwd phase
end

module Driver = Workspace_driver.Make (Store) (Hooks)
module Manager = Workspace_manager.Make (Driver)

let shared_path (path : Driver.Contract.Path.t) : Path.t = path

let boundary () =
  let frozen = reference () in
  let calls = ref 0 in
  let hooks workspace cwd phase =
    incr calls;
    Alcotest.(check bool) "frozen reference" true (workspace == frozen);
    Alcotest.(check string)
      "shared Path brand" "/checked/driver"
      (Path.display (shared_path cwd));
    Alcotest.(check bool)
      "hook phase" true
      (phase = Workspace_settings.Before_run);
    Ok ()
  in
  let trace = ref [] in
  let driver = Driver.create ~store:trace ~hooks ~report:(fun _error -> ()) in
  let outcome =
    Driver.with_lease driver frozen (fun origin lease ->
        Alcotest.(check bool) "origin equality" true (origin = Store.Reused);
        Alcotest.(check bool)
          "successful hook" true
          (Driver.hook driver lease Workspace_settings.Before_run = Ok ());
        lease.Store.path <- Error unsafe;
        match Driver.hook driver lease Workspace_settings.Before_run with
        | Error (Workspace_manager.Unsafe_path _) -> "callback value"
        | Error
            ( Workspace_manager.Invalid_key _
            | Workspace_manager.Ownership_conflict _
            | Workspace_manager.Filesystem_error _
            | Workspace_manager.Hook_failed _
            | Workspace_manager.Hook_timeout _ )
        | Ok () -> Alcotest.fail "invalid path reached hook")
  in
  (match outcome with
  | Ok value ->
      Alcotest.(check string) "callback preserved" "callback value" value
  | Error _ -> Alcotest.fail "callback result lost");
  Alcotest.(check int) "rejected path skips hook" 1 !calls;
  Alcotest.(check bool)
    "lease released once" true
    (List.rev !trace = [ Acquired; Released ])

exception Fixture_cancel
exception Fixture_defect

let cleanup_after_cancel () =
  Eio_posix.run (fun _env ->
      let trace = ref [] in
      let hooks _workspace _cwd phase =
        trace := Hook phase :: !trace;
        match phase with
        | Workspace_settings.After_run ->
            Eio.Fiber.check ();
            Eio.Switch.run (fun sw ->
                Eio.Fiber.fork ~sw (fun () ->
                    Eio.Fiber.yield ();
                    Eio.Fiber.check ();
                    trace := Child_closed :: !trace));
            Error hook_error
        | Workspace_settings.After_create
        | Workspace_settings.Before_run
        | Workspace_settings.Before_remove -> Ok ()
      in
      let report = function
        | Workspace_manager.Hook_failed _ -> trace := Reported :: !trace
        | Workspace_manager.Invalid_key _
        | Workspace_manager.Unsafe_path _
        | Workspace_manager.Ownership_conflict _
        | Workspace_manager.Filesystem_error _
        | Workspace_manager.Hook_timeout _ ->
            Alcotest.fail "unexpected cleanup report"
      in
      let driver = Driver.create ~store:trace ~hooks ~report in
      let cancelled =
        match
          Eio.Switch.run (fun sw ->
              Manager.with_workspace driver (reference ()) (fun _path ->
                  Eio.Switch.fail sw Fixture_cancel;
                  Eio.Fiber.check ();
                  Ok ()))
        with
        | Ok () | Error _ -> false
        | exception Fixture_cancel -> true
      in
      Alcotest.(check bool) "original cancellation" true cancelled;
      Alcotest.(check bool)
        "cleanup child joins before release" true
        (List.rev !trace
        = [
            Acquired;
            Hook Workspace_settings.Before_run;
            Hook Workspace_settings.After_run;
            Child_closed;
            Reported;
            Released;
          ]))

let cleanup_defect () =
  Eio_posix.run (fun _env ->
      let driver =
        Driver.create ~store:(ref [])
          ~hooks:(fun _workspace _cwd _phase -> Ok ())
          ~report:(fun _error -> ())
      in
      let raised =
        match
          Driver.cleanup_scope driver (fun () ->
              Eio.Fiber.yield ();
              raise Fixture_defect)
        with
        | () -> false
        | exception Fixture_defect -> true
      in
      Alcotest.(check bool) "cleanup defect propagates" true raised)

let tests =
  [
    Alcotest.test_case "shared identity and rejected path boundary" `Quick
      boundary;
    Alcotest.test_case "cancelled attempt runs protected cleanup children"
      `Quick cleanup_after_cancel;
    Alcotest.test_case "protected cleanup preserves defects" `Quick
      cleanup_defect;
  ]
