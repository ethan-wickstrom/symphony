let valid_utf8 s =
  let rec loop i =
    if i = String.length s then true
    else
      let d = String.get_utf_8_uchar s i in
      Uchar.utf_decode_is_valid d && loop (i + Uchar.utf_decode_length d)
  in
  loop 0

let case map s =
  let b = Buffer.create (String.length s) in
  let rec loop i =
    if i < String.length s then (
      let d = String.get_utf_8_uchar s i in
      if Uchar.utf_decode_is_valid d then
        let u = Uchar.utf_decode_uchar d in
        match map u with
        | `Self -> Buffer.add_utf_8_uchar b u
        | `Uchars us -> List.iter (Buffer.add_utf_8_uchar b) us
      else Buffer.add_char b s.[i];
      loop (i + Uchar.utf_decode_length d))
  in
  loop 0;
  Buffer.contents b

let lower = case Uucp.Case.Map.to_lower
let upper = case Uucp.Case.Map.to_upper
let normalize s = lower (String.trim s)

let escape s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | '\\' -> Buffer.add_string b "\\\\"
      | c when Char.code c < 32 || Char.code c = 127 ->
          Buffer.add_string b (Printf.sprintf "\\x%02x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b
