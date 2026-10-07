module Server = Native_status.Make (Clock_posix)

module Controlled_clock = struct
  module Pure = Clock.Pure

  type t = {
    now_ : unit -> (Pure.instant, Diagnostic.t) result;
    wait : Pure.instant -> (unit, Diagnostic.t) result;
  }

  let now clock = clock.now_ ()
  let sleep_until clock due = clock.wait due
  let sample _ = Alcotest.fail "The HTTP deadline must not sample wall time"
end

module Controlled = Native_status.Make (Controlled_clock)

type 'a outcome = Returned of 'a | Raised of exn * Printexc.raw_backtrace
type wire = Response of string | Closed
type listen_fixture = { setup : exn; cleanup : exn; released : int ref }

module Fixture_network :
  Eio.Net.Pi.NETWORK with type t = listen_fixture and type tag = [ `Generic ] =
struct
  type t = listen_fixture
  type tag = [ `Generic ]

  let listen fixture ~reuse_addr:_ ~reuse_port:_ ~backlog:_ ~sw _ =
    Eio.Switch.on_release sw (fun () ->
        incr fixture.released;
        raise fixture.cleanup);
    raise fixture.setup

  let connect _ ~bind_to:_ ~options:_ ~sw:_ _ =
    Alcotest.fail "Setup failure cannot connect"

  let datagram_socket _ ~reuse_addr:_ ~reuse_port:_ ~sw:_ _ =
    Alcotest.fail "Setup failure cannot open a datagram socket"

  let getaddrinfo _ ~service:_ _ =
    Alcotest.fail "Setup failure cannot resolve names"

  let getnameinfo _ _ = Alcotest.fail "Setup failure cannot inspect a peer"
end

let capture action =
  try Returned (action ())
  with error -> Raised (error, Printexc.get_raw_backtrace ())

let port value =
  match Http_port.parse (string_of_int value) with
  | Ok value -> value
  | Error message -> Alcotest.fail message

let ensure label condition = Alcotest.check Alcotest.bool label true condition

let success = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Diagnostic.render error)

let echo request =
  {
    Http_message.status = 200;
    content_type = "text/plain";
    allow = [];
    body = request.Http_message.path ^ "|" ^ request.Http_message.body;
  }

let clock env =
  Clock_posix.create
    ~mono:(Eio.Stdenv.mono_clock env)
    ~wall:(Eio.Stdenv.clock env)

let connect env sw port =
  Eio.Net.connect ~sw (Eio.Stdenv.net env)
    (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))

let read_wire socket =
  let buffer = Cstruct.create 4096 in
  let output = Buffer.create 128 in
  let rec read () =
    match Eio.Flow.single_read socket buffer with
    | count ->
        Buffer.add_string output (Cstruct.to_string ~len:count buffer);
        read ()
    | exception End_of_file -> Buffer.contents output
  in
  read ()

let request env bound chunks =
  try
    Eio.Switch.run (fun sw ->
        let socket = connect env sw bound in
        List.iter (fun chunk -> Eio.Flow.copy_string chunk socket) chunks;
        Response (read_wire socket))
  with
  | Unix.Unix_error ((Unix.ECONNRESET | Unix.EPIPE), _, _)
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _)
  ->
    Closed

let status expected = function
  | Closed -> Alcotest.fail "Expected a complete HTTP response"
  | Response bytes ->
      ensure "HTTP status"
        (String.starts_with
           ~prefix:(Printf.sprintf "HTTP/1.1 %d " expected)
           bytes)

let body expected = function
  | Closed -> Alcotest.fail "Expected a complete HTTP response"
  | Response bytes ->
      ensure "HTTP body" (String.ends_with ~suffix:expected bytes)

let authority bound = "localhost:" ^ string_of_int bound

let get bound path =
  "GET " ^ path ^ " HTTP/1.1\r\nHost: " ^ authority bound ^ "\r\n\r\n"

let with_server env handler use =
  let bound = ref None in
  Server.with_server ~net:(Eio.Stdenv.net env) ~clock:(clock env) ~port:(port 0)
    ~ready:(fun value -> bound := Some value)
    ~handler
    (fun () ->
      match !bound with
      | None -> Alcotest.fail "Service entered before listener readiness"
      | Some bound ->
          use bound;
          Ok ())
  |> success

let fragmentation () =
  Eio_posix.run (fun env ->
      let observations = ref [] in
      let handler request =
        observations := request :: !observations;
        echo request
      in
      with_server env handler (fun bound ->
          let wire = get bound "/api/v1/ISSUE-1" in
          let chunks =
            [
              [ wire ];
              List.of_seq (Seq.map (String.make 1) (String.to_seq wire));
              [
                "GET /api/v1/ISSUE-1 HTTP/1.1\r";
                "\nHost: " ^ authority bound ^ "\r\n\r";
                "\n";
              ];
            ]
          in
          List.iter
            (fun chunks ->
              let response = request env bound chunks in
              status 200 response;
              body "/api/v1/ISSUE-1|" response)
            chunks);
      Alcotest.check Alcotest.int "one request per connection" 3
        (List.length !observations))

let chunked_body () =
  Eio_posix.run (fun env ->
      with_server env
        (fun request ->
          ensure "POST method" (request.Http_message.method_ = Http_message.Post);
          echo request)
        (fun bound ->
          let wire =
            "POST /api/v1/refresh HTTP/1.1\r\nHost: " ^ authority bound
            ^ "\r\n\
               Transfer-Encoding: chunked\r\n\
               \r\n\
               1\r\n\
               {\r\n\
               1\r\n\
               }\r\n\
               0\r\n\
               \r\n"
          in
          let response =
            request env bound
              (List.of_seq (Seq.map (String.make 1) (String.to_seq wire)))
          in
          status 200 response;
          body "/api/v1/refresh|{}" response))

let path_boundary () =
  Eio_posix.run (fun env ->
      let entered = ref 0 in
      with_server env
        (fun req ->
          incr entered;
          echo req)
        (fun bound ->
          List.iter
            (fun path -> status 400 (request env bound [ get bound path ]))
            [
              "/bad%";
              "/bad%0";
              "/bad%GG";
              "/bad%2fseparator";
              "/bad%00";
              "/bad%0a";
              "/bad%7f";
              "/bad%ff";
              "/api/v1/state?query=x";
              "/api/v1/state#fragment";
            ];
          let once = request env bound [ get bound "/api/v1/ISSUE%252f1" ] in
          status 200 once;
          body "/api/v1/ISSUE%2f1|" once;
          let unicode = request env bound [ get bound "/api/v1/%C3%89-1" ] in
          status 200 unicode;
          body "/api/v1/É-1|" unicode);
      Alcotest.check Alcotest.int "rejected path never enters handler" 2
        !entered)

let malformed_http () =
  Eio_posix.run (fun env ->
      let entered = ref 0 in
      with_server env
        (fun req ->
          incr entered;
          echo req)
        (fun bound ->
          status 400
            (request env bound [ "GET / HTTP/1.1\r\nbroken header\r\n\r\n" ]);
          status 400
            (request env bound
               [
                 "POST / HTTP/1.1\r\nHost: " ^ authority bound
                 ^ "\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n{}";
               ]);
          status 200 (request env bound [ get bound "/healthy" ]));
      Alcotest.check Alcotest.int "parser rejection is client-local" 1 !entered)

let body_limits () =
  Eio_posix.run (fun env ->
      let entered = ref 0 in
      with_server env
        (fun req ->
          incr entered;
          echo req)
        (fun bound ->
          status 413
            (request env bound
               [
                 "POST / HTTP/1.1\r\nHost: " ^ authority bound
                 ^ "\r\nContent-Length: 65537\r\n\r\n";
               ]);
          let large = String.make 65537 'x' in
          status 413
            (request env bound
               [
                 "POST / HTTP/1.1\r\nHost: " ^ authority bound
                 ^ "\r\nTransfer-Encoding: chunked\r\n\r\n10001\r\n";
                 large;
                 "\r\n0\r\n\r\n";
               ]);
          status 200 (request env bound [ get bound "/healthy" ]));
      Alcotest.check Alcotest.int "oversized body never enters handler" 1
        !entered)

let wire_limit () =
  Eio_posix.run (fun env ->
      let entered = ref 0 in
      with_server env
        (fun req ->
          incr entered;
          echo req)
        (fun bound ->
          let chunks =
            String.concat "" (List.init 17000 (fun _ -> "1\r\nx\r\n"))
          in
          let response =
            request env bound
              [
                "POST / HTTP/1.1\r\nHost: " ^ authority bound
                ^ "\r\nTransfer-Encoding: chunked\r\n\r\n";
                chunks;
                "0\r\n\r\n";
              ]
          in
          (match response with
          | Closed -> ()
          | Response bytes ->
              ensure "chunk overhead counts against wire cap"
                (not (String.starts_with ~prefix:"HTTP/1.1 200 " bytes)));
          status 200 (request env bound [ get bound "/healthy" ]));
      Alcotest.check Alcotest.int "wire cap precedes application handler" 1
        !entered)

let header_limit () =
  Eio_posix.run (fun env ->
      let entered = ref 0 in
      with_server env
        (fun req ->
          incr entered;
          echo req)
        (fun bound ->
          let large =
            "GET / HTTP/1.1\r\nHost: " ^ authority bound ^ "\r\nX-Large: "
            ^ String.make (17 * 1024) 'x'
            ^ "\r\n\r\n"
          in
          (match request env bound [ large ] with
          | Closed -> ()
          | Response bytes ->
              ensure "oversized header is not accepted"
                (not (String.starts_with ~prefix:"HTTP/1.1 200 " bytes)));
          status 200 (request env bound [ get bound "/healthy" ]));
      Alcotest.check Alcotest.int "header cap is client-local" 1 !entered)

let bind_failure () =
  Eio_posix.run (fun env ->
      Eio.Switch.run (fun sw ->
          let listener =
            Eio.Net.listen ~sw ~backlog:1 (Eio.Stdenv.net env)
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let bound =
            match Eio.Net.listening_addr listener with
            | `Tcp (_, value) -> value
            | `Unix _ -> Alcotest.fail "Expected TCP listener"
          in
          let entered = ref 0 in
          let ready = ref 0 in
          let outcome =
            Server.with_server ~net:(Eio.Stdenv.net env) ~clock:(clock env)
              ~port:(port bound)
              ~ready:(fun _ -> incr ready)
              ~handler:echo
              (fun () ->
                incr entered;
                Ok ())
          in
          (match outcome with
          | Ok () -> Alcotest.fail "Occupied port accepted"
          | Error _ -> ());
          Alcotest.check Alcotest.int "callback entries" 0 !entered;
          Alcotest.check Alcotest.int "readiness entries" 0 !ready))

let refused env bound =
  match
    capture (fun () -> Eio.Switch.run (fun sw -> ignore (connect env sw bound)))
  with
  | Raised ((Unix.Unix_error _ | Eio.Io _), _) -> ()
  | Raised (error, trace) -> Printexc.raise_with_backtrace error trace
  | Returned () -> Alcotest.fail "Listener survived its scope"

let callback_error () =
  Eio_posix.run (fun env ->
      let primary =
        Diagnostic.make ~site:(Diagnostic.Host "fixture")
          ~message:"callback failure" ~remedy:"fixture"
      in
      let bound = ref None in
      let result =
        Server.with_server ~net:(Eio.Stdenv.net env) ~clock:(clock env)
          ~port:(port 0)
          ~ready:(fun value -> bound := Some value)
          ~handler:echo
          (fun () -> Error primary)
      in
      (match result with
      | Error error -> ensure "physical expected failure" (error == primary)
      | Ok () -> Alcotest.fail "Callback failure lost");
      Option.iter (refused env) !bound)

let check_fault original = function
  | Returned _ -> Alcotest.fail "Original defect did not escape"
  | Raised (error, trace) ->
      ensure "physical exception" (error == original);
      ensure "original backtrace" (Printexc.raw_backtrace_length trace > 0)

let failing_listen env setup =
  let fixture =
    {
      setup;
      cleanup = Failure "native status listener release";
      released = ref 0;
    }
  in
  let net =
    Eio.Resource.T (fixture, Eio.Net.Pi.network (module Fixture_network))
  in
  let ready = ref 0 in
  let entered = ref 0 in
  let outcome =
    capture (fun () ->
        Server.with_server ~net ~clock:(clock env) ~port:(port 0)
          ~ready:(fun _ -> incr ready)
          ~handler:echo
          (fun () ->
            incr entered;
            Ok ()))
  in
  Alcotest.check Alcotest.int "release joined once" 1 !(fixture.released);
  Alcotest.check Alcotest.int "readiness entries" 0 !ready;
  Alcotest.check Alcotest.int "callback entries" 0 !entered;
  outcome

let bind_cleanup_error () =
  Eio_posix.run (fun env ->
      let original =
        Unix.Unix_error (Unix.EADDRINUSE, "listen", "private fixture")
      in
      match failing_listen env original with
      | Returned (Error error) ->
          let expected =
            Diagnostic.make ~site:(Diagnostic.Host "status_http")
              ~message:"HTTP status listener could not bind."
              ~remedy:
                "Check the configured HTTP port and host network resources."
          in
          Alcotest.check Alcotest.string "bind diagnostic survives release"
            (Diagnostic.render expected)
            (Diagnostic.render error)
      | Returned (Ok ()) -> Alcotest.fail "Expected bind error lost"
      | Raised (error, trace) -> Printexc.raise_with_backtrace error trace)

let bind_cleanup_defect () =
  Printexc.record_backtrace true;
  Eio_posix.run (fun env ->
      let original = Sys_error "native status listener setup" in
      check_fault original (failing_listen env original))

let callback_defect () =
  Printexc.record_backtrace true;
  Eio_posix.run (fun env ->
      let original = Failure "native status callback" in
      let bound = ref None in
      let result =
        capture (fun () ->
            Server.with_server ~net:(Eio.Stdenv.net env) ~clock:(clock env)
              ~port:(port 0)
              ~ready:(fun value -> bound := Some value)
              ~handler:echo
              (fun () -> raise original))
      in
      check_fault original result;
      Option.iter (refused env) !bound)

let handler_defect () =
  Printexc.record_backtrace true;
  Eio_posix.run (fun env ->
      Eio.Switch.run (fun sw ->
          let original = Sys_error "native status handler defect" in
          let bound = ref None in
          let result =
            capture (fun () ->
                Server.with_server ~net:(Eio.Stdenv.net env) ~clock:(clock env)
                  ~port:(port 0)
                  ~ready:(fun value -> bound := Some value)
                  ~handler:(fun _ -> raise original)
                  (fun () ->
                    let value =
                      match !bound with
                      | Some value -> value
                      | None -> Alcotest.fail "Not ready"
                    in
                    Eio.Fiber.fork ~sw (fun () ->
                        ignore (request env value [ get value "/fault" ]));
                    Eio.Promise.await (fst (Eio.Promise.create ()))))
          in
          check_fault original result;
          Option.iter (refused env) !bound))

let response_defect () =
  Eio_posix.run (fun env ->
      Eio.Switch.run (fun sw ->
          let result =
            capture (fun () ->
                let bound = ref None in
                Server.with_server ~net:(Eio.Stdenv.net env) ~clock:(clock env)
                  ~port:(port 0)
                  ~ready:(fun value -> bound := Some value)
                  ~handler:(fun _ ->
                    {
                      Http_message.status = 200;
                      content_type = "text/plain\r\nX-Injected: yes";
                      body = "";
                      allow = [];
                    })
                  (fun () ->
                    let value =
                      match !bound with
                      | Some value -> value
                      | None -> Alcotest.fail "Not ready"
                    in
                    Eio.Fiber.fork ~sw (fun () ->
                        ignore (request env value [ get value "/fault" ]));
                    Eio.Promise.await (fst (Eio.Promise.create ()))))
          in
          match result with
          | Raised (Invalid_argument _, _) -> ()
          | Raised (error, trace) -> Printexc.raise_with_backtrace error trace
          | Returned _ -> Alcotest.fail "Header injection was accepted"))

let held_shutdown () =
  Eio_posix.run (fun env ->
      Eio.Switch.run (fun sw ->
          let now = ref (success (Clock_posix.now (clock env))) in
          let waiting, waiting_resolve = Eio.Promise.create () in
          let advance, advance_resolve = Eio.Promise.create () in
          let controlled =
            {
              Controlled_clock.now_ = (fun () -> Ok !now);
              wait =
                (fun due ->
                  Eio.Promise.resolve waiting_resolve ();
                  Eio.Promise.await advance;
                  now := due;
                  Ok ());
            }
          in
          let socket = ref None in
          let bound = ref None in
          let returned = ref false in
          let entered = ref 0 in
          let result =
            Controlled.with_server ~net:(Eio.Stdenv.net env) ~clock:controlled
              ~port:(port 0)
              ~ready:(fun value -> bound := Some value)
              ~handler:(fun req ->
                incr entered;
                echo req)
              (fun () ->
                let value =
                  match !bound with
                  | Some value -> value
                  | None -> Alcotest.fail "Not ready"
                in
                let peer = connect env sw value in
                socket := Some peer;
                Eio.Flow.copy_string "GET / HTTP/1.1\r\nHost:" peer;
                Eio.Promise.await waiting;
                Eio.Fiber.fork ~sw (fun () ->
                    Eio.Fiber.yield ();
                    ensure "callback returned before client deadline" !returned;
                    Eio.Promise.resolve advance_resolve ());
                returned := true;
                Ok ())
          in
          success result;
          Alcotest.check Alcotest.int "partial request never reaches handler" 0
            !entered;
          Option.iter
            (fun peer ->
              Alcotest.check Alcotest.string "joined peer EOF" ""
                (read_wire peer))
            !socket;
          Option.iter (refused env) !bound))

let owner_query () =
  Eio_posix.run (fun env ->
      Eio.Switch.run (fun sw ->
          let queried, queried_resolve = Eio.Promise.create () in
          let reply, reply_resolve = Eio.Promise.create () in
          let observed = ref None in
          with_server env
            (fun req ->
              Eio.Promise.resolve queried_resolve ();
              Eio.Promise.await reply;
              echo req)
            (fun bound ->
              let done_, resolve = Eio.Promise.create () in
              Eio.Fiber.fork ~sw (fun () ->
                  observed :=
                    Some (request env bound [ get bound "/owner-query" ]);
                  Eio.Promise.resolve resolve ());
              Eio.Promise.await queried;
              ensure "request awaits owner query" (!observed = None);
              Eio.Promise.resolve reply_resolve ();
              Eio.Promise.await done_);
          match !observed with
          | None -> Alcotest.fail "Owner reply did not complete"
          | Some response ->
              status 200 response;
              body "/owner-query|" response))

let concurrency_limit () =
  Eio_posix.run (fun env ->
      Eio.Switch.run (fun sw ->
          let limit = 64 in
          let entered = ref 0 in
          let sent = ref 0 in
          let completed = ref 0 in
          let full, full_resolve = Eio.Promise.create () in
          let all_sent, sent_resolve = Eio.Promise.create () in
          let release, release_resolve = Eio.Promise.create () in
          let all_done, done_resolve = Eio.Promise.create () in
          with_server env
            (fun req ->
              incr entered;
              if !entered = limit then Eio.Promise.resolve full_resolve ();
              Eio.Promise.await release;
              echo req)
            (fun bound ->
              List.iter
                (fun _ ->
                  Eio.Fiber.fork ~sw (fun () ->
                      Eio.Switch.run (fun client_sw ->
                          let socket = connect env client_sw bound in
                          Eio.Flow.copy_string (get bound "/capacity") socket;
                          incr sent;
                          if !sent = limit + 1 then
                            Eio.Promise.resolve sent_resolve ();
                          status 200 (Response (read_wire socket));
                          incr completed;
                          if !completed = limit + 1 then
                            Eio.Promise.resolve done_resolve ())))
                (List.init (limit + 1) Fun.id);
              Eio.Promise.await all_sent;
              Eio.Promise.await full;
              Alcotest.check Alcotest.int "admitted handler capacity" limit
                !entered;
              Alcotest.check Alcotest.int "held handlers have not completed" 0
                !completed;
              Eio.Promise.resolve release_resolve ();
              Eio.Promise.await all_done);
          Alcotest.check Alcotest.int "all queued clients finish" (limit + 1)
            !completed))

let external_cancel () =
  Eio_posix.run (fun env ->
      Eio.Switch.run (fun sw ->
          let original = Failure "native status external cancellation" in
          let entered, entered_resolve = Eio.Promise.create () in
          let completed, completed_resolve = Eio.Promise.create () in
          let timer, timer_resolve = Eio.Promise.create () in
          let cancel = ref None in
          let bound = ref None in
          let socket = ref None in
          let controlled =
            {
              Controlled_clock.now_ = (fun () -> Clock_posix.now (clock env));
              wait =
                (fun _ ->
                  Eio.Promise.resolve timer_resolve ();
                  Eio.Promise.await (fst (Eio.Promise.create ())));
            }
          in
          Eio.Fiber.fork ~sw (fun () ->
              let outcome =
                capture (fun () ->
                    Eio.Cancel.sub (fun context ->
                        cancel := Some context;
                        Controlled.with_server ~net:(Eio.Stdenv.net env)
                          ~clock:controlled ~port:(port 0)
                          ~ready:(fun value -> bound := Some value)
                          ~handler:echo
                          (fun () ->
                            let value =
                              match !bound with
                              | Some value -> value
                              | None -> Alcotest.fail "Not ready"
                            in
                            let peer = connect env sw value in
                            socket := Some peer;
                            Eio.Flow.copy_string "GET / HTTP/1.1\r\nHost:" peer;
                            Eio.Promise.await timer;
                            Eio.Promise.resolve entered_resolve ();
                            Eio.Promise.await (fst (Eio.Promise.create ())))))
              in
              Eio.Promise.resolve completed_resolve outcome);
          Eio.Promise.await entered;
          (match !cancel with
          | None -> Alcotest.fail "No cancellation context"
          | Some context -> Eio.Cancel.cancel context original);
          (match Eio.Promise.await completed with
          | Raised (Eio.Cancel.Cancelled reason, _) ->
              ensure "original cancellation reason" (reason == original)
          | Raised (error, trace) -> Printexc.raise_with_backtrace error trace
          | Returned _ -> Alcotest.fail "Cancellation was lost");
          Option.iter
            (fun peer ->
              (* Cancellation closes unread TCP input; both EOF and reset prove closure. *)
              try
                Alcotest.check Alcotest.string "canceled peer EOF" ""
                  (read_wire peer)
              with
              | Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _)
              | Unix.Unix_error (Unix.ECONNRESET, _, _)
              ->
                ())
            !socket;
          Option.iter (refused env) !bound))

let clock_failure () =
  Eio_posix.run (fun env ->
      Eio.Switch.run (fun sw ->
          let error =
            Diagnostic.make ~site:(Diagnostic.Host "fixture clock")
              ~message:"secret fixture clock payload" ~remedy:"fixture"
          in
          let controlled =
            {
              Controlled_clock.now_ = (fun () -> Error error);
              wait = (fun _ -> Alcotest.fail "Failed clock must not schedule");
            }
          in
          let bound = ref None in
          let result =
            Controlled.with_server ~net:(Eio.Stdenv.net env) ~clock:controlled
              ~port:(port 0)
              ~ready:(fun value -> bound := Some value)
              ~handler:echo
              (fun () ->
                let value =
                  match !bound with
                  | Some value -> value
                  | None -> Alcotest.fail "Not ready"
                in
                Eio.Fiber.fork ~sw (fun () ->
                    ignore (request env value [ get value "/clock" ]));
                Eio.Promise.await (fst (Eio.Promise.create ())))
          in
          (match result with
          | Ok () -> Alcotest.fail "Clock failure was lost"
          | Error diagnostic ->
              ensure "clock diagnostic is host-specific"
                (Diagnostic.site diagnostic = Diagnostic.Host "status_http");
              ensure "raw clock diagnostic is not retained" (diagnostic != error));
          Option.iter (refused env) !bound))

let unrequested_cancellation () =
  Printexc.record_backtrace true;
  Eio_posix.run (fun env ->
      Eio.Switch.run (fun sw ->
          let original =
            Eio.Cancel.Cancelled
              (Failure "unrequested HTTP handler cancellation")
          in
          let entered, entered_resolve = Eio.Promise.create () in
          let bound = ref None in
          let outcome =
            Eio.Fiber.first
              (fun () ->
                `Finished
                  (capture (fun () ->
                       Server.with_server ~net:(Eio.Stdenv.net env)
                         ~clock:(clock env) ~port:(port 0)
                         ~ready:(fun value -> bound := Some value)
                         ~handler:(fun _ ->
                           Eio.Promise.resolve entered_resolve ();
                           raise original)
                         (fun () ->
                           let value =
                             match !bound with
                             | Some value -> value
                             | None -> Alcotest.fail "Not ready"
                           in
                           Eio.Fiber.fork ~sw (fun () ->
                               ignore
                                 (request env value
                                    [ get value "/unrequested-cancel" ]));
                           Eio.Promise.await (fst (Eio.Promise.create ()))))))
              (fun () ->
                Eio.Promise.await entered;
                Eio.Time.sleep (Eio.Stdenv.clock env) 0.1;
                `Parked)
          in
          (match outcome with
          | `Finished result -> check_fault original result
          | `Parked ->
              Alcotest.fail
                "Unrequested handler cancellation stopped admission but left \
                 the callback parked");
          Option.iter (refused env) !bound))

let pipelining () =
  Eio_posix.run (fun env ->
      let observations = ref [] in
      with_server env
        (fun req ->
          observations := req.Http_message.path :: !observations;
          echo req)
        (fun bound ->
          let response =
            request env bound [ get bound "/first" ^ get bound "/second" ]
          in
          status 200 response;
          body "/first|" response);
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "single request authority" [ "/first" ] !observations)

let malformed_body () =
  Eio_posix.run (fun env ->
      let entered = ref 0 in
      with_server env
        (fun req ->
          incr entered;
          echo req)
        (fun bound ->
          List.iter
            (fun framing ->
              let before = !entered in
              let response =
                request env bound
                  [
                    "POST /api/v1/refresh HTTP/1.1\r\nHost: " ^ authority bound
                    ^ "\r\nTransfer-Encoding: chunked\r\n\r\n" ^ framing;
                  ]
              in
              Alcotest.check Alcotest.int
                ("malformed body has zero handler authority: "
               ^ String.escaped framing)
                before !entered;
              (match response with
              | Closed -> ()
              | Response _ -> status 400 response);
              status 200 (request env bound [ get bound "/healthy" ]))
            [
              "GG\r\nx\r\n0\r\n\r\n";
              "1\r\nx!\r\n0\r\n\r\n";
              "0\r\nmalformed trailer\r\n\r\n";
            ]))

type fuzz_oracle =
  | Accept of string * string
  | Reject of int list
  | Budget_close of int list

type fuzz_input = { wire : string; oracle : fuzz_oracle }

let fuzz_seed = 0x53594d50
let fuzz_cases = 256
let fuzz_body_limit = 64 * 1024
let fuzz_wire_limit = 96 * 1024

let chunk_wire bound path body =
  let chunks = Buffer.create (String.length body * 6) in
  String.iter
    (fun c -> Buffer.add_string chunks ("1\r\n" ^ String.make 1 c ^ "\r\n"))
    body;
  "POST " ^ path ^ " HTTP/1.1\r\nHost: " ^ authority bound
  ^ "\r\nTransfer-Encoding: chunked\r\n\r\n" ^ Buffer.contents chunks
  ^ "0\r\n\r\n"

let fuzz_input bound state index =
  let pick choices =
    List.nth_opt choices (Random.State.int state (List.length choices))
    |> function
    | Some value -> value
    | None -> Alcotest.fail "Nonempty fuzz corpus"
  in
  match index mod 8 with
  | 0 ->
      (* Construct encoded/decoded pairs independently of the driver decoder. *)
      let encoded, decoded =
        pick
          [
            ("ISSUE-42", "ISSUE-42");
            ("space%20label", "space label");
            ("percent%25value", "percent%value");
            ("double%252f", "double%2f");
            ("%C3%89-%CE%BB", "É-λ");
            ("x%2By", "x+y");
            ("%E2%82%AC", "€");
          ]
      in
      {
        wire = get bound ("/api/v1/" ^ encoded);
        oracle = Accept ("/api/v1/" ^ decoded, "");
      }
  | 1 ->
      let path =
        pick
          [
            "/bad%";
            "/bad%0";
            "/bad%aZ";
            "/bad%GG";
            "/bad%2F";
            "/bad%00";
            "/bad%0D";
            "/bad%7F";
            "/bad%C0%AF";
            "/bad%ED%A0%80";
            "/bad%F4%90%80%80";
            "/bad%80";
            "/api/v1/state?x=1";
            "/api/v1/state#x";
          ]
      in
      { wire = get bound path; oracle = Reject [ 400 ] }
  | 2 ->
      {
        wire =
          pick
            [
              "GET / HTTP/1.1\r\nbroken header\r\n\r\n";
              "POST / HTTP/1.1\r\nHost: " ^ authority bound
              ^ "\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n{}";
            ];
        oracle = Reject [ 400 ];
      }
  | 3 ->
      let body =
        String.init
          (1 + Random.State.int state 32)
          (fun _ -> Char.chr (Char.code 'a' + Random.State.int state 26))
      in
      {
        wire = chunk_wire bound "/chunked" body;
        oracle = Accept ("/chunked", body);
      }
  | 4 ->
      let length = fuzz_body_limit - 1 + Random.State.int state 3 in
      let body = String.make length 'b' in
      let wire =
        "POST /fixed HTTP/1.1\r\nHost: " ^ authority bound
        ^ "\r\nContent-Length: " ^ string_of_int length ^ "\r\n\r\n" ^ body
      in
      {
        wire;
        oracle =
          (if length > fuzz_body_limit then Reject [ 413 ]
           else Accept ("/fixed", body));
      }
  | 5 ->
      let body = String.make (16200 + Random.State.int state 400) 'w' in
      let wire = chunk_wire bound "/wire" body in
      {
        wire;
        oracle =
          (if String.length wire > fuzz_wire_limit then
             Budget_close [ 400; 413 ]
           else Accept ("/wire", body));
      }
  | 6 ->
      {
        wire =
          "GET / HTTP/1.1\r\nHost: " ^ authority bound ^ "\r\nX-Large: "
          ^ String.make ((17 * 1024) + Random.State.int state 64) 'h'
          ^ "\r\n\r\n";
        oracle = Budget_close [ 400 ];
      }
  | 7 ->
      {
        wire =
          "POST /malformed-body HTTP/1.1\r\nHost: " ^ authority bound
          ^ "\r\nTransfer-Encoding: chunked\r\n\r\n"
          ^ pick
              [
                "GG\r\nx\r\n0\r\n\r\n";
                "1\r\nx!\r\n0\r\n\r\n";
                "0\r\nmalformed trailer\r\n\r\n";
              ];
        oracle = Reject [ 400 ];
      }
  | _ -> Alcotest.fail "Fuzz case selector is modulo eight"

let wire_hex wire =
  let output = Buffer.create (String.length wire * 2) in
  String.iter (fun c -> Printf.bprintf output "%02x" (Char.code c)) wire;
  Buffer.contents output

let framing_corpus () =
  Printexc.record_backtrace true;
  let state = Random.State.make [| fuzz_seed |] in
  Eio_posix.run (fun env ->
      let entered = ref 0 in
      with_server env
        (fun req ->
          incr entered;
          echo req)
        (fun bound ->
          for index = 0 to fuzz_cases - 1 do
            let input = fuzz_input bound state index in
            let before = !entered in
            let check () =
              let response = request env bound [ input.wire ] in
              (match input.oracle with
              | Accept (path, payload) ->
                  Alcotest.check Alcotest.int "exactly one valid handler"
                    (before + 1) !entered;
                  status 200 response;
                  body (path ^ "|" ^ payload) response
              | Reject statuses -> (
                  Alcotest.check Alcotest.int
                    "malformed peer has no handler authority" before !entered;
                  match response with
                  | Closed -> ()
                  | Response bytes ->
                      ensure "malformed peer is rejected"
                        (List.exists
                           (fun code ->
                             String.starts_with
                               ~prefix:(Printf.sprintf "HTTP/1.1 %d " code)
                               bytes)
                           statuses))
              | Budget_close statuses -> (
                  Alcotest.check Alcotest.int
                    "over-budget peer has no handler authority" before !entered;
                  match response with
                  | Closed | Response "" -> ()
                  | Response bytes ->
                      ensure "over-budget peer is rejected"
                        (List.exists
                           (fun code ->
                             String.starts_with
                               ~prefix:(Printf.sprintf "HTTP/1.1 %d " code)
                               bytes)
                           statuses)));
              let after = !entered in
              let healthy = request env bound [ get bound "/healthy" ] in
              status 200 healthy;
              body "/healthy|" healthy;
              Alcotest.check Alcotest.int
                "listener survives with single healthy handler" (after + 1)
                !entered
            in
            match capture check with
            | Returned () -> ()
            | Raised (error, trace) ->
                Format.eprintf "seed=%d case=%d wire_hex=%s@." fuzz_seed index
                  (wire_hex input.wire);
                Printexc.raise_with_backtrace error trace
          done))

let forbidden_status = 403

let browser_authority () =
  Eio_posix.run (fun env ->
      let entered = ref 0 in
      with_server env
        (fun req ->
          incr entered;
          echo req)
        (fun bound ->
          let local = "127.0.0.1:" ^ string_of_int bound in
          let hostname = "localhost:" ^ string_of_int bound in
          let wire headers =
            "POST /api/v1/refresh HTTP/1.1\r\n" ^ headers
            ^ "Content-Length: 0\r\n\r\n"
          in
          let host = "Host: " ^ local ^ "\r\n" in
          let rejected =
            [
              host ^ "Origin: https://foreign.example\r\n";
              host ^ "Origin: null\r\n";
              host ^ "Origin: \r\n";
              host ^ "Origin: http://" ^ local ^ "/\r\n";
              host ^ "Origin: http://" ^ local ^ ", https://foreign.example\r\n";
              host ^ "Origin: http://" ^ hostname ^ "\r\n";
              host ^ "Origin: http://127.0.0.1:1\r\n";
              host ^ "Origin: http://" ^ local ^ "\r\nOrigin: http://" ^ local
              ^ "\r\n";
              host ^ "Sec-Fetch-Site: cross-site\r\n";
              host ^ "Sec-Fetch-Site: same-site\r\n";
              host ^ "Sec-Fetch-Site: unknown\r\n";
              host ^ "Sec-Fetch-Site: same-origin, cross-site\r\n";
              host
              ^ "Sec-Fetch-Site: same-origin\r\nSec-Fetch-Site: same-origin\r\n";
              "Host: foreign.example:" ^ string_of_int bound ^ "\r\n";
              "Host: localhost.foreign.example:" ^ string_of_int bound ^ "\r\n";
              "Host: user@" ^ local ^ "\r\n";
              "Host: 127.0.0.1:1\r\n";
              "Host: localhost\r\n";
              host ^ host;
              "";
            ]
          in
          let responses =
            List.map
              (fun headers -> request env bound [ wire headers ])
              rejected
          in
          Alcotest.check Alcotest.int
            "foreign requests obtain no handler authority" 0 !entered;
          List.iter (status forbidden_status) responses;
          List.iter
            (fun headers -> status 200 (request env bound [ wire headers ]))
            [
              host;
              host ^ "Origin: http://" ^ local
              ^ "\r\nSec-Fetch-Site: same-origin\r\n";
              host ^ "Sec-Fetch-Site: none\r\n";
              "Host: " ^ hostname ^ "\r\nOrigin: http://" ^ hostname ^ "\r\n";
              "Host: LOCALHOST:" ^ string_of_int bound ^ "\r\n";
            ];
          Alcotest.check Alcotest.int "local clients remain usable" 5 !entered))

let tests =
  [
    Alcotest.test_case "actual H1 framing is independent of fragmentation"
      `Quick fragmentation;
    Alcotest.test_case "chunked body reaches the data-only handler" `Quick
      chunked_body;
    Alcotest.test_case "path decoding is strict and occurs once" `Quick
      path_boundary;
    Alcotest.test_case "malformed HTTP remains client-local" `Quick
      malformed_http;
    Alcotest.test_case "decoded body limits precede handler entry" `Quick
      body_limits;
    Alcotest.test_case "chunk overhead is bounded independently of body" `Quick
      wire_limit;
    Alcotest.test_case "header budget does not kill the host" `Quick
      header_limit;
    Alcotest.test_case "bind failure never starts the callback" `Quick
      bind_failure;
    Alcotest.test_case "bind error remains primary over listener release defect"
      `Quick bind_cleanup_error;
    Alcotest.test_case
      "listen defect remains original over listener release defect" `Quick
      bind_cleanup_defect;
    Alcotest.test_case "callback expected failure survives joined closure"
      `Quick callback_error;
    Alcotest.test_case "callback defect retains identity and backtrace" `Quick
      callback_defect;
    Alcotest.test_case "handler defect cancels callback and remains original"
      `Quick handler_defect;
    Alcotest.test_case "trusted response cannot inject headers" `Quick
      response_defect;
    Alcotest.test_case "callback return joins held partial request deadline"
      `Quick held_shutdown;
    Alcotest.test_case "suspending owner query returns through actual HTTP"
      `Quick owner_query;
    Alcotest.test_case "bounded concurrency holds queued sixty-fifth client"
      `Quick concurrency_limit;
    Alcotest.test_case "external cancellation joins listener and held peer"
      `Quick external_cancel;
    Alcotest.test_case "clock failure cancels callback with redacted diagnostic"
      `Quick clock_failure;
    Alcotest.test_case
      "unrequested handler cancellation cannot park the callback" `Quick
      unrequested_cancellation;
    Alcotest.test_case "pipelining cannot obtain a second handler invocation"
      `Quick pipelining;
    Alcotest.test_case "malformed chunk bodies have no handler authority" `Quick
      malformed_body;
    Alcotest.test_case "seeded public HTTP framing and path corpus" `Quick
      framing_corpus;
    Alcotest.test_case "browser origin and Host precede handler authority"
      `Quick browser_authority;
  ]
