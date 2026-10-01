module Model = Workspace_owner_model

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let observe owner : Model.t =
  {
    Model.scope = Tracker_scope.text (Workspace_owner.scope owner);
    issue_id = Issue_id.text (Workspace_owner.issue_id owner);
    identifier = Issue_identifier.text (Workspace_owner.identifier owner);
    device = Printf.sprintf "%016Lx" (Workspace_owner.device owner);
    inode = Printf.sprintf "%016Lx" (Workspace_owner.inode owner);
  }

let make scope issue_id identifier device inode =
  Workspace_owner.make
    ~scope:(checked (Tracker_scope.parse scope))
    ~issue_id:(checked (Issue_id.parse issue_id))
    ~identifier:(checked (Issue_identifier.parse identifier))
    ~device ~inode

let fields : (string * Yojson.Safe.t) list =
  [
    ("version", `Int 1);
    ("scope", `String "linear:project");
    ("issue_id", `String "opaque-id");
    ("identifier", `String "SYM-1");
    ("device", `String "8000000000000000");
    ("inode", `String "ffffffffffffffff");
  ]

let json fields = Yojson.Safe.to_string (`Assoc fields)

let replace name value =
  List.map (fun (key, old) -> (key, if key = name then value else old)) fields

let golden () =
  let owner =
    checked (make "linear:project" "opaque-id" "SYM-1" Int64.min_int (-1L))
  in
  Alcotest.(check string)
    "all 64-bit identity bits" (json fields)
    (Workspace_owner.encode owner);
  let parsed = checked (Workspace_owner.parse (json (List.rev fields))) in
  Alcotest.(check bool)
    "field order is immaterial" true
    (Workspace_owner.equal owner parsed);
  Alcotest.(check string)
    "canonical field order" (json fields)
    (Workspace_owner.encode parsed)

let rejections () =
  let invalid =
    [
      "";
      "null";
      "[]";
      "{}";
      "not JSON";
      json (List.remove_assoc "issue_id" fields);
      json (("unknown", `Null) :: fields);
      json (("scope", `String "other") :: fields);
      json (replace "version" (`Int 2));
      json (replace "version" (`Float 1.0));
      json (replace "version" (`Intlit "1e0"));
      json (replace "version" (`String "1"));
      json (replace "scope" (`String "  \n"));
      json (replace "issue_id" (`String ""));
      json (replace "issue_id" (`String "bad\000id"));
      json (replace "identifier" (`String "."));
      json (replace "identifier" (`String ".."));
      json (replace "identifier" (`String (String.make 256 'a')));
      json (replace "device" (`String "800000000000000A"));
      json (replace "device" (`String "0"));
      json (replace "inode" (`String "0xffffffffffffffff"));
      json (replace "inode" (`Int 1));
      json (replace "scope" (`String "\255"));
      json
        (replace "scope" (`String (String.make Workspace_owner.max_bytes 'a')));
    ]
  in
  List.iter
    (fun source ->
      match Workspace_owner.parse source with
      | Error message ->
          Alcotest.(check bool) "actionable error" true (message <> "")
      | Ok _ -> Alcotest.fail "invalid owner accepted")
    invalid;
  let canonical = json fields in
  let at_limit =
    canonical
    ^ String.make (Workspace_owner.max_bytes - String.length canonical) ' '
  in
  ignore (checked (Workspace_owner.parse at_limit));
  match Workspace_owner.parse (at_limit ^ " ") with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "oversized raw record accepted"

let owner_changes () =
  let original = checked (Workspace_owner.parse (json fields)) in
  let changes =
    [
      ("scope", `String "linear:other");
      ("issue_id", `String "recreated-id");
      ("identifier", `String "sym-1");
      ("device", `String "0000000000000000");
      ("inode", `String "0000000000000000");
    ]
  in
  List.iter
    (fun (name, value) ->
      let changed =
        checked (Workspace_owner.parse (json (replace name value)))
      in
      Alcotest.(check bool)
        ("ownership changes with " ^ name)
        false
        (Workspace_owner.equal original changed))
    changes

let encoding_bound () =
  let build issue_id = make "linear:project" issue_id "SYM-1" 0L 0L in
  let baseline = Workspace_owner.encode (checked (build "x")) in
  let id_bytes = Workspace_owner.max_bytes - String.length baseline + 1 in
  let at_limit = checked (build (String.make id_bytes 'a')) in
  Alcotest.(check int)
    "exact encoded bound" Workspace_owner.max_bytes
    (String.length (Workspace_owner.encode at_limit));
  List.iter
    (fun identity ->
      match build identity with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "oversized owner encoding accepted")
    [
      String.make (id_bytes + 1) 'a';
      String.make id_bytes '"';
      String.make (Workspace_owner.max_bytes + 1) 'a';
    ]

let tests =
  [
    Alcotest.test_case "canonical ownership preserves signed OS identity bits"
      `Quick golden;
    Alcotest.test_case "owner parser rejects unsafe fields and bounds raw input"
      `Quick rejections;
    Alcotest.test_case "every owner component distinguishes reuse" `Quick
      owner_changes;
    Alcotest.test_case "constructor charges escaped JSON at the byte bound"
      `Quick encoding_bound;
  ]

let samples = 1000
let valid_generator = QCheck2.Gen.(triple (int_range 0 99) int64 int64)

let roundtrip (tag, device, inode) =
  let scope = "linear:project-" ^ string_of_int tag in
  let issue_id = "opaque-" ^ string_of_int tag in
  let identifier = if tag mod 2 = 0 then "SYM-1" else "A/é" in
  let original = checked (make scope issue_id identifier device inode) in
  let encoded = Workspace_owner.encode original in
  match Workspace_owner.parse encoded with
  | Error _ -> false
  | Ok parsed ->
      Workspace_owner.equal original parsed
      && String.equal encoded (Workspace_owner.encode parsed)
      && String.length encoded <= Workspace_owner.max_bytes

let raw_generator =
  QCheck2.Gen.(
    map
      (fun (name, value) -> `Assoc (replace name value))
      (pair
         (oneof_list
            [ "version"; "scope"; "issue_id"; "identifier"; "device"; "inode" ])
         (oneof_list
            [
              `Int 1;
              `Int 2;
              `Null;
              `Bool true;
              `Float 1.0;
              `Intlit "1e0";
              `String "";
              `String "SYM-1";
              `String "A/B";
              `String "é";
              `String ".";
              `String "opaque\000id";
              `String "0000000000000000";
              `String "ffffffffffffffff";
              `String "FFFFFFFFFFFFFFFF";
            ])))

let agrees input =
  match
    (Model.of_json input, Workspace_owner.parse (Yojson.Safe.to_string input))
  with
  | None, Error _ -> true
  | Some expected, Ok actual -> Model.equal expected (observe actual)
  | None, Ok _ | Some _, Error _ -> false

let properties =
  [
    QCheck2.Test.make ~count:samples
      ~name:"owner roundtrip and canonical encoding" valid_generator roundtrip;
    QCheck2.Test.make ~count:samples
      ~name:"owner parser agrees with structural JSON model" raw_generator
      agrees;
  ]
