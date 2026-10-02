module Inbox = Service_inbox

module Model = struct
  type status = Fresh | Queued | Taken | Revoked
  type t = { states : (int * status) list; queue : (int * int) list }

  type observation =
    | Reserved of int
    | Sent
    | Duplicate
    | Denied
    | Retracted
    | Already_retracted
    | Exists
    | Consumed of (int * int) option
    | Equal of bool

  let empty = { states = []; queue = [] }

  let reserve state =
    let id = List.length state.states in
    ({ state with states = state.states @ [ (id, Fresh) ] }, Reserved id)

  let replace id status state =
    {
      state with
      states =
        List.map
          (fun (current, old) ->
            if current = id then (current, status) else (current, old))
          state.states;
    }

  let publish id payload state =
    match List.assoc_opt id state.states with
    | None -> invalid_arg "model publication requires a reserved identity"
    | Some Fresh ->
        let next = replace id Queued state in
        ({ next with queue = next.queue @ [ (id, payload) ] }, Sent)
    | Some (Queued | Taken) -> (state, Duplicate)
    | Some Revoked -> (state, Denied)

  let retract id state =
    match List.assoc_opt id state.states with
    | None -> invalid_arg "model retraction requires a reserved identity"
    | Some Fresh -> (replace id Revoked state, Retracted)
    | Some Revoked -> (state, Already_retracted)
    | Some (Queued | Taken) -> (state, Exists)

  let consume state =
    match state.queue with
    | [] -> (state, Consumed None)
    | (id, payload) :: rest ->
        let next = replace id Taken state in
        ({ next with queue = rest }, Consumed (Some (id, payload)))
end

type action =
  | Reserve
  | Publish of int * int
  | Retract of int
  | Consume
  | Same of int * int

type binding = {
  id : int;
  slot : int Inbox.slot;
  producer : int Inbox.producer;
}

let publication = function
  | Inbox.Published -> Model.Sent
  | Inbox.Duplicate -> Model.Duplicate
  | Inbox.Revoked -> Model.Denied

let retraction = function
  | Inbox.Retracted -> Model.Retracted
  | Inbox.Previously_retracted -> Model.Already_retracted
  | Inbox.Publication_exists -> Model.Exists

let observation = function
  | Model.Reserved id -> Printf.sprintf "reserved(%d)" id
  | Model.Sent -> "published"
  | Model.Duplicate -> "duplicate"
  | Model.Denied -> "revoked"
  | Model.Retracted -> "retracted"
  | Model.Already_retracted -> "previously-retracted"
  | Model.Exists -> "publication-exists"
  | Model.Consumed None -> "empty"
  | Model.Consumed (Some (id, payload)) ->
      Printf.sprintf "consume(%d,%d)" id payload
  | Model.Equal answer -> Printf.sprintf "same(%b)" answer

let action = function
  | Reserve -> "reserve"
  | Publish (hint, payload) -> Printf.sprintf "publish(%d,%d)" hint payload
  | Retract hint -> Printf.sprintf "retract(%d)" hint
  | Consume -> "consume"
  | Same (left, right) -> Printf.sprintf "same(%d,%d)" left right

let program actions = String.concat "; " (List.map action actions)

let equal step operation expected actual =
  if expected <> actual then
    QCheck2.Test.fail_reportf "step %d %s: expected %s; actual %s" step
      (action operation) (observation expected) (observation actual)

let choose hint bindings =
  let count = List.length bindings in
  if count = 0 then
    QCheck2.Test.fail_reportf "program failed to reserve its initial slot";
  let id = hint mod count in
  match List.find_opt (fun binding -> binding.id = id) bindings with
  | Some binding -> binding
  | None -> QCheck2.Test.fail_reportf "test binding %d is absent" id

let consumed bindings inbox =
  match Inbox.consume inbox with
  | None -> Model.Consumed None
  | Some (slot, payload) -> (
      match
        List.find_opt (fun binding -> Inbox.same binding.slot slot) bindings
      with
      | Some binding -> Model.Consumed (Some (binding.id, payload))
      | None -> QCheck2.Test.fail_reportf "consume returned an unreserved slot")

let stream actions =
  let inbox = Inbox.create ~changed:(Eio.Condition.create ()) in
  let rec step index state bindings = function
    | [] -> drain index state bindings
    | operation :: rest ->
        let next, bindings, expected, actual =
          match operation with
          | Reserve ->
              let next, expected = Model.reserve state in
              let id = List.length bindings in
              let slot, producer = Inbox.reserve inbox in
              ( next,
                { id; slot; producer } :: bindings,
                expected,
                Model.Reserved id )
          | Publish (hint, payload) ->
              let binding = choose hint bindings in
              let next, expected = Model.publish binding.id payload state in
              ( next,
                bindings,
                expected,
                publication (Inbox.publish binding.producer payload) )
          | Retract hint ->
              let binding = choose hint bindings in
              let next, expected = Model.retract binding.id state in
              (next, bindings, expected, retraction (Inbox.retract binding.slot))
          | Consume ->
              let next, expected = Model.consume state in
              (next, bindings, expected, consumed bindings inbox)
          | Same (left, right) ->
              let a = choose left bindings and b = choose right bindings in
              ( state,
                bindings,
                Model.Equal (a.id = b.id),
                Model.Equal (Inbox.same a.slot b.slot) )
        in
        equal index operation expected actual;
        step (index + 1) next bindings rest
  and drain index state bindings =
    let next, expected = Model.consume state in
    equal index Consume expected (consumed bindings inbox);
    match expected with
    | Model.Consumed None -> true
    | Model.Consumed (Some _) -> drain (index + 1) next bindings
    | Model.Reserved _
    | Model.Sent
    | Model.Duplicate
    | Model.Denied
    | Model.Retracted
    | Model.Already_retracted
    | Model.Exists
    | Model.Equal _ ->
        QCheck2.Test.fail_reportf
          "model consume returned an impossible observation"
  in
  step 0 Model.empty [] (Reserve :: actions)

let publication_check expected actual =
  Alcotest.(check string)
    "publication" (observation expected)
    (observation (publication actual))

let retraction_check expected actual =
  Alcotest.(check string)
    "retraction" (observation expected)
    (observation (retraction actual))

let take inbox slot payload =
  match Inbox.consume inbox with
  | None -> Alcotest.fail "published notification is missing"
  | Some (returned, actual) ->
      Alcotest.(check bool)
        "reserved slot identity" true (Inbox.same slot returned);
      Alcotest.(check int) "first payload" payload actual

let empty inbox =
  match Inbox.consume inbox with
  | None -> ()
  | Some _ -> Alcotest.fail "unexpected queued notification"

let fifo () =
  let inbox = Inbox.create ~changed:(Eio.Condition.create ()) in
  let a, send_a = Inbox.reserve inbox in
  let b, send_b = Inbox.reserve inbox in
  let c, send_c = Inbox.reserve inbox in
  publication_check Model.Sent (Inbox.publish send_b 20);
  publication_check Model.Sent (Inbox.publish send_a 10);
  publication_check Model.Duplicate (Inbox.publish send_b 99);
  retraction_check Model.Exists (Inbox.retract b);
  publication_check Model.Sent (Inbox.publish send_c 30);
  take inbox b 20;
  publication_check Model.Duplicate (Inbox.publish send_b 100);
  retraction_check Model.Exists (Inbox.retract b);
  take inbox a 10;
  take inbox c 30;
  empty inbox;
  empty inbox

let first_object () =
  let inbox = Inbox.create ~changed:(Eio.Condition.create ()) in
  let slot, send = Inbox.reserve inbox in
  let first = ref 7 and replacement = ref 8 in
  publication_check Model.Sent (Inbox.publish send first);
  publication_check Model.Duplicate (Inbox.publish send replacement);
  match Inbox.consume inbox with
  | None -> Alcotest.fail "first object was not delivered"
  | Some (returned, payload) ->
      Alcotest.(check bool) "original slot" true (Inbox.same slot returned);
      Alcotest.(check bool) "original payload object" true (payload == first);
      publication_check Model.Duplicate (Inbox.publish send replacement);
      empty inbox

let retract_laws () =
  let inbox = Inbox.create ~changed:(Eio.Condition.create ()) in
  let dead, send_dead = Inbox.reserve inbox in
  let live, send_live = Inbox.reserve inbox in
  empty inbox;
  empty inbox;
  retraction_check Model.Retracted (Inbox.retract dead);
  retraction_check Model.Already_retracted (Inbox.retract dead);
  publication_check Model.Denied (Inbox.publish send_dead 1);
  publication_check Model.Sent (Inbox.publish send_live 2);
  retraction_check Model.Exists (Inbox.retract live);
  take inbox live 2;
  publication_check Model.Denied (Inbox.publish send_dead 3);
  retraction_check Model.Already_retracted (Inbox.retract dead);
  publication_check Model.Duplicate (Inbox.publish send_live 4);
  retraction_check Model.Exists (Inbox.retract live);
  empty inbox

let identity () =
  let changed = Eio.Condition.create () in
  let left = Inbox.create ~changed and right = Inbox.create ~changed in
  let a, _ = Inbox.reserve left in
  let b, _ = Inbox.reserve left in
  let c, _ = Inbox.reserve right in
  Alcotest.(check bool) "reflexive" true (Inbox.same a a);
  Alcotest.(check bool) "same inbox distinct slots" false (Inbox.same a b);
  Alcotest.(check bool) "cross inbox distinct slots" false (Inbox.same a c);
  Alcotest.(check bool) "symmetric" (Inbox.same a c) (Inbox.same c a);
  empty left;
  empty right

let wake_recheck () =
  Eio_mock.Backend.run (fun () ->
      Eio.Switch.run (fun sw ->
          let changed = Eio.Condition.create () in
          let inbox = Inbox.create ~changed in
          let slot, send = Inbox.reserve inbox in
          let waiting, signal_waiting = Eio.Promise.create () in
          let result, signal_result = Eio.Promise.create () in
          let checks = ref 0 in
          Eio.Fiber.fork ~sw (fun () ->
              let rec await () =
                match Inbox.consume inbox with
                | Some envelope -> Eio.Promise.resolve signal_result envelope
                | None ->
                    incr checks;
                    if !checks = 1 then Eio.Promise.resolve signal_waiting ();
                    (* No suspension separates the empty check and condition wait. *)
                    Eio.Condition.await_no_mutex changed;
                    await ()
              in
              await ());
          Eio.Promise.await waiting;
          Alcotest.(check int) "consumer checked before waiting" 1 !checks;
          Eio.Condition.broadcast changed;
          Eio.Fiber.yield ();
          Alcotest.(check int) "spurious wake rechecks empty inbox" 2 !checks;
          publication_check Model.Sent (Inbox.publish send 42);
          publication_check Model.Duplicate (Inbox.publish send 99);
          let returned, payload = Eio.Promise.await result in
          Alcotest.(check bool)
            "woken consumer receives exact slot" true (Inbox.same slot returned);
          Alcotest.(check int)
            "woken consumer receives first payload" 42 payload;
          empty inbox))

let already_ready () =
  Eio_mock.Backend.run (fun () ->
      Eio.Switch.run (fun sw ->
          let changed = Eio.Condition.create () in
          let inbox = Inbox.create ~changed in
          let slot, send = Inbox.reserve inbox in
          publication_check Model.Sent (Inbox.publish send 7);
          let delivered, signal = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
              match Inbox.consume inbox with
              | Some envelope -> Eio.Promise.resolve signal envelope
              | None ->
                  Eio.Condition.await_no_mutex changed;
                  Alcotest.fail "ready notification incorrectly needed a wake");
          let returned, payload = Eio.Promise.await delivered in
          Alcotest.(check bool)
            "preexisting notification slot" true (Inbox.same slot returned);
          Alcotest.(check int) "preexisting notification payload" 7 payload;
          empty inbox))

exception Owner_defect

let publication_burst = 1024

let failed_owner () =
  Eio_mock.Backend.run (fun () ->
      let inbox = Inbox.create ~changed:(Eio.Condition.create ()) in
      let reservations =
        List.init publication_burst (fun payload ->
            let slot, producer = Inbox.reserve inbox in
            (slot, producer, payload))
      in
      let closed = ref false in
      Alcotest.check_raises "owner defect survives closure publications"
        Owner_defect (fun () ->
          Eio.Switch.run (fun sw ->
              Eio.Fiber.fork ~sw (fun () ->
                  Fun.protect
                    ~finally:(fun () ->
                      Eio.Cancel.protect (fun () ->
                          (* The owner has failed and consumes no notification. *)
                          List.iter
                            (fun (_, producer, payload) ->
                              match Inbox.publish producer payload with
                              | Inbox.Published -> ()
                              | Inbox.Duplicate | Inbox.Revoked ->
                                  Alcotest.fail
                                    "fresh closure slot was rejected")
                            reservations;
                          closed := true))
                    (fun () -> Eio.Fiber.yield ()));
              raise Owner_defect));
      Alcotest.(check bool) "protected producer finalizer joined" true !closed;
      List.iter
        (fun (slot, _, payload) ->
          match Inbox.consume inbox with
          | Some (returned, actual)
            when Inbox.same slot returned && payload = actual -> ()
          | Some (_, actual) ->
              Alcotest.failf "burst payload %d: wrong slot or payload %d"
                payload actual
          | None -> Alcotest.failf "burst payload %d was lost" payload)
        reservations;
      empty inbox)

let maximum_actions = 300
let samples = 300

let action_generator =
  let open QCheck2.Gen in
  oneof_weighted
    [
      (2, return Reserve);
      ( 5,
        map
          (fun (hint, payload) -> Publish (hint, payload))
          (pair (int_range 0 maximum_actions) (int_range (-1000) 1000)) );
      (3, map (fun hint -> Retract hint) (int_range 0 maximum_actions));
      (4, return Consume);
      ( 2,
        map
          (fun (left, right) -> Same (left, right))
          (pair (int_range 0 maximum_actions) (int_range 0 maximum_actions)) );
    ]

let tests =
  [
    Alcotest.test_case "FIFO follows successful publication, first payload wins"
      `Quick fifo;
    Alcotest.test_case "first payload preserves object identity" `Quick
      first_object;
    Alcotest.test_case "retract and consumed tombstone laws" `Quick retract_laws;
    Alcotest.test_case "slot identity cannot collide across inboxes" `Quick
      identity;
    Alcotest.test_case "condition wake rechecks before consumption" `Quick
      wake_recheck;
    Alcotest.test_case "already queued notification needs no wake" `Quick
      already_ready;
    Alcotest.test_case "failed owner cannot block protected closure publication"
      `Quick failed_owner;
  ]

let properties =
  [
    QCheck2.Test.make
      ~name:"reserved Inbox agrees with independent list/status model"
      ~count:samples ~print:program
      QCheck2.Gen.(list_size (int_range 0 maximum_actions) action_generator)
      stream;
  ]
