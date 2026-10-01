type t = Ptime.t

let parse s =
  match Ptime.of_rfc3339 ~strict:true s with
  | Ok (t, _, consumed) when consumed = String.length s -> Ok t
  | Ok _ | Error _ -> Error "expected a complete RFC 3339 timestamp"

let of_unix_seconds seconds =
  if not (Float.is_finite seconds) then
    Error "wall-clock seconds must be finite"
  else
    match Ptime.of_float_s seconds with
    | Some time -> Ok time
    | None -> Error "wall-clock timestamp is outside years 0000 through 9999"

let rfc3339 t = Ptime.to_rfc3339 ~frac_s:12 ~tz_offset_s:0 t
let compare = Ptime.compare

type direction = Earlier | Later

let nanoseconds_per_day = 86_400_000_000_000L
let picoseconds_per_nanosecond = 1_000L
let max_native_nanoseconds = Count.of_uint64_bits (-1L)

let native_span bits =
  (* UInt64 nanoseconds contain at most 213,503 days, including on OCaml 32-bit.
     OCaml cannot express the day/remainder bounds required by Ptime's parser. *)
  let days = Int64.to_int (Int64.unsigned_div bits nanoseconds_per_day) in
  let remainder = Int64.unsigned_rem bits nanoseconds_per_day in
  let picoseconds = Int64.mul remainder picoseconds_per_nanosecond in
  Ptime.Span.of_d_ps (days, picoseconds)

let shift time direction duration =
  let step time bits =
    Option.bind (native_span bits) (fun span ->
        match direction with
        | Earlier -> Ptime.sub_span time span
        | Later -> Ptime.add_span time span)
  in
  (* Every whole chunk advances more than 584 years. Out-of-range input stops
     after at most 18 chunks instead of traversing an unbounded duration. *)
  let rec advance time remaining =
    match Count.to_uint64_bits remaining with
    | Some bits -> step time bits
    | None ->
        Option.bind (step time (-1L)) (fun time ->
            advance time
              (Count.delta ~previous:max_native_nanoseconds ~current:remaining))
  in
  advance time (Seconds.nanoseconds duration)
