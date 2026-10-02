module Clock = Clock.Pure

let operation_count = 2_000
let stream_samples = 100
let law_samples = 2_000
let issue_count = 24
let largest_tick = 1_000_000
let largest_payload = 10_000
let put_weight = 3
let drop_weight = 1

let checked = function
  | Ok value -> value
  | Error error -> Alcotest.fail error

let instant n = Clock.of_nanoseconds (checked (Count.parse (string_of_int n)))
let first_retry, allocator = Retry_id.Allocator.fresh Retry_id.Allocator.empty
let second_retry, _ = Retry_id.Allocator.fresh allocator

module Owner = struct
  type instant = Clock.instant

  type role =
    | Worker
    | Cleanup
    | Retry_waiting of Retry_id.t * instant
    | Retry_refreshing of Retry_id.t

  type t = { issue : Issue.t; role : role; payload : int }

  let issue owner = owner.issue
  let role owner = owner.role

  let equal_role a b =
    match (a, b) with
    | Worker, Worker | Cleanup, Cleanup -> true
    | Retry_waiting (a, due_a), Retry_waiting (b, due_b) ->
        Retry_id.equal a b && Clock.compare due_a due_b = 0
    | Retry_refreshing a, Retry_refreshing b -> Retry_id.equal a b
    | Worker, (Cleanup | Retry_waiting _ | Retry_refreshing _)
    | Cleanup, (Worker | Retry_waiting _ | Retry_refreshing _)
    | Retry_waiting _, (Worker | Cleanup | Retry_refreshing _)
    | Retry_refreshing _, (Worker | Cleanup | Retry_waiting _) -> false

  let equal a b =
    a == b
    || a.payload = b.payload && equal_role a.role b.role
       && Json.equal (Issue.to_json a.issue) (Issue.to_json b.issue)
end

module Queue = Ownership.Make (Clock) (Owner)
module Model = Ownership_model.Make (Clock) (Owner)

let issue key payload =
  checked
    (Issue.parse
       {
         Issue.id = Printf.sprintf "opaque:%02d" key;
         identifier = Printf.sprintf "ISSUE-%02d" key;
         title = Printf.sprintf "Snapshot %d" payload;
         description = None;
         priority = None;
         state = (if payload mod 2 = 0 then "Todo" else "In Progress");
         branch_name = None;
         url = None;
         assignee_id = None;
         labels = [];
         blocked_by = [];
         created_at = None;
         updated_at = None;
         dispatchable = Issue.Dispatchable;
         native_ref = None;
       })

let id key = Issue.id (issue key 0)
let owner key role payload = { Owner.issue = issue key payload; role; payload }

let waiting key due payload =
  let token = if payload mod 2 = 0 then first_retry else second_retry in
  owner key (Owner.Retry_waiting (token, instant due)) payload

let equal_binding (id_a, a) (id_b, b) =
  Issue_id.equal id_a id_b && Owner.equal a b

let bindings queue =
  Queue.fold (fun id owner rest -> (id, owner) :: rest) queue []

let equal_next a b =
  match (a, b) with
  | None, None -> true
  | Some (id_a, token_a, due_a), Some (id_b, token_b, due_b) ->
      Issue_id.equal id_a id_b
      && Retry_id.equal token_a token_b
      && Clock.compare due_a due_b = 0
  | None, Some _ | Some _, None -> false

let equal_queue a b =
  List.equal equal_binding (bindings a) (bindings b)
  && equal_next (Queue.next_retry a) (Queue.next_retry b)

let agrees queue model =
  let model_bindings = Model.bindings model in
  List.equal equal_binding (bindings queue) model_bindings
  && List.for_all
       (fun (id, owner) ->
         Option.fold ~none:false ~some:(Owner.equal owner) (Queue.find id queue))
       model_bindings
  && Issue_id.Set.equal (Queue.running_ids queue) (Model.running_ids model)
  && Issue_id.Set.equal (Queue.retry_ids queue) (Model.retry_ids model)
  && Issue_id.Set.equal (Queue.claimed queue) (Model.claimed model)
  && Issue_id.Set.is_empty
       (Issue_id.Set.inter (Queue.running_ids queue) (Queue.retry_ids queue))
  && Issue_id.Set.equal (Queue.claimed queue)
       (Issue_id.Set.union (Queue.running_ids queue) (Queue.retry_ids queue))
  && equal_next (Queue.next_retry queue) (Model.next_retry model)

let check message condition = Alcotest.(check bool) message true condition

let empty () =
  check "empty projections" (agrees Queue.empty Model.empty);
  check "absent lookup" (Option.is_none (Queue.find (id 0) Queue.empty));
  Alcotest.check Alcotest.int "empty fold" 7
    (Queue.fold (fun _ _ value -> value + 1) Queue.empty 7)

let equal_rank () =
  let old = waiting 0 10 0 and fresh = waiting 0 10 1 in
  let before = Queue.put old Queue.empty in
  let after = Queue.put fresh before in
  check "equal due replaces the complete payload"
    (Option.fold ~none:false ~some:(Owner.equal fresh)
       (Queue.find (id 0) after));
  check "minimum uses the replacement token"
    (equal_next (Queue.next_retry after)
       (Some (id 0, second_retry, instant 10)));
  check "earlier persistent value survives"
    (Option.fold ~none:false ~some:(Owner.equal old) (Queue.find (id 0) before));
  let worker = owner 0 Owner.Worker 2 in
  let cleanup = owner 0 Owner.Cleanup 3 in
  check "equal inactive rank replaces role and snapshot"
    (agrees
       (Queue.put cleanup (Queue.put worker Queue.empty))
       (Model.put cleanup Model.empty))

let refresh_retire () =
  let retry = waiting 0 5 0 in
  let refreshing = owner 0 (Owner.Retry_refreshing first_retry) 1 in
  let before = Queue.put retry Queue.empty in
  let after = Queue.put refreshing before in
  check "refresh retains claim" (Issue_id.Set.mem (id 0) (Queue.claimed after));
  check "refresh remains retry owned"
    (Issue_id.Set.mem (id 0) (Queue.retry_ids after));
  check "refresh has no due entry" (Option.is_none (Queue.next_retry after));
  let cleanup = owner 0 Owner.Cleanup 2 in
  let cleaning = Queue.put cleanup after in
  check "cleanup retains non-retry ownership"
    (Issue_id.Set.mem (id 0) (Queue.running_ids cleaning)
    && Issue_id.Set.is_empty (Queue.retry_ids cleaning));
  let retired = Queue.remove (id 0) cleaning in
  check "retirement removes all projections" (equal_queue retired Queue.empty);
  check "retirement is idempotent"
    (equal_queue (Queue.remove (id 0) retired) retired)

let due_and_id () =
  let later = waiting 0 20 0 in
  let tie_larger = waiting 2 10 1 and tie_smaller = waiting 1 10 0 in
  let inactive = owner 3 Owner.Worker 0 in
  let values = [ later; tie_larger; inactive; tie_smaller ] in
  let queue = List.fold_left (fun q o -> Queue.put o q) Queue.empty values in
  check "due precedes ID and inactive ranks"
    (equal_next (Queue.next_retry queue) (Some (id 1, first_retry, instant 10)));
  check "peek preserves all bindings"
    (agrees queue
       (List.fold_left (fun m o -> Model.put o m) Model.empty values));
  check "removing minimum exposes next tie"
    (equal_next
       (Queue.next_retry (Queue.remove (id 1) queue))
       (Some (id 2, second_retry, instant 10)))

let exact_due () =
  let large =
    Clock.of_nanoseconds
      (checked (Count.parse "184467440737095516160000000000"))
  in
  let far = owner 0 (Owner.Retry_waiting (first_retry, large)) 0 in
  let near = waiting 1 largest_tick 1 in
  check "exact due order exceeds native horizons"
    (equal_next
       (Queue.next_retry (Queue.put far (Queue.put near Queue.empty)))
       (Some (id 1, second_retry, instant largest_tick)))

type operation = Put of Owner.t | Drop of Issue_id.t

let advance queue model = function
  | Put owner -> (Queue.put owner queue, Model.put owner model)
  | Drop id -> (Queue.remove id queue, Model.remove id model)

let stream operations =
  let rec steps queue model = function
    | [] -> true
    | operation :: rest ->
        let previous = bindings queue in
        let next, next_model = advance queue model operation in
        List.equal equal_binding previous (bindings queue)
        && agrees next next_model && steps next next_model rest
  in
  agrees Queue.empty Model.empty && steps Queue.empty Model.empty operations

let fixed_stream () =
  let operations =
    List.init operation_count (fun n ->
        let key = n mod issue_count in
        match n mod 5 with
        | 0 -> Put (waiting key (n mod 17) n)
        | 1 -> Put (owner key (Owner.Retry_refreshing first_retry) n)
        | 2 -> Put (owner key Owner.Worker n)
        | 3 -> Put (owner key Owner.Cleanup n)
        | _ -> Drop (id key))
  in
  check "every operation agrees with the list model" (stream operations)

type kind = Worker | Cleanup | Waiting | Refreshing

let owner_generator =
  let open QCheck2.Gen in
  let kind = oneof (List.map pure [ Worker; Cleanup; Waiting; Refreshing ]) in
  map4
    (fun key kind due payload ->
      match kind with
      | Worker -> owner key Owner.Worker payload
      | Cleanup -> owner key Owner.Cleanup payload
      | Waiting -> waiting key due payload
      | Refreshing -> owner key (Owner.Retry_refreshing first_retry) payload)
    (int_range 0 (issue_count - 1))
    kind (int_range 0 largest_tick)
    (int_range 0 largest_payload)

let operation_generator =
  let open QCheck2.Gen in
  oneof_weighted
    [
      (put_weight, map (fun owner -> Put owner) owner_generator);
      ( drop_weight,
        map (fun key -> Drop (id key)) (int_range 0 (issue_count - 1)) );
    ]

let of_operations operations =
  List.fold_left
    (fun (queue, model) operation -> advance queue model operation)
    (Queue.empty, Model.empty) operations

let short_stream =
  QCheck2.Gen.list_size (QCheck2.Gen.int_range 0 40) operation_generator

let map_laws (a, (b, operations)) =
  let queue, _ = of_operations operations in
  let id_a = Issue.id (Owner.issue a) and id_b = Issue.id (Owner.issue b) in
  equal_queue (Queue.put a (Queue.put a queue)) (Queue.put a queue)
  && (if Issue_id.equal id_a id_b then
        equal_queue (Queue.put a (Queue.put b queue)) (Queue.put a queue)
      else
        equal_queue
          (Queue.put a (Queue.put b queue))
          (Queue.put b (Queue.put a queue)))
  && equal_queue
       (Queue.remove id_a (Queue.remove id_a queue))
       (Queue.remove id_a queue)
  && equal_queue
       (Queue.remove id_a (Queue.remove id_b queue))
       (Queue.remove id_b (Queue.remove id_a queue))

let selected a b =
  let id_a = Issue.id (Owner.issue a) and id_b = Issue.id (Owner.issue b) in
  if Issue_id.equal id_a id_b then 0
  else
    match Queue.next_retry (Queue.put a (Queue.put b Queue.empty)) with
    | Some (id, _, _) -> if Issue_id.equal id id_a then -1 else 1
    | None -> Alcotest.fail "waiting pair lost its due entry"

let order_laws (due_a, (due_b, due_c)) =
  let a = waiting 0 due_a 0
  and b = waiting 1 due_b 1
  and c = waiting 2 due_c 2 in
  let ab = selected a b and bc = selected b c and ac = selected a c in
  selected a a = 0
  && ab = -selected b a
  && (ab > 0 || bc > 0 || ac <= 0)
  && ab <> 0 && bc <> 0 && ac <> 0
  &&
  let queue = Queue.put c (Queue.put b (Queue.put a Queue.empty)) in
  let model = Model.put c (Model.put b (Model.put a Model.empty)) in
  agrees queue model

let tests =
  [
    Alcotest.test_case "empty identity" `Quick empty;
    Alcotest.test_case "equal-rank complete replacement" `Quick equal_rank;
    Alcotest.test_case "refresh and retirement custody" `Quick refresh_retire;
    Alcotest.test_case "minimum due then exact ID" `Quick due_and_id;
    Alcotest.test_case "unbounded exact due values" `Quick exact_due;
    Alcotest.test_case "2000-step role and retirement stream" `Quick
      fixed_stream;
  ]

let properties =
  let open QCheck2.Gen in
  [
    QCheck2.Test.make ~name:"owner keyed write and removal laws"
      ~count:law_samples
      (pair owner_generator (pair owner_generator short_stream))
      map_laws;
    QCheck2.Test.make
      ~name:"owner projections and retry minimum agree with list"
      ~count:law_samples short_stream (fun operations ->
        let queue, model = of_operations operations in
        agrees queue model);
    QCheck2.Test.make ~name:"retry minimum has total due and ID order"
      ~count:law_samples
      (pair (int_range 0 largest_tick)
         (pair (int_range 0 largest_tick) (int_range 0 largest_tick)))
      order_laws;
    QCheck2.Test.make
      ~name:"2000-operation ownership streams agree after every step"
      ~count:stream_samples
      (list_size (pure operation_count) operation_generator)
      stream;
  ]
