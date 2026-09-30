let count n =
  match Count.parse (string_of_int n) with
  | Ok n -> n
  | Error e -> failwith e

let examples () =
  let big =
    match Count.parse "999999999999999999999999999999999999" with
    | Ok n -> n
    | Error e -> Alcotest.fail e
  in
  Alcotest.(check string)
    "exact increment" "1000000000000000000000000000000000000"
    (Count.decimal (Count.add big Count.one));
  Alcotest.(check bool)
    "bounded display" true
    (Result.is_error (Count.decimal_bounded ~max_bytes:10 big));
  List.iter
    (fun s ->
      Alcotest.(check bool)
        (Text.escape s) true
        (Result.is_error (Json.parse s)))
    [
      "{\"x\":1,\"x\":2}";
      "NaN";
      "Infinity";
      "01";
      "[1,]";
      "\"\\ud800\"";
      String.make 65 '[' ^ String.make 65 ']';
    ];
  let n = "123456789012345678901234567890.123e-456" in
  match Json.parse n with
  | Error e -> Alcotest.fail e
  | Ok j -> Alcotest.(check string) "numeric lexeme" n (Json.encode j)

let bounded_composition () =
  let child =
    match Json.of_view (Json.String (String.make 131_072 'x')) with
    | Ok child -> child
    | Error e -> Alcotest.fail e
  in
  let children = List.init 16 (fun _ -> child) in
  let before = Gc.allocated_bytes () in
  let result = Json.of_view (Json.Array children) in
  let allocated = Gc.allocated_bytes () -. before in
  Alcotest.(check bool)
    "reject oversized composition" true (Result.is_error result);
  (* Reject before serialization can allocate the oversized wire value. *)
  Alcotest.(check bool)
    "allocation below encoded input limit" true (allocated < 1_048_576.);
  let limit = 1_048_576 in
  List.iter
    (fun (c, width) ->
      let n = (limit - 2) / width in
      let inside = String.make n c in
      let outside = String.make (n + 1) c in
      let oracle = String.length (Yojson.Safe.to_string (`String inside)) in
      Alcotest.(check bool)
        "serializer oracle within limit" true (oracle <= limit);
      Alcotest.(check bool)
        "accept exact escaped-string boundary" true
        (Result.is_ok (Json.of_view (Json.String inside)));
      Alcotest.(check bool)
        "reject next encoded byte" true
        (Result.is_error (Json.of_view (Json.String outside))))
    [ ('x', 1); ('"', 2); ('\\', 2); ('\n', 2); ('\000', 6); ('\127', 6) ]

let explicit_dispatchable () =
  let base =
    {|"id":"fixture-id","identifier":"SYM-1","title":"Checked fixture","state":"Todo"|}
  in
  List.iter
    (fun suffix ->
      let source = "{" ^ base ^ suffix ^ "}" in
      Alcotest.(check bool)
        "invalid eligibility cannot default to dispatchable" true
        (Result.is_error (Prompt_fixture.parse source)))
    [
      "";
      ",\"dispatchable\":null";
      ",\"dispatchable\":1";
      ",\"dispatchable\":\"true\"";
      ",\"dispatchable\":[]";
      ",\"dispatchable\":{}";
    ];
  List.iter
    (fun (value, expected) ->
      match
        Prompt_fixture.parse ("{" ^ base ^ ",\"dispatchable\":" ^ value ^ "}")
      with
      | Error message -> Alcotest.fail message
      | Ok issue ->
          Alcotest.(check bool)
            "explicit eligibility preserved" expected
            (Issue.routing issue = Issue.Dispatchable))
    [ ("true", true); ("false", false) ]

let tests =
  [
    Alcotest.test_case "exact arithmetic and JSON boundaries" `Quick examples;
    Alcotest.test_case "JSON composition rejects before encoding" `Quick
      bounded_composition;
    Alcotest.test_case "fixture requires explicit boolean eligibility" `Quick
      explicit_dispatchable;
  ]

let properties =
  [
    QCheck2.Test.make
      ~name:"normalized assignee agrees with nullable metadata model"
      ~count:1000
      QCheck2.Gen.(
        option
          (string_size ~gen:(map Char.chr (int_range 0 127)) (int_range 0 64)))
      (fun assignee ->
        let value =
          match assignee with
          | None -> `Null
          | Some value -> `String value
        in
        let fixture =
          Yojson.Safe.to_string
            (`Assoc
               [
                 ("id", `String "model-id");
                 ("identifier", `String "MODEL-1");
                 ("title", `String "Model assignment");
                 ("state", `String "Todo");
                 ("dispatchable", `Bool true);
                 ("assignee_id", value);
               ])
        in
        let expected =
          match assignee with
          | Some text when not (String.contains text '\000') -> Json.String text
          | Some _ | None -> Json.Null
        in
        match Prompt_fixture.parse fixture with
        | Error _ -> false
        | Ok issue -> (
            match Json.view (Issue.to_json issue) with
            | Json.Object fields -> (
                match List.assoc_opt "assignee_id" fields with
                | None -> false
                | Some value -> Json.view value = expected)
            | Json.Null
            | Json.Bool _
            | Json.Number _
            | Json.String _
            | Json.Array _ -> false));
    QCheck2.Test.make ~name:"JSON numeric equality agrees with rational model"
      ~count:1000
      QCheck2.Gen.(
        pair
          (pair (int_range (-10000) 10000) (int_range (-12) 12))
          (pair (int_range (-10000) 10000) (int_range (-12) 12)))
      (fun ((a, e), (b, f)) ->
        let model n e =
          if e >= 0 then
            Q.of_bigint (Z.mul (Z.of_int n) (Z.pow (Z.of_int 10) e))
          else Q.make (Z.of_int n) (Z.pow (Z.of_int 10) (-e))
        in
        let parsed n e = Json.parse (Printf.sprintf "%de%d" n e) in
        match (parsed a e, parsed b f) with
        | Ok x, Ok y ->
            Json.equal x y = Q.equal (model a e) (model b f)
            && Json.equal x x
            && Json.equal x y = Json.equal y x
        | Error _, _ | _, Error _ -> false);
    QCheck2.Test.make ~name:"count agrees with integer sum and monoid laws"
      ~count:2000
      QCheck2.Gen.(
        triple (int_range 0 1000000) (int_range 0 1000000) (int_range 0 1000000))
      (fun (a, b, c) ->
        let x = count a and y = count b and z = count c in
        Count.decimal (Count.add x y) = string_of_int (a + b)
        && Count.compare (Count.add Count.zero x) x = 0
        && Count.compare (Count.add x y) (Count.add y x) = 0
        && Count.compare
             (Count.add (Count.add x y) z)
             (Count.add x (Count.add y z))
           = 0);
    QCheck2.Test.make ~name:"absolute counter delta telescopes" ~count:1000
      QCheck2.Gen.(
        triple (int_range 0 100000) (int_range 0 100000) (int_range 0 100000))
      (fun (a, b, c) ->
        let x = count a and y = count (a + b) and z = count (a + b + c) in
        Count.compare
          (Count.add
             (Count.delta ~previous:x ~current:y)
             (Count.delta ~previous:y ~current:z))
          (Count.delta ~previous:x ~current:z)
        = 0);
    QCheck2.Test.make ~name:"JSON checked values round-trip" ~count:1000
      QCheck2.Gen.(list_size (int_range 0 20) (int_range (-1000000) 1000000))
      (fun xs ->
        let source =
          "[" ^ String.concat "," (List.map string_of_int xs) ^ "]"
        in
        match Json.parse source with
        | Error _ -> false
        | Ok j -> (
            match Json.parse (Json.encode j) with
            | Error _ -> false
            | Ok k -> Json.encode j = Json.encode k));
  ]
