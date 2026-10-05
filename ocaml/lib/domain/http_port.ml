type t = int

let maximum = 65535

let parse text =
  match int_of_string_opt text with
  | Some value when value >= 0 && value <= maximum -> Ok value
  | None | Some _ -> Error "port must be an integer from 0 to 65535"

let number value = value
