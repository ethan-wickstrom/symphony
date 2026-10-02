type t = Count.t

let compare = Count.compare
let equal a b = compare a b = 0
let text = Count.decimal

module Order = struct
  type nonrec t = t

  let compare = compare
end

module Map = Map.Make (Order)
module Set = Set.Make (Order)

module Allocator = struct
  type token = t
  type t = Count.t

  let empty = Count.zero

  let fresh last =
    let next = Count.add last Count.one in
    (next, next)
end
