module Path : sig
  include Workspace_path.S

  val checked : t
end = struct
  type t = Checked

  let checked = Checked
  let display Checked = "/checked/hooks"
end

module Contract = Workspace_reference.Make (Path)

type observation =
  | Hook of Workspace_hooks.event
  | Opened of { cwd : string; command : string; env : (string * string) list }
  | Closed
  | Stdout
  | Stderr
  | Wrote_input
  | Monotonic_read
  | Wall_sample
  | Deadline of string
  | Mapped_error

type trace = observation list ref

let record trace event = trace := event :: !trace
let chronological trace = List.rev !trace

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let diagnostic =
  Diagnostic.make ~site:(Diagnostic.Host "hook fixture")
    ~message:"fixture boundary failure" ~remedy:"fixture control"

type input = Chunks of string list | Endless | Read_error | Eof
type status = Exit_code of int | Signal of int

type completion =
  | Immediately of status
  | After_eof of status
  | Waiting
  | Exit_error

type launch = Execute | Reject | Raise of exn * Printexc.raw_backtrace
type cleanup = Clean | Cleanup_error

let cleanup_diagnostic =
  Diagnostic.make ~site:(Diagnostic.Host "hook cleanup fixture")
    ~message:"secondary process cleanup failure" ~remedy:"fixture control"

module Process = struct
  module Path = Contract.Path

  type error = Diagnostic.t
  type exit = Exited of int | Signaled of int

  type t = {
    trace : trace;
    stdout : input;
    stderr : input;
    completion : completion;
    launch : launch;
    cleanup : cleanup;
  }

  type stream = {
    mutable input : input;
    ended : unit Eio.Promise.t;
    signal : unit Eio.Promise.u;
  }

  type process = { owner : t; stdout : stream; stderr : stream }

  let stream input =
    let ended, signal = Eio.Promise.create () in
    { input; ended; signal }

  let map_error t on_error error =
    record t.trace Mapped_error;
    on_error error

  let with_process t ~cwd ~env ~command ~on_error run =
    match t.launch with
    | Reject -> Error (map_error t on_error diagnostic)
    | Execute | Raise _ -> (
        record t.trace
          (Opened
             { cwd = Path.display cwd; command; env = Environment.bindings env });
        let primary =
          Fun.protect
            ~finally:(fun () -> record t.trace Closed)
            (fun () ->
              match t.launch with
              | Reject -> Alcotest.fail "fixture launch changed inside bracket"
              | Raise (ex, bt) -> Printexc.raise_with_backtrace ex bt
              | Execute ->
                  run
                    {
                      owner = t;
                      stdout = stream t.stdout;
                      stderr = stream t.stderr;
                    })
        in
        match (primary, t.cleanup) with
        | Error _, _ | Ok _, Clean -> primary
        | Ok _, Cleanup_error -> Error (map_error t on_error cleanup_diagnostic)
        )

  let read_stream process event stream =
    record process.owner.trace event;
    match stream.input with
    | Read_error -> Error diagnostic
    | Endless -> Ok (Some "untrusted output\000\n")
    | Eof -> Ok None
    | Chunks [] ->
        stream.input <- Eof;
        Eio.Promise.resolve stream.signal ();
        Ok None
    | Chunks (bytes :: rest) ->
        stream.input <- Chunks rest;
        Ok (Some bytes)

  let read process = read_stream process Stdout process.stdout
  let stderr process = read_stream process Stderr process.stderr

  let write process _bytes =
    record process.owner.trace Wrote_input;
    Ok ()

  let exit = function
    | Exit_code code -> Exited code
    | Signal number -> Signaled number

  let await_exit process =
    match process.owner.completion with
    | Immediately status -> Ok (exit status)
    | After_eof status ->
        Eio.Promise.await process.stdout.ended;
        Eio.Promise.await process.stderr.ended;
        Ok (exit status)
    | Waiting -> Eio.Fiber.await_cancel ()
    | Exit_error -> Error diagnostic
end

module Time = struct
  module Pure = Clock.Pure

  type t = {
    trace : trace;
    clock : Clock_posix.t;
    deadline_ready : unit Eio.Promise.u option;
  }

  let now t =
    record t.trace Monotonic_read;
    Clock_posix.now t.clock

  let sample t =
    record t.trace Wall_sample;
    Clock_posix.sample t.clock

  let sleep_until t deadline =
    record t.trace (Deadline (Count.decimal (Pure.nanoseconds deadline)));
    Option.iter (fun signal -> Eio.Promise.resolve signal ()) t.deadline_ready;
    Clock_posix.sleep_until t.clock deadline
end

module Hooks = Workspace_hooks.Make (Contract) (Process) (Time)

module Wall = struct
  type t = unit
  type time = float

  let now () = Float.nan
  let sleep_until () _ = Alcotest.fail "hook used wall-clock timer"
end

let reference config bindings =
  let base = checked (Absolute_path.parse "/tmp/symphony-hook-tests") in
  let workflow_file = checked (Workflow_path.resolve ~base "WORKFLOW.md") in
  let env = checked (Environment.of_bindings ~temp_dir:base bindings) in
  let env = Environment.public env ~deny:[ "LINEAR_API_KEY" ] ~secrets:[] in
  let settings =
    match
      Workspace_settings.parse ~env ~workflow_file
        (checked (Config_value.parse config))
    with
    | Ok settings -> settings
    | Error errors ->
        Alcotest.fail
          (String.concat "\n"
             (List.map Diagnostic.render (Nonempty_list.to_list errors)))
  in
  match
    Contract.reference ~settings
      ~env:(Environment.child env ~allow:[ "MARKER"; "LINEAR_API_KEY" ])
      ~scope:(checked (Tracker_scope.parse "hook-fixture"))
      ~issue_id:(checked (Issue_id.parse "opaque-hook-id"))
      ~identifier:(checked (Issue_identifier.parse "SYM-2; $(touch UNTRUSTED)"))
  with
  | Ok reference -> reference
  | Error _ -> Alcotest.fail "fixture reference rejected"

let configured () =
  reference
    {|{"hooks":{"before_run":"printf '%s' \"$MARKER\"","timeout_ms":10}}|}
    [ ("MARKER", "frozen"); ("LINEAR_API_KEY", "secret") ]

let make_process ?(cleanup = Clean) trace stdout stderr completion launch =
  {
    Process.trace;
    Process.stdout;
    Process.stderr;
    Process.completion;
    Process.launch;
    Process.cleanup;
  }

let fixture ?deadline_ready trace process emit =
  let mono = Eio_mock.Clock.Mono.make () in
  let wall = Eio.Resource.T ((), Eio.Time.Pi.clock (module Wall)) in
  let clock = Clock_posix.create ~mono ~wall in
  let time = { Time.trace; Time.clock; Time.deadline_ready } in
  let hooks = Hooks.create ~process ~clock:time ~emit in
  (mono, hooks)

let emitter trace _workspace _phase event = record trace (Hook event)

let run hooks workspace =
  Hooks.run hooks ~workspace ~cwd:Path.checked Workspace_settings.Before_run

let kind = function
  | Hook Workspace_hooks.Started -> "started"
  | Hook (Workspace_hooks.Finished Workspace_hooks.Cancelled) -> "cancelled"
  | Hook (Workspace_hooks.Finished (Workspace_hooks.Completed (Ok ()))) -> "ok"
  | Hook (Workspace_hooks.Finished (Workspace_hooks.Completed (Error _))) ->
      "error"
  | Opened _ -> "opened"
  | Closed -> "closed"
  | Stdout -> "stdout"
  | Stderr -> "stderr"
  | Wrote_input -> "stdin"
  | Monotonic_read -> "monotonic"
  | Wall_sample -> "wall"
  | Deadline _ -> "deadline"
  | Mapped_error -> "mapped"

let lifecycle trace =
  List.filter_map
    (function
      | (Hook _ | Opened _ | Closed) as event -> Some (kind event)
      | Stdout
      | Stderr
      | Wrote_input
      | Monotonic_read
      | Wall_sample
      | Deadline _
      | Mapped_error -> None)
    (chronological trace)

let expect_lifecycle expected trace =
  Alcotest.(check (list string)) "lifecycle" expected (lifecycle trace)

let expect_ok = function
  | Ok () -> ()
  | Error _ -> Alcotest.fail "hook failed unexpectedly"

let expect_failed = function
  | Error (Workspace_manager.Hook_failed error) -> (
      match Diagnostic.site error with
      | Diagnostic.Issue { id; identifier } ->
          Alcotest.(check string)
            "diagnostic issue" "opaque-hook-id" (Issue_id.text id);
          Alcotest.(check string)
            "diagnostic identifier" "SYM-2; $(touch UNTRUSTED)"
            (Issue_identifier.text identifier)
      | Diagnostic.Workflow _ | Diagnostic.Protocol _ | Diagnostic.Host _ ->
          Alcotest.fail "hook error lost issue identity")
  | Ok ()
  | Error
      ( Workspace_manager.Invalid_key _
      | Workspace_manager.Unsafe_path _
      | Workspace_manager.Ownership_conflict _
      | Workspace_manager.Filesystem_error _
      | Workspace_manager.Hook_timeout _ ) ->
      Alcotest.fail "expected named hook failure"

let missing_hook () =
  Eio_mock.Backend.run (fun () ->
      let trace = ref [] in
      let process = make_process trace Endless Endless Waiting Reject in
      let _, hooks = fixture trace process (emitter trace) in
      expect_ok (run hooks (reference "{}" []));
      Alcotest.(check (list string))
        "absent hook has no events or effects" []
        (List.map kind (chronological trace)))

let frozen_success () =
  Eio_mock.Backend.run (fun () ->
      let trace = ref [] in
      let workspace = configured () in
      ignore
        (reference {|{"hooks":{"before_run":"echo replaced","timeout_ms":99}}|}
           [ ("MARKER", "replacement") ]);
      let process =
        make_process trace
          (Chunks [ "out\000"; "more" ])
          (Chunks [ "err\n" ]) (After_eof (Exit_code 0)) Execute
      in
      let _, hooks = fixture trace process (emitter trace) in
      expect_ok (run hooks workspace);
      expect_lifecycle [ "started"; "opened"; "closed"; "ok" ] trace;
      let launch =
        List.filter_map
          (function
            | Opened { cwd; command; env } -> Some (cwd, command, env)
            | Hook _
            | Closed
            | Stdout
            | Stderr
            | Wrote_input
            | Monotonic_read
            | Wall_sample
            | Deadline _
            | Mapped_error -> None)
          (chronological trace)
      in
      (match launch with
      | [ (cwd, command, env) ] ->
          Alcotest.(check string) "shared checked Path" "/checked/hooks" cwd;
          Alcotest.(check string)
            "trusted script unchanged" "printf '%s' \"$MARKER\"" command;
          Alcotest.(check (list (pair string string)))
            "frozen allowlisted child env"
            [ ("MARKER", "frozen") ]
            env
      | _ -> Alcotest.fail "hook did not launch exactly once");
      let deadlines =
        List.filter_map
          (function
            | Deadline value -> Some value
            | Hook _
            | Opened _
            | Closed
            | Stdout
            | Stderr
            | Wrote_input
            | Monotonic_read
            | Wall_sample
            | Mapped_error -> None)
          (chronological trace)
      in
      Alcotest.(check (list string))
        "frozen monotonic timeout" [ "10000000" ] deadlines;
      Alcotest.(check int)
        "stdout reaches EOF" 3
        (List.length (List.filter (fun event -> kind event = "stdout") !trace));
      Alcotest.(check int)
        "stderr reaches EOF" 2
        (List.length (List.filter (fun event -> kind event = "stderr") !trace));
      Alcotest.(check bool)
        "wall sampling and stdin unused" false
        (List.exists
           (function
             | Wall_sample | Wrote_input -> true
             | Hook _
             | Opened _
             | Closed
             | Stdout
             | Stderr
             | Monotonic_read
             | Deadline _
             | Mapped_error -> false)
           !trace))

let failures () =
  Eio_mock.Backend.run (fun () ->
      List.iter
        (fun (stdout, stderr, completion, launch) ->
          let trace = ref [] in
          let process = make_process trace stdout stderr completion launch in
          let _, hooks = fixture trace process (emitter trace) in
          expect_failed (run hooks (configured ()));
          let expected =
            match launch with
            | Reject -> [ "started"; "error" ]
            | Execute | Raise _ -> [ "started"; "opened"; "closed"; "error" ]
          in
          expect_lifecycle expected trace)
        [
          (Chunks [], Chunks [], Immediately (Exit_code 42), Execute);
          (Chunks [], Chunks [], Immediately (Signal 15), Execute);
          (Chunks [], Chunks [], Exit_error, Execute);
          (Chunks [], Chunks [], Waiting, Reject);
          (Read_error, Endless, Waiting, Execute);
          (Endless, Read_error, Waiting, Execute);
        ])

let timed_run ?(cleanup = Clean) cancel observe =
  Eio_mock.Backend.run (fun () ->
      let trace = ref [] in
      let ready, signal = Eio.Promise.create () in
      let process =
        make_process ~cleanup trace Endless Endless Waiting Execute
      in
      let mono, hooks =
        fixture ~deadline_ready:signal trace process (emitter trace)
      in
      let result, publish = Eio.Promise.create () in
      let execute sw =
        Eio.Fiber.fork ~sw (fun () ->
            Eio.Promise.resolve publish (run hooks (configured ())));
        Eio.Promise.await ready;
        Eio.Fiber.yield ();
        List.iter
          (fun expected ->
            Alcotest.(check bool)
              "continuous output gets scheduling time" true
              (List.exists (fun event -> kind event = expected) !trace))
          [ "stdout"; "stderr" ];
        cancel sw mono;
        Eio.Promise.await result
      in
      observe trace (fun () -> Eio.Switch.run execute))

let deadline_timeout () =
  timed_run
    (fun _sw mono ->
      Alcotest.(check bool)
        "deadline timer registered" true
        (Eio_mock.Clock.Mono.try_advance mono))
    (fun trace execute ->
      match execute () with
      | Error (Workspace_manager.Hook_timeout _) ->
          expect_lifecycle [ "started"; "opened"; "closed"; "error" ] trace
      | Ok ()
      | Error
          ( Workspace_manager.Invalid_key _
          | Workspace_manager.Unsafe_path _
          | Workspace_manager.Ownership_conflict _
          | Workspace_manager.Filesystem_error _
          | Workspace_manager.Hook_failed _ ) ->
          Alcotest.fail "expected monotonic hook timeout")

let failure_text = function
  | Error (Workspace_manager.Hook_failed error) -> Diagnostic.render error
  | Ok ()
  | Error
      ( Workspace_manager.Invalid_key _
      | Workspace_manager.Unsafe_path _
      | Workspace_manager.Ownership_conflict _
      | Workspace_manager.Filesystem_error _
      | Workspace_manager.Hook_timeout _ ) ->
      Alcotest.fail "expected primary hook failure"

let mapped_errors trace =
  List.fold_left
    (fun count -> function
      | Mapped_error -> count + 1
      | Hook _
      | Opened _
      | Closed
      | Stdout
      | Stderr
      | Wrote_input
      | Monotonic_read
      | Wall_sample
      | Deadline _ -> count)
    0 !trace

let cleanup_failure stdout stderr completion () =
  Eio_mock.Backend.run (fun () ->
      let execute cleanup =
        let trace = ref [] in
        let process =
          make_process ~cleanup trace stdout stderr completion Execute
        in
        let _, hooks = fixture trace process (emitter trace) in
        let result = run hooks (configured ()) in
        expect_lifecycle [ "started"; "opened"; "closed"; "error" ] trace;
        Alcotest.(check int)
          "primary error bypasses process error mapper" 0 (mapped_errors trace);
        failure_text result
      in
      (* Closing errors cannot change an already failed hook's observation. *)
      Alcotest.(check string)
        "primary failure survives secondary cleanup" (execute Clean)
        (execute Cleanup_error))

let cleanup_timeout () =
  timed_run ~cleanup:Cleanup_error
    (fun _sw mono ->
      Alcotest.(check bool)
        "deadline timer registered" true
        (Eio_mock.Clock.Mono.try_advance mono))
    (fun trace execute ->
      match execute () with
      | Error (Workspace_manager.Hook_timeout _) ->
          expect_lifecycle [ "started"; "opened"; "closed"; "error" ] trace;
          Alcotest.(check int)
            "timeout bypasses process error mapper" 0 (mapped_errors trace)
      | Ok ()
      | Error
          ( Workspace_manager.Invalid_key _
          | Workspace_manager.Unsafe_path _
          | Workspace_manager.Ownership_conflict _
          | Workspace_manager.Filesystem_error _
          | Workspace_manager.Hook_failed _ ) ->
          Alcotest.fail "cleanup replaced the hook timeout")

let cleanup_success () =
  Eio_mock.Backend.run (fun () ->
      let trace = ref [] in
      let process =
        make_process ~cleanup:Cleanup_error trace (Chunks []) (Chunks [])
          (Immediately (Exit_code 0)) Execute
      in
      let _, hooks = fixture trace process (emitter trace) in
      expect_failed (run hooks (configured ()));
      Alcotest.(check int)
        "successful hook maps cleanup failure once" 1 (mapped_errors trace);
      expect_lifecycle [ "started"; "opened"; "closed"; "error" ] trace)

exception Cancel_fixture
exception Emit_fixture
exception Defect_fixture

let cancelled () =
  timed_run
    (fun sw _mono ->
      Eio.Switch.fail sw Cancel_fixture;
      Eio.Fiber.yield ())
    (fun trace execute ->
      Alcotest.check_raises "caller cancellation propagates" Cancel_fixture
        (fun () -> ignore (execute ()));
      expect_lifecycle [ "started"; "opened"; "closed"; "cancelled" ] trace)

let emit_defect trace workspace phase event =
  emitter trace workspace phase event;
  match event with
  | Workspace_hooks.Started -> ()
  | Workspace_hooks.Finished _ -> raise Emit_fixture

let report_precedence () =
  Eio_mock.Backend.run (fun () ->
      let trace = ref [] in
      let process =
        make_process trace (Chunks []) (Chunks []) (Immediately (Exit_code 0))
          Execute
      in
      let _, hooks = fixture trace process (emit_defect trace) in
      Alcotest.check_raises "successful hook exposes reporting defect"
        Emit_fixture (fun () -> ignore (run hooks (configured ())));
      expect_lifecycle [ "started"; "opened"; "closed"; "ok" ] trace;
      let trace = ref [] in
      let process =
        make_process trace (Chunks []) (Chunks []) (Immediately (Exit_code 42))
          Execute
      in
      let _, hooks = fixture trace process (emit_defect trace) in
      expect_failed (run hooks (configured ()));
      expect_lifecycle [ "started"; "opened"; "closed"; "error" ] trace)

let original_backtrace () =
  let previous = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace previous)
    (fun () ->
      List.iter
        (fun original ->
          let backtrace =
            try raise original with _ -> Printexc.get_raw_backtrace ()
          in
          let expected = Printexc.raw_backtrace_to_string backtrace in
          Eio_mock.Backend.run (fun () ->
              let trace = ref [] in
              let process =
                make_process trace (Chunks []) (Chunks []) Waiting
                  (Raise (original, backtrace))
              in
              let _, hooks = fixture trace process (emit_defect trace) in
              (try
                 ignore (run hooks (configured ()));
                 Alcotest.fail "primary exception disappeared"
               with actual ->
                 let actual_bt = Printexc.get_raw_backtrace () in
                 Alcotest.(check bool)
                   "original exception identity" true (actual == original);
                 Alcotest.(check bool)
                   "original backtrace prefix" true
                   (String.starts_with ~prefix:expected
                      (Printexc.raw_backtrace_to_string actual_bt)));
              let expected =
                match original with
                | Eio.Cancel.Cancelled _ ->
                    [ "started"; "opened"; "closed"; "cancelled" ]
                | _ -> [ "started"; "opened"; "closed" ]
              in
              expect_lifecycle expected trace))
        [ Eio.Cancel.Cancelled Cancel_fixture; Defect_fixture ])

let tests =
  [
    Alcotest.test_case "absent hook has no effects" `Quick missing_hook;
    Alcotest.test_case "frozen command environment and deadline" `Quick
      frozen_success;
    Alcotest.test_case "status and independent stream failures" `Quick failures;
    Alcotest.test_case "noisy streams cannot starve timeout" `Quick
      deadline_timeout;
    Alcotest.test_case "cancellation finishes after closure" `Quick cancelled;
    Alcotest.test_case "primary failure survives reporting defect" `Quick
      report_precedence;
    Alcotest.test_case "original exception and backtrace survive cleanup" `Quick
      original_backtrace;
    Alcotest.test_case "nonzero exit survives cleanup failure" `Quick
      (cleanup_failure (Chunks []) (Chunks []) (Immediately (Exit_code 42)));
    Alcotest.test_case "stream failure survives cleanup failure" `Quick
      (cleanup_failure Read_error Endless Waiting);
    Alcotest.test_case "timeout survives cleanup failure" `Quick cleanup_timeout;
    Alcotest.test_case "successful hook exposes cleanup failure" `Quick
      cleanup_success;
  ]
