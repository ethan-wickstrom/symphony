let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "expected a checked protocol ID"

let json source =
  match Json.parse source with
  | Ok value -> value
  | Error _ -> Alcotest.fail "invalid test JSON"

let decode source = get (Protocol_id.decode (json source))

let variants () =
  let text = decode "\"7\"" and integer = decode "7" in
  Alcotest.(check bool)
    "string and integer differ" false
    (Protocol_id.equal text integer);
  Alcotest.(check bool)
    "ordered identities differ" false
    (Protocol_id.compare text integer = 0);
  match Protocol_id.view (decode "\"\"") with
  | Protocol_id.String value -> Alcotest.(check string) "empty ID" "" value
  | Protocol_id.Integer _ -> Alcotest.fail "empty ID changed its variant"

let signed_edges () =
  (* These limits come from RequestId's signed int64 contract, not OCaml int. *)
  List.iter
    (fun (source, expected) ->
      let id = decode source in
      (match Protocol_id.view id with
      | Protocol_id.Integer actual ->
          Alcotest.(check int64) "exact signed integer" expected actual
      | Protocol_id.String _ -> Alcotest.fail "integer changed its variant");
      let encoded = get (Protocol_id.encode id) in
      Alcotest.(check bool)
        "integer JSON agreement" true
        (Json.equal (json source) encoded);
      Alcotest.(check bool)
        "ID roundtrip" true
        (Protocol_id.equal id (get (Protocol_id.decode encoded))))
    [
      ("-9223372036854775808", Int64.min_int);
      ("9223372036854775807", Int64.max_int);
      ("-1", -1L);
      ("-0", 0L);
      ("0", 0L);
    ]

let rejected_numbers () =
  List.iter
    (fun source ->
      Alcotest.(check bool)
        "invalid wire integer" true
        (Result.is_error (Protocol_id.decode (json source))))
    [
      "1.0";
      "1e0";
      "1E0";
      "-0.0";
      "9223372036854775808";
      "-9223372036854775809";
      "true";
      "null";
      "[]";
      "{}";
    ]

let string_bounds () =
  let string_limit = 1024 in
  let at_limit = String.make string_limit 'x' in
  ignore (get (Protocol_id.of_string at_limit));
  Alcotest.(check bool)
    "one byte over" true
    (Result.is_error (Protocol_id.of_string (at_limit ^ "x")));
  let unicode =
    String.concat "" (List.init (string_limit / 2) (fun _ -> "é"))
  in
  ignore (get (Protocol_id.of_string unicode));
  Alcotest.(check bool)
    "limit counts UTF-8 bytes" true
    (Result.is_error (Protocol_id.of_string (unicode ^ "é")));
  Alcotest.(check bool)
    "reject invalid UTF-8" true
    (Result.is_error (Protocol_id.of_string "\255"))

let constructors () =
  List.iter
    (fun id ->
      let encoded = get (Protocol_id.encode id) in
      Alcotest.(check bool)
        "constructed ID roundtrip" true
        (Protocol_id.equal id (get (Protocol_id.decode encoded))))
    [
      get (Protocol_id.of_string "");
      get (Protocol_id.of_string "\000quoted\"\n雪");
      Protocol_id.of_int64 Int64.min_int;
      Protocol_id.of_int64 Int64.max_int;
    ]

let tests =
  [
    Alcotest.test_case "wire ID variants" `Quick variants;
    Alcotest.test_case "signed int64 edges" `Quick signed_edges;
    Alcotest.test_case "reject non-wire numbers" `Quick rejected_numbers;
    Alcotest.test_case "bounded UTF-8 IDs" `Quick string_bounds;
    Alcotest.test_case "checked ID constructors" `Quick constructors;
  ]
