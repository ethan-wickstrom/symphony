module Model = Scheduler_algebra_model

let samples = 2_000
let maximum_reports = 30

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let sign value = Int.compare value 0
let count n = checked (Count.parse (Z.to_string n))
let milliseconds n = checked (Milliseconds.parse (Z.to_string n))
let attempt n = checked (Positive_count.parse (Z.to_string n))

let usage (value : Model.totals) =
  Usage.make ~input:(count value.Model.input) ~output:(count value.Model.output)
    ~total:(count value.Model.total)

let decimals value =
  List.map Count.decimal
    [ Usage.input value; Usage.output value; Usage.total value ]

let model_decimals (value : Model.totals) =
  List.map Z.to_string
    [ value.Model.input; value.Model.output; value.Model.total ]

let usage_agrees expected actual =
  List.equal String.equal (model_decimals expected) (decimals actual)

let same_usage left right =
  List.equal String.equal (decimals left) (decimals right)

let totals input output total =
  {
    Model.input = Z.of_int input;
    output = Z.of_int output;
    total = Z.of_int total;
  }

let fixture ~created_at (key : Model.dispatch_key) =
  let input : Issue.input =
    {
      Issue.id = "opaque:" ^ key.Model.identifier;
      identifier = key.Model.identifier;
      title = "Checked scheduling fixture";
      description = None;
      priority = Option.map string_of_int key.Model.priority;
      state = "Todo";
      branch_name = None;
      url = None;
      assignee_id = None;
      labels = [];
      blocked_by = [];
      created_at;
      updated_at = None;
      dispatchable = Issue.Dispatchable;
      native_ref = None;
    }
  in
  checked (Issue.parse input)

let issue (key : Model.dispatch_key) =
  let created_at =
    Option.map
      (fun second -> Printf.sprintf "2026-10-01T00:00:%02dZ" second)
      key.Model.created_at
  in
  fixture ~created_at key

let key priority created_at identifier =
  { Model.priority; created_at; identifier }

let preorder compare (a, b, c) =
  compare a a = 0
  && sign (compare a b) = -sign (compare b a)
  && (compare a b <= 0 || compare b a <= 0)
  && (compare a b > 0 || compare b c > 0 || compare a c <= 0)

let dispatch_examples () =
  let keys =
    [
      key None None "SYM-Z";
      key (Some 4) None "SYM-4";
      key (Some 1) None "SYM-1";
      key (Some 5) (Some 0) "SYM-B";
      key (Some 0) (Some 0) "SYM-A";
      key (Some 2) (Some 0) "SYM-2";
      key (Some 3) (Some 0) "SYM-3";
      key (Some (-1)) (Some 1) "SYM-C";
    ]
  in
  let ordered = List.sort Dispatch_order.dispatch (List.map issue keys) in
  Alcotest.(check (list string))
    "ranked priorities precede chronological fallback bucket"
    [ "SYM-1"; "SYM-2"; "SYM-3"; "SYM-4"; "SYM-A"; "SYM-B"; "SYM-C"; "SYM-Z" ]
    (List.map
       (fun value -> Issue_identifier.text (Issue.identifier value))
       ordered);
  let same = key (Some 2) (Some 0) "SYM-SAME" in
  let utc = fixture ~created_at:(Some "2026-10-01T00:00:00Z") same in
  let offset = fixture ~created_at:(Some "2026-10-01T02:00:00+02:00") same in
  Alcotest.(check int)
    "equivalent timestamp spellings" 0
    (Dispatch_order.dispatch utc offset)

let composition_examples () =
  let earlier = issue (key (Some 4) (Some 0) "SYM-A") in
  let higher = issue (key (Some 1) (Some 1) "SYM-B") in
  let priority_first =
    Dispatch_order.then_by Dispatch_order.priority Dispatch_order.created_at
  in
  let time_first =
    Dispatch_order.then_by Dispatch_order.created_at Dispatch_order.priority
  in
  Alcotest.(check int) "priority first" 1 (sign (priority_first earlier higher));
  Alcotest.(check int) "time first" (-1) (sign (time_first earlier higher));
  let different_id =
    checked
      (Issue.parse
         {
           Issue.id = "a different opaque ID";
           identifier = "SYM-A";
           title = "Another checked issue";
           description = None;
           priority = Some "4";
           state = "Todo";
           branch_name = None;
           url = None;
           assignee_id = None;
           labels = [];
           blocked_by = [];
           created_at = Some "2026-10-01T00:00:00Z";
           updated_at = None;
           dispatchable = Issue.Dispatchable;
           native_ref = None;
         })
  in
  Alcotest.(check bool)
    "ranking equality is not issue identity" false
    (Issue_id.equal (Issue.id earlier) (Issue.id different_id));
  Alcotest.(check int)
    "distinct IDs may have equal dispatch rank" 0
    (Dispatch_order.dispatch earlier different_id)

let backoff_examples () =
  let caps = [ "0"; "7777"; "10000"; "20000"; "9223372036854775807" ] in
  let huge = "1" ^ String.make 4096 '0' in
  let attempts = [ "1"; "2"; "3"; "50"; "51"; "1000000"; huge ] in
  List.iter
    (fun cap ->
      List.iter
        (fun n ->
          let expected =
            Model.backoff ~attempt:(Z.of_string n) ~cap:(Z.of_string cap)
          in
          let actual =
            Backoff.failure
              ~attempt:(checked (Positive_count.parse n))
              ~cap:(checked (Milliseconds.parse cap))
          in
          Alcotest.(check string)
            "closed-form bounded backoff" (Z.to_string expected)
            (Milliseconds.decimal actual))
        attempts)
    caps;
  Alcotest.(check string)
    "continuation delay" "1000"
    (Milliseconds.decimal Backoff.continuation);
  Alcotest.(check bool)
    "zero attempts are rejected" true
    (Result.is_error (Positive_count.parse "0"))

let run () = fst (Run_id.Allocator.fresh Run_id.Allocator.empty)
let thread () = checked (Thread_id.parse "thread:one")

let observe watermark ~run ~thread absolute =
  checked (Usage.observe watermark ~run ~thread ~absolute)

let usage_examples () =
  let run = run () and thread = thread () in
  let initial = Usage.initial ~run ~thread in
  let a = usage (totals 10 20 17) in
  let b = usage (totals 8 25 9) in
  let first, first_delta = observe initial ~run ~thread a in
  let second, second_delta = observe first ~run ~thread b in
  let duplicate, duplicate_delta = observe second ~run ~thread b in
  let reordered, reordered_delta = observe duplicate ~run ~thread a in
  Alcotest.(check (list string))
    "initial totals" [ "0"; "0"; "0" ]
    (decimals (Usage.absolute initial));
  Alcotest.(check (list string))
    "independent absolute counters" [ "10"; "25"; "17" ]
    (decimals (Usage.absolute reordered));
  Alcotest.(check (list string))
    "componentwise growth" [ "0"; "5"; "0" ] (decimals second_delta);
  Alcotest.(check bool)
    "duplicate report contributes zero" true
    (same_usage duplicate_delta Usage.zero);
  Alcotest.(check bool)
    "reordered report contributes zero" true
    (same_usage reordered_delta Usage.zero);
  let accumulated =
    List.fold_left Usage.add Usage.zero
      [ first_delta; second_delta; duplicate_delta; reordered_delta ]
  in
  Alcotest.(check bool)
    "deltas telescope" true
    (same_usage accumulated (Usage.absolute reordered))

let identity_examples () =
  let first, allocator = Run_id.Allocator.fresh Run_id.Allocator.empty in
  let other, _ = Run_id.Allocator.fresh allocator in
  let thread = thread () in
  let other_thread = checked (Thread_id.parse "thread:two") in
  let watermark, _ =
    observe
      (Usage.initial ~run:first ~thread)
      ~run:first ~thread
      (usage (totals 2 3 7))
  in
  let rejected = usage (totals 900 900 900) in
  Alcotest.(check bool)
    "another run is rejected" true
    (Result.is_error
       (Usage.observe watermark ~run:other ~thread ~absolute:rejected));
  Alcotest.(check bool)
    "another thread is rejected" true
    (Result.is_error
       (Usage.observe watermark ~run:first ~thread:other_thread
          ~absolute:rejected));
  let next, delta =
    observe watermark ~run:first ~thread (usage (totals 4 3 8))
  in
  Alcotest.(check (list string))
    "rejections leave the watermark usable" [ "4"; "3"; "8" ]
    (decimals (Usage.absolute next));
  Alcotest.(check (list string))
    "rejected reports add no usage" [ "2"; "0"; "1" ] (decimals delta)

let run_tokens size =
  let rec allocate left state result =
    if left = 0 then List.rev result
    else
      let token, next = Run_id.Allocator.fresh state in
      allocate (left - 1) next (token :: result)
  in
  allocate size Run_id.Allocator.empty []

let retry_tokens size =
  let rec allocate left state result =
    if left = 0 then List.rev result
    else
      let token, next = Retry_id.Allocator.fresh state in
      allocate (left - 1) next (token :: result)
  in
  allocate size Retry_id.Allocator.empty []

let allocation_agrees size =
  let expected = List.init size (fun n -> string_of_int (n + 1)) in
  let runs = run_tokens size and retries = retry_tokens size in
  let run_set = Run_id.Set.of_list runs in
  let retry_set = Retry_id.Set.of_list retries in
  let run_map =
    List.fold_left
      (fun map token -> Run_id.Map.add token () map)
      Run_id.Map.empty runs
  in
  let retry_map =
    List.fold_left
      (fun map token -> Retry_id.Map.add token () map)
      Retry_id.Map.empty retries
  in
  List.equal String.equal expected (List.map Run_id.text runs)
  && List.equal String.equal expected (List.map Retry_id.text retries)
  && Run_id.Set.cardinal run_set = size
  && Retry_id.Set.cardinal retry_set = size
  && List.equal String.equal expected
       (List.map
          (fun (token, ()) -> Run_id.text token)
          (Run_id.Map.bindings run_map))
  && List.equal String.equal expected
       (List.map
          (fun (token, ()) -> Retry_id.text token)
          (Retry_id.Map.bindings retry_map))
  && List.equal String.equal expected
       (List.map Run_id.text (List.sort Run_id.Order.compare runs))
  && List.equal String.equal expected
       (List.map Retry_id.text (List.sort Retry_id.Order.compare retries))

let allocator_examples () =
  Alcotest.(check bool)
    "exact numeric allocation and container order" true (allocation_agrees 1000)

let protocol_id_examples () =
  let parsers =
    [
      (fun raw -> Result.map Thread_id.text (Thread_id.parse raw));
      (fun raw -> Result.map Turn_id.text (Turn_id.parse raw));
      (fun raw -> Result.map Session_id.text (Session_id.parse raw));
    ]
  in
  List.iter
    (fun parse ->
      List.iter
        (fun raw ->
          Alcotest.(check string)
            "checked bytes preserved" raw
            (checked (parse raw)))
        [ "opaque:1"; " é "; "é" ];
      List.iter
        (fun raw ->
          Alcotest.(check bool)
            "invalid identity rejected" true
            (Result.is_error (parse raw)))
        [ ""; " "; "x\000y"; "\255" ])
    parsers

let key_generator =
  QCheck2.Gen.(
    map
      (fun (priority, (created_at, identifier)) ->
        key priority created_at identifier)
      (pair
         (oneof_list
            [
              None;
              Some (-1);
              Some 0;
              Some 1;
              Some 2;
              Some 3;
              Some 4;
              Some 5;
              Some max_int;
            ])
         (pair
            (oneof [ return None; map Option.some (int_range 0 59) ])
            (oneof_list [ "SYM-A"; "SYM-a"; "SYM-10"; "SYM-2"; "é"; "é" ]))))

let triple generator =
  QCheck2.Gen.(
    map
      (fun (a, (b, c)) -> (a, b, c))
      (pair generator (pair generator generator)))

let dispatch_agrees (left, right) =
  sign (Dispatch_order.dispatch (issue left) (issue right))
  = sign (Model.dispatch left right)

let dispatch_preorder (a, b, c) =
  let values = (issue a, issue b, issue c) in
  List.for_all
    (fun compare -> preorder compare values)
    [
      Dispatch_order.priority;
      Dispatch_order.created_at;
      Dispatch_order.identifier;
      Dispatch_order.dispatch;
    ]

let composition_laws (a, b, c) =
  let first x y = 7 * Int.compare (x mod 5) (y mod 5) in
  let second x y = 3 * Int.compare (y mod 7) (x mod 7) in
  let third x y = Int.compare (abs x) (abs y) in
  let compose = Dispatch_order.then_by in
  let left = compose (compose first second) third in
  let right = compose first (compose second third) in
  sign (left a b) = sign (right a b)
  && preorder left (a, b, c)
  && List.for_all
       (fun compare ->
         sign (compose Dispatch_order.equal compare a b) = sign (compare a b)
         && sign (compose compare Dispatch_order.equal a b) = sign (compare a b)
         && sign (compose compare compare a b) = sign (compare a b))
       [ first; second; third ]

let backoff_generator =
  QCheck2.Gen.(pair (int_range 1 200) (int_range 0 1_000_000))

let backoff_agrees (n, cap) =
  let n = Z.of_int n and cap = Z.of_int cap in
  String.equal
    (Milliseconds.decimal
       (Backoff.failure ~attempt:(attempt n) ~cap:(milliseconds cap)))
    (Z.to_string (Model.backoff ~attempt:n ~cap))

let backoff_monotone (a, (b, cap)) =
  let lower = Z.of_int (min a b) and upper = Z.of_int (max a b) in
  let cap = milliseconds (Z.of_int cap) in
  let left = Backoff.failure ~attempt:(attempt lower) ~cap in
  let right = Backoff.failure ~attempt:(attempt upper) ~cap in
  Milliseconds.compare left right <= 0 && Milliseconds.compare right cap <= 0

let cap_monotone (n, (a, b)) =
  let attempt = attempt (Z.of_int n) in
  let low = milliseconds (Z.of_int (min a b)) in
  let high = milliseconds (Z.of_int (max a b)) in
  Milliseconds.compare
    (Backoff.failure ~attempt ~cap:low)
    (Backoff.failure ~attempt ~cap:high)
  <= 0

let natural_generator =
  QCheck2.Gen.(
    oneof
      [
        map Z.of_int (int_range 0 1_000_000);
        map (fun exponent -> Z.shift_left Z.one exponent) (int_range 0 256);
      ])

let totals_generator =
  QCheck2.Gen.(
    map
      (fun (input, (output, total)) -> { Model.input; output; total })
      (pair natural_generator (pair natural_generator natural_generator)))

let addition_laws (a, b, c) =
  let left = usage a and middle = usage b and right = usage c in
  usage_agrees (Model.sum [ a; b; c ]) (Usage.add (Usage.add left middle) right)
  && same_usage
       (Usage.add (Usage.add left middle) right)
       (Usage.add left (Usage.add middle right))
  && same_usage (Usage.add left middle) (Usage.add middle left)
  && same_usage (Usage.add left Usage.zero) left
  && same_usage (Usage.add Usage.zero left) left

let join_laws (a, b, c) =
  let left = usage a and middle = usage b and right = usage c in
  usage_agrees
    (Model.supremum [ a; b; c ])
    (Usage.join (Usage.join left middle) right)
  && same_usage
       (Usage.join (Usage.join left middle) right)
       (Usage.join left (Usage.join middle right))
  && same_usage (Usage.join left middle) (Usage.join middle left)
  && same_usage (Usage.join left left) left
  && same_usage (Usage.join left Usage.zero) left
  && same_usage (Usage.join Usage.zero left) left

let difference_agrees (previous, current) =
  usage_agrees
    (Model.growth ~previous ~current)
    (Usage.difference ~previous:(usage previous) ~current:(usage current))

let watermark_agrees reports =
  let run = run () and thread = thread () in
  let run_text = Run_id.text run and thread_text = Thread_id.text thread in
  let rec process actual expected deltas = function
    | [] ->
        same_usage
          (List.fold_left Usage.add Usage.zero deltas)
          (Usage.absolute actual)
        && usage_agrees (Model.absolute expected) (Usage.absolute actual)
    | report :: rest -> (
        match
          ( Usage.observe actual ~run ~thread ~absolute:(usage report),
            Model.observe expected ~run:run_text ~thread:thread_text ~report )
        with
        | Ok (next, delta), Ok (model_next, model_delta) ->
            usage_agrees model_delta delta
            && usage_agrees (Model.absolute model_next) (Usage.absolute next)
            && process next model_next (delta :: deltas) rest
        | Error _, Error _ | Ok _, Error _ | Error _, Ok _ -> false)
  in
  let initial = Usage.initial ~run ~thread in
  usage_agrees Model.zero (Usage.absolute initial)
  && process initial
       (Model.initial ~run:run_text ~thread:thread_text)
       [] reports

let final_usage reports =
  let run = run () and thread = thread () in
  let rec process watermark = function
    | [] -> Some (Usage.absolute watermark)
    | report :: rest -> (
        match Usage.observe watermark ~run ~thread ~absolute:(usage report) with
        | Error _ -> None
        | Ok (next, _) -> process next rest)
  in
  process (Usage.initial ~run ~thread) reports

let order_independent reports =
  match (final_usage reports, final_usage (List.rev reports)) with
  | Some left, Some right -> same_usage left right
  | None, None | Some _, None | None, Some _ -> false

let identity_agrees report =
  let run, allocator = Run_id.Allocator.fresh Run_id.Allocator.empty in
  let foreign_run, _ = Run_id.Allocator.fresh allocator in
  let thread = thread () in
  let foreign_thread = checked (Thread_id.parse "thread:foreign") in
  let actual = Usage.initial ~run ~thread in
  let expected =
    Model.initial ~run:(Run_id.text run) ~thread:(Thread_id.text thread)
  in
  let rejects foreign_run foreign_thread =
    match
      ( Usage.observe actual ~run:foreign_run ~thread:foreign_thread
          ~absolute:(usage report),
        Model.observe expected ~run:(Run_id.text foreign_run)
          ~thread:(Thread_id.text foreign_thread)
          ~report )
    with
    | Error _, Error (Model.Wrong_run | Model.Wrong_thread) -> true
    | Ok _, Ok _ | Error _, Ok _ | Ok _, Error _ -> false
  in
  rejects foreign_run thread && rejects run foreign_thread
  &&
  match
    ( Usage.observe actual ~run ~thread ~absolute:(usage report),
      Model.observe expected ~run:(Run_id.text run)
        ~thread:(Thread_id.text thread) ~report )
  with
  | Ok (next, delta), Ok (model_next, model_delta) ->
      usage_agrees (Model.absolute model_next) (Usage.absolute next)
      && usage_agrees model_delta delta
  | Error _, Error _ | Error _, Ok _ | Ok _, Error _ -> false

let tests =
  [
    Alcotest.test_case "dispatch buckets, timestamps and identifiers" `Quick
      dispatch_examples;
    Alcotest.test_case "composition is not commutative or identity equality"
      `Quick composition_examples;
    Alcotest.test_case "backoff handles caps, overflow and huge attempts" `Quick
      backoff_examples;
    Alcotest.test_case "absolute usage reports never recount tokens" `Quick
      usage_examples;
    Alcotest.test_case "usage rejects another run or thread" `Quick
      identity_examples;
    Alcotest.test_case "run/retry allocators have numeric container order"
      `Quick allocator_examples;
    Alcotest.test_case "protocol ID domains preserve checked bytes" `Quick
      protocol_id_examples;
  ]

let properties =
  let reports =
    QCheck2.Gen.(list_size (int_range 0 maximum_reports) totals_generator)
  in
  [
    QCheck2.Test.make ~name:"dispatch agrees with independent tuple model"
      ~count:samples
      QCheck2.Gen.(pair key_generator key_generator)
      dispatch_agrees;
    QCheck2.Test.make
      ~name:"dispatch components and composition are total preorders"
      ~count:samples (triple key_generator) dispatch_preorder;
    QCheck2.Test.make ~name:"lexicographic composition monoid and preorder laws"
      ~count:samples
      (triple QCheck2.Gen.(int_range (-1000) 1000))
      composition_laws;
    QCheck2.Test.make
      ~name:"backoff agrees with bounded mathematical power model"
      ~count:samples backoff_generator backoff_agrees;
    QCheck2.Test.make ~name:"backoff is monotone in attempt and below cap"
      ~count:samples
      QCheck2.Gen.(pair (int_range 1 200) backoff_generator)
      backoff_monotone;
    QCheck2.Test.make ~name:"backoff is monotone in cap" ~count:samples
      QCheck2.Gen.(
        pair (int_range 1 200)
          (pair (int_range 0 1_000_000) (int_range 0 1_000_000)))
      cap_monotone;
    QCheck2.Test.make ~name:"usage addition agrees with exact product monoid"
      ~count:samples (triple totals_generator) addition_laws;
    QCheck2.Test.make ~name:"usage join agrees with independent supremum model"
      ~count:samples (triple totals_generator) join_laws;
    QCheck2.Test.make
      ~name:"usage differences agree with nonnegative growth model"
      ~count:samples
      QCheck2.Gen.(pair totals_generator totals_generator)
      difference_agrees;
    QCheck2.Test.make
      ~name:"usage watermarks agree with report history and telescope"
      ~count:samples reports watermark_agrees;
    QCheck2.Test.make ~name:"usage accepted totals ignore report arrival order"
      ~count:samples reports order_independent;
    QCheck2.Test.make
      ~name:"usage identity rejection agrees with independent model"
      ~count:samples totals_generator identity_agrees;
    QCheck2.Test.make
      ~name:"run/retry token allocation agrees with natural-number lists"
      ~count:samples
      QCheck2.Gen.(int_range 0 100)
      allocation_agrees;
  ]
