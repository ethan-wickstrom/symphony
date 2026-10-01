let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let json fields = checked (Json.of_view (Json.Object fields))
let string text = checked (Json.of_view (Json.String text))
let omission reason fields = Linear_omission.make reason (json fields)

let identity warning =
  Linear_omission.identity_text (Linear_omission.identity warning)

let rendered warning = Diagnostic.render (Linear_omission.diagnostic warning)

let partial_identities () =
  let make fields = omission Linear_omission.Invalid_record fields in
  List.iter
    (fun (fields, expected) ->
      Alcotest.check Alcotest.string "checked projection" expected
        (identity (make fields)))
    [
      ([], "unknown");
      ([ ("id", string "id-1") ], "issue_id=\"id-1\"");
      ([ ("identifier", string "FIX-1") ], "issue_identifier=\"FIX-1\"");
      ( [ ("id", string "id-1"); ("identifier", string "FIX-1") ],
        "issue_id=\"id-1\" issue_identifier=\"FIX-1\"" );
      ([ ("id", string " "); ("identifier", string "\000") ], "unknown");
    ]

let bounded_hash () =
  let warning =
    omission Linear_omission.Record_rejected
      [ ("id", string (String.make 129 'a')) ]
  in
  Alcotest.check Alcotest.string "exact bytes SHA256"
    "issue_id=sha256:c12cb024a2e5551cca0e08fce8f1c5e314555cc3fef6329ee994a3db752166ae"
    (identity warning);
  let same_prefix = String.make 128 'a' in
  let changed =
    omission Linear_omission.Record_rejected
      [ ("id", string (same_prefix ^ "b")) ]
  in
  Alcotest.(check bool)
    "suffix changes provenance" false
    (identity warning = identity changed)

let no_payload () =
  let expected =
    omission (Linear_omission.Missing_field Linear_omission.Title)
      [ ("id", string "id-1") ]
  in
  let extra =
    omission (Linear_omission.Missing_field Linear_omission.Title)
      [
        ("id", string "id-1");
        ("description", string "untrusted repository text");
        ("api_key", string "fixture-secret");
        ("native_ref", string "opaque-provider-payload");
      ]
  in
  Alcotest.check Alcotest.string "only checked identity survives"
    (rendered expected) (rendered extra)

let named_keys () =
  let warning =
    omission (Linear_omission.Wrong_type Linear_omission.State) []
  in
  Alcotest.(check bool)
    "closed reason survives" true
    (Linear_omission.reason warning
    = Linear_omission.Wrong_type Linear_omission.State);
  Alcotest.(check bool)
    "key and remedy present" true
    (Re.execp (Re.compile (Re.str "state")) (rendered warning))

let tests =
  [
    Alcotest.test_case "partial checked identity" `Quick partial_identities;
    Alcotest.test_case "oversized identity preserves hashed provenance" `Quick
      bounded_hash;
    Alcotest.test_case "other provider fields cannot reach warning" `Quick
      no_payload;
    Alcotest.test_case "reason names rejected key" `Quick named_keys;
  ]

let ascii =
  QCheck2.Gen.map
    (fun bytes -> String.of_seq (List.to_seq (List.map Char.chr bytes)))
    QCheck2.Gen.(list_size (int_range 0 4096) (int_range 0 127))

let properties =
  [
    QCheck2.Test.make
      ~name:"warning projection is bounded and ignores other fields" ~count:1000
      (QCheck2.Gen.pair ascii ascii) (fun (id, identifier) ->
        let fields = [ ("id", string id); ("identifier", string identifier) ] in
        let first = omission Linear_omission.Record_rejected fields in
        let second =
          omission Linear_omission.Record_rejected
            (("description", string "untrusted payload") :: fields)
        in
        String.length (identity first) <= 2048
        && String.length (rendered first) <= 4096
        && identity first = identity second
        && rendered first = rendered second
        && Linear_omission.reason first = Linear_omission.Record_rejected);
  ]
