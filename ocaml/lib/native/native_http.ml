module Make (Clock : Clock.S) = struct
  module Deadline = Deadline.Make (Clock)

  type peer = Name of [ `host ] Domain_name.t | Address of Ipaddr.t

  type endpoint = {
    host : string;
    port : int;
    authority : string;
    resource : string;
    peer : peer;
  }

  type scheme = Authorization_value | Bearer
  type credential = { destination : endpoint; authorization : string }
  type response = Http_transport.response
  type trust = X509.Certificate.t list
  type runtime = Runtime of Mirage_crypto_rng.g

  type limits = {
    request_bytes : int;
    header_bytes : int;
    body_bytes : int;
    wire_bytes : int;
    timeout : Milliseconds.t;
  }

  type t = {
    net : [ `Generic ] Eio.Net.ty Eio.Resource.t;
    clock : Clock.t;
    trust : trust;
    runtime : runtime;
    limits : limits;
  }

  let secure_prefix = "https://"
  let secure_port = 443
  let maximum_port = 65535
  let read_chunk = 4096
  let terminal_probe = 1
  let minimum_final_status = 200
  let redirect_start = 300
  let redirect_end = 399
  let maximum_status = 599

  let diagnostic message remedy =
    Diagnostic.make ~site:(Diagnostic.Host "tracker.http") ~message ~remedy

  let invalid_endpoint () =
    diagnostic "Invalid tracker.provider.endpoint"
      "Set an absolute HTTPS URL with a DNS name or IP, no userinfo or fragment"

  let unreserved = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
    | _ -> false

  let subdelimiter = function
    | '!' | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | ';' | '=' -> true
    | _ -> false

  let component allowed source =
    let hex = function
      | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
      | _ -> false
    in
    let rec loop offset =
      if offset = String.length source then true
      else if source.[offset] = '%' then
        offset + 2 < String.length source
        && hex source.[offset + 1]
        && hex source.[offset + 2]
        && loop (offset + 3)
      else allowed source.[offset] && loop (offset + 1)
    in
    loop 0

  let valid_port source =
    source <> ""
    && String.for_all (fun c -> c >= '0' && c <= '9') source
    && Option.fold ~none:false
         ~some:(fun value -> value > 0 && value <= maximum_port)
         (int_of_string_opt source)

  let valid_authority source =
    if String.starts_with ~prefix:"[" source then
      match String.index_opt source ']' with
      | None -> false
      | Some closing ->
          let host = String.sub source 1 (closing - 1) in
          let suffix =
            String.sub source (closing + 1) (String.length source - closing - 1)
          in
          Result.is_ok
            (Angstrom.parse_string ~consume:Angstrom.Consume.All Uri.Parser.ipv6
               host)
          && (suffix = ""
             || String.starts_with ~prefix:":" suffix
                && valid_port (String.sub suffix 1 (String.length suffix - 1)))
    else
      let host value =
        value <> "" && component (fun c -> unreserved c || subdelimiter c) value
      in
      match String.split_on_char ':' source with
      | [ name ] -> host name
      | [ name; number ] -> host name && valid_port number
      | [] | _ :: _ -> false

  let raw_endpoint source =
    let start = String.length secure_prefix in
    if
      String.length source < start
      || String.lowercase_ascii (String.sub source 0 start) <> secure_prefix
    then None
    else
      let rec finish offset =
        if offset = String.length source then offset
        else
          match source.[offset] with
          | '/' | '?' | '#' -> offset
          | _ -> finish (offset + 1)
      in
      let stop = finish start in
      let authority = String.sub source start (stop - start) in
      let resource = String.sub source stop (String.length source - stop) in
      let path, query =
        match String.index_opt resource '?' with
        | None -> (resource, "")
        | Some offset ->
            ( String.sub resource 0 offset,
              String.sub resource (offset + 1)
                (String.length resource - offset - 1) )
      in
      let pchar c = unreserved c || subdelimiter c || c = ':' || c = '@' in
      if
        valid_authority authority
        && component (fun c -> pchar c || c = '/') path
        && component (fun c -> pchar c || c = '/' || c = '?') query
      then
        Some
          (if resource = "" || String.starts_with ~prefix:"?" resource then
             "/" ^ resource
           else resource)
      else None

  let endpoint source =
    let invalid = Error (invalid_endpoint ()) in
    match raw_endpoint source with
    | None -> invalid
    | Some resource -> (
        (* Uri's parser consumes the checked raw syntax without repairing it. *)
        match
          Angstrom.parse_string ~consume:Angstrom.Consume.All
            Uri.Parser.uri_reference source
        with
        | Error _ -> invalid
        | Ok uri -> (
            match
              (Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.fragment uri)
            with
            | Some "https", Some host, None, None ->
                let peer =
                  match Ipaddr.of_string host with
                  | Ok ip -> Ok (Address ip, Ipaddr.to_string ip)
                  | Error _ ->
                      Result.bind (Domain_name.of_string host) (fun name ->
                          Result.map
                            (fun name ->
                              (Name name, String.lowercase_ascii host))
                            (Domain_name.host name))
                in
                Result.fold
                  ~error:(fun _ -> invalid)
                  ~ok:(fun (peer, host) ->
                    let port =
                      Option.value ~default:secure_port (Uri.port uri)
                    in
                    let authority =
                      match peer with
                      | Name _ | Address (Ipaddr.V4 _) -> host
                      | Address (Ipaddr.V6 _) -> "[" ^ host ^ "]"
                    in
                    let authority =
                      if port = secure_port then authority
                      else authority ^ ":" ^ string_of_int port
                    in
                    Ok { host; port; authority; resource; peer })
                  peer
            | _ -> invalid))

  let credential destination ~scheme ~token =
    if
      String.trim token = ""
      || not
           (String.for_all
              (fun c -> Char.code c >= 32 && Char.code c <> 127)
              token)
    then
      Error
        (diagnostic "Invalid tracker.provider.api_key"
           "Set a nonempty credential without header control characters")
    else
      let authorization =
        match scheme with
        | Authorization_value -> token
        | Bearer -> "Bearer " ^ token
      in
      Ok { destination; authorization }

  let equal a b =
    String.equal a.destination.host b.destination.host
    && a.destination.port = b.destination.port
    && String.equal a.destination.resource b.destination.resource
    && String.equal a.authorization b.authorization

  let redacted _ = "<redacted>"

  let trust ~pem =
    match X509.Certificate.decode_pem_multiple pem with
    | Ok (_ :: _ as anchors) -> Ok anchors
    | Ok [] | Error _ ->
        Error
          (diagnostic "Invalid tracker TLS trust bundle"
             "Supply a bounded PEM file containing at least one CA certificate")

  let limits ~request_bytes ~header_bytes ~body_bytes ~wire_bytes ~timeout =
    if
      request_bytes <= 0 || header_bytes <= 0 || body_bytes <= 0
      || wire_bytes <= 0
      || Milliseconds.compare timeout Milliseconds.zero <= 0
    then
      Error
        (diagnostic "Invalid tracker HTTP limits"
           "Set positive request, header, body, wire and timeout limits")
    else Ok { request_bytes; header_bytes; body_bytes; wire_bytes; timeout }

  let activate () =
    Mirage_crypto_rng_unix.use_default ();
    Runtime (Mirage_crypto_rng.default_generator ())

  let create ~net ~clock ~trust ~runtime ~limits =
    {
      net :> [ `Generic ] Eio.Net.ty Eio.Resource.t;
      clock;
      trust;
      runtime;
      limits;
    }

  let host operation action =
    try
      match Native_io.capture action with
      | Ok value -> Ok value
      | Error (Native_io.Unix _ | Native_io.Io _) ->
          Error
            (diagnostic (operation ^ " failed")
               "Check tracker connectivity and the explicit TLS trust bundle")
    with Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ ->
      Error
        (diagnostic "Tracker TLS authentication or protocol failed"
           "Check the endpoint host, server certificate and explicit CA bundle")

  let budget name =
    diagnostic
      ("Tracker HTTP " ^ name ^ " byte limit exceeded")
      "Reduce the tracker response or increase the documented byte limit"

  type data = { status : int; body : Buffer.t }

  type phase =
    | Headers
    | Body of data
    | Finished of data
    | Failed of Diagnostic.t
    | Raised of exn * Printexc.raw_backtrace

  let callbacks limits =
    let phase = ref Headers in
    let fail error =
      match !phase with
      | Failed _ | Raised _ -> ()
      | Headers | Body _ | Finished _ -> phase := Failed error
    in
    let guard action =
      match !phase with
      | Failed _ | Raised _ -> ()
      | Headers | Body _ | Finished _ -> (
          try action ()
          with exn -> phase := Raised (exn, Printexc.get_raw_backtrace ()))
    in
    let response_handler response reader =
      guard (fun () ->
          let status = H1.Status.to_code response.H1.Response.status in
          if status < minimum_final_status || status > maximum_status then
            fail
              (diagnostic "Tracker returned an unsupported HTTP status"
                 "Use an endpoint returning one final HTTP/1.1 response")
          else if status >= redirect_start && status <= redirect_end then
            fail
              (diagnostic "Tracker HTTP redirect rejected"
                 "Set tracker.provider.endpoint to the final HTTPS destination")
          else
            let data =
              {
                status;
                body = Buffer.create (min read_chunk limits.body_bytes);
              }
            in
            phase := Body data;
            let rec schedule () =
              H1.Body.Reader.schedule_read reader
                ~on_eof:(fun () ->
                  guard (fun () ->
                      match !phase with
                      | Body data -> phase := Finished data
                      | Headers | Finished _ | Failed _ | Raised _ -> ()))
                ~on_read:(fun bytes ~off ~len ->
                  guard (fun () ->
                      if len > limits.body_bytes - Buffer.length data.body then
                        fail (budget "body")
                      else (
                        Buffer.add_string data.body
                          (Bstr.sub_string bytes ~off ~len);
                        schedule ())))
            in
            schedule ())
    in
    let error_handler = function
      | `Malformed_response _ | `Invalid_response_body_length _ ->
          fail
            (diagnostic "Malformed or incomplete tracker HTTP response"
               "Check the tracker server or its HTTP proxy")
      | `Exn exn -> (
          match !phase with
          | Raised _ | Failed _ -> ()
          | Headers | Body _ | Finished _ ->
              (* Our callbacks capture the original backtrace before H1 catches it. *)
              phase := Raised (exn, Printexc.get_raw_backtrace ()))
    in
    (phase, response_handler, error_handler)

  type input = { mutable bytes : Bstr.t; mutable used : int }
  type read_event = Data of int | Eof

  let reserve input count maximum =
    let required = input.used + count in
    let available = Bigarray.Array1.dim input.bytes in
    if required > available then (
      let grown =
        min maximum
          (max required (available + min available (maximum - available)))
      in
      let bytes = Bstr.create grown in
      Cstruct.blit
        (Cstruct.of_bigarray input.bytes)
        0
        (Cstruct.of_bigarray bytes)
        0 input.used;
      input.bytes <- bytes)

  let read_response flow limits phase connection =
    let input =
      { bytes = Bstr.create (min read_chunk limits.wire_bytes); used = 0 }
    in
    let received = ref 0 in
    let read destination =
      try
        Result.map
          (fun n -> Data n)
          (host "Tracker response read" (fun () ->
               Eio.Flow.single_read flow destination))
      with End_of_file -> Ok Eof
    in
    let feed event =
      let consumed =
        match event with
        | Data count ->
            received := !received + count;
            input.used <- input.used + count;
            H1.Client_connection.read connection input.bytes ~off:0
              ~len:input.used
        | Eof ->
            H1.Client_connection.read_eof connection input.bytes ~off:0
              ~len:input.used
      in
      input.used <- input.used - consumed;
      if input.used > 0 then
        Cstruct.blit
          (Cstruct.of_bigarray input.bytes)
          consumed
          (Cstruct.of_bigarray input.bytes)
          0 input.used
    in
    let rec loop () =
      let operation = H1.Client_connection.next_read_operation connection in
      match !phase with
      | Failed error -> Error error
      | Raised (exn, trace) -> Printexc.raise_with_backtrace exn trace
      | Finished data ->
          Ok
            {
              Http_transport.status = data.status;
              body = Buffer.contents data.body;
            }
      | Headers | Body _ -> (
          match operation with
          | `Close ->
              Error
                (diagnostic "Tracker HTTP closed before response completion"
                   "Check the tracker server or its HTTP proxy")
          | `Read -> (
              let remaining = limits.wire_bytes - !received in
              let remaining =
                match !phase with
                | Headers -> min remaining (limits.header_bytes - !received)
                | Body _ | Finished _ | Failed _ | Raised _ -> remaining
              in
              if remaining <= 0 then
                match !phase with
                | Body _ when !received = limits.wire_bytes -> (
                    (* EOF distinguishes an exact-limit close-delimited body.
                       Any extra byte is rejected without feeding or retaining it. *)
                    match read (Cstruct.create terminal_probe) with
                    | Error _ as error -> error
                    | Ok (Data _) -> Error (budget "wire")
                    | Ok Eof ->
                        feed Eof;
                        loop ())
                | Headers | Body _ | Finished _ | Failed _ | Raised _ ->
                    Error
                      (budget
                         (if !received >= limits.wire_bytes then "wire"
                          else "header"))
              else
                let count = min read_chunk remaining in
                reserve input count limits.wire_bytes;
                let destination =
                  Cstruct.of_bigarray input.bytes ~off:input.used ~len:count
                in
                match read destination with
                | Error _ as error -> error
                | Ok event ->
                    feed event;
                    (* Always expose pending codec errors before reading body EOF. *)
                    loop ()))
    in
    loop ()

  let write_request flow connection =
    let rec loop () =
      match H1.Client_connection.next_write_operation connection with
      | `Close _ -> Ok ()
      | `Yield ->
          let ready, resolve = Eio.Promise.create () in
          H1.Client_connection.yield_writer connection (fun () ->
              Eio.Promise.resolve resolve ());
          Eio.Promise.await ready;
          loop ()
      | `Write vectors -> (
          let buffers =
            List.map
              (fun H1.IOVec.{ buffer; off; len } ->
                Cstruct.of_bigarray buffer ~off ~len)
              vectors
          in
          match
            host "Tracker request write" (fun () -> Eio.Flow.write flow buffers)
          with
          | Error error ->
              H1.Client_connection.report_write_result connection `Closed;
              Error error
          | Ok () ->
              let count =
                List.fold_left
                  (fun total buffer -> total + Cstruct.length buffer)
                  0 buffers
              in
              H1.Client_connection.report_write_result connection (`Ok count);
              loop ())
    in
    loop ()

  let headers limits credential body_bytes =
    let fields =
      [
        ("Host", credential.destination.authority);
        ("Authorization", credential.authorization);
        ("Content-Type", "application/json");
        ("Accept", "application/json");
        ("Content-Length", string_of_int body_bytes);
        ("Connection", "close");
      ]
    in
    let take remaining source =
      let length = String.length source in
      if length > remaining then Error (budget "request header")
      else Ok (remaining - length)
    in
    let ( let* ) = Result.bind in
    let* remaining = take limits.header_bytes "POST " in
    let* remaining = take remaining credential.destination.resource in
    let* remaining = take remaining " HTTP/1.1\r\n" in
    let* remaining =
      List.fold_left
        (fun allowance (name, value) ->
          let* remaining = allowance in
          let* remaining = take remaining name in
          let* remaining = take remaining ": " in
          let* remaining = take remaining value in
          take remaining "\r\n")
        (Ok remaining) fields
    in
    let* _ = take remaining "\r\n" in
    Ok (H1.Headers.of_list fields)

  let exchange flow limits credential headers body =
    let phase, response_handler, error_handler = callbacks limits in
    let writer, connection =
      H1.Client_connection.request
        (H1.Request.create ~headers `POST credential.destination.resource)
        ~response_handler ~error_handler
    in
    H1.Body.Writer.write_string writer body;
    H1.Body.Writer.close writer;
    let waiting, _ = Eio.Promise.create () in
    Native_outcome.resolve
      (Eio.Fiber.first
         (fun () ->
           Native_outcome.capture (fun () ->
               read_response flow limits phase connection))
         (fun () ->
           Native_outcome.capture (fun () ->
               match write_request flow connection with
               | Error _ as error -> error
               | Ok () -> Eio.Promise.await waiting)))

  type 'a admission = Not_entered | Entered of 'a Native_outcome.t

  exception Scope_defect

  let scoped action =
    let primary = ref Not_entered in
    let closure =
      Native_outcome.capture (fun () ->
          Eio.Switch.run (fun sw ->
              primary := Entered (Native_outcome.capture (fun () -> action sw))))
    in
    match !primary with
    | Not_entered ->
        Native_outcome.resolve closure;
        raise Scope_defect
    | Entered (Native_outcome.Raised (exn, trace)) ->
        Printexc.raise_with_backtrace exn trace
    | Entered (Native_outcome.Returned (Error _ as error)) -> error
    | Entered (Native_outcome.Returned (Ok value)) -> (
        match closure with
        | Native_outcome.Returned () -> Ok value
        | Native_outcome.Raised (Eio.Io _, _) ->
            Error
              (diagnostic "Tracker connection cleanup failed"
                 "Check host socket resources")
        | Native_outcome.Raised (exn, trace) ->
            Printexc.raise_with_backtrace exn trace)

  let connect t sw destination =
    Result.bind
      (host "Tracker address lookup" (fun () ->
           Eio.Net.getaddrinfo_stream
             ~service:(string_of_int destination.port)
             t.net destination.host))
      (fun addresses ->
        let rec attempt = function
          | [] ->
              Error
                (diagnostic "Tracker connection failed"
                   "Check tracker endpoint and network connectivity")
          | address :: rest -> (
              match
                host "Tracker connection" (fun () ->
                    Eio.Net.connect ~sw t.net address)
              with
              | Ok flow -> Ok flow
              | Error _ -> attempt rest)
        in
        attempt addresses)

  let request t credential headers body =
    let ( let* ) = Result.bind in
    let* sample = Clock.sample t.clock in
    let* wall =
      match Ptime.of_rfc3339 (Utc.rfc3339 sample.Clock.Pure.wall) with
      | Ok (value, _, _) -> Ok value
      | Error _ ->
          Error
            (diagnostic "Tracker TLS wall time conversion failed"
               "Check the host wall clock")
    in
    let authenticator =
      X509.Authenticator.chain_of_trust ~time:(fun () -> Some wall) t.trust
    in
    let name, ip =
      match credential.destination.peer with
      | Name name -> (Some name, None)
      | Address ip -> (None, Some ip)
    in
    let* config =
      Result.map_error
        (fun _ ->
          diagnostic "Tracker TLS configuration failed"
            "Check the explicit TLS trust bundle")
        (Tls.Config.client ~authenticator ?peer_name:name ?ip
           ~version:(`TLS_1_2, `TLS_1_3) ~alpn_protocols:[ "http/1.1" ] ())
    in
    scoped (fun sw ->
        let* socket = connect t sw credential.destination in
        let* flow =
          try
            host "Tracker TLS handshake" (fun () ->
                Tls_eio.client_of_flow config ?host:name ?ip socket)
          with End_of_file ->
            Error
              (diagnostic "Tracker closed during TLS handshake"
                 "Check tracker endpoint and server TLS configuration")
        in
        exchange flow t.limits credential headers body)

  let post t credential ~body =
    let (Runtime installed) = t.runtime in
    if Mirage_crypto_rng.default_generator () != installed then
      Error
        (diagnostic "Tracker crypto runtime was replaced"
           "Activate one crypto runtime for the host process")
    else if Json.encoded_bytes body > t.limits.request_bytes then
      Error (budget "request")
    else
      Result.bind
        (headers t.limits credential (Json.encoded_bytes body))
        (fun headers ->
          let body = Json.encode body in
          Deadline.run t.clock ~delay:t.limits.timeout ~on_error:Fun.id
            ~on_timeout:(fun () ->
              diagnostic "Tracker HTTP deadline exceeded"
                "Check tracker availability or increase the documented timeout")
            (fun () -> request t credential headers body))
end
