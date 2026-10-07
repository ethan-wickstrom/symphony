module Make (Clock : Clock.S) = struct
  module Deadline = Deadline.Make (Clock)

  let max_connections = 64
  let max_header_bytes = 16 * 1024
  let max_body_bytes = 64 * 1024
  let max_wire_bytes = 96 * 1024
  let max_response_bytes = 8 * 1024 * 1024
  let max_content_type_bytes = 128
  let read_chunk_bytes = 4096
  let client_delay = Milliseconds.parse "5000"
  let bad_request = 400
  let forbidden = 403
  let payload_too_large = 413
  let default_http_port = 80
  let method_not_allowed = 405
  let min_response_status = 200
  let max_response_status = 599
  let content_type = "application/json"

  let rejection_body =
    "{\"error\":{\"code\":\"bad_request\",\"message\":\"Invalid HTTP \
     request.\"}}"

  let payload_error_body =
    "{\"error\":{\"code\":\"payload_too_large\",\"message\":\"HTTP request \
     body exceeds the limit.\"}}"

  let forbidden_body =
    "{\"error\":{\"code\":\"forbidden\",\"message\":\"HTTP request origin is \
     not permitted.\"}}"

  let header_end = "\r\n\r\n"

  type client_error = Peer_closed | Host_failed of Diagnostic.t

  type request_phase =
    | Empty
    | Collecting
    | Complete of H1.Reqd.t * Http_message.request
    | Rejected
    | Handled

  type header_scan = {
    mutable bytes : int;
    mutable matched : int;
    mutable done_ : bool;
  }

  exception Server_failed
  exception Scope_failed
  exception Peer_rejected

  let diagnostic message =
    Diagnostic.make ~site:(Diagnostic.Host "status_http") ~message
      ~remedy:"Check the configured HTTP port and host network resources."

  let is_hex = function
    | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
    | _ -> false

  let escapes_valid value =
    let rec check = function
      | [] -> true
      | '%' :: high :: low :: rest when is_hex high && is_hex low -> check rest
      | '%' :: _ -> false
      | _ :: rest -> check rest
    in
    check (List.of_seq (String.to_seq value))

  let decode_path target =
    let forbidden c = Char.code c < 32 || Char.code c = 127 in
    if
      (not (String.starts_with ~prefix:"/" target))
      || String.contains target '?' || String.contains target '#'
      || not (escapes_valid target)
    then None
    else
      let parts = List.map Uri.pct_decode (String.split_on_char '/' target) in
      if
        List.exists
          (fun part ->
            (not (Text.valid_utf8 part))
            || String.contains part '/'
            || String.exists forbidden part)
          parts
      then None
      else Some (String.concat "/" parts)

  let method_ = function
    | `GET -> Http_message.Get
    | `POST -> Http_message.Post
    | (`HEAD | `PUT | `DELETE | `CONNECT | `OPTIONS | `TRACE | `Other _) as
      value -> Http_message.Other (H1.Method.to_string value)

  let headers ~content_type bytes =
    H1.Headers.of_list
      [
        ("content-type", content_type);
        ("content-length", string_of_int bytes);
        ("connection", "close");
      ]

  let respond reqd (response : Http_message.response) =
    let allow =
      List.map
        (function
          | Http_message.Get -> "GET"
          | Http_message.Post -> "POST"
          | Http_message.Other _ ->
              invalid_arg "Native_status: invalid Allow method")
        response.Http_message.allow
    in
    if response.Http_message.status = method_not_allowed <> (allow <> []) then
      invalid_arg "Native_status: invalid Allow response";
    if
      response.Http_message.status < min_response_status
      || response.Http_message.status > max_response_status
      || String.length response.Http_message.body > max_response_bytes
      || String.length response.Http_message.content_type
         > max_content_type_bytes
      || (not (Text.valid_utf8 response.Http_message.content_type))
      || String.exists
           (fun c -> Char.code c < 32 || Char.code c = 127)
           response.Http_message.content_type
    then invalid_arg "Native_status: invalid handler response";
    let headers =
      headers ~content_type:response.Http_message.content_type
        (String.length response.Http_message.body)
    in
    let headers =
      match allow with
      | [] -> headers
      | methods -> H1.Headers.add headers "allow" (String.concat ", " methods)
    in
    let response_ =
      H1.Response.create ~headers
        (H1.Status.of_code response.Http_message.status)
    in
    H1.Reqd.respond_with_string reqd response_ response.Http_message.body

  let reject phase reqd status =
    phase := Rejected;
    H1.Body.Reader.close (H1.Reqd.request_body reqd);
    let body =
      if status = payload_too_large then payload_error_body
      else if status = forbidden then forbidden_body
      else rejection_body
    in
    respond reqd { Http_message.status; content_type; body; allow = [] }

  (* This scanner counts the header budget only. H1 remains the framing parser. *)
  let count_headers scan data =
    String.iter
      (fun c ->
        if not scan.done_ then (
          scan.bytes <- scan.bytes + 1;
          if scan.bytes > max_header_bytes then raise Peer_rejected;
          let expected = String.get header_end scan.matched in
          scan.matched <-
            (if Char.equal c expected then scan.matched + 1
             else if Char.equal c '\r' then 1
             else 0);
          if scan.matched = String.length header_end then scan.done_ <- true))
      data

  let authorities port =
    let suffix = ":" ^ string_of_int port in
    List.concat_map
      (fun host ->
        let origin =
          "http://" ^ host ^ if port = default_http_port then "" else suffix
        in
        let explicit = (host ^ suffix, origin) in
        if port = default_http_port then [ explicit; (host, origin) ]
        else [ explicit ])
      [ "127.0.0.1"; "localhost" ]

  (* Browser origin is authority only for this exact listener. Duplicate
     headers cannot collapse into a trusted value; CLI clients omit metadata. *)
  let permitted authorities headers =
    match H1.Headers.get_multi headers "host" with
    | [ host ] -> (
        match List.assoc_opt (String.lowercase_ascii host) authorities with
        | None -> false
        | Some origin ->
            let source =
              match H1.Headers.get_multi headers "origin" with
              | [] -> true
              | [ value ] -> String.equal value origin
              | _ -> false
            in
            let site =
              match H1.Headers.get_multi headers "sec-fetch-site" with
              | [] | [ "same-origin" ] | [ "none" ] -> true
              | _ -> false
            in
            source && site)
    | _ -> false

  let request_handler authorities phase reqd =
    (match !phase with
    | Empty -> phase := Collecting
    | Collecting | Complete _ | Rejected | Handled -> raise Peer_rejected);
    let request = H1.Reqd.request reqd in
    if not (permitted authorities request.H1.Request.headers) then
      reject phase reqd forbidden
    else
      match decode_path request.H1.Request.target with
      | None -> reject phase reqd bad_request
      | Some path -> (
          let body = H1.Reqd.request_body reqd in
          match H1.Request.body_length request with
          | `Error `Bad_request -> reject phase reqd bad_request
          | `Fixed length
            when Int64.compare length (Int64.of_int max_body_bytes) > 0 ->
              reject phase reqd payload_too_large
          | `Fixed _ | `Chunked ->
              let bytes = ref 0 in
              let buffer = Buffer.create 128 in
              let rec schedule () =
                H1.Body.Reader.schedule_read body
                  ~on_eof:(fun () ->
                    let request =
                      {
                        Http_message.method_ = method_ request.H1.Request.meth;
                        path;
                        body = Buffer.contents buffer;
                      }
                    in
                    (* H1 also closes bodies while reporting parse errors. Defer
                     authority until the pump has classified that parser result. *)
                    match !phase with
                    | Collecting -> phase := Complete (reqd, request)
                    | Empty | Complete _ | Rejected | Handled -> ())
                  ~on_read:(fun data ~off ~len ->
                    if len > max_body_bytes - !bytes then
                      reject phase reqd payload_too_large
                    else (
                      bytes := !bytes + len;
                      Buffer.add_string buffer (Bstr.sub_string data ~off ~len);
                      schedule ()))
              in
              schedule ())

  let parser_error phase ?request:_ error reply =
    phase := Rejected;
    match error with
    | `Exn error -> raise error
    | `Bad_request | `Bad_gateway | `Internal_server_error ->
        let body =
          reply (headers ~content_type (String.length rejection_body))
        in
        H1.Body.Writer.write_string body rejection_body;
        H1.Body.Writer.close body

  let wait_parser parser =
    let changed, resolve = Eio.Promise.create () in
    let wake () = Eio.Promise.try_resolve resolve () |> ignore in
    H1.Server_connection.yield_reader parser wake;
    H1.Server_connection.yield_writer parser wake;
    Eio.Promise.await changed

  let serve_client authorities handler socket =
    let phase = ref Empty in
    let parser =
      H1.Server_connection.create ~error_handler:(parser_error phase)
        (request_handler authorities phase)
    in
    let input = Bstr.create max_wire_bytes in
    let pending = ref 0 in
    let received = ref 0 in
    let eof = ref false in
    let scan = { bytes = 0; matched = 0; done_ = false } in
    (* Half-close the response before discarding bounded unread request bytes.
       Closing with unread chunk framing can reset a valid 413 response. *)
    let rec drain () =
      if !eof || !received >= max_wire_bytes then Ok ()
      else
        let length = min read_chunk_bytes (max_wire_bytes - !received) in
        let buffer = Cstruct.of_bigarray ~off:0 ~len:length input in
        match
          Native_io.capture (fun () ->
              try Some (Eio.Flow.single_read socket buffer)
              with End_of_file -> None)
        with
        | Error _ -> Error Peer_closed
        | Ok None -> Ok ()
        | Ok (Some count) ->
            received := !received + count;
            drain ()
    in
    let close_peer () =
      match Native_io.capture (fun () -> Eio.Flow.shutdown socket `Send) with
      | Error _ -> Error Peer_closed
      | Ok () -> drain ()
    in
    let rec pump () =
      (* next_read_operation reports deferred framing errors before dispatch. *)
      let read_operation =
        match !phase with
        | Rejected | Handled -> `Close
        | Empty | Collecting | Complete _ ->
            H1.Server_connection.next_read_operation parser
      in
      (match !phase with
      | Complete (reqd, request) ->
          phase := Handled;
          respond reqd (handler request)
      | Empty | Collecting | Rejected | Handled -> ());
      match H1.Server_connection.next_write_operation parser with
      | `Close _ -> close_peer ()
      | `Upgrade -> Error Peer_closed
      | `Write output -> (
          let bytes =
            List.fold_left (fun total iov -> total + iov.H1.IOVec.len) 0 output
          in
          let buffers =
            List.map
              (fun iov ->
                Cstruct.of_bigarray ~off:iov.H1.IOVec.off ~len:iov.H1.IOVec.len
                  iov.H1.IOVec.buffer)
              output
          in
          match Native_io.capture (fun () -> Eio.Flow.write socket buffers) with
          | Error _ -> Error Peer_closed
          | Ok () ->
              H1.Server_connection.report_write_result parser (`Ok bytes);
              pump ())
      | `Yield -> (
          match read_operation with
          | `Upgrade -> Error Peer_closed
          | `Close ->
              H1.Server_connection.shutdown parser;
              pump ()
          | `Yield ->
              wait_parser parser;
              pump ()
          | `Read -> read ())
    and read () =
      if !eof || !received >= max_wire_bytes || !pending >= max_wire_bytes then
        Error Peer_closed
      else
        let length =
          min read_chunk_bytes
            (min (max_wire_bytes - !pending) (max_wire_bytes - !received + 1))
        in
        let buffer = Cstruct.of_bigarray ~off:!pending ~len:length input in
        let read =
          Native_io.capture (fun () ->
              try Some (Eio.Flow.single_read socket buffer)
              with End_of_file -> None)
        in
        match read with
        | Error _ -> Error Peer_closed
        | Ok count ->
            let count =
              match count with
              | Some n -> n
              | None ->
                  eof := true;
                  0
            in
            if count > max_wire_bytes - !received then Error Peer_closed
            else (
              count_headers scan
                (Bstr.sub_string input ~off:!pending ~len:count);
              received := !received + count;
              pending := !pending + count;
              let consume =
                if !eof then H1.Server_connection.read_eof
                else H1.Server_connection.read
              in
              let consumed = consume parser input ~off:0 ~len:!pending in
              let remaining = !pending - consumed in
              Bstr.blit input ~src_off:consumed input ~dst_off:0 ~len:remaining;
              pending := remaining;
              pump ())
    in
    try pump () with Peer_rejected -> Error Peer_closed

  let connection clock authorities handler socket =
    match client_delay with
    | Error _ -> invalid_arg "Native_status: invalid fixed client deadline"
    | Ok delay ->
        Deadline.run clock ~delay
          ~on_error:(fun _ ->
            Host_failed (diagnostic "HTTP status clock failed."))
          ~on_timeout:(fun () -> Peer_closed)
          (fun () -> serve_client authorities handler socket)

  let induced (error, trace) =
    match Eio_failure.leaves (error, trace) with
    | [] -> false
    | leaves ->
        List.for_all
          (function
            | Eio.Cancel.Cancelled Server_failed, _ | Scope_failed, _ -> true
            | _ -> false)
          leaves

  let current_cancelled () =
    try
      Eio.Fiber.check ();
      false
    with Eio.Cancel.Cancelled _ -> true

  let with_server ~net ~clock ~port ~ready ~handler use =
    let failure = ref None in
    let primary = ref None in
    let callback = ref None in
    let failed, failed_resolve = Eio.Promise.create () in
    let stop, stop_resolve = Eio.Promise.create () in
    let record outcome =
      match !failure with
      | Some _ -> ()
      | None ->
          failure := Some outcome;
          ignore (Eio.Promise.try_resolve stop_resolve ());
          ignore (Eio.Promise.try_resolve failed_resolve ())
    in
    let closure =
      Native_outcome.capture (fun () ->
          Eio.Switch.run (fun sw ->
              Eio.Switch.check sw;
              let address =
                `Tcp (Eio.Net.Ipaddr.V4.loopback, Http_port.number port)
              in
              let setup =
                Native_outcome.capture (fun () ->
                    Native_io.capture (fun () ->
                        let listener =
                          Eio.Net.listen ~sw ~backlog:max_connections net
                            address
                        in
                        let bound =
                          match Eio.Net.listening_addr listener with
                          | `Tcp (_, value) -> value
                          | `Unix _ ->
                              invalid_arg "Native_status: non-TCP listener"
                        in
                        (listener, bound)))
              in
              match setup with
              | Native_outcome.Returned (Error _) ->
                  let error =
                    diagnostic "HTTP status listener could not bind."
                  in
                  primary := Some (Native_outcome.Returned (Error error));
                  Error error
              | Native_outcome.Raised (error, trace) ->
                  primary := Some (Native_outcome.Raised (error, trace));
                  Eio.Switch.fail sw Scope_failed;
                  Error (diagnostic "HTTP status listener setup failed.")
              | Native_outcome.Returned (Ok (listener, bound)) -> (
                  let authorities = authorities bound in
                  let done_, done_resolve = Eio.Promise.create () in
                  let client socket _address =
                    match
                      Native_outcome.capture (fun () ->
                          connection clock authorities handler socket)
                    with
                    | Native_outcome.Returned (Ok () | Error Peer_closed) -> ()
                    | Native_outcome.Returned (Error (Host_failed error)) ->
                        record (Native_outcome.Returned (Error error))
                    | Native_outcome.Raised
                        ((Eio.Cancel.Cancelled _ as error), trace) ->
                        if current_cancelled () then
                          Printexc.raise_with_backtrace error trace
                        else record (Native_outcome.Raised (error, trace))
                    | Native_outcome.Raised (error, trace) ->
                        record (Native_outcome.Raised (error, trace))
                  in
                  Eio.Fiber.fork_daemon ~sw (fun () ->
                      let outcome =
                        Native_outcome.capture (fun () ->
                            Eio.Net.run_server ~max_connections ~stop
                              ~on_error:raise listener client)
                      in
                      (match outcome with
                      | Native_outcome.Returned () -> ()
                      | Native_outcome.Raised ((Unix.Unix_error _ | Eio.Io _), _)
                        ->
                          record
                            (Native_outcome.Returned
                               (Error
                                  (diagnostic "HTTP status listener failed.")))
                      | Native_outcome.Raised
                          ((Eio.Cancel.Cancelled _ as error), trace) ->
                          if not (current_cancelled ()) then
                            record (Native_outcome.Raised (error, trace))
                      | Native_outcome.Raised (error, trace) ->
                          record (Native_outcome.Raised (error, trace)));
                      Eio.Promise.resolve done_resolve ();
                      `Stop_daemon);
                  Eio.Fiber.fork_daemon ~sw (fun () ->
                      Eio.Promise.await failed;
                      (match !callback with
                      | None -> ()
                      | Some cancel ->
                          ignore
                            (Native_outcome.capture (fun () ->
                                 Eio.Cancel.cancel cancel Server_failed)));
                      `Stop_daemon);
                  match !failure with
                  | Some _ ->
                      Eio.Switch.fail sw Scope_failed;
                      Error (diagnostic "HTTP status listener failed.")
                  | None -> (
                      let body =
                        Native_outcome.capture (fun () ->
                            Eio.Cancel.sub (fun cancel ->
                                callback := Some cancel;
                                Eio.Fiber.check ();
                                ready bound;
                                use ()))
                      in
                      primary := Some body;
                      callback := None;
                      ignore (Eio.Promise.try_resolve stop_resolve ());
                      match (body, !failure) with
                      | Native_outcome.Returned (Ok value), None ->
                          Eio.Promise.await done_;
                          Ok value
                      | Native_outcome.Returned (Ok _ | Error _), Some _
                      | Native_outcome.Returned (Error _), None
                      | Native_outcome.Raised _, (None | Some _) ->
                          Eio.Switch.fail sw Scope_failed;
                          Error (diagnostic "HTTP status scope closed.")))))
    in
    callback := None;
    let server_failure () =
      match !failure with
      | None -> Native_outcome.resolve closure
      | Some (Native_outcome.Returned (Error error)) -> Error error
      | Some (Native_outcome.Returned (Ok ())) -> Native_outcome.resolve closure
      | Some (Native_outcome.Raised (error, trace)) ->
          Printexc.raise_with_backtrace error trace
    in
    match !primary with
    | None -> server_failure ()
    | Some (Native_outcome.Returned (Error error)) -> Error error
    | Some (Native_outcome.Raised (error, trace)) ->
        if induced (error, trace) then server_failure ()
        else Printexc.raise_with_backtrace error trace
    | Some (Native_outcome.Returned (Ok value)) -> (
        match !failure with
        | Some _ -> server_failure ()
        | None ->
            Native_outcome.resolve closure |> ignore;
            Ok value)
end
