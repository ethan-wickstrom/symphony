type t = int64

let parse s =
  match Count.parse s with
  | Error _ as e -> e
  | Ok n -> (
      match Int64.of_string_opt (Count.decimal n) with
      | Some x -> Ok x
      | None -> Error "duration exceeds signed 64-bit milliseconds")

let decimal = Int64.to_string
let nanoseconds_per_millisecond = 1_000_000

let nanoseconds ms =
  (* Scale in the exact additive monoid, without a bounded native product. *)
  let rec scale factor value total =
    if factor = 0 then total
    else
      let total = if factor land 1 = 1 then Count.add total value else total in
      scale (factor lsr 1) (Count.add value value) total
  in
  scale nanoseconds_per_millisecond (Count.of_uint64_bits ms) Count.zero

let zero = 0L
let compare = Int64.compare

let add x y =
  if Int64.compare x (Int64.sub Int64.max_int y) > 0 then
    Error "duration addition overflow"
  else Ok (Int64.add x y)
