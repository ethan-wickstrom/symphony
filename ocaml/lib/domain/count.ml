type t = Z.t

let parse s =
  if s = "" || not (String.for_all (fun c -> c >= '0' && c <= '9') s) then
    Error "expected nonnegative decimal digits"
  else Ok (Z.of_string s)

let decimal = Z.to_string

let decimal_bounded ~max_bytes n =
  if max_bytes <= 0 || max_bytes > max_int / 4 then
    Error "invalid decimal display budget"
  else if Z.numbits n > max_bytes * 4 then
    Error "decimal display budget exceeded"
  else
    let s = Z.to_string n in
    if String.length s > max_bytes then Error "decimal display budget exceeded"
    else Ok s

let zero = Z.zero
let one = Z.one
let add = Z.add
let compare = Z.compare
let max = Z.max
let delta ~previous ~current = Z.max Z.zero (Z.sub current previous)
