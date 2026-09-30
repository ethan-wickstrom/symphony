type t = Count.t

let equal a b = Count.compare a b = 0
let text = Count.decimal

module Allocator = struct
  type token = t
  type t = Count.t

  let empty = Count.zero

  let fresh n =
    let next = Count.add n Count.one in
    (next, next)
end
