let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let identifier raw = checked (Issue_identifier.parse raw)
let derive raw = Workspace_key.of_identifier (identifier raw)
let key raw = checked (derive raw)
let max_component_bytes = 255
let law_samples = 1000

(* Python hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32], retained here
   without deriving expected hashes through the implementation or its library. *)
let golden =
  [
    ("A/B", "A_B-998d3ed8983acf3905221679bd780342");
    ("A B", "A_B-fea4c5ce720c1d6a1cbc47c1607cc4ea");
    ("A\\B", "A_B-edc0916552f4dbb224da7a63ebb17d9c");
    (" A ", "_A_-e81218e5f07d70f27691b1c553a2dd44");
    ("A\tB", "A_B-34d0e593db2e19f3846171ea117f698e");
    ("A\nB", "A_B-23519a43c66b4c342f25b32e09797ec5");
    ("é", "__-4a99557e4033c3539de2eb65472017ca");
    ("é", "e__-bf12767b0f2a56b2190075bae8169f65");
    ("🧪", "____-0db66ddb1ed9d843f2aff1fc93ea4321");
    ("x:y", "x_y-1274e286686b54fe765ec40735665b4b");
    ("/", "_-8a5edab282632443219e051e4ade2d1d");
    ("../A", ".._A-80dd850293b12572df6a4930afec0584");
    ( String.make 221 'a' ^ "/",
      String.make 221 'a' ^ "_-05ed2b58eadf654ba842919c47e2f95f" );
  ]

let vectors () =
  List.iter
    (fun (raw, expected) ->
      Alcotest.(check string)
        (Text.escape raw) expected
        (Workspace_key.text (key raw));
      match Workspace_key_model.derive raw with
      | Ok actual -> Alcotest.(check string) "reference vector" expected actual
      | Error _ -> Alcotest.fail "reference model rejected valid vector")
    golden

let limits () =
  List.iter
    (fun raw ->
      Alcotest.(check string)
        "safe bytes unchanged" raw
        (Workspace_key.text (key raw)))
    [ "SYM-1"; "AbC_09.-"; "..."; String.make max_component_bytes 'a' ];
  List.iter
    (fun raw ->
      Alcotest.(check bool)
        "invalid component rejected" true
        (Result.is_error (derive raw)))
    [
      ".";
      "..";
      String.make (max_component_bytes + 1) 'a';
      String.make 222 'a' ^ "/";
    ];
  Alcotest.(check bool)
    "empty identity rejected upstream" true
    (Result.is_error (Issue_identifier.parse ""))

let aliases () =
  List.iter
    (fun (raw, literal) ->
      Alcotest.(check int)
        "hash/literal alias requires ownership checking" 0
        (Workspace_key.compare (key raw) (key literal)))
    golden;
  Alcotest.(check bool)
    "byte order retains case identity" true
    (Workspace_key.compare (key "SYM-1") (key "sym-1") <> 0)

let tests =
  [
    Alcotest.test_case "independent SHA-256 key vectors" `Quick vectors;
    Alcotest.test_case "component and suffix length boundaries" `Quick limits;
    Alcotest.test_case "literal hashes and case need acquisition ownership"
      `Quick aliases;
  ]

let fragments = [ "A"; "z"; "0"; "."; "_"; "-"; "/"; "\\"; " "; "\t"; "é"; "🧪" ]

let mixed maximum =
  QCheck2.Gen.(
    map
      (fun values -> "K" ^ String.concat "" values)
      (list_size (int_range 0 maximum) (oneof_list fragments)))

let safe =
  QCheck2.Gen.(
    string_size
      ~gen:
        (oneof_list
           (List.of_seq
              (String.to_seq
                 "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")))
      (int_range 1 300))

let boundary_inputs = mixed 100

let agrees raw =
  match (derive raw, Workspace_key_model.derive raw) with
  | Ok actual, Ok expected -> String.equal (Workspace_key.text actual) expected
  | Error _, Error _ -> true
  | Ok _, Error _ | Error _, Ok _ -> false

let canonical raw =
  match derive raw with
  | Error _ -> true
  | Ok original -> (
      match derive (Workspace_key.text original) with
      | Error _ -> false
      | Ok repeated -> Workspace_key.compare original repeated = 0)

let order (left, (middle, right)) =
  let a, b, c = (key left, key middle, key right) in
  let ab = Workspace_key.compare a b in
  let ba = Workspace_key.compare b a in
  let bc = Workspace_key.compare b c in
  let ac = Workspace_key.compare a c in
  Workspace_key.compare a a = 0
  && Int.compare ab 0
     = Int.compare
         (String.compare (Workspace_key.text a) (Workspace_key.text b))
         0
  && Int.compare ab 0 = Int.compare 0 ba
  && (ab > 0 || bc > 0 || ac <= 0)
  && (ab >= 0 || ba >= 0)
  && ab = 0 = String.equal (Workspace_key.text a) (Workspace_key.text b)

let properties =
  [
    QCheck2.Test.make ~name:"workspace key agrees with byte-list model"
      ~count:law_samples boundary_inputs agrees;
    QCheck2.Test.make ~name:"safe identifier derivation agrees with model"
      ~count:law_samples safe agrees;
    QCheck2.Test.make ~name:"workspace key reimport is idempotent"
      ~count:law_samples boundary_inputs canonical;
    QCheck2.Test.make ~name:"workspace byte order is total"
      ~count:(2 * law_samples)
      QCheck2.Gen.(pair (mixed 20) (pair (mixed 20) (mixed 20)))
      order;
  ]
