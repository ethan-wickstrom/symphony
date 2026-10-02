module F = Service_failure

exception Callback_defect of int

type Eio.Exn.err += First_io | Middle_io | Last_io
type observation = Success | Error | Defect | Shared_defect | Io

let model entries =
  List.find_map
    (function
      | Success, _ -> None
      | (Error | Defect | Shared_defect | Io), outcome -> Some outcome)
    entries

let secondary_model observations =
  let rec after_first = function
    | [] -> []
    | (_, Success) :: rest -> after_first rest
    | (_, (Error | Defect | Shared_defect | Io)) :: rest ->
        List.filter_map
          (function
            | key, (Defect | Shared_defect | Io) -> Some key
            | _, (Success | Error) -> None)
          rest
  in
  after_first
    (List.mapi (fun key observation -> (key, observation)) observations)

let agrees observations =
  let register = F.create () in
  let shared = Callback_defect (-1) in
  let io = Eio.Exn.create First_io in
  (* Distinct identities make replacing the first Error with a later Error
     observable, even when both failures have the same constructor. *)
  let entries =
    List.mapi
      (fun index observation ->
        let outcome =
          match observation with
          | Success -> F.Returned (Ok ())
          | Error ->
              F.Returned
                (Error
                   (Diagnostic.make ~site:(Diagnostic.Host "failure model")
                      ~message:("observation " ^ string_of_int index)
                      ~remedy:"Retain the first failed observation."))
          | Defect -> F.Raised (Callback_defect index, Printexc.get_callstack 8)
          | Shared_defect -> F.Raised (shared, Printexc.get_callstack 8)
          | Io ->
              let error =
                match io with
                | Eio.Io (error, context) -> Eio.Io (error, context)
                | _ -> Alcotest.fail "Expected an IO failure"
              in
              F.Raised (error, Printexc.get_callstack 8)
        in
        (observation, outcome))
      observations
  in
  List.iteri (fun key (_, outcome) -> F.record register key outcome) entries;
  let reports = ref [] in
  let flush () =
    F.flush register ~describe:string_of_int ~report:(fun key _ ->
        reports := key :: !reports)
  in
  flush ();
  flush ();
  List.rev !reports = secondary_model observations
  &&
  match (model entries, F.prefer register (F.Returned (Ok ()))) with
  | None, F.Returned (Ok ()) -> not (F.failed register)
  | Some (F.Returned (Error expected)), F.Returned (Error actual) ->
      actual == expected
  | Some (F.Raised (expected, origin)), F.Raised (actual, trace) ->
      actual == expected && trace == origin
  | ( (None | Some (F.Returned (Ok () | Error _) | F.Raised _)),
      (F.Returned (Ok () | Error _) | F.Raised _) ) -> false

let properties =
  let open QCheck2 in
  [
    Test.make ~name:"failure register preserves first failure and later reports"
      ~count:1000
      ~print:(fun observations ->
        String.concat ","
          (List.map
             (function
               | Success -> "success"
               | Error -> "error"
               | Defect -> "defect"
               | Shared_defect -> "shared-defect"
               | Io -> "io")
             observations))
      (Gen.list_size (Gen.int_range 0 100)
         (Gen.oneof_list [ Success; Error; Defect; Shared_defect; Io ]))
      agrees;
  ]

exception First_cleanup of string
exception Last_cleanup of string

let aggregate failures =
  Eio_mock.Backend.run (fun () ->
      match
        F.capture (fun () ->
            Eio.Switch.run (fun sw ->
                List.iter
                  (fun error ->
                    Eio.Switch.on_release sw (fun () -> raise error))
                  (List.rev failures)))
      with
      | F.Raised (error, backtrace) -> (error, backtrace)
      | F.Returned () -> Alcotest.fail "Cleanup failures disappeared")

let io_order () =
  let first = Eio.Exn.create First_io in
  let middle = Eio.Exn.create Middle_io in
  let last = Eio.Exn.create Last_io in
  let values = Eio_failure.leaves (aggregate [ first; middle; last ]) in
  let labels =
    List.map
      (function
        | Eio.Io (First_io, _), _ -> "first"
        | Eio.Io (Middle_io, _), _ -> "middle"
        | Eio.Io (Last_io, _), _ -> "last"
        | _ -> "unexpected")
      values
  in
  Alcotest.(check (list string))
    "actual IO cleanup observation order"
    [ "first"; "middle"; "last" ]
    labels

let reported ~primary error =
  let register = F.create () in
  F.retain register (F.secondary () ~primary error);
  let messages = ref [] in
  F.flush register
    ~describe:(fun () -> "test")
    ~report:(fun () diagnostic ->
      messages := Diagnostic.render diagnostic :: !messages);
  List.rev !messages

let aggregate_order () =
  let first = First_cleanup "private-first" in
  let last = Last_cleanup "private-last" in
  let aggregate, _ = aggregate [ first; last ] in
  Alcotest.(check (list string))
    "actual cleanup order and redacted leaves"
    (reported ~primary:[] first @ reported ~primary:[] last)
    (reported ~primary:[] aggregate)

let io_primary () =
  let first = Eio.Exn.create First_io in
  let last = Eio.Exn.create Last_io in
  let aggregate, _ = aggregate [ first; last ] in
  Alcotest.(check int)
    "normalized IO primary is not reported again" 1
    (List.length (reported ~primary:[ first ] aggregate));
  Alcotest.(check int)
    "both IO cleanup leaves are retained" 2
    (List.length (reported ~primary:[] aggregate))

let io_occurrences () =
  let first = Eio.Exn.create First_io in
  let second =
    match first with
    | Eio.Io (error, context) -> Eio.Io (error, context)
    | _ -> Alcotest.fail "Expected an IO failure"
  in
  Alcotest.(check bool) "independent IO wrapper identity" false (first == second);
  let errors, _ = aggregate [ first; second ] in
  Alcotest.(check int)
    "suppress one primary, retain the later identical IO" 1
    (List.length (reported ~primary:[ first ] errors))

let independent_failures () =
  let register = F.create () in
  let first = Eio.Exn.create First_io in
  let second =
    match first with
    | Eio.Io (error, context) -> Eio.Io (error, context)
    | _ -> Alcotest.fail "Expected an IO failure"
  in
  let reports = ref [] in
  List.iteri
    (fun key error ->
      F.record register key (F.Raised (error, Printexc.get_callstack 8)))
    [ first; second; first ];
  F.flush register ~describe:string_of_int ~report:(fun key _ ->
      reports := key :: !reports);
  Alcotest.(check (list int))
    "independent observations survive shared payloads and exception values"
    [ 1; 2 ] (List.rev !reports)

let reporter_drain () =
  let register = F.create () in
  let original = Callback_defect 83 in
  let reports = ref [] in
  let report key _diagnostic =
    reports := key :: !reports;
    if key = 1 then raise original
  in
  F.retain register (F.secondary 1 ~primary:[] (First_cleanup "private"));
  F.retain register (F.secondary 2 ~primary:[] (Last_cleanup "private"));
  F.flush register ~describe:string_of_int ~report;
  F.flush register ~describe:string_of_int ~report;
  Alcotest.(check (list int))
    "remaining reports run once after reporter failure" [ 1; 2 ]
    (List.rev !reports);
  match F.prefer register (F.Returned (Ok ())) with
  | F.Raised (error, _) ->
      Alcotest.(check bool)
        "first reporter failure retained" true (error == original)
  | F.Returned _ -> Alcotest.fail "Reporter failure disappeared"

let tests =
  [
    Alcotest.test_case "independent failures are never deduplicated" `Quick
      independent_failures;
    Alcotest.test_case "normalization retains distinct same-kind IO occurrences"
      `Quick io_occurrences;
    Alcotest.test_case "reporter failure drains remaining reports exactly once"
      `Quick reporter_drain;
    Alcotest.test_case "actual IO aggregates retain observation order" `Quick
      io_order;
    Alcotest.test_case "actual exception aggregates retain observation order"
      `Quick aggregate_order;
    Alcotest.test_case "IO aggregation preserves leaves and primary identity"
      `Quick io_primary;
  ]
