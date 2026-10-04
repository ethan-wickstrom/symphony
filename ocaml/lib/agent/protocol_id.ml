type view = String of string | Integer of int64
type t = view

type error =
  | Invalid_type
  | Invalid_integer
  | Integer_range
  | String_limit
  | Invalid_utf8
  | Invalid_json

let max_string_bytes = 1024

let of_string value =
  if String.length value > max_string_bytes then Error String_limit
  else if not (Text.valid_utf8 value) then Error Invalid_utf8
  else Ok (String value)

let of_int64 value = Integer value
let view value = value

let compare left right =
  match (left, right) with
  | String left, String right -> String.compare left right
  | Integer left, Integer right -> Int64.compare left right
  | String _, Integer _ -> -1
  | Integer _, String _ -> 1

let equal left right = compare left right = 0

let integer_lexeme value =
  let length = String.length value in
  let start = if length > 0 && value.[0] = '-' then 1 else 0 in
  let rec digits index =
    if index = length then true
    else if value.[index] < '0' || value.[index] > '9' then false
    else digits (index + 1)
  in
  start < length && digits start

let decode value =
  match Json.view value with
  | Json.String value -> of_string value
  | Json.Number value -> (
      if not (integer_lexeme value) then Error Invalid_integer
      else
        match Int64.of_string_opt value with
        | Some value -> Ok (Integer value)
        | None -> Error Integer_range)
  | Json.Null | Json.Bool _ | Json.Array _ | Json.Object _ -> Error Invalid_type

let encode value =
  let json =
    match value with
    | String value -> Json.String value
    | Integer value -> Json.Number (Int64.to_string value)
  in
  Result.map_error (fun _ -> Invalid_json) (Json.of_view json)
