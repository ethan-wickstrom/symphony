type gate = { promise : unit Eio.Promise.t; resolver : unit Eio.Promise.u }

let gate () =
  let promise, resolver = Eio.Promise.create () in
  { promise; resolver }

let release gate =
  match Eio.Promise.peek gate.promise with
  | Some () -> ()
  | None -> Eio.Promise.resolve gate.resolver ()

let await gate = Eio.Promise.await gate.promise

type event =
  | Launch of { cwd : string; command : string; env : (string * string) list }
  | Write of Json.t
  | Read_stdout of int
  | Read_stderr of int
  | Process_closing
  | Process_closed
  | Workspace_acquired
  | After_run
  | Lease_closing
  | Lease_released

type trace = { mutable reversed : event list; changed : Eio.Condition.t }

let trace () = { reversed = []; changed = Eio.Condition.create () }

let record trace event =
  trace.reversed <- event :: trace.reversed;
  Eio.Condition.broadcast trace.changed

let events trace = List.rev trace.reversed

let rec wait_event trace predicate =
  if List.exists predicate trace.reversed then ()
  else (
    Eio.Condition.await_no_mutex trace.changed;
    wait_event trace predicate)

let writes trace =
  List.filter_map
    (function
      | Write message -> Some message
      | Launch _
      | Read_stdout _
      | Read_stderr _
      | Process_closing
      | Process_closed
      | Workspace_acquired
      | After_run
      | Lease_closing
      | Lease_released -> None)
    (events trace)

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let json value = checked (Json.parse value)
let obj fields = checked (Json.of_view (Json.Object fields))
let text value = checked (Json.of_view (Json.String value))

let field key value =
  match Json.view value with
  | Json.Object fields -> (
      match List.assoc_opt key fields with
      | Some value -> value
      | None -> Alcotest.fail ("Missing wire field: " ^ key))
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      Alcotest.fail "Expected wire object"

let text_value value =
  match Json.view value with
  | Json.String value -> value
  | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _ ->
      Alcotest.fail "Expected wire string"

let method_name value =
  match Json.view value with
  | Json.Object fields -> Option.map text_value (List.assoc_opt "method" fields)
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      Alcotest.fail "Expected wire object"

let cwd = "/fixture/agent/SYM-9"
let version = "0.1.0-test"
let title = "SYM-9: Scoped agent fixture"

module Path = struct
  type t = { label : string }

  let display path = path.label
end

let with_path use = use { Path.label = cwd }

module Contract = Workspace_reference.Make (Path)

type 'a captured = Returned of 'a | Raised of exn * Printexc.raw_backtrace

let capture run =
  try Returned (run ())
  with error -> Raised (error, Printexc.get_raw_backtrace ())

let restore = function
  | Returned value -> value
  | Raised (error, trace) -> Printexc.raise_with_backtrace error trace

let finish primary cleanup =
  match primary with
  | Raised _ | Returned (Error _) -> restore primary
  | Returned (Ok _) ->
      restore cleanup;
      restore primary

type input = Bytes of string | Eof | Read_error of Diagnostic.t | Fault of exn

type peer = {
  trace : trace;
  on_write : peer -> Json.t -> unit;
  stdout : input Eio.Stream.t;
  errors : input Eio.Stream.t;
  exited : int Eio.Promise.t;
  exit_resolver : int Eio.Promise.u;
  mutable active : bool;
}

let pipe_capacity = 128
let chunk_bytes = 4096

let push stream value =
  let length = String.length value in
  let rec chunks offset =
    if offset = length then ()
    else
      let count = min chunk_bytes (length - offset) in
      Eio.Stream.add stream (Bytes (String.sub value offset count));
      chunks (offset + count)
  in
  chunks 0

let send peer value = push peer.stdout value
let stderr peer value = push peer.errors value

let exit peer =
  match Eio.Promise.peek peer.exited with
  | Some _ -> ()
  | None -> Eio.Promise.resolve peer.exit_resolver 0

let eof peer =
  exit peer;
  Eio.Stream.add peer.stdout Eof

let fault peer error = Eio.Stream.add peer.stdout (Fault error)
let read_error peer error = Eio.Stream.add peer.stdout (Read_error error)

module Process = struct
  module Path = Path

  type error = Diagnostic.t
  type exit = Exited of int | Signaled of int
  type process = peer

  type t = {
    trace : trace;
    close : gate option;
    fault : exn option;
    on_launch : peer -> unit;
    on_write : peer -> Json.t -> unit;
  }

  let diagnostic () =
    Diagnostic.make ~site:(Diagnostic.Host "agent-test-peer")
      ~message:"Peer scope is closed" ~remedy:"Acquire a new test peer"

  let with_process (driver : t) ~cwd ~env ~command ~on_error:_ use =
    Eio.Fiber.check ();
    let exited, exit_resolver = Eio.Promise.create () in
    let peer =
      {
        trace = driver.trace;
        on_write = driver.on_write;
        stdout = Eio.Stream.create pipe_capacity;
        errors = Eio.Stream.create pipe_capacity;
        exited;
        exit_resolver;
        active = true;
      }
    in
    record driver.trace
      (Launch
         { cwd = Path.display cwd; command; env = Environment.bindings env });
    let primary =
      capture (fun () ->
          Eio.Switch.run (fun _ ->
              driver.on_launch peer;
              use peer))
    in
    let cleanup =
      capture (fun () ->
          Eio.Cancel.protect (fun () ->
              record driver.trace Process_closing;
              Option.iter await driver.close;
              peer.active <- false;
              exit peer;
              record driver.trace Process_closed;
              Option.iter raise driver.fault))
    in
    finish primary cleanup

  let read_stream peer stream =
    Eio.Fiber.yield ();
    if not peer.active then Error (diagnostic ())
    else
      match Eio.Stream.take stream with
      | Bytes value -> Ok (Some value)
      | Eof -> Ok None
      | Read_error error -> Error error
      | Fault error -> raise error

  let read peer =
    let result = read_stream peer peer.stdout in
    (match result with
    | Ok (Some bytes) -> record peer.trace (Read_stdout (String.length bytes))
    | Ok None | Error _ -> ());
    result

  let stderr peer =
    let result = read_stream peer peer.errors in
    (match result with
    | Ok (Some bytes) -> record peer.trace (Read_stderr (String.length bytes))
    | Ok None | Error _ -> ());
    result

  let write peer frame =
    Eio.Fiber.yield ();
    if not peer.active then Error (diagnostic ())
    else if frame = "" then Ok ()
    else (
      if not (String.ends_with ~suffix:"\n" frame) then
        Alcotest.fail "Outbound frame lacks LF";
      let message = json (String.sub frame 0 (String.length frame - 1)) in
      record peer.trace (Write message);
      peer.on_write peer message;
      Ok ())

  let await_exit peer =
    if not peer.active then Error (diagnostic ())
    else Ok (Exited (Eio.Promise.await peer.exited))
end

let process ?close ?fault ?(on_launch = fun _ -> ()) trace on_write =
  { Process.trace; close; fault; on_launch; on_write }

type cleanup_stage = After_hook | Report

module Workspace = struct
  module Contract = Contract

  type t = {
    trace : trace;
    after_run : gate option;
    release : gate option;
    fault : (cleanup_stage * exn) option;
  }

  let with_workspace (driver : t) _reference ~on_error:_ use =
    Eio.Fiber.check ();
    record driver.trace Workspace_acquired;
    let primary = capture (fun () -> with_path use) in
    let cleanup =
      capture (fun () ->
          Eio.Cancel.protect (fun () ->
              record driver.trace After_run;
              Option.iter await driver.after_run;
              match driver.fault with
              | None -> ()
              | Some (After_hook, error) | Some (Report, error) -> raise error))
    in
    Eio.Cancel.protect (fun () ->
        record driver.trace Lease_closing;
        Option.iter await driver.release;
        record driver.trace Lease_released);
    finish primary cleanup

  let cleanup _driver _request = Ok ()
  let inspect _driver _reference = Ok None
end

let workspace ?after_run ?release ?fault trace =
  { Workspace.trace; after_run; release; fault }

let base = checked (Absolute_path.parse "/fixture/agent")
let prompt_file = checked (Workflow_path.resolve ~base "WORKFLOW.md")

let public =
  checked
    (Environment.of_bindings ~temp_dir:base
       [ ("MARKER", "agent-test"); ("LINEAR_API_KEY", "test-secret") ])
  |> fun env -> Environment.public env ~deny:[ "LINEAR_API_KEY" ] ~secrets:[]

let environment = Environment.child public ~allow:[ "MARKER"; "LINEAR_API_KEY" ]

let diagnostics errors =
  Alcotest.fail
    (String.concat "\n"
       (List.map Diagnostic.render (Nonempty_list.to_list errors)))

let settings ?(read_ms = 20) ?(turn_ms = 50) ?(max_turns = 3) () =
  let config =
    checked
      (Config_value.parse
         (Printf.sprintf
            {|{"agent":{"max_turns":%d},"codex":{"command":"agent app-server","read_timeout_ms":%d,"turn_timeout_ms":%d}}|}
            max_turns read_ms turn_ms))
  in
  match Agent_settings.parse ~env:public config with
  | Ok value -> value
  | Error errors -> diagnostics errors

let issue ?(title = "Scoped agent fixture") () =
  checked
    (Issue.parse
       {
         Issue.id = "opaque-agent-9";
         identifier = "SYM-9";
         title;
         description = Some "Test the scoped attempt";
         priority = None;
         state = "Doing";
         branch_name = None;
         url = None;
         assignee_id = None;
         labels = [];
         blocked_by = [];
         created_at = None;
         updated_at = None;
         dispatchable = Issue.Dispatchable;
         native_ref = None;
       })

let reference () =
  let config =
    checked (Config_value.parse {|{"workspace":{"root":"/fixture/agent"}}|})
  in
  let settings =
    match
      Workspace_settings.parse ~env:public ~workflow_file:prompt_file config
    with
    | Ok value -> value
    | Error errors -> diagnostics errors
  in
  match
    Contract.reference ~settings ~env:environment
      ~scope:(checked (Tracker_scope.parse "agent-tests"))
      ~issue_id:(Issue.id (issue ()))
      ~identifier:(Issue.identifier (issue ()))
  with
  | Ok value -> value
  | Error _ -> Alcotest.fail "Agent test reference was rejected"

let fresh_run () = fst (Run_id.Allocator.fresh Run_id.Allocator.empty)

let reply peer call result =
  send peer
    (Json.encode (obj [ ("id", field "id" call); ("result", result) ]) ^ "\n")

let notify peer method_name params =
  send peer
    (Json.encode (obj [ ("method", text method_name); ("params", params) ])
    ^ "\n")

let request peer ~id method_name params =
  send peer
    (Json.encode
       (obj [ ("id", id); ("method", text method_name); ("params", params) ])
    ^ "\n")

(* Shapes come from the retained 0.159.2 generated response schemas. *)
let thread_result =
  json
    (Printf.sprintf
       {|{"thread":{"id":"thread-9","sessionId":"session-9","cliVersion":"0.159.2","createdAt":0,"updatedAt":0,"cwd":%s,"ephemeral":true,"modelProvider":"openai","preview":"","projectId":null,"source":"appServer","status":{"type":"idle"},"turns":[]},"cwd":%s,"model":"test-model","modelProvider":"openai","approvalPolicy":"never","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite","writableRoots":[%s],"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false}}|}
       (Json.encode (text cwd))
       (Json.encode (text cwd))
       (Json.encode (text cwd)))

let turn ?(error = json "null") ~id ~status () =
  obj
    [
      ("id", text id);
      ("items", json "[]");
      ("status", text status);
      ("error", error);
    ]

let completed peer ?(thread = "thread-9") ?error ~id ~status () =
  notify peer "turn/completed"
    (obj [ ("threadId", text thread); ("turn", turn ?error ~id ~status ()) ])

let server ~turn peer call =
  match method_name call with
  | Some "initialize" ->
      reply peer call
        (json
           {|{"userAgent":"fixture","codexHome":"/fixture/codex","platformFamily":"unix","platformOs":"macos"}|})
  | Some "initialized" -> ()
  | Some "thread/start" -> reply peer call thread_result
  | Some "thread/name/set" -> reply peer call (json "{}")
  | Some "turn/start" -> turn peer call
  | Some "turn/interrupt" ->
      reply peer call (json "{}");
      let id = field "params" call |> field "turnId" |> text_value in
      completed peer ~id ~status:"interrupted" ()
  | Some _ | None -> ()

type mono = Eio_mock.Clock.Mono.t

let clock () =
  let mono = Eio_mock.Clock.Mono.make () in
  let wall = Eio_mock.Clock.make () in
  (mono, Clock_posix.create ~mono ~wall)

let nanoseconds_per_ms = 1_000_000L

let advance mono milliseconds =
  Eio_mock.Clock.Mono.set_time mono
    (Mtime.of_uint64_ns
       (Int64.mul (Int64.of_int milliseconds) nanoseconds_per_ms))
