module Frame = Protocol_frame
module Model = Protocol_frame_model

let profile_max_bytes = 1_048_576
let property_cases = 500
let property_seed = 20261003
let max_fragments = 24
let max_fragment_bytes = 64
let one_byte_payload = 65_536

let category = function
  | Frame.Oversized _ -> Model.Oversized
  | Frame.Invalid_json _ -> Model.Invalid_json
  | Frame.Truncated _ -> Model.Truncated

let name = function
  | None -> "accepted"
  | Some Model.Oversized -> "oversized"
  | Some Model.Invalid_json -> "invalid JSON"
  | Some Model.Truncated -> "truncated"

let rec same_frames left right =
  match (left, right) with
  | [], [] -> true
  | first :: rest, other :: remaining ->
      Json.equal first other && same_frames rest remaining
  | [], _ :: _ | _ :: _, [] -> false

let agrees left right =
  same_frames left.Model.frames right.Model.frames
  && left.Model.failure = right.Model.failure

let check label expected actual =
  Alcotest.check Alcotest.bool
    (label ^ ": accepted prefix")
    true
    (same_frames expected.Model.frames actual.Model.frames);
  Alcotest.check Alcotest.string
    (label ^ ": terminal category")
    (name expected.Model.failure)
    (name actual.Model.failure)

let finish frames state =
  let failure =
    match Frame.finish state with
    | Ok () -> None
    | Error error -> Some (category error)
  in
  { Model.frames = List.rev frames; failure }

let decode chunks =
  let rec read frames state = function
    | [] -> finish frames state
    | chunk :: rest -> (
        let batch = Frame.feed state chunk in
        let frames = List.rev_append batch.Frame.frames frames in
        match batch.Frame.next with
        | Frame.Open next -> read frames next rest
        | Frame.Failed error ->
            { Model.frames = List.rev frames; failure = Some (category error) })
  in
  read [] Frame.empty chunks

let branch state suffix =
  let batch = Frame.feed state suffix in
  match batch.Frame.next with
  | Frame.Open state -> finish (List.rev batch.Frame.frames) state
  | Frame.Failed error ->
      { Model.frames = batch.Frame.frames; failure = Some (category error) }

let oracle input = Model.observe ~max_bytes:profile_max_bytes input

let split ~width input =
  let length = String.length input in
  let rec cut offset reversed =
    if offset = length then List.rev reversed
    else
      let count = min width (length - offset) in
      cut (offset + count) (String.sub input offset count :: reversed)
  in
  cut 0 []

let check_widths input widths =
  let expected = oracle input in
  List.iter
    (fun width ->
      check
        ("width " ^ string_of_int width)
        expected
        (decode (split ~width input)))
    widths

let check_splits input =
  let length = String.length input in
  let expected = oracle input in
  for offset = 0 to length do
    let left = String.sub input 0 offset in
    let right = String.sub input offset (length - offset) in
    check
      ("split " ^ string_of_int offset)
      expected
      (decode [ ""; left; ""; right; "" ])
  done

let profile_bound () =
  Alcotest.check Alcotest.int "selected profile ceiling" profile_max_bytes
    Frame.max_bytes

let utf8_and_crlf () =
  (* Cuts include the middle of each UTF-8 character and the CR/LF boundary. *)
  let wire = "{\"text\":\"λ🙂\"}\r\n[1,2]\n\"a\\nb\"\r\n" in
  check_splits wire;
  check_widths wire [ 1; 2; 3; 7; 4096 ]

let frame_order () =
  let wire = "null\nfalse\n0\n{}\n[]\n\"text\"\n" in
  check_splits wire;
  check_widths wire [ 1; 3; 4096 ]

let malformed_prefix () =
  let accepted = "{\"before\":1}\n[2]\n" in
  let rejected =
    [
      "\n";
      " \t\n";
      "\r\n";
      "{\"same\":1,\"same\":2}\n";
      "{\"nested\":{\"same\":1,\"same\":2}}\n";
      "{broken}\n";
      "\"\xC3\x28\"\n";
      "\"\xC0\xAF\"\n";
      "NaN\n";
    ]
  in
  List.iter
    (fun bad ->
      let wire = accepted ^ bad ^ "{\"after\":3}\n" in
      let expected = oracle wire in
      Alcotest.check Alcotest.string "oracle rejects malformed line"
        "invalid JSON"
        (name expected.Model.failure);
      Alcotest.check Alcotest.int "accepted prefix has two frames" 2
        (List.length expected.Model.frames);
      check_splits wire)
    rejected

let eof_is_truncation () =
  check "empty EOF" (oracle "") (decode []);
  List.iter
    (fun residual ->
      let wire = "{\"before\":1}\n" ^ residual in
      let expected = oracle wire in
      Alcotest.check Alcotest.string "unterminated residual" "truncated"
        (name expected.Model.failure);
      check_splits wire)
    [ "{}"; "0"; " "; "\r"; "{\"open\":"; "\"\xE2" ]

let string_frame bytes = "\"" ^ String.make (bytes - 2) 'x' ^ "\""

let exact_ceiling () =
  let exact = string_frame profile_max_bytes in
  let crlf = string_frame (profile_max_bytes - 1) ^ "\r\n" in
  let prefix = "{\"before\":1}\n" in
  check_widths (exact ^ "\n") [ 4096; profile_max_bytes ];
  check_widths crlf [ 4096; profile_max_bytes ];
  check_widths (prefix ^ exact ^ "\nnull\n") [ 4096; profile_max_bytes ];
  check "exact residual still needs LF" (oracle exact) (decode [ exact ]);
  (* The newline cannot rescue a line that already crossed the byte ceiling. *)
  List.iter
    (fun rejected ->
      let wire = prefix ^ rejected ^ "\n{\"after\":2}\n" in
      let expected = oracle wire in
      Alcotest.check Alcotest.string "ceiling rejects one extra byte"
        "oversized"
        (name expected.Model.failure);
      Alcotest.check Alcotest.int "accepted prefix survives ceiling" 1
        (List.length expected.Model.frames);
      check_widths wire [ 4096; profile_max_bytes; profile_max_bytes + 1 ])
    [ exact ^ "\r"; string_frame (profile_max_bytes + 1) ];
  let oversized = String.make (profile_max_bytes + 1) 'x' in
  check "oversized before EOF"
    (oracle (prefix ^ oversized))
    (decode [ prefix; oversized ])

let empty_and_branching () =
  let prefix = "{\"branch\":" in
  let batch = Frame.feed Frame.empty prefix in
  Alcotest.check Alcotest.int "partial prefix emits no frame" 0
    (List.length batch.Frame.frames);
  match batch.Frame.next with
  | Frame.Failed _ -> Alcotest.fail "partial prefix was rejected"
  | Frame.Open state -> (
      let empty = Frame.feed state "" in
      Alcotest.check Alcotest.int "empty chunk emits no frame" 0
        (List.length empty.Frame.frames);
      let check_branch suffix =
        check suffix (oracle (prefix ^ suffix)) (branch state suffix)
      in
      check_branch "1}\n";
      check_branch "2}\n";
      check_branch "bad}\n";
      check_branch "1}\n";
      check "original state persists" (oracle prefix) (finish [] state);
      match empty.Frame.next with
      | Frame.Failed _ -> Alcotest.fail "empty chunk was rejected"
      | Frame.Open preserved ->
          check "empty chunk preserves state" (oracle prefix)
            (finish [] preserved);
          check "empty chunk preserves future frames"
            (oracle (prefix ^ "1}\n"))
            (branch preserved "1}\n"))

let one_byte_reads () =
  let wire = string_frame one_byte_payload ^ "\n{\"after\":1}\n" in
  let length = String.length wire in
  let rec read offset frames state =
    if offset = length then finish frames state
    else
      let batch = Frame.feed state (String.sub wire offset 1) in
      let frames = List.rev_append batch.Frame.frames frames in
      match batch.Frame.next with
      | Frame.Open next -> read (offset + 1) frames next
      | Frame.Failed error ->
          { Model.frames = List.rev frames; failure = Some (category error) }
  in
  check "one-byte stream" (oracle wire) (read 0 [] Frame.empty)

let properties () =
  let property name generator law =
    (name, QCheck2.Test.make ~name ~count:property_cases generator law)
  in
  let fragments =
    QCheck2.Gen.(
      list_size
        (int_range 0 max_fragments)
        (string_size (int_range 0 max_fragment_bytes)))
  in
  let atoms = [ "null"; "0"; "true"; "[]"; "{}"; "\"λ🙂\""; "{\"id\":7}" ] in
  let tails =
    [
      "";
      "{}";
      " \n";
      "{bad}\nnull\n";
      "{\"id\":1,\"id\":2}\nnull\n";
      "\"\xC3\x28\"\nnull\n";
    ]
  in
  let records =
    QCheck2.Gen.(
      pair
        (list_size (int_range 0 max_fragments) (oneof_list atoms))
        (pair (oneof_list tails) (int_range 1 max_fragment_bytes)))
  in
  [
    property "arbitrary byte fragments agree with split-lines oracle" fragments
      (fun chunks -> agrees (oracle (String.concat "" chunks)) (decode chunks));
    property "JSON records and rejected tails preserve order under partition"
      records (fun (lines, (tail, width)) ->
        let wire = String.concat "\r\n" lines in
        let wire = if lines = [] then tail else wire ^ "\r\n" ^ tail in
        agrees (oracle wire) (decode (split ~width wire)));
    property
      "partial states retain independent branches and empty-chunk identity"
      QCheck2.Gen.(
        triple
          (int_range 0 max_fragment_bytes)
          (int_range 0 1_000_000) (int_range 0 1_000_000))
      (fun (spaces, first, second) ->
        let prefix = String.make spaces ' ' ^ "{\"value\":" in
        let batch = Frame.feed Frame.empty prefix in
        match batch.Frame.next with
        | Frame.Failed _ -> false
        | Frame.Open state -> (
            let a = string_of_int first ^ "}\n" in
            let b = string_of_int second ^ "}\n" in
            let empty = Frame.feed state "" in
            agrees (oracle (prefix ^ a)) (branch state a)
            && agrees (oracle (prefix ^ b)) (branch state b)
            && agrees (oracle prefix) (finish [] state)
            &&
            match empty.Frame.next with
            | Frame.Failed _ -> false
            | Frame.Open preserved ->
                empty.Frame.frames = []
                && agrees (oracle (prefix ^ a)) (branch preserved a)));
  ]

let suite () =
  Printf.printf "protocol frame property seed: %d\n%!" property_seed;
  let example = Alcotest.test_case in
  let examples =
    [
      example "selected profile byte ceiling" `Quick profile_bound;
      example "UTF-8 and CRLF survive every split" `Quick utf8_and_crlf;
      example "coalesced primitive frames preserve order" `Quick frame_order;
      example "malformed lines preserve only the accepted prefix" `Quick
        malformed_prefix;
      example "EOF rejects every unterminated residual" `Quick eof_is_truncation;
      example "byte ceiling counts CR and excludes LF" `Quick exact_ceiling;
      example "empty chunks and branching states remain persistent" `Quick
        empty_and_branching;
      example "long frames survive one-byte reads" `Quick one_byte_reads;
    ]
  in
  let laws =
    List.map
      (fun (name, test) ->
        example name `Quick (fun () ->
            QCheck2.Test.check_exn
              ~rand:(Random.State.make [| property_seed |])
              test))
      (properties ())
  in
  ("protocol framing", examples @ laws)
