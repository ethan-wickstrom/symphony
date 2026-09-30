type t = string

module Hash = Digestif.SHA256

let max_component_bytes = 255
let hash_hex_chars = 32
let separator = "-"
let suffix_bytes = String.length separator + hash_hex_chars

let length_error =
  Printf.sprintf "workspace key exceeds %d bytes; shorten the issue identifier"
    max_component_bytes

let sanitize = function
  | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-') as byte -> byte
  | _ -> '_'

let of_identifier identifier =
  let raw = Issue_identifier.text identifier in
  if String.length raw > max_component_bytes then Error length_error
  else if String.equal raw "." || String.equal raw ".." then
    Error "workspace key is a dot component; change the issue identifier"
  else
    let sanitized = String.map sanitize raw in
    if String.equal raw sanitized then Ok raw
    else if String.length raw + suffix_bytes > max_component_bytes then
      Error length_error
    else
      (* Hash the original bytes, preserving identity lost by sanitization. *)
      let digest = Hash.to_hex (Hash.digest_string raw) in
      let prefix =
        String.of_seq (Seq.take hash_hex_chars (String.to_seq digest))
      in
      Ok (sanitized ^ separator ^ prefix)

let text key = key
let compare = String.compare
