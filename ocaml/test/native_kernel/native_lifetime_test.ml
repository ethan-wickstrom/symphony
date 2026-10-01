module Ids = Set.Make (Int)

type behavior = Complete | Reject | Fail | External_cancel | Until_close

type node = {
  id : int;
  behavior : behavior;
  yields : int;
  order : int;
  ready : unit Eio.Promise.t;
  ready_resolver : unit Eio.Promise.u;
  cancellation : Eio.Cancel.t Eio.Promise.t;
  cancel_resolver : Eio.Cancel.t Eio.Promise.u;
  done_ : unit Eio.Promise.t;
  done_resolver : unit Eio.Promise.u;
  defect : exn;
}

type model = {
  mutable entered : Ids.t;
  mutable active : Ids.t;
  mutable finished : Ids.t;
}

let seed_count = 1_000

let rec yield count =
  if count > 0 then (
    Eio.Fiber.yield ();
    yield (count - 1))

let check seed label expected actual =
  if expected <> actual then Alcotest.failf "seed=%d: %s" seed label

let make_node random id =
  let ready, ready_resolver = Eio.Promise.create () in
  let cancellation, cancel_resolver = Eio.Promise.create () in
  let done_, done_resolver = Eio.Promise.create () in
  let behavior =
    match Random.State.int random 5 with
    | 0 -> Complete
    | 1 -> Reject
    | 2 -> Fail
    | 3 -> External_cancel
    | _ -> Until_close
  in
  {
    id;
    behavior;
    yields = Random.State.int random 4;
    order = Random.State.int random 1_000;
    ready;
    ready_resolver;
    cancellation;
    cancel_resolver;
    done_;
    done_resolver;
    defect = Failure (Printf.sprintf "scope-%d" id);
  }

let dispatch_order a b =
  match Int.compare a.order b.order with
  | 0 -> Int.compare a.id b.id
  | order -> order

let check_outcome seed node = function
  | Ok (Ok id) ->
      check seed "successful scope returned its ID" node.id id;
      check seed "only Complete succeeds" Complete node.behavior
  | Ok (Error Native_lifetime.Closed) ->
      check seed "only owner closure becomes Closed" Until_close node.behavior
  | Ok (Error (Native_lifetime.Rejected id)) ->
      check seed "callback rejection retains its ID" node.id id;
      check seed "only Reject returns expected failure" Reject node.behavior
  | Error (Eio.Cancel.Cancelled cause) ->
      check seed "external cancellation mode" External_cancel node.behavior;
      check seed "external cause identity" true (cause == node.defect)
  | Error error ->
      check seed "original defect mode" Fail node.behavior;
      check seed "original defect identity" true (error == node.defect)

let scenario seed =
  let random = Random.State.make [| seed |] in
  let count = Random.State.int random 11 in
  let nodes = List.init count (make_node random) |> List.sort dispatch_order in
  let expected =
    List.fold_left (fun ids node -> Ids.add node.id ids) Ids.empty nodes
  in
  Eio_mock.Backend.run (fun () ->
      let reports = ref [] in
      let lifetime =
        Native_lifetime.create ~report:(fun failure ->
            reports := failure :: !reports)
      in
      let model =
        { entered = Ids.empty; active = Ids.empty; finished = Ids.empty }
      in
      Eio.Switch.run (fun sw ->
          List.iter
            (fun node ->
              Eio.Fiber.fork ~sw (fun () ->
                  let outcome =
                    try
                      Ok
                        (Eio.Cancel.sub (fun cancel ->
                             Eio.Promise.resolve node.cancel_resolver cancel;
                             Native_lifetime.with_scope lifetime
                               (fun ~sw:child ->
                                 check seed "callback admitted once" false
                                   (Ids.mem node.id model.entered);
                                 model.entered <- Ids.add node.id model.entered;
                                 model.active <- Ids.add node.id model.active;
                                 Eio.Switch.on_release child (fun () ->
                                     yield (node.yields + 1);
                                     model.active <-
                                       Ids.remove node.id model.active;
                                     check seed "scope released once" false
                                       (Ids.mem node.id model.finished);
                                     model.finished <-
                                       Ids.add node.id model.finished);
                                 Eio.Promise.resolve node.ready_resolver ();
                                 yield node.yields;
                                 match node.behavior with
                                 | Complete -> Ok node.id
                                 | Reject -> Error node.id
                                 | Fail -> raise node.defect
                                 | External_cancel | Until_close ->
                                     Eio.Fiber.await_cancel ())))
                    with error -> Error error
                  in
                  check_outcome seed node outcome;
                  Eio.Promise.resolve node.done_resolver ()))
            nodes;
          List.iter (fun node -> Eio.Promise.await node.ready) nodes;
          List.iter
            (fun node ->
              match node.behavior with
              | External_cancel ->
                  Eio.Cancel.cancel
                    (Eio.Promise.await node.cancellation)
                    node.defect;
                  Eio.Promise.await node.done_
              | Complete | Reject | Fail -> Eio.Promise.await node.done_
              | Until_close -> ())
            nodes;
          check seed "Held before closing" true (Native_lifetime.held lifetime);
          let remaining =
            List.fold_left
              (fun ids node ->
                match node.behavior with
                | Until_close -> Ids.add node.id ids
                | Complete | Reject | Fail | External_cancel -> ids)
              Ids.empty nodes
          in
          check seed "reference active IDs before close" true
            (Ids.equal remaining model.active);
          let first, first_resolver = Eio.Promise.create () in
          let second, second_resolver = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
              Native_lifetime.close lifetime;
              Eio.Promise.resolve first_resolver ());
          Eio.Fiber.fork ~sw (fun () ->
              Native_lifetime.close lifetime;
              Eio.Promise.resolve second_resolver ());
          check seed "close revokes admission" false
            (Native_lifetime.held lifetime);
          let invoked = ref false in
          let rejected =
            Native_lifetime.with_scope lifetime (fun ~sw:_ ->
                invoked := true;
                Ok ())
          in
          check seed "Closing or Released returns Closed"
            (Error Native_lifetime.Closed) rejected;
          check seed "revoked callback performs no effect" false !invoked;
          Eio.Promise.await first;
          Eio.Promise.await second;
          List.iter (fun node -> Eio.Promise.await node.done_) nodes;
          List.iter
            (fun _ -> Native_lifetime.close lifetime)
            (List.init (Random.State.int random 4) Fun.id);
          check seed "every admitted ID observed" true
            (Ids.equal expected model.entered);
          check seed "close joins every scope" true (Ids.is_empty model.active);
          check seed "every ID released exactly once" true
            (Ids.equal expected model.finished);
          check seed "Released is permanent" false
            (Native_lifetime.held lifetime);
          check seed "ordinary scopes report no release failures" true
            (!reports = [])))

let seeded_model () =
  let seeds =
    match Sys.getenv_opt "SYMPHONY_LIFETIME_SEED" with
    | None -> List.init seed_count Fun.id
    | Some raw -> (
        match int_of_string_opt raw with
        | Some seed when seed >= 0 -> [ seed ]
        | None | Some _ ->
            Alcotest.fail "SYMPHONY_LIFETIME_SEED must be a nonnegative integer"
        )
  in
  seeds
  |> List.iter (fun seed ->
      try scenario seed
      with error ->
        Alcotest.failf "seed=%d: %s" seed (Printexc.to_string error))

let capture f =
  try Ok (f ()) with error -> Error (error, Printexc.get_raw_backtrace ())

let[@inline never] raise_primary error = raise error

let original_trace trace =
  Printexc.raw_backtrace_to_string trace
  |> String.split_on_char '\n'
  |> List.exists
       (String.starts_with
          ~prefix:"Raised at Dune__exe__Native_lifetime_test.raise_primary")

let report_once reports expected =
  Alcotest.check Alcotest.bool "original secondary reported once" true
    (match !reports with
    | [ (error, _) ] -> error == expected
    | [] | _ :: _ -> false)

let primary_defect () =
  Eio_mock.Backend.run (fun () ->
      let reports = ref [] in
      let lifetime =
        Native_lifetime.create ~report:(fun failure ->
            reports := failure :: !reports)
      in
      let primary = Failure "primary scope defect" in
      let secondary = Failure "scope release defect" in
      let observed =
        capture (fun () ->
            Native_lifetime.with_scope lifetime (fun ~sw ->
                Eio.Switch.on_release sw (fun () -> raise secondary);
                raise_primary primary))
      in
      Alcotest.check Alcotest.bool "primary identity survives release defect"
        true
        (match observed with
        | Error (error, trace) -> error == primary && original_trace trace
        | Ok _ -> false);
      report_once reports secondary;
      (* Eio 1.6 Switch.await_idle:109 calls fail without bt; its default at57 is empty. *)
      Alcotest.check Alcotest.bool
        "dependency-provided empty release trace stays empty" true
        (match !reports with
        | [ (_, trace) ] -> Printexc.raw_backtrace_length trace = 0
        | [] | _ :: _ -> false);
      Native_lifetime.close lifetime;
      Alcotest.check Alcotest.bool "all scopes joined after defect" false
        (Native_lifetime.held lifetime))

let error_release () =
  Eio_mock.Backend.run (fun () ->
      let reports = ref [] in
      let reporter = Failure "reporter defect" in
      let lifetime =
        Native_lifetime.create ~report:(fun failure ->
            reports := failure :: !reports;
            raise reporter)
      in
      let secondary = Failure "expected-error release defect" in
      let later = Failure "second expected-error release defect" in
      let result =
        Native_lifetime.with_scope lifetime (fun ~sw ->
            Eio.Switch.on_release sw (fun () -> raise secondary);
            Eio.Switch.on_release sw (fun () -> raise later);
            Error "callback error")
      in
      Alcotest.check Alcotest.bool
        "expected Error survives release and reporter defects" true
        (match result with
        | Error (Native_lifetime.Rejected "callback error") -> true
        | Ok _
        | Error Native_lifetime.Closed
        | Error (Native_lifetime.Rejected _) -> false);
      Alcotest.check Alcotest.bool
        "every secondary survives an earlier reporter defect" true
        (match !reports with
        | [ (first, first_trace); (second, second_trace) ] ->
            first == secondary && second == later
            && Printexc.raw_backtrace_length first_trace = 0
            && Printexc.raw_backtrace_length second_trace = 0
        | [] | _ :: _ -> false);
      Native_lifetime.close lifetime)

let successful_release () =
  Eio_mock.Backend.run (fun () ->
      let lifetime = Native_lifetime.create ~report:(fun _ -> ()) in
      let secondary = Failure "successful release defect" in
      let observed =
        capture (fun () ->
            Native_lifetime.with_scope lifetime (fun ~sw ->
                Eio.Switch.on_release sw (fun () -> raise secondary);
                Ok "callback success"))
      in
      Alcotest.check Alcotest.bool "successful callback exposes release defect"
        true
        (match observed with
        | Error (error, _) -> error == secondary
        | Ok _ -> false);
      Native_lifetime.close lifetime)

let canceled_release () =
  Eio_mock.Backend.run (fun () ->
      let reports = ref [] in
      let lifetime =
        Native_lifetime.create ~report:(fun failure ->
            reports := failure :: !reports)
      in
      let cause = Failure "external cancellation" in
      let secondary = Failure "canceled release defect" in
      let observed =
        capture (fun () ->
            Eio.Cancel.sub (fun cancel ->
                Native_lifetime.with_scope lifetime (fun ~sw ->
                    Eio.Switch.on_release sw (fun () -> raise secondary);
                    Eio.Fiber.fork ~sw (fun () ->
                        Eio.Cancel.cancel cancel cause);
                    Eio.Fiber.await_cancel ())))
      in
      Alcotest.check Alcotest.bool "cancellation cause survives release defect"
        true
        (match observed with
        | Error (Eio.Cancel.Cancelled actual, _) -> actual == cause
        | Error _ | Ok _ -> false);
      report_once reports secondary;
      Native_lifetime.close lifetime)

type primary = Raise | Rejection

let shared_io_context () =
  Eio_mock.Backend.run (fun () ->
      let reports = ref [] in
      let lifetime =
        Native_lifetime.create ~report:(fun failure ->
            reports := failure :: !reports)
      in
      let primary =
        Eio.Exn.create (Eio.Exn.Not_available Eio_mock.Simulated_failure)
      in
      let secondary =
        match primary with
        | Eio.Io (reason, context) -> Eio.Io (reason, context)
        | _ ->
            Alcotest.fail
              "The public IO constructor returned a non-IO exception"
      in
      Alcotest.check Alcotest.bool "two exceptions are distinct" false
        (primary == secondary);
      let observed =
        capture (fun () ->
            Native_lifetime.with_scope lifetime (fun ~sw ->
                Eio.Switch.on_release sw (fun () -> raise secondary);
                raise_primary primary))
      in
      Alcotest.check Alcotest.bool "primary IO identity and trace retained" true
        (match observed with
        | Error (error, trace) -> error == primary && original_trace trace
        | Ok _ -> false);
      Alcotest.check Alcotest.bool
        "a distinct IO failure sharing context is still reported" true
        (match (secondary, !reports) with
        | ( Eio.Io (expected, expected_context),
            [ (Eio.Io (actual, actual_context), trace) ] ) ->
            expected == actual
            && expected_context == actual_context
            && Printexc.raw_backtrace_length trace = 0
        | _ -> false);
      Native_lifetime.close lifetime)

let pending_children () =
  List.iter
    (fun primary ->
      Eio_mock.Backend.run (fun () ->
          let reports = ref [] in
          let lifetime =
            Native_lifetime.create ~report:(fun failure ->
                reports := failure :: !reports)
          in
          let joined = ref false in
          let defect = Failure "callback with pending child" in
          let outcome =
            capture (fun () ->
                Native_lifetime.with_scope lifetime (fun ~sw ->
                    Eio.Fiber.fork ~sw (fun () ->
                        Fun.protect
                          ~finally:(fun () -> joined := true)
                          Eio.Fiber.await_cancel);
                    match primary with
                    | Raise -> raise_primary defect
                    | Rejection -> Error "rejected"))
          in
          Alcotest.check Alcotest.bool
            "failed callback cancels and joins non-daemon child" true !joined;
          Alcotest.check Alcotest.bool "original failure remains primary" true
            (match (primary, outcome) with
            | Raise, Error (error, trace) ->
                error == defect && original_trace trace
            | Rejection, Ok (Error (Native_lifetime.Rejected "rejected")) ->
                true
            | Raise, Ok _
            | Rejection, Error _
            | Rejection, Ok (Ok _)
            | Rejection, Ok (Error Native_lifetime.Closed)
            | Rejection, Ok (Error (Native_lifetime.Rejected _)) -> false);
          Alcotest.check Alcotest.bool
            "cancellation bookkeeping is not a secondary defect" true
            (!reports = []);
          Native_lifetime.close lifetime))
    [ Raise; Rejection ]

let suite =
  [
    Alcotest.test_case "1000 seeded lifetime scenarios" `Quick seeded_model;
    Alcotest.test_case "primary defect survives resource release defect" `Quick
      primary_defect;
    Alcotest.test_case "expected Error survives release and reporter defects"
      `Quick error_release;
    Alcotest.test_case "callback success exposes release defect after closure"
      `Quick successful_release;
    Alcotest.test_case "failed callbacks cancel pending non-daemon children"
      `Quick pending_children;
    Alcotest.test_case "external cancellation survives release defect" `Quick
      canceled_release;
    Alcotest.test_case "distinct IO failures sharing context are preserved"
      `Quick shared_io_context;
  ]
