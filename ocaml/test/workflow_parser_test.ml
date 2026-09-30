type model =
  | M_null
  | M_bool of bool
  | M_number of string
  | M_string of string
  | M_seq of model list
  | M_map of (string * model) list

(* A flow document printer supplies an independent typed-tree oracle. *)
let quote source =
  let out = Buffer.create (String.length source + 2) in
  Buffer.add_char out '"';
  String.iter
    (function
      | '"' -> Buffer.add_string out "\\\""
      | '\\' -> Buffer.add_string out "\\\\"
      | '\n' -> Buffer.add_string out "\\n"
      | '\r' -> Buffer.add_string out "\\r"
      | '\t' -> Buffer.add_string out "\\t"
      | c when Char.code c < 32 || Char.code c = 127 ->
          Buffer.add_string out (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char out c)
    source;
  Buffer.add_char out '"';
  Buffer.contents out

let rec emit = function
  | M_null -> "null"
  | M_bool value -> string_of_bool value
  | M_number value -> value
  | M_string value -> quote value
  | M_seq values -> "[" ^ String.concat ", " (List.map emit values) ^ "]"
  | M_map fields ->
      let field (key, value) = quote key ^ ": " ^ emit value in
      "{" ^ String.concat ", " (List.map field fields) ^ "}"

let rec model value =
  match Config_value.view value with
  | Config_value.Null -> M_null
  | Config_value.Bool value -> M_bool value
  | Config_value.Number value -> M_number value
  | Config_value.String value -> M_string value
  | Config_value.Sequence values -> M_seq (List.map model values)
  | Config_value.Mapping fields ->
      M_map (List.map (fun (key, value) -> (key, model value)) fields)

let model_test =
  Alcotest.testable (fun fmt x -> Format.pp_print_string fmt (emit x)) ( = )

let parse source =
  match Config_value.parse source with
  | Ok value -> value
  | Error error -> Alcotest.fail error

let check_tree label expected source =
  Alcotest.check model_test label expected (model (parse source))

let rejects source =
  match Config_value.parse source with
  | Error error ->
      Alcotest.check Alcotest.bool "error names the problem" true (error <> "")
  | Ok value -> Alcotest.failf "unexpected parsed tree: %s" (emit (model value))

let file () =
  let base =
    match Absolute_path.parse "/srv/symphony" with
    | Ok value -> value
    | Error error -> Alcotest.fail error
  in
  match Workflow_path.resolve ~base "WORKFLOW.md" with
  | Ok value -> value
  | Error error -> Alcotest.fail error

let document source =
  match Workflow_document.parse ~file:(file ()) source with
  | Ok value -> value
  | Error (Workflow_document.Parse_error error)
  | Error (Workflow_document.Front_matter_not_map error) ->
      Alcotest.fail (Diagnostic.render error)

let scalars () =
  List.iter
    (fun (source, expected) -> check_tree source expected source)
    [
      ("null", M_null);
      ("NULL", M_null);
      ("~", M_null);
      ("true", M_bool true);
      ("False", M_bool false);
      ("yes", M_string "yes");
      ("ON", M_string "ON");
      ("42", M_number "42");
      ("-12", M_number "-12");
      ("0o17", M_number "0o17");
      ("0xFF", M_number "0xFF");
      ("1.5e+20", M_number "1.5e+20");
      (".5", M_number ".5");
      ( "99999999999999999999999999999999",
        M_number "99999999999999999999999999999999" );
      ("\"true\"", M_string "true");
      ("'null'", M_string "null");
      ("\"42\"", M_string "42");
      ("!!str true", M_string "true");
      ("!!bool \"true\"", M_bool true);
      ("! 42", M_string "42");
      ("\"A\\0B\"", M_string "A\000B");
    ]

let invalid_scalars () =
  List.iter rejects
    [
      ".inf";
      "-.Inf";
      "+.INF";
      ".nan";
      "!!float .inf";
      "!!int text";
      "!!bool yes";
      "!!null text";
      "!application x";
      "!!map []";
      "!!seq {}";
      "%YAML 1.1\n---\nx";
      "%YAML 1.3\n---\nx";
    ]

let whole_document () =
  check_tree "standard map tag"
    (M_map [ ("x", M_seq []) ])
    "!!map {x: !!seq []}";
  List.iter rejects
    [
      "";
      "x: [";
      "---\na: 1\n---\nb: 2";
      "{}\ntrailing";
      "a: 1\na: 2";
      "outer: {x: 1, x: 2}";
      "true: value";
      "null: value";
      "[x]: value";
    ];
  check_tree "quoted scalar key"
    (M_map [ ("true", M_string "value") ])
    "'true': value"

let aliases () =
  let source = "saved: &v [true, 42]\ncopy: *v\n" in
  let tree = parse source in
  let expected = M_seq [ M_bool true; M_number "42" ] in
  Alcotest.check model_test "alias equals its definition"
    (M_map [ ("saved", expected); ("copy", expected) ])
    (model tree);
  (match Config_value.field tree "copy" with
  | Some value ->
      Alcotest.check
        (Alcotest.pair Alcotest.int Alcotest.int)
        "alias use location" (2, 7)
        (Config_value.location value)
  | None -> Alcotest.fail "missing alias field");
  check_tree "most recent anchor wins"
    (M_map [ ("outer", M_seq [ M_string "inner" ]); ("copy", M_string "inner") ])
    "outer: &a [ &a inner ]\ncopy: *a";
  List.iter rejects [ "*unknown"; "&cycle [*cycle]" ]

let limits () =
  rejects (String.make 1_048_577 'x');
  rejects (String.make 70 '[' ^ "x" ^ String.make 70 ']');
  rejects ("[" ^ String.concat "," (List.init 32_768 (fun _ -> "x")) ^ "]");
  let payload = String.make 750_000 'x' in
  rejects ("saved: &s " ^ payload ^ "\ncopies: [*s,*s,*s,*s,*s,*s]");
  let layers =
    List.init 16 (fun i ->
        if i = 0 then "a0: &a0 [x,x]"
        else Printf.sprintf "a%d: &a%d [*a%d,*a%d]" i i (i - 1) (i - 1))
  in
  rejects (String.concat "\n" layers)

let workflow_split () =
  let plain = document "\n  Do the work.  \n" in
  Alcotest.check Alcotest.string "plain prompt trimmed" "Do the work."
    (Workflow_document.prompt plain);
  Alcotest.check model_test "no front matter gives empty map" (M_map [])
    (model (Workflow_document.config plain));
  let framed =
    document "---\r\ntracker:\r\n  kind: linear\r\n---  \r\n  Do the work. \r\n"
  in
  Alcotest.check model_test "CRLF front matter"
    (M_map [ ("tracker", M_map [ ("kind", M_string "linear") ]) ])
    (model (Workflow_document.config framed));
  Alcotest.check Alcotest.string "framed prompt trimmed" "Do the work."
    (Workflow_document.prompt framed);
  Alcotest.check Alcotest.string "source identity" "/srv/symphony/WORKFLOW.md"
    (Workflow_path.display (Workflow_document.file framed));
  let literal =
    document "---\nhooks:\n  after_create: |\n    ---\n    echo ok\n---\n"
  in
  Alcotest.check model_test "indented delimiter stays YAML"
    (M_map [ ("hooks", M_map [ ("after_create", M_string "---\necho ok\n") ]) ])
    (model (Workflow_document.config literal));
  Alcotest.check Alcotest.string "empty body" ""
    (Workflow_document.prompt literal);
  Alcotest.check Alcotest.string "leading blank keeps prompt"
    "---\nx: 1\n---\nbody"
    (Workflow_document.prompt (document "\n---\nx: 1\n---\nbody"))

let workflow_errors () =
  List.iter
    (fun source ->
      match Workflow_document.parse ~file:(file ()) source with
      | Error (Workflow_document.Front_matter_not_map error) -> (
          match Diagnostic.site error with
          | Diagnostic.Workflow { file; key = _; line = _ } ->
              Alcotest.check Alcotest.string "error source"
                "/srv/symphony/WORKFLOW.md" file
          | Diagnostic.Issue _ | Diagnostic.Protocol _ | Diagnostic.Host _ ->
              Alcotest.fail "wrong diagnostic site")
      | Error (Workflow_document.Parse_error error) ->
          Alcotest.fail (Diagnostic.render error)
      | Ok _ -> Alcotest.fail "expected non-map front matter")
    [ "---\n---\nbody"; "---\nnull\n---\nbody"; "---\n[x]\n---\nbody" ];
  List.iter
    (fun source ->
      match Workflow_document.parse ~file:(file ()) source with
      | Error (Workflow_document.Parse_error _) -> ()
      | Error (Workflow_document.Front_matter_not_map _) ->
          Alcotest.fail "wrong error category"
      | Ok _ -> Alcotest.fail "expected malformed workflow")
    [
      "---\nx: 1";
      "---\nx: [\n---\nbody";
      "---\na: 1\n---\nignored" ^ String.make 1_048_576 'x';
    ]

exception Cleanup_probe

let parser_lifetime () =
  let closed =
    match Yaml.Stream.with_parser "{}" Fun.id with
    | Ok value -> value
    | Error (`Msg message) -> Alcotest.fail message
  in
  Yaml.Stream.close closed;
  (match Yaml.Stream.do_parse closed with
  | Error (`Msg _) -> ()
  | Ok _ -> Alcotest.fail "closed parser remained usable");
  let captured = ref None in
  (try
     ignore
       (Yaml.Stream.with_parser "{}" (fun parser ->
            captured := Some parser;
            raise Cleanup_probe));
     Alcotest.fail "callback exception did not propagate"
   with Cleanup_probe -> ());
  match !captured with
  | None -> Alcotest.fail "callback did not run"
  | Some parser -> (
      match Yaml.Stream.do_parse parser with
      | Error (`Msg _) -> ()
      | Ok _ -> Alcotest.fail "exception leaked an open parser")

let tests =
  [
    Alcotest.test_case "YAML 1.2 scalar kinds and exact lexemes" `Quick scalars;
    Alcotest.test_case "reject unsupported scalar profiles" `Quick
      invalid_scalars;
    Alcotest.test_case "one complete document and unique string keys" `Quick
      whole_document;
    Alcotest.test_case "aliases resolve in document order" `Quick aliases;
    Alcotest.test_case "source and expansion budgets" `Quick limits;
    Alcotest.test_case "workflow delimiter and prompt rules" `Quick
      workflow_split;
    Alcotest.test_case "workflow expected failure categories" `Quick
      workflow_errors;
    Alcotest.test_case "native parser scope closes on every exit" `Quick
      parser_lifetime;
  ]

let scalar_gen =
  let open QCheck2.Gen in
  let chars = map Char.chr (int_range 0 127) in
  oneof
    [
      return M_null;
      return (M_bool true);
      return (M_bool false);
      map
        (fun value -> M_number value)
        (oneof
           (List.map return
              [ "0"; "-42"; "1.25"; ".5"; "0xFF"; "0o17"; "9e12" ]));
      map
        (fun value -> M_string value)
        (string_size ~gen:chars (int_range 0 24));
    ]

let rec tree_gen depth =
  let open QCheck2.Gen in
  if depth = 0 then scalar_gen
  else
    let values = list_size (int_range 0 4) (tree_gen (depth - 1)) in
    oneof
      [
        scalar_gen;
        map (fun values -> M_seq values) values;
        map
          (fun values ->
            M_map
              (List.mapi (fun i value -> ("k" ^ string_of_int i, value)) values))
          values;
      ]

let rec positioned value =
  let line, column = Config_value.location value in
  line > 0 && column > 0
  &&
  match Config_value.view value with
  | Config_value.Null
  | Config_value.Bool _
  | Config_value.Number _
  | Config_value.String _ -> true
  | Config_value.Sequence values -> List.for_all positioned values
  | Config_value.Mapping fields ->
      List.for_all (fun (_, value) -> positioned value) fields

let properties =
  let open QCheck2 in
  [
    Test.make ~name:"flow printer agrees with typed tree model" ~count:1_000
      ~print:emit (tree_gen 4) (fun expected ->
        match Config_value.parse (emit expected) with
        | Ok actual -> model actual = expected && positioned actual
        | Error _ -> false);
    Test.make ~name:"duplicate bindings always fail" ~count:300 (tree_gen 2)
      (fun value ->
        match Config_value.parse ("{x: " ^ emit value ^ ", x: null}") with
        | Error _ -> true
        | Ok _ -> false);
    Test.make ~name:"aliases agree with copied model trees" ~count:300
      (tree_gen 3) (fun value ->
        match Config_value.parse ("saved: &a " ^ emit value ^ "\ncopy: *a") with
        | Error _ -> false
        | Ok actual ->
            model actual = M_map [ ("saved", value); ("copy", value) ]);
    Test.make ~name:"bounded arbitrary bytes return values or errors"
      ~count:1_000
      (Gen.string_size
         ~gen:(Gen.map Char.chr (Gen.int_range 0 255))
         (Gen.int_range 0 512))
      (fun source ->
        match Config_value.parse source with
        | Error message -> message <> ""
        | Ok value -> positioned value);
    Test.make ~name:"workflow body agrees with trim model" ~count:300
      (Gen.map2
         (fun values body -> (values, body))
         (Gen.list_size (Gen.int_range 0 4) (tree_gen 2))
         (Gen.string_size
            ~gen:(Gen.map Char.chr (Gen.int_range 32 126))
            (Gen.int_range 0 64)))
      (fun (values, body) ->
        let config =
          M_map
            (List.mapi (fun i value -> ("k" ^ string_of_int i, value)) values)
        in
        let source = "---\n" ^ emit config ^ "\n---\n \t" ^ body ^ "\n " in
        match Workflow_document.parse ~file:(file ()) source with
        | Error
            ( Workflow_document.Parse_error _
            | Workflow_document.Front_matter_not_map _ ) -> false
        | Ok actual ->
            model (Workflow_document.config actual) = config
            && Workflow_document.prompt actual = String.trim body);
  ]
