type t = Z.t

let parse s =
  if s = "" || not (String.for_all (fun c -> c >= '0' && c <= '9') s) then
    Error "expected nonnegative decimal digits"
  else Ok (Z.of_string s)

let decimal = Z.to_string
let native_bits = 64
let native_modulus = Z.shift_left Z.one native_bits

let of_uint64_bits bits =
  let signed = Z.of_int64 bits in
  if Int64.compare bits 0L < 0 then Z.add signed native_modulus else signed

let to_uint64_bits n =
  if Z.numbits n > native_bits then None
  else
    let signed =
      if Z.testbit n (native_bits - 1) then Z.sub n native_modulus else n
    in
    Some (Z.to_int64 signed)

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
