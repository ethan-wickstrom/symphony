let unsigned bits = Z.of_string (Printf.sprintf "%Lu" bits)
let nanos_per_millisecond = Z.of_int 1_000_000
let picos_per_nanosecond = Z.of_int 1_000
let picos_per_day = Z.of_string "86400000000000000"

let after time milliseconds =
  Z.add time (Z.mul (Z.of_int64 milliseconds) nanos_per_millisecond)

let elapsed ~since ~until = Z.max Z.zero (Z.sub until since)

let coordinate time =
  let days, picoseconds = Ptime.Span.to_d_ps (Ptime.to_span time) in
  Z.add (Z.mul (Z.of_int days) picos_per_day) (Z.of_int64 picoseconds)

let wall_at ~wall ~monotonic target =
  match Ptime.of_rfc3339 ~strict:true wall with
  | Error _ -> None
  | Ok (wall, _, _) ->
      let projected =
        Z.add (coordinate wall)
          (Z.mul (Z.sub target monotonic) picos_per_nanosecond)
      in
      if
        Z.compare projected (coordinate Ptime.min) < 0
        || Z.compare projected (coordinate Ptime.max) > 0
      then None
      else
        let days, picoseconds = Z.ediv_rem projected picos_per_day in
        Option.bind
          (Ptime.Span.of_d_ps (Z.to_int days, Z.to_int64 picoseconds))
          (fun span ->
            Option.map
              (fun time -> Ptime.to_rfc3339 ~frac_s:12 ~tz_offset_s:0 time)
              (Ptime.of_span span))
