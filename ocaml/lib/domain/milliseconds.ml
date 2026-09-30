type t = int64

let parse s =
  match Count.parse s with
  | Error _ as e -> e
  | Ok n -> (
      match Int64.of_string_opt (Count.decimal n) with
      | Some x -> Ok x
      | None -> Error "duration exceeds signed 64-bit milliseconds")

let decimal = Int64.to_string
let zero = 0L
let compare = Int64.compare

let add x y =
  if Int64.compare x (Int64.sub Int64.max_int y) > 0 then
    Error "duration addition overflow"
  else Ok (Int64.add x y)
