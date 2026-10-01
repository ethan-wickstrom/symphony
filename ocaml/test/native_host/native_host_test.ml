module Host = Workspace_host_posix.Make (Clock_posix)
module Manager = Host.Workspace

(* The manager's checked capability is exactly the process driver's cwd brand. *)
let shared_path (path : Manager.Contract.Path.t) : Host.Process.Path.t = path

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let error_text = function
  | Workspace_manager.Invalid_key error
  | Workspace_manager.Unsafe_path error
  | Workspace_manager.Ownership_conflict error
  | Workspace_manager.Filesystem_error error
  | Workspace_manager.Hook_failed error
  | Workspace_manager.Hook_timeout error -> Diagnostic.render error

let acquired = function
  | Ok value -> value
  | Error error -> Alcotest.fail (error_text error)

let observed = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Diagnostic.render error)

let write_file file bytes =
  let out = open_out_bin file in
  Fun.protect
    ~finally:(fun () -> close_out out)
    (fun () -> output_string out bytes)

let read_file file =
  let input = open_in_bin file in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () ->
      let limit = 16_384 in
      let length = in_channel_length input in
      if length > limit then Alcotest.fail "fixture output exceeded byte bound";
      really_input_string input length)

let lines file = String.split_on_char '\n' (String.trim (read_file file))

let row_phase row =
  match String.index_opt row '|' with
  | None -> row
  | Some stop -> String.sub row 0 stop

type fixture = {
  root : string;
  trace_file : string;
  pid_file : string;
  env : Environment.t;
  child : Environment.child;
  clock : Clock_posix.t;
  host : Host.t;
  events : (Workspace_settings.hook * Workspace_hooks.event) list ref;
  reports : Workspace_manager.error list ref;
}

let with_fixture ?(observe = fun _phase _event -> ()) run =
  Eio_posix.run (fun capabilities ->
      let base = Filename.temp_file "symphony-host-" "" in
      Unix.unlink base;
      Unix.mkdir base 0o700;
      let base = Unix.realpath base in
      let fs = Eio.Stdenv.fs capabilities in
      Fun.protect
        ~finally:(fun () -> Eio.Path.rmtree (Eio.Path.( / ) fs base))
        (fun () ->
          let home = Filename.concat base "home" in
          Unix.mkdir home 0o700;
          write_file (Filename.concat home ".bash_profile") "";
          let trace_file = Filename.concat base "trace" in
          let pid_file = Filename.concat base "child.pid" in
          write_file trace_file "";
          let root = Filename.concat base "workspaces" in
          let env =
            checked
              (Environment.of_bindings
                 ~temp_dir:(checked (Absolute_path.parse base))
                 [
                   ("HOME", home);
                   ("PATH", "/usr/bin:/bin");
                   ("TRACE_FILE", trace_file);
                   ("CHILD_PID_FILE", pid_file);
                   ("MARKER", "literal $(touch UNTRUSTED)");
                   ("LINEAR_API_KEY", "tracker-secret");
                 ])
          in
          let child =
            Environment.child env
              ~allow:
                [
                  "HOME";
                  "PATH";
                  "TRACE_FILE";
                  "CHILD_PID_FILE";
                  "MARKER";
                  "LINEAR_API_KEY";
                ]
              ~deny:[ "LINEAR_API_KEY" ]
          in
          let events = ref [] and reports = ref [] in
          let clock =
            Clock_posix.create
              ~mono:(Eio.Stdenv.mono_clock capabilities)
              ~wall:(Eio.Stdenv.clock capabilities)
          in
          let host =
            Host.create ~fs ~clock
              ~emit:(fun _workspace phase event ->
                events := (phase, event) :: !events;
                observe phase event)
              ~report:(fun error -> reports := error :: !reports)
          in
          run
            {
              root;
              trace_file;
              pid_file;
              env;
              child;
              clock;
              host;
              events;
              reports;
            }))

let after_create =
  "printf '%s|%s|%s|%s\\n' 'after_create' \"$PWD\" \"$MARKER\" \
   \"${LINEAR_API_KEY-unset}\" >> \"$TRACE_FILE\""

let before_run =
  "printf '%s|%s|%s|%s\\n' 'before_run' \"$PWD\" \"$MARKER\" \
   \"${LINEAR_API_KEY-unset}\" >> \"$TRACE_FILE\""

let after_run =
  "printf '%s|%s|%s|%s\\n' 'after_run' \"$PWD\" \"$MARKER\" \
   \"${LINEAR_API_KEY-unset}\" >> \"$TRACE_FILE\""

let before_remove =
  "printf '%s|%s|%s|%s\\n' 'before_remove' \"$PWD\" \"$MARKER\" \
   \"${LINEAR_API_KEY-unset}\" >> \"$TRACE_FILE\""

let fail_create = "printf 'after_create_failed\\n' >> \"$TRACE_FILE\"; exit 11"
let fail_run = "printf 'before_run_failed\\n' >> \"$TRACE_FILE\"; exit 23"
let slow_run = "exec /bin/sleep 5"

let reference fixture ?(created = after_create) ?(before = before_run)
    ?(after = after_run) ?(removed = before_remove) ?(timeout = 3000) () =
  let workflow_file =
    checked
      (Workflow_path.resolve
         ~base:(checked (Absolute_path.parse fixture.root))
         "WORKFLOW.md")
  in
  let config =
    checked
      (Config_value.parse
         (Yojson.Safe.to_string
            (`Assoc
               [
                 ("workspace", `Assoc [ ("root", `String fixture.root) ]);
                 ( "hooks",
                   `Assoc
                     [
                       ("after_create", `String created);
                       ("before_run", `String before);
                       ("after_run", `String after);
                       ("before_remove", `String removed);
                       ("timeout_ms", `Int timeout);
                     ] );
               ])))
  in
  let settings =
    match Workspace_settings.parse ~env:fixture.env ~workflow_file config with
    | Ok settings -> settings
    | Error errors ->
        Alcotest.fail
          (String.concat "\n"
             (List.map Diagnostic.render (Nonempty_list.to_list errors)))
  in
  acquired
    (Host.Contract.reference ~settings ~env:fixture.child
       ~scope:(checked (Tracker_scope.parse "public-native-host"))
       ~issue_id:(checked (Issue_id.parse "opaque-native-issue"))
       ~identifier:
         (checked (Issue_identifier.parse "SYM-2; $(touch UNTRUSTED)")))

let entry fixture workspace =
  Filename.concat fixture.root
    (Workspace_key.text (Host.Contract.key workspace))

let manager fixture = Host.workspace fixture.host

let cleanup fixture workspace =
  let request_id, _ = Request_id.Allocator.fresh Request_id.Allocator.empty in
  acquired
    (Manager.cleanup (manager fixture) { Host.Contract.request_id; workspace })

let expect_rows fixture workspace phases =
  let suffix =
    "|" ^ entry fixture workspace ^ "|literal $(touch UNTRUSTED)|unset"
  in
  Alcotest.(check (list string))
    "frozen cwd and allowlisted values"
    (List.map (fun phase -> phase ^ suffix) phases)
    (lines fixture.trace_file)

let phase_name = function
  | Workspace_settings.After_create -> "after_create"
  | Workspace_settings.Before_run -> "before_run"
  | Workspace_settings.After_run -> "after_run"
  | Workspace_settings.Before_remove -> "before_remove"

let event_name = function
  | Workspace_hooks.Started -> "started"
  | Workspace_hooks.Finished Workspace_hooks.Cancelled -> "cancelled"
  | Workspace_hooks.Finished (Workspace_hooks.Completed (Ok ())) -> "ok"
  | Workspace_hooks.Finished (Workspace_hooks.Completed (Error _)) -> "error"

let event_trace fixture =
  List.map
    (fun (phase, event) -> phase_name phase ^ ":" ^ event_name event)
    (List.rev !(fixture.events))

let preserve fixture workspace cwd =
  Result.map_error
    (fun error -> Workspace_manager.Filesystem_error error)
    (Host.Process.with_process (Host.process fixture.host)
       ~cwd:(shared_path cwd) ~env:(Host.Contract.environment workspace)
       ~command:"printf 'preserved\\n' > preserved" (fun process ->
         match observed (Host.Process.await_exit process) with
         | Host.Process.Exited 0 -> Ok ()
         | Host.Process.Exited _ | Host.Process.Signaled _ ->
             Alcotest.fail "fixture callback command failed"))

let lifecycle () =
  with_fixture (fun fixture ->
      let workspace = reference fixture () in
      ignore
        (reference fixture ~created:"exit 99" ~before:"exit 99" ~after:"exit 99"
           ());
      acquired
        (Manager.with_workspace (manager fixture) workspace (fun cwd ->
             preserve fixture workspace cwd));
      expect_rows fixture workspace
        [ "after_create"; "before_run"; "after_run" ];
      cleanup fixture workspace;
      expect_rows fixture workspace
        [ "after_create"; "before_run"; "after_run"; "before_remove" ];
      Alcotest.(check (list string))
        "all hook lifecycle events"
        [
          "after_create:started";
          "after_create:ok";
          "before_run:started";
          "before_run:ok";
          "after_run:started";
          "after_run:ok";
          "before_remove:started";
          "before_remove:ok";
        ]
        (event_trace fixture);
      Alcotest.(check bool)
        "cleanup removed workspace" false
        (Sys.file_exists (entry fixture workspace));
      Alcotest.(check int)
        "successful lifecycle reports no errors" 0
        (List.length !(fixture.reports)))

let expect_failed = function
  | Error (Workspace_manager.Hook_failed _) -> ()
  | Ok _
  | Error
      ( Workspace_manager.Invalid_key _
      | Workspace_manager.Unsafe_path _
      | Workspace_manager.Ownership_conflict _
      | Workspace_manager.Filesystem_error _
      | Workspace_manager.Hook_timeout _ ) ->
      Alcotest.fail "expected hook status failure"

let preparation_rollback () =
  List.iter
    (fun (created, before, expected) ->
      with_fixture (fun fixture ->
          let workspace = reference fixture ~created ~before () in
          let entered = ref false in
          expect_failed
            (Manager.with_workspace (manager fixture) workspace (fun _cwd ->
                 entered := true;
                 Ok ()));
          Alcotest.(check bool)
            "failed preparation skips callback" false !entered;
          let rows = lines fixture.trace_file in
          let phases = List.map row_phase rows in
          Alcotest.(check (list string))
            "cleanup before rollback" expected phases;
          Alcotest.(check bool)
            "created preparation failure rolled back" false
            (Sys.file_exists (entry fixture workspace))))
    [
      ( fail_create,
        before_run,
        [ "after_create_failed"; "after_run"; "before_remove" ] );
      ( after_create,
        fail_run,
        [ "after_create"; "before_run_failed"; "after_run"; "before_remove" ] );
    ]

let reused_failure () =
  with_fixture (fun fixture ->
      let workspace = reference fixture () in
      acquired
        (Manager.with_workspace (manager fixture) workspace (fun cwd ->
             preserve fixture workspace cwd));
      write_file fixture.trace_file "";
      let failed = reference fixture ~before:fail_run () in
      let entered = ref false in
      expect_failed
        (Manager.with_workspace (manager fixture) failed (fun _cwd ->
             entered := true;
             Ok ()));
      Alcotest.(check bool) "reused preparation skips callback" false !entered;
      Alcotest.(check string)
        "reused content preserved" "preserved\n"
        (read_file (Filename.concat (entry fixture workspace) "preserved"));
      Alcotest.(check (list string))
        "reused skips creation and rollback"
        [ "before_run_failed"; "after_run" ]
        (List.map row_phase (lines fixture.trace_file)))

let hook_timeout () =
  with_fixture (fun fixture ->
      let workspace =
        reference fixture ~created:"exit 0" ~before:slow_run ~timeout:200 ()
      in
      (match
         Manager.with_workspace (manager fixture) workspace (fun _cwd -> Ok ())
       with
      | Error (Workspace_manager.Hook_timeout _) -> ()
      | Ok ()
      | Error
          ( Workspace_manager.Invalid_key _
          | Workspace_manager.Unsafe_path _
          | Workspace_manager.Ownership_conflict _
          | Workspace_manager.Filesystem_error _
          | Workspace_manager.Hook_failed _ ) ->
          Alcotest.fail "expected live hook timeout");
      Alcotest.(check bool)
        "timed out created workspace removed" false
        (Sys.file_exists (entry fixture workspace)))

exception Callback_cancelled

let alive pid =
  try
    Unix.kill pid 0;
    true
  with Unix.Unix_error (Unix.ESRCH, _, _) -> false

let child_command =
  "printf '%s\\n' \"$$\" > \"$CHILD_PID_FILE\"; printf 'ready\\n'; exec \
   /bin/sleep 30"

let ready_bytes_max = 64
let ready_timeout = checked (Milliseconds.parse "5000")

let read_line process =
  let rec collect bytes =
    match observed (Host.Process.read process) with
    | None -> Alcotest.fail "child ended before ready marker"
    | Some chunk ->
        if String.length bytes + String.length chunk > ready_bytes_max then
          Alcotest.fail "child ready marker exceeded byte bound";
        let bytes = bytes ^ chunk in
        if String.ends_with ~suffix:"\n" bytes then bytes else collect bytes
  in
  collect ""

let child_ready process =
  Alcotest.(check string) "child ready" "ready\n" (read_line process)

let await_ready fixture ready =
  let start = observed (Clock_posix.now fixture.clock) in
  let deadline = Clock.Pure.after start ready_timeout in
  Eio.Fiber.first
    (fun () -> Eio.Promise.await ready)
    (fun () ->
      observed (Clock_posix.sleep_until fixture.clock deadline);
      Alcotest.fail "child did not become ready before fixture deadline")

let native_cancellation () =
  let pid = ref None in
  let alive_at_cleanup = ref None in
  let observe phase event =
    match (phase, event) with
    | Workspace_settings.After_run, Workspace_hooks.Started ->
        alive_at_cleanup := Option.map alive !pid
    | ( ( Workspace_settings.After_create
        | Workspace_settings.Before_run
        | Workspace_settings.Before_remove ),
        _ )
    | Workspace_settings.After_run, Workspace_hooks.Finished _ -> ()
  in
  with_fixture ~observe (fun fixture ->
      let workspace = reference fixture () in
      let escaped = ref None in
      let ready, signal = Eio.Promise.create () in
      Alcotest.check_raises "callback cancellation survives cleanup"
        Callback_cancelled (fun () ->
          Eio.Switch.run (fun sw ->
              Eio.Fiber.fork ~sw (fun () ->
                  ignore
                    (Manager.with_workspace (manager fixture) workspace
                       (fun cwd ->
                         escaped := Some cwd;
                         Result.map_error
                           (fun error ->
                             Workspace_manager.Filesystem_error error)
                           (Host.Process.with_process
                              (Host.process fixture.host) ~cwd:(shared_path cwd)
                              ~env:(Host.Contract.environment workspace)
                              ~command:child_command (fun process ->
                                child_ready process;
                                let child =
                                  match
                                    int_of_string_opt
                                      (String.trim (read_file fixture.pid_file))
                                  with
                                  | Some value when value > 0 -> value
                                  | Some _ | None ->
                                      Alcotest.fail "invalid fixture child PID"
                                in
                                pid := Some child;
                                Eio.Promise.resolve signal ();
                                Eio.Fiber.await_cancel ())))));
              await_ready fixture ready;
              Eio.Switch.fail sw Callback_cancelled;
              Eio.Fiber.yield ()));
      Alcotest.(check (option bool))
        "child reaped before protected after_run" (Some false) !alive_at_cleanup;
      expect_rows fixture workspace
        [ "after_create"; "before_run"; "after_run" ];
      Alcotest.(check bool)
        "callback cancellation preserves workspace" true
        (Sys.file_exists (entry fixture workspace));
      let escaped =
        match !escaped with
        | Some cwd -> cwd
        | None -> Alcotest.fail "callback not entered"
      in
      let launched = ref false in
      (match
         Host.Process.with_process (Host.process fixture.host)
           ~cwd:(shared_path escaped) ~env:(Host.Contract.environment workspace)
           ~command:"exit 0" (fun _process ->
             launched := true;
             Ok ())
       with
      | Error _ -> ()
      | Ok () -> Alcotest.fail "released public Path accepted launch");
      Alcotest.(check bool)
        "stale launch failed before callback" false !launched;
      acquired
        (Manager.with_workspace (manager fixture) workspace (fun _cwd -> Ok ())))

let stale_path () =
  with_fixture (fun fixture ->
      let workspace = reference fixture () in
      let escaped =
        acquired
          (Manager.with_workspace (manager fixture) workspace (fun cwd ->
               Ok cwd))
      in
      let launched = ref false in
      (match
         Host.Process.with_process (Host.process fixture.host)
           ~cwd:(shared_path escaped) ~env:(Host.Contract.environment workspace)
           ~command:"printf 'unexpected\\n' >> \"$TRACE_FILE\"" (fun _process ->
             launched := true;
             Ok ())
       with
      | Error _ -> ()
      | Ok () -> Alcotest.fail "escaped public Path accepted launch");
      Alcotest.(check bool) "stale callback skipped" false !launched;
      expect_rows fixture workspace
        [ "after_create"; "before_run"; "after_run" ];
      acquired
        (Manager.with_workspace (manager fixture) workspace (fun _cwd -> Ok ())))

let nested_cleanup () =
  with_fixture (fun fixture ->
      let workspace = reference fixture () in
      acquired
        (Manager.with_workspace (manager fixture) workspace (fun cwd ->
             Result.map_error
               (fun error -> Workspace_manager.Filesystem_error error)
               (Host.Process.with_process (Host.process fixture.host)
                  ~cwd:(shared_path cwd)
                  ~env:(Host.Contract.environment workspace)
                  ~command:
                    "printf 'ready\\n'; IFS= read -r line; printf '%s\\n' \
                     \"$line\"" (fun process ->
                    child_ready process;
                    let request_id, _ =
                      Request_id.Allocator.fresh Request_id.Allocator.empty
                    in
                    (match
                       Manager.cleanup (manager fixture)
                         { Host.Contract.request_id; workspace }
                     with
                    | Error (Workspace_manager.Ownership_conflict _) -> ()
                    | Error
                        ( Workspace_manager.Invalid_key _
                        | Workspace_manager.Unsafe_path _
                        | Workspace_manager.Filesystem_error _
                        | Workspace_manager.Hook_failed _
                        | Workspace_manager.Hook_timeout _ )
                    | Ok () ->
                        Alcotest.fail
                          "nested cleanup did not report a leased key");
                    observed (Host.Process.write process "still-open\n");
                    Alcotest.(check string)
                      "outer process remains usable" "still-open\n"
                      (read_line process);
                    match observed (Host.Process.await_exit process) with
                    | Host.Process.Exited 0 -> Ok ()
                    | Host.Process.Exited _ | Host.Process.Signaled _ ->
                        Alcotest.fail "nested cleanup disrupted child"))));
      expect_rows fixture workspace
        [ "after_create"; "before_run"; "after_run" ];
      Alcotest.(check bool)
        "busy cleanup leaves workspace" true
        (Sys.file_exists (entry fixture workspace));
      cleanup fixture workspace)

let tests =
  [
    Alcotest.test_case "live four-hook lifecycle and frozen inputs" `Quick
      lifecycle;
    Alcotest.test_case "created preparation failures roll back" `Quick
      preparation_rollback;
    Alcotest.test_case "reused preparation failure preserves contents" `Quick
      reused_failure;
    Alcotest.test_case "live monotonic hook timeout" `Quick hook_timeout;
    Alcotest.test_case "cancellation reaps before after_run and release" `Quick
      native_cancellation;
    Alcotest.test_case "escaped public Path rejects a later launch" `Quick
      stale_path;
    Alcotest.test_case "nested cleanup reports busy without closing the child"
      `Quick nested_cleanup;
  ]
