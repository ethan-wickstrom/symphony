type memory = {
  live_heap_bytes : Count.t;
  fiber_stack_bytes : Count.t;
  reserved_heap_bytes : Count.t;
  allocated_bytes : Count.t;
}

let exact_counter_limit = 9_007_199_254_740_992.
let bits_per_byte = 8
let word_bytes = Z.of_int (Sys.word_size / bits_per_byte)

let diagnostic message =
  Diagnostic.make ~site:(Diagnostic.Host "capacity measurement") ~message
    ~remedy:"use coherent OCaml counters below the exact floating-point horizon"

let natural value =
  match Count.parse (Z.to_string value) with
  | Ok count -> count
  | Error message -> invalid_arg message

let exact_counter value =
  Float.is_finite value && value >= 0.
  && value < exact_counter_limit
  && Float.floor value = value

let of_stat (stat : Gc.stat) =
  if
    stat.Gc.live_words < 0 || stat.Gc.heap_words < 0
    || stat.Gc.live_stacks_words < 0
  then Error (diagnostic "negative managed-memory word count")
  else if stat.Gc.live_words > stat.Gc.heap_words then
    Error (diagnostic "live heap exceeds reserved heap")
  else if
    not
      (List.for_all exact_counter
         [ stat.Gc.minor_words; stat.Gc.major_words; stat.Gc.promoted_words ])
  then Error (diagnostic "allocation counter has unsupported precision")
  else if
    stat.Gc.promoted_words > stat.Gc.minor_words
    || stat.Gc.promoted_words > stat.Gc.major_words
  then Error (diagnostic "promoted allocation exceeds its source counters")
  else
    (* Promotion is already counted in both heaps; subtract it exactly once. *)
    let allocated_words =
      Z.sub
        (Z.add
           (Z.of_float stat.Gc.minor_words)
           (Z.of_float stat.Gc.major_words))
        (Z.of_float stat.Gc.promoted_words)
    in
    let bytes words = natural (Z.mul words word_bytes) in
    Ok
      {
        live_heap_bytes = bytes (Z.of_int stat.Gc.live_words);
        fiber_stack_bytes = bytes (Z.of_int stat.Gc.live_stacks_words);
        reserved_heap_bytes = bytes (Z.of_int stat.Gc.heap_words);
        allocated_bytes = bytes allocated_words;
      }

let snapshot () = of_stat (Gc.stat ())

type samples = { limit : Count.t; size : Count.t; values : Seconds.t list }
type added = Added of samples | Full of samples

let make ~limit =
  { limit = Positive_count.count limit; size = Count.zero; values = [] }

let count samples = samples.size

let add duration samples =
  if Count.compare samples.size samples.limit >= 0 then Full samples
  else
    Added
      {
        samples with
        size = Count.add samples.size Count.one;
        values = duration :: samples.values;
      }

let quantile ~numerator ~denominator samples =
  if numerator <= 0 || numerator > denominator || samples.values = [] then None
  else
    (* Exact rank arithmetic keeps fractions near machine-int limits distinct. *)
    let size = Z.of_int (List.length samples.values) in
    let denominator = Z.of_int denominator in
    let rank =
      Z.div
        (Z.add (Z.mul size (Z.of_int numerator)) (Z.pred denominator))
        denominator
    in
    let sorted =
      List.sort
        (fun a b ->
          Count.compare (Seconds.nanoseconds a) (Seconds.nanoseconds b))
        samples.values
    in
    Option.map Seconds.nanoseconds (List.nth_opt sorted (Z.to_int rank - 1))
