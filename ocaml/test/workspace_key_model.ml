type error = Invalid_component | Too_long

module Hash = Digestif.SHA256

let max_component_bytes = 255
let hash_hex_chars = 32

let alphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"

let replacements =
  List.map (fun byte -> (byte, byte)) (List.of_seq (String.to_seq alphabet))

let replace byte =
  Option.value ~default:'_'
    (List.find_map
       (fun (allowed, replacement) ->
         if Char.equal byte allowed then Some replacement else None)
       replacements)

let rec take count bytes =
  match (count, bytes) with
  | 0, _ | _, [] -> []
  | left, byte :: rest -> byte :: take (left - 1) rest

let derive raw =
  let bytes = List.of_seq (String.to_seq raw) in
  let sanitized = List.map replace bytes in
  let candidate =
    if List.equal Char.equal bytes sanitized then sanitized
    else
      let hex = Hash.to_hex (Hash.digest_string raw) in
      sanitized @ ('-' :: take hash_hex_chars (List.of_seq (String.to_seq hex)))
  in
  match candidate with
  | [] | [ '.' ] | [ '.'; '.' ] -> Error Invalid_component
  | _ ->
      if List.length candidate > max_component_bytes then Error Too_long
      else Ok (String.of_seq (List.to_seq candidate))
