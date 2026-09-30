type t = Count.t

let zero = Count.zero
let add = Count.add
let of_nanoseconds x = x
let nanoseconds x = x

let decimal n =
  let s = Count.decimal n in
  let padded = String.make (max 0 (10 - String.length s)) '0' ^ s in
  let split = String.length padded - 9 in
  let whole = String.sub padded 0 split in
  let fraction = String.sub padded split 9 in
  let rec trim i =
    if i > 0 && fraction.[i - 1] = '0' then trim (i - 1) else i
  in
  let len = trim 9 in
  if len = 0 then whole else whole ^ "." ^ String.sub fraction 0 len
