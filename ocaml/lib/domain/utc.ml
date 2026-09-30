type t = Ptime.t

let parse s =
  match Ptime.of_rfc3339 ~strict:true s with
  | Ok (t, _, consumed) when consumed = String.length s -> Ok t
  | Ok _ | Error _ -> Error "expected a complete RFC 3339 timestamp"

let rfc3339 t = Ptime.to_rfc3339 ~frac_s:12 ~tz_offset_s:0 t
let compare = Ptime.compare
