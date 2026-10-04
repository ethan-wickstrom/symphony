let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "expected a checked protocol envelope"

let json source =
  match Json.parse source with
  | Ok value -> value
  | Error _ -> Alcotest.fail "invalid test JSON"

let decode source = get (Protocol_envelope.decode (json source))

let agreement source =
  let original = json source in
  let decoded = get (Protocol_envelope.decode original) in
  let encoded = get (Protocol_envelope.encode decoded) in
  Alcotest.(check bool)
    "preserve complete checked envelope" true
    (Json.equal original encoded);
  ignore (get (Protocol_envelope.decode encoded))

let valid_shapes () =
  List.iter agreement
    [
      "{\"id\":\"\",\"method\":\"initialize\"}";
      "{\"id\":-9223372036854775808,\"method\":\"turn/start\",\"params\":null}";
      "{\"method\":\"initialized\"}";
      "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"t\"}}";
      "{\"id\":9223372036854775807,\"result\":null}";
      "{\"id\":\"7\",\"error\":{\"code\":-32601,\"message\":\"\",\"data\":null}}";
      "{\"id\":7,\"error\":{\"code\":-9223372036854775808,\"message\":\"failure\"}}";
      "{\"id\":7,\"error\":{\"code\":9223372036854775807,\"message\":\"failure\"}}";
    ]

let correlation () =
  List.iter
    (fun id ->
      let request =
        get
          (Protocol_envelope.request ~id ~method_:"turn/interrupt"
             ~params:(Some (json "{}")))
      in
      let response =
        get
          (Protocol_envelope.response ~id
             ~reply:(Protocol_envelope.Success (json "{}")))
      in
      let observed =
        match Protocol_envelope.view response with
        | Protocol_envelope.Response { id; _ } -> id
        | Protocol_envelope.Request _ | Protocol_envelope.Notification _ ->
            Alcotest.fail "response has wrong shape"
      in
      Alcotest.(check bool)
        "response echoes wire identity" true
        (Protocol_id.equal id observed);
      List.iter
        (fun envelope ->
          ignore
            (get
               (Protocol_envelope.decode
                  (get (Protocol_envelope.encode envelope)))))
        [ request; response ])
    [
      get (Protocol_id.of_string "7");
      Protocol_id.of_int64 7L;
      Protocol_id.of_int64 Int64.min_int;
      Protocol_id.of_int64 Int64.max_int;
    ]

let optional_params () =
  (match Protocol_envelope.view (decode "{\"id\":7,\"method\":\"x\"}") with
  | Protocol_envelope.Request { params = None; _ } -> ()
  | Protocol_envelope.Request { params = Some _; _ }
  | Protocol_envelope.Notification _ | Protocol_envelope.Response _ ->
      Alcotest.fail "omitted params became a value");
  match
    Protocol_envelope.view (decode "{\"method\":\"x\",\"params\":null}")
  with
  | Protocol_envelope.Notification { params = Some value; _ } ->
      Alcotest.(check bool)
        "explicit null remains present" true
        (Json.equal value (json "null"))
  | Protocol_envelope.Notification { params = None; _ }
  | Protocol_envelope.Request _ | Protocol_envelope.Response _ ->
      Alcotest.fail "explicit params were lost"

let extensions () =
  (* The selected schemas permit additive fields; they carry no authority. *)
  List.iter agreement
    [
      "{\"id\":7,\"method\":\"x\",\"trace\":{\"traceparent\":null},\"future\":{\"x\":[true]}}";
      "{\"method\":\"x\",\"future\":42}";
      "{\"id\":\"7\",\"result\":{},\"future\":[null]}";
      "{\"id\":7,\"error\":{\"code\":-32601,\"message\":\"unknown\",\"future\":true},\"extra\":1}";
    ]

let malformed () =
  List.iter
    (fun source ->
      Alcotest.(check bool)
        "reject malformed envelope" true
        (Result.is_error (Protocol_envelope.decode (json source))))
    [
      "null";
      "[]";
      "{}";
      "{\"result\":null}";
      "{\"id\":null,\"result\":null}";
      "{\"id\":1e0,\"result\":null}";
      "{\"id\":9223372036854775808,\"result\":null}";
      "{\"id\":7,\"method\":null}";
      "{\"method\":\"\"}";
      "{\"id\":7,\"result\":null,\"error\":{\"code\":1,\"message\":\"x\"}}";
      "{\"id\":7,\"method\":\"x\",\"result\":null}";
      "{\"method\":\"x\",\"error\":null}";
      "{\"id\":7,\"result\":null,\"params\":null}";
      "{\"id\":7,\"error\":null}";
      "{\"id\":7,\"error\":{\"message\":\"x\"}}";
      "{\"id\":7,\"error\":{\"code\":1}}";
      "{\"id\":7,\"error\":{\"code\":1.0,\"message\":\"x\"}}";
      "{\"id\":7,\"error\":{\"code\":1,\"message\":null}}";
      "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}";
      "{\"jsonrpc\":null,\"id\":7,\"result\":null}";
    ];
  List.iter
    (fun source ->
      Alcotest.(check bool)
        "duplicate keys rejected before envelope" true
        (Result.is_error (Json.parse source)))
    [
      "{\"id\":7,\"id\":\"7\",\"result\":null}";
      "{\"method\":\"x\",\"method\":\"y\"}";
      "{\"id\":7,\"error\":{\"code\":1,\"message\":\"x\",\"message\":\"y\"}}";
    ]

let method_bounds () =
  let method_limit = 256 in
  let method_ = String.make method_limit 'x' in
  ignore (get (Protocol_envelope.notification ~method_ ~params:None));
  List.iter
    (fun method_ ->
      Alcotest.(check bool)
        "invalid method constructor" true
        (Result.is_error (Protocol_envelope.notification ~method_ ~params:None)))
    [ ""; method_ ^ "x"; "\255" ]

let constructors () =
  let id = get (Protocol_id.of_string "rpc") in
  let reply =
    Protocol_envelope.Failure
      {
        Protocol_envelope.code = -32601L;
        Protocol_envelope.message = "Unsupported method";
        Protocol_envelope.data = None;
      }
  in
  let envelope = get (Protocol_envelope.response ~id ~reply) in
  Alcotest.(check bool)
    "error response uses exact wire shape" true
    (Json.equal
       (json
          "{\"id\":\"rpc\",\"error\":{\"code\":-32601,\"message\":\"Unsupported \
           method\"}}")
       (get (Protocol_envelope.encode envelope)));
  let invalid =
    Protocol_envelope.Failure
      {
        Protocol_envelope.code = 1L;
        Protocol_envelope.message = "\255";
        Protocol_envelope.data = None;
      }
  in
  Alcotest.(check bool)
    "invalid error string is a value" true
    (Result.is_error (Protocol_envelope.response ~id ~reply:invalid))

let tests =
  [
    Alcotest.test_case "valid selected envelopes" `Quick valid_shapes;
    Alcotest.test_case "correlated ID variants" `Quick correlation;
    Alcotest.test_case "omitted and null params" `Quick optional_params;
    Alcotest.test_case "additive extensions survive" `Quick extensions;
    Alcotest.test_case "malformed envelopes" `Quick malformed;
    Alcotest.test_case "bounded UTF-8 methods" `Quick method_bounds;
    Alcotest.test_case "checked response constructor" `Quick constructors;
  ]
