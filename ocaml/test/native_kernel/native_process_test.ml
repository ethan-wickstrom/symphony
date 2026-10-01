module Store = Workspace_store_posix
module Contract = Store.Contract
module Process = Workspace_process_posix.Make (Clock_posix)

let checked = function
  | Ok value -> value
  | Error reason -> Alcotest.fail reason

let workspace_error = function
  | Workspace_manager.Invalid_key diagnostic
  | Workspace_manager.Unsafe_path diagnostic
  | Workspace_manager.Ownership_conflict diagnostic
  | Workspace_manager.Filesystem_error diagnostic
  | Workspace_manager.Hook_failed diagnostic
  | Workspace_manager.Hook_timeout diagnostic -> Diagnostic.render diagnostic

let acquired = function
  | Ok value -> value
  | Error error -> Alcotest.fail (workspace_error error)

let succeeded = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Diagnostic.render error)

let rejected = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "Closed process accepted an operation"

let reference root env child =
  let base = checked (Absolute_path.parse root) in
  let workflow_file = checked (Workflow_path.resolve ~base "WORKFLOW.md") in
  let config =
    checked
      (Config_value.parse
         (Yojson.Safe.to_string
            (`Assoc [ ("workspace", `Assoc [ ("root", `String root) ]) ])))
  in
  let settings =
    match Workspace_settings.parse ~env ~workflow_file config with
    | Ok settings -> settings
    | Error errors ->
        Alcotest.fail
          (String.concat "\n"
             (List.map Diagnostic.render (Nonempty_list.to_list errors)))
  in
  acquired
    (Contract.reference ~settings ~env:child
       ~scope:(checked (Tracker_scope.parse "native-process-test"))
       ~issue_id:(checked (Issue_id.parse "opaque-process"))
       ~identifier:(checked (Issue_identifier.parse "SYM-process")))

let with_fixture ?(released = fun ~store:_ ~issue:_ ~cwd:_ -> ()) run =
  Eio_posix.run (fun host ->
      let base = Filename.temp_file "symphony-process-" "" in
      Unix.unlink base;
      Unix.mkdir base 0o700;
      let fs = Eio.Stdenv.fs host in
      Fun.protect
        (fun () ->
          let root = Filename.concat base "workspaces" in
          let env =
            checked
              (Environment.of_bindings
                 ~temp_dir:(checked (Absolute_path.parse base))
                 [
                   ("HOME", base);
                   ("SYMPHONY_ALLOWED", "literal $(echo injected)");
                   ("SYMPHONY_SECRET", "tracker-token");
                   ("SYMPHONY_HIDDEN", "host-private");
                 ])
          in
          let env =
            Environment.public env ~deny:[ "SYMPHONY_SECRET" ] ~secrets:[]
          in
          let child =
            Environment.child env
              ~allow:[ "HOME"; "SYMPHONY_ALLOWED"; "SYMPHONY_SECRET" ]
          in
          let issue = reference root env child in
          let clock =
            Clock_posix.create
              ~mono:(Eio.Stdenv.mono_clock host)
              ~wall:(Eio.Stdenv.clock host)
          in
          let store =
            Store.create ~fs ~close_path:Workspace_path_posix.close
              ~report:(fun error -> Alcotest.fail (workspace_error error))
          in
          let cwd, result =
            acquired
              (Store.with_lease store issue (fun _ lease ->
                   let cwd = acquired (Store.path lease) in
                   (cwd, run ~clock ~child ~cwd)))
          in
          released ~store ~issue ~cwd;
          result)
        ~finally:(fun () -> Eio.Path.rmtree (Eio.Path.( / ) fs base)))

let collect read =
  let buffer = Buffer.create 4096 in
  let rec chunks () =
    match succeeded (read ()) with
    | None -> Buffer.contents buffer
    | Some bytes ->
        Alcotest.(check bool) "chunk bound" true (String.length bytes <= 4096);
        Buffer.add_string buffer bytes;
        chunks ()
  in
  chunks ()

let streams () =
  with_fixture (fun ~clock ~child ~cwd ->
      let process =
        Process.create ~clock ~report:(fun error ->
            Alcotest.fail (Diagnostic.render error))
      in
      let frame = String.make (3 * 65536) 'x' in
      let escaped =
        succeeded
          (Process.with_process process ~on_error:Fun.id ~cwd ~env:child
             ~command:
               "IFS= read -r line; printf '%s' \"$line\"; printf 'separate' \
                >&2; exit 7" (fun running ->
               let statuses, (output, errors) =
                 Eio.Fiber.pair
                   (fun () ->
                     succeeded (Process.write running (frame ^ "\n"));
                     let first = succeeded (Process.await_exit running) in
                     let second = succeeded (Process.await_exit running) in
                     (first, second))
                   (fun () ->
                     Eio.Fiber.pair
                       (fun () -> collect (fun () -> Process.read running))
                       (fun () -> collect (fun () -> Process.stderr running)))
               in
               Alcotest.(check string) "entire frame" frame output;
               Alcotest.(check string) "separate stderr" "separate" errors;
               (match statuses with
               | Process.Exited 7, Process.Exited 7 -> ()
               | ( (Process.Exited _ | Process.Signaled _),
                   (Process.Exited _ | Process.Signaled _) ) ->
                   Alcotest.fail
                     "Exit observations changed or returned wrong status");
               Ok running))
      in
      rejected (Process.read escaped);
      rejected (Process.stderr escaped);
      rejected (Process.write escaped "");
      rejected (Process.await_exit escaped))

let environment () =
  with_fixture (fun ~clock ~child ~cwd ->
      let process =
        Process.create ~clock ~report:(fun error ->
            Alcotest.fail (Diagnostic.render error))
      in
      let output =
        succeeded
          (Process.with_process process ~on_error:Fun.id ~cwd ~env:child
             ~command:
               "printf '%s\n\
                %s|%s|%s' \"$PWD\" \"$SYMPHONY_ALLOWED\" \
                \"${SYMPHONY_SECRET-unset}\" \"${SYMPHONY_HIDDEN-unset}\""
             (fun running -> Ok (collect (fun () -> Process.read running))))
      in
      match String.split_on_char '\n' output with
      | [ physical_cwd; values ] ->
          let identity path =
            let stat = Unix.LargeFile.stat path in
            (stat.Unix.LargeFile.st_dev, stat.Unix.LargeFile.st_ino)
          in
          Alcotest.(check (pair int int))
            "descriptor cwd identity"
            (identity (Process.Path.display cwd))
            (identity physical_cwd);
          Alcotest.(check string)
            "literal filtered values" "literal $(echo injected)|unset|unset"
            values
      | [] | [ _ ] | _ :: _ :: _ ->
          Alcotest.fail "Child did not report its cwd and environment")

module Broken_clock = struct
  module Pure = Clock.Pure

  type t = unit

  let error =
    Diagnostic.make ~site:(Diagnostic.Host "test clock")
      ~message:"clock unavailable" ~remedy:"restore the injected test clock"

  let now () = Error error
  let sample () = Error error
  let sleep_until () _ = Error error
end

module Broken = Workspace_process_posix.Make (Broken_clock)

exception Reporter_defect
exception Mapper_defect
exception Stop

let sleeper = "printf '%s\n' \"$$\"; exec /bin/sleep 30"

let pid read =
  let buffer = Buffer.create 32 in
  let rec line () =
    match succeeded (read ()) with
    | None -> Alcotest.fail "Child exited before announcing its identity"
    | Some bytes -> (
        Buffer.add_string buffer bytes;
        let contents = Buffer.contents buffer in
        match String.index_opt contents '\n' with
        | None -> line ()
        | Some ending -> int_of_string (String.sub contents 0 ending))
  in
  line ()

let reaped child =
  match Unix.kill child 0 with
  | () -> Alcotest.fail "Direct child remained after process bracket"
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> ()

let broken () = Broken.create ~clock:() ~report:(fun _ -> raise Reporter_defect)

let primary_error () =
  with_fixture (fun ~clock:_ ~child ~cwd ->
      let original =
        Diagnostic.make ~site:(Diagnostic.Host "callback")
          ~message:"primary rejected" ~remedy:"repair the callback"
      in
      let children = ref [] in
      let result =
        Broken.with_process (broken ()) ~on_error:Fun.id ~cwd ~env:child
          ~command:sleeper (fun running ->
            children := [ pid (fun () -> Broken.read running) ];
            Error original)
      in
      (match result with
      | Error observed ->
          Alcotest.(check bool)
            "primary diagnostic identity" true (observed == original)
      | Ok _ -> Alcotest.fail "Primary error disappeared");
      List.iter reaped !children)

let primary_defect () =
  with_fixture (fun ~clock:_ ~child ~cwd ->
      let original = Failure "callback defect" in
      let children = ref [] in
      let traces = ref [] in
      let result =
        Native_outcome.capture (fun () ->
            Broken.with_process (broken ()) ~on_error:Fun.id ~cwd ~env:child
              ~command:sleeper (fun running ->
                children := [ pid (fun () -> Broken.read running) ];
                try raise original
                with exn ->
                  let trace = Printexc.get_raw_backtrace () in
                  traces := [ trace ];
                  Printexc.raise_with_backtrace exn trace))
      in
      (match result with
      | Native_outcome.Raised (observed, trace) -> (
          Alcotest.(check bool)
            "primary exception identity" true (observed == original);
          match !traces with
          | [ expected ] ->
              Alcotest.(check bool)
                "nonempty original backtrace" true
                (Printexc.raw_backtrace_length expected > 0);
              Alcotest.(check bool)
                "original backtrace retained" true
                (String.starts_with
                   ~prefix:(Printexc.raw_backtrace_to_string expected)
                   (Printexc.raw_backtrace_to_string trace))
          | [] | _ :: _ -> Alcotest.fail "Callback backtrace was not captured")
      | Native_outcome.Returned (Ok _ | Error _) ->
          Alcotest.fail "Primary exception disappeared");
      List.iter reaped !children)

let cancellation () =
  with_fixture (fun ~clock:_ ~child ~cwd ->
      let children = ref [] in
      let outcome =
        Native_outcome.capture (fun () ->
            Eio.Cancel.sub (fun cancel ->
                Broken.with_process (broken ()) ~on_error:Fun.id ~cwd ~env:child
                  ~command:sleeper (fun running ->
                    children := [ pid (fun () -> Broken.read running) ];
                    Eio.Cancel.cancel cancel Stop;
                    Eio.Fiber.check ();
                    Ok ())))
      in
      (match outcome with
      | Native_outcome.Raised (Eio.Cancel.Cancelled Stop, _) -> ()
      | Native_outcome.Raised _ -> Alcotest.fail "Cancellation was replaced"
      | Native_outcome.Returned (Ok () | Error _) ->
          Alcotest.fail "Cancellation disappeared");
      List.iter reaped !children)

let cleanup_defect () =
  with_fixture (fun ~clock:_ ~child ~cwd ->
      let children = ref [] in
      let outcome =
        Native_outcome.capture (fun () ->
            Broken.with_process (broken ()) ~on_error:Fun.id ~cwd ~env:child
              ~command:sleeper (fun running ->
                children := [ pid (fun () -> Broken.read running) ];
                Ok ()))
      in
      (match outcome with
      | Native_outcome.Raised (Reporter_defect, _) -> ()
      | Native_outcome.Raised _ ->
          Alcotest.fail "Wrong cleanup defect propagated"
      | Native_outcome.Returned (Ok () | Error _) ->
          Alcotest.fail "Cleanup reporter defect disappeared");
      List.iter reaped !children)

let semantic_error () =
  with_fixture (fun ~clock:_ ~child ~cwd ->
      let original =
        Workspace_manager.Hook_timeout
          (Diagnostic.make ~site:(Diagnostic.Host "callback hook")
             ~message:"hook deadline reached" ~remedy:"repair the hook")
      in
      let children = ref [] in
      let reports = ref [] in
      let mapped = ref 0 in
      let process =
        Broken.create ~clock:() ~report:(fun error ->
            reports := error :: !reports)
      in
      let result =
        Broken.with_process process ~cwd ~env:child ~command:sleeper
          ~on_error:(fun _ ->
            incr mapped;
            raise Mapper_defect)
          (fun running ->
            children := [ pid (fun () -> Broken.read running) ];
            Error original)
      in
      (match result with
      | Error observed ->
          Alcotest.(check bool)
            "semantic callback error identity" true (observed == original)
      | Ok _ -> Alcotest.fail "Semantic callback error disappeared");
      Alcotest.(check int) "shadowed cleanup never maps" 0 !mapped;
      Alcotest.(check bool)
        "cleanup clock failure was reported" true
        (List.exists (fun error -> error == Broken_clock.error) !reports);
      List.iter reaped !children)

let mapped_cleanup () =
  with_fixture (fun ~clock:_ ~child ~cwd ->
      let children = ref [] in
      let mapped = ref [] in
      let original = Workspace_manager.Hook_failed Broken_clock.error in
      let process = Broken.create ~clock:() ~report:(fun _ -> ()) in
      let result =
        Broken.with_process process ~cwd ~env:child ~command:sleeper
          ~on_error:(fun error ->
            (* Policy conversion follows complete native child closure. *)
            List.iter reaped !children;
            mapped := error :: !mapped;
            original)
          (fun running ->
            children := [ pid (fun () -> Broken.read running) ];
            Ok ())
      in
      (match result with
      | Error observed ->
          Alcotest.(check bool)
            "mapped cleanup error identity" true (observed == original)
      | Ok () -> Alcotest.fail "Expected cleanup error disappeared");
      match !mapped with
      | [ error ] ->
          Alcotest.(check bool)
            "first expected cleanup diagnostic" true
            (error == Broken_clock.error)
      | [] | _ :: _ -> Alcotest.fail "Cleanup conversion did not run once")

let mapping_defect () =
  with_fixture (fun ~clock:_ ~child ~cwd ->
      let children = ref [] in
      let traces = ref [] in
      let original = Mapper_defect in
      let process = Broken.create ~clock:() ~report:(fun _ -> ()) in
      let outcome =
        Native_outcome.capture (fun () ->
            Broken.with_process process ~cwd ~env:child ~command:sleeper
              ~on_error:(fun _ ->
                List.iter reaped !children;
                try raise original
                with exn ->
                  let trace = Printexc.get_raw_backtrace () in
                  traces := [ trace ];
                  Printexc.raise_with_backtrace exn trace)
              (fun running ->
                children := [ pid (fun () -> Broken.read running) ];
                Ok ()))
      in
      (match outcome with
      | Native_outcome.Raised (observed, trace) -> (
          Alcotest.(check bool)
            "mapper exception identity" true (observed == original);
          match !traces with
          | [ expected ] ->
              Alcotest.(check bool)
                "nonempty mapper backtrace" true
                (Printexc.raw_backtrace_length expected > 0);
              Alcotest.(check bool)
                "mapper backtrace retained" true
                (String.starts_with
                   ~prefix:(Printexc.raw_backtrace_to_string expected)
                   (Printexc.raw_backtrace_to_string trace))
          | [] | _ :: _ -> Alcotest.fail "Mapper backtrace was not captured")
      | Native_outcome.Returned (Ok () | Error _) ->
          Alcotest.fail "Cleanup mapper defect disappeared");
      List.iter reaped !children)

module Recording_clock = struct
  module Pure = Clock.Pure

  type event =
    | Observed of Pure.instant
    | Slept of Pure.instant
    | Woke of Pure.instant

  type fault = Healthy | Once of Diagnostic.t

  type t = {
    native : Clock_posix.t;
    mutable events : event list;
    mutable fault : fault;
  }

  let now t =
    match t.fault with
    | Once error ->
        t.fault <- Healthy;
        Error error
    | Healthy ->
        Result.map
          (fun instant ->
            t.events <- Observed instant :: t.events;
            instant)
          (Clock_posix.now t.native)

  let sample t = Clock_posix.sample t.native

  let sleep_until t deadline =
    t.events <- Slept deadline :: t.events;
    Result.bind (Clock_posix.sleep_until t.native deadline) (fun () ->
        Result.map
          (fun instant -> t.events <- Woke instant :: t.events)
          (Clock_posix.now t.native))
end

module Recorded = Workspace_process_posix.Make (Recording_clock)

let grace_report reports error = reports := error :: !reports

let process_remedy =
  "Check the workspace process, host pipes and supplied capabilities"

let permission_error site =
  Diagnostic.make ~site:(Diagnostic.Host site)
    ~message:("group signal: " ^ Unix.error_message Unix.EPERM)
    ~remedy:process_remedy

type platform = Darwin | Other

let platform () =
  let channel =
    Unix.open_process_args_in "/usr/bin/uname" [| "uname"; "-s" |]
  in
  let system =
    Fun.protect
      (fun () -> input_line channel)
      ~finally:(fun () ->
        match Unix.close_process_in channel with
        | Unix.WEXITED 0 -> ()
        | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
            Alcotest.fail "Host system query failed")
  in
  match system with
  | "Darwin" -> Darwin
  | _ -> Other

let conservative system site error =
  (* The public report redacts native causes into Diagnostic.t, so a typed
     Group_signal EPERM is unavailable. Check the whole public diagnostic;
     uncertainty stays observable and every other error still fails. *)
  match (system, Diagnostic.site error) with
  | Darwin, Diagnostic.Host observed ->
      String.equal observed site
      && String.equal
           (Diagnostic.render (permission_error site))
           (Diagnostic.render error)
  | Other, Diagnostic.Host _
  | ( (Darwin | Other),
      (Diagnostic.Workflow _ | Diagnostic.Issue _ | Diagnostic.Protocol _) ) ->
      false

let log_conservative error =
  Format.eprintf "Retained conservative Darwin cleanup error: %s@."
    (Diagnostic.render error)

let check_cleanup system site reports result =
  match (result, List.rev reports) with
  | Ok (), [] -> ()
  | Error error, [ report ] when conservative system site error ->
      Alcotest.(check string)
        "outer Error matches retained cleanup report" (Diagnostic.render report)
        (Diagnostic.render error);
      log_conservative error
  | Error error, _ -> Alcotest.fail (Diagnostic.render error)
  | Ok (), _ :: _ -> Alcotest.fail "Reported cleanup error became success"

let lease_closed ~store ~issue ~cwd =
  (match Workspace_path_posix.check cwd with
  | Error (Workspace_manager.Unsafe_path _) -> ()
  | Ok () -> Alcotest.fail "Workspace path remained live after lease closure"
  | Error
      (( Workspace_manager.Invalid_key _
       | Workspace_manager.Ownership_conflict _
       | Workspace_manager.Filesystem_error _
       | Workspace_manager.Hook_failed _
       | Workspace_manager.Hook_timeout _ ) as error) ->
      Alcotest.fail (workspace_error error));
  acquired
    (Store.with_existing store issue (function
      | Some lease -> ignore (acquired (Store.path lease))
      | None -> Alcotest.fail "Workspace disappeared after process cleanup"))

let injected_report () =
  with_fixture ~released:lease_closed (fun ~clock ~child ~cwd ->
      let site = Contract.Path.display cwd in
      let original = permission_error site in
      let recorded =
        Recording_clock.{ native = clock; events = []; fault = Once original }
      in
      let children = ref [] in
      let reports = ref [] in
      let process =
        Recorded.create ~clock:recorded ~report:(grace_report reports)
      in
      let result =
        Recorded.with_process process ~on_error:Fun.id ~cwd ~env:child
          ~command:sleeper (fun running ->
            children := [ pid (fun () -> Recorded.read running) ];
            Ok ())
      in
      List.iter reaped !children;
      (match result with
      | Error error ->
          Alcotest.(check bool)
            "injected cleanup error retains identity" true (error == original)
      | Ok () -> Alcotest.fail "Injected cleanup error disappeared");
      Alcotest.(check int)
        "injected cleanup report occurs once" 1
        (List.length (List.filter (fun error -> error == original) !reports));
      let system = platform () in
      List.iter
        (fun error ->
          if error != original then (
            Alcotest.(check bool)
              "additional report is documented Darwin disposition" true
              (conservative system site error);
            log_conservative error))
        !reports;
      Alcotest.(check bool)
        "exact Darwin disposition" true
        (conservative Darwin site original);
      Alcotest.(check bool)
        "Linux retains permission failures" false
        (conservative Other site original);
      let foreign = permission_error (site ^ "/foreign") in
      Alcotest.(check bool)
        "foreign-site permission error rejects" false
        (conservative Darwin site foreign);
      let extra =
        Diagnostic.make ~site:(Diagnostic.Host site)
          ~message:
            ("group signal: "
            ^ Unix.error_message Unix.EPERM
            ^ "; child reap: "
            ^ Unix.error_message Unix.ECHILD)
          ~remedy:process_remedy
      in
      Alcotest.(check bool)
        "additional reap failure rejects" false
        (conservative Darwin site extra))

let kill_after_grace () =
  with_fixture ~released:lease_closed (fun ~clock ~child ~cwd ->
      let recorded =
        Recording_clock.{ native = clock; events = []; fault = Healthy }
      in
      let reports = ref [] in
      let process =
        Recorded.create ~clock:recorded ~report:(grace_report reports)
      in
      let children = ref [] in
      let result =
        Recorded.with_process process ~on_error:Fun.id ~cwd ~env:child
          ~command:"trap '' TERM; printf '%s\n' \"$$\"; exec /bin/sleep 30"
          (fun running ->
            children := [ pid (fun () -> Recorded.read running) ];
            Ok ())
      in
      List.iter reaped !children;
      check_cleanup (platform ()) (Contract.Path.display cwd) !reports result;
      match List.rev recorded.Recording_clock.events with
      | Recording_clock.Observed since
        :: Recording_clock.Slept deadline
        :: Recording_clock.Woke woke
        :: _ ->
          let expected =
            Clock.Pure.after since (checked (Milliseconds.parse "1000"))
          in
          Alcotest.(check int)
            "fixed exact TERM grace deadline" 0
            (Clock.Pure.compare deadline expected);
          Alcotest.(check bool)
            "timer woke after full TERM grace before KILL" true
            (Clock.Pure.compare woke expected >= 0)
      | []
      | [ _ ]
      | ( Recording_clock.Observed _
        | Recording_clock.Slept _
        | Recording_clock.Woke _ )
        :: ( Recording_clock.Observed _
           | Recording_clock.Slept _
           | Recording_clock.Woke _ )
        :: _ -> Alcotest.fail "TERM grace did not use the injected clock")

let escaped_read () =
  with_fixture (fun ~clock ~child ~cwd ->
      Eio.Switch.run (fun outer ->
          let producer = ref [] in
          let completed, resolved = Eio.Promise.create () in
          let pending = ref [] in
          let process =
            Process.create ~clock ~report:(fun error ->
                Alcotest.fail (Diagnostic.render error))
          in
          let command =
            "/usr/bin/python3 -c 'import os, signal\n\
             child = os.fork()\n\
             if child == 0:\n\
             \x20print(os.getpid(), flush=True)\n\
             \x20os.read(0, 1)\n\
             \x20os.setsid()\n\
             \x20print(\"ready\", flush=True)\n\
             while True: signal.pause()'"
          in
          let ready () =
            let joined =
              succeeded
                (Process.with_process process ~on_error:Fun.id ~cwd ~env:child
                   ~command (fun running ->
                     (* Record ownership before granting permission to escape. *)
                     producer := [ pid (fun () -> Process.read running) ];
                     succeeded (Process.write running "!");
                     (match succeeded (Process.read running) with
                     | Some "ready\n" -> ()
                     | Some _ | None -> Alcotest.fail "Producer did not escape");
                     let started, start = Eio.Promise.create () in
                     Eio.Fiber.fork ~sw:outer (fun () ->
                         Eio.Promise.resolve start ();
                         let outcome =
                           Native_outcome.capture (fun () ->
                               Process.read running)
                         in
                         Eio.Promise.resolve resolved outcome);
                     pending := [ completed ];
                     Eio.Promise.await started;
                     Eio.Fiber.yield ();
                     Ok ()))
            in
            ignore joined;
            Eio.Promise.is_resolved completed
          in
          let joined_before_return =
            Fun.protect ready ~finally:(fun () ->
                List.iter
                  (fun owned ->
                    try Unix.kill owned Sys.sigkill
                    with Unix.Unix_error (Unix.ESRCH, _, _) -> ())
                  !producer;
                (* Join the escaped read on both red and green executions. *)
                List.iter
                  (fun operation -> ignore (Eio.Promise.await operation))
                  !pending)
          in
          Alcotest.(check bool)
            "pending operation joined before bracket returned" true
            joined_before_return;
          match Eio.Promise.await completed with
          | Native_outcome.Returned (Error _) -> ()
          | Native_outcome.Returned (Ok _) | Native_outcome.Raised _ ->
              Alcotest.fail "Closing did not revoke the pending operation"))

let tests =
  [
    Alcotest.test_case
      "full frames, bounded streams, stable exit and closed methods" `Quick
      streams;
    Alcotest.test_case "descriptor cwd and exact allowlisted environment" `Quick
      environment;
    Alcotest.test_case "callback Error survives timer and reporter defects"
      `Quick primary_error;
    Alcotest.test_case
      "callback defect retains identity and backtrace after reap" `Quick
      primary_defect;
    Alcotest.test_case "cancellation survives cleanup defects and reaps" `Quick
      cancellation;
    Alcotest.test_case "escaped pending read closes before process return"
      `Quick escaped_read;
    Alcotest.test_case "successful callback exposes reporter defect after reap"
      `Quick cleanup_defect;
    Alcotest.test_case "semantic callback error never maps cleanup" `Quick
      semantic_error;
    Alcotest.test_case "successful callback maps cleanup once after reap" `Quick
      mapped_cleanup;
    Alcotest.test_case "cleanup mapper defect retains backtrace after reap"
      `Quick mapping_defect;
    Alcotest.test_case "TERM-resistant child uses exact grace then KILL/reap"
      `Quick kill_after_grace;
    Alcotest.test_case "conservative cleanup report retains expected Error"
      `Quick injected_report;
  ]
