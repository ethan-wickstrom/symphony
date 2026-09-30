type t = Count.t

let parse s =
  match Count.parse s with
  | Error _ as e -> e
  | Ok n when Count.compare n Count.zero = 0 ->
      Error "expected a positive count"
  | Ok n -> Ok n

let first = Count.one
let next n = Count.add n first
let count x = x
