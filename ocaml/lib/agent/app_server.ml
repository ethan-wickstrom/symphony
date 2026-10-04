type error =
  | Failure of Agent_runner.failure
  | Deadline of Agent_runner.timeout
  | Stopped of {
      interrupt : Agent_runner.interrupt;
      remote_error : Diagnostic.t option;
    }

type terminal =
  | Completed
  | Failed of Diagnostic.t
  | Interrupted of Diagnostic.t option
  | Input_required of Diagnostic.t

type ended = { turn : Turn_id.t; outcome : terminal }

let ( let* ) = Result.bind

type 'a captured = Returned of 'a | Raised of exn * Printexc.raw_backtrace

let capture run =
  try Returned (run ()) with
  | Eio.Cancel.Cancelled _ as error ->
      let trace = Printexc.get_raw_backtrace () in
      Eio.Fiber.check ();
      Raised (error, trace)
  | error -> Raised (error, Printexc.get_raw_backtrace ())

let restore = function
  | Returned value -> value
  | Raised (error, trace) -> Printexc.raise_with_backtrace error trace

let choose a b =
  match (a, b) with
  | Raised (a, at), Raised (b, bt) ->
      let error, trace = Eio.Exn.combine (a, at) (b, bt) in
      Raised (error, trace)
  | Raised _, Returned _ -> a
  | Returned _, Raised _ -> b
  | Returned _, Returned _ -> a

let diagnostic message =
  Diagnostic.make
    ~site:
      (Diagnostic.Protocol { method_name = "app-server"; request_id = None })
    ~message ~remedy:"Check the configured Codex command and protocol profile."

let failure value : error = Failure value

let protocol_error method_name error =
  failure
    (Agent_runner.Response_error (Protocol_codec.diagnostic ~method_name error))

module Make (Process : Agent_process.S) (Clock : Clock.S) = struct
  module Path = Process.Path
  module Policy = Agent_settings.Bind (Path)

  module Id_map = Map.Make (struct
    type t = Protocol_id.t

    let compare = Protocol_id.compare
  end)

  let read_chunk_limit = 65_536
  let replay_limit = 128
  let early_limit = 128
  let mailbox_capacity = 1

  type packet = Bytes of string | Eof
  type mode = Active | Closing
  type phase = Ready | Awaiting of Turn_id.t option
  type pipe = Open_pipe | Ended_pipe

  type current = {
    id : Turn_id.t;
    session : Session_id.t;
    mutable terminal : terminal option;
  }

  type replay = { request : Json.t; response : Protocol_envelope.t option }

  type session = {
    process : Process.process;
    clock : Clock.t;
    interrupt : Agent_runner.interrupt Eio.Promise.t;
    settings : Agent_settings.t;
    cwd : string;
    policy : Json.t;
    packets : packet Eio.Stream.t;
    changed : Eio.Condition.t;
    mutable fault : error option;
    mutable last_stdout : Clock.Pure.instant;
    mutable frame : Protocol_frame.t;
    mutable frames : Json.t list;
    mutable frame_error : error option;
    mutable pipe : pipe;
    mutable next_id : Positive_count.t;
    mutable replays : replay Id_map.t;
    mutable replay_bytes : int;
    mutable thread : Thread_id.t option;
    mutable current : current option;
    mutable phase : phase;
    mutable pending_terminal : terminal option;
    mutable input : Diagnostic.t option;
    mutable pending_events : Agent_runner.event list;
    mutable known : Turn_id.Set.t;
    mutable early : Protocol_envelope.t list;
    mutable early_bytes : int;
    mutable pending_rate : Json.t option;
    mutable emit : Agent_runner.event -> unit;
  }

  let clock_error d = failure (Agent_runner.Port_exit d)
  let now t = Result.map_error clock_error (Clock.now t.clock)

  let set_fault t error =
    if Option.is_none t.fault then t.fault <- Some error;
    Eio.Condition.broadcast t.changed

  let frame_error = function
    | Protocol_frame.Oversized d
    | Protocol_frame.Invalid_json d
    | Protocol_frame.Truncated d -> failure (Agent_runner.Response_error d)

  let rec read_loop t =
    match Process.read t.process with
    | Error d -> set_fault t (failure (Agent_runner.Port_exit d))
    | Ok None -> Eio.Stream.add t.packets Eof
    | Ok (Some bytes) -> (
        if String.length bytes > read_chunk_limit then
          set_fault t
            (failure
               (Agent_runner.Response_error
                  (diagnostic "The process exceeded the bounded read profile.")))
        else if String.length bytes = 0 then (
          Eio.Fiber.yield ();
          read_loop t)
        else
          match now t with
          | Error error -> set_fault t error
          | Ok stamp ->
              t.last_stdout <- stamp;
              Eio.Condition.broadcast t.changed;
              Eio.Stream.add t.packets (Bytes bytes);
              read_loop t)

  let rec stderr_loop t =
    match Process.stderr t.process with
    | Ok None -> ()
    | Ok (Some _) ->
        Eio.Fiber.yield ();
        stderr_loop t
    | Error d -> set_fault t (failure (Agent_runner.Port_exit d))

  let response_timeout () =
    Deadline
      (Agent_runner.Response_deadline
         (diagnostic "The app-server request exceeded its fixed deadline."))

  let silence_timeout () =
    Deadline
      (Agent_runner.Turn_silence
         (diagnostic "The active turn exceeded its stdout silence deadline."))

  let stop t mode =
    match (mode, Eio.Promise.peek t.interrupt) with
    | Active, Some interrupt ->
        Some (Stopped { interrupt; remote_error = None })
    | Closing, _ | Active, None -> None

  let due t mode fixed =
    let* stamp = now t in
    let silence =
      match (mode, t.current) with
      | Active, Some { terminal = None; _ } ->
          Some
            (Clock.Pure.after t.last_stdout
               (Agent_settings.turn_timeout t.settings))
      | Closing, _ | Active, Some _ | Active, None -> None
    in
    let expired = function
      | Some deadline -> Clock.Pure.compare stamp deadline >= 0
      | None -> false
    in
    if expired fixed then Error (response_timeout ())
    else if expired silence then Error (silence_timeout ())
    else
      Ok
        (match (fixed, silence) with
        | None, other | other, None -> other
        | Some a, Some b -> Some (if Clock.Pure.compare a b <= 0 then a else b))

  let rec watch t mode fixed =
    match (t.fault, stop t mode) with
    | Some error, _ | None, Some error -> Error error
    | None, None ->
        let* deadline = due t mode fixed in
        let* () =
          match deadline with
          | None ->
              Eio.Condition.await_no_mutex t.changed;
              Ok ()
          | Some deadline ->
              Eio.Fiber.first
                (fun () ->
                  Result.map_error clock_error
                    (Clock.sleep_until t.clock deadline))
                (fun () ->
                  Eio.Condition.await_no_mutex t.changed;
                  Ok ())
        in
        watch t mode fixed

  let guard t mode fixed work =
    match (t.fault, stop t mode) with
    | Some error, _ | None, Some error -> Error error
    | None, None ->
        let* _ = due t mode fixed in
        (* A producer may finish while the other branch is being canceled. Keep
           the first recorded result, rather than the join's return ordering. *)
        let selected = ref None in
        let select result =
          selected :=
            Some
              (match !selected with
              | None -> result
              | Some prior -> choose prior result);
          match !selected with
          | Some result -> result
          | None -> assert false
        in
        let joined =
          Eio.Fiber.first ~combine:choose
            (fun () -> select (capture work))
            (fun () ->
              select
                (capture (fun () ->
                     Eio.Fiber.first
                       (fun () -> watch t mode fixed)
                       (fun () ->
                         match mode with
                         | Active ->
                             let interrupt = Eio.Promise.await t.interrupt in
                             Error (Stopped { interrupt; remote_error = None })
                         | Closing ->
                             Eio.Condition.await_no_mutex t.changed;
                             watch t mode fixed))))
        in
        restore (Option.value !selected ~default:joined)

  let deadline t =
    let* stamp = now t in
    Ok (Clock.Pure.after stamp (Agent_settings.read_timeout t.settings))

  let send t mode fixed envelope =
    let* fixed =
      match fixed with
      | Some _ -> Ok fixed
      | None -> Result.map Option.some (deadline t)
    in
    let* json =
      Result.map_error
        (fun e -> protocol_error "envelope" (Protocol_codec.Envelope e))
        (Protocol_envelope.encode envelope)
    in
    guard t mode fixed (fun () ->
        Result.map_error
          (fun d -> failure (Agent_runner.Port_exit d))
          (Process.write t.process (Json.encode json ^ "\n")))

  let rec next t mode fixed =
    let* () = guard t mode fixed (fun () -> Ok ()) in
    match t.frames with
    | value :: rest ->
        t.frames <- rest;
        Ok value
    | [] -> (
        match t.frame_error with
        | Some error -> Error error
        | None when t.pipe = Ended_pipe ->
            Error
              (failure
                 (Agent_runner.Port_exit
                    (diagnostic "The app-server stdout is closed.")))
        | None -> (
            let* packet =
              guard t mode fixed (fun () -> Ok (Eio.Stream.take t.packets))
            in
            match packet with
            | Eof ->
                t.pipe <- Ended_pipe;
                let* () =
                  Result.map_error frame_error (Protocol_frame.finish t.frame)
                in
                Error
                  (failure
                     (Agent_runner.Port_exit
                        (diagnostic
                           "The app-server stdout closed before the expected \
                            reply.")))
            | Bytes bytes ->
                let batch = Protocol_frame.feed t.frame bytes in
                t.frames <- batch.Protocol_frame.frames;
                (match batch.Protocol_frame.next with
                | Protocol_frame.Open frame -> t.frame <- frame
                | Protocol_frame.Failed error ->
                    t.frame_error <- Some (frame_error error));
                next t mode fixed))

  let emit t mode fixed event =
    guard t mode fixed (fun () ->
        t.emit event;
        (* A synchronous receipt may accept interruption before the watcher runs. *)
        match stop t mode with
        | Some error -> Error error
        | None -> Ok ())

  let provisional t turn =
    match t.phase with
    | Ready -> Ok ()
    | Awaiting None when not (Turn_id.Set.mem turn t.known) ->
        t.phase <- Awaiting (Some turn);
        Ok ()
    | Awaiting (Some expected) when Turn_id.equal expected turn -> Ok ()
    | Awaiting None | Awaiting (Some _) ->
        Error
          (failure
             (Agent_runner.Response_error
                (diagnostic
                   "Early messages disagreed on the pending turn identity.")))

  let queue t envelope =
    let* json =
      Result.map_error
        (fun e -> protocol_error "notification" (Protocol_codec.Envelope e))
        (Protocol_envelope.encode envelope)
    in
    if
      List.length t.early >= early_limit
      || Json.encoded_bytes json > Protocol_frame.max_bytes - t.early_bytes
    then
      Error
        (failure
           (Agent_runner.Response_error
              (diagnostic "The session exceeded its early notification budget.")))
    else (
      t.early <- envelope :: t.early;
      t.early_bytes <- t.early_bytes + Json.encoded_bytes json;
      Ok ())

  let context t (context : Protocol_codec.context) =
    let thread_ok =
      match (context.Protocol_codec.thread, t.thread) with
      | None, _ -> true
      | Some a, Some b -> Thread_id.equal a b
      | Some _, None -> false
    in
    let* () =
      if thread_ok then Ok ()
      else
        Error
          (failure
             (Agent_runner.Response_error
                (diagnostic "The server request crossed its owned thread.")))
    in
    let* () =
      match context.Protocol_codec.turn with
      | None -> Ok ()
      | Some turn -> provisional t turn
    in
    let turn_ok =
      match (context.Protocol_codec.turn, t.phase, t.current) with
      | None, _, _ -> true
      | Some a, Awaiting (Some b), _ -> Turn_id.equal a b
      | Some a, Ready, Some b -> Turn_id.equal a b.id
      | Some _, Awaiting None, _ | Some _, Ready, None -> false
    in
    if thread_ok && turn_ok then Ok ()
    else
      Error
        (failure
           (Agent_runner.Response_error
              (diagnostic "The server request crossed its owned thread or turn.")))

  let server t mode fixed envelope id method_name params =
    let* json =
      Result.map_error
        (fun e -> protocol_error method_name (Protocol_codec.Envelope e))
        (Protocol_envelope.encode envelope)
    in
    match Id_map.find_opt id t.replays with
    | Some previous -> (
        if not (Json.equal previous.request json) then
          Error
            (failure
               (Agent_runner.Response_error
                  (diagnostic
                     "The server reused an RPC identity for a different \
                      request.")))
        else
          match previous.response with
          | None -> Ok ()
          | Some response -> send t mode fixed response)
    | None -> (
        if Id_map.cardinal t.replays >= replay_limit then
          Error
            (failure
               (Agent_runner.Response_error
                  (diagnostic
                     "The turn exceeded its server request replay budget.")))
        else
          let* action =
            Result.map_error
              (protocol_error method_name)
              (Protocol_codec.server_request ~id ~method_name params)
          in
          let reply response =
            let* response_bytes =
              match response with
              | None -> Ok 0
              | Some response ->
                  Result.map Json.encoded_bytes
                    (Result.map_error
                       (fun e ->
                         protocol_error method_name (Protocol_codec.Envelope e))
                       (Protocol_envelope.encode response))
            in
            let size = Json.encoded_bytes json + response_bytes in
            if size > Protocol_frame.max_bytes - t.replay_bytes then
              Error
                (failure
                   (Agent_runner.Response_error
                      (diagnostic
                         "The turn exceeded its server request byte budget.")))
            else begin
              t.replays <- Id_map.add id { request = json; response } t.replays;
              t.replay_bytes <- t.replay_bytes + size;
              match response with
              | None -> Ok ()
              | Some value -> send t mode fixed value
            end
          in
          match action with
          | Protocol_codec.Reply { context = source; response; tool } -> (
              let* () = context t source in
              let* () = reply (Some response) in
              match tool with
              | None -> Ok ()
              | Some name -> (
                  let event =
                    Agent_runner.Unsupported_tool
                      {
                        name;
                        diagnostic =
                          diagnostic "The requested tool is unsupported.";
                      }
                  in
                  match t.phase with
                  | Ready -> emit t mode fixed event
                  | Awaiting _ ->
                      t.pending_events <- event :: t.pending_events;
                      Ok ()))
          | Protocol_codec.Input_required { context = source; response } -> (
              let* () = context t source in
              let* () = reply response in
              let input_diagnostic =
                diagnostic "The turn requires external input."
              in
              match (t.phase, t.current) with
              | Awaiting _, _ | Ready, Some _ ->
                  t.input <- Some input_diagnostic;
                  Ok ()
              | Ready, None ->
                  Error
                    (failure
                       (Agent_runner.Turn_input_required
                          (diagnostic
                             "The session requires external input before a \
                              turn."))))
          | Protocol_codec.Unsupported response ->
              let* () = reply (Some response) in
              Error
                (failure
                   (Agent_runner.Response_error
                      (diagnostic
                         "The server requires an unsupported authentication \
                          operation."))))

  let same_thread t thread =
    match t.thread with
    | Some owned when Thread_id.equal thread owned -> Ok ()
    | Some _ | None ->
        Error
          (failure
             (Agent_runner.Response_error
                (diagnostic "The notification crossed its owned thread.")))

  let terminal_of (turn : Protocol_codec.turn) =
    match turn.Protocol_codec.status with
    | Protocol_codec.Completed -> Ok Completed
    | Protocol_codec.Failed ->
        Ok
          (Failed
             (Option.value turn.Protocol_codec.error
                ~default:(diagnostic "The remote turn failed.")))
    | Protocol_codec.Interrupted -> Ok (Interrupted turn.Protocol_codec.error)
    | Protocol_codec.In_progress ->
        Error
          (failure
             (Agent_runner.Response_error
                (diagnostic "A completed notification reported an active turn.")))

  let merge_terminal previous incoming =
    (* A replay preserves the first outcome; a conflicting terminal is invalid. *)
    match (previous, incoming) with
    | None, terminal -> Ok (Some terminal)
    | Some Completed, Completed
    | Some (Failed _), Failed _
    | Some (Interrupted _), Interrupted _
    | Some (Input_required _), Input_required _ -> Ok previous
    | Some Completed, (Failed _ | Interrupted _ | Input_required _)
    | Some (Failed _), (Completed | Interrupted _ | Input_required _)
    | Some (Interrupted _), (Completed | Failed _ | Input_required _)
    | Some (Input_required _), (Completed | Failed _ | Interrupted _) ->
        Error
          (failure
             (Agent_runner.Response_error
                (diagnostic "The turn reported conflicting terminal outcomes.")))

  let notice t mode fixed envelope method_name params =
    let* notice =
      Result.map_error
        (protocol_error method_name)
        (Protocol_codec.notification ~method_name params)
    in
    let thread =
      match notice with
      | Protocol_codec.Turn_started_notice { thread; _ }
      | Protocol_codec.Turn_completed_notice { thread; _ }
      | Protocol_codec.Usage { thread; _ }
      | Protocol_codec.Request_resolved { thread; _ }
      | Protocol_codec.Settings { thread; _ } -> Some thread
      | Protocol_codec.Other { thread; _ } -> thread
      | Protocol_codec.Rate_limits _ -> None
    in
    let foreign =
      match (thread, t.thread) with
      | Some a, Some b -> not (Thread_id.equal a b)
      | None, _ | Some _, None -> false
    in
    if foreign then Ok ()
    else
      match notice with
      | Protocol_codec.Rate_limits value -> (
          match t.phase with
          | Awaiting _ -> queue t envelope
          | Ready when Turn_id.Set.is_empty t.known ->
              t.pending_rate <- Some value;
              Ok ()
          | Ready -> emit t mode fixed (Agent_runner.Rate_limits value))
      | Protocol_codec.Request_resolved { thread; request = _ } ->
          same_thread t thread
      | Protocol_codec.Settings { thread; cwd; approval; sandbox } ->
          let* () = same_thread t thread in
          if not (String.equal cwd t.cwd) then
            Error
              (failure
                 (Agent_runner.Invalid_workspace_cwd
                    (diagnostic
                       "The remote settings changed the acquired workspace cwd.")))
          else
            Result.map_error
              (protocol_error method_name)
              (Protocol_codec.check_turn_policy ~expected:t.policy ~approval
                 ~sandbox)
      | Protocol_codec.Turn_started_notice { thread; turn }
      | Protocol_codec.Turn_completed_notice { thread; turn } -> (
          let* () = same_thread t thread in
          match (t.phase, t.current) with
          | Awaiting _, _
            when not (Turn_id.Set.mem turn.Protocol_codec.id t.known) ->
              let* () = provisional t turn.Protocol_codec.id in
              let* () =
                if String.equal method_name "turn/completed" then (
                  let* terminal = terminal_of turn in
                  let* merged = merge_terminal t.pending_terminal terminal in
                  t.pending_terminal <- merged;
                  Ok ())
                else Ok ()
              in
              queue t envelope
          | Ready, Some current
            when Turn_id.equal current.id turn.Protocol_codec.id ->
              if String.equal method_name "turn/completed" then (
                let* terminal = terminal_of turn in
                let* merged = merge_terminal current.terminal terminal in
                current.terminal <- merged;
                Ok ())
              else Ok ()
          | (Ready | Awaiting _), Some _
            when Turn_id.Set.mem turn.Protocol_codec.id t.known -> Ok ()
          | (Ready | Awaiting _), Some _ | (Ready | Awaiting _), None ->
              Error
                (failure
                   (Agent_runner.Response_error
                      (diagnostic "The notification named an unowned turn."))))
      | Protocol_codec.Usage { thread; turn; absolute } -> (
          let* () = same_thread t thread in
          if Turn_id.Set.mem turn t.known then
            emit t mode fixed
              (Agent_runner.Usage_report { thread; turn; absolute })
          else
            match t.phase with
            | Awaiting _ ->
                let* () = provisional t turn in
                queue t envelope
            | Ready ->
                Error
                  (failure
                     (Agent_runner.Response_error
                        (diagnostic "Usage named an unowned turn."))))
      | Protocol_codec.Other { method_name; thread; turn } -> (
          let* () =
            match thread with
            | None -> Ok ()
            | Some thread -> same_thread t thread
          in
          match (t.phase, t.current) with
          | Awaiting _, _
            when Option.fold ~none:false
                   ~some:(fun turn -> Turn_id.Set.mem turn t.known)
                   turn -> Ok ()
          | Awaiting _, _ ->
              let* () =
                match turn with
                | None -> Ok ()
                | Some turn -> provisional t turn
              in
              queue t envelope
          | Ready, Some current
            when Option.fold ~none:true ~some:(Turn_id.equal current.id) turn ->
              emit t mode fixed
                (Agent_runner.Output
                   {
                     session = current.session;
                     event_name = method_name;
                     message = None;
                   })
          | Ready, Some _ | Ready, None -> Ok ())

  let dispatch t mode fixed envelope =
    match Protocol_envelope.view envelope with
    | Protocol_envelope.Request { id; method_; params } ->
        server t mode fixed envelope id method_ params
    | Protocol_envelope.Notification { method_; params } ->
        notice t mode fixed envelope method_ params
    | Protocol_envelope.Response _ -> Ok ()

  let rec receive t mode fixed id call =
    let* json = next t mode fixed in
    let* envelope =
      Result.map_error
        (fun e ->
          protocol_error
            (Protocol_codec.method_name call)
            (Protocol_codec.Envelope e))
        (Protocol_envelope.decode json)
    in
    match Protocol_envelope.view envelope with
    | Protocol_envelope.Response { id = returned; reply }
      when Protocol_id.equal id returned -> (
        match reply with
        | Protocol_envelope.Failure rpc ->
            Error
              (protocol_error
                 (Protocol_codec.method_name call)
                 (Protocol_codec.Rpc rpc.Protocol_envelope.code))
        | Protocol_envelope.Success value ->
            Result.map_error
              (protocol_error (Protocol_codec.method_name call))
              (Protocol_codec.reply call value))
    | Protocol_envelope.Request _
    | Protocol_envelope.Notification _
    | Protocol_envelope.Response _ ->
        let* () = dispatch t mode fixed envelope in
        receive t mode fixed id call

  let rpc t mode fixed call =
    let* id =
      Result.map_error
        (fun _ ->
          failure
            (Agent_runner.Response_error
               (diagnostic
                  "The client RPC sequence exceeded its identity profile.")))
        (Protocol_id.of_string
           (Positive_count.count t.next_id |> Count.decimal))
    in
    t.next_id <- Positive_count.next t.next_id;
    let* envelope =
      Result.map_error
        (protocol_error (Protocol_codec.method_name call))
        (Protocol_codec.request ~id call)
    in
    let* () = send t mode fixed envelope in
    receive t mode fixed id call

  let request t mode call =
    let* until = deadline t in
    rpc t mode (Some until) call

  let rec settle t mode fixed =
    (* Finish the accepted batch before handing back a session or outcome.
       Preserve its known malformed suffix and trailing observations. *)
    match t.frames with
    | _ :: _ ->
        let* json = next t mode fixed in
        let* envelope =
          Result.map_error
            (fun e -> protocol_error "continuation" (Protocol_codec.Envelope e))
            (Protocol_envelope.decode json)
        in
        let* () = dispatch t mode fixed envelope in
        settle t mode fixed
    | [] -> (
        match t.frame_error with
        | Some error -> Error error
        | None -> Ok ())

  let ready t =
    let* () = settle t Active None in
    match t.input with
    | Some d -> Error (failure (Agent_runner.Turn_input_required d))
    | None -> Ok ()

  let rec wait_turn t mode fixed =
    match (mode, t.input, t.current) with
    | Active, Some d, _ ->
        let* () = settle t mode fixed in
        Ok (Input_required d)
    | (Active | Closing), _, Some { terminal = Some terminal; _ } -> (
        let* () = settle t mode fixed in
        match (mode, t.input) with
        | Active, Some d -> Ok (Input_required d)
        | Active, None | Closing, _ -> Ok terminal)
    | (Active | Closing), _, Some { terminal = None; _ } ->
        let* json = next t mode fixed in
        let* envelope =
          Result.map_error
            (fun e -> protocol_error "turn" (Protocol_codec.Envelope e))
            (Protocol_envelope.decode json)
        in
        let* () = dispatch t mode fixed envelope in
        wait_turn t mode fixed
    | (Active | Closing), _, None ->
        Error
          (failure
             (Agent_runner.Response_error
                (diagnostic "The session has no current turn.")))

  let rec drain t fixed turn =
    let terminal =
      match (t.phase, t.current) with
      | Awaiting (Some target), _ when Turn_id.equal turn target ->
          t.pending_terminal
      | Ready, Some current when Turn_id.equal turn current.id ->
          current.terminal
      | Awaiting None, _ | Awaiting (Some _), _ | Ready, Some _ | Ready, None ->
          None
    in
    match terminal with
    | Some terminal ->
        let* () = settle t Closing fixed in
        Ok terminal
    | None ->
        let* json = next t Closing fixed in
        let* envelope =
          Result.map_error
            (fun e ->
              protocol_error "turn/interrupt" (Protocol_codec.Envelope e))
            (Protocol_envelope.decode json)
        in
        let* () = dispatch t Closing fixed envelope in
        drain t fixed turn

  let interrupt_turn t =
    let turn =
      match (t.phase, t.current) with
      | Awaiting candidate, _ -> candidate
      | Ready, Some current -> Some current.id
      | Ready, None -> None
    in
    match (t.pipe, t.thread, turn) with
    | Open_pipe, Some thread, Some turn ->
        let saved = t.emit in
        t.emit <- (fun _ -> ());
        Fun.protect
          ~finally:(fun () -> t.emit <- saved)
          (fun () ->
            match deadline t with
            | Error error -> Error error
            | Ok until -> (
                let result =
                  let* _ =
                    rpc t Closing (Some until)
                      (Protocol_codec.Interrupt { thread; turn })
                  in
                  drain t (Some until) turn
                in
                match result with
                | Ok (Failed d | Input_required d) -> Ok (Some d)
                | Ok (Interrupted d) -> Ok d
                | Ok Completed -> Ok None
                | Error error -> Error error))
    | Ended_pipe, _, _ | Open_pipe, Some _, None | Open_pipe, None, _ -> Ok None

  let close_error t (error : error) =
    let cleanup = interrupt_turn t in
    let remote_error =
      match cleanup with
      | Ok diagnostic -> diagnostic
      | Error (Failure (Agent_runner.Response_error d)) -> Some d
      | Error
          ( Failure
              ( Agent_runner.Codex_not_found _
              | Agent_runner.Invalid_workspace_cwd _
              | Agent_runner.Port_exit _
              | Agent_runner.Turn_failed _
              | Agent_runner.Turn_input_required _
              | Agent_runner.Template_error _
              | Agent_runner.Workspace_error _
              | Agent_runner.Tracker_error _ )
          | Deadline _ | Stopped _ ) -> None
    in
    (* Input requests need a successful interruption to clear the pending RPC. *)
    match error with
    | Failure (Agent_runner.Turn_input_required _) -> (
        match cleanup with
        | Error cleanup -> Error cleanup
        | Ok _ -> Error error)
    | Stopped { interrupt; _ } -> Error (Stopped { interrupt; remote_error })
    | Failure
        ( Agent_runner.Codex_not_found _
        | Agent_runner.Invalid_workspace_cwd _
        | Agent_runner.Port_exit _
        | Agent_runner.Turn_failed _
        | Agent_runner.Response_error _
        | Agent_runner.Template_error _
        | Agent_runner.Workspace_error _
        | Agent_runner.Tracker_error _ )
    | Deadline _ -> Error error

  let flush_early t =
    let early = List.rev t.early in
    t.early <- [];
    t.early_bytes <- 0;
    let rec loop = function
      | [] -> Ok ()
      | envelope :: rest ->
          let* () = dispatch t Active None envelope in
          loop rest
    in
    let* () = loop early in
    let events = List.rev t.pending_events in
    t.pending_events <- [];
    let rec publish = function
      | [] -> Ok ()
      | event :: rest ->
          let* () = emit t Active None event in
          publish rest
    in
    let* () = publish events in
    if t.early = [] then Ok ()
    else
      Error
        (failure
           (Agent_runner.Response_error
              (diagnostic "An early notification named an unowned turn.")))

  let start_turn t prompt =
    let* thread =
      match t.thread with
      | Some value -> Ok value
      | None ->
          Error
            (failure
               (Agent_runner.Response_error
                  (diagnostic "The session has no initialized thread.")))
    in
    (* Settled prior turns keep replay protection until this new RPC generation. *)
    t.replays <- Id_map.empty;
    t.replay_bytes <- 0;
    t.phase <- Awaiting None;
    t.pending_terminal <- None;
    t.input <- None;
    let* reply =
      request t Active
        (Protocol_codec.Start_turn
           { thread; cwd = t.cwd; policy = t.policy; prompt })
    in
    match reply with
    | Protocol_codec.Turn_started turn ->
        let agrees =
          match t.phase with
          | Awaiting None -> true
          | Awaiting (Some expected) ->
              Turn_id.equal expected turn.Protocol_codec.id
          | Ready -> false
        in
        if
          (not agrees)
          || Turn_id.Set.mem turn.Protocol_codec.id t.known
          || Turn_id.Set.cardinal t.known >= Agent_settings.max_turns t.settings
        then
          Error
            (failure
               (Agent_runner.Response_error
                  (diagnostic
                     "The server reused a turn identity or exceeded the turn \
                      cap.")))
        else
          let* session =
            Result.map_error
              (fun _ ->
                failure
                  (Agent_runner.Response_error
                     (diagnostic "The observed session identity is invalid.")))
              (Session_id.parse
                 (Thread_id.text thread ^ "-"
                 ^ Turn_id.text turn.Protocol_codec.id))
          in
          let first = Turn_id.Set.is_empty t.known in
          (* A start result acknowledges identity. Only a matched completion
             notification can establish the terminal barrier. *)
          let terminal = t.pending_terminal in
          t.current <- Some { id = turn.Protocol_codec.id; session; terminal };
          t.phase <- Ready;
          t.known <- Turn_id.Set.add turn.Protocol_codec.id t.known;
          let* stamp = now t in
          t.last_stdout <- stamp;
          let event =
            if first then
              Agent_runner.Session_started
                { session; thread; turn = turn.Protocol_codec.id }
            else
              Agent_runner.Turn_started
                { session; turn = turn.Protocol_codec.id }
          in
          let* () = emit t Active None event in
          let pending_rate = t.pending_rate in
          t.pending_rate <- None;
          let* () =
            match pending_rate with
            | Some value -> emit t Active None (Agent_runner.Rate_limits value)
            | None -> Ok ()
          in
          flush_early t
    | Protocol_codec.Initialized
    | Protocol_codec.Thread_started _
    | Protocol_codec.Named
    | Protocol_codec.Interrupt_ack ->
        Error
          (failure
             (Agent_runner.Response_error
                (diagnostic "The server returned a different RPC result.")))

  let turn t ~prompt ~emit:callback =
    t.emit <- callback;
    let result =
      let* () = ready t in
      let* () = start_turn t prompt in
      let* outcome = wait_turn t Active None in
      match t.current with
      | None -> assert false
      | Some current ->
          let* () =
            match outcome with
            | Completed ->
                emit t Active None
                  (Agent_runner.Turn_completed
                     { session = current.session; turn = current.id })
            | Failed _ | Interrupted _ | Input_required _ -> Ok ()
          in
          Ok { turn = current.id; outcome }
    in
    match result with
    | Error error -> close_error t error
    | Ok ({ outcome = Input_required _; _ } as ended) ->
        let* _ = interrupt_turn t in
        Ok ended
    | Ok ({ outcome = Completed | Failed _ | Interrupted _; _ } as ended) ->
        Ok ended

  type 'a awaited = Answer of 'a | Frame of Json.t

  let await t callback =
    let valid =
      match (t.phase, t.current) with
      | Ready, Some { terminal = Some Completed; _ } -> true
      | ( Ready,
          Some
            {
              terminal =
                None | Some (Failed _ | Interrupted _ | Input_required _);
              _;
            } )
      | Ready, None
      | Awaiting _, _ -> false
    in
    if not valid then
      Error
        (failure
           (Agent_runner.Response_error
              (diagnostic "A session callback requires a completed turn.")))
    else
      let answer, resolve = Eio.Promise.create () in
      let result =
        Eio.Switch.run (fun sw ->
            let* () = ready t in
            Eio.Fiber.fork_daemon ~sw (fun () ->
                let value = capture callback in
                Eio.Promise.resolve resolve value;
                `Stop_daemon);
            let read_error = ref None in
            let finish value =
              match value with
              | Raised _ -> Ok value
              | Returned _ ->
                  (* Joining the losing read can record a fault after the answer
                     wins. Recheck transport state before accepting the reply. *)
                  let* () =
                    match !read_error with
                    | Some error -> Error error
                    | None -> Ok ()
                  in
                  guard t Active None (fun () ->
                      let* () = ready t in
                      Ok value)
            in
            let rec loop () =
              let* () = ready t in
              match Eio.Promise.peek answer with
              | Some value -> finish value
              | None -> (
                  (* Only the read competes with callback completion. An emitted
                 fact finishes its receipt before this owner returns the answer. *)
                  let selected = ref None in
                  let select value =
                    (match (!selected, value) with
                    | Some (Ok (Answer _)), Ok (Frame json) ->
                        t.frames <- json :: t.frames
                    | Some (Ok (Answer _)), Error error ->
                        read_error := Some error
                    | Some (Ok (Answer _)), Ok (Answer _)
                    | ( Some (Ok (Frame _) | Error _),
                        (Ok (Frame _ | Answer _) | Error _) ) -> ()
                    | None, _ -> selected := Some value);
                    match !selected with
                    | Some value -> value
                    | None -> assert false
                  in
                  let* next =
                    guard t Active None (fun () ->
                        Eio.Fiber.first
                          (fun () ->
                            select
                              (Result.map
                                 (fun value -> Frame value)
                                 (next t Active None)))
                          (fun () ->
                            select (Ok (Answer (Eio.Promise.await answer)))))
                  in
                  match next with
                  | Answer value -> finish value
                  | Frame json ->
                      let* envelope =
                        Result.map_error
                          (fun e ->
                            protocol_error "continuation"
                              (Protocol_codec.Envelope e))
                          (Protocol_envelope.decode json)
                      in
                      let* () = dispatch t Active None envelope in
                      loop ())
            in
            loop ())
      in
      (* A protocol error can win before callback cancellation raises a defect.
         Inspect the joined callback before accepting that expected error. *)
      match Eio.Promise.peek answer with
      | Some (Raised (error, trace)) ->
          Printexc.raise_with_backtrace error trace
      | Some (Returned _) | None -> (
          match result with
          | Ok value -> Ok (restore value)
          | Error error -> close_error t error)

  let init t version title =
    let* _ = request t Active (Protocol_codec.Initialize { version }) in
    let* initialized =
      Result.map_error
        (protocol_error "initialized")
        (Protocol_codec.initialized ())
    in
    let* until = deadline t in
    let* () = send t Active (Some until) initialized in
    let* thread =
      request t Active
        (Protocol_codec.Start_thread
           { cwd = t.cwd; policy = Agent_settings.thread_policy t.settings })
    in
    match thread with
    | Protocol_codec.Thread_started thread ->
        t.thread <- Some thread;
        let* _ =
          request t Active (Protocol_codec.Name_thread { thread; name = title })
        in
        ready t
    | Protocol_codec.Initialized
    | Protocol_codec.Named
    | Protocol_codec.Turn_started _
    | Protocol_codec.Interrupt_ack ->
        Error
          (failure
             (Agent_runner.Response_error
                (diagnostic
                   "The server returned a different initialization result.")))

  type scope_error =
    | Expected of error
    | Defect of exn * Printexc.raw_backtrace

  let with_session ~process ~clock ~interrupt ~cwd ~env ~settings ~version
      ~title callback =
    match Eio.Promise.peek interrupt with
    | Some interrupt -> Error (Stopped { interrupt; remote_error = None })
    | None -> (
        let* stamp = Result.map_error clock_error (Clock.now clock) in
        let* sandbox =
          Result.map_error
            (fun d -> failure (Agent_runner.Response_error d))
            (Policy.turn_policy settings cwd)
        in
        let approval =
          match Json.view (Agent_settings.thread_policy settings) with
          | Json.Object fields -> List.assoc_opt "approvalPolicy" fields
          | Json.Null
          | Json.Bool _
          | Json.Number _
          | Json.String _
          | Json.Array _ -> None
        in
        let* policy =
          match approval with
          | Some approval ->
              Result.map_error
                (fun _ ->
                  failure
                    (Agent_runner.Response_error
                       (diagnostic
                          "The bound turn policy exceeded the JSON profile.")))
                (Json.of_view
                   (Json.Object
                      [
                        ("approvalPolicy", approval); ("sandboxPolicy", sandbox);
                      ]))
          | None ->
              Error
                (failure
                   (Agent_runner.Response_error
                      (diagnostic
                         "The checked settings have no approval policy.")))
        in
        let acquired = ref false in
        let result =
          Process.with_process process ~cwd ~env
            ~command:(Agent_settings.command settings)
            ~on_error:(fun d ->
              Expected
                (failure
                   (if !acquired then Agent_runner.Port_exit d
                    else Agent_runner.Codex_not_found d)))
            (fun process ->
              acquired := true;
              let primary = ref None in
              let scoped =
                capture (fun () ->
                    Eio.Switch.run (fun sw ->
                        let t =
                          {
                            process;
                            clock;
                            interrupt;
                            settings;
                            cwd = Path.display cwd;
                            policy;
                            packets = Eio.Stream.create mailbox_capacity;
                            changed = Eio.Condition.create ();
                            fault = None;
                            last_stdout = stamp;
                            frame = Protocol_frame.empty;
                            frames = [];
                            frame_error = None;
                            pipe = Open_pipe;
                            next_id = Positive_count.first;
                            replays = Id_map.empty;
                            replay_bytes = 0;
                            thread = None;
                            current = None;
                            phase = Ready;
                            pending_terminal = None;
                            input = None;
                            pending_events = [];
                            known = Turn_id.Set.empty;
                            early = [];
                            early_bytes = 0;
                            pending_rate = None;
                            emit = (fun _ -> ());
                          }
                        in
                        Eio.Fiber.fork_daemon ~sw (fun () ->
                            read_loop t;
                            `Stop_daemon);
                        Eio.Fiber.fork_daemon ~sw (fun () ->
                            stderr_loop t;
                            `Stop_daemon);
                        let value =
                          capture (fun () ->
                              let* () = init t version title in
                              callback t)
                        in
                        (* Keep the body result through daemon cancellation/join. *)
                        primary := Some value;
                        value))
              in
              let value =
                match (!primary, scoped) with
                | Some (Raised _ as original), _
                | Some (Returned (Error _) as original), _ -> original
                | (None | Some (Returned (Ok _))), Returned value -> value
                | (None | Some (Returned (Ok _))), Raised (error, trace) ->
                    Raised (error, trace)
              in
              match value with
              | Returned (Ok value) -> Ok value
              | Returned (Error error) -> Error (Expected error)
              | Raised (error, trace) -> Error (Defect (error, trace)))
        in
        match result with
        | Ok value -> Ok value
        | Error (Expected error) -> Error error
        | Error (Defect (error, trace)) ->
            Printexc.raise_with_backtrace error trace)
end
