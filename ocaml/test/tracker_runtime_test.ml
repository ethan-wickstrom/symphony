let tracker_checked = function
  | Ok value -> value
  | Error error ->
      Alcotest.fail (Diagnostic.render (Tracker_error.diagnostic error))

let text_checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let tls_path name =
  let directory = Sys.getenv "SYMPHONY_TEST_TLS_DIRECTORY" in
  if Filename.is_relative directory then
    Alcotest.fail "Shared TLS directory must be absolute";
  Filename.concat directory name

let fixture fs name = Eio.Path.load (Eio.Path.( / ) fs (tls_path name))

let tls_server fs =
  let chain =
    match X509.Certificate.decode_pem_multiple (fixture fs "server.pem") with
    | Ok value -> value
    | Error (`Msg message) -> Alcotest.fail message
  in
  let key =
    match X509.Private_key.decode_pem (fixture fs "server.key") with
    | Ok value -> value
    | Error (`Msg message) -> Alcotest.fail message
  in
  match
    Tls.Config.server
      ~certificates:(`Single (chain, key))
      ~version:(`TLS_1_2, `TLS_1_3) ~alpn_protocols:[ "http/1.1" ] ()
  with
  | Ok value -> value
  | Error (`Msg message) -> Alcotest.fail message

let header_boundary bytes =
  let rec scan offset =
    if offset + 4 > String.length bytes then None
    else if String.sub bytes offset 4 = "\r\n\r\n" then Some (offset + 4)
    else scan (offset + 1)
  in
  scan 0

let content_length headers =
  let field = "content-length:" in
  let lengths =
    String.split_on_char '\n' headers
    |> List.filter_map (fun line ->
        let lower = String.lowercase_ascii line in
        if not (String.starts_with ~prefix:field lower) then None
        else
          let value =
            String.sub line (String.length field)
              (String.length line - String.length field)
            |> String.trim
          in
          Some (int_of_string_opt value))
  in
  match lengths with
  | [ Some length ] when length >= 0 && length <= 65536 -> length
  | _ -> Alcotest.fail "fixture request has no bounded content length"

let receive flow =
  let bound = 131072 in
  let scratch = Cstruct.create 4096 in
  let captured = Buffer.create 4096 in
  let rec read () =
    let bytes = Buffer.contents captured in
    match header_boundary bytes with
    | Some start when String.length bytes >= start + content_length bytes -> ()
    | Some _ | None ->
        let count = Eio.Flow.single_read flow scratch in
        if count > bound - Buffer.length captured then
          Alcotest.fail "fixture request capture exceeded bound";
        Buffer.add_string captured (Cstruct.to_string ~len:count scratch);
        read ()
  in
  read ()

type page = Continuation | Final

let reply flow ~page =
  let body =
    match page with
    | Continuation ->
        {|{"data":{"issues":{"nodes":[{"id":"runtime-A","identifier":"RUN-1","title":"First","state":{"name":"Todo"},"project":{"slugId":"sample"},"labels":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}},"inverseRelations":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}],"pageInfo":{"hasNextPage":true,"endCursor":"after-A"}}}}|}
    | Final ->
        {|{"data":{"issues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}|}
  in
  let wire =
    Printf.sprintf
      "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
      (String.length body) body
  in
  Eio.Flow.write flow [ Cstruct.of_string wire ]

let configuration registry ~base ~endpoint =
  let file = text_checked (Workflow_path.resolve ~base "WORKFLOW.md") in
  let source =
    Printf.sprintf
      "---\n\
       tracker:\n\
      \  kind: linear\n\
      \  active_states: [Todo, Doing]\n\
      \  terminal_states: [Done]\n\
      \  provider:\n\
      \    endpoint: %s\n\
      \    project_slug: sample\n\
      \    api_key: runtime-fixture-token\n\
       ---\n"
      endpoint
  in
  let document =
    match Workflow_document.parse ~file source with
    | Ok value -> value
    | Error
        ( Workflow_document.Parse_error diagnostic
        | Workflow_document.Front_matter_not_map diagnostic ) ->
        Alcotest.fail (Diagnostic.render diagnostic)
  in
  let env =
    text_checked
      (Environment.of_bindings
         ~temp_dir:(text_checked (Absolute_path.parse "/tmp"))
         [])
  in
  match Tracker_runtime.Config.resolve registry ~env ~document with
  | Ok value -> value
  | Error (Config_layer.Tracker error) -> tracker_checked (Error error)
  | Error (Config_layer.Fields diagnostics) ->
      Alcotest.fail
        (String.concat "\n"
           (List.map Diagnostic.render (Nonempty_list.to_list diagnostics)))
  | Error (Config_layer.Workflow _) -> Alcotest.fail "fixture workflow rejected"

let overlapping () =
  Eio_posix.run (fun host ->
      let base = text_checked (Absolute_path.parse (Sys.getcwd ())) in
      let net = Eio.Stdenv.net host in
      let runtime = Native_http.defer () in
      let mono = Eio.Stdenv.mono_clock host in
      let clock = Clock_posix.create ~mono ~wall:(Eio.Stdenv.clock host) in
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock host) 5.0 (fun () ->
          Eio.Switch.run (fun sw ->
              let listener =
                Eio.Net.listen ~sw ~backlog:4 net
                  (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
              in
              let endpoint =
                match Eio.Net.listening_addr listener with
                | `Tcp (_, port) ->
                    Printf.sprintf "https://localhost:%d/graphql" port
                | `Unix _ -> Alcotest.fail "fixture requires TCP"
              in
              let registry =
                tracker_checked
                  (Tracker_runtime.registry ~runtime ~fs:(Eio.Stdenv.fs host)
                     ~net ~clock ~cwd:base ~ca_bundle:(tls_path "ca.pem")
                     ~warning:ignore)
              in
              let config = configuration registry ~base ~endpoint in
              let binding = Tracker_runtime.Config.tracker config in
              let policy =
                Tracker_read_policy.of_scheduling
                  (Tracker_runtime.Config.scheduling config)
              in
              let first_started, start_first = Eio.Promise.create () in
              let second_done, finish_second = Eio.Promise.create () in
              let calls = ref 0 in
              Eio.Fiber.fork_daemon ~sw (fun () ->
                  let rec accept () =
                    let socket, _ = Eio.Net.accept ~sw listener in
                    incr calls;
                    let ordinal = !calls in
                    Eio.Fiber.fork ~sw (fun () ->
                        let flow =
                          Tls_eio.server_of_flow
                            (tls_server (Eio.Stdenv.fs host))
                            socket
                        in
                        receive flow;
                        if ordinal = 1 then (
                          Eio.Promise.resolve start_first ();
                          Eio.Promise.await second_done);
                        reply flow
                          ~page:(if ordinal = 1 then Continuation else Final);
                        Eio.Resource.close flow);
                    accept ()
                  in
                  accept ());
              let first = ref None in
              let second = ref None in
              Eio.Fiber.both
                (fun () ->
                  first :=
                    Some (Tracker_registry.states binding ~policy [ "Todo" ]))
                (fun () ->
                  Eio.Promise.await first_started;
                  second :=
                    Some (Tracker_registry.states binding ~policy [ "Doing" ]);
                  Eio.Promise.resolve finish_second ());
              let complete label expected = function
                | Some (Ok batch) ->
                    Alcotest.(check int)
                      label expected
                      (List.length (Issue_batch.ordered batch))
                | Some (Error error) ->
                    Alcotest.fail
                      (label ^ ": "
                      ^ Diagnostic.render (Tracker_error.diagnostic error))
                | None -> Alcotest.fail (label ^ " was never completed")
              in
              complete "first paginated read" 1 !first;
              complete "second overlapping read" 0 !second;
              Alcotest.(check int) "all pages reached the server" 3 !calls)))

let current () =
  match Mirage_crypto_rng.default_generator () with
  | value -> Some value
  | exception Mirage_crypto_rng.No_default_generator -> None

let offline () =
  let before = current () in
  let runtime = Native_http.defer () in
  Eio_posix.run (fun host ->
      let base = text_checked (Absolute_path.parse (Sys.getcwd ())) in
      let clock =
        Clock_posix.create
          ~mono:(Eio.Stdenv.mono_clock host)
          ~wall:(Eio.Stdenv.clock host)
      in
      let registry =
        tracker_checked
          (Tracker_runtime.registry ~runtime ~fs:(Eio.Stdenv.fs host)
             ~net:(Eio.Stdenv.net host) ~clock ~cwd:base
             ~ca_bundle:"fixtures/tls/does-not-exist.pem" ~warning:ignore)
      in
      let config =
        configuration registry ~base ~endpoint:"https://localhost:1/graphql"
      in
      let policy =
        Tracker_read_policy.of_scheduling
          (Tracker_runtime.Config.scheduling config)
      in
      let batch =
        tracker_checked
          (Tracker_registry.states
             (Tracker_runtime.Config.tracker config)
             ~policy [])
      in
      Alcotest.(check int)
        "empty read ignores missing trust bundle" 0
        (List.length (Issue_batch.ordered batch)));
  let unchanged =
    match (before, current ()) with
    | None, None -> true
    | Some before, Some after -> before == after
    | None, Some _ | Some _, None -> false
  in
  Alcotest.(check bool)
    "offline assembly does not initialize crypto" true unchanged

let tests =
  [
    Alcotest.test_case "offline capture and empty read" `Quick offline;
    Alcotest.test_case "overlapping registry reads" `Quick overlapping;
  ]
