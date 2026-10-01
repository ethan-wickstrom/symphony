let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let tracker_checked = function
  | Ok value -> value
  | Error error ->
      Alcotest.fail (Diagnostic.render (Tracker_error.diagnostic error))

let diagnostic message =
  Diagnostic.make ~site:(Diagnostic.Host "linear.fixture") ~message
    ~remedy:"repair fixture"

module Port = struct
  module Pure = Clock.Pure

  type t = {
    observe : unit -> (Pure.instant, Diagnostic.t) result;
    wait : Pure.instant -> (unit, Diagnostic.t) result;
  }

  let now clock = clock.observe ()
  let sleep_until clock due = clock.wait due
  let sample _ = Alcotest.fail "tracker sampled the wall clock"
end

module Native = Native_http.Make (Port)

module Http = struct
  type endpoint = Native.endpoint
  type credential = Native.credential
  type scheme = Native.scheme = Authorization_value | Bearer
  type response = Http_transport.response

  type t = {
    expected : credential;
    calls : int ref;
    reply : unit -> (response, Diagnostic.t) result;
  }

  let endpoint = Native.endpoint
  let credential = Native.credential
  let equal = Native.equal
  let redacted = Native.redacted

  let post driver credential ~body:_ =
    incr driver.calls;
    Alcotest.(check bool)
      "sealed destination/auth values" true
      (equal driver.expected credential);
    driver.reply ()
end

module Linear = Linear_tracker.Make (Http) (Port)

let mock = Eio_mock.Backend.run
let http_ok = 200
let start = Clock.Pure.of_nanoseconds Count.zero
let delay = checked (Milliseconds.parse "30000")
let default_endpoint = "https://api.linear.app/graphql"
let custom_name = "CUSTOM_TOKEN"

let env token =
  checked
    (Environment.of_bindings
       ~temp_dir:(checked (Absolute_path.parse "/fixture/temp"))
       [ ("LINEAR_API_KEY", token); (custom_name, token) ])

let settings ?(endpoint = default_endpoint) ?(project = "fixture") token =
  let config =
    checked
      (Config_value.parse
         (Printf.sprintf
            "endpoint: '%s'\nproject_slug: '%s'\napi_key: $CUSTOM_TOKEN\n"
            endpoint project))
  in
  fst (tracker_checked (Linear.Config.parse ~env:(env token) config))

let policy terminal =
  let config =
    checked
      (Config_value.parse
         ("tracker:\n  active_states: [Todo]\n  terminal_states: "
         ^ Json.encode
             (checked
                (Json.of_view
                   (Json.Array
                      (List.map
                         (fun name -> checked (Json.of_view (Json.String name)))
                         terminal))))
         ^ "\n"))
  in
  let public = Environment.public (env "") ~deny:[] ~secrets:[] in
  match Scheduling_policy.parse ~env:public config with
  | Ok scheduling -> Tracker_read_policy.of_scheduling scheduling
  | Error errors ->
      Alcotest.fail
        (String.concat "\n"
           (List.map Diagnostic.render (Nonempty_list.to_list errors)))

let normal_policy = policy [ "Done" ]

let sealed endpoint token =
  let endpoint =
    match Http.endpoint endpoint with
    | Ok endpoint -> endpoint
    | Error error -> Alcotest.fail (Diagnostic.render error)
  in
  match Http.credential endpoint ~scheme:Http.Authorization_value ~token with
  | Ok credential -> credential
  | Error error -> Alcotest.fail (Diagnostic.render error)

let parked closed observations =
  let pending, _ = Eio.Promise.create () in
  Port.
    {
      observe =
        (fun () ->
          incr observations;
          Ok start);
      wait =
        (fun due ->
          Alcotest.(check int)
            "fixed 30 s deadline" 0
            (Pure.compare due (Pure.after start delay));
          Fun.protect
            ~finally:(fun () -> incr closed)
            (fun () -> Eio.Promise.await pending));
    }

let empty_page =
  {|{"data":{"issues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}|}

let page_before =
  {|{"data":{"issues":{"nodes":[{"id":"issue-1","identifier":"FIX-1","title":"fixture","state":{"name":"Todo"},"project":{"slugId":"fixture"},"labels":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}},"inverseRelations":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}|}

let body_with_blocker =
  {|{"data":{"issues":{"nodes":[{"id":"issue-1","identifier":"FIX-1","title":"fixture","state":{"name":"Todo"},"project":{"id":"project-1","slugId":"fixture"},"labels":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}},"inverseRelations":{"nodes":[{"id":"relation-1","type":"blocks","issue":{"id":"blocker-1","identifier":"FIX-0","state":{"name":"Done"}},"relatedIssue":{"id":"issue-1"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}|}

let response body = Http_transport.{ status = http_ok; body }
let no_warning _ = Alcotest.fail "unexpected omission"

let pure_and_empty () =
  let factory_calls = ref 0 in
  let clock =
    Port.
      {
        observe = (fun () -> Alcotest.fail "empty read sampled clock");
        wait = (fun _ -> Alcotest.fail "empty read scheduled timer");
      }
  in
  let io =
    Linear.io ~clock
      ~omitted:(fun _ -> Alcotest.fail "empty read reported warning")
      ~http:(fun () ->
        incr factory_calls;
        Error (diagnostic "forbidden factory"))
  in
  let config = settings "fixture-a" in
  Alcotest.(check int) "construction/parse are offline" 0 !factory_calls;
  let result =
    tracker_checked (Linear.states io config ~policy:normal_policy [])
  in
  Alcotest.(check int)
    "empty batch" 0
    (List.length (Issue_batch.ordered result));
  let result =
    tracker_checked
      (Linear.ids io config ~policy:normal_policy Issue_id.Set.empty)
  in
  Alcotest.(check int) "empty map" 0 (Issue_id.Map.cardinal result);
  Alcotest.(check int) "empty inputs never activate transport" 0 !factory_calls;
  Alcotest.(check (list string))
    "declared credential sources"
    [ "LINEAR_API_KEY"; custom_name ]
    (Linear.Config.secret_names config)

let scoped_settings () =
  let endpoint = "https://linear.example/graphql?operator=endpoint-secret" in
  let project = "project-secret" in
  let first = settings ~endpoint ~project "fixture-a" in
  let rotated = settings ~endpoint ~project "fixture-b" in
  let scope = Linear.Config.scope first in
  Alcotest.(check string)
    "unambiguous routing digest"
    "linear:6e15fc4d28b1420e15d175f6a2ccdcf38625bfac424fc7a8790ac1825fa7a3d4"
    (Tracker_scope.text scope);
  Alcotest.(check bool)
    "credential rotation keeps workspace scope" true
    (Tracker_scope.equal scope (Linear.Config.scope rotated));
  Alcotest.(check bool)
    "credential rotation changes settings" false
    (Linear.Config.equal first rotated);
  let normalized = policy [ " DONE "; "Done"; "CLOSED" ] in
  let equivalent = policy [ "closed"; "done" ] in
  Alcotest.(check bool)
    "terminal set is canonical" true
    (Tracker_read_policy.equal normalized equivalent);
  Alcotest.(check bool)
    "terminal policy changes read context" false
    (Tracker_read_policy.equal normal_policy (policy [ "Closed" ]))

let checked_header () =
  let config =
    checked
      (Config_value.parse "project_slug: fixture\napi_key: $CUSTOM_TOKEN\n")
  in
  match Linear.Config.parse ~env:(env "fixture\ninjected") config with
  | Ok _ -> Alcotest.fail "newline credential was sealed"
  | Error error -> (
      Alcotest.(check bool)
        "secret category" true
        (Tracker_error.category error = Tracker_error.Missing_tracker_secret);
      match Diagnostic.site (Tracker_error.diagnostic error) with
      | Diagnostic.Workflow { key; _ } ->
          Alcotest.(check (option string))
            "source key" (Some "tracker.provider.api_key") key
      | Diagnostic.Issue _ | Diagnostic.Protocol _ | Diagnostic.Host _ ->
          Alcotest.fail "sealing error lost configuration key")

type route_field = Project | Endpoint

let secret_routing () =
  let marker = "routing-secret-fixture" in
  let secret_pattern = Re.compile (Re.str marker) in
  List.iter
    (fun field ->
      let key, token, declared, project =
        match field with
        | Project -> ("project_slug", marker, "declared-" ^ marker, "")
        | Endpoint ->
            ( "endpoint",
              "https://linear.example/" ^ marker,
              "https://linear.example/declared-" ^ marker,
              "project_slug: fixture\n" )
      in
      let environment =
        checked
          (Environment.of_bindings
             ~temp_dir:(checked (Absolute_path.parse "/fixture/temp"))
             [
               ("LINEAR_API_KEY", declared);
               (custom_name, token);
               ("ROUTE_ALIAS", token);
               ("DECLARED_ALIAS", declared);
             ])
      in
      List.iter
        (fun routing ->
          let value =
            checked
              (Config_value.parse
                 (Printf.sprintf "%s%s: '%s'\napi_key: $CUSTOM_TOKEN\n" project
                    key routing))
          in
          match Linear.Config.parse ~env:environment value with
          | Ok _ -> Alcotest.fail ("credential material accepted in " ^ key)
          | Error error ->
              Alcotest.(check bool)
                "routing error category" true
                (Tracker_error.category error
                = Tracker_error.Invalid_tracker_config);
              Alcotest.(check bool)
                "routing diagnostic is redacted" false
                (Re.execp secret_pattern
                   (Diagnostic.render (Tracker_error.diagnostic error))))
        [
          "$LINEAR_API_KEY";
          "$CUSTOM_TOKEN";
          "$ROUTE_ALIAS";
          "$DECLARED_ALIAS";
          token;
          declared;
        ])
    [ Project; Endpoint ];
  let endpoint = "https://linear.example/graphql" in
  let project = "public-project" in
  let environment =
    checked
      (Environment.of_bindings
         ~temp_dir:(checked (Absolute_path.parse "/fixture/temp"))
         [
           (custom_name, marker);
           ("PUBLIC_ENDPOINT", endpoint);
           ("PUBLIC_PROJECT", project);
         ])
  in
  let config =
    checked
      (Config_value.parse
         "endpoint: $PUBLIC_ENDPOINT\n\
          project_slug: $PUBLIC_PROJECT\n\
          api_key: $CUSTOM_TOKEN\n")
  in
  let parsed, _ =
    tracker_checked (Linear.Config.parse ~env:environment config)
  in
  Alcotest.(check bool)
    "nonsecret environment references retain routing semantics" true
    (Linear.Config.equal parsed (settings ~endpoint ~project marker));
  let config =
    checked
      (Config_value.parse "project_slug: fixture\napi_key: $CUSTOM_TOKEN\n")
  in
  match Linear.Config.parse ~env:(env default_endpoint) config with
  | Ok _ -> Alcotest.fail "default endpoint equal to credential was exposed"
  | Error error ->
      Alcotest.(check bool)
        "derived default has the same quarantine" true
        (Tracker_error.category error = Tracker_error.Invalid_tracker_config)

let once_per_read () =
  mock (fun () ->
      let factory_calls = ref 0 and post_calls = ref 0 in
      let timer_closed = ref 0 and observations = ref 0 in
      let pages = ref [ page_before; empty_page ] in
      let driver =
        Http.
          {
            expected = sealed default_endpoint "fixture-a";
            calls = post_calls;
            reply =
              (fun () ->
                match !pages with
                | [] -> Alcotest.fail "extra provider request"
                | body :: rest ->
                    pages := rest;
                    Ok (response body));
          }
      in
      let io =
        Linear.io ~clock:(parked timer_closed observations) ~omitted:no_warning
          ~http:(fun () ->
            incr factory_calls;
            Eio.Fiber.yield ();
            Ok driver)
      in
      let result =
        tracker_checked
          (Linear.states io (settings "fixture-a") ~policy:normal_policy
             [ "Todo" ])
      in
      Alcotest.(check int)
        "complete paged batch" 1
        (List.length (Issue_batch.ordered result));
      Alcotest.(check int) "one deferred factory for all pages" 1 !factory_calls;
      Alcotest.(check int) "both pages read" 2 !post_calls;
      Alcotest.(check int) "one monotonic sample" 1 !observations;
      Alcotest.(check int) "timer canceled and joined" 1 !timer_closed)

let terminal_snapshot () =
  mock (fun () ->
      let post_calls = ref 0 and factories = ref 0 in
      let timer_closed = ref 0 and observations = ref 0 in
      let expected =
        ref [ "fixture-a"; "fixture-b"; "fixture-a"; "fixture-a" ]
      in
      let io =
        Linear.io ~clock:(parked timer_closed observations) ~omitted:no_warning
          ~http:(fun () ->
            incr factories;
            Eio.Fiber.yield ();
            match !expected with
            | [] -> Alcotest.fail "unexpected configuration read"
            | token :: rest ->
                expected := rest;
                Ok
                  Http.
                    {
                      expected = sealed default_endpoint token;
                      calls = post_calls;
                      reply = (fun () -> Ok (response body_with_blocker));
                    })
      in
      let old = settings "fixture-a" in
      let changed = settings "fixture-b" in
      let new_policy = policy [ "Closed" ] in
      let read config policy =
        match
          Issue_batch.ordered
            (tracker_checked (Linear.states io config ~policy [ "Todo" ]))
        with
        | [ issue ] -> Issue.routing issue
        | [] | _ :: _ -> Alcotest.fail "wrong issue snapshot count"
      in
      Alcotest.(check bool)
        "initial request uses its terminal policy" true
        (read old normal_policy = Issue.Dispatchable);
      Alcotest.(check bool)
        "new terminal policy applied" true
        (read changed new_policy = Issue.Unroutable);
      Alcotest.(check bool)
        "old credential accepts current terminal policy" true
        (read old new_policy = Issue.Unroutable);
      Alcotest.(check bool)
        "older request retains its captured policy" true
        (read old normal_policy = Issue.Dispatchable);
      Alcotest.(check int) "one factory per policy snapshot" 4 !factories;
      Alcotest.(check int) "all timers joined" 4 !timer_closed)

let factory_error () =
  mock (fun () ->
      let primary = diagnostic "factory unavailable" in
      let timer_closed = ref 0 and observations = ref 0 in
      let io =
        Linear.io ~clock:(parked timer_closed observations) ~omitted:no_warning
          ~http:(fun () ->
            Eio.Fiber.yield ();
            Error primary)
      in
      match
        Linear.states io (settings "fixture-a") ~policy:normal_policy [ "Todo" ]
      with
      | Ok _ -> Alcotest.fail "factory error disappeared"
      | Error error ->
          Alcotest.(check bool)
            "request category" true
            (Tracker_error.category error = Tracker_error.Tracker_request);
          Alcotest.(check bool)
            "original diagnostic" true
            (Tracker_error.diagnostic error == primary);
          Alcotest.(check int)
            "timer joined before returning error" 1 !timer_closed)

let clock_error () =
  let primary = diagnostic "monotonic clock unavailable" in
  let factory_calls = ref 0 in
  let clock =
    Port.
      {
        observe = (fun () -> Error primary);
        wait = (fun _ -> Alcotest.fail "rejected deadline scheduled a timer");
      }
  in
  let io =
    Linear.io ~clock ~omitted:no_warning ~http:(fun () ->
        incr factory_calls;
        Error (diagnostic "forbidden factory"))
  in
  match
    Linear.states io (settings "fixture-a") ~policy:normal_policy [ "Todo" ]
  with
  | Ok _ -> Alcotest.fail "clock failure admitted provider IO"
  | Error error ->
      Alcotest.(check bool)
        "clock error retains request category" true
        (Tracker_error.category error = Tracker_error.Tracker_request);
      Alcotest.(check bool)
        "clock diagnostic retains identity" true
        (Tracker_error.diagnostic error == primary);
      Alcotest.(check int)
        "rejected deadline invokes no factory" 0 !factory_calls

let factory_deadline () =
  mock (fun () ->
      let entered, enter = Eio.Promise.create () in
      let pending, _ = Eio.Promise.create () in
      let closed = ref false and factories = ref 0 in
      let clock =
        Port.
          {
            observe = (fun () -> Ok start);
            wait =
              (fun due ->
                Alcotest.(check int)
                  "factory shares fixed deadline" 0
                  (Pure.compare due (Pure.after start delay));
                Eio.Promise.await entered;
                Ok ());
          }
      in
      let io =
        Linear.io ~clock ~omitted:no_warning ~http:(fun () ->
            incr factories;
            Eio.Promise.resolve enter ();
            Fun.protect
              ~finally:(fun () -> closed := true)
              (fun () -> Eio.Promise.await pending))
      in
      match
        Linear.states io (settings "fixture-a") ~policy:normal_policy [ "Todo" ]
      with
      | Ok _ -> Alcotest.fail "blocked factory outlived whole-read deadline"
      | Error error ->
          Alcotest.(check bool)
            "timeout category" true
            (Tracker_error.category error = Tracker_error.Tracker_request);
          Alcotest.(check bool) "factory cancellation joined" true !closed;
          Alcotest.(check int) "single activation attempt" 1 !factories)

let tests =
  [
    Alcotest.test_case "offline parse and empty reads have zero IO" `Quick
      pure_and_empty;
    Alcotest.test_case
      "routing scope hides endpoint/project and survives rotation" `Quick
      scoped_settings;
    Alcotest.test_case "real header constructor rejects newline credential"
      `Quick checked_header;
    Alcotest.test_case
      "credential sources aliases and literals cannot become routing" `Quick
      secret_routing;
    Alcotest.test_case "one factory and deadline span all pages" `Quick
      once_per_read;
    Alcotest.test_case "fresh terminal policy uses the frozen credential" `Quick
      terminal_snapshot;
    Alcotest.test_case "factory error preserves original diagnostic" `Quick
      factory_error;
    Alcotest.test_case "clock rejection preserves error and performs no IO"
      `Quick clock_error;
    Alcotest.test_case
      "deadline includes factory activation and joins cancellation" `Quick
      factory_deadline;
  ]

let names = [ "Done"; "DONE"; " done "; "Closed"; "CLOSED"; " closed " ]

let terminal_model values =
  List.sort_uniq String.compare
    (List.map (fun value -> String.lowercase_ascii (String.trim value)) values)

let properties =
  [
    QCheck2.Test.make
      ~name:"read policy agrees with terminal-set reference model" ~count:300
      QCheck2.Gen.(
        pair
          (list_size (int_range 0 10) (oneof_list names))
          (list_size (int_range 0 10) (oneof_list names)))
      (fun (left, right) ->
        let a = policy left in
        let b = policy right in
        Tracker_read_policy.equal a b
        = (terminal_model left = terminal_model right));
  ]
