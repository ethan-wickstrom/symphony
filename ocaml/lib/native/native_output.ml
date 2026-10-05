module Make (Clock : Clock.S) = struct
  module Deadline = Deadline.Make (Clock)
  module Keys = Set.Make (String)

  let record_bytes = 4096
  let queue_bytes = 1_048_576
  let flush_timeout_ms = "1000"

  let flush_delay =
    match Milliseconds.parse flush_timeout_ms with
    | Ok value -> value
    | Error _ -> failwith "Invalid operator output flush delay."

  let event_key = "event"
  let hex_digits = "0123456789abcdef"
  let hex_shift = 4
  let hex_mask = 15
  let ascii_first = Char.code '!'
  let ascii_last = Char.code '~'

  type phase = Open | Closing | Closed

  type t = {
    sink : Eio.Flow.sink_ty Eio.Flow.sink;
    queue : string Queue.t;
    changed : Eio.Condition.t;
    mutable bytes : int;
    mutable phase : phase;
    mutable failure : (unit, Diagnostic.t) result Native_outcome.t option;
    mutable callback : Eio.Cancel.t option;
    failed : unit Eio.Promise.u;
  }

  exception Rejected
  exception Output_failed
  exception Scope_failed

  let diagnostic message =
    Diagnostic.make ~site:(Diagnostic.Host "operator output") ~message
      ~remedy:"Check the operator output consumer and record limits."

  let record_failure t error =
    match t.failure with
    | Some previous -> previous
    | None ->
        t.failure <- Some error;
        Eio.Promise.resolve t.failed ();
        error

  let reject t message =
    ignore
      (record_failure t (Native_outcome.Returned (Error (diagnostic message)))
        : (unit, Diagnostic.t) result Native_outcome.t);
    raise Rejected

  let append t buffer text =
    if String.length text > record_bytes - Buffer.length buffer then begin
      reject t "Operator output record exceeded its byte limit."
    end;
    Buffer.add_string buffer text

  let token t buffer text =
    if text = "" || String.length text > record_bytes then begin
      reject t "Operator output record has an invalid token."
    end;
    String.iter
      (function
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> ()
        | _ -> reject t "Operator output record has an invalid token.")
      text;
    append t buffer text

  let value t buffer text =
    String.iter
      (fun character ->
        let byte = Char.code character in
        if
          byte >= ascii_first && byte <= ascii_last && character <> '='
          && character <> '\\'
        then begin
          append t buffer (String.make 1 character)
        end
        else begin
          let encoded = Bytes.of_string "\\x00" in
          Bytes.set encoded 2 hex_digits.[byte lsr hex_shift];
          Bytes.set encoded 3 hex_digits.[byte land hex_mask];
          append t buffer (Bytes.unsafe_to_string encoded)
        end)
      text

  let render t ~event fields =
    let buffer = Buffer.create record_bytes in
    append t buffer (event_key ^ "=");
    token t buffer event;
    let rec add keys = function
      | [] -> ()
      | (key, text) :: rest ->
          if key = event_key || Keys.mem key keys then begin
            reject t "Operator output record has duplicate or reserved keys."
          end;
          append t buffer " ";
          token t buffer key;
          append t buffer "=";
          value t buffer text;
          add (Keys.add key keys) rest
    in
    add Keys.empty fields;
    append t buffer "\n";
    Buffer.contents buffer

  let emit t ~event fields =
    match (t.phase, t.failure) with
    | Closing, _ | Closed, _ -> reject t "Operator output is closed."
    | Open, Some _ -> raise Rejected
    | Open, None ->
        let line = render t ~event fields in
        if String.length line > queue_bytes - t.bytes then begin
          reject t "Operator output queue exceeded its byte limit."
        end;
        (* Retain the in-flight line in the budget until its write completes. *)
        t.bytes <- t.bytes + String.length line;
        Queue.add line t.queue;
        Eio.Condition.broadcast t.changed

  let rec write t =
    match Queue.take_opt t.queue with
    | Some line ->
        Eio.Flow.copy_string line t.sink;
        t.bytes <- t.bytes - String.length line;
        write t
    | None -> (
        match t.phase with
        | Closing | Closed -> ()
        | Open ->
            Eio.Condition.await_no_mutex t.changed;
            write t)

  let cancel_callback t =
    match t.callback with
    | None -> ()
    | Some cancel ->
        t.callback <- None;
        (* Cancellation-hook defects cannot prevent the writer's closing receipt. *)
        begin match
          Native_outcome.capture (fun () ->
              Eio.Cancel.cancel cancel Output_failed)
        with
        | Native_outcome.Returned () -> ()
        | Native_outcome.Raised ((Unix.Unix_error _ | Eio.Io _), _) ->
            ignore
              (record_failure t
                 (Native_outcome.Returned
                    (Error (diagnostic "Operator output cancellation failed."))))
        | Native_outcome.Raised (error, trace) ->
            ignore (record_failure t (Native_outcome.Raised (error, trace)))
        end

  let writer t resolve =
    let outcome = Native_outcome.capture (fun () -> write t) in
    let failed (outcome : (unit, Diagnostic.t) result Native_outcome.t) =
      ignore
        (record_failure t outcome
          : (unit, Diagnostic.t) result Native_outcome.t);
      cancel_callback t;
      outcome
    in
    let result =
      match outcome with
      | Native_outcome.Returned () -> Native_outcome.Returned (Ok ())
      | Native_outcome.Raised ((Eio.Cancel.Cancelled _ as error), trace) -> (
          match Native_outcome.capture Eio.Fiber.check with
          | Native_outcome.Raised (Eio.Cancel.Cancelled _, _) ->
              Native_outcome.Returned (Ok ())
          | Native_outcome.Returned () | Native_outcome.Raised _ ->
              failed (Native_outcome.Raised (error, trace)))
      | Native_outcome.Raised ((Unix.Unix_error _ | Eio.Io _), _) ->
          failed
            (Native_outcome.Returned
               (Error (diagnostic "Operator output write failed.")))
      | Native_outcome.Raised (error, trace) ->
          failed (Native_outcome.Raised (error, trace))
    in
    Eio.Promise.resolve resolve result;
    `Stop_daemon

  let induced (error, trace) =
    match Eio_failure.leaves (error, trace) with
    | [] -> false
    | leaves ->
        List.for_all
          (function
            | Eio.Cancel.Cancelled Output_failed, _ | Rejected, _ -> true
            | _ -> false)
          leaves

  let with_output ~clock ~sink use =
    let failed, failed_resolve = Eio.Promise.create () in
    let t =
      {
        sink;
        queue = Queue.create ();
        changed = Eio.Condition.create ();
        bytes = 0;
        phase = Open;
        failure = None;
        callback = None;
        failed = failed_resolve;
      }
    in
    let primary = ref None in
    let closure =
      Native_outcome.capture (fun () ->
          Eio.Switch.run (fun sw ->
              Eio.Switch.check sw;
              let done_, resolve = Eio.Promise.create () in
              Eio.Fiber.fork_daemon ~sw (fun () -> writer t resolve);
              (* Publication wakes this owner; emit never runs cancellation hooks. *)
              Eio.Fiber.fork_daemon ~sw (fun () ->
                  Eio.Promise.await failed;
                  cancel_callback t;
                  `Stop_daemon);
              let body =
                Native_outcome.capture (fun () ->
                    Eio.Cancel.sub (fun cancel ->
                        t.callback <- Some cancel;
                        Eio.Fiber.check ();
                        use t))
              in
              primary := Some body;
              t.callback <- None;
              t.phase <- Closing;
              Eio.Condition.broadcast t.changed;
              match t.failure with
              | Some _ -> Eio.Switch.fail sw Scope_failed
              | None -> (
                  (* Drain queued host diagnostics before restoring callback failure. *)
                  let result =
                    Native_outcome.capture (fun () ->
                        Eio.Fiber.check ();
                        Deadline.run clock ~delay:flush_delay
                          ~on_error:(fun _ ->
                            let error =
                              diagnostic "Operator output clock failed."
                            in
                            ignore
                              (record_failure t
                                 (Native_outcome.Returned (Error error)));
                            error)
                          ~on_timeout:(fun () ->
                            let error =
                              diagnostic
                                "Operator output flush deadline expired."
                            in
                            ignore
                              (record_failure t
                                 (Native_outcome.Returned (Error error)));
                            error)
                          (fun () ->
                            Native_outcome.resolve (Eio.Promise.await done_)))
                  in
                  match result with
                  | Native_outcome.Returned (Ok ()) -> ()
                  | Native_outcome.Returned (Error _) | Native_outcome.Raised _
                    ->
                      ignore (record_failure t result);
                      Eio.Switch.fail sw Scope_failed)))
    in
    t.callback <- None;
    t.phase <- Closed;
    Queue.clear t.queue;
    t.bytes <- 0;
    match !primary with
    | Some (Native_outcome.Returned (Error error)) -> Error error
    | Some (Native_outcome.Raised (error, trace)) -> (
        match t.failure with
        | Some failure when induced (error, trace) ->
            Native_outcome.resolve failure
        | None | Some _ -> Printexc.raise_with_backtrace error trace)
    | None ->
        Native_outcome.resolve closure;
        raise Scope_failed
    | Some (Native_outcome.Returned (Ok ())) -> (
        match t.failure with
        | Some outcome -> Native_outcome.resolve outcome
        | None -> (
            match closure with
            | Native_outcome.Returned () -> Ok ()
            | Native_outcome.Raised (Eio.Cancel.Cancelled _, _) ->
                Native_outcome.resolve closure;
                raise Scope_failed
            | Native_outcome.Raised ((Unix.Unix_error _ | Eio.Io _), _) ->
                Error (diagnostic "Operator output scope failed.")
            | Native_outcome.Raised (error, trace) ->
                Printexc.raise_with_backtrace error trace))
end
