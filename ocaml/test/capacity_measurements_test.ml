module M = Capacity_measurements

let property_cases = 500
let property_seed = 20261003
let maximum_population = 48
let bits_per_byte = 8
let word_bytes = Z.of_int (Sys.word_size / bits_per_byte)
let exact_counter_limit = 9_007_199_254_740_992.
let report_quantiles = [ (1, 2); (95, 100); (99, 100); (1, 1) ]

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let observed = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Diagnostic.render error)

let natural text = checked (Count.parse text)
let positive n = checked (Positive_count.parse (string_of_int n))
let duration value = Seconds.of_nanoseconds value
let decimal value = Option.map Count.decimal value

let population values =
  let empty = M.make ~limit:(positive (max 1 (List.length values))) in
  List.fold_left
    (fun samples value ->
      match M.add (duration value) samples with
      | M.Added next -> next
      | M.Full _ -> Alcotest.fail "unexpected population limit")
    empty values

let base_stat () =
  Gc.
    {
      minor_words = 0.;
      promoted_words = 0.;
      major_words = 0.;
      minor_collections = 0;
      major_collections = 0;
      heap_words = 0;
      heap_chunks = 0;
      live_words = 0;
      live_blocks = 0;
      free_words = 0;
      free_blocks = 0;
      largest_free = 0;
      fragments = 0;
      compactions = 0;
      top_heap_words = 0;
      stack_size = 0;
      forced_major_collections = 0;
      live_stacks_words = 0;
    }

let empty_and_invalid () =
  let empty = M.make ~limit:Positive_count.first in
  let one = population [ natural "7" ] in
  Alcotest.(check (option string))
    "empty" None
    (decimal (M.quantile ~numerator:1 ~denominator:2 empty));
  List.iter
    (fun (numerator, denominator) ->
      Alcotest.(check (option string))
        "invalid fraction" None
        (decimal (M.quantile ~numerator ~denominator one)))
    [ (0, 1); (-1, 1); (1, 0); (1, -1); (2, 1) ]

let bound_and_persistence () =
  let empty = M.make ~limit:Positive_count.first in
  let added =
    match M.add (duration (natural "9")) empty with
    | M.Added samples -> samples
    | M.Full _ -> Alcotest.fail "empty population is full"
  in
  Alcotest.(check string)
    "prior population remains empty" "0"
    (Count.decimal (M.count empty));
  match M.add (duration Count.zero) added with
  | M.Added _ -> Alcotest.fail "limit did not reject insertion"
  | M.Full samples ->
      Alcotest.(check string)
        "count unchanged" "1"
        (Count.decimal (M.count samples));
      Alcotest.(check (option string))
        "value unchanged" (Some "9")
        (decimal (M.quantile ~numerator:1 ~denominator:1 samples))

let exact_ranks () =
  let values =
    [ natural "18446744073709551617"; natural "18446744073709551618" ]
  in
  let samples = population values in
  Alcotest.(check (option string))
    "below half near machine limit" (Some "18446744073709551617")
    (decimal (M.quantile ~numerator:(max_int / 2) ~denominator:max_int samples));
  Alcotest.(check (option string))
    "above half near machine limit" (Some "18446744073709551618")
    (decimal
       (M.quantile ~numerator:((max_int / 2) + 1) ~denominator:max_int samples));
  let fifty =
    List.init 100 (fun n -> natural (string_of_int (n + 1))) |> population
  in
  List.iter
    (fun (numerator, denominator) ->
      let expected =
        if denominator = 2 then "50" else string_of_int numerator
      in
      Alcotest.(check (option string))
        "declared report rank" (Some expected)
        (decimal (M.quantile ~numerator ~denominator fifty)))
    [ (1, 2); (95, 100); (99, 100); (100, 100) ]

let exact_allocation_totals () =
  let stat =
    {
      (base_stat ()) with
      Gc.minor_words = exact_counter_limit -. 1.;
      major_words = exact_counter_limit -. 1.;
      promoted_words = 1.;
      live_words = 2;
      heap_words = 3;
      live_stacks_words = 5;
    }
  in
  let memory = observed (M.of_stat stat) in
  let expected words = Z.to_string (Z.mul (Z.of_string words) word_bytes) in
  Alcotest.(check string)
    "exact sum beyond float integer horizon"
    (expected "18014398509481981")
    (Count.decimal memory.M.allocated_bytes);
  Alcotest.(check string)
    "live heap word units" (expected "2")
    (Count.decimal memory.M.live_heap_bytes);
  Alcotest.(check string)
    "reserved heap word units" (expected "3")
    (Count.decimal memory.M.reserved_heap_bytes);
  Alcotest.(check string)
    "stack word units" (expected "5")
    (Count.decimal memory.M.fiber_stack_bytes)

let reject_bad_stats () =
  let rejects stat =
    match M.of_stat stat with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "invalid GC counters were accepted"
  in
  (* Each source counter needs its own guard before sums can be exact. *)
  List.iter
    (fun value ->
      List.iter rejects
        [
          { (base_stat ()) with Gc.minor_words = value };
          { (base_stat ()) with Gc.major_words = value };
          { (base_stat ()) with Gc.promoted_words = value };
        ])
    [
      Float.nan;
      Float.infinity;
      Float.neg_infinity;
      -1.;
      0.5;
      exact_counter_limit;
    ];
  List.iter rejects
    [
      { (base_stat ()) with Gc.live_words = -1 };
      { (base_stat ()) with Gc.heap_words = -1 };
      { (base_stat ()) with Gc.live_stacks_words = -1 };
      { (base_stat ()) with Gc.live_words = 1 };
      { (base_stat ()) with Gc.minor_words = 1.; promoted_words = 1. };
      { (base_stat ()) with Gc.major_words = 1.; promoted_words = 1. };
    ]

let exact_large_words () =
  let stat =
    {
      (base_stat ()) with
      Gc.heap_words = max_int;
      live_words = max_int;
      live_stacks_words = max_int;
    }
  in
  let memory = observed (M.of_stat stat) in
  let expected = Z.to_string (Z.mul (Z.of_int max_int) word_bytes) in
  List.iter
    (fun actual ->
      Alcotest.(check string) "no word-to-byte overflow" expected actual)
    (List.map Count.decimal
       [
         memory.M.live_heap_bytes;
         memory.M.reserved_heap_bytes;
         memory.M.fiber_stack_bytes;
       ])

let program_wide_snapshot () =
  let before = observed (M.snapshot ()) in
  let after = observed (M.snapshot ()) in
  Alcotest.(check bool)
    "lifetime allocation never reverses" true
    (Count.compare before.M.allocated_bytes after.M.allocated_bytes <= 0);
  Alcotest.(check bool)
    "live heap fits reservation" true
    (Count.compare after.M.live_heap_bytes after.M.reserved_heap_bytes <= 0)

let rank_law ~numerator ~denominator values result =
  match result with
  | None -> values = []
  | Some value ->
      let less =
        List.filter (fun x -> Count.compare x value < 0) values |> List.length
      in
      let through =
        List.filter (fun x -> Count.compare x value <= 0) values |> List.length
      in
      let threshold =
        Z.mul (Z.of_int (List.length values)) (Z.of_int numerator)
      in
      List.exists (fun x -> Count.compare x value = 0) values
      && Z.compare (Z.mul (Z.of_int less) (Z.of_int denominator)) threshold < 0
      && Z.compare (Z.mul (Z.of_int through) (Z.of_int denominator)) threshold
         >= 0

let same_quantile a b (numerator, denominator) =
  decimal (M.quantile ~numerator ~denominator a)
  = decimal (M.quantile ~numerator ~denominator b)

let agrees values samples =
  let size = List.length values in
  Count.decimal (M.count samples) = string_of_int size
  && List.for_all
       (fun rank ->
         rank_law ~numerator:rank ~denominator:size values
           (M.quantile ~numerator:rank ~denominator:size samples))
       (List.init size (fun i -> i + 1))

let bounded_program (limit, bits) =
  let rec run values samples = function
    | [] -> agrees values samples
    | bit :: rest ->
        let value = Count.of_uint64_bits bit in
        let next, next_values =
          match M.add (duration value) samples with
          | M.Added next -> (next, value :: values)
          | M.Full next -> (next, values)
        in
        let expected_size = min limit (List.length values + 1) in
        List.length next_values = expected_size
        && agrees next_values next && run next_values next rest
  in
  run [] (M.make ~limit:(positive limit)) bits

let properties () =
  let property name generator law =
    (name, QCheck2.Test.make ~name ~count:property_cases generator law)
  in
  let values = QCheck2.Gen.(list_size (int_range 0 maximum_population) int64) in
  [
    property "every bounded insertion agrees with rank-counting model"
      QCheck2.Gen.(pair (int_range 1 maximum_population) values)
      bounded_program;
    property "nearest rank satisfies strict lower and inclusive upper counts"
      QCheck2.Gen.(pair values (pair (int_range 1 1000) (int_range 1 1000)))
      (fun (bits, (a, b)) ->
        let numerator = min a b in
        let denominator = max a b in
        let values = List.map Count.of_uint64_bits bits in
        rank_law ~numerator ~denominator values
          (M.quantile ~numerator ~denominator (population values)));
    property "arbitrary keyed permutations preserve report quantiles"
      QCheck2.Gen.(
        list_size (int_range 0 maximum_population) (pair int64 int64))
      (fun keyed ->
        let samples values =
          population (List.map (fun (x, _) -> Count.of_uint64_bits x) values)
        in
        let original = samples keyed in
        let reordered =
          samples (List.sort (fun (_, a) (_, b) -> Int64.compare a b) keyed)
        in
        List.for_all (same_quantile original reordered) report_quantiles);
    property "equal durations retain the exact value at every report rank"
      QCheck2.Gen.(pair int64 (int_range 1 maximum_population))
      (fun (bits, size) ->
        let value = Count.of_uint64_bits bits in
        let samples = population (List.init size (fun _ -> value)) in
        List.for_all
          (fun (numerator, denominator) ->
            decimal (M.quantile ~numerator ~denominator samples)
            = Some (Count.decimal value))
          report_quantiles);
    property "promotion changes location without allocating twice"
      QCheck2.Gen.(
        pair (int_range 0 1_000_000)
          (pair (int_range 0 1_000_000) (int_range 0 1_000_000)))
      (fun (minor, (direct, proposed)) ->
        let promoted = min minor proposed in
        let memory =
          observed
            (M.of_stat
               {
                 (base_stat ()) with
                 Gc.minor_words = float_of_int minor;
                 major_words = float_of_int (direct + promoted);
                 promoted_words = float_of_int promoted;
               })
        in
        Count.decimal memory.M.allocated_bytes
        = Z.to_string (Z.mul (Z.of_int (minor + direct)) word_bytes));
  ]

let suite () =
  let example = Alcotest.test_case in
  let examples =
    [
      example "empty population and invalid fractions" `Quick empty_and_invalid;
      example "bound rejection preserves current and prior populations" `Quick
        bound_and_persistence;
      example "exact ranks distinguish adjacent machine-limit fractions" `Quick
        exact_ranks;
      example "exact allocation sum and managed-word units" `Quick
        exact_allocation_totals;
      example "reject unsupported and inconsistent GC counters" `Quick
        reject_bad_stats;
      example "word-to-byte conversion cannot overflow native integers" `Quick
        exact_large_words;
      example "program-wide GC snapshot remains coherent" `Quick
        program_wide_snapshot;
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
  ("capacity measurements", examples @ laws)
