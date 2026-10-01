type t = V of view

and view =
  | Null
  | Bool of bool
  | Number of string
  | String of string
  | Array of t list
  | Object of (string * t) list

let max_bytes = 1_048_576
let max_depth = 64
let max_nodes = 32_768
let view (V v) = v

let number s =
  let len = String.length s in
  let digit c = c >= '0' && c <= '9' in
  let rec digits i = if i < len && digit s.[i] then digits (i + 1) else i in
  let i = if len > 0 && s.[0] = '-' then 1 else 0 in
  if i = len then false
  else
    let j =
      if s.[i] = '0' then i + 1
      else if s.[i] >= '1' && s.[i] <= '9' then digits (i + 1)
      else i
    in
    if j = i then false
    else
      let k = if j < len && s.[j] = '.' then digits (j + 1) else j in
      if k = j + 1 then false
      else
        let e = if k < len && (s.[k] = 'e' || s.[k] = 'E') then k + 1 else k in
        let sign =
          if e > k && e < len && (s.[e] = '+' || s.[e] = '-') then e + 1 else e
        in
        let finish = if e > k then digits sign else k in
        finish = len && (e = k || finish > sign)

let rec raw (V v) : Yojson.Raw.t =
  match v with
  | Null -> `Null
  | Bool b -> `Bool b
  | Number n -> `Intlit n
  | String s -> `Stringlit (Yojson.Safe.to_string (`String s))
  | Array xs -> `List (List.map raw xs)
  | Object xs -> `Assoc (List.map (fun (k, v) -> (k, raw v)) xs)

let encode v = Yojson.Raw.to_string (raw v)

let quoted_bytes text =
  String.fold_left
    (fun size -> function
      | '"' | '\\' | '\b' | '\012' | '\n' | '\r' | '\t' -> size + 2
      | '\000' .. '\031' | '\127' -> size + 6
      | _ -> size + 1)
    2 text

let wire_list size = function
  | [] -> 2
  | first :: rest ->
      List.fold_left
        (fun total value -> total + 1 + size value)
        (2 + size first)
        rest

let rec encoded_bytes (V json) =
  match json with
  | Null -> 4
  | Bool true -> 4
  | Bool false -> 5
  | Number text -> String.length text
  | String text -> quoted_bytes text
  | Array values -> wire_list encoded_bytes values
  | Object fields ->
      wire_list
        (fun (key, value) -> quoted_bytes key + 1 + encoded_bytes value)
        fields

let numeric_key s =
  let minus = String.starts_with ~prefix:"-" s in
  let s = if minus then String.sub s 1 (String.length s - 1) else s in
  let exponent_pos =
    match String.index_opt s 'e' with
    | Some i -> Some i
    | None -> String.index_opt s 'E'
  in
  let mantissa, exponent =
    match exponent_pos with
    | None -> (s, Z.zero)
    | Some i ->
        ( String.sub s 0 i,
          Z.of_string (String.sub s (i + 1) (String.length s - i - 1)) )
  in
  let places =
    match String.index_opt mantissa '.' with
    | None -> 0
    | Some i -> String.length mantissa - i - 1
  in
  let digits = String.concat "" (String.split_on_char '.' mantissa) in
  let rec first i =
    if i < String.length digits && digits.[i] = '0' then first (i + 1) else i
  in
  let start = first 0 in
  if start = String.length digits then (false, "0", Z.zero)
  else
    let rec last i =
      if i > start && digits.[i - 1] = '0' then last (i - 1) else i
    in
    let finish = last (String.length digits) in
    ( minus,
      String.sub digits start (finish - start),
      Z.add exponent (Z.of_int (String.length digits - finish - places)) )

let rec equal (V a) (V b) =
  match (a, b) with
  | Null, Null -> true
  | Bool a, Bool b -> a = b
  | String a, String b -> a = b
  | Number a, Number b ->
      let sa, ca, ea = numeric_key a in
      let sb, cb, eb = numeric_key b in
      Bool.equal sa sb && String.equal ca cb && Z.equal ea eb
  | Array a, Array b -> List.equal equal a b
  | Object a, Object b ->
      let order (a, _) (b, _) = String.compare a b in
      List.equal
        (fun (ka, a) (kb, b) -> ka = kb && equal a b)
        (List.sort order a) (List.sort order b)
  | ( (Null | Bool _ | Number _ | String _ | Array _ | Object _),
      (Null | Bool _ | Number _ | String _ | Array _ | Object _) ) -> false

let to_int (V json) =
  match json with
  | Number lexeme ->
      let minus, digits, exponent = numeric_key lexeme in
      let max_digits = String.length (string_of_int max_int) in
      let room = max_digits - String.length digits in
      if
        room < 0
        || Z.sign exponent < 0
        || Z.compare exponent (Z.of_int room) > 0
      then None
      else
        let magnitude = digits ^ String.make (Z.to_int exponent) '0' in
        int_of_string_opt (if minus then "-" ^ magnitude else magnitude)
  | Null | Bool _ | String _ | Array _ | Object _ -> None

let of_view v =
  let nodes = ref 0 in
  let bytes = ref 0 in
  let ( let* ) = Result.bind in
  let charge n =
    if n > max_bytes - !bytes then Error "JSON byte limit exceeded"
    else (
      bytes := !bytes + n;
      Ok ())
  in
  (* Charge the wire form before serialization can duplicate checked children. *)
  let string_bytes s =
    let* () = charge 2 in
    let* () = charge (String.length s) in
    let rec escaped i =
      if i = String.length s then Ok ()
      else
        let extra =
          match s.[i] with
          | '"' | '\\' | '\b' | '\012' | '\n' | '\r' | '\t' -> 1
          | '\000' .. '\031' | '\127' -> 5
          | _ -> 0
        in
        match charge extra with
        | Error _ as error -> error
        | Ok () -> escaped (i + 1)
    in
    escaped 0
  in
  let rec check depth (V v) =
    incr nodes;
    if depth > max_depth || !nodes > max_nodes then
      Error "JSON depth/node limit exceeded"
    else
      match v with
      | Null -> charge 4
      | Bool b -> charge (if b then 4 else 5)
      | Number n ->
          let* () = charge (String.length n) in
          if number n then Ok () else Error "invalid JSON number"
      | String s ->
          let* () = string_bytes s in
          if Text.valid_utf8 s then Ok () else Error "invalid JSON string UTF-8"
      | Array xs ->
          let* () = charge 2 in
          all (depth + 1) xs
      | Object xs ->
          let* () = charge 2 in
          let module Keys = Set.Make (String) in
          let rec fields seen = function
            | [] -> Ok ()
            | (k, value) :: rest ->
                let* () = string_bytes k in
                if not (Text.valid_utf8 k) then Error "invalid JSON key UTF-8"
                else if Keys.mem k seen then Error "duplicate JSON object key"
                else
                  let* () = charge 1 in
                  let* () = check (depth + 1) value in
                  let* () =
                    match rest with
                    | [] -> Ok ()
                    | _ :: _ -> charge 1
                  in
                  fields (Keys.add k seen) rest
          in
          fields Keys.empty xs
  and all depth = function
    | [] -> Ok ()
    | x :: xs ->
        let* () = check depth x in
        let* () =
          match xs with
          | [] -> Ok ()
          | _ :: _ -> charge 1
        in
        all depth xs
  in
  let t = V v in
  match check 0 t with
  | Error _ as e -> e
  | Ok () -> Ok t

let depth_ok s =
  let rec loop i depth quoted escaped =
    if i = String.length s then true
    else
      let c = s.[i] in
      if quoted then
        if escaped then loop (i + 1) depth true false
        else if c = '\\' then loop (i + 1) depth true true
        else loop (i + 1) depth (c <> '"') false
      else if c = '"' then loop (i + 1) depth true false
      else if c = '{' || c = '[' then
        depth < max_depth && loop (i + 1) (depth + 1) false false
      else
        loop (i + 1)
          (if c = '}' || c = ']' then depth - 1 else depth)
          false false
  in
  loop 0 0 false false

let parse s =
  if String.length s > max_bytes || not (depth_ok s) then
    Error "JSON byte/depth limit exceeded"
  else if not (Text.valid_utf8 s) then Error "invalid JSON source UTF-8"
  else
    let rec convert : Yojson.Raw.t -> t = function
      | `Null -> V Null
      | `Bool b -> V (Bool b)
      | `Intlit n | `Floatlit n -> V (Number n)
      | `Stringlit s -> (
          match Yojson.Safe.from_string s with
          | `String s -> V (String s)
          | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _
            -> raise (Yojson.Json_error "invalid string literal"))
      | `Assoc xs -> V (Object (List.map (fun (k, v) -> (k, convert v)) xs))
      | `List xs -> V (Array (List.map convert xs))
    in
    try of_view (view (convert (Yojson.Raw.from_string s)))
    with Yojson.Json_error _ -> Error "invalid JSON syntax"
