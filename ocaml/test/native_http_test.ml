(** Native HTTPS integration controls. Test keys have no production authority.
*)
module Test_clock = struct
  module Pure = Clock_posix.Pure

  type t = System of Clock_posix.t | Defective of Clock_posix.t * exn

  let native = function
    | System clock | Defective (clock, _) -> clock

  let now clock = Clock_posix.now (native clock)

  let sleep_until clock deadline =
    Clock_posix.sleep_until (native clock) deadline

  let sample = function
    | System clock -> Clock_posix.sample clock
    | Defective (_, exn) -> raise exn
end

module Http = Native_http.Make (Test_clock)

let checked = function
  | Ok value -> value
  | Error reason -> Alcotest.fail reason

let succeeded = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Diagnostic.render error)

let rejected = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "Expected a checked HTTP failure"

let tls_rejection = function
  | Ok _ -> false
  | Error error ->
      let expected =
        Diagnostic.make ~site:(Diagnostic.Host "tracker.http")
          ~message:"Tracker TLS authentication or protocol failed"
          ~remedy:
            "Check the endpoint host, server certificate and explicit CA bundle"
      in
      String.equal (Diagnostic.render expected) (Diagnostic.render error)

let rejection_classifier () =
  List.iter
    (fun message ->
      let error =
        Diagnostic.make ~site:(Diagnostic.Host "tracker.http") ~message
          ~remedy:"Fixture control"
      in
      Alcotest.(check bool)
        "unrelated failure is not TLS rejection" false
        (tls_rejection (Error error)))
    [ "Tracker HTTP deadline exceeded"; "Tracker connection failed" ]

let body = checked (Json.parse "{}")
let request_bound = 4096
let header_bound = 4096
let body_bound = 4096
let wire_bound = 8192
let fixture_timeout = "1000"
let close_timeout_seconds = 5.
let fixture_buffer = 4096
let request_capture_bound = 16384

let limits ?(request_bytes = request_bound) ?(header_bytes = header_bound)
    ?(body_bytes = body_bound) ?(wire_bytes = wire_bound)
    ?(timeout = fixture_timeout) () =
  succeeded
    (Http.limits ~request_bytes ~header_bytes ~body_bytes ~wire_bytes
       ~timeout:(checked (Milliseconds.parse timeout)))

type identity = Matching | Wrong_name | Rsa_signed | Rsa_zero | Rsa_one
type closure = Close_reply | Await_close
type reply = Wire of string list * closure | Silent

let pem cwd name =
  let directory = Eio.Path.( / ) cwd "fixtures/tls" in
  Eio.Path.load (Eio.Path.( / ) directory name)

type anchors = Trusted | Unrelated | Rsa_trusted

let trust cwd anchors =
  let name =
    match anchors with
    | Trusted -> "ca.pem"
    | Unrelated -> "other-ca.pem"
    | Rsa_trusted -> "rsa-ca.pem"
  in
  succeeded (Http.trust ~pem:(pem cwd name))

let server_config cwd identity =
  let certificate, key =
    match identity with
    | Matching -> ("server.pem", "server.key")
    | Wrong_name -> ("wrong-host.pem", "wrong-host.key")
    | Rsa_signed -> ("rsa-signed.pem", "server.key")
    | Rsa_zero -> ("rsa-signature-0.pem", "server.key")
    | Rsa_one -> ("rsa-signature-1.pem", "server.key")
  in
  let chain =
    match X509.Certificate.decode_pem_multiple (pem cwd certificate) with
    | Ok chain -> chain
    | Error (`Msg message) -> Alcotest.fail message
  in
  let key =
    match X509.Private_key.decode_pem (pem cwd key) with
    | Ok key -> key
    | Error (`Msg message) -> Alcotest.fail message
  in
  match
    Tls.Config.server
      ~certificates:(`Single (chain, key))
      ~version:(`TLS_1_2, `TLS_1_3) ~alpn_protocols:[ "http/1.1" ] ()
  with
  | Ok config -> config
  | Error (`Msg message) -> Alcotest.fail message

let receive_request flow =
  let scratch = Cstruct.create fixture_buffer in
  let request = Buffer.create fixture_buffer in
  let rec read () =
    let count = Eio.Flow.single_read flow scratch in
    if count > request_capture_bound - Buffer.length request then
      Alcotest.fail "Fixture request exceeded capture bound";
    Buffer.add_string request (Cstruct.to_string ~len:count scratch);
    let captured = Buffer.contents request in
    if String.ends_with ~suffix:"\r\n\r\n{}" captured then captured else read ()
  in
  read ()

let await_close flow =
  let scratch = Cstruct.create fixture_buffer in
  let rec read () =
    match Eio.Flow.single_read flow scratch with
    | _ -> read ()
    | exception End_of_file -> ()
  in
  read ()

let with_server runtime ~identity ~anchors ~limits ~reply run =
  Eio_posix.run (fun host ->
      let net = Eio.Stdenv.net host in
      let cwd = Eio.Stdenv.cwd host in
      let trust = trust cwd anchors in
      let clock =
        Test_clock.System
          (Clock_posix.create
             ~mono:(Eio.Stdenv.mono_clock host)
             ~wall:(Eio.Stdenv.clock host))
      in
      Eio.Switch.run (fun sw ->
          let listener =
            Eio.Net.listen ~sw ~backlog:1 net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let endpoint =
            match Eio.Net.listening_addr listener with
            | `Tcp (_, port) ->
                succeeded
                  (Http.endpoint
                     ("https://localhost:" ^ string_of_int port ^ "/graphql"))
            | `Unix _ -> Alcotest.fail "Expected a TCP fixture"
          in
          let credential =
            succeeded
              (Http.credential endpoint ~scheme:Http.Bearer
                 ~token:"fixture-token")
          in
          let http = Http.create ~net ~clock ~trust ~runtime ~limits in
          let ready, resolve = Eio.Promise.create () in
          let captured = ref None in
          let client_closed = ref false in
          Eio.Fiber.both
            (fun () ->
              Eio.Switch.run (fun server_sw ->
                  let socket, _ = Eio.Net.accept ~sw:server_sw listener in
                  match
                    Tls_eio.server_of_flow (server_config cwd identity) socket
                  with
                  | flow -> (
                      captured := Some (receive_request flow);
                      Eio.Promise.resolve resolve ();
                      match reply with
                      | Silent ->
                          await_close flow;
                          client_closed := true
                      | Wire (fragments, closure) -> (
                          List.iter
                            (fun fragment ->
                              Eio.Flow.write flow [ Cstruct.of_string fragment ];
                              Eio.Fiber.yield ())
                            fragments;
                          match closure with
                          | Close_reply -> Eio.Resource.close flow
                          | Await_close ->
                              await_close flow;
                              client_closed := true))
                  | exception (Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _) -> (
                      match identity with
                      | Matching | Wrong_name | Rsa_signed -> ()
                      | Rsa_zero | Rsa_one ->
                          (* Observe EOF before the server's own switch closes. *)
                          Eio.Time.with_timeout_exn (Eio.Stdenv.clock host)
                            close_timeout_seconds (fun () -> await_close socket);
                          client_closed := true)
                  | exception End_of_file -> client_closed := true))
            (fun () ->
              run ~post:(fun () -> Http.post http credential ~body) ~ready);
          match (identity, anchors, !captured) with
          | Matching, Trusted, None | Rsa_signed, Rsa_trusted, None ->
              Alcotest.fail "Trusted fixture did not receive the request"
          | ( (Wrong_name | Rsa_zero | Rsa_one),
              (Trusted | Unrelated | Rsa_trusted),
              captured )
          | Matching, (Unrelated | Rsa_trusted), captured
          | Rsa_signed, (Trusted | Unrelated), captured -> (
              match captured with
              | None -> (
                  match identity with
                  | Matching | Wrong_name | Rsa_signed -> ()
                  | Rsa_zero | Rsa_one ->
                      Alcotest.(check bool)
                        "rejected client socket reached EOF" true !client_closed
                  )
              | Some _ ->
                  Alcotest.fail "Credential reached an unauthenticated server")
          | Matching, Trusted, Some request
          | Rsa_signed, Rsa_trusted, Some request -> (
              Alcotest.(check bool)
                "literal request target" true
                (String.starts_with ~prefix:"POST /graphql HTTP/1.1\r\n" request);
              let fields = String.split_on_char '\n' request in
              Alcotest.(check bool)
                "destination-bound authorization" true
                (List.mem "Authorization: Bearer fixture-token\r" fields);
              match reply with
              | Wire (_, Close_reply) -> ()
              | Wire (_, Await_close) | Silent ->
                  Alcotest.(check bool)
                    "client socket closed" true !client_closed)))

let fixed body =
  "HTTP/1.1 200 OK\r\nContent-Length: "
  ^ string_of_int (String.length body)
  ^ "\r\nConnection: close\r\n\r\n" ^ body

let complete runtime () =
  with_server runtime ~identity:Matching ~anchors:Trusted ~limits:(limits ())
    ~reply:(Wire ([ fixed "answer" ], Await_close))
    (fun ~post ~ready:_ ->
      let response = succeeded (post ()) in
      Alcotest.(check int) "HTTP status" 200 response.Http_transport.status;
      Alcotest.(check string)
        "decoded body" "answer" response.Http_transport.body)

let fragmented runtime () =
  let wire =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    ^ "2\r\nok\r\n1\r\n!\r\n0\r\n\r\n"
  in
  let fragments =
    List.init (String.length wire) (fun index -> String.make 1 wire.[index])
  in
  with_server runtime ~identity:Matching ~anchors:Trusted ~limits:(limits ())
    ~reply:(Wire (fragments, Await_close))
    (fun ~post ~ready:_ ->
      let response = succeeded (post ()) in
      Alcotest.(check string) "chunked body" "ok!" response.Http_transport.body)

let wrong_ca runtime () =
  with_server runtime ~identity:Matching ~anchors:Unrelated ~limits:(limits ())
    ~reply:Silent (fun ~post ~ready:_ -> rejected (post ()))

let wrong_name runtime () =
  with_server runtime ~identity:Wrong_name ~anchors:Trusted ~limits:(limits ())
    ~reply:Silent (fun ~post ~ready:_ -> rejected (post ()))

let rsa_trusted runtime () =
  with_server runtime ~identity:Rsa_signed ~anchors:Rsa_trusted
    ~limits:(limits ())
    ~reply:(Wire ([ fixed "trusted RSA issuer" ], Close_reply))
    (fun ~post ~ready:_ ->
      let response = succeeded (post ()) in
      Alcotest.(check string)
        "authenticated body" "trusted RSA issuer" response.Http_transport.body)

let rsa_rejected identity runtime () =
  with_server runtime ~identity ~anchors:Rsa_trusted ~limits:(limits ())
    ~reply:Silent (fun ~post ~ready:_ ->
      Alcotest.(check bool)
        "checked TLS rejection" true
        (tls_rejection (post ())))

let truncated runtime () =
  with_server runtime ~identity:Matching ~anchors:Trusted ~limits:(limits ())
    ~reply:
      (Wire
         ([ "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort" ], Close_reply))
    (fun ~post ~ready:_ -> rejected (post ()))

let malformed runtime () =
  with_server runtime ~identity:Matching ~anchors:Trusted ~limits:(limits ())
    ~reply:
      (Wire
         ( [ "HTTP/1.1 600 Unsupported\r\nContent-Length: 0\r\n\r\n" ],
           Await_close ))
    (fun ~post ~ready:_ -> rejected (post ()))

let redirect runtime () =
  with_server runtime ~identity:Matching ~anchors:Trusted ~limits:(limits ())
    ~reply:
      (Wire
         ( [
             "HTTP/1.1 302 Found\r\n\
              Location: https://wrong.invalid/\r\n\
              Content-Length: 0\r\n\
              \r\n";
           ],
           Await_close ))
    (fun ~post ~ready:_ -> rejected (post ()))

let body_limit runtime () =
  with_server runtime ~identity:Matching ~anchors:Trusted
    ~limits:(limits ~body_bytes:3 ())
    ~reply:(Wire ([ fixed "four" ], Await_close))
    (fun ~post ~ready:_ -> rejected (post ()))

let header_limit runtime () =
  let wire =
    "HTTP/1.1 200 OK\r\nPadding: " ^ String.make 512 'x'
    ^ "\r\nContent-Length: 0\r\n\r\n"
  in
  with_server runtime ~identity:Matching ~anchors:Trusted
    ~limits:(limits ~header_bytes:256 ())
    ~reply:(Wire ([ wire ], Await_close))
    (fun ~post ~ready:_ -> rejected (post ()))

let wire_limit runtime () =
  let wire =
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    ^ String.concat "" (List.init 10 (fun _ -> "1\r\nx\r\n"))
    ^ "0\r\n\r\n"
  in
  with_server runtime ~identity:Matching ~anchors:Trusted
    ~limits:(limits ~wire_bytes:80 ())
    ~reply:(Wire ([ wire ], Await_close))
    (fun ~post ~ready:_ -> rejected (post ()))

let delimited_wire = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nabc"

let wire_exact runtime () =
  with_server runtime ~identity:Matching ~anchors:Trusted
    ~limits:(limits ~wire_bytes:(String.length delimited_wire) ())
    ~reply:(Wire ([ delimited_wire ], Close_reply))
    (fun ~post ~ready:_ ->
      let response = succeeded (post ()) in
      Alcotest.(check string)
        "exact-limit body" "abc" response.Http_transport.body)

let wire_excess runtime () =
  with_server runtime ~identity:Matching ~anchors:Trusted
    ~limits:(limits ~wire_bytes:(String.length delimited_wire) ())
    ~reply:(Wire ([ delimited_wire ^ "!" ], Close_reply))
    (fun ~post ~ready:_ -> rejected (post ()))

let timeout runtime () =
  with_server runtime ~identity:Matching ~anchors:Trusted
    ~limits:(limits ~timeout:"100" ()) ~reply:Silent (fun ~post ~ready:_ ->
      rejected (post ()))

exception Stop

let cancellation runtime () =
  with_server runtime ~identity:Matching ~anchors:Trusted ~limits:(limits ())
    ~reply:Silent (fun ~post ~ready ->
      let outcome =
        try
          let _ =
            Eio.Cancel.sub (fun cancel ->
                Eio.Fiber.both
                  (fun () -> ignore (post ()))
                  (fun () ->
                    Eio.Promise.await ready;
                    Eio.Cancel.cancel cancel Stop))
          in
          None
        with exn -> Some (exn, Printexc.get_raw_backtrace ())
      in
      match outcome with
      | Some (Eio.Cancel.Cancelled Stop, _) -> ()
      | Some (exn, _) -> Alcotest.fail (Printexc.to_string exn)
      | None -> Alcotest.fail "External cancellation disappeared")

exception Sample_defect

let defect runtime () =
  Eio_posix.run (fun host ->
      let clock =
        Test_clock.Defective
          ( Clock_posix.create
              ~mono:(Eio.Stdenv.mono_clock host)
              ~wall:(Eio.Stdenv.clock host),
            Sample_defect )
      in
      let endpoint = succeeded (Http.endpoint "https://localhost:1/") in
      let credential =
        succeeded
          (Http.credential endpoint ~scheme:Http.Bearer ~token:"fixture-token")
      in
      let http =
        Http.create ~net:(Eio.Stdenv.net host) ~clock
          ~trust:(trust (Eio.Stdenv.cwd host) Trusted)
          ~runtime ~limits:(limits ())
      in
      match Http.post http credential ~body with
      | Ok _ | Error _ -> Alcotest.fail "Clock defect became an HTTP value"
      | exception exn ->
          let trace =
            Printexc.raw_backtrace_to_string (Printexc.get_raw_backtrace ())
          in
          Alcotest.(check bool) "exception identity" true (exn == Sample_defect);
          let retained =
            List.exists
              (String.starts_with
                 ~prefix:
                   "Raised at Dune__exe__Native_http_test.Test_clock.sample")
              (String.split_on_char '\n' trace)
          in
          if not retained then Alcotest.fail trace)

let preflight runtime () =
  Eio_posix.run (fun host ->
      let clock =
        Test_clock.Defective
          ( Clock_posix.create
              ~mono:(Eio.Stdenv.mono_clock host)
              ~wall:(Eio.Stdenv.clock host),
            Sample_defect )
      in
      let endpoint = succeeded (Http.endpoint "https://localhost:1/") in
      let credential =
        succeeded
          (Http.credential endpoint ~scheme:Http.Bearer ~token:"fixture-token")
      in
      let create limits =
        Http.create ~net:(Eio.Stdenv.net host) ~clock
          ~trust:(trust (Eio.Stdenv.cwd host) Trusted)
          ~runtime ~limits
      in
      rejected
        (Http.post (create (limits ~request_bytes:1 ())) credential ~body);
      rejected (Http.post (create (limits ~header_bytes:1 ())) credential ~body))

let constructors () =
  List.iter
    (fun endpoint -> rejected (Http.endpoint endpoint))
    [
      "http://localhost/";
      "https://user@localhost/";
      "https://localhost/#fragment";
      "https://localhost/%zz";
      "https://localhost:0/";
      "https://localhost/\r\nx: y";
    ];
  rejected (Http.trust ~pem:"");
  rejected (Http.trust ~pem:"not a certificate");
  rejected
    (Http.limits ~request_bytes:1 ~header_bytes:1 ~body_bytes:1 ~wire_bytes:1
       ~timeout:Milliseconds.zero)

let adoption _runtime () =
  let installed = Mirage_crypto_rng.default_generator () in
  defect (Native_http.defer ()) ();
  Alcotest.(check bool)
    "preexisting generator retained" true
    (Mirage_crypto_rng.default_generator () == installed)

let replacement runtime () =
  let installed = Mirage_crypto_rng.default_generator () in
  Fun.protect
    ~finally:(fun () -> Mirage_crypto_rng.set_default_generator installed)
    (fun () ->
      (* A foreign owner changes the process global after this runtime was used. *)
      Mirage_crypto_rng_unix.use_default ();
      Eio_posix.run (fun host ->
          let clock =
            Test_clock.Defective
              ( Clock_posix.create
                  ~mono:(Eio.Stdenv.mono_clock host)
                  ~wall:(Eio.Stdenv.clock host),
                Sample_defect )
          in
          let endpoint = succeeded (Http.endpoint "https://localhost:1/") in
          let credential =
            succeeded
              (Http.credential endpoint ~scheme:Http.Bearer
                 ~token:"fixture-token")
          in
          let http =
            Http.create ~net:(Eio.Stdenv.net host) ~clock
              ~trust:(trust (Eio.Stdenv.cwd host) Trusted)
              ~runtime ~limits:(limits ())
          in
          rejected (Http.post http credential ~body)))

let () =
  Printexc.record_backtrace true;
  let runtime = Native_http.defer () in
  let case name run = Alcotest.test_case name `Quick (run runtime) in
  Alcotest.run "native HTTPS"
    [
      ( "native HTTP",
        [
          case "trusted destination and request" complete;
          case "fragmented chunk body" fragmented;
          case "wrong CA rejected" wrong_ca;
          case "wrong hostname rejected" wrong_name;
          case "trusted RSA issuer" rsa_trusted;
          case "RSA certificate signature zero rejected" (rsa_rejected Rsa_zero);
          case "RSA certificate signature one rejected" (rsa_rejected Rsa_one);
          Alcotest.test_case "TLS rejection excludes other failures" `Quick
            rejection_classifier;
          case "truncated fixed body rejected" truncated;
          case "malformed status rejected" malformed;
          case "redirect rejected" redirect;
          case "body bytes bounded" body_limit;
          case "response head bounded" header_limit;
          case "wire framing bounded" wire_limit;
          case "deadline closes socket" timeout;
          case "external cancellation closes socket" cancellation;
          case "clock defect identity and backtrace" defect;
          case "preexisting RNG is adopted unchanged" adoption;
          case "request preflight" preflight;
          Alcotest.test_case "checked constructors" `Quick constructors;
          case "close-delimited exact wire limit" wire_exact;
          case "close-delimited extra byte rejected" wire_excess;
          case "foreign RNG replacement precedes TLS" replacement;
        ] );
      ("registry runtime", Tracker_runtime_test.tests);
    ]
